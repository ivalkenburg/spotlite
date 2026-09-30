import Foundation
import SpotliteCore

/// The indexed apps and their launch history: loading the cached index, keeping it
/// current, and bounding launch history. Spotlite's own commands and the
/// user's links are listed beside the index, never cached with it.
@MainActor
final class AppLibrary {

    private var directories: [URL]

    init(directories: [String]) {
        self.directories = AppIndex.normalizedDirectories(directories)
    }

    func setDirectories(_ paths: [String]) {
        let updated = AppIndex.normalizedDirectories(paths)
        guard updated != directories else { return }
        directories = updated
        guard hasLoaded else { return }
        watcher = nil
        startWatching()
        fingerprint = AppIndex.directoriesFingerprint(directories: directories)
        // Removed roots must disappear immediately, including while a previous scan finishes.
        indexed = indexed.filter {
            $0.kind != .app || AppIndex.includesApplication(at: $0.url, directories: directories)
        }
        combine()
        onChange?(entries, true)
        refresh()
    }

    /// The index plus `extras`, sorted by name.
    private(set) var entries: [AppEntry] = []
    /// What the last scan found.
    private var indexed: [AppEntry] = []
    /// Commands and links. Setting them reports a change like a fresh scan does.
    var extras: [AppEntry] = [] {
        didSet {
            combine()
            onChange?(entries, false)
        }
    }
    private(set) var frecency = Storage.loadFrecency()
    /// The Bool is true after a disk scan, when cached icons may have changed at
    /// paths whose app names and bundle identifiers stayed the same.
    var onChange: (([AppEntry], Bool) -> Void)?

    private var watcher: DirectoryWatcher?
    private var fingerprint: [String: Date] = [:]
    private var hasLoaded = false
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false

    /// Loads the index on first use and starts watching; on later calls does the cheap
    /// staleness check that catches changes FSEvents missed while the machine was asleep.
    /// True when this call installed the cached index, which `onChange` does not report.
    @discardableResult
    func loadIfNeeded() -> Bool {
        guard hasLoaded else {
            hasLoaded = true
            indexed = AppIndex.loadCached(directories: directories) ?? []
            combine()
            capFrecency()
            fingerprint = AppIndex.directoriesFingerprint(directories: directories)
            startWatching()
            // Cached results make the first frame immediate; this scan guarantees that
            // changes made while Spotlite was not running are still discovered.
            refresh()
            return true
        }

        let current = AppIndex.directoriesFingerprint(directories: directories)
        guard current != fingerprint else { return false }
        fingerprint = current
        refresh()
        return false
    }

    /// Coalesces refresh requests and keeps bundle traversal plus cache writes off the
    /// main actor. Only complete immutable snapshots cross back into the UI.
    func refresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }

        let scannedDirectories = directories
        refreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                AppIndex.refresh(directories: scannedDirectories)
            }.value
            guard let self else { return }
            guard self.directories == scannedDirectories else {
                self.refreshTask = nil
                self.refreshPending = false
                self.refresh()
                return
            }
            self.indexed = refreshed
            self.combine()
            self.capFrecency()
            self.fingerprint = AppIndex.directoriesFingerprint(directories: directories)
            self.onChange?(self.entries, true)

            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    func recordLaunch(_ id: String) {
        frecency.recordLaunch(id)
        frecency.capRecords()
        Storage.save(frecency)
    }

    var hasHistory: Bool { !frecency.records.isEmpty }

    func hasHistory(for id: String) -> Bool { frecency.records[id] != nil }

    func forgetHistory(for id: String) {
        if frecency.forget(id) { Storage.save(frecency) }
    }

    func resetHistory() {
        frecency.removeAll()
        Storage.save(frecency)
    }

    private func combine() {
        entries = AppIndex.sortedByName(indexed + extras)
    }

    /// Keep history when a location is removed or temporarily unavailable, so adding
    /// it back restores the user's ranking. The existing hard ceiling bounds storage.
    private func capFrecency() {
        if frecency.capRecords() { Storage.save(frecency) }
    }

    private func startWatching() {
        let paths = directories.map(\.path)
        guard !paths.isEmpty else { return }
        watcher = DirectoryWatcher(paths: paths, ignoredPaths: [Storage.cacheDirectory.path, Storage.supportDirectory.path]) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
