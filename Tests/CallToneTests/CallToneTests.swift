import XCTest
import AVFoundation
import CoreGraphics
@testable import CallTone

final class CallToneTests: XCTestCase {
    func testWelcomeConsentAppliesOnlyToAcceptedBuild() throws {
        let suite = "CallToneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WelcomeConsent(version: "1.0.0+1", defaults: defaults)
        let update = WelcomeConsent(version: "1.0.0+2", defaults: defaults)

        XCTAssertFalse(first.isAccepted)
        first.accept()
        XCTAssertTrue(WelcomeConsent(version: "1.0.0+1", defaults: defaults).isAccepted)
        XCTAssertFalse(update.isAccepted)
        update.accept()
        XCTAssertTrue(update.isAccepted)
        XCTAssertFalse(first.isAccepted)
    }

    func testRingtoneItemEffectiveDurationAndFormatting() {
        let item = RingtoneItem(
            name: "Test Tone",
            fileName: "test.m4a",
            fileExtension: "M4A",
            duration: 120.0,
            trimStart: 15.0,
            trimEnd: 45.0
        )
        XCTAssertEqual(item.effectiveDuration, 30.0, accuracy: 0.01)
        XCTAssertEqual(item.formattedDuration, "0:30")
        XCTAssertEqual(RingtoneItem.formatTime(95), "1:35")
    }

