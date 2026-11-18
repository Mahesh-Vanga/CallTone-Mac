import AppKit

@MainActor
enum MenuBarActivation {
    private static var observation: NSObjectProtocol?

    static func keepAccessoryPolicy() {
        if observation == nil {
            observation = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification, object: NSApp, queue: .main
            ) { _ in
                MainActor.assumeIsolated { restoreAccessoryPolicy() }
            }
        }
        restoreAccessoryPolicy()
    }

    private static func restoreAccessoryPolicy() {
        // The existing window opener promotes the app before bringing its window forward.
        guard NSApp.activationPolicy() == .regular else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        NSApp.setActivationPolicy(.accessory)
        guard let window, window.isVisible, window.alphaValue > 0 else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
