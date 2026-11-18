import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

struct GeneralSettingsView: View {
    @AppStorage("AutomaticallyCheckForUpdates") private var automaticallyCheckForUpdates = false
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: CallMonitorEngine
    @EnvironmentObject var suppression: AudioSuppressionEngine
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var notificationSettings: UNNotificationSettings?
    @State private var notificationMessage: String?
    @State private var requestingNotifications = false

    var body: some View {
        Form {
            if let error = settings.lastError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Updates") {
                Button("Check for Updates") { CallToneAppDelegate.shared?.checkForUpdates() }
                Toggle("Check for Updates Automatically", isOn: $automaticallyCheckForUpdates)
                Text("Update checks contact GitHub to fetch public release information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background Operation") {
                Toggle("Launch CallTone Mac at Login", isOn: Binding(get: { loginIsRegistered }, set: updateLogin))
                if loginStatus == .requiresApproval {
                    Text("Allow CallTone Mac in macOS Login Items to finish setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                Toggle("Start Incoming Call Monitoring Automatically", isOn: $settings.autoStartMonitoring)
                Toggle("Show Menu Bar Icon", isOn: $settings.showMenuBarIcon)
            }

            Section("Notifications") {
                Toggle("Show Local Notification When Custom Ringtone Starts", isOn: Binding(
                    get: { settings.showCallToneNotifications && notificationsAllowed },
                    set: updateNotifications
                ))
                .disabled(requestingNotifications || notificationSettings == nil)
                if notificationSettings?.authorizationStatus == .denied {
                    Text("Allow notifications for CallTone Mac in macOS Notifications settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if notificationsAllowed, notificationSettings?.alertStyle == UNAlertStyle.none {
                    Text("Banners are off. Choose Banners or Alerts in macOS Notifications settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notificationMessage {
                    Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Send Test Notification", action: sendTestNotification)
                        .disabled(!notificationsAllowed || !settings.showCallToneNotifications)
                    Button("Open Notifications Settings", action: CallToneNotifications.openSettings)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("macOS Permissions") {
                HStack {
                    Image(systemName: monitor.hasCallUIPermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(monitor.hasCallUIPermission ? .green : .orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Call UI Detection (Accessibility)")
                            .font(.subheadline.weight(.medium))
                        Text(monitor.hasCallUIPermission
                             ? "Accessibility enabled. CallTone Mac reads Apple's Answer/Decline buttons for low-latency call tracking."
                             : "Enable Accessibility so CallTone Mac can read Apple's call controls instantly. Audio-only detection can lag.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Accessibility Settings") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                HStack {
                    Image(systemName: suppression.permissionStatus == .tapStarted ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundStyle(suppression.permissionStatus == .tapStarted ? .green : .orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("System Audio Recording (Process Tap Muting)")
                            .font(.subheadline.weight(.medium))
                        Text("Status: \(suppression.permissionStatus.rawValue) — Required by macOS Core Audio Process Taps to mute the default ringtone. Call audio is never stored or recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings", action: SystemAudioRecordingSettings.open)
                }
                if let error = suppression.lastErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Privacy & Storage") {
                Link("Privacy Policy", destination: URL(string: "https://github.com/Mahesh-Vanga/CallTone-Mac/blob/main/PRIVACY.md")!)
                Text("Call detection, audio processing, and ringtone storage stay on your Mac. CallTone Mac does not share or send your personal or call data.")
                LabeledContent("Audio Capture Usage", value: "Real-time Core Audio Muting (Never Recorded)")
                HStack {
                    LabeledContent("Library Folder", value: "~/Library/Application Support/CallTone")
                    Spacer()
                    Button("Reveal") {
                        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        let dir = appSupport.appendingPathComponent("CallTone", isDirectory: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Section("About CallTone Mac") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                LabeledContent("Architecture", value: "Apple Silicon (arm64)")
                LabeledContent("License", value: "MIT Open Source")
                Text("CallTone Mac plays selected ringtones when incoming calls arrive and mutes the original calling app via Core Audio Process Taps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General Settings")
        .task { await refreshSystemSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSystemSettings() }
        }
    }

    private var loginIsRegistered: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    private func updateLogin(_ enabled: Bool) {
        loginStatus = SMAppService.mainApp.status
        loginError = nil
        guard enabled != loginIsRegistered else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Could not update the login item. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    private var notificationsAllowed: Bool {
        notificationSettings?.authorizationStatus == .authorized || notificationSettings?.authorizationStatus == .provisional
    }

    private func refreshSystemSettings() async {
        loginStatus = SMAppService.mainApp.status
        notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
    }

    private func updateNotifications(_ enabled: Bool) {
        notificationMessage = nil
        guard enabled else {
            settings.showCallToneNotifications = false
            return
        }
        requestingNotifications = true
        Task {
            defer { requestingNotifications = false }
            do {
                settings.showCallToneNotifications = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
            } catch {
                notificationMessage = "Could not request notifications. \(error.localizedDescription)"
            }
            await refreshSystemSettings()
        }
    }

    private func sendTestNotification() {
        Task {
            let request = CallToneNotifications.request(title: "CallTone Mac", body: "Local notifications are working.")
            do {
                try await UNUserNotificationCenter.current().add(request)
                notificationMessage = "Test notification sent."
            } catch {
                notificationMessage = "Could not send the test notification. \(error.localizedDescription)"
                await refreshSystemSettings()
            }
        }
    }
}
