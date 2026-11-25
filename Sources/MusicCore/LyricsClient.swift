import AVFoundation
import CoreFoundation
import CryptoKit
import Foundation

public struct LyricsCandidate: Decodable, Identifiable, Sendable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String
    public var duration: Double
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?
    public var origin: LyricSource?
    public var remoteKey: String?
    public var translation: String?
    public var identity: String { "\((origin ?? .lrclib).rawValue):\(remoteKey ?? String(id))" }
    public var document: LyricsDocument? {
        let timed = syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = [timed, plain].compactMap({ $0 }).first(where: { !$0.isEmpty && $0 != "null" }) else { return nil }
        return LyricsDocument(text: text + ((translation?.isEmpty == false) ? "\n" + translation! : ""), source: (origin ?? .lrclib).title)
    }
}

public enum LyricsError: LocalizedError {
    case notFound, rateLimited, server(Int), invalidText
    public var errorDescription: String? {
        switch self {
        case .notFound: "没有找到匹配的歌词，可以手动搜索或导入 LRC。"
        case .rateLimited: "歌词服务暂时限流，请稍后手动重试。"
        case .server(let code): "歌词服务暂不可用（HTTP \(code)）。"
        case .invalidText: "无法读取歌词，请使用 UTF-8、UTF-16 或 GB18030 编码的文本文件。"
        }
    }
}

public actor LyricsClient {
    private let directory: URL
    let session: URLSession
    var providerCooldowns: [LyricSource: Date] = [:]
    var providerRequestTimes: [LyricSource: Date] = [:]
    public init(directory: URL, session: URLSession = .shared) { self.directory = directory; self.session = session }

    public static func decodeText(_ data: Data) throws -> String {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        for encoding in [String.Encoding.utf8, .utf16, String.Encoding(rawValue: gb)] {
            if let text = String(data: data, encoding: encoding) {
                return text.replacingOccurrences(of: "\u{feff}", with: "")
            }
        }
        throw LyricsError.invalidText
    }

    public static func readText(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 2_000_000 else { throw LyricsError.invalidText }
        return try decodeText(Data(contentsOf: url))
    }

    public func localOrCached(for track: Track) async -> LyricsDocument? {
        let local = track.url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = try? Self.readText(at: local), !text.isEmpty {
            return LyricsDocument(text: text, source: "同目录 LRC")
        }
        if let data = try? Data(contentsOf: cacheURL(track)),
           let doc = try? JSONDecoder().decode(LyricsDocument.self, from: data) { return doc }
        let asset = AVURLAsset(url: track.url)
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = item.identifier?.rawValue.lowercased() ?? ""
                if key.contains("uslt") || key.contains("©lyr") || key.contains("lyrics"),
                   let text = try? await item.load(.stringValue), !text.isEmpty {
                    return LyricsDocument(text: text, source: "内嵌歌词")
                }
            }
        }
        return nil
    }

    public func fetch(for track: Track) async throws -> LyricsDocument {
        var query = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if track.album != "未知专辑" { query.append(.init(name: "album_name", value: track.album)) }
        if track.duration > 0, track.duration <= 3600 {
            query.append(.init(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        let data = try await request(path: "get", query: query)
        let candidate = try JSONDecoder().decode(LyricsCandidate.self, from: data)
        guard let document = candidate.document else { throw LyricsError.notFound }
        try cache(document, for: track)
        return document
    }

    public func search(_ query: String) async throws -> [LyricsCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let data = try await request(path: "search", query: [.init(name: "q", value: query)])
        return Array(try JSONDecoder().decode([LyricsCandidate].self, from: data).filter { $0.document != nil }.prefix(30))
    }

    public func cache(_ document: LyricsDocument, for track: Track) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: cacheURL(track), options: .atomic)
    }

    private func cacheURL(_ track: Track) -> URL {
        let key = SHA256.hash(data: Data(track.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> Data {
        try await throttle(.lrclib)
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("VSound/1.0 (https://github.com/Attiv/VSound)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch response.statusCode {
        case 200: return data
        case 404: throw LyricsError.notFound
        case 429:
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            providerCooldowns[.lrclib] = Date().addingTimeInterval(min(86_400, max(1, wait)))
            throw LyricsError.rateLimited
        default: throw LyricsError.server(response.statusCode)
        }
    }
}
