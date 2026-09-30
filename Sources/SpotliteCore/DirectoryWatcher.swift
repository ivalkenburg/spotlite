import Foundation

/// Watches application roots with coalesced FSEvents and no idle polling.
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    var isWatching: Bool { stream != nil }
    private let queue = DispatchQueue(label: "com.igorv.spotlite.fsevents")

    /// Owned by the stream, independently of the watcher. An in-flight callback never
    /// dereferences a watcher that the main actor may be replacing.
    private final class CallbackContext {
        let roots: [String]
        let ignoredPaths: [String]
        let onChange: @Sendable () -> Void

        init(roots: [String], ignoredPaths: [String], onChange: @escaping @Sendable () -> Void) {
            // Include canonical roots because FSEvents may report resolved symlink paths.
            self.roots = Array(Set(roots + roots.map { DirectoryWatcher.canonicalPath($0) }))
            self.ignoredPaths = Array(Set(ignoredPaths + ignoredPaths.map { DirectoryWatcher.canonicalPath($0) }))
            self.onChange = onChange
        }
    }

    public init(paths: [String], ignoredPaths: [String] = [], latency: CFTimeInterval = 2.0,
                onChange: @escaping @Sendable () -> Void) {
        guard !paths.isEmpty else { return }
        let callbackContext = CallbackContext(roots: paths, ignoredPaths: ignoredPaths, onChange: onChange)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            guard let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String], changed.count == count else {
                context.onChange()
                return
            }
            for index in changed.indices {
                if DirectoryWatcher.shouldRefresh(path: changed[index], flags: flags[index],
                                                   roots: context.roots, ignoredPaths: context.ignoredPaths) {
                    context.onChange()
                    return
                }
            }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackContext>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                              paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                              latency, FSEventStreamCreateFlags(options)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            NSLog("Spotlite: could not start application-directory watcher")
            return
        }
        self.stream = stream
    }

    /// realpath keeps the spelling emitted by FSEvents (e.g. /private/var), whereas
    /// Foundation can shorten existing paths to /var but leave deleted paths unchanged.
    /// Resolve the nearest existing ancestor for a cache/support directory not yet created.
    static func canonicalPath(_ path: String) -> String {
        var ancestor = path
        var missing: [String] = []
        while true {
            if let resolved = realpath(ancestor, nil) {
                defer { free(resolved) }
                let prefix = String(cString: resolved)
                let suffix = missing.reversed().joined(separator: "/")
                return suffix.isEmpty ? prefix : prefix + (prefix == "/" ? "" : "/") + suffix
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != ancestor else { return path }
            missing.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
    }

    /// Match scan depth, while retaining updates anywhere inside an indexed app bundle.
    /// Ignore our own persistence and unrelated deep paths when a user watches home or /.
    static func shouldRefresh(path: String, flags: FSEventStreamEventFlags = 0,
                              roots: [String], ignoredPaths: [String] = []) -> Bool {
        let mustRescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        if flags & FSEventStreamEventFlags(mustRescan) != 0 { return true }
        // FSEvents supplies absolute paths. Preserve their physical spelling for
        // both existing and deleted files; Foundation standardization can differ.
        func contains(_ ancestor: String, _ child: String) -> Bool {
            ancestor == child || child.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
        }
        if ignoredPaths.contains(where: { contains($0, path) }) { return false }
        var associatedWithRoot = false
        for root in roots {
            // A parent event can invalidate the root itself (e.g. volume removal).
            if contains(path, root) { return true }
            guard contains(root, path) else { continue }
            associatedWithRoot = true
            let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
            let parts = relative.split(separator: "/", maxSplits: 2)
            guard let first = parts.first else { return true }
            if first.hasSuffix(".app") { return true }
            if parts.count == 1 { return true }
            if first.hasPrefix(".") { continue }
            if parts.count == 2 || parts[1].hasSuffix(".app") { return true }
        }
        // A stream can report canonical paths outside a configured symlink spelling.
        // Unknown paths are conservative refreshes, never silently missed updates.
        return !associatedWithRoot
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
