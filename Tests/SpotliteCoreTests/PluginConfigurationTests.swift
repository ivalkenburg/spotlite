import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin configuration")
struct PluginConfigurationTests {
    private func settings(_ json: String) throws -> [PluginSetting] {
        try JSONDecoder().decode([PluginSetting].self, from: Data(json.utf8))
    }

    private let schema = #"""
    [{"id":"organization","label":"Organization","type":"text","required":true},
     {"id":"limit","label":"Results","type":"number","min":1,"max":50,"default":20},
     {"id":"forks","label":"Include forks","type":"boolean"},
     {"id":"sort","label":"Sort by","type":"choice","default":"stars",
      "options":[{"value":"stars","label":"Stars"},{"value":"updated","label":"Updated"}]}]
    """#

    @Test func defaultsRetainTheirJSONTypesAndMissingRequiredValuesBlockSetup() throws {
        let fields = try settings(schema)
        let initial = PluginConfiguration(settings: fields)
        #expect(!initial.isValid)
        #expect(initial.errors.keys.sorted() == ["organization"])
        #expect(initial.values["limit"] == .number(20))
        #expect(initial.values["forks"] == .boolean(false))
        #expect(initial.values["sort"] == .string("stars"))
        let configured = PluginConfiguration(settings: fields, saved: ["organization": .string("openai")])
        #expect(configured.isValid)
        let object = try #require(JSONSerialization.jsonObject(with: Data(configured.json().utf8)) as? [String: Any])
        #expect(object["organization"] as? String == "openai")
        #expect(object["limit"] as? Double == 20)
        #expect(object["forks"] as? Bool == false)
    }

    @Test func validatesSavedValuesWithoutSilentlyReplacingInvalidOnes() throws {
        let configuration = PluginConfiguration(settings: try settings(schema), saved: [
            "organization": .string(" \n\t"), "limit": .number(51),
            "forks": .string("false"), "sort": .string("removed"),
        ])
        #expect(configuration.errors.count == 4)
        #expect(configuration.values["sort"] == .string("removed"))
        #expect(configuration.values["limit"] == .number(51))
        let belowMinimum = PluginConfiguration(settings: try settings(schema), saved: ["limit": .number(0)])
        #expect(belowMinimum.errors["limit"] != nil)
    }

    @Test func updatesRevalidateValuesApplyNewDefaultsAndOmitRemovedKeys() throws {
        let saved: [String: PluginSettingValue] = ["organization": .string("openai"), "removed": .string("old")]
        let current = PluginConfiguration(settings: try settings(schema), saved: saved)
        #expect(current.isValid)
        #expect(current.values["removed"] == nil)
        #expect(try !current.json().contains("removed"))
        let updated = try settings(#"[{"id":"organization","label":"Organization","type":"number","required":true}]"#)
        let migrated = PluginConfiguration(settings: updated, saved: saved)
        #expect(!migrated.isValid)
        #expect(migrated.values["organization"] == .string("openai"))
    }

    @Test func optionalValuesMayBeAbsentAndFalseSatisfiesARequiredToggle() throws {
        let fields = try settings(#"""
        [{"id":"optional","label":"Optional","type":"text"},
         {"id":"toggle","label":"Toggle","type":"boolean","required":true}]
        """#)
        let configuration = PluginConfiguration(settings: fields)
        #expect(configuration.isValid)
        #expect(configuration.values == ["toggle": .boolean(false)])
    }

    @Test(arguments: [
        #"[{"id":"../bad","label":"Bad","type":"text"}]"#,
        #"[{"id":"x","label":" ","type":"text"}]"#,
        #"[{"id":"x","label":"X","type":"secret","default":"hunter2"}]"#,
        #"[{"id":"x","label":"X","type":"number","multiline":true}]"#,
        #"[{"id":"x","label":"X","type":"text","mustExist":true}]"#,
        #"[{"id":"x","label":"X","type":"folder","extensions":["json"]}]"#,
        #"[{"id":"x","label":"X","type":"file","extensions":[""]}]"#,
        #"[{"id":"x","label":"X","type":"file","default":3}]"#,
        #"[{"id":"x","label":"X","type":"list","default":"a"}]"#,
        #"[{"id":"x","label":"X","type":"list","required":true,"default":[]}]"#,
        #"[{"id":"x","label":"X","type":"list","default":["a",""]}]"#,
        #"[{"id":"x","label":"X","type":"list","default":["a\nb"]}]"#,
        #"[{"id":"x","label":"X","type":"number","min":3,"max":2}]"#,
        #"[{"id":"x","label":"X","type":"text","min":1}]"#,
        #"[{"id":"x","label":"X","type":"boolean","default":"true"}]"#,
        #"[{"id":"x","label":"X","type":"number","max":5,"default":6}]"#,
        #"[{"id":"x","label":"X","type":"text","required":true,"default":" "}]"#,
        #"[{"id":"x","label":"X","type":"choice","options":[]}]"#,
        #"[{"id":"x","label":"X","type":"choice","options":[{"value":"a","label":"A"},{"value":"a","label":"B"}]}]"#,
        #"[{"id":"x","label":"X","type":"choice","default":"b","options":[{"value":"a","label":"A"}]}]"#,
    ])
    func invalidSchemasAreRejected(json: String) {
        #expect(throws: DecodingError.self) { try settings(json) }
    }

    @Test func manifestsRejectDuplicateFieldsAndOlderManifestsNeedNoSetup() throws {
        let json = #"{"id":"test","name":"Test","commands":[],"settings":[{"id":"x","label":"X","type":"text"},{"id":"x","label":"X","type":"text"}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)) }
        let old = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"old","name":"Old","commands":[]}"#.utf8))
        #expect(old.settings.isEmpty)
        #expect(PluginConfiguration(settings: old.settings).isValid)
    }

    @Test func settingsPersistIndependentlyAndResetOnlyTheChosenPlugin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory.appendingPathComponent("PluginSettings"), secrets: MemorySecretStore())
        #expect(try store.load(for: "test", settings: []).isEmpty)
        try store.reset(for: "test")
        let configuration = PluginConfiguration(settings: try settings(schema), saved: ["organization": .string("openai")])
        try store.save(configuration.values, for: "test", settings: [])
        try store.save(["keep": .boolean(true)], for: "other", settings: [])
        // A fresh store after reinstalling reads the same host-owned values.
        let reinstalled = PluginConfigurationStore(directory: store.directory, secrets: MemorySecretStore())
        #expect(try reinstalled.load(for: "test", settings: []) == configuration.values)
        try reinstalled.reset(for: "test")
        #expect(try reinstalled.load(for: "test", settings: []).isEmpty)
        #expect(try reinstalled.load(for: "other", settings: []) == ["keep": .boolean(true)])
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.save([:], for: "../escape", settings: []) }
    }

    @Test func unreadableSettingsAreNotSilentlyTreatedAsConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory, secrets: MemorySecretStore())
        let file = directory.appendingPathComponent("test.json")
        try Data("{".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: "test", settings: []) }
        #expect(try Data(contentsOf: file) == Data("{".utf8))
        #expect(!PluginConfiguration(settings: [], problem: "Unreadable settings").isValid)
    }

    @Test func oversizedSettingsAreRejectedBeforeReplacingThePreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory, secrets: MemorySecretStore())
        try store.save(["text": .string("original")], for: "test", settings: [])
        let oversized = ["text": PluginSettingValue.string(String(repeating: "x", count: PluginConfigurationStore.maxBytes))]
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.save(oversized, for: "test", settings: []) }
        #expect(try store.load(for: "test", settings: []) == ["text": .string("original")])
    }

    @Test func oversizedExternalFilesAreRejectedOnRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory, secrets: MemorySecretStore())
        try Data(repeating: 32, count: PluginConfigurationStore.maxBytes + 1)
            .write(to: directory.appendingPathComponent("test.json"))
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.load(for: "test", settings: []) }
    }

    // MARK: - Secrets

    private let secretSchema = #"""
    [{"id":"token","label":"Token","type":"secret","required":true},
     {"id":"extra","label":"Extra","type":"secret"},
     {"id":"organization","label":"Organization","type":"text"}]
    """#

    @Test func secretsValidateLikeTextAndReachThePluginAsStrings() throws {
        let fields = try settings(secretSchema)
        #expect(fields[0].type == .secret)
        let missing = PluginConfiguration(settings: fields)
        #expect(missing.errors.keys.sorted() == ["token"])
        #expect(PluginConfiguration(settings: fields, saved: ["token": .string(" \n")]).errors["token"] != nil)
        let configured = PluginConfiguration(settings: fields, saved: ["token": .string("hunter2"), "organization": .string("o")])
        #expect(configured.isValid)
        #expect(configured.secretIDs == ["token", "extra"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(configured.json().utf8)) as? [String: Any])
        #expect(object["token"] as? String == "hunter2")
        #expect(object["extra"] == nil)
        // A set secret is a string setting like any other; an unset one is not exported.
        #expect(configured.variables == ["SPOTLITE_CONFIG_TOKEN": "hunter2", "SPOTLITE_CONFIG_ORGANIZATION": "o"])
    }

    @Test func secretsAreNeverWrittenToTheSettingsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemorySecretStore()
        let store = PluginConfigurationStore(directory: directory, secrets: secrets)
        let fields = try settings(secretSchema)
        try store.save(["token": .string("hunter2"), "organization": .string("o")], for: "test", settings: fields)
        let file = try String(contentsOf: directory.appendingPathComponent("test.json"), encoding: .utf8)
        #expect(!file.contains("hunter2") && !file.contains("token"))
        #expect(secrets.snapshot == ["test": ["token": "hunter2"]])
        #expect(try store.load(for: "test", settings: fields) == ["token": .string("hunter2"), "organization": .string("o")])
        // A secret someone wrote into the file by hand does not override the stored one.
        try Data(#"{"token":"from-file"}"#.utf8).write(to: directory.appendingPathComponent("test.json"))
        #expect(try store.load(for: "test", settings: fields)["token"] == .string("hunter2"))
        // Clearing an optional secret, or saving without it, removes the stored value.
        try store.save(["token": .string("new"), "extra": .string("x")], for: "test", settings: fields)
        #expect(secrets.snapshot["test"] == ["token": "new", "extra": "x"])
        try store.save(["token": .string("new")], for: "test", settings: fields)
        #expect(secrets.snapshot["test"] == ["token": "new"])
    }

    @Test func resetClearsSecretsAndRemovalKeepsThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemorySecretStore()
        let store = PluginConfigurationStore(directory: directory, secrets: secrets)
        let fields = try settings(secretSchema)
        try store.save(["token": .string("a")], for: "test", settings: fields)
        try store.save(["token": .string("b")], for: "other", settings: fields)
        try secrets.write("obsolete", plugin: "test", field: "removed")
        // A reinstalled plugin finds its secret again.
        #expect(try PluginConfigurationStore(directory: directory, secrets: secrets).load(for: "test", settings: fields)["token"] == .string("a"))
        try store.reset(for: "test")
        #expect(secrets.snapshot == ["other": ["token": "b"]])
        #expect(try store.load(for: "test", settings: fields).isEmpty)
    }

    @Test func savingLeavesUnchangedSecretsAlone() throws {
        /// Counts what reaches the store, as each call may reach the Keychain.
        final class Counting: PluginSecretStore, @unchecked Sendable {
            let inner = MemorySecretStore()
            private let lock = NSLock()
            private var calls: [String] = []
            var log: [String] { lock.withLock { calls } }
            func read(plugin: String, field: String) throws -> String? { try inner.read(plugin: plugin, field: field) }
            func write(_ value: String, plugin: String, field: String) throws {
                lock.withLock { calls.append("write \(field)") }
                try inner.write(value, plugin: plugin, field: field)
            }
            func delete(plugin: String, field: String) throws {
                lock.withLock { calls.append("delete \(field)") }
                try inner.delete(plugin: plugin, field: field)
            }
            func deleteAll(plugin: String) throws { try inner.deleteAll(plugin: plugin) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = Counting()
        let store = PluginConfigurationStore(directory: directory, secrets: secrets)
        let fields = try settings(secretSchema)
        // Without previous values every secret is written or cleared.
        try store.save(["token": .string("a")], for: "test", settings: fields)
        #expect(secrets.log == ["write token", "delete extra"])
        let saved = try store.load(for: "test", settings: fields)
        try store.save(saved.merging(["organization": .string("o")]) { $1 }, for: "test", settings: fields, previous: saved)
        #expect(secrets.log.count == 2, "an unchanged secret is not written again: \(secrets.log)")
        #expect(try store.load(for: "test", settings: fields) == ["token": .string("a"), "organization": .string("o")])
        // A changed, added or cleared secret still is; an empty one counts as cleared.
        try store.save(["token": .string("b"), "extra": .string("x")], for: "test", settings: fields, previous: saved)
        try store.save(["token": .string("")], for: "test", settings: fields,
                       previous: ["token": .string("b"), "extra": .string("x")])
        #expect(Array(secrets.log.dropFirst(2)) == ["write token", "write extra", "delete token", "delete extra"])
        #expect(secrets.inner.snapshot["test"]?.isEmpty == true)
    }

    @Test func keychainStoreRejectsUnsafeIdentifiers() {
        let keychain = KeychainSecretStore(prefix: "com.igorv.spotlite.tests.")
        #expect(throws: PluginConfigurationStore.Failure.self) { try keychain.read(plugin: "../x", field: "token") }
        #expect(throws: PluginConfigurationStore.Failure.self) { try keychain.write("x", plugin: "test", field: "a b") }
    }

    // MARK: - Paths, multi-line text and lists

    @Test func pathsExpandTildeForThePluginAndValidateExistenceOnlyWhenAsked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let fields = try settings(#"""
        [{"id":"config","label":"Config","type":"file","mustExist":true,"extensions":[".json","yaml"],"default":"~/missing.json"},
         {"id":"workspace","label":"Workspace","type":"folder","required":true,"default":"~"},
         {"id":"loose","label":"Loose","type":"folder"}]
        """#)
        #expect(fields[0].type == .file && fields[0].mustExist && fields[0].extensions == ["json", "yaml"])
        // A missing default path is a setup problem on this machine, not a schema error.
        let initial = PluginConfiguration(settings: fields)
        #expect(initial.errors.keys.sorted() == ["config"])
        #expect(initial.values["workspace"] == .string("~"))
        let configured = PluginConfiguration(settings: fields, saved: ["config": .string(file.path), "loose": .string("~/nowhere")])
        #expect(configured.isValid)
        let object = try #require(JSONSerialization.jsonObject(with: Data(configured.json().utf8)) as? [String: Any])
        #expect(object["workspace"] as? String == NSHomeDirectory())
        #expect(object["loose"] as? String == NSHomeDirectory() + "/nowhere")
        #expect(configured.values["workspace"] == .string("~"))
        // The per-field variables hold the same expanded paths: no shell expands them.
        #expect(configured.variables["SPOTLITE_CONFIG_WORKSPACE"] == NSHomeDirectory())
        #expect(configured.variables["SPOTLITE_CONFIG_LOOSE"] == NSHomeDirectory() + "/nowhere")
        // A folder is not a file and vice versa; empty optional paths need not exist.
        #expect(fields[0].validationError(for: .string(directory.path)) != nil)
        #expect(fields[1].validationError(for: .string(file.path)) == nil)
        #expect(fields[1].validationError(for: .string(" ")) != nil)
        let optional = try settings(#"[{"id":"x","label":"X","type":"file","mustExist":true}]"#)[0]
        #expect(optional.validationError(for: .string("")) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(!PluginConfiguration(settings: fields, saved: ["config": .string(file.path)]).isValid)
    }

    @Test func multilineTextIsAString() throws {
        let fields = try settings(#"[{"id":"notes","label":"Notes","type":"text","multiline":true,"required":true,"default":"a\nb"}]"#)
        #expect(fields[0].multiline)
        let configuration = PluginConfiguration(settings: fields)
        #expect(configuration.isValid && configuration.values["notes"] == .string("a\nb"))
        #expect(try configuration.json() == #"{"notes":"a\nb"}"#)
        #expect(fields[0].validationError(for: .string("\n \n")) != nil)
    }

    @Test func listsAreJSONArraysEditedOnePerLine() throws {
        let fields = try settings(#"""
        [{"id":"hosts","label":"Hosts","type":"list","required":true},
         {"id":"repos","label":"Repos","type":"list","default":["a/b","c/d"]}]
        """#)
        let initial = PluginConfiguration(settings: fields)
        #expect(initial.errors.keys.sorted() == ["hosts"])
        #expect(initial.values["repos"] == .list(["a/b", "c/d"]))
        #expect(initial.values["repos"]?.text == "a/b\nc/d")
        let edited = PluginSettingValue.list(lines: " one \n\n  \r\ntwo\n")
        #expect(edited == .list(["one", "two"]))
        #expect(PluginSettingValue.list(lines: "\n ") == .list([]))
        #expect(fields[0].validationError(for: .list([])) != nil)
        #expect(fields[0].validationError(for: .list(["ok", " "])) != nil)
        #expect(fields[0].validationError(for: .string("one")) != nil)
        let configured = PluginConfiguration(settings: fields, saved: ["hosts": edited])
        #expect(configured.isValid)
        let object = try #require(JSONSerialization.jsonObject(with: Data(configured.json().utf8)) as? [String: Any])
        #expect(object["hosts"] as? [String] == ["one", "two"])
        // Lists round-trip through the settings file next to other types.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory, secrets: MemorySecretStore())
        let values: [String: PluginSettingValue] = ["hosts": edited, "empty": .list([]), "flag": .boolean(true), "name": .string("x")]
        try store.save(values, for: "test", settings: fields)
        #expect(try store.load(for: "test", settings: fields) == values)
    }
}
