import AppKit
import ApplicationServices
import Combine
import OSLog

@MainActor
final class AdditionalCallRingtoneMonitor: ObservableObject {
    nonisolated static let meetID = "com.google.Meet"
    nonisolated static let meetAppBundleID = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
    nonisolated private static let browserBundleIDs = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.apple.Safari",
        "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser"
    ]
    private static let enabledKey = "AccessibilityCallAppIDs"
    private static let builtInIDs: Set<String> = [
        "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "us.zoom.xos",
        "com.microsoft.teams2", meetID, "com.hnc.Discord"
    ]

    @Published private var enabledIDs: Set<String>
    @Published private(set) var activeAppID: String?
    private let defaults: UserDefaults
    private weak var settings: SettingsStore?
    private weak var library: RingtoneLibraryManager?
    private weak var callMonitor: CallMonitorEngine?
    private let player = RingtonePlayer()
    private let suppression = AudioSuppressionEngine()
    private let logger = Logger(subsystem: "com.calltone.macos", category: "AdditionalCalls")
    private var monitorEvents: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var handledAppID: String?
    private var playedToneID: UUID?
    private var lastConfirmedAt: TimeInterval?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledIDs = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
    }

    func handles(_ app: CallingApp) -> Bool {
        app.isCustomAdded || Self.builtInIDs.contains(app.id)
    }

    func displayProfile(_ app: CallingApp) -> CallingApp {
        guard handles(app) else { return app }
        var profile = app
        profile.isEnabled = enabledIDs.contains(app.id)
        return profile
    }

    func displayStatus(for app: CallingApp, using settings: SettingsStore) -> AppInstallStatus {
        guard app.id == Self.meetID else { return settings.installStatus(for: app) }
        return ([Self.meetAppBundleID] + Self.browserBundleIDs).contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        } ? .webBased : .notInstalled
    }

    func connect(settings: SettingsStore, library: RingtoneLibraryManager, monitor: CallMonitorEngine) {
        guard self.settings == nil else { return }
        self.settings = settings
        self.library = library
        callMonitor = monitor
        // Retire the broad audio/window fallback for these profiles before starting their AX detector.
        for app in settings.callingApps where handles(app) && app.isEnabled {
            setEnabled(true, for: app)
        }
        monitor.$isMonitoring.sink { [weak self] running in
            self?.setMonitoring(running)
        }.store(in: &monitorEvents)
        monitor.$activeCall.map { $0 != nil }.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                if busy { self?.finishCall() }
            }.store(in: &monitorEvents)
    }

    func setEnabled(_ enabled: Bool, for app: CallingApp) {
        guard handles(app) else {
            settings?.toggleApp(app, enabled: enabled)
            return
        }
        if enabled {
            enabledIDs.insert(app.id)
        } else {
            enabledIDs.remove(app.id)
            if activeAppID == app.id { finishCall() }
        }
        defaults.set(enabledIDs.sorted(), forKey: Self.enabledKey)
        if settings?.callingApps.first(where: { $0.id == app.id })?.isEnabled == true {
            settings?.toggleApp(app, enabled: false)
        }
    }

    func stopRingtone() {
        finishCall()
    }

    private func setMonitoring(_ enabled: Bool) {
        guard enabled else {
            task?.cancel()
            task = nil
            handledAppID = nil
            finishCall()
            return
        }
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let candidates = self.settings?.callingApps.filter { self.enabledIDs.contains($0.id) } ?? []
                let result = await Task.detached(priority: .utility) {
                    autoreleasepool { Self.scan(candidates) }
                }.value
                guard !Task.isCancelled else { return }
                self.update(result)
                try? await Task.sleep(for: .milliseconds(self.activeAppID == nil ? 120 : 45))
            }
        }
    }

    private enum Snapshot {
        case incoming(CallingApp, [AudioProcessInfo])
        case idle
        case unavailable
    }

    private func update(_ snapshot: Snapshot) {
        guard callMonitor?.activeCall == nil else {
            finishCall()
            return
        }
        if case .unavailable = snapshot, let lastConfirmedAt,
           ProcessInfo.processInfo.systemUptime - lastConfirmedAt < 0.15 {
            return
        }
        guard case .incoming(var app, let processes) = snapshot, enabledIDs.contains(app.id),
              let settings, let library else {
            handledAppID = nil
            lastConfirmedAt = nil
            finishCall()
            return
        }
        lastConfirmedAt = ProcessInfo.processInfo.systemUptime
        if handledAppID != app.id {
            finishCall()
            handledAppID = app.id
            guard let tone = settings.ringtoneForIncomingCall(from: app, library: library) else { return }
            player.play(item: tone, fileURL: library.fileURL(for: tone), masterVolume: settings.masterVolume,
                        fadeInOverride: 0, loopOverride: true, outputDeviceID: settings.selectedOutputDeviceID)
            if player.isPlaying {
                activeAppID = app.id
                playedToneID = tone.id
                logger.notice("Custom ringtone started for \(app.id, privacy: .private)")
            }
        }
        guard player.isPlaying else { return }
        app.bundleIdentifiers = processes.map(\.bundleID).filter { !$0.isEmpty }
        app.audioProcessNames = processes.map(\.processName).filter { !$0.isEmpty }
        suppression.suppressRinging(targetApp: app, additionalApps: [], processes: processes)
    }

    private func finishCall() {
        guard activeAppID != nil else { return }
        player.stop(fadeOut: false)
        suppression.stopSuppressing()
        activeAppID = nil
        logger.notice("Custom ringtone stopped")
        if let toneID = playedToneID {
            playedToneID = nil
            settings?.advanceRingtonePlaylist(after: toneID)
        }
    }

    nonisolated static func audioBelongsToApp(_ process: AudioProcessInfo, pids: Set<pid_t>, bundleIDs: [String]) -> Bool {
        pids.contains(process.pid) || bundleIDs.contains { bundleID in
            process.bundleID == bundleID || process.bundleID.hasPrefix(bundleID + ".")
        }
    }

    nonisolated private static func scan(_ candidates: [CallingApp]) -> Snapshot {
        guard !candidates.isEmpty, AXIsProcessTrusted() else { return .idle }
        var incomplete = false
        for app in candidates {
            let bundleIDs = app.id == meetID ? [meetAppBundleID] : app.bundleIdentifiers
            let running = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            let hosts = app.id == meetID
                ? running + browserBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                : running
            for application in hosts {
                let requireMeetOrigin = app.id == meetID && application.bundleIdentifier != meetAppBundleID
                switch hasIncomingCall(pid: application.processIdentifier, requireMeetOrigin: requireMeetOrigin) {
                case true?:
                    let pids = Set(running.map(\.processIdentifier))
                    let bundlePaths = running.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
                    let processes = AudioSuppressionEngine.fetchActiveAudioProcesses().filter {
                        audioBelongsToApp($0, pids: pids, bundleIDs: bundleIDs)
                            || ($0.isRunningOutput && isEmbeddedHelper(pid: $0.pid, bundlePaths: bundlePaths))
                    }
                    return .incoming(app, processes)
                case false?: break
                case nil: incomplete = true
                }
            }
        }
        return incomplete ? .unavailable : .idle
    }

    nonisolated static func isGoogleMeetDocument(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "meet.google.com"
    }

    nonisolated private static func isEmbeddedHelper(pid: pid_t, bundlePaths: [String]) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let executablePath = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return bundlePaths.contains { executablePath.hasPrefix($0 + "/Contents/") }
    }

    nonisolated static func hasIncomingControls(buttons: [String], hasIncomingLabel: Bool) -> Bool {
        let names = buttons.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let answer = names.contains { ["answer", "answercall", "acceptcall", "acceptaudiocall",
            "acceptvideocall", "acceptwithaudio", "acceptwithvideo", "answerincomingcall"].contains($0) }
        let decline = names.contains { ["decline", "reject", "declinecall", "rejectcall", "declineincomingcall"].contains($0) }
        return decline && (answer || (hasIncomingLabel && names.contains("accept")))
    }

    nonisolated private static func hasIncomingCall(pid: pid_t, requireMeetOrigin: Bool) -> Bool? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.015)
        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
        if status == .cannotComplete { return nil }
        var incomplete = false
        // Budget each candidate window so a large chat window cannot starve a separate call pop-up.
        for window in (windows as? [AXUIElement] ?? []).prefix(5) {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.04
            var nodes = [(node: window, isCallApp: !requireMeetOrigin)]
            var buttons: [String] = []
            var incomingLabel = false
            var index = 0
            while index < nodes.count {
                guard index < 350, ProcessInfo.processInfo.systemUptime < deadline else {
                    incomplete = true
                    break
                }
                let (node, inheritedScope) = nodes[index]
                index += 1
                func read(_ name: String) -> CFTypeRef? {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(node, name as CFString, &value)
                    if status == .cannotComplete { incomplete = true }
                    return status == .success ? value : nil
                }
                let role = read(kAXRoleAttribute) as? String
                var identifiesCallApp = inheritedScope
                if requireMeetOrigin, role == kAXWindowRole || role == "AXWebArea" {
                    let urls = [kAXURLAttribute, kAXDocumentAttribute].compactMap { name -> URL? in
                        let value = read(name)
                        return (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
                    }
                    if !urls.isEmpty { identifiesCallApp = urls.contains(where: isGoogleMeetDocument) }
                }
                if identifiesCallApp && role == kAXButtonRole {
                    buttons += [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].compactMap { read($0) as? String }
                } else if identifiesCallApp && (role == kAXStaticTextRole || role == kAXWindowRole) {
                    // Read call wording in memory. Caller names and surrounding UI text never leave this scan.
                    incomingLabel = incomingLabel || [kAXTitleAttribute, kAXValueAttribute].contains { name in
                        guard let text = (read(name) as? String)?.lowercased() else { return false }
                        return ["incoming call", "incoming voice call", "incoming audio call", "incoming video call",
                                "is calling you", "is calling…"].contains { text.contains($0) }
                    }
                }
                if identifiesCallApp && hasIncomingControls(buttons: buttons, hasIncomingLabel: incomingLabel) { return true }
                if let children = read(kAXChildrenAttribute) as? [AXUIElement] {
                    nodes.append(contentsOf: children.prefix(max(0, 350 - nodes.count)).map { ($0, identifiesCallApp) })
                }
            }
        }
        return incomplete ? nil : false
    }
}
