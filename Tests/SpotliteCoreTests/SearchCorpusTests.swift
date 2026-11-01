import Foundation
import Testing
@testable import SpotliteCore

@Suite("Search corpus")
struct SearchCorpusTests {
    private let apps = ["Safari", "Photoshop", "Terminal"].map { name in
        AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: "app.\(name)")
    }
    private let pane = AppEntry(url: URL(fileURLWithPath: "/tmp/Bluetooth.appex"), name: "Bluetooth",
                                bundleID: "pane.bluetooth", kind: .settingsPane)

    @Test func dropsHiddenEntriesAndSwitchedOffPanes() {
        let all = apps + [pane]
        #expect(SearchCorpus(entries: all).entries == all)
        #expect(SearchCorpus(entries: all, includeSettingsPanes: false).entries == apps)
        #expect(SearchCorpus(entries: all, hiddenBundleIDs: ["app.Safari", "pane.bluetooth"]).entries
                == Array(apps.dropFirst()))
    }

    @Test func dropsSwitchedOffCommandsButKeepsLinks() throws {
        let link = try #require(Link(name: "Downloads", target: "/tmp").entry)
        let all = apps + SystemCommand.entries + [link]
        #expect(SearchCorpus(entries: all, includeCommands: false).entries == apps + [link])
    }

    /// Aliases are resolved per entry after filtering, so a hidden entry before an
    /// aliased one must not shift the alias onto its neighbour.
    @Test func aliasesStayWithTheirEntryAfterFiltering() {
        let corpus = SearchCorpus(entries: apps, aliases: AliasIndex(aliases: ["app.Terminal": "xy"]),
                                  hiddenBundleIDs: ["app.Safari"])
        let hits = Matcher().matches("xy", in: corpus)
        #expect(hits.map(\.entry.name) == ["Terminal"])
        #expect(hits.first?.tier == .aliasPrefix)
    }

    @Test func hidingAnIDHidesEveryCopyOfIt() {
        let copy = AppEntry(url: URL(fileURLWithPath: "/Volumes/Old/Safari.app"), name: "Safari", bundleID: "app.Safari")
        let corpus = SearchCorpus(entries: apps + [copy], hiddenBundleIDs: ["app.Safari"])
        #expect(corpus.entries.map(\.name) == ["Photoshop", "Terminal"])
    }

    @Test func anAppWithoutABundleIDCannotBeHidden() {
        let tool = AppEntry(url: URL(fileURLWithPath: "/Applications/Tool.app"), name: "Tool", bundleID: nil)
        #expect(SearchCorpus(entries: [tool], hiddenBundleIDs: [tool.id]).entries == [tool])
    }

    @Test func noAliasesMeansNoPerEntryLookups() {
        #expect(SearchCorpus(entries: apps).aliases.isEmpty)
    }
}
