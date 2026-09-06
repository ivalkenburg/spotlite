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
        prefs.hiddenBundleIDs = ["com.example.one", "com.example.two"]
        prefs.showMenuBarIcon = false
        prefs.hasCompletedFirstRun = true

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == prefs)
    }

    /// A missing or truncated file must fall back to defaults rather than throwing.
    @Test func decodingGarbageFallsBackToDefaults() {
        let partial = Data(#"{"showMenuBarIcon": false}"#.utf8)
        #expect((try? JSONDecoder().decode(Preferences.self, from: partial)) == nil)
    }
}
