import SwiftUI
import AppKit

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case library = "Ringtone Library"
    case apps = "Calling Applications"
    case audio = "Audio Settings"
    case general = "General Settings"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .library: return "music.note.list"
        case .apps: return "phone.connection"
        case .audio: return "speaker.wave.3"
        case .general: return "gearshape"
        }
    }
}

@MainActor
final class AppCore {
    static let shared = AppCore()

    let settingsStore = SettingsStore()
    let libraryManager = RingtoneLibraryManager()
    let deviceManager = AudioDeviceManager()
    let suppressionEngine = AudioSuppressionEngine()
    let ringtonePlayer = RingtonePlayer()
    let monitorEngine = CallMonitorEngine()
    let menuBarController = MenuBarController()

    private var didStart = false
    var openWindowAction: (() -> Void)?

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        NSApp?.appearance = settingsStore.appearanceMode.nsAppearance
        settingsStore.ensureDefaultRingtoneSelected(from: libraryManager)

        monitorEngine.bind(
            settings: settingsStore,
            library: libraryManager,
            suppression: suppressionEngine,
            player: ringtonePlayer
        )

        menuBarController.configure(
            settings: settingsStore,
            library: libraryManager,
            monitor: monitorEngine,
            player: ringtonePlayer,
            onOpenWindow: { [weak self] in
                self?.openWindowAction?()
            }
        )

        if settingsStore.autoStartMonitoring {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.monitorEngine.startMonitoring()
            }
        }
    }
}

@MainActor
final class CallToneAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: CallToneAppDelegate?
    private var mainWindow: NSWindow?
    private var allowExplicitQuit = false
    private let welcomeConsent = WelcomeConsent(bundle: .main, defaults: .standard)

    private var lastUpdateCheck: Date?
    private var checkingForUpdates = false
    private var showManualUpdateResult = false

    func applicationDidBecomeActive(_ notification: Notification) {
        checkForUpdates(manually: false)
    }

    func checkForUpdates(manually: Bool = true) {
        guard welcomeConsent.isAccepted, let window = mainWindow, window.isVisible else { return }
        if !manually {
            guard UserDefaults.standard.bool(forKey: "AutomaticallyCheckForUpdates"),
                  AppCore.shared.monitorEngine.activeCall == nil,
                  lastUpdateCheck.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true else { return }
        }
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "CallToneUpdateRepository") as? String,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest"),
              let releases = URL(string: "https://github.com/\(repository)/releases/latest") else {
            if manually { showUpdateStatus("Update source unavailable", detail: "CallTone Mac has no valid release source configured.", in: window) }
            return
        }
        if manually { showManualUpdateResult = true }
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        lastUpdateCheck = Date()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.checkingForUpdates = false
                self.showManualUpdateResult = false
            }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let result = try? await session.data(for: request)
            guard let window = self.mainWindow, window.isVisible, window.attachedSheet == nil else {
                self.lastUpdateCheck = nil
                return
            }
            let manual = self.showManualUpdateResult
            if !manual && (!UserDefaults.standard.bool(forKey: "AutomaticallyCheckForUpdates")
                           || !NSApp.isActive || AppCore.shared.monitorEngine.activeCall != nil) {
                self.lastUpdateCheck = nil
                return
            }
            let status = (result?.1 as? HTTPURLResponse)?.statusCode
            guard status == 200, let data = result?.0,
                  let release = try? JSONDecoder().decode(CallToneRelease.self, from: data) else {
                if manual {
                    let detail = status == 404
                        ? "No public release is available from the configured update source."
                        : "CallTone Mac couldn’t reach the release feed. Please try again."
                    self.showUpdateStatus("Update check unavailable", detail: detail, in: window)
                }
                return
            }
            guard let newerVersion = release.updateVersion(after: version) else {
                if manual { self.showUpdateStatus("No newer update found", detail: "You’re using CallTone Mac \(version).", in: window) }
                return
            }
            let key = "LastShownUpdateVersion"
            guard manual || UserDefaults.standard.string(forKey: key) != newerVersion else { return }
            let alert = NSAlert()
            alert.messageText = "CallTone Mac \(newerVersion) is available"
            alert.informativeText = "You’re using version \(version). Open the release page for details and downloads."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            UserDefaults.standard.set(newerVersion, forKey: key)
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(releases) }
            }
        }
    }

    private func showUpdateStatus(_ title: String, detail: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            allowExplicitQuit = true
            NSApp.terminate(nil)
            return
        }
        Self.shared = self
        ProcessInfo.processInfo.disableAutomaticTermination("CallTone Mac background monitoring")
        ProcessInfo.processInfo.disableSuddenTermination()
        let core = AppCore.shared
        core.openWindowAction = { [weak self] in
            self?.showMainWindow()
        }
        if welcomeConsent.isAccepted { core.startIfNeeded() }
        showMainWindow()
        applicationDidBecomeActive(notification)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showMainWindow() {
        if let existing = mainWindow {
            NSApp.setActivationPolicy(.regular)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 780, height: 520)
        if welcomeConsent.isAccepted {
            showDashboard(in: window)
        } else {
            let welcome = NSHostingController(rootView: WelcomeView(
                core: AppCore.shared,
                onContinue: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.welcomeConsent.accept()
                    AppCore.shared.startIfNeeded()
                    self.showDashboard(in: window)
                    self.checkForUpdates(manually: false)
                },
                onQuit: { [weak self] in self?.quitExplicitly() }
            ))
            welcome.sizingOptions = []
            window.contentViewController = welcome
        }
        window.title = "CallTone Mac"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDashboard(in window: NSWindow) {
        AppCore.shared.settingsStore.refreshInstalledAppCache()
        let frame = window.frame
        let dashboard = NSHostingController(rootView: RootContentView())
        dashboard.sizingOptions = []
        window.contentViewController = dashboard
        window.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard welcomeConsent.isAccepted else {
            DispatchQueue.main.async { self.quitExplicitly() }
            return false
        }
        sender.orderOut(nil)
        sender.contentViewController = nil
        mainWindow = nil
        AppCore.shared.settingsStore.clearIconCache()
        AppCore.shared.menuBarController.ensureVisible()
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    func quitExplicitly() {
        allowExplicitQuit = true
        AppCore.shared.monitorEngine.stopMonitoring()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return allowExplicitQuit || !welcomeConsent.isAccepted ? .terminateNow : .terminateCancel
    }
}

