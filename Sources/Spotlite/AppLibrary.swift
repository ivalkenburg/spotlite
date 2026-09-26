import Foundation
import SpotliteCore

/// The indexed apps and their launch history: loading the cached index, keeping it
/// current, and pruning history for apps that are gone.
@MainActor
final class AppLibrary {

    /// Already sorted by name.
    private(set) var entries: [AppEntry] = []
    private(set) var frecency = Storage.loadFrecency()
    /// Called with every freshly scanned index.
    var onChange: (([AppEntry]) -> Void)?

    /// Cached so pruning on every show doesn't rebuild it from the index each time.
    private var indexedIDs: Set<String> = []
    private var watcher: DirectoryWatcher?
    private var fingerprint: [String: Date] = [:]
    private var hasLoaded = false
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false

    /// Loads the index on first use and starts watching; on later calls does the cheap
    /// staleness check that catches changes FSEvents missed while the machine was asleep.
    func loadIfNeeded() {
        guard hasLoaded else {
            hasLoaded = true
            entries = AppIndex.loadCached() ?? []
            indexedIDs = Set(entries.map(\.id))
            pruneFrecency()
            fingerprint = AppIndex.directoriesFingerprint()
            startWatching()
            // Cached results make the first frame immediate; this scan guarantees that
            // changes made while Spotlite was not running are still discovered.
            refresh()
            return
        }

        let current = AppIndex.directoriesFingerprint()
        guard current != fingerprint else { return }
        fingerprint = current
        refresh()
    }

    /// Coalesces refresh requests and keeps bundle traversal plus cache writes off the
    /// main actor. Only complete immutable snapshots cross back into the UI.
    func refresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }

        refreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                AppIndex.refresh()
            }.value
            guard let self else { return }
            self.entries = refreshed
            self.indexedIDs = Set(refreshed.map(\.id))
            self.pruneFrecency()
            self.fingerprint = AppIndex.directoriesFingerprint()
            self.onChange?(refreshed)

            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    func recordLaunch(_ id: String) {
        frecency.recordLaunch(id)
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

    /// Drops launch history for apps that are gone and caps what remains. Called when a
    /// cached or freshly scanned index is installed, never on the panel's hot path.
    private func pruneFrecency() {
        guard !indexedIDs.isEmpty else { return }
        if frecency.prune(keeping: indexedIDs) { Storage.save(frecency) }
    }

    private func startWatching() {
        let paths = AppIndex.searchDirectories.map(\.path)
        watcher = DirectoryWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
