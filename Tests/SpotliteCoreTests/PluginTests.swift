import Foundation
import Testing
@testable import SpotliteCore

/// A scratch folder holding plugin folders, removed when the test ends.
private final class PluginFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlite-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A plugin folder with the given manifest and, optionally, an executable script.
    @discardableResult
    func plugin(_ folder: String, manifest: String, script: String? = nil, in parent: String = "Plugins") throws -> URL {
        let directory = root.appendingPathComponent(parent).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        if let script {
            let url = directory.appendingPathComponent("run.sh")
            try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return directory
    }

    var plugins: URL { root.appendingPathComponent("Plugins", isDirectory: true) }

    static func manifest(id: String = "demo", executable: Bool = true, action: String = #"{"type":"list"}"#) -> String {
        """
        {"id":"\(id)","name":"Demo",\(executable ? #""executable":"run.sh","# : "")
         "commands":[{"id":"main","title":"Demo Command","keyword":"dm","action":\(action)}]}
        """
    }
}

@Suite("Plugin manifests and responses")
struct PluginModelTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func decodesEveryAction() throws {
        #expect(try decode(PluginAction.self, #"{"type":"open","url":"https://example.com"}"#) == .open("https://example.com"))
        #expect(try decode(PluginAction.self, #"{"type":"copy","text":"x"}"#) == .copy("x"))
        #expect(try decode(PluginAction.self, #"{"type":"run","args":["a"],"keepOpen":true}"#)
                == .run(args: ["a"], keepOpen: true))
        #expect(try decode(PluginAction.self, #"{"type":"run"}"#) == .run(args: [], keepOpen: false))
        #expect(try decode(PluginAction.self, #"{"type":"list","args":["l"]}"#) == .list(args: ["l"]))
        #expect(try decode(PluginAction.self, #"{"type":"search"}"#)
                == .search(args: [], debounce: PluginAction.defaultDebounce, minimumQuery: 1))
        #expect(try decode(PluginAction.self, #"{"type":"search","debounce":999999,"minQuery":-3}"#)
                == .search(args: [], debounce: 2_000, minimumQuery: 0))
        #expect(try decode(PluginAction.self, #"{"type":"menu","items":[{"title":"A"},{"nope":1}]}"#)
                == .menu([PluginItem(title: "A")]))
        #expect(throws: DecodingError.self) { try decode(PluginAction.self, #"{"type":"launchMissiles"}"#) }
    }

    @Test func onlyLevelsEnterAScope() {
        #expect(PluginAction.list(args: []).entersScope)
        #expect(PluginAction.menu([]).entersScope)
        #expect(!PluginAction.run(args: [], keepOpen: true).entersScope)
        #expect(PluginSource(.open("x")) == nil)
        #expect(PluginSource(.search(args: ["s"], debounce: 5, minimumQuery: 2))?.isSearch == true)
    }

    @Test func openTargetsArePathsOrAddressesWithAScheme() {
        #expect(PluginAction.url(for: " https://example.com/a?b=1\n")?.absoluteString == "https://example.com/a?b=1")
        #expect(PluginAction.url(for: "/tmp/a b")?.path == "/tmp/a b")
        #expect(PluginAction.url(for: "~/Documents")?.path == NSHomeDirectory() + "/Documents")
        #expect(PluginAction.url(for: "x-apple.systempreferences:com.apple.Displays")?.scheme == "x-apple.systempreferences")
        // No scheme and no leading slash: nothing says what would open it.
        #expect(PluginAction.url(for: "example.com") == nil)
        #expect(PluginAction.url(for: "") == nil)
    }

    @Test func manifestClampsTimeoutAndRequiresCommands() throws {
        let manifest = try decode(PluginManifest.self, #"{"id":"a","name":"A","timeout":9000,"commands":[]}"#)
        #expect(manifest.timeout == 60)
        #expect(try decode(PluginManifest.self, #"{"id":"a","name":"A","timeout":0,"commands":[]}"#).timeout == 1)
        #expect(try decode(PluginManifest.self, #"{"id":"a","name":"A","commands":[]}"#).timeout == 10)
        #expect(throws: DecodingError.self) { try decode(PluginManifest.self, #"{"id":"a","name":"A"}"#) }
    }

    @Test func idsStayPlain() {
        #expect(PluginManifest.isValidID("com.example.kube-ctx_2"))
        for bad in ["", ".", "..", "a/b", "a b", "ü", String(repeating: "a", count: 129)] {
            #expect(!PluginManifest.isValidID(bad))
        }
    }

    @Test func responseSkipsMalformedParts() throws {
        let response = try PluginResponse.decode(Data(#"""
        {"items":[{"title":"Good","subtitle":"s","icon":"star","action":{"type":"copy","text":"c"}},
                  {"subtitle":"no title"}, {"title":"Bad action","action":{"type":"??"}}],
         "toast":"Done", "copy": 5,
         "update":[{"command":"main","icon":"bolt","expires":100},{"icon":"orphan"}]}
        """#.utf8))
        #expect(response.items == [PluginItem(title: "Good", subtitle: "s", icon: "star", action: .copy("c"))])
        #expect(response.toast == PluginToast(text: "Done"))
        #expect(response.copy == nil)
        #expect(response.update.map(\.command) == ["main"])
        #expect(response.update[0].hasExpired(at: Date(timeIntervalSince1970: 100)))
        #expect(!response.update[0].hasExpired(at: Date(timeIntervalSince1970: 99)))
    }

    @Test func emptyOutputIsAnEmptyResponse() throws {
        #expect(try PluginResponse.decode(Data()) == PluginResponse())
        #expect(try PluginResponse.decode(Data(" \n".utf8)) == PluginResponse())
        #expect(try PluginResponse.decode(Data("{}".utf8)).items == nil)
        #expect(throws: (any Error).self) { try PluginResponse.decode(Data("oops".utf8)) }
    }

    @Test func toastTakesAStringOrAnObject() throws {
        let toast = try decode(PluginToast.self, #"{"text":"No","symbol":"xmark","style":"failure"}"#)
        #expect(toast == PluginToast(text: "No", symbol: "xmark", isFailure: true))
        #expect(try decode(PluginToast.self, #""Plain""#) == PluginToast(text: "Plain"))
        #expect(try decode(PluginToast.self, #"{"text":"Yes","style":"success"}"#) == PluginToast(text: "Yes"))
        #expect(try decode(PluginCommandUpdate.self, #"{"command":"main"}"#).isReset)
        // Without `expires` a look lasts until the next update.
        let lasting = try decode(PluginCommandUpdate.self, #"{"command":"main","subtitle":"On"}"#)
        #expect(!lasting.isReset && !lasting.hasExpired(at: .distantFuture))
    }

    @Test func responsesAreCappedInLength() throws {
        let rows = (0..<(PluginItem.maxItems + 50)).map { #"{"title":"Row \#($0)"}"# }.joined(separator: ",")
        let response = try PluginResponse.decode(Data("{\"items\":[\(rows)]}".utf8))
        #expect(response.items?.count == PluginItem.maxItems)
    }

    @Test func malformedRowsDoNotConsumeTheResponseLimit() throws {
        let malformed = ["null", #"{"subtitle":"No title"}"#, #"{"title":"Bad action","action":{"type":"unknown"}}"#]
        let rows = malformed + (0..<(PluginItem.maxItems + 50)).map { #"{"title":"Row \#($0)"}"# }
        let response = try PluginResponse.decode(Data(("{\"items\":[" + rows.joined(separator: ",") + "]}").utf8))
        #expect(response.items?.count == PluginItem.maxItems)
        #expect(response.items?.first?.title == "Row 0")
        #expect(response.items?.last?.title == "Row \(PluginItem.maxItems - 1)")
    }

    @Test func listFiltersByTitleAndKeepsOrderWhenEmpty() {
        // Duplicate ids and titles must each stay reachable.
        let list = PluginList(items: [
            PluginItem(id: "x", title: "production-eu"), PluginItem(id: "x", title: "staging"),
            PluginItem(id: "y", title: "production-us"),
        ])
        let matcher = Matcher()
        #expect(list.matchingIndices("  ", matcher: matcher) == [0, 1, 2])
        #expect(list.matchingIndices("stag", matcher: matcher) == [1])
        #expect(Set(list.matchingIndices("prod", matcher: matcher)) == [0, 2])
        #expect(list.matchingIndices("zzz", matcher: matcher).isEmpty)
        #expect(PluginList.empty.matchingIndices("a", matcher: matcher).isEmpty)
    }

    @Test func remoteResultsKeepTheirOrderWithoutLocalMatching() {
        let items = [PluginItem(title: "Remote answer B"), PluginItem(title: "Remote answer A")]
        let remote = PluginList(items: items, filterLocally: false)
        #expect(remote.matchingIndices("a completely different query", matcher: Matcher()) == [0, 1])
        #expect(remote.matchingIndices("", matcher: Matcher()) == [0, 1])
    }

    @Test func duplicateOccurrencesSurviveFilteringAndUnrelatedInsertions() {
        let rows = [PluginItem(id: "same", title: "Same title"), PluginItem(id: "other", title: "Other"),
                    PluginItem(id: "same", title: "Same title")]
        let list = PluginList(items: rows)
        let indices = list.matchingIndices("Same title", matcher: Matcher())
        #expect(indices == [0, 2])
        #expect(indices.map { list.occurrence(at: $0) } == [0, 1])
        let inserted = PluginList(items: [PluginItem(id: "new", title: "New")] + rows)
        #expect(inserted.occurrence(at: 1) == list.occurrence(at: 0))
        #expect(inserted.occurrence(at: 3) == list.occurrence(at: 2))
    }

    @Test func iconsAreSymbolsUnlessTheyLookLikePaths() {
        let directory = URL(fileURLWithPath: "/plugins/demo")
        #expect(PluginIcon("cup.and.saucer.fill", directory: directory) == .symbol("cup.and.saucer.fill"))
        #expect(PluginIcon("icon.png", directory: directory) == .file(directory.appendingPathComponent("icon.png")))
        #expect(PluginIcon("assets/logo", directory: directory) == .file(directory.appendingPathComponent("assets/logo")))
        #expect(PluginIcon("/Applications/Safari.app", directory: directory)
                == .file(URL(fileURLWithPath: "/Applications/Safari.app")))
        #expect(PluginIcon("Logo.PNG", directory: directory) == .file(directory.appendingPathComponent("Logo.PNG")))
        #expect(PluginIcon("~/icon.icns", directory: directory)
                == .file(URL(fileURLWithPath: NSHomeDirectory() + "/icon.icns")))
    }

    @Test func environmentAddsToolPathsOnce() throws {
        let fixture = try PluginFixture()
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(), script: "echo"))
        let environment = PluginEnvironment.make(
            for: plugin, query: "q", base: ["PATH": "/usr/local/bin:/usr/bin", "HOME": "/Users/x"],
            dataDirectory: fixture.root)
        #expect(environment["PATH"] == "/usr/local/bin:/usr/bin:/opt/homebrew/bin:/opt/homebrew/sbin")
        #expect(environment["HOME"] == "/Users/x")
        #expect(environment["SPOTLITE_PLUGIN_DIR"] == plugin.directory.path)
        // A missing PATH still gets the system's places.
        let bare = PluginEnvironment.make(for: plugin, query: "", base: [:], dataDirectory: fixture.root)
        #expect(bare["PATH"]?.hasPrefix("/usr/bin:/bin:") == true)
        #expect(PluginStore.dataDirectory(for: "demo", in: fixture.root).path.hasSuffix("/PluginData/demo"))
    }
}

@Suite("Plugin store")
struct PluginStoreTests {
    @Test func scansUsablePluginsAndExplainsBrokenOnes() throws {
        let fixture = try PluginFixture()
        try fixture.plugin("good", manifest: PluginFixture.manifest(id: "good"), script: "echo '{}'")
        try fixture.plugin("twin", manifest: PluginFixture.manifest(id: "good"), script: "echo '{}'")
        try fixture.plugin("no-script", manifest: PluginFixture.manifest(id: "no-script"))
        try fixture.plugin("no-executable-key", manifest: PluginFixture.manifest(id: "nek", executable: false))
        try fixture.plugin("static", manifest: PluginFixture.manifest(
            id: "static", executable: false, action: #"{"type":"open","url":"https://example.com"}"#))
        try fixture.plugin("garbage", manifest: "{")
        try fixture.plugin("bad-id", manifest: PluginFixture.manifest(id: "bad id"), script: "echo")
        try FileManager.default.createDirectory(at: fixture.plugins.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        try "x".write(to: fixture.plugins.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        let plugins = PluginStore.scan(directory: fixture.plugins)
        let usable = plugins.filter(\.isUsable).map(\.directory.lastPathComponent)
        #expect(usable == ["good", "static"])
        #expect(plugins.count == 8)
        #expect(plugins.filter { !$0.isUsable }.allSatisfy { $0.problem?.isEmpty == false && $0.entries.isEmpty })
        #expect(PluginStore.scan(directory: fixture.root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func commandsBecomeEntriesWithStableIdentity() throws {
        let fixture = try PluginFixture()
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(), script: "echo"))
        let entry = try #require(plugin.entries.first)
        #expect(entry.kind == .plugin)
        #expect(entry.name == "Demo Command")
        #expect(entry.id == "com.igorv.spotlite.plugin.demo/main")
        #expect(entry.id == plugin.entryID(for: plugin.manifest!.commands[0]))
        // The keyword works as an alias, and a plugin command ranks with apps.
        let corpus = SearchCorpus(entries: plugin.entries, aliases: AliasIndex(aliases: [entry.id: "dm"]))
        let match = try #require(Matcher().search("dm", in: corpus).first)
        #expect(match.tier == .aliasPrefix)
        #expect(AppRanking.precedence(Matcher().search("demo", in: corpus)[0]) % 2 == 1)
    }

    @Test func executableMustStayInsideThePlugin() throws {
        let fixture = try PluginFixture()
        let manifest = #"{"id":"x","name":"X","executable":"../../../../bin/sh","commands":[]}"#
        #expect(PluginStore.load(try fixture.plugin("x", manifest: manifest)).problem?.contains("inside") == true)
    }

    @Test func executableMustBeAFileAndIsNeededByNestedRows() throws {
        let fixture = try PluginFixture()
        let folder = try fixture.plugin("dir", manifest: #"{"id":"dir","name":"D","executable":"bin","commands":[]}"#)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        #expect(PluginStore.load(folder).problem?.contains("not executable") == true)

        // A run two menus down still needs a program; menus of links alone do not.
        func nested(_ leaf: String) -> String {
            PluginFixture.manifest(executable: false, action: """
            {"type":"menu","items":[{"title":"A","action":{"type":"menu","items":[{"title":"B","action":\(leaf)}]}}]}
            """)
        }
        #expect(PluginStore.load(try fixture.plugin("deep", manifest: nested(#"{"type":"run"}"#)))
            .problem?.contains("no executable") == true)
        #expect(PluginStore.load(try fixture.plugin("links", manifest: nested(#"{"type":"copy","text":"x"}"#))).isUsable)
    }

    @Test func duplicateCommandIDsAreRejected() throws {
        let fixture = try PluginFixture()
        let manifest = #"""
        {"id":"x","name":"X","commands":[{"id":"a","title":"A","action":{"type":"copy","text":"1"}},
                                         {"id":"a","title":"B","action":{"type":"copy","text":"2"}}]}
        """#
        let plugin = PluginStore.load(try fixture.plugin("x", manifest: manifest))
        #expect(plugin.problem?.contains("unique") == true)
        #expect(plugin.manifest != nil && plugin.entries.isEmpty)
    }

    @Test func pluginIDsCannotCreateHiddenInstallations() throws {
        let fixture = try PluginFixture()
        let source = try fixture.plugin("source", manifest: PluginFixture.manifest(id: ".demo"), script: "echo '{}'")
        #expect(PluginStore.load(source).problem?.contains("dot") == true)
        #expect(throws: PluginStore.InstallError.self) { try PluginStore.install(from: source, into: fixture.plugins) }
    }

    @Test(arguments: [false, true])
    func installationNeverOverwritesAnUnrelatedPlugin(linked: Bool) throws {
        let fixture = try PluginFixture()
        let old = try fixture.plugin("beta", manifest: PluginFixture.manifest(id: "alpha"), script: "echo original",
                                     in: linked ? "Work" : "Plugins")
        let destination = fixture.plugins.appendingPathComponent("beta")
        if linked {
            try FileManager.default.createDirectory(at: fixture.plugins, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: old)
        }
        let source = try fixture.plugin("download", manifest: PluginFixture.manifest(id: "beta"), script: "echo replacement", in: "Downloads")
        #expect(throws: PluginStore.InstallError.self) { try PluginStore.install(from: source, into: fixture.plugins) }
        #expect(PluginStore.scan(directory: fixture.plugins).map(\.id) == ["alpha"])
        #expect(try String(contentsOf: old.appendingPathComponent("run.sh"), encoding: .utf8).contains("original"))
    }

    @Test func idsDifferingOnlyByCaseCannotShareInstallationOrState() throws {
        let fixture = try PluginFixture()
        try fixture.plugin("a", manifest: PluginFixture.manifest(id: "Demo"), script: "echo original")
        let download = try fixture.plugin("download", manifest: PluginFixture.manifest(id: "demo"), script: "echo replacement", in: "Downloads")
        #expect(throws: PluginStore.InstallError.self) { try PluginStore.install(from: download, into: fixture.plugins) }
        try fixture.plugin("b", manifest: PluginFixture.manifest(id: "demo"), script: "echo duplicate")
        let plugins = PluginStore.scan(directory: fixture.plugins)
        #expect(plugins.filter(\.isUsable).map(\.id) == ["Demo"])
        #expect(plugins.last?.problem?.contains("letter case") == true)
    }

    @Test(arguments: [false, true])
    func replacementUsesAnExistingPluginsActualFolder(linked: Bool) throws {
        let fixture = try PluginFixture()
        let old = try fixture.plugin("a-development", manifest: PluginFixture.manifest(), script: "echo old",
                                     in: linked ? "Work" : "Plugins")
        let destination = fixture.plugins.appendingPathComponent("a-development")
        if linked {
            try FileManager.default.createDirectory(at: fixture.plugins, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: old)
        }
        let new = try fixture.plugin("download", manifest: PluginFixture.manifest(), script: "echo new", in: "Downloads")
        let installed = try PluginStore.install(from: new, into: fixture.plugins)
        #expect(installed.directory.standardizedFileURL == destination.standardizedFileURL)
        let plugins = PluginStore.scan(directory: fixture.plugins)
        #expect(plugins.count == 1 && plugins[0].isUsable)
        #expect(try String(contentsOf: installed.executableURL!, encoding: .utf8).contains("new"))
        if linked { #expect(try String(contentsOf: old.appendingPathComponent("run.sh"), encoding: .utf8).contains("old")) }
    }

    @Test func installReplacesALinkAndLeavesAnInstalledFolderAlone() throws {
        let fixture = try PluginFixture()
        let development = try fixture.plugin("dev", manifest: PluginFixture.manifest(id: "demo"),
                                             script: "echo dev", in: "Work")
        let download = try fixture.plugin("new", manifest: PluginFixture.manifest(id: "demo"),
                                          script: "echo new", in: "Downloads")
        try FileManager.default.createDirectory(at: fixture.plugins, withIntermediateDirectories: true)
        let link = fixture.plugins.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: development)

        // Installing the linked folder itself changes nothing.
        try PluginStore.install(from: development, into: fixture.plugins)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == development.path)

        // Another copy takes the link's place; the folder it pointed at is untouched.
        let installed = try PluginStore.install(from: download, into: fixture.plugins)
        #expect(installed.isUsable)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(try String(contentsOf: link.appendingPathComponent("run.sh"), encoding: .utf8).contains("new"))
        #expect(try String(contentsOf: development.appendingPathComponent("run.sh"), encoding: .utf8).contains("dev"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.plugins.path) == ["demo"])

        // Installing from where it already lives is not a copy onto itself.
        #expect(try PluginStore.install(from: link, into: fixture.plugins).isUsable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.plugins.path) == ["demo"])
    }

    @Test func installCopiesReplacesAndRemoves() throws {
        let fixture = try PluginFixture()
        let source = try fixture.plugin("anything", manifest: PluginFixture.manifest(id: "demo"),
                                        script: "echo one", in: "Downloads")
        let installed = try PluginStore.install(from: source, into: fixture.plugins)
        #expect(installed.isUsable)
        #expect(installed.directory.lastPathComponent == "demo")
        #expect(FileManager.default.isExecutableFile(atPath: installed.executableURL!.path))

        // A newer copy replaces the installed one, leaving no staging folder behind.
        try "#!/bin/sh\necho two".write(to: source.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: source.appendingPathComponent("run.sh").path)
        try PluginStore.install(from: source, into: fixture.plugins)
        let script = try String(contentsOf: fixture.plugins.appendingPathComponent("demo/run.sh"), encoding: .utf8)
        #expect(script.contains("two"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.plugins.path) == ["demo"])

        let broken = try fixture.plugin("broken", manifest: "{", in: "Downloads")
        #expect(throws: PluginStore.InstallError.self) { try PluginStore.install(from: broken, into: fixture.plugins) }
        #expect(PluginStore.scan(directory: fixture.plugins).count == 1)

        // A linked plugin loses its link, never the folder it points at.
        let link = fixture.plugins.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(PluginStore.scan(directory: fixture.plugins).count == 2)
        try PluginStore.remove(PluginStore.load(link))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(PluginStore.scan(directory: fixture.plugins).map(\.id) == ["demo"])
    }

    @Test func installingFromARelativeSymlinkCopiesTheFolder() throws {
        let fixture = try PluginFixture()
        let source = try fixture.plugin("source", manifest: PluginFixture.manifest(),
                                        script: "echo '{}'", in: "Downloads")
        let link = source.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "source")

        let installed = try PluginStore.install(from: link, into: fixture.plugins)
        #expect(installed.isUsable)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: installed.directory.path)) == nil)
        try FileManager.default.removeItem(at: source)
        #expect(PluginStore.load(installed.directory).isUsable)
    }

    @Test func invalidStagedCopyPreservesTheInstalledPlugin() throws {
        let fixture = try PluginFixture()
        let source = try fixture.plugin("source", manifest: PluginFixture.manifest(),
                                        script: "echo original", in: "Downloads")
        let installed = try PluginStore.install(from: source, into: fixture.plugins)
        let script = source.appendingPathComponent("run.sh")
        let helper = source.deletingLastPathComponent().appendingPathComponent("helper.sh")
        try FileManager.default.moveItem(at: script, to: helper)
        try FileManager.default.createSymbolicLink(atPath: script.path, withDestinationPath: "../helper.sh")
        #expect(PluginStore.load(source).isUsable)

        // The relative executable link breaks after copying to Plugins. Reject the
        // staged copy before replacing the working installation.
        #expect(throws: PluginStore.InstallError.self) {
            try PluginStore.install(from: source, into: fixture.plugins)
        }
        #expect(PluginStore.load(installed.directory).isUsable)
        #expect(try String(contentsOf: installed.executableURL!, encoding: .utf8).contains("original"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.plugins.path) == ["demo"])
    }

    @Test func disabledPluginsSurviveASave() throws {
        let preferences = Preferences(disabledPlugins: ["demo"])
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.disabledPlugins == ["demo"])
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).disabledPlugins.isEmpty)
    }
}

@Suite("Plugin runs")
struct PluginRunTests {
    private func run(_ script: String, arguments: [String] = [], timeout: TimeInterval = 5,
                     query: String = "", configurationJSON: String = "{}") async throws -> Result<PluginResponse, PluginRunError> {
        let fixture = try PluginFixture()
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(), script: script))
        let environment = PluginEnvironment.make(for: plugin, query: query, base: ["PATH": "/usr/bin:/bin"],
                                                 dataDirectory: fixture.root.appendingPathComponent("data"), configurationJSON: configurationJSON)
        return await withCheckedContinuation { continuation in
            PluginRun.start(executable: plugin.executableURL!, arguments: arguments, environment: environment,
                            directory: plugin.directory, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    @Test func passesArgumentsAndEnvironment() async throws {
        let script = #"""
        printf '{"items":[{"title":"%s"},{"title":"%s"},{"title":"%s"},{"title":"%s"}]}' \
          "$2" "$SPOTLITE_QUERY" "$SPOTLITE_PLUGIN_ID" "$(basename "$PWD")-$(basename "$SPOTLITE_PLUGIN_DATA")"
        case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) exit 9 ;; esac
        """#
        let response = try await run(script, arguments: ["use", "two words"], query: "typed").get()
        #expect(response.items?.map(\.title) == ["two words", "typed", "demo", "demo-data"])
    }

    @Test func passesConfigurationAsOneJSONEnvironmentValue() async throws {
        let response = try await run(#"printf '%s' "$SPOTLITE_CONFIG""#,
                                     configurationJSON: #"{"copy":"configured"}"#).get()
        #expect(response.copy == "configured")
    }

    @Test func reportsTheFirstErrorLine() async throws {
        let result = try await run("echo 'kubectl was not found' >&2; echo more >&2; exit 3")
        #expect(result == .failure(.failed(status: 3, message: "kubectl was not found")))
        #expect(PluginRunError.failed(status: 3, message: "").message.contains("3"))
    }

    @Test func drainsStandardErrorWhenStandardOutputClosesFirst() async throws {
        let result = try await run("exec 1>&-; echo 'the actual error' >&2; head -c 65536 /dev/zero >&2; exit 3")
        #expect(result == .failure(.failed(status: 3, message: "the actual error")))
    }

    @Test func doesNotWaitForAnInheritedErrorPipe() async throws {
        let start = Date()
        let result = try await run("sleep 20 >/dev/null & echo 'the actual error' >&2; exit 3")
        #expect(result == .failure(.failed(status: 3, message: "the actual error")))
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func rejectsOutputThatIsNotJSON() async throws {
        guard case .failure(.invalidOutput) = try await run("echo hello") else {
            Issue.record("expected invalid output")
            return
        }
        #expect(try await run("true").get() == PluginResponse())
    }

    @Test func stopsARunThatTakesTooLong() async throws {
        let start = Date()
        #expect(try await run("sleep 30", timeout: 0.3) == .failure(.timedOut))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func doesNotWaitForAProcessLeftRunning() async throws {
        // The background sleep inherits the output pipe, as a careless plugin's child would.
        let start = Date()
        let response = try await run(#"sleep 20 & echo '{"toast":"started"}'"#).get()
        #expect(response.toast?.text == "started")
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func readsOutputLargerThanAPipeBuffer() async throws {
        let script = #"""
        printf '{"items":['
        i=0; while [ $i -lt 400 ]; do printf '{"title":"%0500d"},' $i; i=$((i+1)); done
        printf '{"title":"last"}]}'
        """#
        #expect(try await run(script).get().items?.last?.title == "last")
    }

    @Test func stopsARunawayOutput() async throws {
        let start = Date()
        #expect(try await run("head -c 6000000 /dev/zero; sleep 30") == .failure(.outputTooLarge))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aFailureOutranksWhatWasPrinted() async throws {
        let result = try await run(#"echo '{"toast":"fine"}'; exit 1"#)
        #expect(result == .failure(.failed(status: 1, message: "")))
    }

    @Test func cancelledRunStaysSilent() async throws {
        let fixture = try PluginFixture()
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(),
                                                         script: "sleep 1; echo '{}'"))
        let called = Called()
        let run = PluginRun.start(executable: plugin.executableURL!, arguments: [], environment: [:],
                                  directory: plugin.directory, timeout: 5) { _ in called.set() }
        run.cancel()
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(!called.value)
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let result: Result<PluginResponse, PluginRunError> = await withCheckedContinuation { continuation in
            PluginRun.start(executable: URL(fileURLWithPath: "/nonexistent/program"), arguments: [],
                            environment: [:], directory: FileManager.default.temporaryDirectory,
                            timeout: 1) { continuation.resume(returning: $0) }
        }
        guard case .failure(.launchFailed) = result else {
            Issue.record("expected a launch failure")
            return
        }
    }

    @Test func completedRunsReleaseBeforeTheirTimeoutDeadline() async throws {
        let fixture = try PluginFixture()
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(), script: "echo '{}'"))
        weak var released: PluginRun?
        let result: Result<PluginResponse, PluginRunError> = await withCheckedContinuation { continuation in
            let run = PluginRun.start(executable: plugin.executableURL!, arguments: [], environment: [:],
                                      directory: plugin.directory, timeout: 60) { continuation.resume(returning: $0) }
            released = run
        }
        #expect(try result.get() == PluginResponse())
        try await Task.sleep(for: .milliseconds(500))
        #expect(released == nil)
    }

    @Test(arguments: [true, false])
    func stopsDescendantsThatIgnoreTermination(cancelled: Bool) async throws {
        let fixture = try PluginFixture()
        let script = #"""
        echo $$ > group.pid
        /bin/sh -c 'trap "" TERM; echo $$ > "$1"; sleep 30; :' child "$PWD/child.pid" &
        wait
        """#
        let plugin = PluginStore.load(try fixture.plugin("demo", manifest: PluginFixture.manifest(), script: script))
        let outcome = RecordedPluginResult()
        let run = PluginRun.start(executable: plugin.executableURL!, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                                  directory: plugin.directory, timeout: cancelled ? 60 : 0.5) { outcome.record($0) }
        defer { run.cancel() }
        let marker = plugin.directory.appendingPathComponent("child.pid")
        // Synchronize cancellation with the child installing its signal handler.
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try #require(Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let group = try #require(Int32(try String(contentsOf: plugin.directory.appendingPathComponent("group.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if group != getpgrp() { kill(-group, SIGKILL) } }
        if cancelled { run.cancel() }
        try await Task.sleep(for: .seconds(2))
        let status = kill(child, 0)
        let reason = errno
        #expect(status == -1 && reason == ESRCH)
        if cancelled { #expect(outcome.value == nil) }
        else { #expect(outcome.value == .failure(.timedOut)) }
    }
}

private final class RecordedPluginResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<PluginResponse, PluginRunError>?
    var value: Result<PluginResponse, PluginRunError>? { lock.withLock { result } }
    func record(_ value: Result<PluginResponse, PluginRunError>) { lock.withLock { result = value } }
}

private final class Called: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
