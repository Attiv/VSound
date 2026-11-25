import AVFoundation
import Foundation
@testable import MusicCore
import XCTest

final class PlaylistAndPreferencesTests: XCTestCase {
    func testPlaylistDeduplicatesAndMovesMultipleSongsInOrder() {
        var playlist = MusicPlaylist(name: "  Morning  ", trackIDs: ["a", "b", "a", "c", "d"])
        XCTAssertEqual(playlist.name, "Morning")
        playlist.append(["c", "e", "e"])
        XCTAssertEqual(playlist.trackIDs, ["a", "b", "c", "d", "e"])
        playlist.move(from: IndexSet([1, 3]), to: 5)
        XCTAssertEqual(playlist.trackIDs, ["a", "c", "e", "b", "d"])
        playlist.move(from: IndexSet(integer: 4), to: 0)
        XCTAssertEqual(playlist.trackIDs, ["d", "a", "c", "e", "b"])
    }
    func testM3UResolvesLocalPathsAndRejectsNetworkLocations() {
        let location = URL(fileURLWithPath: "/Music/Lists/list.m3u8")
        let urls = M3UPlaylist.urls(in: "\u{feff}#EXTM3U\n../A song.flac\n/Music/B.mp3\nfile:///Music/B.mp3\nhttps://example.test/song.mp3\nfile://remote.test/share/song.wav", relativeTo: location)
        XCTAssertEqual(urls.map(\.path), ["/Music/A song.flac", "/Music/B.mp3"])
        let tracks = urls.map { Track(url: $0, folderID: UUID(), title: "A\n#EXTINF:bad", duration: 42) }
        let exported = M3UPlaylist.text(for: tracks)
        XCTAssertEqual(M3UPlaylist.urls(in: exported, relativeTo: location).map(\.path), urls.map(\.path))
        XCTAssertFalse(exported.contains("\n#EXTINF:bad"))
    }
    func testOldLibraryRemainsReadableAndNewPreferencesRoundTrip() throws {
        var old = LibraryState()
        old.volume = 0.42
        let oldJSON = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(LibraryState.self, from: oldJSON)
        XCTAssertNil(restored.preferences); XCTAssertNil(restored.playlists)
        XCTAssertEqual(restored.volume, 0.42)
        old.preferences = PlayerPreferences(); old.preferences?.transition = .crossfade
        old.playlists = [MusicPlaylist(name: "Evening", trackIDs: ["one", "two"])]
        let current = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(current.preferences?.transition, .crossfade)
        XCTAssertEqual(current.playlists?.first?.trackIDs, ["one", "two"])
    }
    func testVersionComparisonIsNumericAndRejectsUntrustedVersions() {
        XCTAssertLessThan(AppVersion("v1.9.0")!, AppVersion("1.10.0")!)
        XCTAssertEqual(AppVersion("1.1"), AppVersion("1.1.0"))
        XCTAssertNil(AppVersion("1.1.0-beta.1")); XCTAssertNil(AppVersion("javascript:1"))
        XCTAssertNil(AppVersion("1.-2.0")); XCTAssertNil(AppVersion("9999999999999999.0.0"))
    }
    func testReleaseURLCannotEscapeProjectOrMismatchVersion() throws {
        for url in ["https://evil.test/Attiv/VSound/releases/tag/v1.2.0", "http://github.com/Attiv/VSound/releases/tag/v1.2.0", "https://github.com/Attiv/Other/releases/tag/v1.2.0", "https://github.com/Attiv/VSound/releases/tag/v9.0.0"] {
            let json = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.0", "html_url": url, "draft": false, "prerelease": false])
            XCTAssertNil(try JSONDecoder().decode(ReleaseUpdate.self, from: json).validatedPage)
        }
    }
}

