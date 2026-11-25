import Foundation

public struct AppVersion: Comparable, Equatable, Sendable {
    public let components: [Int]
    public init?(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        guard !clean.contains("-"), let base = clean.split(separator: "+").first else { return nil }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), part.count <= 8 else { return nil }
            return Int(part)
        }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct ReleaseUpdate: Decodable, Sendable {
    public let tag_name: String
    public let html_url: URL
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public var version: String { tag_name }
    public var validatedPage: URL? {
        guard html_url.scheme == "https", html_url.host?.lowercased() == "github.com", html_url.port == nil,
              html_url.user == nil, html_url.password == nil,
              html_url.path == "/Attiv/VSound/releases/tag/" + tag_name, html_url.query == nil, html_url.fragment == nil,
              AppVersion(tag_name) != nil else { return nil }
        return html_url
    }
}

public actor UpdateClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func check(currentVersion: String) async throws -> ReleaseUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Attiv/VSound/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VSound/1.1 (https://github.com/Attiv/VSound)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(ReleaseUpdate.self, from: data)
        guard !release.draft, !release.prerelease, release.validatedPage != nil,
              let available = AppVersion(release.tag_name), let current = AppVersion(currentVersion) else { throw URLError(.cannotParseResponse) }
        return available > current ? release : nil
    }
}
