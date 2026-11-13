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
        #"[{"id":"x","label":"X","type":"secret"}]"#,
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
        let store = PluginConfigurationStore(directory: directory.appendingPathComponent("PluginSettings"))
        #expect(try store.load(for: "test").isEmpty)
        try store.reset(for: "test")
        let configuration = PluginConfiguration(settings: try settings(schema), saved: ["organization": .string("openai")])
        try store.save(configuration.values, for: "test")
        try store.save(["keep": .boolean(true)], for: "other")
        // A fresh store after reinstalling reads the same host-owned values.
        let reinstalled = PluginConfigurationStore(directory: store.directory)
        #expect(try reinstalled.load(for: "test") == configuration.values)
        try reinstalled.reset(for: "test")
        #expect(try reinstalled.load(for: "test").isEmpty)
        #expect(try reinstalled.load(for: "other") == ["keep": .boolean(true)])
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.save([:], for: "../escape") }
    }

    @Test func unreadableSettingsAreNotSilentlyTreatedAsConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory)
        let file = directory.appendingPathComponent("test.json")
        try Data("{".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: "test") }
        #expect(try Data(contentsOf: file) == Data("{".utf8))
        #expect(!PluginConfiguration(settings: [], problem: "Unreadable settings").isValid)
    }

    @Test func oversizedSettingsAreRejectedBeforeReplacingThePreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory)
        try store.save(["text": .string("original")], for: "test")
        let oversized = ["text": PluginSettingValue.string(String(repeating: "x", count: PluginConfigurationStore.maxBytes))]
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.save(oversized, for: "test") }
        #expect(try store.load(for: "test") == ["text": .string("original")])
    }

    @Test func oversizedExternalFilesAreRejectedOnRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigurationStore(directory: directory)
        try Data(repeating: 32, count: PluginConfigurationStore.maxBytes + 1)
            .write(to: directory.appendingPathComponent("test.json"))
        #expect(throws: PluginConfigurationStore.Failure.self) { try store.load(for: "test") }
    }
}