final class MultiSourceLyricsTests: XCTestCase {
    func testProviderSearchParsingKeepsSourceAndCorrectUnits() throws {
        let netease: [String: Any] = ["code": 200, "result": ["songs": [["id": 7, "name": "Song", "duration": 240000, "artists": [["name": "Artist"]], "album": ["name": "Album"]]]]]
        let qq: [String: Any] = ["code": 0, "data": ["song": ["list": [["songmid": "mid", "songname": "A &amp; B", "interval": 240, "singer": [["name": "Artist"]]]]]]]
        let kugou: [String: Any] = ["status": 1, "data": ["info": [["hash": "hash", "songname": "Song", "duration": 240, "singername": "Artist"]]]]
        let first = try LyricsClient.parseSearch(netease, source: .netease).first!
        let second = try LyricsClient.parseSearch(qq, source: .qq).first!
        let third = try LyricsClient.parseSearch(kugou, source: .kugou).first!
        XCTAssertEqual(first.duration, 240); XCTAssertEqual(first.origin, .netease)
        XCTAssertEqual(second.trackName, "A & B"); XCTAssertEqual(second.remoteKey, "mid")
        XCTAssertEqual(third.origin, .kugou); XCTAssertEqual(third.duration, 240)
        XCTAssertNotEqual(first.identity, third.identity)
        XCTAssertThrowsError(try LyricsClient.parseSearch(["code": 403], source: .qq))
    }
    func testMatchingRejectsWrongVersionAndArtist() throws {
        let track = Track(url: URL(fileURLWithPath: "/song.wav"), folderID: UUID(), title: "Song", artist: "Artist", duration: 240)
        let candidate = LyricsCandidate(id: 1, trackName: "Song (Live)", artistName: "Artist", albumName: "Album", duration: 240, instrumental: false)
        XCTAssertEqual(LyricsClient.matchScore(candidate, track: track), 0)
        var exact = candidate; exact.trackName = "Song"
        XCTAssertGreaterThan(LyricsClient.matchScore(exact, track: track), 5)
        exact.artistName = "Other"; exact.duration = 300
        XCTAssertEqual(LyricsClient.matchScore(exact, track: track), 0)
    }
    func testBilingualLinesShareOneTimestampAndEntitiesDecodeSafely() {
        let document = LyricsDocument(text: "[00:01.00]Original\n[00:02.00]Next\n[00:01.00]译文\n[00:02.00]下一句")
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines[0].text, "Original\n译文")
        XCTAssertEqual(document.activeLine(at: 1.5), 0)
        XCTAssertEqual(LyricsClient.decodeEntities("&#x4F60;&#22909; &amp; &lt;"), "你好 & <")
    }
}

final class LoudnessAndPCMTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func tone(_ name: String, rate: Double = 48_000, channels: AVAudioChannelCount = 2, amplitude: Float = 0.1) throws -> Track {
        let url = directory.appendingPathComponent(name + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = amplitude * sin(2 * .pi * 1000 * Float(frame) / Float(rate)) }
        }
        try output.write(from: buffer)
        return Track(url: url, folderID: UUID(), title: name, artist: "Test", album: "Album", duration: 2)
    }
    func testKWeightedLoudnessCalibrationAndAlbumGain() async throws {
        let quiet = try tone("quiet"), loud = try tone("loud", amplitude: 0.2)
        let records = try await LoudnessAnalyzer().analyze([quiet, loud]) { _, _ in }
        let a = records[quiet.id]!, b = records[loud.id]!
        XCTAssertEqual(a.lufs, -20, accuracy: 0.25)
        XCTAssertEqual(b.lufs - a.lufs, 6.0206, accuracy: 0.05)
        XCTAssertEqual(a.gain(for: .album), b.gain(for: .album), accuracy: 0.001)
        XCTAssertEqual(a.gain(for: .off), 0)
        XCTAssertEqual(a.gain(for: .track), Float(-18 - a.lufs), accuracy: 0.01)
    }
    func testSilenceDoesNotGetAmplifiedAndPeakGuardPreventsClipping() async throws {
        let silent = try tone("silence", amplitude: 0)
        let records = try await LoudnessAnalyzer().analyze([silent]) { _, _ in }
        XCTAssertEqual(records[silent.id]?.gain(for: .track), 0)
        let record = LoudnessRecord(lufs: -35, peak: 0.99, albumGain: 12, albumPeak: 0.99, fileSize: 0)
        XCTAssertLessThan(record.gain(for: .track), 0)
        XCTAssertLessThanOrEqual(0.99 * pow(10, Double(record.gain(for: .track)) / 20), pow(10, -1.0 / 20) + 0.00001)
    }
    func testPCMReaderConvertsDifferentRatesAndMonoWithoutTrailingGap() throws {
        for (rate, channels) in [(44_100.0, AVAudioChannelCount(1)), (96_000.0, AVAudioChannelCount(2))] {
            let track = try tone("rate-\(Int(rate))", rate: rate, channels: channels)
            let reader = try PCMReader(url: track.url, seconds: 0)
            var count = 0
            while let buffer = try reader.read() {
                XCTAssertEqual(buffer.format.sampleRate, 48_000)
                XCTAssertEqual(buffer.format.channelCount, 2)
                XCTAssertGreaterThan(buffer.frameLength, 0)
                count += Int(buffer.frameLength)
            }
            XCTAssertEqual(Double(count), 96_000, accuracy: 8)
        }
    }
}

