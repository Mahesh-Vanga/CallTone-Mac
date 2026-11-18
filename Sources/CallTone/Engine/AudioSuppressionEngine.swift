import Foundation
import CoreAudio
import AudioToolbox

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
    private let ioQueue = DispatchQueue(label: "com.calltone.audio.tap", qos: .userInteractive)
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

    /// Starts a Core Audio Process Tap that mutes the target app (and optionally all enabled calling apps)
    /// while the incoming call is ringing so zero default ringtone sound is heard.
    func startSuppressing(targetApp: CallingApp, additionalApps: [CallingApp] = []) {
        stopSuppressing()

        guard #available(macOS 14.2, *) else {
            permissionStatus = .unsupportedOS
            lastErrorMessage = "Core Audio Process Tap suppression requires macOS 14.2 or later."
            return
        }

        let appsToMute = [targetApp] + additionalApps
        let isAppleCall = appsToMute.contains { $0.isContinuityPhone || $0.id == "com.apple.FaceTime" }
        let processes = Self.fetchActiveAudioProcesses()
        let matchingObjects = processes.filter { proc in
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

        guard !matchingObjects.isEmpty else {
            lastErrorMessage = "No active audio process found for \(targetApp.name) to tap."
            return
        }

        let objectIDs = matchingObjects.map { $0.id }
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true
        tapDescription.name = "CallTone Mac-Suppress-\(targetApp.name)"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            lastErrorMessage = "AudioHardwareCreateProcessTap failed (OSStatus \(tapStatus))."
            return
        }

        let outputDeviceID = AudioDeviceManager.getDefaultOutputDeviceID()
        guard let outputUID = AudioDeviceManager.getDeviceUID(for: outputDeviceID) else {
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "Could not resolve default output device UID."
            return
        }

        let tapUUIDString = tapDescription.uuid.uuidString
        let aggregateUID = "com.calltone.aggregate.\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTone Mac-Tap-\(targetApp.name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
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
            return
        }

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, _, _, _, _ in }

        guard ioStatus == noErr, let createdIOProc = ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(ioStatus))."
            return
        }

        let startStatus = AudioDeviceStart(aggregateID, createdIOProc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, createdIOProc)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            lastErrorMessage = "AudioDeviceStart failed (OSStatus \(startStatus))."
            return
        }

        self.activeTapID = tapID
        self.activeAggregateDeviceID = aggregateID
        self.activeIOProcID = createdIOProc
        self.isSuppressing = true
        self.suppressedBundleIDs = matchingObjects.map { $0.bundleID.isEmpty ? $0.processName : $0.bundleID }
        self.lastErrorMessage = nil
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

        let outputID = AudioDeviceManager.getDefaultOutputDeviceID()
        guard let outputUID = AudioDeviceManager.getDeviceUID(for: outputID) else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTone Mac-Probe",
            kAudioAggregateDeviceUIDKey: "com.calltone.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
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
