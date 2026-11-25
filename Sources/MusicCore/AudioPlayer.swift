import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Observation

@MainActor @Observable
public final class AudioPlayer {
    public private(set) var isPlaying = false
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var loadedID: String?
    public private(set) var error: String?
    public var onEnded: (() -> Void)?
    public var onAdvanced: ((String) -> Void)?
    public var onStateChanged: (() -> Void)?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    @ObservationIgnored private let gains = [AVAudioUnitEQ(numberOfBands: 0), AVAudioUnitEQ(numberOfBands: 0)]
    @ObservationIgnored private let mix = AVAudioMixerNode()
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: EQSettings.frequencies.count)
    @ObservationIgnored private var current: Deck?
    @ObservationIgnored private var standby: Deck?
    @ObservationIgnored private var fading: Deck?
    @ObservationIgnored private var nextTrack: Track?
    @ObservationIgnored private var nextGain: Float = 0
    @ObservationIgnored private var transition: TransitionMode = .gapless
    @ObservationIgnored private var fadeSeconds: Double = 3
    @ObservationIgnored private var startsAt: UInt64 = 0
    @ObservationIgnored private var overlap: Double = 0
    @ObservationIgnored private var attemptedPreparation = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var settings = EQSettings()
    @ObservationIgnored private var currentVolume: Float = 0.7
    @ObservationIgnored private var eqRamp: Task<Void, Never>?
    @ObservationIgnored private var selectedDevice: AudioDeviceID?

    private struct Deck {
        var token: UUID
        var track: Track
        var index: Int
        var base: Double
        var gain: Float
        var stream: PCMStream
    }

    public init() {
        engine.attach(mix); engine.attach(equalizer)
        for index in 0..<2 {
            engine.attach(nodes[index]); engine.attach(gains[index])
            engine.connect(nodes[index], to: gains[index], format: PCMReader.format)
            engine.connect(gains[index], to: mix, fromBus: 0, toBus: AVAudioNodeBus(index), format: PCMReader.format)
        }
        engine.connect(mix, to: equalizer, format: PCMReader.format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: PCMReader.format)
        EqualizerDSP.configure(equalizer, settings: settings)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverConfiguration() }
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit {
        eqRamp?.cancel(); timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        current?.stream.cancel(); standby?.stream.cancel(); fading?.stream.cancel()
    }

    public func load(_ track: Track, at seconds: Double = 0, autoplay: Bool = true, gain: Float = 0) throws {
        eqRamp?.cancel()
        current?.stream.cancel(); current = nil
        cancelUpcoming(); finishFade()
        isPlaying = false; loadedID = nil
        do {
            let deck = try makeDeck(track, index: 0, seconds: seconds.isFinite ? max(0, seconds) : 0, gain: gain)
            current = deck; duration = deck.stream.reader.duration
            position = deck.base; loadedID = track.id; error = nil
            EqualizerDSP.configure(equalizer, settings: settings)
            engine.mainMixerNode.outputVolume = currentVolume
            if autoplay { try play() }
        } catch {
            duration = 0; position = 0; self.error = error.localizedDescription
            throw error
        }
    }
    public func play() throws {
        guard let deck = current else { return }
        if position >= duration { try load(deck.track, autoplay: false, gain: deck.gain) }
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            if let current { nodes[current.index].play() }
            isPlaying = true; error = nil; onStateChanged?()
        } catch { self.error = error.localizedDescription; throw error }
    }
    public func pause() {
        tick(); cancelUpcoming(); finishFade()
        if let current { nodes[current.index].pause() }
        isPlaying = false; onStateChanged?()
    }
    public func stop() {
        cancelUpcoming(); finishFade(); current?.stream.cancel(); current = nil
        engine.stop(); isPlaying = false; position = 0; duration = 0; loadedID = nil
        onStateChanged?()
    }
    public func seek(to seconds: Double) throws {
        guard let deck = current, seconds.isFinite else { return }
        let wasPlaying = isPlaying
        try load(deck.track, at: min(max(0, seconds), max(0, duration - 0.001)), autoplay: wasPlaying, gain: deck.gain)
        onStateChanged?()
    }
    public func setVolume(_ volume: Float) {
        currentVolume = volume.isFinite ? min(1, max(0, volume)) : 0.7
        engine.mainMixerNode.outputVolume = currentVolume
    }
    public func setLoudnessGain(_ gain: Float) {
        guard var deck = current else { return }
        deck.gain = gain.isFinite ? min(12, max(-30, gain)) : 0
        current = deck; gains[deck.index].globalGain = deck.gain
    }
    public func setUpcoming(_ track: Track?, mode: TransitionMode, seconds: Double, gain: Float) {
        if nextTrack?.id != track?.id || transition != mode || fadeSeconds != seconds || nextGain != gain { cancelUpcoming() }
        nextTrack = track; transition = mode
        fadeSeconds = seconds.isFinite ? min(10, max(0.2, seconds)) : 3
        nextGain = gain.isFinite ? min(12, max(-30, gain)) : 0
    }
    public func setOutputDevice(_ id: AudioDeviceID) throws {
        guard selectedDevice != id, let unit = engine.outputNode.audioUnit else { return }
        let saved = current, savedPosition = position, wasPlaying = isPlaying
        engine.stop()
        var device = id
        let code = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard code == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
        selectedDevice = id
        if let saved { try load(saved.track, at: savedPosition, autoplay: wasPlaying, gain: saved.gain) }
    }
    public func apply(_ value: EQSettings) {
        eqRamp?.cancel(); settings = value; settings.normalize()
        guard isPlaying else { EqualizerDSP.configure(equalizer, settings: settings); return }
        let start = equalizer.bypass ? Array(repeating: Float(0), count: 10) : equalizer.bands.map(\.gain)
        let preamp: Float = equalizer.bypass ? 0 : equalizer.globalGain
        let target = settings.enabled ? settings.gains : Array(repeating: Float(0), count: 10)
        equalizer.bypass = false
        eqRamp = Task { [weak self] in
            for step in 1...15 {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self else { return }
                let fraction = Float(step) / 15
                for (index, band) in self.equalizer.bands.enumerated() { band.gain = start[index] + (target[index] - start[index]) * fraction }
                self.equalizer.globalGain = preamp + (self.settings.effectivePreamp - preamp) * fraction
            }
            guard let self else { return }; self.equalizer.bypass = !self.settings.enabled
        }
    }
    private func makeDeck(_ track: Track, index: Int, seconds: Double, gain: Float) throws -> Deck {
        let token = UUID()
        let stream = try PCMStream(url: track.url, seconds: seconds, node: nodes[index]) { [weak self] failure in
            Task { @MainActor [weak self] in self?.ended(token, failure: failure) }
        }
        let base = min(max(0, seconds), max(0, stream.reader.duration - 1 / PCMReader.format.sampleRate))
        gains[index].globalGain = gain.isFinite ? min(12, max(-30, gain)) : 0
        nodes[index].volume = 1
        try stream.prime()
        return Deck(token: token, track: track, index: index, base: base, gain: gain, stream: stream)
    }
    private func cancelUpcoming() {
        standby?.stream.cancel(); standby = nil; attemptedPreparation = false
    }
    private func finishFade() {
        fading?.stream.cancel(); fading = nil
        if let current { nodes[current.index].volume = 1 }
    }
    private func prepareUpcoming(_ deck: Deck) {
        guard let track = nextTrack, transition != .off, standby == nil, fading == nil, !attemptedPreparation,
              duration - position <= max(6, fadeSeconds + 2), let render = nodes[deck.index].lastRenderTime,
              let clock = nodes[deck.index].playerTime(forNodeTime: render) else { return }
        attemptedPreparation = true
        do {
            let next = try makeDeck(track, index: 1 - deck.index, seconds: 0, gain: nextGain)
            let remaining = duration - deck.base - Double(clock.sampleTime) / clock.sampleRate
            overlap = transition == .crossfade ? min(fadeSeconds, duration / 2, next.stream.reader.duration / 2) : 0
            let delay = max(0, remaining - overlap)
            startsAt = render.hostTime + AVAudioTime.hostTime(forSeconds: delay)
            standby = next; nodes[next.index].volume = overlap > 0 ? 0 : 1
            nodes[next.index].play(at: AVAudioTime(hostTime: startsAt))
        } catch { self.error = "下一首预缓冲失败，将尝试普通切换：\(error.localizedDescription)" }
    }
    private func promoteUpcoming() {
        guard let next = standby else { return }
        let old = current; current = next; standby = nil
        loadedID = next.track.id; duration = next.stream.reader.duration; position = 0
        if overlap > 0 { fading = old }
        else { old?.stream.cancel(); nodes[next.index].volume = 1 }
        attemptedPreparation = false; nextTrack = nil
        onAdvanced?(next.track.id); onStateChanged?()
    }
    private func ended(_ token: UUID, failure: Error?) {
        if standby?.token == token {
            standby?.stream.cancel(); standby = nil
            if let failure { error = failure.localizedDescription }
            return
        }
        guard current?.token == token else { return }
        if let failure { stop(); error = failure.localizedDescription; return }
        guard isPlaying else { return }
        if standby != nil { promoteUpcoming(); return }
        position = duration; isPlaying = false; finishFade(); onEnded?(); onStateChanged?()
    }
    private func tick() {
        guard isPlaying, let deck = current else { return }
        if let render = nodes[deck.index].lastRenderTime, let clock = nodes[deck.index].playerTime(forNodeTime: render), clock.sampleRate > 0 {
            position = min(duration, max(deck.base, deck.base + Double(clock.sampleTime) / clock.sampleRate))
        }
        if standby != nil, mach_absolute_time() >= startsAt { promoteUpcoming() }
        if let fading, let current {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time() - min(mach_absolute_time(), startsAt))
            let fraction = Float(min(1, max(0, elapsed / max(0.001, overlap))))
            nodes[current.index].volume = fraction; nodes[fading.index].volume = 1 - fraction
            if fraction >= 1 { finishFade() }
        }
        if let current { prepareUpcoming(current) }
    }
    private func recoverConfiguration() {
        guard !engine.isRunning, let saved = current else { return }
        let savedPosition = position, resume = isPlaying
        do { try load(saved.track, at: savedPosition, autoplay: resume, gain: saved.gain) }
        catch { self.error = "音频设备切换失败：\(error.localizedDescription)"; onStateChanged?() }
    }
}
