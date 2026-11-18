import SwiftUI

struct WaveformTrimmerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var library: RingtoneLibraryManager
    @EnvironmentObject var player: RingtonePlayer
    @EnvironmentObject var monitor: CallMonitorEngine
    @EnvironmentObject var settings: SettingsStore

    final class TrimmerUIState: ObservableObject {
        @Published var item: RingtoneItem
        @Published var waveform: [Float] = []
        @Published var isLoadingWaveform: Bool = true
        @Published var dragStartOffset: Double? = nil
        @Published var dragEndOffset: Double? = nil

        init(item: RingtoneItem) {
            self.item = item
        }
    }

    @StateObject private var uiState: TrimmerUIState

    init(item: RingtoneItem) {
        _uiState = StateObject(wrappedValue: TrimmerUIState(item: item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerBar

            waveformEditorCard

            trimPresetBar

            GroupBox("Trim & Playback Parameters") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text("Start Time")
                            .frame(width: 90, alignment: .leading)
                        Button {
                            uiState.item.trimStart = max(0, uiState.item.trimStart - 0.1)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)

                        Slider(value: $uiState.item.trimStart, in: 0...max(0.1, uiState.item.trimEnd - 0.5))

                        Button {
                            uiState.item.trimStart = min(max(0.1, uiState.item.trimEnd - 0.5), uiState.item.trimStart + 0.1)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)

                        Text(String(format: "%.2fs", uiState.item.trimStart))
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack(spacing: 12) {
                        Text("End Time")
                            .frame(width: 90, alignment: .leading)
                        Button {
                            uiState.item.trimEnd = max(uiState.item.trimStart + 0.5, uiState.item.trimEnd - 0.1)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)

                        Slider(value: $uiState.item.trimEnd, in: min(uiState.item.duration, uiState.item.trimStart + 0.5)...uiState.item.duration)

                        Button {
                            uiState.item.trimEnd = min(uiState.item.duration, uiState.item.trimEnd + 0.1)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)

                        Text(String(format: "%.2fs", uiState.item.trimEnd))
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack {
                        Text("Fade In")
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $uiState.item.fadeInDuration, in: 0...5.0, step: 0.1)
                        Text(String(format: "%.1fs", uiState.item.fadeInDuration))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    HStack {
                        Text("Fade Out")
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $uiState.item.fadeOutDuration, in: 0...5.0, step: 0.1)
                        Text(String(format: "%.1fs", uiState.item.fadeOutDuration))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    HStack {
                        Text("Clip Volume")
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $uiState.item.volume, in: 0.05...1.0, step: 0.05)
                        Text("\(Int(uiState.item.volume * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Loop Ringtone Until Answered or Declined", isOn: $uiState.item.loopEnabled)
                }
                .padding(8)
            }

            bottomActionBar
        }
        .padding(22)
        .frame(width: 650)
        .task {
            uiState.waveform = await library.extractWaveformSamples(for: uiState.item)
            uiState.isLoadingWaveform = false
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit & Trim Ringtone")
                    .font(.title2.weight(.semibold))
                Text(uiState.item.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Clip: \(RingtoneItem.formatTime(uiState.item.effectiveDuration))")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Text("Total: \(RingtoneItem.formatTime(uiState.item.duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimPresetBar: some View {
        HStack(spacing: 8) {
            Text("Presets:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("First 15s") {
                uiState.item.trimStart = 0
                uiState.item.trimEnd = min(15.0, uiState.item.duration)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("First 30s") {
                uiState.item.trimStart = 0
                uiState.item.trimEnd = min(30.0, uiState.item.duration)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Full Audio") {
                uiState.item.trimStart = 0
                uiState.item.trimEnd = uiState.item.duration
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text("Tip: Drag the handles directly on the waveform")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var waveformEditorCard: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let duration = max(0.1, uiState.item.duration)
            let startRatio = uiState.item.trimStart / duration
            let endRatio = uiState.item.trimEnd / duration
            let xStart = CGFloat(startRatio) * width
            let xEnd = CGFloat(endRatio) * width

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                if uiState.isLoadingWaveform {
                    ProgressView("Analyzing waveform...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Waveform bars
                    HStack(spacing: 2) {
                        ForEach(Array(uiState.waveform.enumerated()), id: \.offset) { index, amp in
                            let ratio = Double(index) / Double(max(1, uiState.waveform.count - 1))
                            let isSelected = ratio >= startRatio && ratio <= endRatio
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.28))
                                .frame(height: max(6, CGFloat(amp) * (height - 24)))
                        }
                    }
                    .padding(.horizontal, 10)
                }

                // Dimmed region before trim start
                if xStart > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.25))
                        .frame(width: max(0, xStart))
                }

                // Dimmed region after trim end
                if xEnd < width {
                    Rectangle()
                        .fill(Color.black.opacity(0.25))
                        .frame(width: max(0, width - xEnd))
                        .offset(x: xEnd)
                }

                // Selected range highlight
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: max(4, xEnd - xStart))
                    .offset(x: xStart)

                // Left Drag Handle
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 28)
                        .overlay {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .frame(width: 24, height: height)
                .contentShape(Rectangle())
                .offset(x: max(0, xStart - 12))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newX = max(0, min(xEnd - 10, xStart + value.translation.width))
                            let newStart = (Double(newX) / Double(width)) * duration
                            uiState.item.trimStart = max(0, min(uiState.item.trimEnd - 0.5, newStart))
                        }
                )

                // Right Drag Handle
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 28)
                        .overlay {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .frame(width: 24, height: height)
                .contentShape(Rectangle())
                .offset(x: min(width - 24, xEnd - 12))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newX = max(xStart + 10, min(width, xEnd + value.translation.width))
                            let newEnd = (Double(newX) / Double(width)) * duration
                            uiState.item.trimEnd = min(duration, max(uiState.item.trimStart + 0.5, newEnd))
                        }
                )

                // Real-time Playhead
                if player.isPlaying && player.activeRingtoneID == uiState.item.id {
                    let playheadRatio = duration > 0 ? player.currentPlaybackTime / duration : 0
                    let playheadX = CGFloat(playheadRatio) * width
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .shadow(color: .accentColor, radius: 4)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 36, height: 16)
                            .overlay {
                                Text(String(format: "%.1fs", player.currentPlaybackTime))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .offset(y: 2)
                    }
                    .frame(height: height)
                    .offset(x: max(0, min(width - 2, playheadX)))
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(height: 120)
    }

    private var bottomActionBar: some View {
        let isPlayingThis = player.isPlaying && player.activeRingtoneID == uiState.item.id

        return HStack(spacing: 12) {
            Button {
                if isPlayingThis {
                    player.stop()
                } else {
                    player.play(
                        item: uiState.item,
                        fileURL: library.fileURL(for: uiState.item),
                        masterVolume: settings.masterVolume,
                        outputDeviceID: settings.selectedOutputDeviceID
                    )
                }
            } label: {
                Label(
                    isPlayingThis ? "Stop Preview" : "Preview Trimmed Clip",
                    systemImage: isPlayingThis ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.bordered)
            .disabled(monitor.activeCall != nil)

            if isPlayingThis {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text(String(format: "Playing: %.1fs / %.1fs", player.currentPlaybackTime, uiState.item.effectiveDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Cancel") {
                if monitor.activeCall == nil { player.stop(fadeOut: false) }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save Changes") {
                if monitor.activeCall == nil { player.stop(fadeOut: false) }
                library.updateItem(uiState.item)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
