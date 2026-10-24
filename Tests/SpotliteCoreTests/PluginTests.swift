import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin packages")
struct PluginTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotlitePlugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func package(_ root: URL, version: String = "1.0.0", api: Int = 1, id: String = "test.plugin") throws -> URL {
        let folder = root.appendingPathComponent("\(UUID().uuidString).spotliteplugin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["id": id, "name": "Test", "version": version, "apiVersion": api,
                                     "commands": [["id": "search", "title": "Test Search"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("return {} -- \(version)".utf8).write(to: folder.appendingPathComponent("main.lua"))
        return folder
    }

    @Test func installUpdateRollbackAndRetainedSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        let original = try package(root)
        let first = try await store.install(original)
        #expect(first.enabled && !first.globalSearch)
        #expect(store.packageURL(first) != original)
        _ = try await store.setEnabled(first.id, false)
        _ = try await store.setGlobalSearch(first.id, true)
        try await store.saveSettings(first.id, values: ["option": .string("preserved")])
        try await store.storeValue(first.id, key: "saved", value: .number(42))
        let second = try await store.install(package(root, version: "1.1.0"))
        #expect(second.manifest.version == "1.1.0")
        #expect(!second.enabled && second.globalSearch)
        let rolledBack = try await store.rollback(first.id)
        #expect(rolledBack.manifest.version == "1.0.0")
        #expect(try await store.settings(first.id)["option"] == .string("preserved"))
        #expect(try await store.storedValue(first.id, key: "saved") == .number(42))
        let remaining = try await store.uninstall(first.id, removeData: false)
        #expect(remaining.isEmpty)
        #expect(try await store.settings(first.id)["option"] == .string("preserved"))
        _ = try await store.install(original)
        _ = try await store.uninstall(first.id, removeData: true)
        #expect(!FileManager.default.fileExists(atPath: store.dataURL(first.id).path))
    }

    @Test func incompatibleOrMismatchedUpdatesPreserveWorkingCode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        let installed = try await store.install(package(root))
        let original = try Data(contentsOf: store.packageURL(installed).appendingPathComponent("main.lua"))
        let incompatible = try package(root, version: "2.0.0", api: 2)
        await #expect(throws: (any Error).self) { try await store.install(incompatible) }
        let wrongID = try package(root, id: "other.plugin")
        await #expect(throws: (any Error).self) { try await store.install(wrongID, expectedID: installed.id) }
        let wrongVersion = try package(root, version: "1.1.0")
        await #expect(throws: (any Error).self) { try await store.install(wrongVersion, expectedID: installed.id, expectedVersion: "1.2.0") }
        #expect(try Data(contentsOf: store.packageURL(installed).appendingPathComponent("main.lua")) == original)
        #expect(try await store.load().first?.manifest.version == "1.0.0")
    }

