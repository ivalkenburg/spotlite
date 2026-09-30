import Foundation
import Testing
@testable import SpotliteCore

@Suite("Storage recovery")
struct StorageTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotliteStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func corruptPreferencesArePreservedBeforeDefaultsAreReturned() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prefs.json")
        try Data("not-json".utf8).write(to: url)

        let loaded = Storage.loadPreferences(from: url)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        #expect(loaded == Preferences())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(files.contains { $0.hasPrefix("prefs.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func missingPreferencesReturnDefaults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Storage.loadPreferences(from: directory.appendingPathComponent("missing.json"))
                == Preferences())
    }

    @Test func allStoredShapesRoundTripAtInjectedLocations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferencesURL = directory.appendingPathComponent("nested/prefs.json")
        var preferences = Preferences()
        preferences.aliases = ["test.app": "ta"]
        Storage.save(preferences, to: preferencesURL)
        #expect(Storage.loadPreferences(from: preferencesURL) == preferences)

        let frecencyURL = directory.appendingPathComponent("frecency.json")
        var frecency = Frecency()
        frecency.recordLaunch("test.app", now: Date(timeIntervalSince1970: 100))
        Storage.save(frecency, to: frecencyURL)
        #expect(Storage.loadFrecency(from: frecencyURL).records["test.app"]?.count == 1)

        let indexURL = directory.appendingPathComponent("index.json")
        let cached = CachedApp(path: "/Applications/Test.app", name: "Test", bundleID: "test.app")
        let pane = CachedApp(path: "/System/Library/ExtensionKit/Extensions/Test.appex",
                             name: "Test Pane", bundleID: "test.pane", kind: .settingsPane)
        Storage.saveIndex([cached, pane], directories: AppIndex.searchDirectories, to: indexURL)
        #expect(Storage.loadIndex(directories: AppIndex.searchDirectories, from: indexURL) == [cached, pane])
    }

    @Test func indexCacheIsBoundToItsConfiguredRoots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.json")
        let roots = [directory]
        let apps = [CachedApp(path: directory.appendingPathComponent("Test.app").path,
                              name: "Test", bundleID: "test.app")]
        Storage.saveIndex(apps, directories: roots, to: url)
        #expect(Storage.loadIndex(directories: roots, from: url) == apps)
        #expect(Storage.loadIndex(directories: [], from: url) == nil)
        #expect(Storage.loadIndex(directories: AppIndex.searchDirectories, from: url) == nil)
        try JSONEncoder().encode(apps).write(to: url)
        #expect(Storage.loadIndex(directories: AppIndex.searchDirectories, from: url) == apps)
        #expect(Storage.loadIndex(directories: roots, from: url) == nil)
    }

    @Test func identicalIndexSnapshotsDoNotTouchTheCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.json")
        let apps = [CachedApp(path: "/Applications/Test.app", name: "Test", bundleID: "test.app")]
        Storage.saveIndex(apps, directories: [directory], to: url)
        let original = try Data(contentsOf: url)
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
        Storage.saveIndex(apps, directories: [directory], to: url)
        let unchanged = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(unchanged == sentinel)
        #expect(try Data(contentsOf: url) == original)
        Storage.saveIndex(apps, directories: [], to: url)
        #expect(Storage.loadIndex(directories: [], from: url) == apps)
        #expect(try Data(contentsOf: url) != original)
    }

    /// An index cached before panes existed has no `kind`; it must load, as apps, rather
    /// than fail and cost a cold scan.
    @Test func indexWithoutKindsLoadsAsApps() throws {
        let old = Data(#"[{"path":"/Applications/Test.app","name":"Test","bundleID":"test.app"}]"#.utf8)
        let decoded = try JSONDecoder().decode([CachedApp].self, from: old)
        #expect(decoded.map(\.kind) == [.app])
    }
}
