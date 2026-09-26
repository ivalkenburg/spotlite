import Foundation
import Testing
@testable import SpotliteCore

@Suite("Settings pane index")
struct SettingsPaneIndexTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotliteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExtension(in directory: URL, file: String, bundleID: String, name: String,
                               point: String = SettingsPaneIndex.extensionPoint) throws {
        let contents = directory.appendingPathComponent("\(file).appex/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": name,
            "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": point],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func scansOnlySidebarPanes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExtension(in: root, file: "Pane", bundleID: "test.pane", name: "Pane")
        try makeExtension(in: root, file: "Widget", bundleID: "test.widget", name: "Widget",
                          point: "com.apple.appintents-extension")
        try makeExtension(in: root, file: "FollowUps",
                          bundleID: "com.apple.FollowUpSettings.FollowUpSettingsExtension", name: "FollowUps")

        let panes = SettingsPaneIndex.scan(directory: root)
        #expect(panes.map(\.name) == ["Pane"])
        #expect(panes.first?.kind == .settingsPane)
        #expect(panes.first?.id == "test.pane")
    }

    @Test func nameFallsBackFromLocalizedToTableToInfoPlist() {
        let battery = "com.apple.Battery-Settings.extension"
        let info = ["CFBundleDisplayName": "PowerPreferences"]
        #expect(SettingsPaneIndex.name(localized: ["CFBundleDisplayName": "Batterie"], info: info,
                                       bundleID: battery) == "Batterie")
        #expect(SettingsPaneIndex.name(localized: nil, info: info, bundleID: battery) == "Battery")
        #expect(SettingsPaneIndex.name(localized: [:], info: ["CFBundleName": "Bluetooth"],
                                       bundleID: "x") == "Bluetooth")
        #expect(SettingsPaneIndex.name(localized: ["CFBundleDisplayName": " "], info: [:], bundleID: "x") == nil)
    }

    /// Against this Mac's own panes: the names the sidebar shows, none of the internal ones.
    @Test func realPanesHaveSidebarNames() {
        let names = Set(SettingsPaneIndex.scan().map(\.name))
        #expect(names.isSuperset(of: ["General", "Bluetooth", "Battery", "Displays", "Wi\u{2011}Fi"]))
        #expect(!names.contains { $0.contains("Extension") || $0 == "PowerPreferences" || $0 == "FollowUps" })
    }
}
