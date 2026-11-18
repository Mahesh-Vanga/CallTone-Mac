import SwiftUI
import ApplicationServices

struct DashboardView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: RingtoneLibraryManager
    @EnvironmentObject var monitor: CallMonitorEngine
    @EnvironmentObject var suppression: AudioSuppressionEngine
    @EnvironmentObject var player: RingtonePlayer

    final class DashboardUIState: ObservableObject {
        @Published var selectedTestAppID: String = CallingApp.defaultCatalog.first?.id ?? "com.apple.ContinuityPhone"
    }
    @StateObject private var uiState = DashboardUIState()

    private var globalRingtone: RingtoneItem? {
        library.ringtones.first { $0.id == settings.globalRingtoneID }
    }

    private var rotation: RingtoneRotation {
        settings.ringtoneRotation.available(in: library.ringtones)
    }

    private var enabledApps: [CallingApp] {
        settings.callingApps.map { library.additionalCalls.displayProfile($0) }.filter(\.isEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !monitor.hasCallUIPermission || suppression.permissionStatus == .deniedOrSilent {
                    permissionAttentionBanner
                }

                headerBanner

                if let active = monitor.activeCall {
                    activeCallBanner(active)
                } else if let appID = library.additionalCalls.activeAppID,
                          let app = settings.callingApps.first(where: { $0.id == appID }) {
                    HStack {
                        Label("Incoming Call: \(app.name)", systemImage: "phone.arrow.down.left.fill")
                        Spacer()
                        Button("Stop Ringtone") { library.additionalCalls.stopRingtone() }
                    }
                    .padding(16)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }

                metricsBar

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    monitoringStatusCard
                    globalRingtoneCard
                }

                supportedAppsCard
                recentActivityCard
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .onAppear {
            library.additionalCalls.connect(settings: settings, library: library, monitor: monitor)
        }
    }

    private var permissionAttentionBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions Setup Recommended")
                    .font(.headline)
                Text("Grant Accessibility (for instant Apple call control detection) and System Audio Recording (for Core Audio Process Tap muting).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Privacy Settings") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var headerBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(monitor.isMonitoring ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: monitor.isMonitoring ? "waveform.badge.mic" : "bell.slash")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(monitor.isMonitoring ? Color.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(monitor.isMonitoring ? "CallTone Mac Monitoring Active" : "Monitoring Paused")
                        .font(.title2.weight(.semibold))
                    if monitor.isMonitoring && monitor.hasCallUIPermission {
                        Text("Live Protected")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(monitor.isMonitoring
                     ? "Listening locally for incoming calls across \(enabledApps.count) enabled apps."
                     : "Start monitoring to replace incoming call ringtones automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if monitor.isMonitoring {
                    monitor.stopMonitoring()
                } else {
                    monitor.startMonitoring()
                }
            } label: {
                Label(
                    monitor.isMonitoring ? "Stop Monitoring" : "Start Monitoring",
                    systemImage: monitor.isMonitoring ? "stop.fill" : "play.fill"
                )
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(monitor.isMonitoring ? .red : .accentColor)
            .controlSize(.large)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var metricsBar: some View {
        HStack(spacing: 12) {
            metricTile(title: "Calling Apps", value: "\(enabledApps.count)/\(settings.callingApps.count) Active", icon: "phone.connection", color: .blue)
            metricTile(title: "Ringtone Library", value: "\(library.ringtones.count) Tones", icon: "music.note.list", color: .purple)
            metricTile(title: "Tap Muting", value: "Automatic", icon: "speaker.slash.fill", color: .green)
            metricTile(title: "Output Route", value: settings.selectedOutputDeviceUID == nil ? "Default" : "Custom", icon: "speaker.wave.2.fill", color: .orange)
        }
    }

    private func metricTile(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private func activeCallBanner(_ call: DetectedCallEvent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Incoming Call: \(call.app.name)")
                        .font(.headline)
                    if call.isSimulated {
                        Text("Simulation")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text("Signal: \(call.signalSource) • Suppression: \(suppression.isSuppressing ? "Muting Original (Process Tap)" : "Inactive")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tone = library.ringtones.first(where: { $0.id == player.activeRingtoneID }) {
                    Text("Playing \(tone.name)")
                        .font(.caption)
                        .lineLimit(1)
                } else if let error = player.lastPlaybackError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            AnimatedEqualizer()
                .frame(width: 40, height: 20)
                .padding(.trailing, 8)

            Button("Stop Ringtone") {
                monitor.stopSimulatedOrActiveCall()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(16)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
        )
    }

    private var monitoringStatusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Engine & Suppression Status", systemImage: "cpu")
                    .font(.headline)

                statusRow(
                    title: "Ringtone Replacement",
                    value: "Core Audio Process Tap",
                    color: .green
                )
                statusRow(
                    title: "System Audio Permission",
                    value: suppression.permissionStatus.rawValue,
                    color: suppression.permissionStatus == .tapStarted ? .green : .orange
                )
                statusRow(
                    title: "Live Audio Outputs",
                    value: monitor.liveAudioOutputs.isEmpty ? "None" : monitor.liveAudioOutputs.joined(separator: ", "),
                    color: .secondary
                )

                statusRow(
                    title: "Call Timing",
                    value: monitor.hasCallUIPermission ? "UI access enabled (low-latency)" : "Audio fallback; timing can lag",
                    color: monitor.hasCallUIPermission ? .green : .orange
                )
                Divider()

                HStack {
                    Picker("Test App", selection: $uiState.selectedTestAppID) {
                        ForEach(settings.callingApps) { app in
                            Text(app.name).tag(app.id)
                        }
                    }
                    .labelsHidden()

                    Button("Simulate Call") {
                        if let app = settings.callingApps.first(where: { $0.id == uiState.selectedTestAppID }) {
                            monitor.simulateIncomingCall(for: app)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(6)
        }
    }

    private var globalRingtoneCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Global Ringtone", systemImage: "music.note")
                    .font(.headline)

                if rotation.mode != .single, !rotation.toneIDs.isEmpty {
                    Text(rotation.mode.rawValue)
                        .font(.title3.weight(.semibold))
                    Text("\(rotation.toneIDs.count) tones · Edit in Ringtone Library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let tone = globalRingtone {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tone.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            Text("\(tone.fileExtension) • \(tone.formattedDuration) • \(tone.loopEnabled ? "Loops" : "Single")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if player.isPlaying && player.activeRingtoneID == tone.id {
                                player.stop()
                            } else {
                                player.play(
                                    item: tone,
                                    fileURL: library.fileURL(for: tone),
                                    masterVolume: settings.masterVolume,
                                    outputDeviceID: settings.selectedOutputDeviceID
                                )
                            }
                        } label: {
                            Image(systemName: (player.isPlaying && player.activeRingtoneID == tone.id) ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                        .disabled(monitor.activeCall != nil)
                        .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text("No Global Ringtone Selected")
                        .foregroundStyle(.secondary)
                }

                if rotation.mode == .single {
                    Divider()

                    Picker("Active Global Tone", selection: Binding(
                        get: { settings.globalRingtoneID },
                        set: { settings.globalRingtoneID = $0 }
                    )) {
                        ForEach(library.ringtones) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(6)
        }
    }

    private var supportedAppsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Calling Applications", systemImage: "app.badge.checkmark")
                        .font(.headline)
                    Spacer()
                    Text("\(enabledApps.count) of \(settings.callingApps.count) enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 200), spacing: 10)
                ], spacing: 10) {
                    ForEach(settings.callingApps.map { library.additionalCalls.displayProfile($0) }) { app in
                        HStack(spacing: 10) {
                            if let nsImage = settings.appIcon(for: app) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: app.sfSymbol)
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(app.isEnabled ? Color.accentColor : .secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(settings.ringtoneRotation.isPlayingPlaylist ? "Playlist" : (app.customRingtoneID != nil ? "Custom Tone" : "Global Tone"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Circle()
                                .fill(app.isEnabled ? Color.green : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(6)
        }
    }

    private var recentActivityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Recent Call Detection Log", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    if !monitor.recentEvents.isEmpty {
                        Button("Clear Log") {
                            monitor.clearRecentEvents()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if monitor.recentEvents.isEmpty {
                    Text("No incoming calls detected in this session yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(monitor.recentEvents.prefix(6)) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.app.sfSymbol)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            Text(event.app.name)
                                .font(.subheadline.weight(.medium))

                            eventStateBadge(event.state)

                            Text("• \(event.signalSource)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(event.detectedAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func eventStateBadge(_ state: CallState) -> some View {
        let color: Color = (state == .ringing) ? .green : ((state == .connected) ? .blue : .secondary)
        return Text(state.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
        }
    }
}

// Bouncy audio equalizer animation for active calls
struct AnimatedEqualizer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<5) { index in
                    let heightRatio = (sin(Double(index) * 1.2 + timeline.date.timeIntervalSinceReferenceDate * 8) + 1.0) / 2.0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.green)
                        .frame(width: 3, height: max(4, CGFloat(heightRatio) * 18))
                }
            }
        }
    }
}
