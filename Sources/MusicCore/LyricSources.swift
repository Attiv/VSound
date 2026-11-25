import Foundation

public enum LyricSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case lrclib, qq, netease, kugou
    public var id: String { rawValue }
    public var title: String { switch self { case .lrclib: "LRCLIB"; case .qq: "QQ 音乐"; case .netease: "网易云"; case .kugou: "酷狗" } }
}

public struct LyricsSearchResponse: Sendable {
    public var candidates: [LyricsCandidate]
    public var failures: [String]
}

extension LyricsClient {
    public func match(for track: Track, sources: [LyricSource]) async throws -> LyricsDocument {
        if sources.contains(.lrclib), let exact = try? await fetch(for: track) { return exact }
        try Task.checkCancellation()
        let query = track.title + (track.artist == "未知歌手" ? "" : " " + track.artist)
        let response = try await searchAll(query, sources: sources)
        let ranked = response.candidates.map { ($0, Self.matchScore($0, track: track)) }.filter { $0.1 >= 5 }.sorted { $0.1 > $1.1 }
        for (candidate, _) in ranked.prefix(4) {
            try Task.checkCancellation()
            if let document = try? await resolve(candidate) { try cache(document, for: track); return document }
        }
        throw LyricsError.notFound
    }
    static func matchScore(_ candidate: LyricsCandidate, track: Track) -> Int {
        func normalized(_ value: String) -> String { value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
        let title = normalized(track.title), found = normalized(candidate.trackName)
        guard !title.isEmpty, title == found else { return 0 }
        let timed = track.duration > 0 && candidate.duration > 0 && abs(track.duration - candidate.duration) <= 5
        let artist = normalized(track.artist), foundArtist = normalized(candidate.artistName)
        let artistMatches = track.artist != "未知歌手" && !artist.isEmpty && (artist == foundArtist || foundArtist.contains(artist))
        guard artistMatches || timed else { return 0 }
        return 4 + (artistMatches ? 3 : 0) + (timed ? 2 : 0)
    }

    public func searchAll(_ query: String, sources: [LyricSource]) async throws -> LyricsSearchResponse {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .init(candidates: [], failures: []) }
        var candidates: [LyricsCandidate] = [], failures: [String] = []
        for source in LyricSource.allCases where sources.contains(source) {
            try Task.checkCancellation()
            do {
                candidates.append(contentsOf: try await searchProvider(source, query: clean))
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(source.title)：\(error.localizedDescription)") }
        }
        var seen = Set<String>()
        return .init(candidates: candidates.filter { seen.insert($0.identity).inserted }, failures: failures)
    }

    private func searchProvider(_ source: LyricSource, query: String) async throws -> [LyricsCandidate] {
        if source == .lrclib { return try await search(query) }
        let endpoint: String, parameters: [String: String]
        switch source {
        case .netease:
            endpoint = "https://music.163.com/api/search/get/web"
            parameters = ["s": query, "type": "1", "limit": "20", "offset": "0"]
        case .qq:
            endpoint = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
            parameters = ["w": query, "format": "json", "n": "20", "p": "1"]
        case .kugou:
            endpoint = "https://mobiles.kugou.com/api/v3/search/song"
            parameters = ["keyword": query, "page": "1", "pagesize": "20", "format": "json"]
        case .lrclib: return []
        }
        let object = try await providerJSON(source, endpoint: endpoint, parameters: parameters)
        return try Self.parseSearch(object, source: source)
    }

    static func parseSearch(_ object: [String: Any], source: LyricSource) throws -> [LyricsCandidate] {
        let songs: [[String: Any]]
        switch source {
        case .netease:
            guard (object["code"] as? Int) == 200 else { throw LyricsError.server(object["code"] as? Int ?? 502) }
            songs = (object["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        case .qq:
            guard (object["code"] as? Int) == 0 else { throw LyricsError.server(object["code"] as? Int ?? 502) }
            songs = ((object["data"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        case .kugou:
            guard (object["status"] as? Int) == 1 else { throw LyricsError.server(object["errcode"] as? Int ?? 502) }
            songs = (object["data"] as? [String: Any])?["info"] as? [[String: Any]] ?? []
        case .lrclib: return []
        }
        return songs.prefix(20).compactMap { song in
            let key: String, title: String, artist: String, album: String, duration: Double
            switch source {
            case .netease:
                guard let id = song["id"] as? NSNumber, let name = song["name"] as? String else { return nil }
                key = id.stringValue; title = name
                artist = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
                album = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                duration = ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            case .qq:
                guard let mid = song["songmid"] as? String, let name = song["songname"] as? String else { return nil }
                key = mid; title = name
                artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
                album = song["albumname"] as? String ?? ""; duration = (song["interval"] as? NSNumber)?.doubleValue ?? 0
            case .kugou:
                guard let hash = song["hash"] as? String, let name = song["songname"] as? String else { return nil }
                key = hash; title = name; artist = song["singername"] as? String ?? ""
                album = song["album_name"] as? String ?? ""; duration = (song["duration"] as? NSNumber)?.doubleValue ?? 0
            case .lrclib: return nil
            }
            guard !key.isEmpty, !title.isEmpty else { return nil }
            return LyricsCandidate(id: Int(CloudFileNames.digest(source.rawValue + key).prefix(12), radix: 16) ?? 0,
                                   trackName: Self.decodeEntities(title), artistName: Self.decodeEntities(artist),
                                   albumName: Self.decodeEntities(album), duration: duration.isFinite ? max(0, duration) : 0,
                                   instrumental: false, plainLyrics: nil, syncedLyrics: nil, origin: source, remoteKey: key)
        }
    }

    public func resolve(_ candidate: LyricsCandidate) async throws -> LyricsDocument {
        if let document = candidate.document { return document }
        guard let source = candidate.origin, let key = candidate.remoteKey else { throw LyricsError.notFound }
        var text = "", translated = ""
        switch source {
        case .netease:
            let json = try await providerJSON(source, endpoint: "https://music.163.com/api/song/lyric",
                                              parameters: ["id": key, "lv": "-1", "tv": "-1", "kv": "-1"])
            text = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
            translated = (json["tlyric"] as? [String: Any])?["lyric"] as? String ?? ""
        case .qq:
            let json = try await providerJSON(source, endpoint: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                                              parameters: ["songmid": key, "format": "json", "nobase64": "1"])
            guard (json["code"] as? Int) == 0 else { throw LyricsError.notFound }
            text = Self.decodeEntities(json["lyric"] as? String ?? "")
            translated = Self.decodeEntities(json["trans"] as? String ?? "")
        case .kugou:
            let found = try await providerJSON(source, endpoint: "https://lyrics.kugou.com/search", parameters:
                ["ver": "1", "man": "yes", "client": "pc", "keyword": candidate.trackName + " " + candidate.artistName,
                 "duration": String(Int(min(86_400, max(0, candidate.duration)) * 1000)), "hash": key])
            guard let records = found["candidates"] as? [[String: Any]], let best = records.first,
                  let access = best["accesskey"] as? String else { throw LyricsError.notFound }
            let id = (best["id"] as? String) ?? (best["id"] as? NSNumber)?.stringValue ?? ""
            guard !id.isEmpty else { throw LyricsError.notFound }
            let json = try await providerJSON(source, endpoint: "https://lyrics.kugou.com/download", parameters:
                ["ver": "1", "client": "pc", "id": id, "accesskey": access, "fmt": "lrc", "charset": "utf8"])
            guard let encoded = json["content"] as? String, let data = Data(base64Encoded: encoded) else { throw LyricsError.notFound }
            text = try Self.decodeText(data)
        case .lrclib: throw LyricsError.notFound
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsError.notFound }
        return LyricsDocument(text: text + (translated.isEmpty ? "" : "\n" + translated), source: source.title)
    }

    private func providerJSON(_ source: LyricSource, endpoint: String, parameters: [String: String]) async throws -> [String: Any] {
        try await throttle(source)
        var components = URLComponents(string: endpoint)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 VSound/1.1 (https://github.com/Attiv/VSound)", forHTTPHeaderField: "User-Agent")
        request.setValue(source == .qq ? "https://y.qq.com/" : source == .netease ? "https://music.163.com/" : "https://www.kugou.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw LyricsError.invalidText }
        if response.statusCode == 429 {
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            providerCooldowns[source] = Date().addingTimeInterval(min(86_400, max(1, wait)))
            throw LyricsError.rateLimited
        }
        guard response.statusCode == 200 else { throw LyricsError.server(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.invalidText }
        return json
    }

    func throttle(_ source: LyricSource) async throws {
        if let until = providerCooldowns[source], until > Date() { throw LyricsError.rateLimited }
        let now = Date(), earliest = max(Date(), (providerRequestTimes[source] ?? .distantPast).addingTimeInterval(0.25))
        providerRequestTimes[source] = earliest
        if earliest > now { try await Task.sleep(for: .seconds(earliest.timeIntervalSince(now))) }
        try Task.checkCancellation()
        if let until = providerCooldowns[source], until > Date() { throw LyricsError.rateLimited }
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (encoded, decoded) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: encoded, with: decoded)
        }
        let regex = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range(at: 1), in: result), let full = Range(match.range, in: result) else { continue }
            let digits = String(result[range])
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(full, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
