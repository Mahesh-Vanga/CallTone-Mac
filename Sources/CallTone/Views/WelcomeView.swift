import SwiftUI
import ApplicationServices
import UserNotifications

struct WelcomeConsent {
    private static let key = "AcceptedWelcomeVersion"
    let version: String
    let defaults: UserDefaults

    init(version: String, defaults: UserDefaults) {
        self.version = version
        self.defaults = defaults
    }

    init(bundle: Bundle, defaults: UserDefaults) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        self.init(version: "\(version)+\(build)", defaults: defaults)
    }

    var isAccepted: Bool { defaults.string(forKey: Self.key) == version }

    func accept() {
        defaults.set(version, forKey: Self.key)
    }
}

struct WelcomeView: View {
    let core: AppCore
    let onContinue: () -> Void
    let onQuit: () -> Void

    @ObservedObject private var suppression: AudioSuppressionEngine
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var notificationStatus = ""
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
                    Text("CallTone Mac detects incoming calls and plays the ringtone you choose. When enabled, it temporarily mutes the calling app’s original ringtone. Call detection, audio processing, and ringtone storage stay on your Mac.")
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
                                permissionDescription("Accessibility", "Reads Apple’s call controls to detect when a call starts or stops ringing. Other signals are used if access is unavailable.")
                            }
                            Divider()
                            LabeledContent {
                                HStack {
                                    Button("Request", action: requestAudioPermission)
                                        .disabled(checkingAudioPermission)
                                    Button("Open Settings") { openSettings("Privacy_AudioCapture") }
                                }
                            } label: {
                                permissionDescription("System Audio Recording", "Lets CallTone Mac mute the original ringtone. The audio from the tap is discarded. \(suppression.permissionStatus.rawValue).")
                            }
                            if let error = suppression.lastErrorMessage {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            LabeledContent {
                                Button("Enable") {
                                    Task {
                                        let allowed = (try? await UNUserNotificationCenter.current()
                                            .requestAuthorization(options: [.alert])) ?? false
                                        if allowed { core.settingsStore.showCallToneNotifications = true }
                                        notificationStatus = allowed
                                            ? "Enabled."
                                            : "Unavailable. You can manage access in System Settings → Notifications."
                                    }
                                }
                            } label: {
                                permissionDescription("Notifications (optional)", "Shows a local alert when a custom ringtone starts. \(notificationStatus)")
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
                    .disabled(checkingAudioPermission)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private func requestAudioPermission() {
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
