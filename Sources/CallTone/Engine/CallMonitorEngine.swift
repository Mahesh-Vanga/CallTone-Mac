import Foundation
import AppKit
import CoreAudio
import UserNotifications
import OSLog
import ApplicationServices

struct DetectedCallEvent: Identifiable, Equatable {
    let id = UUID()
    let app: CallingApp
    let state: CallState
    let detectedAt: Date
    let signalSource: String
    let isSimulated: Bool
}

@MainActor
final class CallMonitorEngine: ObservableObject {
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var activeCall: DetectedCallEvent?
    @Published private(set) var appStates: [String: CallState] = [:]
    @Published private(set) var recentEvents: [DetectedCallEvent] = []
    @Published private(set) var liveAudioOutputs: [String] = []

    private var activeCallHadIncomingWindow = false
    private var activeCallHadAppleUI = false
    private var activeCallHadAppleWindow = false
    @Published private(set) var hasCallUIPermission = AXIsProcessTrusted()

    private var monitorTask: Task<Void, Never>?
    private var processListListener: AudioObjectPropertyListenerBlock?

    private var workspaceObservers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.calltone.macos", category: "CallDetection")
    private var lastSnapshotTime: TimeInterval = 0
    private var awaitingTeardownByApp: Set<String> = []
    private var teardownQuietSince: [String: TimeInterval] = [:]
    /// Timestamps: when each app's call was answered (connected state entered).
    private var connectedSinceTime: [String: TimeInterval] = [:]
    /// Cooldown in seconds after answer/decline before allowing re-ring from the same app.
    private let postCallCooldownSeconds: TimeInterval = 8.0

    private weak var settingsStore: SettingsStore?
    private weak var libraryManager: RingtoneLibraryManager?
    private weak var suppressionEngine: AudioSuppressionEngine?
    private weak var ringtonePlayer: RingtonePlayer?

    func bind(
        settings: SettingsStore,
        library: RingtoneLibraryManager,
        suppression: AudioSuppressionEngine,
        player: RingtonePlayer
    ) {
        self.settingsStore = settings
        self.libraryManager = library
        self.suppressionEngine = suppression
        self.ringtonePlayer = player
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastSnapshotTime = ProcessInfo.processInfo.systemUptime
        installWorkspaceObservers()
        installCoreAudioProcessListener()

        monitorTask?.cancel()
        monitorTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let snapshotTime = ProcessInfo.processInfo.systemUptime
                let snapshot = await Task.detached(priority: .userInitiated) {
                    autoreleasepool {
                        let procs = AudioSuppressionEngine.fetchActiveAudioProcesses()
                        let windows = CallMonitorEngine.fetchVisibleWindowTitlesByPID()
                        return (procs, windows?.titles, AppleCallUI.incomingState(), windows?.appleCallWindowVisible)
                    }
                }.value

                guard let self, self.isMonitoring, !Task.isCancelled else { break }
                self.processSnapshot(audioProcesses: snapshot.0, windowTitlesByPID: snapshot.1, capturedAt: snapshotTime, appleIncoming: snapshot.2, appleCallWindowVisible: snapshot.3)

                let sleepNs: UInt64 = (self.activeCall != nil) ? 35_000_000 : 50_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        removeCoreAudioProcessListener()
        removeWorkspaceObservers()

        if activeCall != nil {
            endActiveCall(reason: "Monitoring stopped")
        }
        if !appStates.isEmpty {
            appStates.removeAll()
        }
        awaitingTeardownByApp.removeAll()
        teardownQuietSince.removeAll()
        connectedSinceTime.removeAll()
    }

    // MARK: - Simulation

    func simulateIncomingCall(for app: CallingApp) {
        guard let settings = settingsStore, let library = libraryManager else { return }
        if activeCall != nil {
            endActiveCall(reason: "Replaced by test call")
        }

        let event = DetectedCallEvent(
            app: app,
            state: .ringing,
            detectedAt: Date(),
            signalSource: "User Test Simulation",
            isSimulated: true
        )
        activeCall = event
        appStates[app.id] = .ringing
        recordEvent(event)

        if settings.suppressOriginalRingtone {
            let extras = settings.muteAllCallingAppsOnRing ? settings.callingApps.filter { $0.isEnabled } : []
            suppressionEngine?.startSuppressing(targetApp: app, additionalApps: extras)
        }
        playResolvedRingtone(for: app, settings: settings, library: library)
    }

    func stopSimulatedOrActiveCall() {
        endActiveCall(reason: "Stopped manually")
    }

