import Foundation

public struct CloudCacheEntry: Identifiable, Sendable {
    public var id: String { directory.absoluteString }
    public let directory: URL
    public let name: String
    public let provider: CloudProvider
    public let bytes: Int64
    public let songs: Int
}

public actor CloudCacheStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }
    public func entries() throws -> [CloudCacheEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        var result: [CloudCacheEntry] = []
        for provider in CloudProvider.allCases {
            let root = directory.appendingPathComponent(provider.rawValue, isDirectory: true)
            for account in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
                guard UUID(uuidString: account.lastPathComponent) != nil, (try? account.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                for folder in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
                    guard valid(folder) else { continue }
                    var bytes: Int64 = 0, songs = 0
                    let iterator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    while let file = iterator?.nextObject() as? URL {
                        try Task.checkCancellation()
                        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
                        if values.isSymbolicLink == true { iterator?.skipDescendants(); continue }
                        if values.isRegularFile == true {
                            bytes += Int64(max(0, values.fileSize ?? 0))
                            if LibraryScanner.extensions.contains(file.pathExtension.lowercased()) { songs += 1 }
                        }
                    }
                    let manifest = folder.appendingPathComponent(".vsound-folder.json")
                    let display: String?
                    if let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
                       let data = try? Data(contentsOf: manifest), let object = try? JSONDecoder().decode([String: String].self, from: data) { display = object["name"] }
                    else { display = nil }
                    result.append(CloudCacheEntry(directory: folder, name: display ?? "\(provider.title) · 缓存 \(folder.lastPathComponent.prefix(8))", provider: provider, bytes: bytes, songs: songs))
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func remove(_ folder: URL) throws {
        guard valid(folder) else { throw CloudError.cacheDamaged }
        try FileManager.default.removeItem(at: folder)
    }
    private func valid(_ url: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let normalized = url.standardizedFileURL
        guard normalized.resolvingSymlinksInPath().path.hasPrefix(root),
              (try? normalized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
              (try? normalized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        let parts = String(normalized.resolvingSymlinksInPath().path.dropFirst(root.count)).split(separator: "/").map(String.init)
        return parts.count == 3 && CloudProvider(rawValue: parts[0]) != nil && UUID(uuidString: parts[1]) != nil &&
            parts[2].count == 64 && parts[2].allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

public enum CloudDownloadState: String, Codable, Sendable {
    case running, completed, cancelled, failed
    public var title: String { switch self { case .running: "下载中"; case .completed: "已完成"; case .cancelled: "已停止"; case .failed: "未完成" } }
}
public struct CloudDownloadJob: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var provider: CloudProvider
    public var folder: CloudItem
    public var state: CloudDownloadState = .running
    public var completed = 0
    public var total = 0
    public var message = "正在读取文件夹…"
    public var startedAt = Date()
    public init(provider: CloudProvider, folder: CloudItem) { self.provider = provider; self.folder = folder }
}
