import Foundation
import CoreServices
import Synchronization
import Testing
@testable import SpotliteCore

@Suite("Directory watcher")
struct DirectoryWatcherTests {
    @Test func matchesScanDepthAndChangesInsideApps() {
        let roots = ["/Applications"]
        for path in ["/Applications", "/Applications/New.app", "/Applications/Vendor",
                     "/Applications/Vendor/New.app", "/Applications/One.app/Contents/Info.plist",
                     "/Applications/Vendor/Two.app/Contents/Resources/Icon.icns", "/Applications/.Hidden.app/Contents"] {
            #expect(DirectoryWatcher.shouldRefresh(path: path, roots: roots), "\(path)")
        }
        for path in ["/Applications/Vendor/Deep/New.app", "/Applications/.hidden/New.app",
                     "/Applications/Vendor/Documents/readme.txt"] {
            #expect(!DirectoryWatcher.shouldRefresh(path: path, roots: roots), "\(path)")
        }
    }

    @Test func homeAndFilesystemRootsIgnoreUnrelatedDeepPathsAndOwnStorage() {
        let cache = "/Users/test/Library/Caches/Spotlite"
        let support = "/Users/test/Library/Application Support/Spotlite"
        for roots in [["/Users/test"], ["/"]] {
            #expect(!DirectoryWatcher.shouldRefresh(path: cache + "/index.json", roots: roots, ignoredPaths: [cache, support]))
            #expect(!DirectoryWatcher.shouldRefresh(path: support + "/prefs.json", roots: roots, ignoredPaths: [cache, support]))
            #expect(!DirectoryWatcher.shouldRefresh(path: "/Users/test/Projects/Project/source.swift", roots: roots))
        }
        #expect(DirectoryWatcher.shouldRefresh(path: "/Example.app/Contents/Info.plist", roots: ["/"]))
        #expect(DirectoryWatcher.shouldRefresh(path: "/Vendor/Example.app/Contents/Info.plist", roots: ["/"]))
        #expect(!DirectoryWatcher.shouldRefresh(path: "/Users/test/Library/Caches/SpotliteElsewhere/deep/file", roots: ["/Users/test"], ignoredPaths: [cache]))
        // Component boundaries prevent /ApplicationsElsewhere from being mistaken for a root.
        // Unmapped paths conservatively refresh, including alternate symlink spellings.
        #expect(DirectoryWatcher.shouldRefresh(path: "/ApplicationsElsewhere/vendor/deep/file", roots: ["/Applications"]))
    }

    @Test func lostEventsForceARefreshEvenForExcludedPaths() {
        let ignored = "/Users/test/Library/Caches/Spotlite"
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            #expect(DirectoryWatcher.shouldRefresh(path: ignored + "/index.json", flags: FSEventStreamEventFlags(flag),
                                                  roots: ["/Users/test"], ignoredPaths: [ignored]))
        }
    }

    @Test func canonicalPathsResolveSymlinkRootsAndMissingStorageDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteWatcherSymlink-\(UUID())")
        let physical = root.appendingPathComponent("Physical")
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)
        let canonical = DirectoryWatcher.canonicalPath(physical.path)
        let cache = physical.appendingPathComponent("Cache")
        let file = cache.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: file)
        let eventPath = canonical + "/Cache/index.json"
        let exclusions = [canonical + "/Cache"]
        #expect(!DirectoryWatcher.shouldRefresh(path: eventPath, roots: [canonical], ignoredPaths: exclusions))
        try FileManager.default.removeItem(at: file)
        #expect(!DirectoryWatcher.shouldRefresh(path: eventPath, roots: [canonical], ignoredPaths: exclusions))
        #expect(DirectoryWatcher.canonicalPath(link.path) == canonical)
        #expect(DirectoryWatcher.canonicalPath(link.appendingPathComponent("Cache/New").path) == canonical + "/Cache/New")
        #expect(!DirectoryWatcher.shouldRefresh(path: canonical + "/Cache/New/index.json", roots: [canonical],
                                               ignoredPaths: [DirectoryWatcher.canonicalPath(link.appendingPathComponent("Cache").path)]))
    }

    private final class Counter: Sendable { let value = Mutex(0) }

    @Test func aWatchedRootContainingTheCacheDoesNotCreateARefreshLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteWatchedCache-\(UUID())")
        let cache = root.appendingPathComponent("Cache")
        let app = root.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = cache.appendingPathComponent("index.json")
        let apps = [CachedApp(path: root.appendingPathComponent("Example.app").path, name: "Example", bundleID: "test.example")]
        Storage.saveIndex(apps, directories: [root], to: url)
        let calls = Counter()
        let watcher = DirectoryWatcher(paths: [root.path], ignoredPaths: [cache.path], latency: 0.01) {
            calls.value.withLock { $0 += 1 }
            Storage.saveIndex(apps, directories: [root], to: url)
        }
        #expect(watcher.isWatching)
        try Data("updated".utf8).write(to: app.appendingPathComponent("Info.plist"))
        for _ in 0..<100 {
            if calls.value.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value.withLock { $0 } > 0)
        // Let the initial batch settle, then deliberately write a changed cache.
        try await Task.sleep(for: .milliseconds(100))
        let settled = calls.value.withLock { $0 }
        Storage.saveIndex([], directories: [root], to: url)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.value.withLock { $0 } == settled)
        #expect(Storage.loadIndex(directories: [root], from: url) == [])
        withExtendedLifetime(watcher) {}
    }

    private final class Lifetime: Sendable {}
    private final class WeakLifetime { weak var value: Lifetime? }

    @Test func streamRetainsAndReleasesItsCallbackContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteWatcher-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var lifetime: Lifetime? = Lifetime()
        let reference = WeakLifetime()
        reference.value = lifetime
        var watcher: DirectoryWatcher? = DirectoryWatcher(paths: [root.path]) { [held = lifetime!] in
            withExtendedLifetime(held) {}
        }
        lifetime = nil
        #expect(watcher?.isWatching == true)
        #expect(reference.value != nil)
        watcher = nil
        // FSEvents releases its retained context after queued teardown completes.
        for _ in 0..<100 {
            if reference.value == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reference.value == nil)
    }

    @Test func repeatedReplacementWithPendingFilesystemActivityIsSafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteWatcherStress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<30 {
            let watcher = DirectoryWatcher(paths: [root.path], latency: 0.001) {}
            #expect(watcher.isWatching)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("App\(index).app"),
                                                    withIntermediateDirectories: true)
            withExtendedLifetime(watcher) {}
        }
    }
}