    @Test func developmentUninstallPreservesSourceAndDetectsChangedIDs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        let source = try package(root)
        let plugin = try await store.install(source, development: true)
        #expect(store.packageURL(plugin).path == source.path)
        let manifest = source.appendingPathComponent("manifest.json")
        let data = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "test.plugin", with: "changed.plugin")
        try Data(data.utf8).write(to: manifest)
        await #expect(throws: (any Error).self) { try await store.refreshDevelopment(plugin.id) }
        _ = try await store.uninstall(plugin.id, removeData: true)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removedBundledPluginsStayRemovedAndRegistryReloads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        _ = try package(bundled)
        let location = root.appendingPathComponent("managed")
        let store = PluginStore(root: location)
        let initial = try await store.load(bundledDirectory: bundled)
        #expect(initial.count == 1 && initial[0].bundled)
        _ = try await store.uninstall(initial[0].id, removeData: false)
        let reload = PluginStore(root: location)
        #expect(try await reload.load(bundledDirectory: bundled).isEmpty)
    }

    @Test func legacyVisibilityMigratesThroughManifestWithoutDisablingBackgroundWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let folder = try package(bundled)
        let file = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file))
        manifest.legacyUtilityID = "formerUtility"
        manifest.background = true
        manifest.activation = "startup"
        try JSONEncoder().encode(manifest).write(to: file)
        let location = root.appendingPathComponent("managed")
        let store = PluginStore(root: location)
        let installed = try await store.load(bundledDirectory: bundled, legacyHiddenUtilityIDs: ["formerUtility"])
        #expect(installed.count == 1 && installed[0].enabled && !installed[0].showCommands)
        #expect(installed[0].manifest.startsAtLaunch)
        #expect(PluginCommandIndex(plugins: installed).search("Test", matcher: Matcher()).isEmpty)
        _ = try await store.setShowCommands(installed[0].id, true)
        let reload = PluginStore(root: location)
        let restored = try await reload.load(bundledDirectory: bundled, legacyHiddenUtilityIDs: ["formerUtility"])
        #expect(restored[0].showCommands)
    }

    @Test func corruptRegistryIsNeverOverwritten() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("registry.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        let store = PluginStore(root: root)
        await #expect(throws: (any Error).self) { try await store.load() }
        let candidate = try package(root)
        await #expect(throws: (any Error).self) { try await store.install(candidate) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func zipRoundTripSupportsFolderAndFlatArchives() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        let folder = try package(root)
        for keepParent in [true, false] {
            let archive = root.appendingPathComponent("\(UUID().uuidString).zip")
            let zipper = Process()
            zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zipper.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, archive.path]
            try zipper.run(); zipper.waitUntilExit()
            #expect(zipper.terminationStatus == 0)
            let plugin = try await store.install(archive)
            #expect(plugin.id == "test.plugin")
        }
    }

    @Test func packageRejectsEscapingEntryAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try package(root)
        let link = folder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try PluginStore.inspect(folder) }
        #expect(!PluginManifest.relativePath("../outside.lua"))
        #expect(!PluginManifest.relativePath("/outside.lua"))
        #expect(!PluginManifest.relativePath("sub/../../outside.lua"))
        #expect(!PluginManifest.validID("../plugin"))
    }

    @Test func semanticVersionsOrderPrereleasesBeforeStable() {
        #expect(PluginVersion("1.2.0")! > PluginVersion("1.1.9")!)
        #expect(PluginVersion("1.0.0-rc.10")! > PluginVersion("1.0.0-rc.2")!)
        #expect(PluginVersion("1.0.0")! > PluginVersion("1.0.0-rc.10")!)
        #expect(PluginVersion("1.0") == nil)
        #expect(PluginVersion("01.0.0") == nil)
        #expect(PluginVersion("1.0.0-01") == nil)
        #expect(PluginVersion("1.0.0+?") == nil)
    }

    @Test func metadataSearchRespectsDisabledPluginsKeywordsAndResultOrder() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"test.github","name":"GitHub","version":"1.0.0","apiVersion":1,"commands":[{"id":"github","title":"GitHub","prefix":"gh","keywords":["repositories"]}]}"#.utf8))
        let plugin = InstalledPlugin(manifest: manifest)
        let index = PluginCommandIndex(plugins: [plugin])
        let matcher = Matcher()
        #expect(index.search("repositories", matcher: matcher).first?.command.id == "github")
        #expect(index.search("gh", matcher: matcher).count == 1)
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/GitHub Desktop.app"), name: "GitHub Desktop", bundleID: "test.app")
        let results = SearchResults.build(for: "github", corpus: SearchCorpus(entries: [app]), matcher: matcher,
            frecency: Frecency(), webSearch: .google, pluginCommands: index)
        guard results.count == 3, case .app = results[0], case .pluginCommand = results[1], case .webSearch = results[2] else {
            Issue.record("Plugin commands must follow built-in matches and precede web search."); return
        }
        var disabled = plugin; disabled.enabled = false
        #expect(PluginCommandIndex(plugins: [disabled]).search("github", matcher: matcher).isEmpty)
        let noLegacyUtility = SearchResults.build(for: "caf", corpus: .empty, matcher: matcher,
            frecency: Frecency(), pluginCommands: PluginCommandIndex(plugins: []))
        #expect(noLegacyUtility.isEmpty)
    }

    @Test func malformedViewsAndActionsAreRejected() throws {
        for source in [
            #"{"id":"view","title":"Test","items":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}"#,
            #"{"id":"view","title":"Test","actions":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}"#,
            #"{"id":"view","title":"Test","type":"webview"}"#,
            #"{"id":"view","title":"Test","type":"form","fields":[{"id":"a","title":"A","type":"unknown"}]}"#
        ] {
            let view = try JSONDecoder().decode(PluginView.self, from: Data(source.utf8))
            #expect(throws: (any Error).self) { try view.validate() }
        }
    }

    @Test func failedRegistryWriteRestoresPreviousCodeAndManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let store = PluginStore(root: managed)
        _ = try await store.load()
        _ = try await store.install(package(root))
        let initial = try await store.install(package(root, version: "1.1.0"))
        let codeURL = store.packageURL(initial).appendingPathComponent("main.lua")
        let oldCode = try Data(contentsOf: codeURL)
        let registry = managed.appendingPathComponent("registry.json")
        let savedRegistry = try Data(contentsOf: registry)
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let candidate = try package(root, version: "1.2.0")
        await #expect(throws: (any Error).self) { try await store.install(candidate) }
        #expect(try Data(contentsOf: codeURL) == oldCode)
        #expect(try await store.load().first?.manifest.version == "1.1.0")
        #expect(try PluginStore.inspect(store.backupURL(initial.id)).version == "1.0.0")
        try FileManager.default.removeItem(at: registry)
        try savedRegistry.write(to: registry)
        #expect(try PluginStore.snapshot(root: managed).first?.manifest.version == "1.1.0")
        let rolledBack = try await store.rollback(initial.id)
        #expect(rolledBack.manifest.version == "1.0.0")
        #expect(try PluginStore.inspect(store.backupURL(initial.id)).version == "1.1.0")
    }

    @Test func oversizedSparseArchiveIsRejectedWithoutReadingItsContents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("oversized.zip")
        try Data().write(to: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try handle.close()
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        do {
            _ = try await store.install(archive)
            Issue.record("An oversized sparse ZIP must be rejected before reading it.")
        } catch {
            #expect(error.localizedDescription == "Invalid or oversized plugin ZIP.")
        }
        #expect(try await store.load().isEmpty)
    }

    @Test func failedInstallMoveRestoresEarlierRollbackPackage() async throws {
        let root = try temporaryDirectory()
        let managed = root.appendingPathComponent("managed")
        let packages = managed.appendingPathComponent("Packages")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: packages.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PluginStore(root: managed)
        _ = try await store.load()
        _ = try await store.install(package(root))
        let initial = try await store.install(package(root, version: "1.1.0"))
        let candidate = try package(root, version: "1.2.0")
        let registry = try Data(contentsOf: managed.appendingPathComponent("registry.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: packages.path)
        await #expect(throws: (any Error).self) { try await store.install(candidate) }
        #expect(try await store.load() == [initial])
        #expect(try Data(contentsOf: managed.appendingPathComponent("registry.json")) == registry)
        #expect(try PluginStore.inspect(store.packageURL(initial)).version == "1.1.0")
        #expect(try PluginStore.inspect(store.backupURL(initial.id)).version == "1.0.0")
    }

    @Test func failedDevelopmentRefreshAndSettingWritesRestoreCachedRecord() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let store = PluginStore(root: managed)
        _ = try await store.load()
        let source = try package(root)
        let initial = try await store.install(source, development: true)
        let manifestFile = source.appendingPathComponent("manifest.json")
        var manifest = initial.manifest
        manifest.version = "1.1.0"
        try JSONEncoder().encode(manifest).write(to: manifestFile)
        let registry = managed.appendingPathComponent("registry.json")
        let savedRegistry = try Data(contentsOf: registry)
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.refreshDevelopment(initial.id) }
        await #expect(throws: (any Error).self) { try await store.setEnabled(initial.id, false) }
        await #expect(throws: (any Error).self) { try await store.setGlobalSearch(initial.id, true) }
        await #expect(throws: (any Error).self) { try await store.setShowCommands(initial.id, false) }
        #expect(try await store.load() == [initial])
        try FileManager.default.removeItem(at: registry)
        try savedRegistry.write(to: registry)
        let refreshed = try await store.refreshDevelopment(initial.id)
        #expect(refreshed.manifest.version == "1.1.0")
        #expect(try PluginStore.snapshot(root: managed) == [refreshed])
    }

    @Test func failedUninstallRegistryWriteRestoresPackagesDataAndBundledRecord() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let store = PluginStore(root: managed)
        _ = try await store.load()
        _ = try await store.install(package(root), bundled: true)
        let initial = try await store.install(package(root, version: "1.1.0"))
        try await store.saveSettings(initial.id, values: ["keep": .bool(true)])
        let registry = managed.appendingPathComponent("registry.json")
        let savedRegistry = try Data(contentsOf: registry)
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.uninstall(initial.id, removeData: true) }
        #expect(try await store.load() == [initial])
        #expect(try PluginStore.inspect(store.packageURL(initial)).version == "1.1.0")
        #expect(try PluginStore.inspect(store.backupURL(initial.id)).version == "1.0.0")
        #expect(try await store.settings(initial.id)["keep"] == .bool(true))
        try FileManager.default.removeItem(at: registry)
        try savedRegistry.write(to: registry)
        // A later save must not persist the failed uninstall's bundled tombstone.
        _ = try await store.setEnabled(initial.id, false)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any])
        #expect((json["removedBundled"] as? [String])?.isEmpty == true)
    }

    @Test func failedUninstallMoveRestoresAlreadyStagedArtifacts() async throws {
        let root = try temporaryDirectory()
        let managed = root.appendingPathComponent("managed")
        let dataDirectory = managed.appendingPathComponent("Data")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PluginStore(root: managed)
        _ = try await store.load()
        _ = try await store.install(package(root))
        let initial = try await store.install(package(root, version: "1.1.0"))
        try await store.saveSettings(initial.id, values: ["keep": .bool(true)])
        let registry = try Data(contentsOf: managed.appendingPathComponent("registry.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDirectory.path)
        await #expect(throws: (any Error).self) { try await store.uninstall(initial.id, removeData: true) }
        #expect(try await store.load() == [initial])
        #expect(try Data(contentsOf: managed.appendingPathComponent("registry.json")) == registry)
        #expect(try PluginStore.inspect(store.packageURL(initial)).version == "1.1.0")
        #expect(try PluginStore.inspect(store.backupURL(initial.id)).version == "1.0.0")
        #expect(try await store.settings(initial.id)["keep"] == .bool(true))
    }

    @Test func importRejectsAncestorThroughSymlinkBeforeCreatingStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root)
        let managed = source.appendingPathComponent("managed")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasedSource = alias.appendingPathComponent(source.lastPathComponent)
        let store = PluginStore(root: managed)
        _ = try await store.load()
        await #expect(throws: (any Error).self) { try await store.install(aliasedSource) }
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test func uninstallCannotDeleteDevelopmentSourceInsideData() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        let data = store.dataURL("test.plugin")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let source = try package(data)
        let initial = try await store.install(source, development: true)
        await #expect(throws: (any Error).self) { try await store.uninstall(initial.id, removeData: true) }
        #expect(try await store.load() == [initial])
        #expect(try PluginStore.inspect(source).version == "1.0.0")
        #expect(try await store.uninstall(initial.id, removeData: false).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func archiveTraversalIsRejectedBeforeExtraction() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try package(root)
        let archive = root.appendingPathComponent("plugin.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", folder.path, archive.path]
        try zipper.run(); zipper.waitUntilExit()
        var bytes = try Data(contentsOf: archive)
        let original = Data("main.lua".utf8), escaping = Data("../x.lua".utf8)
        while let range = bytes.range(of: original) { bytes.replaceSubrange(range, with: escaping) }
        #expect(throws: (any Error).self) { try PluginArchive.validate(bytes) }
        try bytes.write(to: archive)
        let store = PluginStore(root: root.appendingPathComponent("managed"))
        _ = try await store.load()
        await #expect(throws: (any Error).self) { try await store.install(archive) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x.lua").path))
    }

    @Test func wireValuesPreserveNullBooleansAndNestedData() throws {
        let data = Data(#"{"id":"request","result":{"enabled":true,"items":[],"value":null,"count":2}}"#.utf8)
        let message = try JSONDecoder().decode(PluginMessage.self, from: data)
        #expect(message.result?["enabled"] == .bool(true))
        #expect(message.result?["value"] == .null)
        #expect(message.result?["items"] == .array([]))
        #expect(try JSONDecoder().decode(PluginMessage.self, from: JSONEncoder().encode(message)).result == message.result)
    }
}