    @MainActor
    func testLibraryRejectsPathsOutsideRingtoneDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ringtones = root.appendingPathComponent("Ringtones")
        try FileManager.default.createDirectory(at: ringtones, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.wav")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: ringtones.appendingPathComponent("link.wav"), withDestinationURL: outside
        )
        for fileName in ["../outside.wav", "link.wav"] {
            let item = RingtoneItem(name: "Sample", fileName: fileName, fileExtension: "WAV", duration: 1)
            let metadata = try JSONEncoder().encode([item])
            let metadataURL = root.appendingPathComponent("library.json")
            try metadata.write(to: metadataURL)
            let library = RingtoneLibraryManager(directory: root)
            XCTAssertTrue(library.ringtones.isEmpty)
            XCTAssertNotNil(library.lastError)
            library.saveLibrary()
            XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        }
    }

    @MainActor
    func testBuiltInRingtoneRenamePreservesIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ringtones = root.appendingPathComponent("Ringtones")
        try FileManager.default.createDirectory(at: ringtones, withIntermediateDirectories: true)
        let item = RingtoneItem(name: "CallTone Horizon (Built-in)", fileName: "calltone-horizon-default.wav",
                                fileExtension: "WAV", duration: 1)
        try Data().write(to: ringtones.appendingPathComponent(item.fileName))
        let metadataURL = root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item]).write(to: metadataURL)

        let library = RingtoneLibraryManager(directory: root)
        XCTAssertEqual(library.ringtones.first?.id, item.id)
        XCTAssertEqual(library.ringtones.first?.name, "CallTone Mac Horizon (Built-in)")
        let persisted = try JSONDecoder().decode([RingtoneItem].self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(persisted.first?.name, library.ringtones.first?.name)
    }

    @MainActor
    func testIncomingWindowClosureDoesNotWaitForAudioTeardown() {
        let monitor = CallMonitorEngine()
        // Audio-only detection must still work when window titles are unavailable.
        XCTAssertFalse(monitor.updateIncomingWindow(false))
        XCTAssertFalse(monitor.updateIncomingWindow(true))
        XCTAssertFalse(monitor.updateIncomingWindow(true))
        XCTAssertTrue(monitor.updateIncomingWindow(false))
        XCTAssertFalse(monitor.updateIncomingWindow(false))
        XCTAssertFalse(monitor.updateIncomingWindow(true))
        monitor.stopSimulatedOrActiveCall()
        XCTAssertFalse(monitor.updateIncomingWindow(false))
    }

    @MainActor
    func testLoopingRingtoneContinuesPastOriginalRingingGap() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.05)) * 0.01
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = RingtonePlayer()
        defer { player.stop(fadeOut: false) }
        for trimmed in [false, true] {
            var item = RingtoneItem(name: "Silence test", fileName: url.lastPathComponent,
                                    fileExtension: "WAV", duration: 1, trimStart: 0,
                                    trimEnd: trimmed ? 0.5 : 1)
            item.loopEnabled = true
            player.play(item: item, fileURL: url, masterVolume: 0.1, fadeInOverride: 0)
            XCTAssertTrue(player.isPlaying, player.lastPlaybackError ?? "Playback did not start")
            try await Task.sleep(nanoseconds: 3_200_000_000)
            XCTAssertTrue(player.isPlaying, "Looped tone must continue past a three-second source gap")
            XCTAssertEqual(player.activeRingtoneID, item.id)
            player.stop(fadeOut: false)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    private func withMonitor(_ body: (CallMonitorEngine, SettingsStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        settings.callingApps = Array(CallingApp.defaultCatalog.prefix(2))
        settings.globalRingtoneID = nil
        let library = RingtoneLibraryManager(directory: directory)
        let player = RingtonePlayer()
        let monitor = CallMonitorEngine()
        monitor.bind(settings: settings, library: library, suppression: nil, player: player)
        try withExtendedLifetime((library, player)) { try body(monitor, settings) }
    }

    private func appleAudio(output: Bool = true, input: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(id: 123456, pid: 123456,
                         bundleID: "com.apple.telephonyutilities.callservicesd",
                         processName: "callservicesd", isRunningOutput: output, isRunningInput: input)
    }

    @MainActor
    func testSharedAppleSignalStartsOnceAndWindowClosureStopsBeforeAudioTeardown() throws {
        try withMonitor { monitor, _ in
            let windows: [pid_t: [String]] = [123456: ["Incoming Call"]]
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: windows, capturedAt: 1)
            let eventID = monitor.activeCall?.id
            XCTAssertNotNil(eventID)
            for tick in 2...20 {
                monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: windows, capturedAt: Double(tick))
                XCTAssertEqual(monitor.activeCall?.id, eventID)
            }
            XCTAssertEqual(monitor.recentEvents.count, 1)
            // The original sound can pause without interrupting the custom tone.
            monitor.processSnapshot(audioProcesses: [appleAudio(output: false)], windowTitlesByPID: windows, capturedAt: 21)
            XCTAssertEqual(monitor.activeCall?.id, eventID)
            // An unavailable window snapshot is not evidence that the call closed.
            monitor.processSnapshot(audioProcesses: [appleAudio(output: false)], windowTitlesByPID: nil, capturedAt: 21.5)
            XCTAssertEqual(monitor.activeCall?.id, eventID)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 22)
            XCTAssertNil(monitor.activeCall)
            XCTAssertEqual(monitor.recentEvents.first?.state, .ended)
            // Neither an alias nor a late background snapshot may restart ringing.
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: windows, capturedAt: 10)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 23)
            XCTAssertNil(monitor.activeCall)
            // A new call immediately after teardown must not wait for a fixed cooldown.
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 24)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: windows, capturedAt: 25)
            XCTAssertNotNil(monitor.activeCall)
            XCTAssertNotEqual(monitor.activeCall?.id, eventID)
        }
    }

    @MainActor
    func testAnsweringStopsRingtoneAndLingeringOutputDoesNotRestartIt() throws {
        try withMonitor { monitor, _ in
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 1)
            XCTAssertNotNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [appleAudio(input: true)], windowTitlesByPID: [:], capturedAt: 2)
            XCTAssertNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 3)
            XCTAssertNil(monitor.activeCall)
            // A long answered call can still produce short audio gaps during hang-up.
            monitor.processSnapshot(audioProcesses: [appleAudio(input: true)], windowTitlesByPID: [:], capturedAt: 60)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 61)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 62)
            XCTAssertNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 63, appleIncoming: true)
            XCTAssertNotNil(monitor.activeCall)
        }
    }

    @MainActor
    func testAudioOnlyAppleCallBridgesShortGapsAndRearmsAfterSustainedSilence() throws {
        try withMonitor { monitor, _ in
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 1)
            let firstCall = try XCTUnwrap(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 2)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 2.35)
            XCTAssertEqual(monitor.activeCall?.id, firstCall.id)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 3)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 3.95)
            XCTAssertNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 4)
            XCTAssertNotEqual(try XCTUnwrap(monitor.activeCall).id, firstCall.id)
        }
        let faceTime = CallingApp.defaultCatalog.first { $0.id == "com.apple.FaceTime" }!
        XCTAssertFalse(CallMonitorEngine.checkIncomingWindow(pids: [123456], keywords: faceTime.incomingWindowKeywords,
                                                            windowMap: [123456: ["FaceTime"]]))
    }

    func testTrimmedNativeLoopRendersWithoutSilentBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        source.frameLength = 4096
        for frame in 0..<4096 { source.floatChannelData![0][frame] = 0.125 }
        try autoreleasepool { try AVAudioFile(forWriting: url, settings: format.settings).write(from: source) }
        let file = try AVAudioFile(forReading: url)
        let loop = try XCTUnwrap(RingtonePlayer.loopingBuffer(file: file, startFrame: 512, frameCount: 1024))
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        node.scheduleBuffer(loop, at: nil, options: .loops)
        try engine.start()
        defer { node.stop(); engine.stop() }
        node.play()
        let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        for _ in 0..<20 {
            XCTAssertEqual(try engine.renderOffline(512, to: rendered), .success)
            let samples = UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength))
            XCTAssertTrue(samples.allSatisfy { abs($0 - 0.125 / sqrt(2)) < 0.0001 }, "Unexpected silence or discontinuity at a loop boundary")
        }
        XCTAssertThrowsError(try RingtonePlayer.loopingBuffer(file: file, startFrame: -1, frameCount: 10))
        XCTAssertThrowsError(try RingtonePlayer.loopingBuffer(file: file, startFrame: 4090, frameCount: 10))
    }

    func testAppleIncomingControlsDistinguishAnsweringFromActiveAndUnknownUI() {
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Accept", "Decline"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["answerCallButton", "rejectCallButton"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["End Call", "Mute"]), false)
        XCTAssertNil(AppleCallUI.incomingState(buttonLabels: []))
        XCTAssertNil(AppleCallUI.incomingState(buttonLabels: ["Accept"]))
        XCTAssertNil(AppleCallUI.incomingState(buttonLabels: ["Other notification"]))
    }

    @MainActor
    func testAppleControlsStartBeforeAudioAndStopBeforeLingeringStream() throws {
        try withMonitor { monitor, _ in
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 1, appleIncoming: true)
            let eventID = monitor.activeCall?.id
            XCTAssertNotNil(eventID)
            XCTAssertEqual(monitor.activeCall?.signalSource, "Apple incoming-call controls")
            // AX query failure must not turn an ongoing incoming call into silence.
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 2, appleIncoming: nil)
            XCTAssertEqual(monitor.activeCall?.id, eventID)
            // Call controls disappearing override both stale titles and an active audio daemon.
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [123456: ["Incoming Call"]],
                                    capturedAt: 3, appleIncoming: false)
            XCTAssertNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 4, appleIncoming: false)
            XCTAssertNil(monitor.activeCall)
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: 5, appleIncoming: true)
            XCTAssertNotNil(monitor.activeCall)
        }
    }

    @MainActor
    func testKnownNonIncomingAppleUIDoesNotRingFromAudioAlone() throws {
        try withMonitor { monitor, _ in
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [123456: ["Incoming Call"]],
                                    capturedAt: 1, appleIncoming: false)
            XCTAssertNil(monitor.activeCall)
        }
    }

    @MainActor
    func testUntitledAppleWindowClosureStopsDespiteLingeringAudioWithoutAccessibility() throws {
        try withMonitor { monitor, _ in
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 1,
                                    appleCallWindowVisible: true)
            let eventID = monitor.activeCall?.id
            XCTAssertNotNil(eventID)
            // A natural audio gap and an unavailable window query must not interrupt ringing.
            monitor.processSnapshot(audioProcesses: [appleAudio(output: false)], windowTitlesByPID: [:], capturedAt: 2,
                                    appleCallWindowVisible: true)
            XCTAssertEqual(monitor.activeCall?.id, eventID)
            monitor.processSnapshot(audioProcesses: [appleAudio(output: false)], windowTitlesByPID: nil, capturedAt: 3)
            XCTAssertEqual(monitor.activeCall?.id, eventID)
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 4,
                                    appleCallWindowVisible: false)
            XCTAssertNil(monitor.activeCall)
            XCTAssertEqual(monitor.recentEvents.first?.signalSource, "Apple call window dismissed")
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 5,
                                    appleCallWindowVisible: false)
            XCTAssertNil(monitor.activeCall)
            // A fresh call window can open before the shared daemon stops producing audio.
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 5.1,
                                    appleCallWindowVisible: true)
            XCTAssertEqual(monitor.activeCall?.signalSource, "Apple Call Window + Audio")
            XCTAssertNotEqual(monitor.activeCall?.id, eventID)
        }
    }

    func testSuppressionTargetsNewAppleAudioProcessesWhileTheyAreStillQuiet() {
        let phone = CallingApp.defaultCatalog[0]
        let whatsapp = CallingApp.defaultCatalog.first { $0.name == "WhatsApp" }!
        let telephony = appleAudio(output: false)
        let systemSound = AudioProcessInfo(id: 42, pid: 42, bundleID: "", processName: "systemsoundserverd",
                                           isRunningOutput: false, isRunningInput: false)
        let media = AudioProcessInfo(id: 43, pid: 43, bundleID: "com.apple.Music", processName: "Music",
                                      isRunningOutput: true, isRunningInput: false)
        XCTAssertEqual(AudioSuppressionEngine.ringtoneProcesses(
            targetApp: phone, additionalApps: [], processes: [telephony, systemSound, media]
        ), [telephony, systemSound])
        XCTAssertEqual(AudioSuppressionEngine.ringtoneProcesses(
            targetApp: whatsapp, additionalApps: [phone], processes: [telephony, systemSound, media]
        ), [telephony])
    }

    func testAppleCallWindowDoesNotRequireAReadableTitleAndIgnoresInvisibleSurfaces() {
        var info: [String: Any] = [kCGWindowOwnerName as String: "MacInCallService",
                                  kCGWindowAlpha as String: 1.0,
                                  kCGWindowBounds as String: ["Width": 360.0, "Height": 100.0]]
        XCTAssertTrue(CallMonitorEngine.isAppleCallWindow(info))
        info[kCGWindowOwnerName as String] = "InCallService"
        XCTAssertTrue(CallMonitorEngine.isAppleCallWindow(info))
        info[kCGWindowAlpha as String] = 0.0
        XCTAssertFalse(CallMonitorEngine.isAppleCallWindow(info))
        info[kCGWindowAlpha as String] = 1.0
        info[kCGWindowBounds as String] = ["Width": 1.0, "Height": 1.0]
        XCTAssertFalse(CallMonitorEngine.isAppleCallWindow(info))
        info[kCGWindowOwnerName as String] = "Unrelated app"
        XCTAssertFalse(CallMonitorEngine.isAppleCallWindow(info))
    }

    @MainActor
    func testDisablingAllCallingAppsEndsActiveCall() throws {
        try withMonitor { monitor, settings in
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 1)
            XCTAssertNotNil(monitor.activeCall)
            settings.callingApps = []
            monitor.processSnapshot(audioProcesses: [appleAudio()], windowTitlesByPID: [:], capturedAt: 2)
            XCTAssertNil(monitor.activeCall)
            XCTAssertEqual(monitor.recentEvents.first?.signalSource, "Calling app disabled")
        }
    }

    func testDeletedCustomToneFallsBackToGlobalTone() {
        var app = CallingApp.defaultCatalog[0]
        app.customRingtoneID = UUID()
        let global = RingtoneItem(name: "Global", fileName: "global.wav", fileExtension: "WAV", duration: 1)
        XCTAssertEqual(CallMonitorEngine.resolvedRingtone(for: app, globalID: global.id, ringtones: [global]), global)
        XCTAssertNil(CallMonitorEngine.resolvedRingtone(for: app, globalID: nil, ringtones: [global]))
    }

    @MainActor
    func testRingtoneSelectionAcrossDetectedCallsInAllModes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        let library = RingtoneLibraryManager(directory: directory)
        let player = RingtonePlayer()
        let monitor = CallMonitorEngine()
        let selected = Array(library.ringtones.prefix(3))
        XCTAssertEqual(selected.count, 3)
        var trimmed = selected[1]
        trimmed.trimEnd = 0.5
        library.updateItem(trimmed)

        settings.globalRingtoneID = selected[2].id
        settings.masterVolume = 0
        settings.ringtoneRotation = RingtoneRotation(mode: .sequential, toneIDs: [selected[1].id, selected[0].id])
        settings.ringtoneRotation.move(selected[0].id, by: -1)
        XCTAssertEqual(SettingsStore(directory: directory).ringtoneRotation, settings.ringtoneRotation)

        monitor.bind(settings: settings, library: library, suppression: nil, player: player)
        defer { monitor.stopSimulatedOrActiveCall() }
        let app = CallingApp.defaultCatalog[0]
        var overridingApp = app
        overridingApp.customRingtoneID = selected[0].id
        var capturedAt: TimeInterval = 0

        func ring(_ app: CallingApp) -> UUID? {
            settings.callingApps = [app]
            capturedAt += 1
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: capturedAt, appleIncoming: true)
            let id = player.activeRingtoneID
            XCTAssertTrue(player.isPlaying, player.lastPlaybackError ?? "Playback did not start")
            capturedAt += 1
            monitor.processSnapshot(audioProcesses: [], windowTitlesByPID: [:], capturedAt: capturedAt, appleIncoming: false)
            XCTAssertFalse(player.isPlaying)
            return id
        }

        XCTAssertEqual(ring(overridingApp), selected[0].id)
        XCTAssertEqual(ring(app), selected[0].id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(ring(app), trimmed.id)
        XCTAssertEqual(ring(app), selected[0].id)

        let ids = selected.map(\.id)
        settings.ringtoneRotation = RingtoneRotation(mode: .shuffle, toneIDs: ids)
        let firstCycle = ids.compactMap { _ in ring(app) }
        let secondCycle = ids.compactMap { _ in ring(app) }
        XCTAssertEqual(Set(firstCycle), Set(ids))
        XCTAssertEqual(Set(secondCycle), Set(ids))
        XCTAssertNotEqual(firstCycle.last, secondCycle.first)

        settings.ringtoneRotation.mode = .single
        XCTAssertEqual(ring(app), selected[2].id)
        XCTAssertEqual(ring(app), selected[2].id)
        settings.ringtoneRotation.mode = .shuffle
        settings.ringtoneRotation.toneIDs = [trimmed.id]
        library.deleteItem(trimmed)
        XCTAssertEqual(ring(app), selected[2].id)
    }

    @MainActor
    func testLegacySettingsKeepSingleRingtoneByDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        let originalID = UUID()
        settings.globalRingtoneID = originalID
        let url = directory.appendingPathComponent("settings.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy.removeValue(forKey: "ringtoneRotation")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let restored = SettingsStore(directory: directory)
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.globalRingtoneID, originalID)
        XCTAssertEqual(restored.ringtoneRotation.mode, .single)
    }

    @MainActor
    func testUnreadableSettingsAndLibraryAreNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("invalid original data".utf8)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let libraryURL = directory.appendingPathComponent("library.json")
        try original.write(to: settingsURL)
        try original.write(to: libraryURL)
        let settings = SettingsStore(directory: directory)
        settings.masterVolume = 0.5
        XCTAssertNotNil(settings.lastError)
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        let library = RingtoneLibraryManager(directory: directory)
        library.saveLibrary()
        XCTAssertNotNil(library.lastError)
        XCTAssertTrue(library.ringtones.isEmpty)
        XCTAssertEqual(try Data(contentsOf: libraryURL), original)
    }

    @MainActor
    func testExportFailureKeepsDestinationAndSuccessfulExportIsM4A() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RingtoneLibraryManager(directory: directory)
        let destination = directory.appendingPathComponent("export.m4a")
        let previous = Data("keep this existing destination".utf8)
        try previous.write(to: destination)
        let missing = RingtoneItem(name: "Missing", fileName: "absent.wav", fileExtension: "WAV", duration: 1)
        let failure = await library.exportItem(missing, to: destination)
        XCTAssertFalse(failure)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let sample = try XCTUnwrap(library.ringtones.first)
        let success = await library.exportItem(sample, to: destination)
        XCTAssertTrue(success, library.lastError ?? "Export failed")
        let exported = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: exported[4..<8], encoding: .ascii), "ftyp")
        let source = library.fileURL(for: sample)
        let original = try Data(contentsOf: source)
        let sameFile = await library.exportItem(sample, to: source)
        XCTAssertFalse(sameFile)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let noSamples = await library.extractWaveformSamples(for: sample, sampleCount: 0)
        XCTAssertEqual(noSamples, [])
    }

    @MainActor
    func testInvalidAudioImportIsRejectedAndCopiedFileIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RingtoneLibraryManager(directory: directory)
        let before = library.ringtones
        let source = directory.appendingPathComponent("invalid.mp3")
        try Data("not an audio file".utf8).write(to: source)
        let result = await library.importFile(url: source)
        XCTAssertNil(result)
        XCTAssertEqual(library.ringtones, before)
        let files = try FileManager.default.contentsOfDirectory(atPath: library.storageDirectory.path)
        XCTAssertEqual(files.count, before.count)
        XCTAssertNotNil(library.lastError)
    }

    func testDefaultCatalogContainsRequiredApps() {
        let names = Set(CallingApp.defaultCatalog.map(\.name))
        XCTAssertTrue(names.contains("Apple Phone (iPhone Continuity)"))
        XCTAssertTrue(names.contains("FaceTime"))
        XCTAssertTrue(names.contains("WhatsApp"))
        XCTAssertTrue(names.contains("Telegram"))
        XCTAssertTrue(names.contains("Signal"))
        XCTAssertTrue(names.contains("Zoom"))
        XCTAssertTrue(names.contains("Microsoft Teams"))
        XCTAssertTrue(names.contains("Google Meet"))
        XCTAssertTrue(names.contains("Discord"))
    }

    func testAppleIncomingControlsMultiLanguageSupport() {
        // Spanish
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Aceptar", "Rechazar"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Finalizar llamada"]), false)

        // French
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Accepter", "Refuser"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Raccrocher"]), false)

        // German
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Annehmen", "Ablehnen"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["Auflegen"]), false)

        // Japanese
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["応答", "拒否"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["通話を終了"]), false)

        // Chinese
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["接听", "拒绝"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["挂断"]), false)

        // Hindi
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["उत्तर दें", "अस्वीकार"]), true)
        XCTAssertEqual(AppleCallUI.incomingState(buttonLabels: ["कॉल समाप्त करें"]), false)
    }

    @MainActor
    func testRingtoneDuplicationAndSuiteGeneration() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RingtoneLibraryManager(directory: directory)

        // Verifies the 5 offline synthesized tones are created on launch
        XCTAssertGreaterThanOrEqual(library.ringtones.count, 5)
        let horizon = library.ringtones.first { $0.name.contains("Horizon") }
        XCTAssertNotNil(horizon)

        // Verifies duplication produces a new independent item with (Copy)
        let copy = library.duplicateItem(horizon!)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.name.contains("(Copy)"))
        XCTAssertNotEqual(copy!.id, horizon!.id)
        XCTAssertNotEqual(copy!.fileName, horizon!.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: copy!).path))

        // Verifies restoreBuiltInSamples re-adds missing built-ins
        library.deleteItem(copy!)
        library.restoreBuiltInSamples()
        XCTAssertGreaterThanOrEqual(library.ringtones.count, 5)
    }

    @MainActor
    func testThirdPartyAudioFallbackSetting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        let library = RingtoneLibraryManager(directory: directory)
        let player = RingtonePlayer()
        let monitor = CallMonitorEngine()
        monitor.bind(settings: settings, library: library, suppression: nil, player: player)

        let whatsAppProc = AudioProcessInfo(id: 9999, pid: 9999, bundleID: "net.whatsapp.WhatsApp", processName: "WhatsApp", isRunningOutput: true, isRunningInput: false)

        // With fallback enabled (default), 3rd-party audio triggers ringing even with empty window titles
        settings.allowAudioFallbackForThirdParty = true
        monitor.processSnapshot(audioProcesses: [whatsAppProc], windowTitlesByPID: [:], capturedAt: 1)
        XCTAssertNotNil(monitor.activeCall)
        XCTAssertEqual(monitor.activeCall?.app.id, "net.whatsapp.WhatsApp")

        monitor.stopSimulatedOrActiveCall()
        XCTAssertNil(monitor.activeCall)

        // With fallback disabled, 3rd-party audio does not trigger without matching window titles
        settings.allowAudioFallbackForThirdParty = false
        monitor.processSnapshot(audioProcesses: [whatsAppProc], windowTitlesByPID: [:], capturedAt: 2)
        XCTAssertNil(monitor.activeCall)

        // Clearing recent events
        monitor.clearRecentEvents()
        XCTAssertTrue(monitor.recentEvents.isEmpty)
    }
}

extension CallToneTests {
    func testUpdatePopupOnlyForNewerStableRelease() throws {
        let data = Data(#"{"tag_name":"v1.10.0","draft":false,"prerelease":false}"#.utf8)
        let release = try JSONDecoder().decode(CallToneRelease.self, from: data)
        XCTAssertEqual(release.updateVersion(after: "1.9.0"), "1.10.0")
        XCTAssertNil(release.updateVersion(after: "1.10"))
        XCTAssertNil(release.updateVersion(after: "2.0.0"))
        XCTAssertNil(CallToneRelease(tag_name: "v2.0.0", draft: false, prerelease: true).updateVersion(after: "1.0"))
        XCTAssertNil(CallToneRelease(tag_name: "v2.0.0", draft: true, prerelease: false).updateVersion(after: "1.0"))
        XCTAssertNil(CallToneRelease(tag_name: "v2.0.0-beta", draft: false, prerelease: false).updateVersion(after: "1.0"))
    }
}
