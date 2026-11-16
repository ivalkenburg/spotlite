import Foundation
import Testing
@testable import SpotliteCore

/// Keeps `plugins/plugin.schema.json` and `plugins/plugin-response.schema.json` in step with
/// the decoders, and the shipped manifests decodable. Full validation of the manifests
/// against the schemas needs a JSON Schema validator, which the package does not carry.
@Suite struct PluginSchemaTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func schema(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("plugins").appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func defs(_ schema: [String: Any]) throws -> [String: [String: Any]] {
        try #require(schema["$defs"] as? [String: [String: Any]])
    }

    static func enumValues(_ def: [String: Any]?) throws -> Set<String> {
        Set(try #require(def?["enum"] as? [String]))
    }

    static func manifestFolders() throws -> [URL] {
        let files = FileManager.default
        return try ["plugins", "Tests/Fixtures/Plugins"].flatMap { parent in
            try files.contentsOfDirectory(at: root.appendingPathComponent(parent), includingPropertiesForKeys: nil)
                .filter { files.fileExists(atPath: $0.appendingPathComponent(PluginStore.manifestName).path) }
        }
    }

    @Test func shippedManifestsDecodeAndLoad() throws {
        let folders = try Self.manifestFolders()
        #expect(folders.count >= 9)
        for folder in folders {
            let data = try Data(contentsOf: folder.appendingPathComponent(PluginStore.manifestName))
            #expect(throws: Never.self, "\(folder.lastPathComponent)") {
                _ = try JSONDecoder().decode(PluginManifest.self, from: data)
            }
            let plugin = PluginStore.load(folder)
            #expect(plugin.isUsable, "\(folder.lastPathComponent): \(plugin.problem ?? "")")
        }
    }

    @Test func manifestToleratesSchemaKey() throws {
        let json = """
        { "$schema": "https://raw.githubusercontent.com/ivalkenburg/spotlite/main/plugins/plugin.schema.json",
          "id": "demo", "name": "Demo",
          "commands": [{ "id": "go", "title": "Go", "action": { "type": "copy", "text": "x" } }] }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.id == "demo")
        #expect(manifest.commands.map(\.id) == ["go"])
    }

    @Test func examplesPointAtTheSchema() throws {
        let id = try #require(try Self.schema("plugin.schema.json")["$id"] as? String)
        for folder in try Self.manifestFolders() where folder.path.contains("/plugins/") {
            let data = try Data(contentsOf: folder.appendingPathComponent(PluginStore.manifestName))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["$schema"] as? String == id, "\(folder.lastPathComponent)")
        }
    }

    @Test func actionTypesMatchTheDecoder() throws {
        let defs = try Self.defs(try Self.schema("plugin.schema.json"))
        let properties = defs["action"]?["properties"] as? [String: [String: Any]]
        let types = try Self.enumValues(properties?["type"])
        #expect(types == Set(PluginAction.Kind.allCases.map(\.rawValue)))
        let branches = try #require(defs["action"]?["allOf"] as? [[String: Any]])
        #expect(branches.count == types.count)
        for type in types { #expect(defs[type + "Action"] != nil, "\(type)") }
    }

    @Test func settingTypesMatchTheDecoder() throws {
        let defs = try Self.defs(try Self.schema("plugin.schema.json"))
        let properties = defs["setting"]?["properties"] as? [String: [String: Any]]
        let types = try Self.enumValues(properties?["type"])
        #expect(types == Set(PluginSetting.Kind.allCases.map(\.rawValue)))
        let branches = try #require(defs["setting"]?["allOf"] as? [[String: Any]])
        #expect(branches.count == types.count)
        for type in types { #expect(defs[type + "Setting"] != nil, "\(type)") }
    }

    @Test func shortcutNamesMatchTheDecoder() throws {
        let defs = try Self.defs(try Self.schema("plugin.schema.json"))
        let names = try Self.enumValues(defs["shortcutName"])
        #expect(names == Set(PluginShortcut.names.keys))

        // The pattern accepts exactly the names, joined by `+`.
        let pattern = try #require(defs["shortcut"]?["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        var candidates = Array(names) + ["", "+", "cmd+", "+cmd", "cmd++shift", "hyper", "cmd+hyper", "fn", "meta"]
        for first in names { for second in names { candidates.append(first + "+" + second) } }
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            let matches = regex.firstMatch(in: candidate, range: range) != nil
            #expect(matches == (PluginShortcut(candidate) != nil), "\(candidate)")
        }
    }

    @Test func limitsMatchTheDecoder() throws {
        let manifest = try Self.schema("plugin.schema.json")
        let defs = try Self.defs(manifest)
        let top = try #require(manifest["properties"] as? [String: [String: Any]])
        #expect(top["timeout"]?["minimum"] as? Double == PluginManifest.timeoutRange.lowerBound)
        #expect(top["timeout"]?["maximum"] as? Double == PluginManifest.timeoutRange.upperBound)
        #expect(top["timeout"]?["default"] as? Double == PluginManifest.defaultTimeout)
        #expect(top["settings"]?["maxItems"] as? Int == 64)
        #expect(defs["actions"]?["maxItems"] as? Int == PluginSecondaryAction.maxCount)
        let item = defs["item"]?["properties"] as? [String: [String: Any]]
        #expect(item?["keywords"]?["maxItems"] as? Int == PluginItem.maxKeywords)
        let search = defs["searchAction"]?["properties"] as? [String: [String: Any]]
        #expect(search?["debounce"]?["minimum"] as? Int == PluginAction.debounceRange.lowerBound)
        #expect(search?["debounce"]?["maximum"] as? Int == PluginAction.debounceRange.upperBound)
        #expect(search?["debounce"]?["default"] as? Int == PluginAction.defaultDebounce)

        let response = try Self.defs(try Self.schema("plugin-response.schema.json"))
        let items = (response["response"]?["properties"] as? [String: [String: Any]])?["items"]
        #expect(items?["maxItems"] as? Int == PluginItem.maxItems)

        let update = response["commandUpdate"]?["properties"] as? [String: [String: Any]]
        #expect(update?["pid"]?["minimum"] as? Int == 2)
        #expect(update?["pid"]?["maximum"] as? Int == Int(Int32.max))
        let menuActions = (response["menuBar"]?["properties"] as? [String: [String: Any]])?["actions"]
        #expect(menuActions?["maxItems"] as? Int == PluginMenuBar.maxActions)
        let constraint = ((menuActions?["items"] as? [String: Any])?["allOf"] as? [[String: Any]])?.last
        let actionType = ((constraint?["properties"] as? [String: Any])?["action"] as? [String: Any])?["properties"]
        let kinds = Set(try #require(((actionType as? [String: Any])?["type"] as? [String: Any])?["enum"] as? [String]))
        let decoder = Set(PluginAction.Kind.allCases.filter { kind in
            PluginMenuBar.allows(Self.sampleAction(kind))
        }.map(\.rawValue))
        #expect(kinds == decoder)
    }

    static func sampleAction(_ kind: PluginAction.Kind) -> PluginAction {
        switch kind {
        case .open: .open("https://example.com")
        case .copy: .copy("x")
        case .run: .run(args: [], keepOpen: false)
        case .list: .list(args: [])
        case .search: .search(args: [], debounce: 0, minimumQuery: 0)
        case .menu: .menu([])
        }
    }

    /// The response schema borrows the row and icon from the manifest schema.
    @Test func crossFileReferencesResolve() throws {
        let manifestDefs = try Self.defs(try Self.schema("plugin.schema.json"))
        let text = try String(contentsOf: Self.root.appendingPathComponent("plugins/plugin-response.schema.json"),
                              encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""plugin\.schema\.json#/\$defs/([A-Za-z]+)""#)
        let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        #expect(!names.isEmpty)
        for name in names { #expect(manifestDefs[name] != nil, "\(name)") }
    }
}
