import Foundation

/// Watches the application directories with FSEvents.
///
/// The 2-second latency is deliberate: dragging an app into /Applications produces
/// dozens of filesystem events, and coalescing them means one rescan instead of forty.
/// While nothing changes, the stream costs no CPU at all.
public final class DirectoryWatcher {

    private var stream: FSEventStreamRef?
    var isWatching: Bool { stream != nil }
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.igorv.spotlite.fsevents")

    public init(paths: [String], latency: CFTimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            NSLog("Spotlite: could not start application-directory watcher")
            return
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
