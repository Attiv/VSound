import Foundation

public struct Track: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.absoluteString }
    public var url: URL
    public var folderID: UUID
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var trackNumber: Int
    public var artworkPath: String?
    public var modifiedAt: Date?
    public var fileSize: Int64

    public init(url: URL, folderID: UUID, title: String, artist: String = "未知歌手",
                album: String = "未知专辑", duration: Double = 0, trackNumber: Int = 0,
                artworkPath: String? = nil, modifiedAt: Date? = nil, fileSize: Int64 = 0) {
        self.url = url; self.folderID = folderID; self.title = title
        self.artist = artist; self.album = album; self.duration = duration
        self.trackNumber = trackNumber; self.artworkPath = artworkPath
        self.modifiedAt = modifiedAt; self.fileSize = fileSize
    }

    public var albumID: String { artist + "\u{1f}" + album }
    public var fileType: String { url.pathExtension.uppercased() }
    public func matches(_ search: String) -> Bool {
        search.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            [title, artist, album, url.lastPathComponent].contains {
                $0.localizedStandardContains(String(term))
            }
        }
    }
}

public struct LibraryFolder: Identifiable, Codable, Sendable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data?
    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil) {
        self.id = id; self.url = url; self.bookmark = bookmark
    }
}

public enum MusicFormatting {
    public static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
