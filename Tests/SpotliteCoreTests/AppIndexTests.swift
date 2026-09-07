import Foundation
import Testing
@testable import SpotliteCore

@Suite("App index")
struct AppIndexTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotliteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeApp(in directory: URL, name: String, bundleID: String,
                         metadataName: String? = nil, background: Bool = false) throws -> URL {
        let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleName": metadataName ?? name,
            "CFBundleDisplayName": metadataName ?? name,
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
        ]
        if background { info["LSUIElement"] = true }
        let data = try PropertyListSerialization.data(fromPropertyList: info,
                                                      format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func scansNestedAppsAndRejectsBackgroundAgents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeApp(in: root, name: "Visible", bundleID: "test.visible")
        try makeApp(in: vendor, name: "Nested", bundleID: "test.nested")
        try makeApp(in: root, name: "Agent", bundleID: "test.agent", background: true)

        #expect(AppIndex.scan(directories: [root]).map(\.name) == ["Nested", "Visible"])
        let fingerprint = AppIndex.directoriesFingerprint(directories: [root])
        #expect(fingerprint[root.path] != nil)
    }

    @Test func keepsSeparateCopiesWithTheSameBundleIdentifier() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try makeApp(in: first, name: "Example", bundleID: "test.shared")
        try makeApp(in: second, name: "Example Copy", bundleID: "test.shared")

        let apps = AppIndex.scan(directories: [first, second])
        #expect(apps.count == 2)
        #expect(Set(apps.map(\.id)) == ["test.shared"])
        #expect(Set(apps.map(\.instanceID)).count == 2)
        #expect(AppEntry(cached: apps[0].cached) == apps[0])
    }

    @Test func finderVisibleNameWinsOverInternalBundleName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(in: root, name: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
                    metadataName: "Code")

        let apps = AppIndex.scan(directories: [root])
        #expect(apps.first?.name == "Visual Studio Code")
        #expect(Matcher().search("visual", in: apps).first?.entry.name == "Visual Studio Code")
        #expect(Matcher().search("code", in: apps).first?.entry.name == "Visual Studio Code")
    }

    @Test func watcherCanStartAndStopForATemporaryDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = DirectoryWatcher(paths: [root.path], latency: 0.01) {}
        #expect(watcher.isWatching)
    }
}
