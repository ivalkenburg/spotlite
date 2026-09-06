import Foundation

/// User settings. Lives in Application Support, never in Caches: the hidden-app list
/// is not regenerable, and eviction would silently un-hide everything.
public struct Preferences: Codable, Sendable, Equatable {
    public var hiddenBundleIDs: Set<String>
    public var hotKeyCode: UInt32
    public var hotKeyModifiers: UInt32
    public var showMenuBarIcon: Bool
    public var hasCompletedFirstRun: Bool

    /// Option-Space: free on a stock system, unlike Control-Space and Command-Space.
    ///
    /// Written as literals because this module deliberately doesn't import Carbon.
    /// `PreferencesTests.defaultsMatchCarbonConstants` pins them to `kVK_Space` and
    /// `optionKey` so the two can't drift apart unnoticed.
    public static let defaultKeyCode: UInt32 = 49
    public static let defaultModifiers: UInt32 = 2048

    public init(
        hiddenBundleIDs: Set<String> = [],
        hotKeyCode: UInt32 = Preferences.defaultKeyCode,
        hotKeyModifiers: UInt32 = Preferences.defaultModifiers,
        showMenuBarIcon: Bool = true,
        hasCompletedFirstRun: Bool = false
    ) {
        self.hiddenBundleIDs = hiddenBundleIDs
        self.hotKeyCode = hotKeyCode
        self.hotKeyModifiers = hotKeyModifiers
        self.showMenuBarIcon = showMenuBarIcon
        self.hasCompletedFirstRun = hasCompletedFirstRun
    }
}

/// Reads and writes the two on-disk files. Preferences and frecency live together in
/// Application Support; the app index lives in Caches because it is regenerable.
public enum Storage {

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotlite", isDirectory: true)
    }

    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotlite", isDirectory: true)
    }

    private static var preferencesURL: URL { supportDirectory.appendingPathComponent("prefs.json") }
    private static var frecencyURL: URL { supportDirectory.appendingPathComponent("frecency.json") }
    private static var indexURL: URL { cacheDirectory.appendingPathComponent("index.json") }

    public static func loadPreferences() -> Preferences {
        load(Preferences.self, from: preferencesURL) ?? Preferences()
    }

    public static func save(_ preferences: Preferences) {
        save(preferences, to: preferencesURL)
    }

    public static func loadFrecency() -> Frecency {
        load(Frecency.self, from: frecencyURL) ?? Frecency()
    }

    public static func save(_ frecency: Frecency) {
        save(frecency, to: frecencyURL)
    }

    public static func loadIndex() -> [CachedApp]? {
        load([CachedApp].self, from: indexURL)
    }

    public static func saveIndex(_ apps: [CachedApp]) {
        save(apps, to: indexURL)
    }

    // MARK: -

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes atomically: a partial file from an interrupted write would otherwise
    /// fail to decode and silently reset the user's settings.
    private static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Spotlite: failed to write \(url.lastPathComponent): \(error)")
        }
    }
}
