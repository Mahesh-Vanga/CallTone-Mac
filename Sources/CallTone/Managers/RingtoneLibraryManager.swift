import Foundation
import AVFoundation
import UniformTypeIdentifiers
import AppKit

@MainActor
final class RingtoneLibraryManager: ObservableObject {
    @Published private(set) var ringtones: [RingtoneItem] = []
    @Published var lastError: String?

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.mp3, .wav, .mpeg4Audio, .aiff, .audio]
        if let m4r = UTType(filenameExtension: "m4r") { types.append(m4r) }
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let aac = UTType(filenameExtension: "aac") { types.append(aac) }
        return types
    }()

    let storageDirectory: URL
    private let metadataURL: URL
    private var canSave = true

    init(directory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = directory ?? appSupport.appendingPathComponent("CallTone", isDirectory: true)
        self.storageDirectory = root.appendingPathComponent("Ringtones", isDirectory: true)
        self.metadataURL = root.appendingPathComponent("library.json")

        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadLibrary()
        if ringtones.isEmpty && canSave {
            createBuiltInSampleToneIfNeeded()
        }
    }

    func fileURL(for item: RingtoneItem) -> URL {
        storageDirectory.appendingPathComponent(item.fileName)
    }

    func loadLibrary() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            ringtones = []
            return
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode([RingtoneItem].self, from: data)
            let libraryDirectory = storageDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            for item in decoded {
                let name = item.fileName
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
                      fileURL(for: item).resolvingSymlinksInPath().standardizedFileURL
                        .deletingLastPathComponent().path == libraryDirectory else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            ringtones = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            if let index = ringtones.firstIndex(where: {
                $0.fileName == "calltone-horizon-default.wav" && $0.name == "CallTone Horizon (Built-in)"
            }) {
                ringtones[index].name = "CallTone Mac Horizon (Built-in)"
                saveLibrary()
            }
        } catch {
            lastError = "Failed to load ringtone library: \(error.localizedDescription)"
            canSave = false
            ringtones = []
        }
    }

    func saveLibrary() {
        guard canSave else { return }
        do {
            let data = try JSONEncoder().encode(ringtones)
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            lastError = "Failed to save library: \(error.localizedDescription)"
        }
    }

    // MARK: - Import & Export

    func importFiles(urls: [URL]) async -> [RingtoneItem] {
        var imported: [RingtoneItem] = []
        for url in urls {
            if let item = await importFile(url: url) {
                imported.append(item)
            }
        }
        return imported
    }

    func importFile(url: URL) async -> RingtoneItem? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        let uniqueFileName = "\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)"
        let destination = storageDirectory.appendingPathComponent(uniqueFileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)

            let asset = AVURLAsset(url: destination)
            let durationTime = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(durationTime)
            guard seconds.isFinite, seconds > 0,
                  !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let validDuration = seconds

            let item = RingtoneItem(
                name: baseName,
                fileName: uniqueFileName,
                fileExtension: ext.uppercased(),
                duration: validDuration
            )
            ringtones.insert(item, at: 0)
            saveLibrary()
            return item
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func updateItem(_ updated: RingtoneItem) {
        guard let idx = ringtones.firstIndex(where: { $0.id == updated.id }) else { return }
        ringtones[idx] = updated
        saveLibrary()
    }

    func renameItem(_ item: RingtoneItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = ringtones.firstIndex(where: { $0.id == item.id }) else { return }
        ringtones[idx].name = trimmed
        saveLibrary()
    }

    func deleteItem(_ item: RingtoneItem) {
        let url = fileURL(for: item)
        do { try FileManager.default.removeItem(at: url) }
        catch { lastError = "Ringtone could not be deleted: \(error.localizedDescription)"; return }
        ringtones.removeAll { $0.id == item.id }
        saveLibrary()
    }

    func exportItem(_ item: RingtoneItem, to destinationURL: URL) async -> Bool {
        let sourceURL = fileURL(for: item)
        guard sourceURL.standardizedFileURL.resolvingSymlinksInPath() != destinationURL.standardizedFileURL.resolvingSymlinksInPath() else {
            lastError = "Export must use a different file from the original ringtone."
            return false
        }
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".calltone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let asset = AVURLAsset(url: sourceURL)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            session.outputURL = temporary
            session.outputFileType = .m4a
            session.timeRange = CMTimeRange(start: CMTime(seconds: item.trimStart, preferredTimescale: 600),
                                           end: CMTime(seconds: item.trimEnd, preferredTimescale: 600))
            await session.export()
            guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destinationURL)
            }
            return true
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Waveform Extraction for Trimmer UI

    func extractWaveformSamples(for item: RingtoneItem, sampleCount: Int = 90) async -> [Float] {
        guard sampleCount > 0 else { return [] }
        let url = fileURL(for: item)
        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                return [Float](repeating: 0.25, count: sampleCount)
            }

            guard let reader = try? AVAssetReader(asset: asset) else {
                return [Float](repeating: 0.25, count: sampleCount)
            }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            guard reader.startReading() else {
                return [Float](repeating: 0.25, count: sampleCount)
            }

            var allSamples: [Float] = []
            while let buffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { ptr in
                    if let baseAddress = ptr.baseAddress {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
                    }
                }
                let int16Count = length / MemoryLayout<Int16>.size
                data.withUnsafeBytes { rawPtr in
                    let samples = rawPtr.bindMemory(to: Int16.self)
                    let strideStep = max(1, int16Count / 200)
                    for i in Swift.stride(from: 0, to: int16Count, by: strideStep) {
                        let normalized = abs(Float(samples[i])) / Float(Int16.max)
                        allSamples.append(normalized)
                    }
                }
            }

            guard !allSamples.isEmpty else {
                return [Float](repeating: 0.25, count: sampleCount)
            }

            let bucketSize = max(1, allSamples.count / sampleCount)
            var result: [Float] = []
            for i in 0..<sampleCount {
                let start = i * bucketSize
                let end = min(allSamples.count, start + bucketSize)
                if start < end {
                    let slice = allSamples[start..<end]
                    let peak = slice.max() ?? 0.1
                    result.append(min(1.0, max(0.08, peak)))
                } else {
                    result.append(0.1)
                }
            }
            return result
        }.value
    }

    func duplicateItem(_ item: RingtoneItem) -> RingtoneItem? {
        let sourceURL = fileURL(for: item)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            lastError = "Cannot duplicate missing file."
            return nil
        }
        let ext = item.fileExtension.lowercased()
        let uniqueFileName = "\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)"
        let destination = storageDirectory.appendingPathComponent(uniqueFileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let newItem = RingtoneItem(
                name: "\(item.name) (Copy)",
                fileName: uniqueFileName,
                fileExtension: item.fileExtension,
                duration: item.duration,
                trimStart: item.trimStart,
                trimEnd: item.trimEnd,
                fadeInDuration: item.fadeInDuration,
                fadeOutDuration: item.fadeOutDuration,
                volume: item.volume,
                loopEnabled: item.loopEnabled
            )
            ringtones.insert(newItem, at: 0)
            saveLibrary()
            return newItem
        } catch {
            lastError = "Duplication failed: \(error.localizedDescription)"
            return nil
        }
    }

    func restoreBuiltInSamples() {
        createBuiltInSampleToneIfNeeded(forceAddMissing: true)
    }

    // MARK: - Built-in Sample Tones (Local Offline Synthesis)

    private func createToneFile(fileName: String, duration: Double, decayRate: Double = 2.5, notes: [(start: Double, end: Double, freq: Double, harmonic: Double)]) {
        let dest = storageDirectory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else {
            return
        }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample: Double = 0
            for note in notes where t >= note.start && t <= note.end {
                let localT = t - note.start
                let env = min(1.0, localT / 0.015) * exp(-localT * decayRate)
                let fundamental = sin(2.0 * .pi * note.freq * localT)
                let harmonic = note.harmonic * sin(4.0 * .pi * note.freq * localT)
                sample += (fundamental + harmonic) * env * 0.42
            }
            let clamped = Float(max(-0.95, min(0.95, sample)))
            left[frame] = clamped
            right[frame] = clamped
        }

        if let file = try? AVAudioFile(forWriting: dest, settings: format.settings) {
            try? file.write(from: buffer)
        }
    }

    private func createBuiltInSampleToneIfNeeded(forceAddMissing: Bool = false) {
        struct BuiltInSpec {
            let name: String
            let fileName: String
            let duration: Double
            let decay: Double
            let notes: [(start: Double, end: Double, freq: Double, harmonic: Double)]
        }

        let specs: [BuiltInSpec] = [
            BuiltInSpec(
                name: "CallTone Mac Horizon (Built-in)",
                fileName: "calltone-horizon-default.wav",
                duration: 2.4,
                decay: 2.5,
                notes: [
                    (0.00, 0.70, 523.25, 0.3),
                    (0.28, 1.05, 659.25, 0.3),
                    (0.56, 1.45, 783.99, 0.3),
                    (0.88, 2.30, 987.77, 0.3)
                ]
            ),
            BuiltInSpec(
                name: "Celestial Bells (Built-in)",
                fileName: "calltone-celestial-bells.wav",
                duration: 3.0,
                decay: 2.0,
                notes: [
                    (0.00, 1.20, 659.25, 0.4),
                    (0.35, 1.60, 830.61, 0.4),
                    (0.70, 2.00, 987.77, 0.35),
                    (1.10, 2.80, 1318.51, 0.3)
                ]
            ),
            BuiltInSpec(
                name: "Minimal Pulse (Built-in)",
                fileName: "calltone-minimal-pulse.wav",
                duration: 1.8,
                decay: 3.5,
                notes: [
                    (0.00, 0.45, 440.00, 0.2),
                    (0.20, 0.65, 659.25, 0.2),
                    (0.50, 1.00, 880.00, 0.25),
                    (0.75, 1.60, 1108.73, 0.2)
                ]
            ),
            BuiltInSpec(
                name: "Sunny Marimba (Built-in)",
                fileName: "calltone-sunny-marimba.wav",
                duration: 2.6,
                decay: 3.2,
                notes: [
                    (0.00, 0.60, 349.23, 0.15),
                    (0.20, 0.80, 440.00, 0.15),
                    (0.40, 1.00, 523.25, 0.15),
                    (0.65, 1.30, 659.25, 0.15),
                    (0.90, 2.20, 698.46, 0.15)
                ]
            ),
            BuiltInSpec(
                name: "Breeze Ambient (Built-in)",
                fileName: "calltone-breeze-ambient.wav",
                duration: 3.0,
                decay: 1.8,
                notes: [
                    (0.00, 1.80, 293.66, 0.3),
                    (0.30, 2.10, 369.99, 0.3),
                    (0.60, 2.40, 440.00, 0.35),
                    (0.95, 2.90, 587.33, 0.3)
                ]
            )
        ]

        var newItems: [RingtoneItem] = []
        for spec in specs {
            createToneFile(fileName: spec.fileName, duration: spec.duration, decayRate: spec.decay, notes: spec.notes)
            let dest = storageDirectory.appendingPathComponent(spec.fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                if !ringtones.contains(where: { $0.fileName == spec.fileName }) {
                    let item = RingtoneItem(
                        name: spec.name,
                        fileName: spec.fileName,
                        fileExtension: "WAV",
                        duration: spec.duration,
                        fadeInDuration: 0.1,
                        fadeOutDuration: 0.2,
                        volume: 0.9,
                        loopEnabled: true
                    )
                    newItems.append(item)
                }
            }
        }

        if !newItems.isEmpty {
            if ringtones.isEmpty {
                ringtones = newItems
            } else if forceAddMissing {
                ringtones.append(contentsOf: newItems)
            }
            saveLibrary()
        }
    }
}