final class CacheManagementTests: XCTestCase {
    func testInventoryAndSelectedCleanupStayInsideManagedRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("CloudMusic")
        let folder = root.appendingPathComponent("googleDrive").appendingPathComponent(UUID().uuidString).appendingPathComponent(CloudFileNames.digest("folder"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("audio".utf8).write(to: folder.appendingPathComponent("track.wav"))
        try JSONEncoder().encode(["name": "Drive · Album"]).write(to: folder.appendingPathComponent(".vsound-folder.json"))
        let outside = temporary.appendingPathComponent("keep.wav")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.wav"), withDestinationURL: outside)
        let cache = CloudCacheStore(directory: root)
        let entries = try await cache.entries()
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].name, "Drive · Album"); XCTAssertEqual(entries[0].songs, 1)
        do { try await cache.remove(temporary); XCTFail("Must reject root escape") } catch { }
        try await cache.remove(entries[0].directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let remaining = try await cache.entries()
        XCTAssertTrue(remaining.isEmpty)
    }
}

private final class EnhancementURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "60"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class EnhancementNetworkTests: XCTestCase {
    private var directory: URL!, session: URLSession!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EnhancementURLProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDownWithError() throws { session.invalidateAndCancel(); EnhancementURLProtocol.handler = nil; try FileManager.default.removeItem(at: directory) }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testMultiSourceFailureIsVisibleAndSelectedQQResultCachesBilingualLyrics() async throws {
        var lyricRequests = 0
        EnhancementURLProtocol.handler = { request in
            let url = request.url!
            if url.host == "lrclib.net" { return (503, Data()) }
            if url.path.contains("client_search") {
                return (200, try self.json(["code": 0, "data": ["song": ["list": [["songmid": "unit-mid", "songname": "Unit song", "interval": 100, "singer": [["name": "Unit artist"]]]]]]]))
            }
            XCTAssertEqual(url.host, "c.y.qq.com"); XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://y.qq.com/")
            lyricRequests += 1
            return (200, try self.json(["code": 0, "lyric": "[00:01.00]Original", "trans": "[00:01.00]译文"]))
        }
        let client = LyricsClient(directory: directory, session: session)
        let response = try await client.searchAll("Unit song", sources: [.lrclib, .qq])
        XCTAssertEqual(response.candidates.count, 1); XCTAssertEqual(response.failures.count, 1)
        XCTAssertEqual(lyricRequests, 0, "Do not fetch all candidates' lyrics during search.")
        let document = try await client.resolve(response.candidates[0])
        XCTAssertEqual(document.lines.first?.text, "Original\n译文"); XCTAssertEqual(document.source, "QQ 音乐")
        let track = Track(url: directory.appendingPathComponent("unit.wav"), folderID: UUID(), title: "Unit song")
        try await client.cache(document, for: track)
        let cached = await client.localOrCached(for: track)
        XCTAssertEqual(cached, document)
    }
    func testKugouLazyDownloadDecodesOnlyPlainLRCAndBacksOffRateLimits() async throws {
        var calls = 0
        EnhancementURLProtocol.handler = { request in
            calls += 1
            if request.url!.path == "/search" { return (200, try self.json(["candidates": [["id": "unit-id", "accesskey": "unit-public-key"]]])) }
            return (200, try self.json(["content": Data("[00:01.00]Unit lyric".utf8).base64EncodedString()]))
        }
        let client = LyricsClient(directory: directory, session: session)
        let candidate = LyricsCandidate(id: 1, trackName: "Unit", artistName: "Test", albumName: "", duration: 42, instrumental: false, origin: .kugou, remoteKey: "unit-hash")
        let result = try await client.resolve(candidate)
        XCTAssertTrue(result.isSynced); XCTAssertEqual(calls, 2)
        let limited = LyricsClient(directory: directory, session: session)
        calls = 0
        EnhancementURLProtocol.handler = { _ in calls += 1; return (429, Data()) }
        for _ in 0..<2 { do { _ = try await limited.resolve(candidate); XCTFail("Expected rate limit") } catch { XCTAssertTrue(error is LyricsError) } }
        XCTAssertEqual(calls, 1)
    }
    func testLatestReleaseChecksVersionAndNeverOpensUntrustedURLs() async throws {
        EnhancementURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.host, "api.github.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, try self.json(["tag_name": "v1.2.0", "html_url": "https://github.com/Attiv/VSound/releases/tag/v1.2.0", "draft": false, "prerelease": false]))
        }
        let client = UpdateClient(session: session)
        let available = try await client.check(currentVersion: "1.1.0")
        XCTAssertEqual(available?.version, "v1.2.0")
        let noUpdate = try await client.check(currentVersion: "1.10.0")
        XCTAssertNil(noUpdate)
        EnhancementURLProtocol.handler = { _ in (200, try self.json(["tag_name": "v1.2.0", "html_url": "https://evil.test/payload", "draft": false, "prerelease": false])) }
        do { _ = try await client.check(currentVersion: "1.1.0"); XCTFail("Expected invalid URL rejection") } catch { }
    }
}

