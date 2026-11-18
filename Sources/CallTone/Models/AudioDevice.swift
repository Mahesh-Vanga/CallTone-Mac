import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefaultOutput: Bool
    let channelCount: Int
}
