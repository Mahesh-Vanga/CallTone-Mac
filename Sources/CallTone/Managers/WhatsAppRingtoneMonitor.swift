import AppKit
import ApplicationServices
import Combine
import OSLog

@MainActor
final class WhatsAppRingtoneMonitor {
    nonisolated static let bundleID = "net.whatsapp.WhatsApp"

    private weak var settings: SettingsStore?
    private weak var library: RingtoneLibraryManager?
    private weak var callMonitor: CallMonitorEngine?
    private let player = RingtonePlayer()
    private let suppression = AudioSuppressionEngine()
    private let logger = Logger(subsystem: "com.calltone.macos", category: "WhatsApp")
    private var task: Task<Void, Never>?
    private var playlistPreparation: AnyCancellable?
    private var playingPlaylistToneID: UUID?
    private var handledIncomingCall = false
    private var lastConfirmedIncoming: TimeInterval?
    var isRinging: Bool { player.isPlaying }

    private enum CallSnapshot {
        case incoming([AudioProcessInfo])
        case idle
        case unavailable
    }

    init(settings: SettingsStore, library: RingtoneLibraryManager, callMonitor: CallMonitorEngine) {
        self.settings = settings
        self.library = library
        self.callMonitor = callMonitor
        playlistPreparation = Publishers.CombineLatest3(
            settings.$ringtoneRotation,
            library.$ringtones,
            settings.$selectedOutputDeviceUID
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in self?.preparePlaylistTone() }
    }

    func setMonitoring(_ enabled: Bool) {
        guard enabled else {
            task?.cancel()
            task = nil
            update(.idle)
            return
        }
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabledApp != nil {
                    let call = await Task.detached(priority: .utility) { () -> CallSnapshot in
                        autoreleasepool {
                            guard let incoming = Self.hasIncomingCall() else { return .unavailable }
                            return incoming ? .incoming(AudioSuppressionEngine.fetchActiveAudioProcesses()) : .idle
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    self.update(call)
                } else {
                    self.update(.idle)
                }
                try? await Task.sleep(for: .milliseconds(self.isRinging ? 35 : 75))
            }
        }
        preparePlaylistTone()
    }

    func stopRingtone() {
        guard player.isPlaying || suppression.isSuppressing else { return }
        player.stop(fadeOut: false)
        suppression.stopSuppressing()
        logger.notice("WhatsApp custom ringtone stopped")
    }

    private var enabledApp: CallingApp? {
        settings?.callingApps.first { $0.id == Self.bundleID && $0.isEnabled }
    }

    private func preparePlaylistTone() {
        guard task != nil, !handledIncomingCall, let app = enabledApp, let settings, let library,
              settings.ringtoneRotation.isPlayingPlaylist,
              let tone = settings.ringtoneForIncomingCall(from: app, library: library) else { return }
        player.prepareNextCall(item: tone, fileURL: library.fileURL(for: tone),
                               outputDeviceID: settings.selectedOutputDeviceID)
    }

    private func update(_ call: CallSnapshot) {
        // shortcut: bridge an incomplete AX scan briefly until WhatsApp exposes definite state again.
        if case .unavailable = call, enabledApp != nil, callMonitor?.activeCall == nil,
           let lastConfirmedIncoming, ProcessInfo.processInfo.systemUptime - lastConfirmedIncoming < 0.15 {
            return
        }
        guard case .incoming(let incomingProcesses) = call, var app = enabledApp, let settings, let library else {
            lastConfirmedIncoming = nil
            handledIncomingCall = false
            stopRingtone()
            if let toneID = playingPlaylistToneID {
                playingPlaylistToneID = nil
                settings?.advanceRingtonePlaylist(after: toneID)
                preparePlaylistTone()
            }
            return
        }
        if callMonitor?.activeCall != nil {
            stopRingtone()
            handledIncomingCall = true
            return
        }
        lastConfirmedIncoming = ProcessInfo.processInfo.systemUptime
        if !handledIncomingCall {
            handledIncomingCall = true
            guard let tone = settings.ringtoneForIncomingCall(from: app, library: library) else { return }
            player.play(item: tone, fileURL: library.fileURL(for: tone), masterVolume: settings.masterVolume,
                        fadeInOverride: 0, loopOverride: true, outputDeviceID: settings.selectedOutputDeviceID,
                        forIncomingCall: true)
            if player.isPlaying {
                if settings.ringtoneRotation.isPlayingPlaylist { playingPlaylistToneID = tone.id }
                logger.notice("WhatsApp custom ringtone started")
            }
        }
        guard player.isPlaying else { return }
        // WhatsApp delegates its incoming ringtone to macOS on the desktop build.
        app.audioProcessNames.append("systemsoundserverd")
        suppression.suppressRinging(targetApp: app, additionalApps: [], processes: incomingProcesses)
    }

    nonisolated static func hasIncomingControls(_ identifiers: Set<String>) -> Bool {
        identifiers.contains("CallUI_AcceptButton") && identifiers.contains("CallUI_DeclineButton")
    }

    nonisolated private static func hasIncomingCall() -> Bool? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.015)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04

        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
        if status == .cannotComplete { return nil }
        var incomplete = false
        for window in windows as? [AXUIElement] ?? [] {
            var pending = [window]
            var identifiers: Set<String> = []
            while let element = pending.popLast() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                var identifierValue: CFTypeRef?
                let identifierStatus = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierValue)
                if identifierStatus == .cannotComplete { incomplete = true }
                if let identifier = identifierValue as? String {
                    identifiers.insert(identifier)
                    if hasIncomingControls(identifiers) { return true }
                }
                var childValue: CFTypeRef?
                let childStatus = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue)
                if childStatus == .cannotComplete { incomplete = true }
                if let children = childValue as? [AXUIElement] {
                    pending.append(contentsOf: children.reversed())
                }
            }
        }
        return incomplete ? nil : false
    }
}
