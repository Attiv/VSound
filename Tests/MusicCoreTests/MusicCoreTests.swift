import AVFoundation
import Foundation
@testable import MusicCore
import XCTest

final class PlaybackQueueTests: XCTestCase {
    func testSequentialRepeatAndManualSkip() {
        var queue = PlaybackQueue()
        queue.start("a", in: ["a", "b", "c", "a"])
        XCTAssertEqual(queue.trackIDs, ["a", "b", "c"])
        XCTAssertEqual(queue.next(), "b")
        queue.repeatMode = .one
        XCTAssertEqual(queue.next(automatic: true), "b")
        XCTAssertEqual(queue.next(), "c")
        queue.repeatMode = .off
        XCTAssertNil(queue.next(automatic: true))
        queue.repeatMode = .all
        XCTAssertEqual(queue.next(automatic: true), "a")
    }

    func testShuffleDoesNotRepeatAndPreviousUsesHistory() {
        for _ in 0..<30 {
            var queue = PlaybackQueue()
            queue.start("a", in: ["a", "b", "c", "d", "e"])
            queue.toggleShuffle()
            var heard = ["a"]
            for _ in 0..<4 { heard.append(queue.next()!) }
            XCTAssertEqual(Set(heard).count, 5)
            let last = heard[4]
            XCTAssertEqual(queue.previous(), heard[3])
            XCTAssertEqual(queue.next(), last)
            XCTAssertNotEqual(queue.next(), last)
        }
    }

    func testPlayNextAndRemovingMissingTracks() {
        var queue = PlaybackQueue()
        queue.start("a", in: ["a", "b", "c"])
        queue.playNext("c")
        XCTAssertEqual(queue.next(), "c")
        queue.toggleShuffle()
        queue.playNext("new")
        XCTAssertEqual(queue.next(), "new")
        queue.retain(["a", "c"])
        XCTAssertNil(queue.currentID)
        XCTAssertEqual(Set(queue.trackIDs), ["a", "c"])
    }

    func testShuffleWithoutRepeatStopsAfterOneCycle() {
        var queue = PlaybackQueue()
        queue.start("a", in: ["a", "b"])
        queue.toggleShuffle(); queue.repeatMode = .off
        XCTAssertEqual(queue.next(automatic: true), "b")
        XCTAssertNil(queue.next(automatic: true))
    }

    func testPlayNextAfterGoingBackDoesNotDuplicateShuffleEntries() {
        var queue = PlaybackQueue()
        queue.start("a", in: ["a", "b", "c", "d"])
        queue.toggleShuffle(); queue.repeatMode = .off
        _ = queue.next(); let last = queue.next()
        _ = queue.previous()
        queue.playNext("new")
        XCTAssertEqual(queue.next(), "new")
        XCTAssertEqual(queue.next(), last)
        var rest: [String] = []
        while let next = queue.next() { rest.append(next) }
        XCTAssertFalse(rest.contains("new"))
    }
}

final class LyricsTests: XCTestCase {
    func testFractionsMultipleTagsOffsetAndBinaryLookup() {
        let document = LyricsDocument(text: "[ar:Artist]\n[offset:-200]\n[00:01.5][00:03.050]Hello\n[00:02.34]World\n[00:75]invalid")
        XCTAssertEqual(document.lines.map(\.text), ["Hello", "World", "Hello"])
        XCTAssertEqual(document.lines[0].time, 1.3, accuracy: 0.0001)
        XCTAssertEqual(document.lines[1].time, 2.14, accuracy: 0.0001)
        XCTAssertEqual(document.lines[2].time, 2.85, accuracy: 0.0001)
        XCTAssertNil(document.activeLine(at: 1.29))
        XCTAssertEqual(document.activeLine(at: 2.14), 1)
        XCTAssertEqual(document.activeLine(at: 900), 2)
        XCTAssertNil(document.activeLine(at: .nan))
    }

    func testPlainLyricsAndUTF16() throws {
        let text = "第一句\n第二句"
        XCTAssertFalse(LyricsDocument(text: text).isSynced)
        XCTAssertEqual(LyricsDocument(text: text).plainText, text)
        XCTAssertEqual(try LyricsClient.decodeText(text.data(using: .utf16)!), text)
        XCTAssertEqual(MusicFormatting.time(.nan), "0:00")
        XCTAssertEqual(MusicFormatting.time(3661), "1:01:01")
    }
}

final class EqualizerTests: XCTestCase {
    func testPresetsAndHeadroom() {
        XCTAssertTrue(EQPreset.builtIn.contains { $0.id == "harman-style" })
        XCTAssertEqual(Set(EQPreset.builtIn.map(\.id)).count, EQPreset.builtIn.count)
        for preset in EQPreset.builtIn {
            XCTAssertEqual(preset.gains.count, 10)
            XCTAssertTrue(preset.gains.allSatisfy { (-12...12).contains($0) })
            var settings = EQSettings(); settings.enabled = true; settings.gains = preset.gains
            XCTAssertLessThanOrEqual(settings.effectivePreamp, 0)
        }
    }
    func testCorruptValuesAreNormalized() {
        var settings = EQSettings()
        settings.gains = [.nan, .infinity, 30, -30]; settings.preamp = .nan
        settings.normalize()
        XCTAssertEqual(settings.gains, [0, 0, 12, -12, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(settings.preamp, 0)
    }
}

final class LibraryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testAtomicStateRoundTripAndCorruptBackup() throws {
        let store = StateStore(directory: directory)
        XCTAssertTrue(try store.load().tracks.isEmpty)
        var state = LibraryState()
        let track = Track(url: directory.appendingPathComponent("test.wav"), folderID: UUID(), title: "测试歌曲")
        state.tracks = [track]; state.favorites = [track.id]
        state.queue.start(track.id, in: [track.id]); state.position = 42
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.tracks, state.tracks)
        XCTAssertEqual(restored.favorites, state.favorites)
        XCTAssertEqual(restored.queue.currentID, track.id)
        XCTAssertEqual(restored.position, 42)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.stateURL)
        XCTAssertThrowsError(try store.load())
        let backup = try store.preserveUnreadableState()
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), corrupt)
    }

    func testScannerFindsNestedAudioAndSkipsSymlinks() async throws {
        let nested = directory.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("Artist - Song.wav")
        try makeTone(at: file)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.wav"), withDestinationURL: file)
        let folder = LibraryFolder(url: directory)
        let scanner = LibraryScanner(artworkDirectory: directory.appendingPathComponent("Artwork"))
        let result = try await scanner.scan(folder, existing: []) { _ in }
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(result.tracks[0].title, "Song")
        XCTAssertEqual(result.tracks[0].artist, "Artist")
        XCTAssertEqual(result.tracks[0].duration, 1, accuracy: 0.01)
        let again = try await scanner.scan(folder, existing: result.tracks) { _ in }
        XCTAssertEqual(again.tracks, result.tracks)
    }

    func testSearchMatchesAllTermsAcrossFields() {
        let track = Track(url: directory.appendingPathComponent("song.flac"), folderID: UUID(), title: "夜曲", artist: "周杰伦", album: "十一月的萧邦")
        XCTAssertTrue(track.matches("周杰伦 夜曲"))
        XCTAssertFalse(track.matches("周杰伦 晴天"))
    }
}

func makeTone(at url: URL, seconds: Double = 1) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let count = AVAudioFrameCount(44_100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    for channel in 0..<2 {
        for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = 0.1 * sin(2 * .pi * 440 * Float(frame) / 44_100) }
    }
    var fileSettings = format.settings
    fileSettings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: url, settings: fileSettings)
    try file.write(from: buffer)
}
