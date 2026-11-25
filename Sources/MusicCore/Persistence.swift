import Foundation

public struct HotKeyBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

public struct LibraryState: Codable, Sendable {
    public var folders: [LibraryFolder] = []
    public var tracks: [Track] = []
    public var favorites: Set<String> = []
    public var recentIDs: [String] = []
    public var queue = PlaybackQueue()
    public var position: Double = 0
    public var volume: Float = 0.7
    public var equalizer = EQSettings()
    public var customPresets: [SavedEQPreset] = []
    public var onlineLyrics = false
    public var lyricsOffsets: [String: Double] = [:]
    public var hotKeys: [String: HotKeyBinding] = [:]
    public var hotKeysEnabled = true
    public init() {}
}

public struct StateStore: Sendable {
    public let directory: URL
    public var stateURL: URL { directory.appendingPathComponent("library.json") }
    public var artworkDirectory: URL { directory.appendingPathComponent("Artwork", isDirectory: true) }
    public var lyricsDirectory: URL { directory.appendingPathComponent("Lyrics", isDirectory: true) }
    public var cloudMusicDirectory: URL { directory.appendingPathComponent("CloudMusic", isDirectory: true) }

    public init(directory: URL? = nil) {
        // Keep the original storage location so rebranding never resets an existing library.
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusic", isDirectory: true)
    }

    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: stateURL))
    }

    public func preserveUnreadableState() throws -> URL {
        let backup = directory.appendingPathComponent("library-unreadable-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: stateURL, to: backup)
        return backup
    }

    public func save(_ state: LibraryState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