final class ContinuousPlaybackTests: XCTestCase {
    @MainActor
    func testPrebufferedNextTrackAdvancesWithoutCallingEndAndPreservesPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("first.wav"), secondURL = directory.appendingPathComponent("second.wav")
        try makeTone(at: firstURL); try makeTone(at: secondURL)
        let first = Track(url: firstURL, folderID: UUID(), title: "First"), second = Track(url: secondURL, folderID: UUID(), title: "Second")
        let player = AudioPlayer(); player.setVolume(0)
        defer { player.stop(); try? FileManager.default.removeItem(at: directory) }
        let advanced = expectation(description: "Prebuffered track becomes active")
        var ordinaryEnd = 0
        player.onEnded = { ordinaryEnd += 1 }
        player.onAdvanced = { id in XCTAssertEqual(id, second.id); advanced.fulfill() }
        player.setUpcoming(second, mode: .gapless, seconds: 3, gain: -3)
        try player.load(first)
        await fulfillment(of: [advanced], timeout: 4)
        XCTAssertTrue(player.isPlaying); XCTAssertEqual(player.loadedID, second.id); XCTAssertEqual(ordinaryEnd, 0)
        player.pause(); let position = player.position
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(player.position, position, accuracy: 0.001)
        try player.seek(to: 0.5)
        XCTAssertEqual(player.position, 0.5, accuracy: 0.001)
    }
    @MainActor
    func testCrossfadeAdvancesEarlyAndSeekingCancelsOldPrebuffer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone.wav"); try makeTone(at: url)
        let first = Track(url: url, folderID: UUID(), title: "First")
        let otherURL = directory.appendingPathComponent("other.wav"); try makeTone(at: otherURL)
        let second = Track(url: otherURL, folderID: UUID(), title: "Second")
        let player = AudioPlayer(); player.setVolume(0)
        defer { player.stop(); try? FileManager.default.removeItem(at: directory) }
        let advanced = expectation(description: "Crossfade begins before prior track ends")
        let start = Date()
        player.onAdvanced = { id in XCTAssertEqual(id, second.id); XCTAssertLessThan(Date().timeIntervalSince(start), 1.2); advanced.fulfill() }
        player.setUpcoming(second, mode: .crossfade, seconds: 0.4, gain: 0)
        try player.load(first)
        await fulfillment(of: [advanced], timeout: 4)
        try player.seek(to: 0.2)
        XCTAssertEqual(player.loadedID, second.id)
        XCTAssertEqual(player.position, 0.2, accuracy: 0.001)
        player.setUpcoming(nil, mode: .off, seconds: 3, gain: 0)
    }
}

final class LibraryWatcherTests: XCTestCase {
    @MainActor
    func testNativeWatcherNoticesANestedAudioFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = expectation(description: "FSEvents observes the imported folder")
        changed.assertForOverFulfill = false
        let watcher = LibraryWatcher { changed.fulfill() }
        watcher.watch([directory])
        defer { watcher.stop() }
        try Data("unit audio".utf8).write(to: nested.appendingPathComponent("new.wav"))
        await fulfillment(of: [changed], timeout: 7)
    }
}
