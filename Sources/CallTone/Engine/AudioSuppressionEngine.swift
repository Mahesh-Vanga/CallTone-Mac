import Foundation
import CoreAudio
import AudioToolbox
import os
import OSLog

struct AudioProcessInfo: Identifiable, Hashable {
    let id: AudioObjectID // Core Audio process object ID
    let pid: pid_t
    let bundleID: String
    let processName: String
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

enum SuppressionPermissionStatus: String {
    case unknown = "Not Checked"
    case tapStarted = "Tap Started (Access Unverified)"
    case deniedOrSilent = "Permission Needed"
    case unsupportedOS = "Requires macOS 14.2+"
}

/// Suppresses the original calling app's ringtone at the Core Audio HAL layer using
/// macOS 14.2+ Core Audio Process Taps (`AudioHardwareCreateProcessTap` + `CATapDescription`).
@MainActor
final class AudioSuppressionEngine: ObservableObject {
    @Published private(set) var isSuppressing: Bool = false
    @Published private(set) var suppressedBundleIDs: [String] = []
    @Published private(set) var permissionStatus: SuppressionPermissionStatus = .unknown
    @Published private(set) var lastErrorMessage: String?

    private var activeTapID: AudioObjectID = kAudioObjectUnknown
    private var activeAggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var activeIOProcID: AudioDeviceIOProcID?
    private var activeProcessIDs: Set<AudioObjectID> = []
    private var activeTapUUID: UUID?
    private var retryAfter: TimeInterval = 0
    private var isRearmSuppression = false
    private let ioQueue = DispatchQueue(label: "com.calltone.audio.tap", qos: .userInteractive)
    private let ringSignal = OSAllocatedUnfairLock(initialState: RingSignal())
    private let logger = Logger(subsystem: "com.calltone.macos", category: "CallDetection")

    struct RingSignal {
        private var lastBuffer: TimeInterval?
        private var lastAudibleBuffer: TimeInterval?

        mutating func observe(audible: Bool, at time: TimeInterval) {
            lastBuffer = time
            if audible { lastAudibleBuffer = time }
        }

        var isQuiet: Bool {
            guard let lastBuffer, let lastAudibleBuffer else { return false }
            return lastBuffer - lastAudibleBuffer >= 0.06
        }
    }
    deinit {
        // Ensure cleanup even on deinit
        if activeAggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID = activeIOProcID {
                AudioDeviceStop(activeAggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(activeAggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(activeAggregateDeviceID)
        }
        if activeTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(activeTapID)
            }
        }
    }

    // MARK: - Process Discovery via Core Audio HAL

    nonisolated(unsafe) private static var pidMetadataCache: [pid_t: (bundleID: String, name: String)] = [:]
    nonisolated private static let cacheLock = NSLock()

    nonisolated static func fetchActiveAudioProcesses() -> [AudioProcessInfo] {
        autoreleasepool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
                  dataSize > 0 else {
                return []
            }

            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs) == noErr else {
                return []
            }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            var results: [AudioProcessInfo] = []
            results.reserveCapacity(objectIDs.count)
            var activePIDs = Set<pid_t>()

            for objID in objectIDs {
                let pid = readPID(for: objID)
                guard pid > 0, pid != ownPID else { continue }
                activePIDs.insert(pid)

                let runningOutput = readBoolProperty(objID, selector: kAudioProcessPropertyIsRunningOutput)
                let runningInput = readBoolProperty(objID, selector: kAudioProcessPropertyIsRunningInput)

                cacheLock.lock()
                let cached = pidMetadataCache[pid]
                cacheLock.unlock()

                let bundleID: String
                let name: String
                if let cached {
                    bundleID = cached.bundleID
                    name = cached.name
                } else {
                    bundleID = readBundleID(for: objID) ?? ""
                    name = processName(for: pid, fallbackBundleID: bundleID)
                    cacheLock.lock()
                    pidMetadataCache[pid] = (bundleID, name)
                    cacheLock.unlock()
                }

                results.append(AudioProcessInfo(
                    id: objID,
                    pid: pid,
                    bundleID: bundleID,
                    processName: name,
                    isRunningOutput: runningOutput,
                    isRunningInput: runningInput
                ))
            }

            cacheLock.lock()
            if pidMetadataCache.count > activePIDs.count + 16 {
                pidMetadataCache = pidMetadataCache.filter { activePIDs.contains($0.key) }
            }
            cacheLock.unlock()

