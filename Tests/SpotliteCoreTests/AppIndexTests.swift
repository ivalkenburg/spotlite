import Foundation
import Testing
@testable import SpotliteCore

@Suite("App index")
struct AppIndexTests {
    @Test func fingerprintRereadsModificationDates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppIndex.directoriesFingerprint(directories: [root])
        let changed = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: root.path)
        let second = AppIndex.directoriesFingerprint(directories: [root])
        #expect(second != first)
        #expect(second[root.path] == changed)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotliteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeApp(in directory: URL, name: String, bundleID: String,
                         metadataName: String? = nil, background: Bool = false,
                         backgroundOnly: Bool = false) throws -> URL {
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
        if backgroundOnly { info["LSBackgroundOnly"] = true }
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

    @Test func discoversDirectEmbeddedAppsWithoutTraversingBundleInternals() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try makeApp(in: root, name: "Host", bundleID: "test.host")
        let applications = host.appendingPathComponent("Contents/Applications", isDirectory: true)
        let tool = try makeApp(in: applications, name: "Device Hub", bundleID: "test.devices")
        try makeApp(in: applications, name: "UI Agent", bundleID: "test.uiagent", background: true)
        try makeApp(in: applications, name: "Background Agent", bundleID: "test.background",
                    backgroundOnly: true)
        let helper = try makeApp(in: host.appendingPathComponent("Contents/Frameworks"),
                                 name: "Internal Helper", bundleID: "test.helper")
        let nested = try makeApp(in: tool.appendingPathComponent("Contents/Applications"),
                                 name: "Nested Tool", bundleID: "test.nestedtool")
        let subfolder = try makeApp(in: applications.appendingPathComponent("Vendor"),
                                    name: "Subfolder Tool", bundleID: "test.subfoldertool")

        #expect(AppIndex.scan(directories: [root]).map(\.name) == ["Device Hub", "Host"])
        #expect(AppIndex.includesApplication(at: tool, directories: [root]))
        for excluded in [helper, nested, subfolder] {
            #expect(!AppIndex.includesApplication(at: excluded, directories: [root]))
        }
        #expect(!AppIndex.includesApplication(at: tool, directories: []))
        #expect(!AppIndex.includesApplication(at: tool, directories: [root.appendingPathComponent("Other")]))
    }

    @Test func discoversEmbeddedAppsInVendorFoldersButNotBeyondSearchDepth() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("Vendor")
        let host = try makeApp(in: vendor, name: "Host", bundleID: "test.host")
        let tool = try makeApp(in: host.appendingPathComponent("Contents/Applications"),
                               name: "Instruments", bundleID: "test.instruments")
        let deep = try makeApp(in: vendor.appendingPathComponent("Deep"),
                               name: "Deep Host", bundleID: "test.deephost")
        let deepTool = try makeApp(in: deep.appendingPathComponent("Contents/Applications"),
                                   name: "Deep Tool", bundleID: "test.deeptool")

        #expect(AppIndex.scan(directories: [root]).map(\.name) == ["Host", "Instruments"])
        #expect(AppIndex.includesApplication(at: tool, directories: [root]))
        #expect(!AppIndex.includesApplication(at: deepTool, directories: [root]))
    }

    @Test func overlappingRootsDoNotDuplicateEmbeddedApps() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try makeApp(in: root, name: "Host", bundleID: "test.host")
        let applications = host.appendingPathComponent("Contents/Applications", isDirectory: true)
        let tool = try makeApp(in: applications, name: "Device Hub", bundleID: "test.devices")

        for directories in [[root, applications], [applications, root]] {
            #expect(AppIndex.scan(directories: directories).map(\.name) == ["Device Hub", "Host"])
        }
        // Removing the host's root retains a tool covered by an explicit root.
        #expect(AppIndex.scan(directories: [applications]).map(\.name) == ["Device Hub"])
        #expect(AppIndex.includesApplication(at: tool, directories: [applications]))
        #expect(!AppIndex.includesApplication(at: host, directories: [applications]))
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

    @Test func rescanSeesInfoPlistChangedInPlace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(in: root, name: "Updated", bundleID: "test.before")
        #expect(AppIndex.scan(directories: [root]).map(\.bundleID) == ["test.before"])

        // An update rewrites the plist inside the same bundle path.
        try makeApp(in: root, name: "Updated", bundleID: "test.after")
        #expect(AppIndex.scan(directories: [root]).map(\.bundleID) == ["test.after"])
        try makeApp(in: root, name: "Updated", bundleID: "test.after", background: true)
        #expect(AppIndex.scan(directories: [root]).isEmpty)
    }

    @Test func normalizesDirectoriesWithoutRestoringRemovedDefaults() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppIndex.normalizedDirectories(["~/Applications", home + "/Applications/", "relative", "/tmp/../tmp"])
                .map(\.path) == [home + "/Applications", "/tmp"])
        #expect(AppIndex.normalizedDirectories([]).isEmpty)
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(old.applicationDirectories == AppIndex.searchDirectories.map(\.path))
        let empty = Preferences(applicationDirectories: [])
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(empty)).applicationDirectories.isEmpty)
        let custom = Preferences(applicationDirectories: ["/tmp/Apps", "/tmp/Apps/"])
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(custom)) == custom)
        #expect(custom.applicationDirectories == ["/tmp/Apps"])
    }

    @Test func customRootsRespectDepthAndDoNotIncludeStandardApps() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("Vendor")
        let deep = vendor.appendingPathComponent("Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try makeApp(in: root, name: "Root", bundleID: "test.root")
        try makeApp(in: vendor, name: "Vendor", bundleID: "test.vendor")
        try makeApp(in: deep, name: "Too Deep", bundleID: "test.deep")
        #expect(AppIndex.includesApplication(at: root.appendingPathComponent("Root.app"), directories: [root]))
        #expect(AppIndex.includesApplication(at: vendor.appendingPathComponent("Vendor.app"), directories: [root]))
        #expect(!AppIndex.includesApplication(at: deep.appendingPathComponent("Too Deep.app"), directories: [root]))
        #expect(!AppIndex.includesApplication(at: root.appendingPathComponent("Root.app"), directories: []))
        #expect(AppIndex.scanAll(directories: [root]).filter { $0.kind == .app }.map(\.name) == ["Root", "Vendor"])
        #expect(AppIndex.scanAll(directories: []).allSatisfy { $0.kind == .settingsPane })
    }

    @Test func watcherCanStartAndStopForATemporaryDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = DirectoryWatcher(paths: [root.path], latency: 0.01) {}
        #expect(watcher.isWatching)
    }
}
