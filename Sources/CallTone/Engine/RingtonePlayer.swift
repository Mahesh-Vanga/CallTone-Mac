import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

@MainActor
final class RingtonePlayer: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var activeRingtoneID: UUID?
    @Published private(set) var currentPlaybackTime: TimeInterval = 0
    @Published var lastPlaybackError: String?

    private var avPlayer: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var loopGeneration: Int = 0
    private var fadeTimer: Timer?
    private var progressTimer: Timer?
    private var playbackStartDate: Date?

    func play(
        item: RingtoneItem,
        fileURL: URL,
        masterVolume: Float,
        fadeInOverride: TimeInterval? = nil,
        fadeOutOverride: TimeInterval? = nil,
        loopOverride: Bool? = nil,
        outputDeviceID: AudioDeviceID? = nil
    ) {
        stop(fadeOut: false)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastPlaybackError = "Audio file not found: \(fileURL.lastPathComponent)"
            return
        }

        let effectiveVolume = min(max(masterVolume * item.volume, 0), 1.0)
        let fadeIn = fadeInOverride ?? item.fadeInDuration
        let shouldLoop = loopOverride ?? item.loopEnabled
        let isTrimmed = item.trimStart > 0.05 || item.trimEnd < (item.duration - 0.05)

        // Use AVAudioPlayer when playing full file on System Default Output (supports MP3, WAV, M4A, M4R, CAF, AAC, FLAC reliably)
        if outputDeviceID == nil && !isTrimmed {
            do {
                let player = try AVAudioPlayer(contentsOf: fileURL)
                player.numberOfLoops = shouldLoop ? -1 : 0
                player.prepareToPlay()

                if fadeIn > 0.1 {
                    player.volume = 0
                    guard player.play() else { throw CocoaError(.fileReadUnknown) }
                    player.setVolume(effectiveVolume, fadeDuration: fadeIn)
                } else {
                    player.volume = effectiveVolume
                    guard player.play() else { throw CocoaError(.fileReadUnknown) }
                }

                self.avPlayer = player
                self.isPlaying = true
                self.activeRingtoneID = item.id
                self.playbackStartDate = Date()
                self.lastPlaybackError = nil
                startProgressTimer(item: item, loop: shouldLoop)

                if !shouldLoop {
                    let duration = player.duration
                    let gen = loopGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
                        guard let self, self.loopGeneration == gen else { return }
                        self.stop(fadeOut: false)
                    }
                }
                return
            } catch {
                // Fall back to AVAudioEngine below if AVAudioPlayer cannot decode
                lastPlaybackError = error.localizedDescription
            }
        }

        // AVAudioEngine path for trimmed clips or custom Core Audio output device routing
        do {
            let newEngine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            newEngine.attach(node)

            if let outputDeviceID, outputDeviceID != kAudioObjectUnknown,
               let audioUnit = newEngine.outputNode.audioUnit {
                var id = outputDeviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            }

            let file = try AVAudioFile(forReading: fileURL)
            newEngine.connect(node, to: newEngine.mainMixerNode, format: file.processingFormat)
            newEngine.prepare()
            try newEngine.start()

            self.engine = newEngine
            self.playerNode = node
            self.audioFile = file

            let sampleRate = file.processingFormat.sampleRate
            guard item.trimStart.isFinite, item.trimEnd.isFinite,
                  item.trimStart >= 0, item.trimStart < Double(file.length) / sampleRate,
                  item.trimEnd > item.trimStart else { throw CocoaError(.fileReadCorruptFile) }
            let startFrame = AVAudioFramePosition(item.trimStart * sampleRate)
            let endFrame = AVAudioFramePosition(min(Double(file.length), item.trimEnd * sampleRate))
            let frames = endFrame - startFrame
            guard frames > 0, frames <= Int64(UInt32.max) else { throw CocoaError(.fileReadTooLarge) }
            let frameCount = AVAudioFrameCount(frames)

            loopGeneration += 1
            let generation = loopGeneration

            if fadeIn > 0.1 {
                node.volume = 0
                startEngineFadeIn(duration: fadeIn, target: effectiveVolume)
            } else {
                node.volume = effectiveVolume
            }

            if shouldLoop, let buffer = try Self.loopingBuffer(file: file, startFrame: startFrame, frameCount: frameCount) {
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            } else {
                // Keep two streamed segments queued so the UI thread is one loop ahead.
                if shouldLoop {
                    node.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
                }
                scheduleSegment(node: node, file: file, startFrame: startFrame,
                                frameCount: frameCount, loop: shouldLoop, generation: generation)
            }

            node.play()
            isPlaying = true
            activeRingtoneID = item.id
            playbackStartDate = Date()
            lastPlaybackError = nil
            startProgressTimer(item: item, loop: shouldLoop)
        } catch {
            lastPlaybackError = "Playback failed: \(error.localizedDescription)"
            stop(fadeOut: false)
        }
    }

    nonisolated static func loopingBuffer(file: AVAudioFile, startFrame: AVAudioFramePosition,
                                         frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard startFrame >= 0, frameCount > 0,
              startFrame <= file.length, Int64(frameCount) <= file.length - startFrame else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let planes: UInt64 = file.processingFormat.isInterleaved ? 1 : UInt64(file.processingFormat.channelCount)
        let bytes = UInt64(frameCount) * UInt64(file.processingFormat.streamDescription.pointee.mBytesPerFrame) * planes
        // shortcut: loops above 64 MiB stream with one segment of lead; use a dedicated scheduler if needed.
        guard bytes <= 64 * 1024 * 1024 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw CocoaError(.fileReadTooLarge)
        }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: min(frameCount, 16384)) else {
            throw CocoaError(.fileReadTooLarge)
        }
        file.framePosition = startFrame
        buffer.frameLength = frameCount
        let bytesPerFrame = Int(file.processingFormat.streamDescription.pointee.mBytesPerFrame)
        var copied: AVAudioFrameCount = 0
        while copied < frameCount {
            try file.read(into: chunk, frameCount: min(chunk.frameCapacity, frameCount - copied))
            guard chunk.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let source = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for index in 0..<destination.count {
                guard let target = destination[index].mData, let data = source[index].mData else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                target.advanced(by: Int(copied) * bytesPerFrame)
                    .copyMemory(from: data, byteCount: Int(chunk.frameLength) * bytesPerFrame)
            }
            copied += chunk.frameLength
        }
        return buffer
    }

    private func scheduleSegment(
        node: AVAudioPlayerNode,
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        loop: Bool,
        generation: Int
    ) {
        node.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: loop ? .dataConsumed : .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isPlaying, self.loopGeneration == generation else { return }
                if loop {
                    self.scheduleSegment(
                        node: node,
                        file: file,
                        startFrame: startFrame,
                        frameCount: frameCount,
                        loop: true,
                        generation: generation
                    )
                } else {
                    self.stop(fadeOut: false)
                }
            }
        }
    }

    func stop(fadeOut: Bool = true, fadeOutDuration: TimeInterval = 0.25) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil

        if let avPlayer {
            if fadeOut && fadeOutDuration > 0.05 && avPlayer.isPlaying {
                avPlayer.setVolume(0, fadeDuration: fadeOutDuration)
                let gen = loopGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) { [weak self] in
                    guard let self, self.loopGeneration == gen else { return }
                    self.cleanupPlayback()
                }
                return
            } else {
                cleanupPlayback()
                return
            }
        }

        guard isPlaying, let node = playerNode else {
            cleanupPlayback()
            return
        }

        if fadeOut && fadeOutDuration > 0.05 {
            let startGain = node.volume
            let steps = 10
            let interval = fadeOutDuration / Double(steps)
            var step = 0
            let generation = loopGeneration

            fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self, self.loopGeneration == generation else {
                        timer.invalidate()
                        return
                    }
                    step += 1
                    let progress = Float(step) / Float(steps)
                    self.playerNode?.volume = max(0, startGain * (1.0 - progress))
                    if step >= steps {
                        timer.invalidate()
                        self.cleanupPlayback()
                    }
                }
            }
        } else {
            cleanupPlayback()
        }
    }

    private func cleanupPlayback() {
        loopGeneration += 1
        avPlayer?.stop()
        avPlayer = nil

        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        audioFile = nil

        isPlaying = false
        activeRingtoneID = nil
        currentPlaybackTime = 0
        playbackStartDate = nil
    }

    private func startEngineFadeIn(duration: TimeInterval, target: Float) {
        let steps = 16
        let interval = duration / Double(steps)
        var step = 0
        let generation = loopGeneration

        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.isPlaying, self.loopGeneration == generation else {
                    timer.invalidate()
                    return
                }
                step += 1
                let progress = Float(step) / Float(steps)
                self.playerNode?.volume = target * progress
                if step >= steps {
                    timer.invalidate()
                }
            }
        }
    }

    private func startProgressTimer(item: RingtoneItem, loop: Bool) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let start = self.playbackStartDate else { return }
                let elapsed = Date().timeIntervalSince(start)
                let dur = item.effectiveDuration
                if loop && dur > 0 {
                    self.currentPlaybackTime = item.trimStart + elapsed.truncatingRemainder(dividingBy: dur)
                } else {
                    self.currentPlaybackTime = min(item.trimEnd, item.trimStart + elapsed)
                }
            }
        }
    }
}
