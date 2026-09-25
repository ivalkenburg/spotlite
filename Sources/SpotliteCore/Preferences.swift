import Foundation

/// User settings. Lives in Application Support, never in Caches: the hidden-app list
/// is not regenerable, and eviction would silently un-hide everything.
/// Which display the panel opens on.
public enum PanelScreen: String, Codable, Sendable {
    /// The display holding the pointer — your eyes are usually where your mouse is.
    case followPointer
    /// Always the display with the menu bar.
    case primary
}

/// The appearance Spotlite uses. `system` follows the current macOS appearance.
public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case light
    case dark
    case system
}

public struct Preferences: Codable, Sendable, Equatable {
    /// 2: geometry left at the version-1 default moves to Spotlight's placement.
    private static let currentFormatVersion = 2
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case hiddenBundleIDs, aliases, panelScreen, panelGeometry, themeMode
        case hotKeyCode, hotKeyModifiers, showMenuBarIcon, hasCompletedFirstRun
    }

    public var hiddenBundleIDs: Set<String>
    /// Bundle ID to a short name the user types instead, e.g. "ps" for Photoshop.
    public var aliases: [String: String]
    public var panelScreen: PanelScreen
    /// Width and vertical position, adjusted by dragging the panel's edges and header.
    public var panelGeometry: PanelGeometry
    public var themeMode: ThemeMode
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

    /// Hand-written so a preferences file saved by an older build - which has no
    /// `aliases` or `panelScreen` key - still decodes instead of resetting everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        guard (0...Preferences.currentFormatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion, in: c,
                debugDescription: "Unsupported preferences format version \(version)"
            )
        }
        hiddenBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenBundleIDs) ?? []
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        panelScreen = try c.decodeIfPresent(PanelScreen.self, forKey: .panelScreen) ?? .followPointer
        panelGeometry = try c.decodeIfPresent(PanelGeometry.self, forKey: .panelGeometry) ?? .default
        // Only an untouched panel moves: a width or position the user dragged to on
        // purpose is kept.
        if version < 2, panelGeometry == .legacyDefault { panelGeometry = .default }
        themeMode = try c.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        hotKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) ?? Preferences.defaultKeyCode
        hotKeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? Preferences.defaultModifiers
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        hasCompletedFirstRun = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedFirstRun) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Preferences.currentFormatVersion, forKey: .formatVersion)
        try c.encode(hiddenBundleIDs, forKey: .hiddenBundleIDs)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(panelScreen, forKey: .panelScreen)
        try c.encode(panelGeometry, forKey: .panelGeometry)
        try c.encode(themeMode, forKey: .themeMode)
        try c.encode(hotKeyCode, forKey: .hotKeyCode)
        try c.encode(hotKeyModifiers, forKey: .hotKeyModifiers)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(hasCompletedFirstRun, forKey: .hasCompletedFirstRun)
    }

    public init(
        hiddenBundleIDs: Set<String> = [],
        aliases: [String: String] = [:],
        panelScreen: PanelScreen = .followPointer,
        panelGeometry: PanelGeometry = .default,
        themeMode: ThemeMode = .system,
        hotKeyCode: UInt32 = Preferences.defaultKeyCode,
        hotKeyModifiers: UInt32 = Preferences.defaultModifiers,
        showMenuBarIcon: Bool = true,
        hasCompletedFirstRun: Bool = false
    ) {
        self.hiddenBundleIDs = hiddenBundleIDs
        self.aliases = aliases
        self.panelScreen = panelScreen
        self.panelGeometry = panelGeometry
        self.themeMode = themeMode
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
        loadPreferences(from: preferencesURL)
    }

    /// Internal entry point used by tests and recovery tooling. A malformed preferences
    /// file is moved aside before defaults are returned, so first-run persistence cannot
    /// silently destroy the only copy of the user's settings.
    static func loadPreferences(from url: URL) -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return Preferences() }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            preserveCorruptFile(at: url)
            return Preferences()
        }
        return decoded
    }

    public static func save(_ preferences: Preferences) {
        save(preferences, to: preferencesURL)
    }

    static func save(_ preferences: Preferences, to url: URL) { write(preferences, to: url) }

    public static func loadFrecency() -> Frecency {
        loadFrecency(from: frecencyURL)
    }

    static func loadFrecency(from url: URL) -> Frecency {
        load(Frecency.self, from: url) ?? Frecency()
    }

    public static func save(_ frecency: Frecency) {
        save(frecency, to: frecencyURL)
    }

    static func save(_ frecency: Frecency, to url: URL) { write(frecency, to: url) }

    public static func loadIndex() -> [CachedApp]? {
        loadIndex(from: indexURL)
    }

    static func loadIndex(from url: URL) -> [CachedApp]? { load([CachedApp].self, from: url) }

    public static func saveIndex(_ apps: [CachedApp]) {
        saveIndex(apps, to: indexURL)
    }

    static func saveIndex(_ apps: [CachedApp], to url: URL) { write(apps, to: url) }

    // MARK: -

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func preserveCorruptFile(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            NSLog("Spotlite: preserved invalid preferences as \(backup.lastPathComponent)")
        } catch {
            NSLog("Spotlite: could not preserve invalid preferences: \(error)")
        }
    }

    /// Writes atomically: a partial file from an interrupted write would otherwise
    /// fail to decode and silently reset the user's settings.
    private static func write<T: Encodable>(_ value: T, to url: URL) {
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
