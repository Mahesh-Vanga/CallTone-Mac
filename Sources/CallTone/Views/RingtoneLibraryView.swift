import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RingtoneLibraryView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: RingtoneLibraryManager
    @EnvironmentObject var player: RingtonePlayer
    @EnvironmentObject var monitor: CallMonitorEngine

    final class LibraryUIState: ObservableObject {
        @Published var searchText: String = ""
        @Published var editingItem: RingtoneItem?
        @Published var renamingItem: RingtoneItem?
        @Published var renameDraft: String = ""
        @Published var isDropTargeted: Bool = false
    }
    @StateObject private var uiState = LibraryUIState()

    private var filteredRingtones: [RingtoneItem] {
        if uiState.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return library.ringtones
        }
        return library.ringtones.filter { $0.name.localizedCaseInsensitiveContains(uiState.searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarHeader
            if let error = library.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
            }
            Divider()

            if filteredRingtones.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(filteredRingtones) { item in
                        ringtoneRow(item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Ringtone Library")
        .onDrop(of: [.fileURL], isTargeted: $uiState.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if uiState.isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(12)
                    .overlay {
                        Label("Drop Audio Files to Import", systemImage: "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
            }
        }
        .sheet(item: $uiState.editingItem) { item in
            WaveformTrimmerView(item: item)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(monitor)
        }
        .alert("Rename Ringtone", isPresented: Binding(
            get: { uiState.renamingItem != nil },
            set: { if !$0 { uiState.renamingItem = nil } }
        )) {
            TextField("Ringtone Name", text: $uiState.renameDraft)
            Button("Save") {
                if let item = uiState.renamingItem {
                    library.renameItem(item, newName: uiState.renameDraft)
                }
                uiState.renamingItem = nil
            }
            Button("Cancel", role: .cancel) {
                uiState.renamingItem = nil
            }
        }
    }

    private var toolbarHeader: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search ringtones...", text: $uiState.searchText)
                    .textFieldStyle(.plain)
                if !uiState.searchText.isEmpty {
                    Button {
                        uiState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 260)

            Spacer()

            Text("\(library.ringtones.count) tones")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                library.restoreBuiltInSamples()
                settings.ensureDefaultRingtoneSelected(from: library)
            } label: {
                Label("Built-in Tones", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .help("Restore built-in sound samples if any were deleted")

            Button {
                importViaPanel()
            } label: {
                Label("Import Audio", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("i", modifiers: [.command])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor.opacity(0.7))
            Text("No Ringtones Found")
                .font(.title3.weight(.semibold))
            Text("Import MP3, WAV, M4A, M4R, CAF, AAC, or FLAC files, or restore the built-in sound suite.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button("Import Audio File") {
                    importViaPanel()
                }
                .buttonStyle(.borderedProminent)

                Button("Load Built-in Tones") {
                    library.restoreBuiltInSamples()
                    settings.ensureDefaultRingtoneSelected(from: library)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ringtoneRow(_ item: RingtoneItem) -> some View {
        let isGlobal = settings.globalRingtoneID == item.id
        let isPlayingThis = player.isPlaying && player.activeRingtoneID == item.id

        return HStack(spacing: 14) {
            Button {
                if isPlayingThis {
                    player.stop()
                } else {
                    player.play(
                        item: item,
                        fileURL: library.fileURL(for: item),
                        masterVolume: settings.masterVolume,
                        outputDeviceID: settings.selectedOutputDeviceID
                    )
                }
            } label: {
                Image(systemName: isPlayingThis ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(monitor.activeCall != nil)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                    if isGlobal {
                        Text("Global Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text("\(item.fileExtension) • \(item.formattedDuration) (Full: \(RingtoneItem.formatTime(item.duration))) • Fade \(String(format: "%.1fs", item.fadeInDuration)) • \(item.loopEnabled ? "Loops" : "Single")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isPlayingThis {
                    let duration = max(0.1, item.effectiveDuration)
                    let elapsed = max(0, player.currentPlaybackTime - item.trimStart)
                    let progress = min(1.0, elapsed / duration)
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 160)
                        Text(String(format: "%.1fs / %.1fs", elapsed, duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }

            Spacer()

            if !isGlobal {
                Button("Set Global") {
                    settings.globalRingtoneID = item.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                uiState.editingItem = item
            } label: {
                Label("Trim & Edit", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("Set as Global Ringtone") {
                    settings.globalRingtoneID = item.id
                }

                Menu("Assign to Calling App") {
                    ForEach(settings.callingApps) { app in
                        Button {
                            settings.setCustomRingtone(item.id, for: app)
                        } label: {
                            HStack {
                                Text(app.name)
                                if app.customRingtoneID == item.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Button("Duplicate") {
                    _ = library.duplicateItem(item)
                }

                Button("Rename") {
                    uiState.renameDraft = item.name
                    uiState.renamingItem = item
                }

                Button("Export Clip...") {
                    exportViaPanel(item: item)
                }

                Button("Reveal in Finder") {
                    let url = library.fileURL(for: item)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Divider()

                Button("Delete", role: .destructive) {
                    if isPlayingThis { player.stop(fadeOut: false) }
                    library.deleteItem(item)
                    settings.ensureDefaultRingtoneSelected(from: library)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .disabled(monitor.activeCall != nil)
            .frame(width: 28)
        }
        .padding(.vertical, 6)
    }

    private func importViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = RingtoneLibraryManager.supportedTypes
        if panel.runModal() == .OK {
            Task {
                let imported = await library.importFiles(urls: panel.urls)
                if settings.globalRingtoneID == nil, let first = imported.first {
                    settings.globalRingtoneID = first.id
                }
            }
        }
    }

    private func exportViaPanel(item: RingtoneItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.name).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                _ = await library.exportItem(item, to: url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            let imported = await library.importFiles(urls: urls)
            if settings.globalRingtoneID == nil, let first = imported.first { settings.globalRingtoneID = first.id }
        }
        return true
    }
}
