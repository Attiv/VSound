import Foundation

public struct CloudImportProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var message: String
}

public struct CloudImportResult: Sendable {
    public var directory: URL
    public var displayName: String
    public var provider: CloudProvider
    public var downloaded: Int
    public var reused: Int
    public var warnings: [String]
}

public struct CloudFileCache: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }

    public func destination(for item: CloudItem) -> URL {
        let folder = directory.appendingPathComponent(CloudFileNames.digest(item.id), isDirectory: true)
        // Keep the first local name so remote renames don't break queues or duplicate cached tracks.
        if item.isAudio, let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
           let previous = existing.first(where: { LibraryScanner.extensions.contains($0.pathExtension.lowercased()) }) {
            return folder.appendingPathComponent(previous.lastPathComponent)
        }
        return folder.appendingPathComponent(CloudFileNames.safe(item.name))
    }

    public func isFresh(_ item: CloudItem, at url: URL) -> Bool {
        guard !item.revision.isEmpty, isInside(url),
              let data = try? Data(contentsOf: marker(for: url)),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.id == item.id,
              record.revision == item.revision,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == record.size else { return false }
        return item.size == nil || item.size == record.size
    }

    public func install(_ downloaded: URL, item: CloudItem, at destination: URL) throws {
        guard isInside(destination) else { throw CloudError.cacheDamaged }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard isInside(destination.resolvingSymlinksInPath()) else { throw CloudError.cacheDamaged }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: downloaded, to: staged)
        let size = Int64(try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size >= 0, item.size == nil || item.size == size else { throw CloudError.cacheDamaged }
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: destination) }
        let record = Record(id: item.id, revision: item.revision, size: size)
        try JSONEncoder().encode(record).write(to: marker(for: destination), options: .atomic)
    }

    private struct Record: Codable { var id: String; var revision: String; var size: Int64 }
    private func marker(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + CloudFileNames.digest(url.lastPathComponent) + ".json")
    }
    private func isInside(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") &&
        url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }
}

public actor CloudMusicImporter {
    private let client: CloudClient
    private let directory: URL
    public init(client: CloudClient, directory: URL) {
        self.client = client; self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func importFolder(_ folder: CloudItem, provider: CloudProvider,
                             progress: @Sendable (CloudImportProgress) async -> Void) async throws -> CloudImportResult {
        guard folder.isFolder else { throw CloudError.invalidResponse }
        let namespace = try await client.namespace(for: provider)
        let root = directory.appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(namespace.uuidString, isDirectory: true)
            .appendingPathComponent(CloudFileNames.digest(folder.id), isDirectory: true)
        let cache = CloudFileCache(directory: root)
        var pending = [folder.id], visited = Set<String>(), collected = Set<String>()
        var music: [(CloudItem, CloudItem?)] = []
        while let id = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { continue }
            let items = try await client.list(provider, folderID: id)
            pending.append(contentsOf: items.filter(\.isFolder).map(\.id))
            let lyrics = Dictionary(items.filter(\.isLyric).map {
                (($0.name as NSString).deletingPathExtension.lowercased(), $0)
            }, uniquingKeysWith: { first, _ in first })
            for item in items where item.isAudio && item.canDownload && collected.insert(item.id).inserted {
                music.append((item, lyrics[(item.name as NSString).deletingPathExtension.lowercased()]))
            }
            await progress(.init(completed: 0, total: music.count, message: "正在读取文件夹，已发现 \(music.count) 首音乐…"))
        }
        guard !music.isEmpty else { throw CloudError.noMusic }
        var downloaded = 0, reused = 0, warnings: [String] = []
        for (index, pair) in music.enumerated() {
            try Task.checkCancellation()
            let (audio, lyric) = pair
            await progress(.init(completed: index, total: music.count, message: audio.name))
            let destination = cache.destination(for: audio)
            do {
                if cache.isFresh(audio, at: destination) { reused += 1 }
                else { try await fetch(audio, provider: provider, cache: cache, destination: destination); downloaded += 1 }
                if let lyric, lyric.canDownload {
                    let local = destination.deletingPathExtension().appendingPathExtension("lrc")
                    if !cache.isFresh(lyric, at: local) {
                        do { try await fetch(lyric, provider: provider, cache: cache, destination: local) }
                        catch is CancellationError { throw CancellationError() }
                        catch { warnings.append("\(lyric.name)：\(error.localizedDescription)") }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch CloudError.disconnected { throw CloudError.disconnected }
            catch CloudError.rateLimited { throw CloudError.rateLimited }
            catch CloudError.permissionDenied { throw CloudError.permissionDenied }
            catch { warnings.append("\(audio.name)：\(error.localizedDescription)") }
        }
        guard downloaded + reused > 0 else { throw CloudError.cacheDamaged }
        await progress(.init(completed: music.count, total: music.count, message: "正在加入本地曲库…"))
        return CloudImportResult(directory: root, displayName: "\(provider.title) · \(folder.name)", provider: provider,
                                 downloaded: downloaded, reused: reused, warnings: warnings)
    }

    private func fetch(_ item: CloudItem, provider: CloudProvider, cache: CloudFileCache, destination: URL) async throws {
        let file = try await client.download(item, provider: provider)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        try cache.install(file, item: item, at: destination)
    }
}
