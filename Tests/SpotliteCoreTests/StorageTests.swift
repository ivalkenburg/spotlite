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
        Storage.saveIndex([cached], to: indexURL)
        #expect(Storage.loadIndex(from: indexURL) == [cached])
    }
}
