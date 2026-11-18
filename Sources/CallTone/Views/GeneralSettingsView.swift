import SwiftUI
import AppKit
import ApplicationServices

struct GeneralSettingsView: View {
    @AppStorage("AutomaticallyCheckForUpdates") private var automaticallyCheckForUpdates = false
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: CallMonitorEngine
    @EnvironmentObject var suppression: AudioSuppressionEngine

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
                Toggle("Launch CallTone Mac at Login", isOn: $settings.launchAtLogin)
                Toggle("Start Incoming Call Monitoring Automatically", isOn: $settings.autoStartMonitoring)
                Toggle("Show Menu Bar Icon", isOn: $settings.showMenuBarIcon)
                Toggle("Show Local Notification When Custom Ringtone Starts", isOn: $settings.showCallToneNotifications)
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
                    Button("Request / Verify") {
                        suppression.triggerAudioCapturePermissionProbe()
                    }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
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
    }
}
