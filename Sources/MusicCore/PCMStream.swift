import AVFoundation
import Foundation

final class PCMReader {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let duration: Double
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private var exhausted = false
    init(url: URL, seconds: Double) throws {
        file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: file.processingFormat, to: Self.format) else { throw CocoaError(.fileReadCorruptFile) }
        self.converter = converter
        duration = Double(file.length) / file.processingFormat.sampleRate
        let safe = seconds.isFinite ? min(max(0, seconds), max(0, duration - 1 / file.processingFormat.sampleRate)) : 0
        file.framePosition = min(file.length - 1, AVAudioFramePosition(safe * file.processingFormat.sampleRate))
        converter.primeMethod = .normal
    }
    func read() throws -> AVAudioPCMBuffer? {
        let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 8192)!
        var conversionError: NSError?, readingError: Error?
        let status = converter.convert(to: output, error: &conversionError) { requested, state in
            if self.exhausted || self.file.framePosition >= self.file.length {
                self.exhausted = true; state.pointee = .endOfStream; return nil
            }
            do {
                let count = min(65_536, max(1, requested))
                let input = AVAudioPCMBuffer(pcmFormat: self.file.processingFormat, frameCapacity: count)!
                try self.file.read(into: input, frameCount: count)
                if input.frameLength == 0 { self.exhausted = true; state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return input
            } catch { readingError = error; state.pointee = .endOfStream; return nil }
        }
        if let readingError { throw readingError }
        if let conversionError { throw conversionError }
        guard status != .error else { throw CocoaError(.fileReadCorruptFile) }
        return output.frameLength > 0 ? output : nil
    }
}

final class PCMStream: @unchecked Sendable {
    let reader: PCMReader
    private let node: AVAudioPlayerNode
    private let queue = DispatchQueue(label: "app.vsound.pcm-decoding", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var completionSent = false
    private var pending: AVAudioPCMBuffer?
    private let finished: @Sendable (Error?) -> Void
    init(url: URL, seconds: Double, node: AVAudioPlayerNode, finished: @escaping @Sendable (Error?) -> Void) throws {
        reader = try PCMReader(url: url, seconds: seconds); self.node = node; self.finished = finished
        pending = try reader.read()
        guard pending != nil else { throw CocoaError(.fileReadCorruptFile) }
    }
    func prime() throws {
        try fillOne()
        queue.async { [weak self] in
            do { for _ in 0..<5 { try self?.fillOne() } }
            catch { self?.finish(error) }
        }
    }
    func cancel() {
        lock.withLock { cancelled = true }
        node.stop()
    }
    private func fillOne() throws {
        guard lock.withLock({ !cancelled }), let buffer = pending else { return }
        pending = try reader.read()
        let last = pending == nil
        lock.withLock {
            guard !cancelled else { return }
            node.scheduleBuffer(buffer, completionCallbackType: last ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
                guard let self else { return }
                if last { self.finish(nil) }
                else {
                    self.queue.async { [weak self] in
                        do { try self?.fillOne() } catch { self?.finish(error) }
                    }
                }
            }
        }
    }
    private func finish(_ error: Error?) {
        let shouldSend = lock.withLock {
            guard !cancelled, !completionSent else { return false }
            completionSent = true; return true
        }
        if shouldSend { finished(error) }
    }
}
