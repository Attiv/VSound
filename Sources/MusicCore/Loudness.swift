import AVFoundation
import Foundation

public struct LoudnessRecord: Codable, Sendable {
    public var lufs: Double
    public var peak: Double
    public var albumGain: Float
    public var albumPeak: Double
    public var modifiedAt: Date?
    public var fileSize: Int64
    public func isCurrent(for track: Track) -> Bool { modifiedAt == track.modifiedAt && fileSize == track.fileSize }
    public func gain(for mode: LoudnessMode) -> Float {
        guard mode != .off, lufs > -70 else { return 0 }
        let requested = mode == .album ? albumGain : Float(-18 - lufs)
        let maximumPeak = mode == .album ? albumPeak : peak
        let safe = maximumPeak > 0 ? Float(-1 - 20 * log10(maximumPeak)) : 0
        return requested.isFinite ? min(12, max(-30, min(requested, safe))) : 0
    }
}

private struct WeightingFilter {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ input: Double) -> Double {
        let value = b0 * input + z1
        z1 = b1 * input - a1 * value + z2
        z2 = b2 * input - a2 * value
        return value
    }
    static func kWeighting(rate: Double) -> [Self] {
        // BS.1770 K-weighting: shelf followed by RLB high-pass, bilinear-transformed at the file rate.
        let k = tan(.pi * 1681.974450955533 / rate), q = 0.7071752369554196
        let high = pow(10, 3.999843853973347 / 20), middle = pow(high, 0.4996667741545416)
        let d = 1 + k / q + k * k
        let shelf = Self(b0: (high + middle * k / q + k * k) / d,
                         b1: 2 * (k * k - high) / d, b2: (high - middle * k / q + k * k) / d,
                         a1: 2 * (k * k - 1) / d, a2: (1 - k / q + k * k) / d)
        let h = tan(.pi * 38.13547087602444 / rate), r = 0.5003270373238773, hd = 1 + h / r + h * h
        return [shelf, Self(b0: 1, b1: -2, b2: 1, a1: 2 * (h * h - 1) / hd, a2: (1 - h / r + h * h) / hd)]
    }
}

public actor LoudnessAnalyzer {
    public init() {}
    public func analyze(_ tracks: [Track], progress: @Sendable (Int, Int) async -> Void) async throws -> [String: LoudnessRecord] {
        let albums = Dictionary(grouping: tracks) { $0.album == "未知专辑" ? $0.id : $0.albumID }
        var result: [String: LoudnessRecord] = [:], completed = 0
        for group in albums.values {
            var measured: [(Track, [Double], Double)] = []
            for track in group {
                try Task.checkCancellation()
                let (blocks, peak) = try Self.measure(track.url)
                measured.append((track, blocks, peak)); completed += 1
                await progress(completed, tracks.count)
            }
            let albumLUFS = Self.integrated(measured.flatMap { $0.1 })
            let albumPeak = measured.map { $0.2 }.max() ?? 0
            for (track, blocks, peak) in measured {
                result[track.id] = LoudnessRecord(lufs: Self.integrated(blocks), peak: peak,
                    albumGain: albumLUFS > -70 ? Float(-18 - albumLUFS) : 0, albumPeak: albumPeak,
                    modifiedAt: track.modifiedAt, fileSize: track.fileSize)
            }
        }
        return result
    }

    static func integrated(_ energies: [Double]) -> Double {
        let absolute = pow(10, (-70 + 0.691) / 10)
        let audible = energies.filter { $0.isFinite && $0 > absolute }
        guard !audible.isEmpty else { return -100 }
        let relative = audible.reduce(0, +) / Double(audible.count) * 0.1
        let gated = audible.filter { $0 >= relative }
        guard !gated.isEmpty else { return -100 }
        return -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }

    private static func measure(_ url: URL) throws -> ([Double], Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        guard rate >= 8_000, rate <= 384_000, (1...2).contains(channels), file.length > 0 else {
            throw NSError(domain: "VSound.Loudness", code: 1, userInfo: [NSLocalizedDescriptionKey: "响度分析仅支持 8–384 kHz 单声道或立体声音乐：\(url.lastPathComponent)"])
        }
        let step = max(1, Int((rate * 0.1).rounded())), window = step * 4
        var ring = [Double](repeating: 0, count: window), filters = (0..<channels).map { _ in WeightingFilter.kWeighting(rate: rate) }
        var frame = 0, sum = 0.0, peak = 0.0, blocks: [Double] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: 16_384)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for index in 0..<Int(buffer.frameLength) {
                var energy = 0.0
                for channel in 0..<channels {
                    let value = Double(data[channel][index].isFinite ? data[channel][index] : 0)
                    peak = max(peak, abs(value))
                    let shelf = filters[channel][0].process(value)
                    let weighted = filters[channel][1].process(shelf)
                    energy += weighted * weighted
                }
                let slot = frame % window
                sum += energy - ring[slot]; ring[slot] = energy; frame += 1
                if frame >= window, (frame - window).isMultiple(of: step) { blocks.append(max(0, sum / Double(window))) }
            }
        }
        if blocks.isEmpty, frame > 0 { blocks.append(max(0, sum / Double(frame))) }
        return (blocks, peak)
    }
}
