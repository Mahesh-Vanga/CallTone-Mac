import AppKit
import SwiftUI

struct StartInMenuBar: NSViewRepresentable {
    let needsSetup: Bool

    func makeNSView(context: Context) -> WindowAttachment {
        WindowAttachment(needsSetup: needsSetup)
    }

    func updateNSView(_ nsView: WindowAttachment, context: Context) {}

    final class WindowAttachment: NSView {
        private let needsSetup: Bool

        init(needsSetup: Bool) {
            self.needsSetup = needsSetup
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let newWindow {
                MenuBarStartup.shared.attach(to: newWindow, needsSetup: needsSetup)
            }
        }
    }
}

@MainActor
private final class MenuBarStartup: NSObject {
    static let shared = MenuBarStartup()
    private var hasStarted = false
    private var setupItem: NSStatusItem?

    func attach(to window: NSWindow, needsSetup: Bool) {
        window.isRestorable = false
        if !needsSetup, let setupItem {
            NSStatusBar.system.removeStatusItem(setupItem)
            self.setupItem = nil
        }
        guard !hasStarted else { return }
        hasStarted = true

        if needsSetup {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "CallTone Mac")
            item.button?.setAccessibilityLabel("CallTone Mac")
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open CallTone Mac", action: #selector(openWindow), keyEquivalent: "")
            open.target = self
            let quit = menu.addItem(withTitle: "Quit CallTone Mac", action: #selector(quit), keyEquivalent: "")
            quit.target = self
            item.menu = menu
            setupItem = item
        } else {
            AppCore.shared.menuBarController.ensureVisible()
        }

        // Keep the existing window opener available while withholding its first frame at launch.
        let previousApp = NSWorkspace.shared.frontmostApplication
        let opacity = window.alphaValue
        window.alphaValue = 0
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.orderOut(nil)
            window.alphaValue = opacity
            if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
                previousApp.activate()
            }
        }
    }

    @objc private func openWindow() {
        CallToneAppDelegate.shared?.showMainWindow()
    }

    @objc private func quit() {
        CallToneAppDelegate.shared?.quitExplicitly()
    }
}
