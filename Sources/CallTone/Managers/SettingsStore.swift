import Foundation
import Combine
import AppKit
import CoreAudio
import ServiceManagement

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var globalRingtoneID: UUID? { didSet { save() } }
    @Published var ringtoneRotation = RingtoneRotation() {
        didSet {
            if ringtoneRotation.mode != oldValue.mode || ringtoneRotation.toneIDs != oldValue.toneIDs {
                save()
            }
        }
    }
    @Published private var configuredCallingApps = CallingApp.defaultCatalog {
        didSet {
            playlistCallingApps = configuredCallingApps.map { app in
                var playlistApp = app
                playlistApp.customRingtoneID = nil
                return playlistApp
            }
            save()
        }
    }
    private var playlistCallingApps = CallingApp.defaultCatalog
    private var playlistConfiguration: RingtoneRotation?
    private var lastPlaylistToneID: UUID?
    private var playlistChanges: AnyCancellable?
    private var playlistPlayback: AnyCancellable?
    private var playlistCallEnd: AnyCancellable?
    private var playingPlaylistToneID: UUID?

    var callingApps: [CallingApp] {
        get { ringtoneRotation.isPlayingPlaylist ? playlistCallingApps : configuredCallingApps }
        set { configuredCallingApps = newValue }
    }

    func connectRingtonePlaylist(library: RingtoneLibraryManager, monitor: CallMonitorEngine, player: RingtonePlayer) {
        prepareRingtonePlaylist(from: library)
        playlistChanges = Publishers.CombineLatest(
            $ringtoneRotation.map { RingtoneRotation(mode: $0.mode, toneIDs: $0.toneIDs) }.removeDuplicates(),
            library.$ringtones.map { $0.map(\.id) }.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak library] _, _ in
            if let library { self?.prepareRingtonePlaylist(from: library) }
        }
        playlistPlayback = player.$activeRingtoneID.dropFirst().compactMap { $0 }
            .sink { [weak self, weak monitor] toneID in
                if let self, monitor?.activeCall != nil, self.ringtoneRotation.isPlayingPlaylist,
                   self.ringtoneRotation.playbackOrder?.first == toneID {
                    self.playingPlaylistToneID = toneID
                }
            }
        playlistCallEnd = monitor.$activeCall.dropFirst()
            .sink { [weak self] call in
                guard call == nil, let self, let toneID = self.playingPlaylistToneID else { return }
                self.playingPlaylistToneID = nil
                self.advanceRingtonePlaylist(after: toneID)
            }
    }

    private func prepareRingtonePlaylist(from library: RingtoneLibraryManager) {
        let configuration = RingtoneRotation(mode: ringtoneRotation.mode, toneIDs: ringtoneRotation.toneIDs)
            .available(in: library.ringtones)
        guard configuration != playlistConfiguration else { return }
        playlistConfiguration = configuration
        let order = configuration.cycle(after: lastPlaylistToneID)
        ringtoneRotation.playbackOrder = order.isEmpty ? nil : order
    }

    func advanceRingtonePlaylist(after toneID: UUID) {
        guard ringtoneRotation.isPlayingPlaylist, let configuration = playlistConfiguration,
              let order = ringtoneRotation.playbackOrder, order.first == toneID else { return }
        lastPlaylistToneID = toneID
        ringtoneRotation.playbackOrder = order.count == 1 ? configuration.cycle(after: toneID) : Array(order.dropFirst())
    }

    func ringtoneForIncomingCall(from app: CallingApp, library: RingtoneLibraryManager) -> RingtoneItem? {
        let playlistTone = ringtoneRotation.isPlayingPlaylist ? ringtoneRotation.playbackOrder?.first : nil
        return CallMonitorEngine.resolvedRingtone(for: app, globalID: playlistTone ?? globalRingtoneID, ringtones: library.ringtones)
    }

    // Audio Settings
    @Published var masterVolume: Float = 0.9 { didSet { save() } }
    @Published var globalFadeIn: TimeInterval = 0.25 { didSet { save() } }
    @Published var globalFadeOut: TimeInterval = 0.25 { didSet { save() } }
    @Published var globalLoopEnabled: Bool = true { didSet { save() } }
    @Published var useGlobalAudioOverrides: Bool = true { didSet { save() } }
    @Published var muteAllCallingAppsOnRing: Bool = true { didSet { save() } }
    @Published var allowAudioFallbackForThirdParty: Bool = true { didSet { save() } }
    @Published var selectedOutputDeviceUID: String? { didSet { save() } }

    // General Settings
    @Published var autoStartMonitoring: Bool = true { didSet { save() } }
    @Published var showMenuBarIcon: Bool = true { didSet { save() } }
    @Published var launchAtLogin: Bool = false {
        didSet {
            if !isLoading {
                updateLaunchAtLogin(enabled: launchAtLogin)
                save()
            }
        }
    }
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            if !isLoading {
                NSApp?.appearance = appearanceMode.nsAppearance
                save()
            }
        }
    }
    @Published var showCallToneNotifications: Bool = false { didSet { save() } }

    @Published private(set) var cachedInstallStatus: [String: AppInstallStatus] = [:]
    @Published private(set) var cachedAppIcons: [String: NSImage] = [:]

    private let settingsURL: URL
    private var isLoading = false
    private var canSave = true
    @Published private(set) var lastError: String?

    private struct PersistedSettings: Codable {
        var globalRingtoneID: UUID?
        var ringtoneRotation: RingtoneRotation?
        var callingApps: [CallingApp]
        var masterVolume: Float
        var globalFadeIn: TimeInterval
        var globalFadeOut: TimeInterval
        var globalLoopEnabled: Bool
        var useGlobalAudioOverrides: Bool
        var suppressOriginalRingtone: Bool?
        var muteAllCallingAppsOnRing: Bool?
        var allowAudioFallbackForThirdParty: Bool?
        var selectedOutputDeviceUID: String?
        var autoStartMonitoring: Bool
        var showMenuBarIcon: Bool
        var launchAtLogin: Bool
        var appearanceMode: AppearanceMode
        var showCallToneNotifications: Bool
    }

    init(directory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = directory ?? appSupport.appendingPathComponent("CallTone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.settingsURL = dir.appendingPathComponent("settings.json")
        load()
    }

    var selectedOutputDeviceID: AudioDeviceID? {
        guard let uid = selectedOutputDeviceUID else { return nil }
        // Resolve dynamically via AudioDeviceManager
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        return ids.first { AudioDeviceManager.getDeviceUID(for: $0) == uid }
    }

    func refreshInstalledAppCache() {
        let apps = callingApps
        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                var statusMap: [String: AppInstallStatus] = [:]
                var pathMap: [String: String] = [:]

                for app in apps {
                    if app.isContinuityPhone {
                        statusMap[app.id] = .systemBuiltIn
                    } else if app.id == "com.google.Meet" {
                        let found = app.bundleIdentifiers.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                        statusMap[app.id] = found != nil ? .webBased : .notInstalled
                    } else {
                        let found = app.bundleIdentifiers.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                        statusMap[app.id] = found != nil ? .installed : .notInstalled
                    }

                    for bid in app.bundleIdentifiers {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                            pathMap[app.id] = url.path
                            break
                        }
                    }
                }
                return (statusMap, pathMap)
            }.value

            guard let self else { return }
            self.cachedInstallStatus = resolved.0
            var iconMap: [String: NSImage] = [:]
            let targetSize = NSSize(width: 28, height: 28)
            for (appID, path) in resolved.1 {
                let rawIcon = NSWorkspace.shared.icon(forFile: path)
                let smallIcon = NSImage(size: targetSize, flipped: false) { rect in
                    rawIcon.draw(in: rect)
                    return true
                }
                iconMap[appID] = smallIcon
            }
            self.cachedAppIcons = iconMap
        }
    }

    func clearIconCache() {
        cachedAppIcons.removeAll()
    }

    func installStatus(for app: CallingApp) -> AppInstallStatus {
        cachedInstallStatus[app.id] ?? (app.isContinuityPhone ? .systemBuiltIn : .notInstalled)
    }

    func appIcon(for app: CallingApp) -> NSImage? {
        cachedAppIcons[app.id]
    }

    func addCustomApp(from appURL: URL) {
        guard let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier else { return }

        if callingApps.contains(where: { $0.bundleIdentifiers.contains(bundleID) }) {
            return
        }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let execName = (bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? name

        let customApp = CallingApp(
            id: bundleID,
            name: name,
            bundleIdentifiers: [bundleID],
            audioProcessNames: [execName, name],
            incomingWindowKeywords: ["Incoming", "Call", "Ringing", "Accept", "Answer"],
            sfSymbol: "phone.badge.plus",
            isEnabled: true,
            customRingtoneID: nil,
            isCustomAdded: true
        )
        configuredCallingApps.append(customApp)
    }

    func removeCustomApp(_ app: CallingApp) {
        guard app.isCustomAdded else { return }
        configuredCallingApps.removeAll { $0.id == app.id }
    }

    func toggleApp(_ app: CallingApp, enabled: Bool) {
        guard let idx = configuredCallingApps.firstIndex(where: { $0.id == app.id }) else { return }
        configuredCallingApps[idx].isEnabled = enabled
    }

    func setCustomRingtone(_ ringtoneID: UUID?, for app: CallingApp) {
        guard let idx = configuredCallingApps.firstIndex(where: { $0.id == app.id }) else { return }
        configuredCallingApps[idx].customRingtoneID = ringtoneID
    }

    func ensureDefaultRingtoneSelected(from library: RingtoneLibraryManager) {
        if globalRingtoneID == nil || !library.ringtones.contains(where: { $0.id == globalRingtoneID }) {
            globalRingtoneID = library.ringtones.first?.id
        }
        let available = ringtoneRotation.available(in: library.ringtones)
        if available != ringtoneRotation {
            ringtoneRotation = available
        }
    }

    func setSingleRingtone(_ id: UUID) {
        globalRingtoneID = id
        if ringtoneRotation.mode != .single {
            ringtoneRotation.mode = .single
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            lastError = "Login item could not be updated: \(error.localizedDescription)"
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let decoded: PersistedSettings
        do {
            decoded = try JSONDecoder().decode(PersistedSettings.self, from: Data(contentsOf: settingsURL))
        } catch {
            canSave = false
            lastError = "Settings could not be read. The original file has been preserved: \(error.localizedDescription)"
            return
        }

        self.globalRingtoneID = decoded.globalRingtoneID
        self.ringtoneRotation = decoded.ringtoneRotation ?? RingtoneRotation()
        // Merge default catalog with saved user preferences (isEnabled, customRingtoneID)
        // Always keep the latest bundleIdentifiers, audioProcessNames, and keywords from defaultCatalog
        var merged = CallingApp.defaultCatalog.map { defaultApp -> CallingApp in
            var updated = defaultApp
            if let saved = decoded.callingApps.first(where: { $0.id == defaultApp.id }) {
                updated.isEnabled = saved.isEnabled
                updated.customRingtoneID = saved.customRingtoneID
            }
            return updated
        }
        let customOnes = decoded.callingApps.filter { $0.isCustomAdded }
        merged.append(contentsOf: customOnes)
        self.callingApps = merged

        self.masterVolume = decoded.masterVolume
        self.globalFadeIn = decoded.globalFadeIn
        self.globalFadeOut = decoded.globalFadeOut
        self.globalLoopEnabled = decoded.globalLoopEnabled
        self.useGlobalAudioOverrides = decoded.useGlobalAudioOverrides
        self.muteAllCallingAppsOnRing = decoded.muteAllCallingAppsOnRing ?? true
        self.allowAudioFallbackForThirdParty = decoded.allowAudioFallbackForThirdParty ?? true
        self.selectedOutputDeviceUID = decoded.selectedOutputDeviceUID
        self.autoStartMonitoring = decoded.autoStartMonitoring
        self.showMenuBarIcon = decoded.showMenuBarIcon
        self.launchAtLogin = decoded.launchAtLogin
        self.appearanceMode = decoded.appearanceMode
        self.showCallToneNotifications = decoded.showCallToneNotifications
    }

    private func save() {
        guard !isLoading, canSave else { return }
        let payload = PersistedSettings(
            globalRingtoneID: globalRingtoneID,
            ringtoneRotation: ringtoneRotation,
            callingApps: configuredCallingApps,
            masterVolume: masterVolume,
            globalFadeIn: globalFadeIn,
            globalFadeOut: globalFadeOut,
            globalLoopEnabled: globalLoopEnabled,
            useGlobalAudioOverrides: useGlobalAudioOverrides,
            suppressOriginalRingtone: true,
            muteAllCallingAppsOnRing: muteAllCallingAppsOnRing,
            allowAudioFallbackForThirdParty: allowAudioFallbackForThirdParty,
            selectedOutputDeviceUID: selectedOutputDeviceUID,
            autoStartMonitoring: autoStartMonitoring,
            showMenuBarIcon: showMenuBarIcon,
            launchAtLogin: launchAtLogin,
            appearanceMode: appearanceMode,
            showCallToneNotifications: showCallToneNotifications
        )
        do {
            try JSONEncoder().encode(payload).write(to: settingsURL, options: [.atomic])
        } catch {
            lastError = "Settings could not be saved: \(error.localizedDescription)"
        }
    }
}
