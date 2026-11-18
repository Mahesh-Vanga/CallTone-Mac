import Foundation
import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    private weak var settings: SettingsStore?
    private weak var library: RingtoneLibraryManager?
    private weak var monitor: CallMonitorEngine?
    private weak var player: RingtonePlayer?
    private var whatsAppRingtone: WhatsAppRingtoneMonitor?
    private var onOpenWindow: (() -> Void)?

    func configure(
        settings: SettingsStore,
        library: RingtoneLibraryManager,
        monitor: CallMonitorEngine,
        player: RingtonePlayer,
        onOpenWindow: @escaping () -> Void
    ) {
        self.settings = settings
        self.library = library
        self.monitor = monitor
        self.player = player
        self.onOpenWindow = onOpenWindow
        settings.connectRingtonePlaylist(library: library, monitor: monitor, player: player)
        let whatsAppRingtone = WhatsAppRingtoneMonitor(settings: settings, library: library, callMonitor: monitor)
        self.whatsAppRingtone = whatsAppRingtone

        monitor.$isMonitoring
            .sink { [weak whatsAppRingtone] running in
                whatsAppRingtone?.setMonitoring(running)
            }
            .store(in: &cancellables)

        updateVisibility(show: settings.showMenuBarIcon)

        settings.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                self?.updateVisibility(show: show)
            }
            .store(in: &cancellables)

        monitor.$isMonitoring
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
            }
            .store(in: &cancellables)

        monitor.$activeCall
            .receive(on: RunLoop.main)
            .sink { [weak self] call in
                if call != nil { self?.whatsAppRingtone?.stopRingtone() }
                self?.updateIcon()
            }
            .store(in: &cancellables)
    }

    private func updateVisibility(show: Bool) {
        if show {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            updateIcon()
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    func ensureVisible() {
        updateVisibility(show: true)
    }

    private lazy var monitoringIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = true
        image.accessibilityDescription = "CallTone Mac"
        return image
    }()

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isRinging = monitor?.activeCall != nil
        let isMonitoring = monitor?.isMonitoring ?? false
        if isMonitoring && !isRinging, let monitoringIcon {
            button.image = monitoringIcon
            return
        }
        let symbolName = isRinging ? "phone.arrow.down.left.fill" : (isMonitoring ? "waveform.badge.mic" : "bell.slash")
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CallTone Mac")
        img?.isTemplate = !isRinging
        button.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let settings, let library, let monitor, let player else { return }

        let isMonitoring = monitor.isMonitoring
        let statusTitle = isMonitoring ? "● Monitoring Active" : "○ Monitoring Paused"
        let statusItemRow = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItemRow.isEnabled = false
        menu.addItem(statusItemRow)

        let toneName = library.ringtones.first(where: { $0.id == settings.globalRingtoneID })?.name ?? "None Selected"
        let rotation = settings.ringtoneRotation.available(in: library.ringtones)
        let isRotating = rotation.mode != .single && !rotation.toneIDs.isEmpty
        let toneTitle = isRotating ? "\(rotation.mode.rawValue) (\(rotation.toneIDs.count) tones)" : toneName
        let toneRow = NSMenuItem(title: "Global Tone: \(toneTitle)", action: nil, keyEquivalent: "")
        toneRow.isEnabled = false
        menu.addItem(toneRow)

        menu.addItem(.separator())

        if let active = monitor.activeCall {
            let stopCall = NSMenuItem(title: "Stop Ringtone (\(active.app.name))", action: #selector(stopActiveCall), keyEquivalent: "")
            stopCall.target = self
            menu.addItem(stopCall)
            menu.addItem(.separator())
        } else if whatsAppRingtone?.isRinging == true {
            let stopCall = NSMenuItem(title: "Stop WhatsApp Ringtone", action: #selector(stopWhatsAppRingtone), keyEquivalent: "")
            stopCall.target = self
            menu.addItem(stopCall)
            menu.addItem(.separator())
        } else if player.isPlaying {
            let stopPreview = NSMenuItem(title: "Stop Preview", action: #selector(stopPreviewAction), keyEquivalent: "")
            stopPreview.target = self
            menu.addItem(stopPreview)
            menu.addItem(.separator())
        }

        let toggleMon = NSMenuItem(
            title: isMonitoring ? "Pause Monitoring" : "Start Monitoring",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggleMon.target = self
        menu.addItem(toggleMon)

        let switchMenuItem = NSMenuItem(
            title: rotation.mode == .single ? "Switch Global Ringtone" : "Use a Single Ringtone",
            action: nil, keyEquivalent: ""
        )
        let submenu = NSMenu()
        for tone in library.ringtones {
            let entry = NSMenuItem(title: tone.name, action: #selector(selectRingtone(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tone.id
            entry.state = (rotation.mode == .single && tone.id == settings.globalRingtoneID) ? .on : .off
            submenu.addItem(entry)
        }
        switchMenuItem.submenu = submenu
        menu.addItem(switchMenuItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open CallTone Mac", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit CallTone Mac", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func stopActiveCall() {
        monitor?.stopSimulatedOrActiveCall()
    }

    @objc private func stopPreviewAction() {
        player?.stop()
    }

    @objc private func stopWhatsAppRingtone() {
        whatsAppRingtone?.stopRingtone()
    }

    @objc private func toggleMonitoring() {
        guard let monitor else { return }
        if monitor.isMonitoring {
            monitor.stopMonitoring()
        } else {
            monitor.startMonitoring()
        }
    }

    @objc private func selectRingtone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        settings?.setSingleRingtone(id)
    }

    @objc private func openMainWindow() {
        onOpenWindow?()
    }

    @objc private func quitApp() {
        if let delegate = CallToneAppDelegate.shared {
            delegate.quitExplicitly()
        } else {
            monitor?.stopMonitoring()
            NSApp.terminate(nil)
        }
    }
}
