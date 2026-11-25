import AVFoundation
import Foundation
@testable import MusicCore
import XCTest

final class AudioTests: XCTestCase {
    func testEqualizerActuallyChangesRenderedAudio() throws {
        var settings = EQSettings()
        settings.autoHeadroom = false
        let flat = try renderedRMS(settings)
        settings.enabled = true
        settings.gains[5] = 6
        let boosted = try renderedRMS(settings)
        let decibels = 20 * log10(boosted / flat)
        XCTAssertEqual(decibels, 6, accuracy: 0.5, "The native EQ must affect actual PCM samples.")
        settings.enabled = false
        XCTAssertEqual(try renderedRMS(settings), flat, accuracy: 0.0001)
    }

    @MainActor
    func testPlaybackPauseSeekAndCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone.wav")
        try makeTone(at: url)
        let player = AudioPlayer()
        defer { player.stop(); try? FileManager.default.removeItem(at: directory) }
        player.setVolume(0)
        let track = Track(url: url, folderID: UUID(), title: "Lifecycle test")
        try player.load(track, autoplay: false)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.loadedID, track.id)
        XCTAssertEqual(player.duration, 1, accuracy: 0.01)
        try player.seek(to: 0.25)
        XCTAssertEqual(player.position, 0.25, accuracy: 0.001)
        try player.play()
        try await Task.sleep(for: .milliseconds(140))
        player.pause()
        XCTAssertFalse(player.isPlaying)
        let paused = player.position
        XCTAssertGreaterThan(paused, 0.25)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.position, paused, accuracy: 0.002)
        let ended = expectation(description: "Playback reaches the real audio end")
        player.onEnded = { ended.fulfill() }
        try player.seek(to: 0.85)
        try player.play()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.001)
    }

    @MainActor
    func testMissingAudioFailsWithoutLeavingAPlayingState() throws {
        let player = AudioPlayer()
        let missing = Track(url: URL(fileURLWithPath: "/nonexistent-vsound-test.wav"), folderID: UUID(), title: "Missing")
        XCTAssertThrowsError(try player.load(missing))
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.loadedID)
        XCTAssertNotNil(player.error)
    }

    private func renderedRMS(_ settings: EQSettings) throws -> Double {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine(), source = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        engine.attach(source); engine.attach(eq)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        EqualizerDSP.configure(eq, settings: settings)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        input.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 { input.floatChannelData![channel][frame] = 0.1 * sin(2 * .pi * 1_000 * Float(frame) / 48_000) }
        }
        source.scheduleBuffer(input)
        try engine.start(); source.play()
        defer { source.stop(); engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var sum = 0.0, count = 0
        for block in 0..<10 {
            let status = try engine.renderOffline(4096, to: output)
            XCTAssertEqual(status, .success)
            guard block > 1 else { continue }
            for frame in 0..<Int(output.frameLength) {
                let sample = Double(output.floatChannelData![0][frame])
                XCTAssertTrue(sample.isFinite)
                sum += sample * sample; count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        return sqrt(sum / Double(max(1, count)))
    }
}
