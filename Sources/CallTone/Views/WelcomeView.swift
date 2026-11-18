import SwiftUI
import ApplicationServices
import UserNotifications

struct WelcomeConsent {
    private static let key = "AcceptedWelcomePolicy"
    private static let policyVersion = 1
    private let defaults: UserDefaults

    init(bundle _: Bundle, defaults: UserDefaults) {
        self.defaults = defaults
        if Self.policyVersion == 1, defaults.object(forKey: Self.key) == nil,
           let previousConsent = defaults.string(forKey: "AcceptedWelcomeVersion"),
           previousConsent.range(of: #"^(\d+(\.\d+)*|development)\+\d+(\.\d+)*$"#,
                                 options: .regularExpression) != nil {
            accept()
        }
    }

    var isAccepted: Bool { defaults.integer(forKey: Self.key) == Self.policyVersion }

    func accept() {
        defaults.set(Self.policyVersion, forKey: Self.key)
    }
}

struct WelcomeView: View {
    let core: AppCore
    let onContinue: () -> Void
    let onQuit: () -> Void

    @ObservedObject private var suppression: AudioSuppressionEngine
    @ObservedObject private var settings: SettingsStore
    @AppStorage("RequestedSystemAudioRecordingDuringSetup") private var requestedAudioPermission = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var notificationAuthorization: UNAuthorizationStatus?
    @State private var notificationError: String?
    @State private var requestingNotifications = false
    @State private var enablingNotificationsFromSettings = false
    @State private var checkingAudioPermission = false
    @State private var document: SetupDocument?

    private struct SetupDocument: Identifiable {
        let id: String
        let text: String
    }

    init(core: AppCore, onContinue: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.core = core
        self.onContinue = onContinue
        self.onQuit = onQuit
        self.suppression = core.suppressionEngine
        self.settings = core.settingsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        Text("Welcome to CallTone Mac").font(.largeTitle.bold())
                    }
                    Text("Choose your own ringtone for calls on your Mac. Use a single ringtone or play a shared playlist in order or on shuffle.")
                    Text("Open Calling Applications to enable an app or add one from Applications. CallTone Mac can mute the original ringtone when macOS can identify the app’s audio. Call detection, audio processing, and ringtone storage stay on your Mac.")
                    GroupBox("macOS permissions") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent {
                                Button(accessibilityGranted ? "Granted" : "Open Settings") {
                                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                    accessibilityGranted = AXIsProcessTrustedWithOptions(options)
                                    openSettings("Privacy_Accessibility")
                                }
                                .disabled(accessibilityGranted)
                            } label: {
                                permissionDescription("Accessibility", "Reads incoming-call controls to detect when ringing starts and stops. Required for the additional calling apps.")
                            }
                            Divider()
                            LabeledContent {
                                HStack {
                                    if !requestedAudioPermission {
                                        Button("Request", action: requestAudioPermission)
                                            .disabled(checkingAudioPermission)
                                    }
                                    Button("Open Settings", action: SystemAudioRecordingSettings.open)
                                }
                            } label: {
                                permissionDescription("System Audio Recording", requestedAudioPermission
                                    ? "Manage access in System Settings."
                                    : "Allows CallTone Mac to mute the original ringtone. CallTone Mac does not save audio from the tap.")
                            }
                            if let error = suppression.lastErrorMessage {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            LabeledContent {
                                Button(notificationButtonTitle, action: enableNotifications)
                                    .disabled(requestingNotifications || notificationAuthorization == nil || notificationsEnabled)
                            } label: {
                                permissionDescription("Notifications (optional)", notificationError ?? (
                                    notificationAuthorization == .denied
                                    ? "Allow notifications for CallTone Mac in System Settings."
                                    : "Shows a local alert when a custom ringtone starts."
                                ))
                            }
                        }
                        .padding(8)
                    }
                    Text("macOS lets you decline or revoke access. You can continue now and manage permissions later in General Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    GroupBox("Terms and privacy") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CallTone Mac is provided as is under the MIT License. CallTone Mac does not upload call or ringtone data. If you check for updates, the app contacts GitHub for public release information.")
                            HStack {
                                documentButton("MIT License", resource: "LICENSE", extension: nil)
                                documentButton("Privacy Policy", resource: "PRIVACY", extension: "md")
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Button("Quit", action: onQuit)
                Spacer()
                Button("Agree and Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .disabled(checkingAudioPermission || requestingNotifications)
            }
            .padding(16)
        }
        .sheet(item: $document) { document in
            VStack(alignment: .leading, spacing: 16) {
                Text(document.id).font(.title2.bold())
                ScrollView {
                    Text(document.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { self.document = nil }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .frame(width: 560, height: 420)
        }
        .background(StartInMenuBar(needsSetup: true))
        .onAppear { MenuBarActivation.keepAccessoryPolicy() }
        .task { await refreshNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            Task { await refreshNotificationAuthorization() }
        }
    }

    private var notificationsAllowed: Bool {
        notificationAuthorization == .authorized || notificationAuthorization == .provisional
    }

    private var notificationsEnabled: Bool {
        notificationsAllowed && settings.showCallToneNotifications
    }

    private var notificationButtonTitle: String {
        if notificationAuthorization == .denied { return "Open Settings" }
        return notificationsEnabled ? "Enabled" : "Enable"
    }

    private func refreshNotificationAuthorization() async {
        notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if enablingNotificationsFromSettings && notificationsAllowed {
            settings.showCallToneNotifications = true
            enablingNotificationsFromSettings = false
        }
    }

    private func enableNotifications() {
        notificationError = nil
        if notificationAuthorization == .denied {
            enablingNotificationsFromSettings = true
            CallToneNotifications.openSettings()
            return
        }
        if notificationsAllowed {
            settings.showCallToneNotifications = true
            return
        }
        requestingNotifications = true
        Task {
            defer { requestingNotifications = false }
            do {
                if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
                    settings.showCallToneNotifications = true
                }
            } catch {
                notificationError = "Could not enable notifications. \(error.localizedDescription)"
            }
            await refreshNotificationAuthorization()
        }
    }

    private func requestAudioPermission() {
        guard !requestedAudioPermission, !checkingAudioPermission else { return }
        requestedAudioPermission = true
        checkingAudioPermission = true
        Task { @MainActor in
            defer { checkingAudioPermission = false }
            if let tone = core.libraryManager.ringtones.first {
                core.ringtonePlayer.play(
                    item: tone,
                    fileURL: core.libraryManager.fileURL(for: tone),
                    masterVolume: 0,
                    fadeInOverride: 0,
                    loopOverride: true
                )
                // Give Core Audio time to register this app before the self-only tap.
                try? await Task.sleep(for: .milliseconds(250))
            }
            suppression.triggerAudioCapturePermissionProbe()
            core.ringtonePlayer.stop(fadeOut: false)
        }
    }

    private func permissionDescription(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func documentButton(_ title: String, resource: String, extension fileExtension: String?) -> some View {
        Button(title) {
            let url = Bundle.main.url(forResource: resource, withExtension: fileExtension)
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            document = SetupDocument(id: title, text: text ?? "This document is unavailable in this build.")
        }
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SystemAudioRecordingSettings {
    @MainActor
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
