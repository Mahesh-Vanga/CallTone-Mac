import AppKit
import Combine
import UserNotifications

final class CallToneNotifications: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = CallToneNotifications()
    @MainActor private var additionalCallUpdates: AnyCancellable?

    @MainActor
    func connect(_ additionalCalls: AdditionalCallRingtoneMonitor, settings: SettingsStore) {
        UNUserNotificationCenter.current().delegate = self
        guard additionalCallUpdates == nil else { return }
        additionalCallUpdates = additionalCalls.$activeAppID.dropFirst().sink { [weak settings] appID in
            guard let settings, settings.showCallToneNotifications,
                  let app = settings.callingApps.first(where: { $0.id == appID }) else { return }
            let request = Self.request(title: "Custom Ringtone Active", body: "Playing your custom ringtone for \(app.name).")
            UNUserNotificationCenter.current().add(request)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    static func request(title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