@MainActor
@main
struct CallToneAppMain {
    private static let sharedDelegate = CallToneAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = sharedDelegate
        app.run()
    }
}

struct RootContentView: View {
    final class UIState: ObservableObject {
        @Published var selectedSection: SidebarSection = .dashboard
    }
    @StateObject private var uiState = UIState()

    private let core = AppCore.shared

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $uiState.selectedSection) { section in
                HStack {
                    Label(section.rawValue, systemImage: section.sfSymbol)
                    Spacer()
                    sidebarBadge(for: section)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215)
        } detail: {
            Group {
                switch uiState.selectedSection {
                case .dashboard:
                    DashboardView()
                case .library:
                    RingtoneLibraryView()
                case .apps:
                    CallingAppsView()
                case .audio:
                    AudioSettingsView()
                case .general:
                    GeneralSettingsView()
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .background {
            Group {
                Button("") { uiState.selectedSection = .dashboard }.keyboardShortcut("1", modifiers: [.command])
                Button("") { uiState.selectedSection = .library }.keyboardShortcut("2", modifiers: [.command])
                Button("") { uiState.selectedSection = .apps }.keyboardShortcut("3", modifiers: [.command])
                Button("") { uiState.selectedSection = .audio }.keyboardShortcut("4", modifiers: [.command])
                Button("") { uiState.selectedSection = .general }.keyboardShortcut("5", modifiers: [.command])
                Button("") {
                    if core.monitorEngine.isMonitoring { core.monitorEngine.stopMonitoring() }
                    else { core.monitorEngine.startMonitoring() }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("") {
                    core.monitorEngine.stopSimulatedOrActiveCall()
                    core.ringtonePlayer.stop(fadeOut: false)
                }.keyboardShortcut(".", modifiers: [.command])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .environmentObject(core.settingsStore)
        .environmentObject(core.libraryManager)
        .environmentObject(core.deviceManager)
        .environmentObject(core.suppressionEngine)
        .environmentObject(core.ringtonePlayer)
        .environmentObject(core.monitorEngine)
    }

    @ViewBuilder
    private func sidebarBadge(for section: SidebarSection) -> some View {
        switch section {
        case .dashboard:
            if core.monitorEngine.activeCall != nil {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else if core.monitorEngine.isMonitoring {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        case .library:
            if !core.libraryManager.ringtones.isEmpty {
                Text("\(core.libraryManager.ringtones.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        case .apps:
            let enabledCount = core.settingsStore.callingApps.filter { $0.isEnabled }.count
            Text("\(enabledCount)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: Capsule())
        case .audio, .general:
            EmptyView()
        }
    }
}
