import Foundation

struct RingtoneItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var fileExtension: String
    var duration: TimeInterval
    var trimStart: TimeInterval
    var trimEnd: TimeInterval
    var fadeInDuration: TimeInterval
    var fadeOutDuration: TimeInterval
    var volume: Float
    var loopEnabled: Bool
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        fileExtension: String,
        duration: TimeInterval,
        trimStart: TimeInterval = 0,
        trimEnd: TimeInterval? = nil,
        fadeInDuration: TimeInterval = 0.25,
        fadeOutDuration: TimeInterval = 0.25,
        volume: Float = 1.0,
        loopEnabled: Bool = true,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.duration = max(0.1, duration)
        self.trimStart = max(0, trimStart)
        self.trimEnd = min(duration, trimEnd ?? duration)
        self.fadeInDuration = max(0, fadeInDuration)
        self.fadeOutDuration = max(0, fadeOutDuration)
        self.volume = min(max(volume, 0), 1)
        self.loopEnabled = loopEnabled
        self.dateAdded = dateAdded
    }

    var effectiveDuration: TimeInterval {
        max(0.1, trimEnd - trimStart)
    }

    var formattedDuration: String {
        Self.formatTime(effectiveDuration)
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
