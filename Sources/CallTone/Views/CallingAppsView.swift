import SwiftUI
import AppKit

struct CallingAppsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: RingtoneLibraryManager
    @EnvironmentObject var monitor: CallMonitorEngine

    @State private var searchText: String = ""
    @State private var inspectingApp: CallingApp?
    @State private var appImportMessage: String?

    private var filteredApps: [CallingApp] {
        let profiles = settings.callingApps.map { library.additionalCalls.displayProfile($0) }
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return profiles
        }
        return profiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifiers.contains { $0.localizedCaseInsensitiveContains(searchText) } ||
            $0.audioProcessNames.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            List {
                Section("Incoming Call Ringtone") {
                    HStack {
                        Label("Global Ringtone", systemImage: "globe")
                            .font(.headline)
                        Spacer()
                        if settings.ringtoneRotation.isPlayingPlaylist {
                            Text("\(settings.ringtoneRotation.mode.rawValue) Playlist")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Global Ringtone", selection: $settings.globalRingtoneID) {
                                ForEach(library.ringtones) { tone in
                                    Text(tone.name).tag(Optional(tone.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Calling Applications (\(filteredApps.count))") {
                    ForEach(filteredApps) { app in
                        appRow(app)
                    }
                }
                if filteredApps.contains(where: { $0.id == AdditionalCallRingtoneMonitor.meetID }) {
                    Text("Google Meet works with an open Meet page. Native muting requires macOS to report a separate Meet audio process.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Calling Applications")
        .onAppear {
            library.additionalCalls.connect(settings: settings, library: library, monitor: monitor)
        }
        .alert("Add Calling Apps", isPresented: Binding(
            get: { appImportMessage != nil },
            set: { if !$0 { appImportMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appImportMessage = nil }
        } message: {
            Text(appImportMessage ?? "")
        }
        .sheet(item: $inspectingApp) { app in
            appDetailSheet(app)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps, bundles, processes...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
            .frame(maxWidth: 280)

            Spacer()

            Button {
                addCustomAppPanel()
            } label: {
                Label("Add Custom App", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func appRow(_ app: CallingApp) -> some View {
        let installStatus = library.additionalCalls.displayStatus(for: app, using: settings)
        let additionalCallIsRinging = library.additionalCalls.activeAppID == app.id
        let callState = additionalCallIsRinging ? .ringing : (monitor.appStates[app.id] ?? .idle)
        let isCurrentlyRinging = additionalCallIsRinging || monitor.activeCall?.app.id == app.id

        return HStack(spacing: 14) {
            if let icon = settings.appIcon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: app.sfSymbol)
                    .font(.title2)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(.headline)
                    statusBadge(installStatus: installStatus, callState: callState)
                }
                Text(app.bundleIdentifiers.first ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Per-app test simulation button
            Button {
                if additionalCallIsRinging {
                    library.additionalCalls.stopRingtone()
                } else if isCurrentlyRinging {
                    monitor.stopSimulatedOrActiveCall()
                } else {
                    monitor.simulateIncomingCall(for: app)
                }
            } label: {
                Label(isCurrentlyRinging ? "Stop" : "Test", systemImage: isCurrentlyRinging ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .tint(isCurrentlyRinging ? .orange : .accentColor)
            .controlSize(.small)
            .disabled(!app.isEnabled)

            Picker("Ringtone", selection: Binding(
                get: { app.customRingtoneID },
                set: { settings.setCustomRingtone($0, for: app) }
            )) {
                Text(settings.ringtoneRotation.isPlayingPlaylist ? "Use Ringtone Playlist" : "Use Global Ringtone").tag(UUID?.none)
                Divider()
                ForEach(library.ringtones) { tone in
                    Text(tone.name).tag(UUID?.some(tone.id))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .disabled(!app.isEnabled || settings.ringtoneRotation.isPlayingPlaylist)
            .help("App-specific tones apply in Single mode.")

            Toggle("", isOn: Binding(
                get: { app.isEnabled },
                set: { library.additionalCalls.setEnabled($0, for: app) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(app.name)")

            Button {
                inspectingApp = app
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("View app details and detection configuration")

            if app.isCustomAdded {
                Button(role: .destructive) {
                    library.additionalCalls.setEnabled(false, for: app)
                    settings.removeCustomApp(app)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(installStatus: AppInstallStatus, callState: CallState) -> some View {
        let text = callState == .idle ? installStatus.rawValue : callState.rawValue
        let color: Color = {
            if callState == .ringing { return .green }
            if callState == .connected { return .blue }
            switch installStatus {
            case .installed, .systemBuiltIn: return .green
            case .webBased: return .teal
            case .notInstalled: return .secondary
            }
        }()

        return HStack(spacing: 4) {
            if callState == .ringing {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }

    private func appDetailSheet(_ app: CallingApp) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let icon = settings.appIcon(for: app) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: app.sfSymbol)
                        .font(.title)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title2.weight(.semibold))
                    Text(app.isContinuityPhone ? "Apple System Built-in" : (app.isCustomAdded ? "Custom Added Application" : "Standard Catalog Profile"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(installStatus: library.additionalCalls.displayStatus(for: app, using: settings),
                            callState: library.additionalCalls.activeAppID == app.id ? .ringing : (monitor.appStates[app.id] ?? .idle))
            }

            Divider()

            GroupBox("Bundle Identifiers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.id == AdditionalCallRingtoneMonitor.meetID ? [AdditionalCallRingtoneMonitor.meetAppBundleID] : app.bundleIdentifiers, id: \.self) { bid in
                        Text("• \(bid)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Core Audio Monitored Process Names") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.audioProcessNames, id: \.self) { proc in
                        Text("• \(proc)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Incoming Call Window Keywords") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.incomingWindowKeywords, id: \.self) { kw in
                        Text("• \"\(kw)\"")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Done") {
                    inspectingApp = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func addCustomAppPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            var skipped: [String] = []
            for url in panel.urls {
                let knownIDs = Set(settings.callingApps.map(\.id))
                if Bundle(url: url)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    settings.addCustomApp(from: url)
                }
                if let added = settings.callingApps.first(where: { !knownIDs.contains($0.id) }) {
                    library.additionalCalls.setEnabled(true, for: added)
                } else {
                    skipped.append(url.deletingPathExtension().lastPathComponent)
                }
            }
            settings.refreshInstalledAppCache()
            if !skipped.isEmpty {
                appImportMessage = "Already listed or missing an application identity: \(skipped.joined(separator: ", "))."
            }
        }
    }
}
