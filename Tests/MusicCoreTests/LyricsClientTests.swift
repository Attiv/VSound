import Foundation
@testable import MusicCore
import XCTest

private final class LyricsURLProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var responseBody = Data()
    static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Retry-After": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LyricsClientTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsURLProtocol.self]
        session = URLSession(configuration: config)
        LyricsURLProtocol.status = 200; LyricsURLProtocol.lastURL = nil
        LyricsURLProtocol.responseBody = Data(#"{"id":1,"trackName":"夜曲","artistName":"周杰伦","albumName":"Album","duration":210,"instrumental":false,"plainLyrics":"歌词","syncedLyrics":"[00:01.00]歌词"}"#.utf8)
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
    }
    private var track: Track { Track(url: directory.appendingPathComponent("test.flac"), folderID: UUID(), title: "夜曲", artist: "周杰伦", duration: 210) }

    func testFetchEncodesMetadataAndCachesForOfflineUse() async throws {
        let client = LyricsClient(directory: directory.appendingPathComponent("cache"), session: session)
        let track = track
        let document = try await client.fetch(for: track)
        XCTAssertTrue(document.isSynced)
        let components = URLComponents(url: LyricsURLProtocol.lastURL!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(components.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(query["track_name"], "夜曲")
        XCTAssertEqual(query["artist_name"], "周杰伦")
        XCTAssertEqual(query["duration"], "210")
        XCTAssertFalse(LyricsURLProtocol.lastURL!.absoluteString.contains("test.flac"))
        let cached = await client.localOrCached(for: track)
        XCTAssertEqual(cached, document)
    }

    func testLocalLRCIsPreferredToCache() async throws {
        let client = LyricsClient(directory: directory.appendingPathComponent("cache"), session: session)
        let track = track
        try await client.cache(LyricsDocument(text: "cached"), for: track)
        try "[00:00.00]local".write(to: track.url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        let loaded = await client.localOrCached(for: track)
        XCTAssertEqual(loaded?.lines.first?.text, "local")
    }

    func testRateLimitAndMissingTrackAreRecoverable() async throws {
        let client = LyricsClient(directory: directory, session: session)
        for status in [404, 429, 503] {
            LyricsURLProtocol.status = status
            do { _ = try await client.fetch(for: track); XCTFail("Expected HTTP \(status) error") }
            catch { XCTAssertTrue(error is LyricsError) }
        }
    }
}