    func processSnapshot(audioProcesses: [AudioProcessInfo], windowTitlesByPID: [pid_t: [String]]?, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, appleIncoming: Bool? = nil, appleCallWindowVisible: Bool? = nil) {
        guard capturedAt >= lastSnapshotTime else { return }
        lastSnapshotTime = capturedAt
        let trusted = AXIsProcessTrusted()
        if trusted != hasCallUIPermission { hasCallUIPermission = trusted }
        let activeOut = audioProcesses
            .filter { $0.isRunningOutput }
            .map { $0.processName.isEmpty ? $0.bundleID : "\($0.processName) (\($0.bundleID))" }
        if activeOut != liveAudioOutputs {
            liveAudioOutputs = activeOut
        }

        guard let settings = settingsStore, let library = libraryManager else { return }

        if let current = activeCall, current.isSimulated {
            return
        }

        let enabledApps = settings.callingApps.filter { $0.isEnabled }
        if let current = activeCall, !enabledApps.contains(where: { $0.id == current.app.id }) {
            endActiveCall(reason: "Calling app disabled")
            return
        }
        guard !enabledApps.isEmpty else { return }

        // Shared Apple audio daemons must not start a second ringtone over the active one.
        let appsToInspect = activeCall.map { [$0.app] } ?? enabledApps
        for app in appsToInspect {
            let matchingProcs = audioProcesses.filter { proc in
                app.bundleIdentifiers.contains { proc.bundleID.caseInsensitiveCompare($0) == .orderedSame } ||
                app.audioProcessNames.contains {
                    proc.processName.localizedCaseInsensitiveContains($0) ||
                    proc.bundleID.localizedCaseInsensitiveContains($0)
                }
            }

            let isOutputting = matchingProcs.contains { $0.isRunningOutput }
            let isMicActive = matchingProcs.contains { $0.isRunningInput }
            let appPIDs = app.bundleIdentifiers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
            }
            let pids = Set(matchingProcs.map { $0.pid } + appPIDs)
            let isAppleCall = app.isContinuityPhone || app.id == "com.apple.FaceTime"
            let useAppleUI = isAppleCall && (appleIncoming == true || (activeCallHadAppleUI && appleIncoming == nil))
            let visibleAppleWindow = isAppleCall && appleCallWindowVisible == true && appleIncoming != false
            let hasIncomingWindow = useAppleUI || visibleAppleWindow || (windowTitlesByPID.map {
                Self.checkIncomingWindow(pids: pids, keywords: app.incomingWindowKeywords, windowMap: $0)
            } ?? (activeCall?.app.id == app.id && activeCallHadIncomingWindow))

            let previousState = appStates[app.id] ?? .idle
            if isAppleCall, activeCall?.app.id == app.id {
                if activeCallHadAppleWindow && appleCallWindowVisible == false && appleIncoming != true {
                    endActiveCall(reason: "Apple call window dismissed")
                    return
                }
                if appleIncoming == false {
                    endActiveCall(reason: "Apple call no longer incoming")
                    return
                }
                if appleCallWindowVisible == true && !activeCallHadAppleWindow {
                    logger.notice("Apple call window visible; window-close stop enabled")
                    activeCallHadAppleWindow = true
                }
            }
            if isAppleCall, activeCall?.app.id == app.id, appleIncoming == true {
                activeCallHadAppleUI = true
            }
            if activeCall?.app.id == app.id,
               updateIncomingWindow(hasIncomingWindow) {
                endActiveCall(reason: "Incoming call window closed", waitForTeardown: isAppleCall || isOutputting)
                return
            }

            if isMicActive && !(isAppleCall && appleIncoming == true) {
                connectedSinceTime[app.id] = capturedAt
                teardownQuietSince.removeValue(forKey: app.id)
                if previousState == .ringing {
                    appStates[app.id] = .connected
                    connectedSinceTime[app.id] = capturedAt
                    if activeCall?.app.id == app.id {
                        endActiveCall(reason: "Call answered (mic active)")
                        appStates[app.id] = .connected
                    }
                } else if previousState != .connected {
                    appStates[app.id] = .connected
                    if connectedSinceTime[app.id] == nil {
                        connectedSinceTime[app.id] = capturedAt
                    }
                }
                continue
            }

            let isContinuityOrFaceTime = app.isContinuityPhone || app.id == "com.apple.FaceTime"
            let ringingDetected: Bool
            let signalSource: String

            if isAppleCall, appleIncoming == false {
                ringingDetected = false
                signalSource = ""
            } else if isAppleCall, appleIncoming == true {
                ringingDetected = true
                signalSource = "Apple incoming-call controls"
            } else if visibleAppleWindow {
                ringingDetected = true
                signalSource = isOutputting ? "Apple Call Window + Audio" : "Apple Call Window"
            } else if hasIncomingWindow {
                ringingDetected = true
                signalSource = isOutputting ? "Incoming Window + Audio" : "Incoming Window"
            } else if isContinuityOrFaceTime && isOutputting && !isMicActive {
                ringingDetected = true
                signalSource = "Core Audio Daemon (\(matchingProcs.first(where: { $0.isRunningOutput })?.processName ?? "callservicesd"))"
            } else if !isContinuityOrFaceTime && isOutputting && !isMicActive && !hasIncomingWindow {
                // Fallback for 3rd-party calling apps when Screen Recording isn't granted to read window titles
                if settings.allowAudioFallbackForThirdParty {
                    ringingDetected = true
                    signalSource = "Audio Stream (Fallback: \(matchingProcs.first(where: { $0.isRunningOutput })?.processName ?? app.name))"
                } else {
                    ringingDetected = false
                    signalSource = ""
                }
            } else {
                ringingDetected = false
                signalSource = ""
            }

            // An answered call's lingering audio output is not a new incoming call.
            // Use a time-based cooldown to prevent false re-ring from pulsing audio.
            if previousState == .connected && !hasIncomingWindow {
                if let connectedAt = connectedSinceTime[app.id] {
                    let elapsed = capturedAt - connectedAt
                    if elapsed < postCallCooldownSeconds {
                        // Still within cooldown — ignore all audio signals from this app.
                        continue
                    }
                    // Cooldown expired and no audio — safe to go idle.
                    if !isOutputting {
                        appStates[app.id] = .idle
                        connectedSinceTime.removeValue(forKey: app.id)
                    }
                } else {
                    // No timestamp recorded (shouldn't happen) — record now and skip.
                    connectedSinceTime[app.id] = capturedAt
                }
                continue
            }

            if awaitingTeardownByApp.contains(app.id) {
                let credibleNewRing = appleIncoming == true && isAppleCall
                    || (hasIncomingWindow && !visibleAppleWindow)
                if credibleNewRing {
                    awaitingTeardownByApp.remove(app.id)
                    teardownQuietSince.removeValue(forKey: app.id)
                } else {
                    // shortcut: audio-only calls need three quiet seconds to rearm until a reliable call signal is available.
                    if isOutputting || hasIncomingWindow {
                        teardownQuietSince.removeValue(forKey: app.id)
                    } else if !isAppleCall || capturedAt - (teardownQuietSince[app.id] ?? capturedAt) >= 3 {
                        awaitingTeardownByApp.remove(app.id)
                        teardownQuietSince.removeValue(forKey: app.id)
                    } else if teardownQuietSince[app.id] == nil {
                        teardownQuietSince[app.id] = capturedAt
                    }
                    continue
                }
            }

            if ringingDetected {
                if previousState != .ringing {
                    appStates[app.id] = .ringing
                    handleNewIncomingCall(app: app, signalSource: signalSource, settings: settings, library: library)
                    activeCallHadIncomingWindow = hasIncomingWindow
                    activeCallHadAppleUI = isAppleCall && appleIncoming == true
                    activeCallHadAppleWindow = isAppleCall && (appleCallWindowVisible == true || visibleAppleWindow)
                    if activeCallHadAppleWindow { logger.notice("Apple call window visible; window-close stop enabled") }
                    return
                }
            } else if previousState == .ringing {
                appStates[app.id] = .idle
                if activeCall?.app.id == app.id {
                    endActiveCall(reason: "Call ended or missed", waitForTeardown: isAppleCall || isOutputting)
                    return
                }
            } else if previousState != .idle {
                appStates[app.id] = .idle
            }
        }
    }

    private func handleNewIncomingCall(
        app: CallingApp,
        signalSource: String,
        settings: SettingsStore,
        library: RingtoneLibraryManager
    ) {
        if activeCall?.app.id == app.id && activeCall?.state == .ringing {
            return
        }

        let event = DetectedCallEvent(
            app: app,
            state: .ringing,
            detectedAt: Date(),
            signalSource: signalSource,
            isSimulated: false
        )
        activeCall = event
        logger.notice("Ring start app=\(app.id, privacy: .private) source=\(signalSource, privacy: .public)")
        recordEvent(event)

        if settings.suppressOriginalRingtone {
            let extras = settings.muteAllCallingAppsOnRing ? settings.callingApps.filter { $0.isEnabled } : []
            suppressionEngine?.startSuppressing(targetApp: app, additionalApps: extras)
        }
        playResolvedRingtone(for: app, settings: settings, library: library)
        sendOptionalNotification(for: app, settings: settings)
    }

    private func playResolvedRingtone(
        for app: CallingApp,
        settings: SettingsStore,
        library: RingtoneLibraryManager
    ) {
        guard let item = Self.resolvedRingtone(for: app, globalID: settings.globalRingtoneID, ringtones: library.ringtones) else {
            return
        }
        let fileURL = library.fileURL(for: item)
        ringtonePlayer?.play(
            item: item,
            fileURL: fileURL,
            masterVolume: settings.masterVolume,
            fadeInOverride: 0,
            fadeOutOverride: settings.useGlobalAudioOverrides ? settings.globalFadeOut : nil,
            loopOverride: true,
            outputDeviceID: settings.selectedOutputDeviceID
        )
    }

    nonisolated static func resolvedRingtone(for app: CallingApp, globalID: UUID?, ringtones: [RingtoneItem]) -> RingtoneItem? {
        ringtones.first { $0.id == app.customRingtoneID } ?? ringtones.first { $0.id == globalID }
    }

    // Audio daemons can keep their output stream alive after the call UI closes.
    func updateIncomingWindow(_ isVisible: Bool) -> Bool {
        let closed = activeCallHadIncomingWindow && !isVisible
        activeCallHadIncomingWindow = isVisible
        return closed
    }

    private func endActiveCall(reason: String, waitForTeardown: Bool = true) {
        ringtonePlayer?.stop(fadeOut: false)
        suppressionEngine?.stopSuppressing()
        if let current = activeCall {
            logger.notice("Ring stop app=\(current.app.id, privacy: .private) reason=\(reason, privacy: .public)")
            recordEvent(DetectedCallEvent(app: current.app, state: .ended, detectedAt: Date(), signalSource: reason, isSimulated: current.isSimulated))
            let relatedApps = settingsStore?.callingApps.filter {
                $0.id == current.app.id || !Set($0.audioProcessNames).isDisjoint(with: current.app.audioProcessNames)
            } ?? [current.app]
            for app in relatedApps {
                appStates[app.id] = .idle
                if waitForTeardown && !current.isSimulated {
                    awaitingTeardownByApp.insert(app.id)
                }
            }
        }
        activeCall = nil
        activeCallHadIncomingWindow = false
        activeCallHadAppleUI = false
        activeCallHadAppleWindow = false
    }

    func clearRecentEvents() {
        recentEvents.removeAll()
    }

    private func recordEvent(_ event: DetectedCallEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 25 {
            recentEvents.removeLast(recentEvents.count - 25)
        }
    }

    // MARK: - Window Inspection (Background Safe)

    nonisolated private static func fetchVisibleWindowTitlesByPID() -> (titles: [pid_t: [String]], appleCallWindowVisible: Bool)? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var result: [pid_t: [String]] = [:]
        let appleCallWindowVisible = infoList.contains(where: Self.isAppleCallWindow)
        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let name = (info[kCGWindowName as String] as? String) ?? ""
            let combined = name.trimmingCharacters(in: .whitespaces)
            if !combined.isEmpty {
                result[pid, default: []].append(combined)
            }
        }
        return (result, appleCallWindowVisible)
    }

    nonisolated static func isAppleCallWindow(_ info: [String: Any]) -> Bool {
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              (owner == "MacInCallService" || owner == "InCallService"),
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
        return width >= 100 && height >= 40
    }

    nonisolated static func checkIncomingWindow(pids: Set<pid_t>, keywords: [String], windowMap: [pid_t: [String]]) -> Bool {
        for pid in pids {
            guard let titles = windowMap[pid] else { continue }
            for title in titles {
                for keyword in keywords where title.localizedCaseInsensitiveContains(keyword) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Workspace & Sleep/Wake Observers

    private func installCoreAudioProcessListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let snapshotTime = ProcessInfo.processInfo.systemUptime
            Task.detached(priority: .userInitiated) {
                let procs = AudioSuppressionEngine.fetchActiveAudioProcesses()
                let windows = CallMonitorEngine.fetchVisibleWindowTitlesByPID()
                let incoming = AppleCallUI.incomingState()
                await MainActor.run {
                    guard let self, self.isMonitoring else { return }
                    self.processSnapshot(audioProcesses: procs, windowTitlesByPID: windows?.titles, capturedAt: snapshotTime, appleIncoming: incoming, appleCallWindowVisible: windows?.appleCallWindowVisible)
                }
            }
        }
        processListListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
    }

    private func removeCoreAudioProcessListener() {
        if let block = processListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.global(qos: .userInitiated),
                block
            )
            processListListener = nil
        }
    }

    private func installWorkspaceObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let sleepObs = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endActiveCall(reason: "Mac going to sleep")
            }
        }

        workspaceObservers = [sleepObs]
    }

    private func removeWorkspaceObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            wsCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
    }

    private func sendOptionalNotification(for app: CallingApp, settings: SettingsStore) {
        guard settings.showCallToneNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Custom Ringtone Active"
        content.body = "Playing your custom ringtone for \(app.name)."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
