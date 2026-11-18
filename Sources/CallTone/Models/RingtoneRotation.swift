import Foundation

struct RingtoneRotation: Codable, Equatable {
    enum Mode: String, CaseIterable, Codable {
        case single = "Single"
        case sequential = "Sequential"
        case shuffle = "Shuffle"
    }

    var mode: Mode = .single
    var toneIDs: [UUID] = []

    func available(in ringtones: [RingtoneItem]) -> Self {
        guard !toneIDs.isEmpty else { return self }
        var availableIDs = Set(ringtones.map(\.id))
        return Self(mode: mode, toneIDs: toneIDs.filter { availableIDs.remove($0) != nil })
    }

    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = toneIDs.firstIndex(of: id), toneIDs.indices.contains(index + offset) else { return }
        toneIDs.swapAt(index, index + offset)
    }

    func cycle(after previous: UUID?) -> [UUID] {
        switch mode {
        case .single: return []
        case .sequential: return toneIDs
        case .shuffle:
            var order = toneIDs.shuffled()
            if order.count > 1, order.first == previous {
                order.swapAt(0, 1)
            }
            return order
        }
    }
}
