import Carbon.HIToolbox
import Foundation
import Testing
@testable import SpotliteCore

@Suite("Preferences")
struct PreferencesTests {

    /// SpotliteCore doesn't import Carbon, so the default shortcut is written as raw
    /// numbers. This is the only thing stopping those numbers from silently drifting.
    @Test func defaultsMatchCarbonConstants() {
        #expect(Preferences.defaultKeyCode == UInt32(kVK_Space))
        #expect(Preferences.defaultModifiers == UInt32(optionKey))
    }

    @Test func roundTripsThroughJSON() throws {
        var prefs = Preferences()
        prefs.hiddenUtilities = [.caffeinate, .unitConversion]
        prefs.hiddenBundleIDs = ["com.example.one", "com.example.two"]
        prefs.aliases = ["com.adobe.Photoshop": "ps"]
        prefs.panelScreen = .primary
        prefs.themeMode = .dark
        prefs.glassTint = 0.4
        prefs.showMenuBarIcon = false
        prefs.hasCompletedFirstRun = true
        prefs.queryRetention = 12
        prefs.backNavigationBehavior = .clearQuery
        prefs.showSystemCommands = false
        prefs.showRecentApps = true
        prefs.showRunningIndicator = false
        prefs.appNameCompletion = .prefixOnly
        prefs.showWebSearch = false
        prefs.webSearchEngine = .bing
        prefs.links = [Link(name: "Downloads", target: "~/Downloads")]
        prefs.visibleRows = 9

        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == prefs)
        #expect(String(decoding: data, as: UTF8.self).contains(#""formatVersion":2"#))
    }

    /// A file written by an older build has no `aliases` or `panelScreen` key. It must
    /// decode with those defaulted rather than throwing and resetting every other setting.
    @Test func decodesPreferencesWrittenByAnOlderBuild() throws {
        let old = Data(#"{"hiddenBundleIDs":["com.example.one"],"hotKeyCode":49,"hotKeyModifiers":2048,"showMenuBarIcon":false,"hasCompletedFirstRun":true}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.hiddenUtilities.isEmpty)
        #expect(decoded.hiddenBundleIDs == ["com.example.one"])
        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.hasCompletedFirstRun)
        #expect(decoded.aliases.isEmpty)
        #expect(decoded.panelScreen == .followPointer)
        #expect(decoded.themeMode == .system)
        #expect(decoded.glassTint == 0)
        #expect(decoded.queryRetention == 0)
        #expect(decoded.backNavigationBehavior == .restoreQuery)
        #expect(decoded.showSystemSettings)
        #expect(decoded.showSystemCommands)
        #expect(!decoded.showRecentApps)
        #expect(decoded.appNameCompletion == .allMatches)
        #expect(decoded.showRunningIndicator)
        #expect(decoded.showWebSearch)
        #expect(decoded.webSearchEngine == .duckDuckGo)
        #expect(decoded.links.isEmpty)
        #expect(decoded.visibleRows == 7)
    }

    /// A hand-edited row count must not size the panel off the screen or to nothing.
    @Test func clampsVisibleRows() throws {
        let tooMany = Data(#"{"visibleRows":50}"#.utf8)
        let tooFew = Data(#"{"visibleRows":0}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: tooMany).visibleRows == 10)
        #expect(try JSONDecoder().decode(Preferences.self, from: tooFew).visibleRows == 4)
        #expect(Preferences(visibleRows: 2).visibleRows == 4)
    }

    /// One hand-edited link must not reset every other setting, or lose the good links.
    @Test func malformedLinkIsDroppedAlone() throws {
        let data = Data(#"{"links":[{"name":"No id","target":"/tmp"},{"id":"L","name":"Tmp","target":"/tmp"}],"showMenuBarIcon":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.links.map(\.id) == ["L"])
        #expect(!decoded.showMenuBarIcon)
    }

    /// An engine a later build dropped must not reset every other setting.
    @Test func unknownSearchEngineFallsBack() throws {
        let data = Data(#"{"webSearchEngine":"kagi","showMenuBarIcon":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.webSearchEngine == .duckDuckGo)
        #expect(!decoded.showMenuBarIcon)
    }

    @Test func unknownBackNavigationBehaviorFallsBack() throws {
        let data = Data(#"{"backNavigationBehavior":"futureOption","showMenuBarIcon":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.backNavigationBehavior == .restoreQuery)
        #expect(!decoded.showMenuBarIcon)
    }

    @Test func utilitiesAreVisibleByDefault() {
        #expect(Preferences().hiddenUtilities.isEmpty)
    }

    @Test func unknownUtilityDoesNotLoseOtherPreferences() throws {
        let data = Data(#"{"hiddenUtilities":["caffeinate","futureUtility",42,"calculator"],"showMenuBarIcon":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.hiddenUtilities == [.caffeinate, .calculator])
        #expect(!decoded.showMenuBarIcon)
    }

    @Test func completionModesPersist() throws {
        for mode in AppNameCompletion.allCases {
            let prefs = Preferences(appNameCompletion: mode)
            let data = try JSONEncoder().encode(prefs)
            #expect(try JSONDecoder().decode(Preferences.self, from: data).appNameCompletion == mode)
        }
        #expect(Preferences().appNameCompletion == .allMatches)
    }

    @Test func unknownCompletionModeFallsBack() throws {
        let data = Data(#"{"appNameCompletion":"futureOption","showMenuBarIcon":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.appNameCompletion == .allMatches)
        #expect(!decoded.showMenuBarIcon)
    }

    @Test func backNavigationRestoresQueryByDefault() {
        #expect(Preferences().backNavigationBehavior == .restoreQuery)
    }

    @Test func movesAnUntouchedPanelToTheNewDefault() throws {
        let untouched = Data(#"{"formatVersion":1,"panelGeometry":{"width":720,"verticalFraction":0.22}}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: untouched).panelGeometry == .default)
    }

    @Test func keepsAPanelTheUserDragged() throws {
        let dragged = Data(#"{"formatVersion":1,"panelGeometry":{"width":900,"verticalFraction":0.22}}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: dragged).panelGeometry.width == 900)
    }

    /// Once migrated, the old default is an ordinary choice the user may make again.
    @Test func doesNotMigrateTwice() throws {
        let current = Data(#"{"formatVersion":2,"panelGeometry":{"width":720,"verticalFraction":0.22}}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: current).panelGeometry == .legacyDefault)
    }

    @Test func defaultsToSystemTheme() {
        #expect(Preferences().themeMode == .system)
    }

    @Test func defaultsToUntintedGlass() {
        #expect(Preferences().glassTint == 0)
    }

    @Test func clampsAHandEditedTint() throws {
        let high = Data(#"{"formatVersion":2,"glassTint":3.5}"#.utf8)
        let low = Data(#"{"formatVersion":2,"glassTint":-1}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: high).glassTint == 1)
        #expect(try JSONDecoder().decode(Preferences.self, from: low).glassTint == 0)
    }

    @Test func clampsAHandEditedQueryRetention() throws {
        let high = Data(#"{"formatVersion":2,"queryRetention":600}"#.utf8)
        let low = Data(#"{"formatVersion":2,"queryRetention":-5}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: high).queryRetention == 30)
        #expect(try JSONDecoder().decode(Preferences.self, from: low).queryRetention == 0)
    }

    @Test func decodingRealGarbageStillFails() {
        #expect((try? JSONDecoder().decode(Preferences.self, from: Data("not json".utf8))) == nil)
    }

    @Test func rejectsUnknownFutureFormat() {
        let future = Data(#"{"formatVersion":999}"#.utf8)
        #expect((try? JSONDecoder().decode(Preferences.self, from: future)) == nil)
    }
}
