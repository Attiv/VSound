import AVFoundation
import Foundation

public struct EQPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var symbol: String
    public var gains: [Float]
    public init(_ id: String, _ name: String, _ subtitle: String, _ symbol: String, _ gains: [Float]) {
        precondition(gains.count == EQSettings.frequencies.count)
        self.id = id; self.name = name; self.subtitle = subtitle; self.symbol = symbol; self.gains = gains
    }
    public static let builtIn: [EQPreset] = [
        .init("flat", "原声", "忠于原本的声音", "waveform", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init("harman-style", "哈曼卡顿风格", "饱满低频 · 清晰人声 · 通透高频", "hifispeaker.fill", [2.5, 3.5, 2, 0, -1, 0, 1, 2, 1.5, 0.5]),
        .init("pop", "流行", "节奏鲜明，日常耐听", "music.note", [1.5, 2, 1, -0.5, -0.5, 0.5, 1.5, 2, 1, 0.5]),
        .init("vocal", "人声", "让每一句都更靠近", "mic.fill", [-1.5, -1, -0.5, 0, 1, 2.5, 3, 1.5, 0, -0.5]),
        .init("rock", "摇滚", "鼓点有力，吉他鲜明", "guitars.fill", [2.5, 3, 1.5, -1, -1.5, 0, 1.5, 2.5, 2, 1]),
        .init("jazz", "爵士", "温润、松弛，有层次", "pianokeys", [1, 1.5, 0.5, 0, -0.5, 0.5, 1.5, 1, 1, 0.5]),
        .init("classical", "古典", "克制修饰，舒展细节", "music.quarternote.3", [0.5, 0.5, 0, 0, -0.5, 0, 0.5, 1, 1.5, 1]),
        .init("electronic", "电子", "更深的下潜，更亮的节奏", "bolt.fill", [4, 4, 2, 0, -1, -1, 0.5, 2, 3, 2]),
        .init("night", "深夜", "轻柔低频，收敛高频", "moon.stars.fill", [-2, -1, 0, 0.5, 1, 1, 0.5, 0, -1, -2])
    ]
}

enum EqualizerDSP {
    static func configure(_ unit: AVAudioUnitEQ, settings: EQSettings) {
        var safe = settings
        safe.normalize()
        precondition(unit.bands.count == EQSettings.frequencies.count)
        for (index, band) in unit.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EQSettings.frequencies[index]
            band.bandwidth = 1
            band.gain = safe.gains[index]
            band.bypass = false
        }
        unit.globalGain = safe.effectivePreamp
        unit.bypass = !safe.enabled
    }
}

public struct SavedEQPreset: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var gains: [Float]
    public init(name: String, gains: [Float]) { id = UUID().uuidString; self.name = name; self.gains = gains }
}

public struct EQSettings: Codable, Equatable, Sendable {
    public static let frequencies: [Float] = [31, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public var enabled = false
    public var presetID = "flat"
    public var gains: [Float] = Array(repeating: 0, count: 10)
    public var preamp: Float = 0
    public var autoHeadroom = true
    public init() {}

    public mutating func normalize() {
        gains = (0..<Self.frequencies.count).map { index in
            let value = index < gains.count ? gains[index] : 0
            return value.isFinite ? min(12, max(-12, value)) : 0
        }
        preamp = preamp.isFinite ? min(0, max(-24, preamp)) : 0
    }

    public var effectivePreamp: Float {
        guard enabled else { return 0 }
        guard autoHeadroom else { return preamp }
        // Summing positive gains is a conservative bound even when adjacent bands overlap.
        let headroom = gains.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        return min(preamp, -headroom)
    }
}
