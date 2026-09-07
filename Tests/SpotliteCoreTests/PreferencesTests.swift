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
        prefs.aliases = ["com.adobe.Photoshop": "ps"]
        prefs.panelScreen = .primary
        prefs.themeMode = .dark
        prefs.showMenuBarIcon = false
        prefs.hasCompletedFirstRun = true

        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == prefs)
        #expect(String(decoding: data, as: UTF8.self).contains(#""formatVersion":1"#))
    }

    /// A file written by an older build has no `aliases` or `panelScreen` key. It must
    /// decode with those defaulted rather than throwing and resetting every other setting.
    @Test func decodesPreferencesWrittenByAnOlderBuild() throws {
        let old = Data(#"{"hiddenBundleIDs":["com.example.one"],"hotKeyCode":49,"hotKeyModifiers":2048,"showMenuBarIcon":false,"hasCompletedFirstRun":true}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.hiddenBundleIDs == ["com.example.one"])
        #expect(decoded.showMenuBarIcon == false)
        #expect(decoded.hasCompletedFirstRun)
        #expect(decoded.aliases.isEmpty)
        #expect(decoded.panelScreen == .followPointer)
        #expect(decoded.themeMode == .system)
    }

    @Test func defaultsToSystemTheme() {
        #expect(Preferences().themeMode == .system)
    }

    @Test func decodingRealGarbageStillFails() {
        #expect((try? JSONDecoder().decode(Preferences.self, from: Data("not json".utf8))) == nil)
    }

    @Test func rejectsUnknownFutureFormat() {
        let future = Data(#"{"formatVersion":999}"#.utf8)
        #expect((try? JSONDecoder().decode(Preferences.self, from: future)) == nil)
    }
}
