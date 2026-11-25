import Foundation

public struct MusicPlaylist: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var trackIDs: [String]
    public init(id: UUID = UUID(), name: String, trackIDs: [String] = []) {
        self.id = id; self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        var seen = Set<String>()
        self.trackIDs = trackIDs.filter { seen.insert($0).inserted }
    }
    public mutating func append(_ ids: [String]) {
        var seen = Set(trackIDs)
        trackIDs.append(contentsOf: ids.filter { seen.insert($0).inserted })
    }
    public mutating func move(from offsets: IndexSet, to destination: Int) {
        let valid = offsets.filter { trackIDs.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { trackIDs[$0] }
        for index in valid.reversed() { trackIDs.remove(at: index) }
        let insertion = min(trackIDs.count, max(0, destination - valid.filter { $0 < destination }.count))
        trackIDs.insert(contentsOf: moving, at: insertion)
    }
}

public enum M3UPlaylist {
    public static func urls(in text: String, relativeTo location: URL) -> [URL] {
        var seen = Set<String>()
        return text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#"), !value.contains("\0") else { return nil }
            let url: URL
            if let parsed = URL(string: value), parsed.scheme != nil {
                guard parsed.isFileURL, parsed.host == nil || parsed.host == "" || parsed.host == "localhost" else { return nil }
                url = parsed
            } else if value.hasPrefix("/") { url = URL(fileURLWithPath: value) }
            else { url = URL(fileURLWithPath: value, relativeTo: location.deletingLastPathComponent()).absoluteURL }
            let normalized = url.standardizedFileURL
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }
    public static func text(for tracks: [Track]) -> String {
        "#EXTM3U\n" + tracks.map { track in
            let title = "\(track.artist) - \(track.title)".components(separatedBy: .newlines).joined(separator: " ")
            return "#EXTINF:\(Int(track.duration.isFinite ? max(0, min(track.duration, 86_400_000)) : 0)),\(title)\n\(track.url.absoluteString)"
        }.joined(separator: "\n") + "\n"
    }
}
