import Foundation

public enum LoudnessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, track, album
    public var id: String { rawValue }
    public var title: String { switch self { case .off: "关闭"; case .track: "单曲响度"; case .album: "专辑响度" } }
}

public enum TransitionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case gapless, crossfade, off
    public var id: String { rawValue }
    public var title: String { switch self { case .gapless: "无缝衔接"; case .crossfade: "交叉淡入淡出"; case .off: "普通切换" } }
}

public struct DesktopLyricsSettings: Codable, Sendable {
    public var enabled = false
    public var locked = false
    public var fontSize: Double = 28
    public var opacity: Double = 0.9
    public var showsTranslation = true
    public init() {}
}

public struct DeviceAudioProfile: Codable, Sendable {
    public var equalizer: EQSettings
    public var volume: Float
    public init(equalizer: EQSettings, volume: Float) { self.equalizer = equalizer; self.volume = volume }
}

public struct PlayerPreferences: Codable, Sendable {
    public var watchesFolders = true
    public var loudness: LoudnessMode = .off
    public var transition: TransitionMode = .gapless
    public var crossfadeSeconds: Double = 3
    public var desktopLyrics = DesktopLyricsSettings()
    public var deviceProfiles: [String: DeviceAudioProfile] = [:]
    public var selectedDeviceUID: String?
    public var checksUpdatesAutomatically = false
    public var lyricSources: [LyricSource] = LyricSource.allCases
    public init() {}
}
