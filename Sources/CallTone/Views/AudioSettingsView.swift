import SwiftUI

struct AudioSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var deviceManager: AudioDeviceManager
    @EnvironmentObject var suppression: AudioSuppressionEngine
    @EnvironmentObject var library: RingtoneLibraryManager
    @EnvironmentObject var player: RingtonePlayer

    var body: some View {
        Form {
            Section("Ringtone Playback") {
                HStack {
                    Text("Master Volume")
                    Spacer()
                    Slider(value: $settings.masterVolume, in: 0.05...1.0, step: 0.05)
                        .frame(width: 220)
                    Text("\(Int(settings.masterVolume * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Apply Global Fade & Loop Settings to All Ringtones", isOn: $settings.useGlobalAudioOverrides)

                if settings.useGlobalAudioOverrides {
                    HStack {
                        Text("Fade-In Duration")
                        Spacer()
                        Slider(value: $settings.globalFadeIn, in: 0...5.0, step: 0.1)
                            .frame(width: 220)
                        Text(String(format: "%.1fs", settings.globalFadeIn))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    HStack {
                        Text("Fade-Out Duration")
                        Spacer()
                        Slider(value: $settings.globalFadeOut, in: 0...3.0, step: 0.1)
                            .frame(width: 220)
                        Text(String(format: "%.1fs", settings.globalFadeOut))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Loop Ringtone Until Answered, Declined, or Ended", isOn: $settings.globalLoopEnabled)
                }
            }

            Section("Output Device Routing") {
                Picker("Play Ringtones Through", selection: $settings.selectedOutputDeviceUID) {
                    Text("System Default Output").tag(String?.none)
                    Divider()
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.isDefaultOutput ? "\(device.name) (Default)" : device.name)
                            .tag(String?.some(device.uid))
                    }
                }

                HStack {
                    Button {
                        testAudioOutput()
                    } label: {
                        Label(player.isPlaying ? "Stop Test Chime" : "Test Audio Output", systemImage: player.isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Refresh Audio Devices") {
                        deviceManager.refreshDevices()
                    }
                }
            }

            Section("Call Detection Heuristics") {
                Toggle("Allow Audio Stream Fallback for 3rd-Party Calling Apps", isOn: $settings.allowAudioFallbackForThirdParty)

                Text("When window inspection is unavailable (e.g. without Screen Recording permission), detects calls in WhatsApp, Telegram, Zoom, Teams, and Signal based on process audio stream activity when microphone is inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Original Ringtone Suppression (Core Audio Process Tap)") {
                Text("CallTone automatically mutes the original ringtone for monitored calls.")
                Toggle("Mute All Enabled Calling Apps During Ring", isOn: $settings.muteAllCallingAppsOnRing)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Suppression Status:")
                                .font(.subheadline.weight(.medium))
                            Text(suppression.isSuppressing ? "Active (Currently Muting)" : suppression.permissionStatus.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(suppression.isSuppressing ? .green : .secondary)
                        }
                        Text("Uses macOS 14.2+ Core Audio Process Taps (no kernel extension or virtual audio driver). Process taps are torn down the instant a call is answered so normal call voice audio flows untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open System Audio Recording Settings", action: SystemAudioRecordingSettings.open)
                }

                if let error = suppression.lastErrorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio Settings")
    }

    private func testAudioOutput() {
        if player.isPlaying {
            player.stop()
            return
        }

        let tone = library.ringtones.first { $0.id == settings.globalRingtoneID } ?? library.ringtones.first
        guard let item = tone else { return }

        player.play(
            item: item,
            fileURL: library.fileURL(for: item),
            masterVolume: settings.masterVolume,
            fadeInOverride: 0,
            fadeOutOverride: 0.2,
            loopOverride: false,
            outputDeviceID: settings.selectedOutputDeviceID
        )
    }
}
