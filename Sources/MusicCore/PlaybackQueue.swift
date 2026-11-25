import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    public var title: String {
        switch self { case .off: "顺序播放"; case .all: "列表循环"; case .one: "单曲循环" }
    }
    public mutating func cycle() { self = self == .off ? .all : self == .all ? .one : .off }
}

public struct PlaybackQueue: Codable, Sendable {
    public private(set) var trackIDs: [String] = []
    public private(set) var currentID: String?
    public var repeatMode: RepeatMode = .all
    public private(set) var isShuffled = false
    private var remaining: [String] = []
    private var history: [String] = []
    private var forward: [String] = []

    public init() {}

    public mutating func start(_ id: String, in ids: [String]) {
        var seen = Set<String>()
        trackIDs = ids.filter { seen.insert($0).inserted }
        if !trackIDs.contains(id) { trackIDs.append(id) }
        currentID = id
        history = []; forward = []
        remaining = trackIDs.filter { $0 != id }.shuffled()
    }

    public mutating func toggleShuffle() {
        isShuffled.toggle()
        remaining = trackIDs.filter { $0 != currentID }.shuffled()
        forward = []
    }

    public var upcomingIDs: [String] {
        let upcoming: [String]
        if isShuffled { upcoming = remaining }
        else if let currentID, let index = trackIDs.firstIndex(of: currentID) {
            upcoming = Array(trackIDs.dropFirst(index + 1))
        } else { upcoming = trackIDs }
        var seen = Set<String>()
        return (forward.reversed() + upcoming).filter { $0 != currentID && seen.insert($0).inserted }
    }

    public mutating func next(automatic: Bool = false) -> String? {
        guard !trackIDs.isEmpty else { return nil }
        if automatic, repeatMode == .one, let currentID { return currentID }
        let nextID: String?
        if let id = forward.popLast() { nextID = id }
        else if isShuffled {
            if remaining.isEmpty {
                guard repeatMode == .all else { return nil }
                remaining = trackIDs.filter { $0 != currentID }.shuffled()
                if remaining.isEmpty { return currentID }
            }
            nextID = remaining.removeFirst()
        } else if let currentID, let index = trackIDs.firstIndex(of: currentID) {
            if index + 1 < trackIDs.count { nextID = trackIDs[index + 1] }
            else { nextID = repeatMode == .all ? trackIDs.first : nil }
        } else { nextID = trackIDs.first }
        guard let nextID else { return nil }
        remaining.removeAll { $0 == nextID }
        if let currentID, currentID != nextID { history.append(currentID) }
        currentID = nextID
        return nextID
    }

    public mutating func previous() -> String? {
        if let id = history.popLast() {
            if let currentID { forward.append(currentID) }
            currentID = id
            return id
        }
        guard !isShuffled, let currentID,
              let index = trackIDs.firstIndex(of: currentID), index > 0 else { return currentID }
        forward.append(currentID)
        self.currentID = trackIDs[index - 1]
        return self.currentID
    }

    public mutating func append(_ id: String) {
        guard !trackIDs.contains(id) else { return }
        trackIDs.append(id)
        if isShuffled { remaining.append(id) }
    }

    public mutating func playNext(_ id: String) {
        guard id != currentID else { return }
        trackIDs.removeAll { $0 == id }
        let index = currentID.flatMap { trackIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        trackIDs.insert(id, at: index)
        remaining.removeAll { $0 == id }
        remaining.insert(id, at: 0)
        forward.removeAll { $0 == id }
        if !forward.isEmpty { forward.append(id) }
    }

    public mutating func retain(_ validIDs: Set<String>) {
        trackIDs.removeAll { !validIDs.contains($0) }
        remaining.removeAll { !validIDs.contains($0) }
        history.removeAll { !validIDs.contains($0) }
        forward.removeAll { !validIDs.contains($0) }
        if let currentID, !validIDs.contains(currentID) { self.currentID = nil }
    }

    public mutating func removeUpcoming(_ id: String) {
        guard id != currentID else { return }
        retain(Set(trackIDs.filter { $0 != id }))
    }
}