            return results
        }
    }

    nonisolated private static func readPID(for processObjectID: AudioObjectID) -> pid_t {
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : 0
    }

    nonisolated private static func readBundleID(for processObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &bundleRef)
        guard status == noErr, let cfStr = bundleRef?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    nonisolated private static func readBoolProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    nonisolated private static func processName(for pid: pid_t, fallbackBundleID: String) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        if len > 0 {
            return String(cString: buffer)
        }
        return fallbackBundleID
    }

    // MARK: - Suppression Control

    func suppressRinging(targetApp: CallingApp, additionalApps: [CallingApp], processes: [AudioProcessInfo]) {
        if isRearmSuppression {
            isRearmSuppression = false
            retryAfter = 0
            ringSignal.withLock { $0 = RingSignal() }
        }
        let matching = Self.ringtoneProcesses(targetApp: targetApp, additionalApps: additionalApps, processes: processes)
        suppress(targetApp: targetApp, matching: matching)
    }

    func suppressAppleRingtoneDuringRearm(for app: CallingApp?, processes: [AudioProcessInfo]) {
        guard let app, let renderer = Self.appleRingtoneRenderer(for: app, in: processes) else {
            if isRearmSuppression { stopSuppressing() }
            return
        }

        let alreadyMuted = isRearmSuppression && activeProcessIDs.contains(renderer.id)
        isRearmSuppression = true
        suppress(targetApp: app, matching: [renderer])
        if !alreadyMuted, activeProcessIDs.contains(renderer.id) {
            logger.notice("Native Apple ringtone muted while waiting to rearm")
        }
    }

    nonisolated static func appleRingtoneRenderer(for app: CallingApp, in processes: [AudioProcessInfo]) -> AudioProcessInfo? {
        let candidates = ringtoneProcesses(targetApp: app, additionalApps: [], processes: processes)
        guard !candidates.contains(where: \.isRunningInput) else { return nil }
        // Use the dedicated call UI renderer here. The normal tap also covers shared system and call-audio processes.
        return candidates.first {
            $0.bundleID == "com.apple.InCallService" || $0.processName == "MacInCallService"
        }
    }

    private func suppress(targetApp: CallingApp, matching matchingObjects: [AudioProcessInfo]) {
        guard #available(macOS 14.2, *) else {
            permissionStatus = .unsupportedOS
            lastErrorMessage = "Core Audio Process Tap suppression requires macOS 14.2 or later."
            return
        }

        guard !matchingObjects.isEmpty else { return }
        let objectIDs = Set(matchingObjects.map(\.id))
        guard objectIDs != activeProcessIDs, ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        // A failed start or update can be retried on the next call snapshot after this interval.
        retryAfter = ProcessInfo.processInfo.systemUptime + 0.25

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: Array(objectIDs))
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true
        tapDescription.name = "CallTone Mac-Suppress-\(targetApp.name)"

        if let activeTapUUID {
            tapDescription.uuid = activeTapUUID
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var description = Unmanaged.passUnretained(tapDescription)
            let status = AudioObjectSetPropertyData(activeTapID, &address, 0, nil,
                UInt32(MemoryLayout.size(ofValue: description)), &description)
            guard status == noErr else {
                lastErrorMessage = "Could not update ringtone muting (OSStatus \(status))."
                return
            }
        } else if !startTap(tapDescription, app: targetApp) {
            return
        }

        activeProcessIDs = objectIDs
        isSuppressing = true
        suppressedBundleIDs = matchingObjects.map { $0.bundleID.isEmpty ? $0.processName : $0.bundleID }
        retryAfter = 0
        lastErrorMessage = nil
    }

    nonisolated static func ringtoneProcesses(
        targetApp: CallingApp, additionalApps: [CallingApp], processes: [AudioProcessInfo]
    ) -> [AudioProcessInfo] {
        let appsToMute = [targetApp] + additionalApps
        let isAppleCall = targetApp.isContinuityPhone || targetApp.id == "com.apple.FaceTime"
        return processes.filter { proc in
            let matchesApp = appsToMute.contains { app in
                let matchesBundle = app.bundleIdentifiers.contains { bid in
                    proc.bundleID.caseInsensitiveCompare(bid) == .orderedSame
                }
                let matchesName = app.audioProcessNames.contains { name in
                    proc.processName.localizedCaseInsensitiveContains(name) ||
                    proc.bundleID.localizedCaseInsensitiveContains(name)
                }
                return matchesBundle || matchesName
            }
            let matchesSystemTelephony = isAppleCall && (
                proc.bundleID.caseInsensitiveCompare("systemsoundserverd") == .orderedSame ||
                proc.processName.localizedCaseInsensitiveContains("systemsoundserverd")
            )
            return matchesApp || matchesSystemTelephony
        }
    }

    func isAppleRingQuiet(targetApp: CallingApp, processes: [AudioProcessInfo]) -> Bool {
        guard ringSignal.withLock({ $0.isQuiet }) else { return false }
        let appleIDs = Set(Self.ringtoneProcesses(targetApp: targetApp, additionalApps: [], processes: processes).map(\.id))
        return !processes.contains { $0.isRunningOutput && activeProcessIDs.contains($0.id) && !appleIDs.contains($0.id) }
    }

    @available(macOS 14.2, *)
    private func startTap(_ tapDescription: CATapDescription, app: CallingApp) -> Bool {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            lastErrorMessage = "AudioHardwareCreateProcessTap failed (OSStatus \(tapStatus))."
            return false
        }

        let tapUUIDString = tapDescription.uuid.uuidString
        let aggregateUID = "com.calltone.aggregate.\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTone Mac-Tap-\(app.name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUIDString
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "AudioHardwareCreateAggregateDevice failed (OSStatus \(aggStatus))."
            return false
        }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: format))
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let meterEnabled = (app.isContinuityPhone || app.id == "com.apple.FaceTime")
            && AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format) == noErr
            && format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == kAudioFormatFlagIsFloat
        let signal = ringSignal
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, _, _ in
            guard meterEnabled else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // Keep timestamps only. A silent or unreadable tap must not suppress all ringing.
            let audible = buffers.contains { buffer in
                guard let data = buffer.mData else { return false }
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
                return samples.contains { abs($0) > 0.001 }
            }
            let time = ProcessInfo.processInfo.systemUptime
            _ = signal.withLockIfAvailable { $0.observe(audible: audible, at: time) }
        }

        guard ioStatus == noErr, let createdIOProc = ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(ioStatus))."
            return false
        }

        let startStatus = AudioDeviceStart(aggregateID, createdIOProc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, createdIOProc)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "AudioDeviceStart failed (OSStatus \(startStatus))."
            return false
        }

        self.activeTapID = tapID
        self.activeAggregateDeviceID = aggregateID
        self.activeIOProcID = createdIOProc
        self.activeTapUUID = tapDescription.uuid
        return true
    }

    /// Immediately stops suppressing and restores untouched audio routing for the calling app.
    func stopSuppressing() {
        if activeAggregateDeviceID != kAudioObjectUnknown {
            if let ioProc = activeIOProcID {
                AudioDeviceStop(activeAggregateDeviceID, ioProc)
                AudioDeviceDestroyIOProcID(activeAggregateDeviceID, ioProc)
                activeIOProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(activeAggregateDeviceID)
            activeAggregateDeviceID = kAudioObjectUnknown
        }

        if activeTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(activeTapID)
            }
            activeTapID = kAudioObjectUnknown
        }

        activeTapUUID = nil
        activeProcessIDs.removeAll()
        retryAfter = 0
        isRearmSuppression = false
        ringSignal.withLock { $0 = RingSignal() }
        isSuppressing = false
        suppressedBundleIDs = []
    }

    // MARK: - TCC Permission Trigger Probe

    /// Triggers the macOS System Audio Recording TCC prompt by spinning up a brief throwaway tap
    /// and starting IO on it, then tearing it down cleanly.
    func triggerAudioCapturePermissionProbe() {
        guard #available(macOS 14.2, *) else {
            permissionStatus = .unsupportedOS
            return
        }

        var pid = ProcessInfo.processInfo.processIdentifier
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess) == noErr,
              ownProcess != kAudioObjectUnknown else {
            lastErrorMessage = "Play a ringtone preview, then try checking audio permission again."
            return
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [ownProcess])
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.name = "CallTone Mac-Permission-Probe"
        lastErrorMessage = nil

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr, tapID != kAudioObjectUnknown else {
            permissionStatus = .deniedOrSilent
            return
        }

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTone Mac-Probe",
            kAudioAggregateDeviceUIDKey: "com.calltone.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString
            ]]
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, ioQueue) { _, _, _, _, _ in }
        if status == noErr, let proc = ioProcID {
            guard AudioDeviceStart(aggID, proc) == noErr else {
                AudioDeviceDestroyIOProcID(aggID, proc)
                AudioHardwareDestroyAggregateDevice(aggID)
                AudioHardwareDestroyProcessTap(tapID)
                permissionStatus = .deniedOrSilent
                return
            }
            // Tear down after a short beat so TCC registers and prompts the user
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                AudioDeviceStop(aggID, proc)
                AudioDeviceDestroyIOProcID(aggID, proc)
                AudioHardwareDestroyAggregateDevice(aggID)
                AudioHardwareDestroyProcessTap(tapID)
                self?.permissionStatus = .tapStarted
            }
        } else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            permissionStatus = .deniedOrSilent
        }
    }
}
