import CoreServices
import Foundation

public final class LibraryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.vsound.library-events", qos: .utility)
    private var pending: DispatchWorkItem?
    private let changed: @Sendable () -> Void
    public init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    deinit { stop() }
    public func watch(_ folders: [URL]) {
        stop()
        let paths = Array(Set(folders.map { $0.standardizedFileURL.path })).sorted()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                              FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    public func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        queue.sync { pending?.cancel(); pending = nil }
    }
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.changed() }
        pending = work
        queue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
