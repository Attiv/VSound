import AVFoundation
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
    public var onStateChanged: (() -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: EQSettings.frequencies.count)
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var baseFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var settings = EQSettings()
    @ObservationIgnored private var currentVolume: Float = 0.7
    @ObservationIgnored private var eqRamp: Task<Void, Never>?

    public init() {
        engine.attach(node)
        engine.attach(equalizer)
        configureEQ()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverConfiguration() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    deinit {
        eqRamp?.cancel()
        timer?.invalidate()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    public func load(_ track: Track, at seconds: Double = 0, autoplay: Bool = true) throws {
        eqRamp?.cancel()
        invalidateSchedule()
        isPlaying = false
        loadedID = nil
        engine.stop()
        do {
            let nextFile = try AVAudioFile(forReading: track.url)
            guard nextFile.processingFormat.sampleRate > 0, nextFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            file = nextFile
            duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(equalizer)
            engine.connect(node, to: equalizer, format: nextFile.processingFormat)
            engine.connect(equalizer, to: engine.mainMixerNode, format: nextFile.processingFormat)
            engine.mainMixerNode.outputVolume = currentVolume
            configureEQ()
            loadedID = track.id
            error = nil
            schedule(at: seconds)
            if autoplay { try play() }
        } catch {
            file = nil; duration = 0; position = 0
            self.error = error.localizedDescription
            throw error
        }
    }

    public func play() throws {
        guard file != nil else { return }
        if position >= duration { schedule(at: 0) }
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            node.play()
            isPlaying = true
            error = nil
            onStateChanged?()
        } catch { self.error = error.localizedDescription; throw error }
    }

    public func pause() {
        tick()
        node.pause()
        isPlaying = false
        onStateChanged?()
    }

    public func stop() {
        invalidateSchedule()
        engine.stop()
        isPlaying = false; position = 0; duration = 0; loadedID = nil; file = nil
        onStateChanged?()
    }

    public func seek(to seconds: Double) throws {
        guard file != nil, seconds.isFinite else { return }
        let wasPlaying = isPlaying
        schedule(at: min(max(0, seconds), max(0, duration - 0.001)))
        if wasPlaying { try play() }
        onStateChanged?()
    }

    public func setVolume(_ volume: Float) {
        currentVolume = volume.isFinite ? min(1, max(0, volume)) : 0.7
        engine.mainMixerNode.outputVolume = currentVolume
    }

    public func apply(_ value: EQSettings) {
        eqRamp?.cancel()
        settings = value
        settings.normalize()
        guard isPlaying else { configureEQ(); return }
        let start = equalizer.bypass ? Array(repeating: Float(0), count: 10) : equalizer.bands.map(\.gain)
        let startPreamp: Float = equalizer.bypass ? 0 : equalizer.globalGain
        let target = settings.enabled ? settings.gains : Array(repeating: Float(0), count: 10)
        let targetPreamp = settings.effectivePreamp
        for (index, band) in equalizer.bands.enumerated() { band.gain = start[index] }
        equalizer.globalGain = startPreamp
        equalizer.bypass = false
        eqRamp = Task { [weak self] in
            for step in 1...15 {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self else { return }
                let fraction = Float(step) / 15
                for (index, band) in self.equalizer.bands.enumerated() {
                    band.gain = start[index] + (target[index] - start[index]) * fraction
                }
                self.equalizer.globalGain = startPreamp + (targetPreamp - startPreamp) * fraction
            }
            guard let self else { return }
            self.equalizer.bypass = !self.settings.enabled
        }
    }

    private func configureEQ() {
        EqualizerDSP.configure(equalizer, settings: settings)
    }

    private func invalidateSchedule() {
        generation = UUID()
        node.stop()
    }

    private func schedule(at seconds: Double) {
        guard let file else { return }
        invalidateSchedule()
        let rate = file.processingFormat.sampleRate
        let safe = seconds.isFinite ? max(0, min(seconds, duration - 1 / rate)) : 0
        baseFrame = min(file.length - 1, AVAudioFramePosition(safe * rate))
        position = Double(baseFrame) / rate
        let token = generation
        let count = min(file.length - baseFrame, AVAudioFramePosition(UInt32.max))
        node.scheduleSegment(file, startingFrame: baseFrame, frameCount: AVAudioFrameCount(count), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isPlaying else { return }
                if self.baseFrame + count < file.length {
                    self.schedule(at: Double(self.baseFrame + count) / rate)
                    try? self.play()
                } else {
                    self.position = self.duration
                    self.isPlaying = false
                    self.onEnded?()
                    self.onStateChanged?()
                }
            }
        }
    }

    private func tick() {
        guard isPlaying, let file, let render = node.lastRenderTime,
              let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return }
        position = min(duration, max(0, Double(baseFrame) / file.processingFormat.sampleRate + Double(time.sampleTime) / time.sampleRate))
    }

    private func recoverConfiguration() {
        guard file != nil else { return }
        let shouldResume = isPlaying
        let saved = position
        isPlaying = false
        schedule(at: saved)
        if shouldResume {
            do { try play() }
            catch { self.error = "音频设备切换失败：\(error.localizedDescription)"; onStateChanged?() }
        }
    }
}
