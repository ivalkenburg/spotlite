import Foundation

/// Finds the System Settings panes, which macOS ships as ExtensionKit extensions. Read
/// from disk rather than listed by hand, so names follow the user's language and the
/// list follows the OS: macOS 27 renamed Control Center to Menu Bar.
public enum SettingsPaneIndex {

    public static let directory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")

    /// The extension point every sidebar pane declares.
    static let extensionPoint = "com.apple.Settings.extension.ui"

    /// Panes that declare the extension point but never appear in the sidebar.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
        "com.apple.ClassKit-Settings.extension",
        "com.apple.Classroom-Settings.extension",
        "com.apple.SecurityImprovements-Settings.extension",
    ]

    /// Panes with no localized name, whose Info.plist names are internal ones. English
    /// only, and used only when nothing localized exists.
    static let fallbackNames = [
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.HeadphoneSettings": "Headphones",
    ]

    public static let systemSettingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// Opens a pane by bundle identifier.
    public static func url(for bundleID: String) -> URL? {
        URL(string: "x-apple.systempreferences:" + bundleID)
    }

    /// Scanned once per process. Unlike /Applications these bundles only change with an OS
    /// update, which restarts Spotlite, so rereading ~280 plists on every app change
    /// would find nothing new.
    public static let installed = scan()

    public static func scan(directory: URL = directory) -> [AppEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { url in
            guard url.pathExtension == "appex",
                  let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as? [String: Any],
                  pointIdentifier(info) == extensionPoint,
                  let bundleID = info[kCFBundleIdentifierKey as String] as? String,
                  !excludedBundleIDs.contains(bundleID)
            else { return nil }
            // `Bundle(url:)` is cached for the process's lifetime, which AppIndex avoids
            // for apps. Harmless here, for the same reason `installed` is scanned once.
            let localized = Bundle(url: url)?.localizedInfoDictionary
            guard let name = name(localized: localized, info: info, bundleID: bundleID) else { return nil }
            return AppEntry(url: url, name: name, bundleID: bundleID, kind: .settingsPane)
        }
    }

    /// The localized name, then the fallback table, then whatever Info.plist says.
    static func name(localized: [String: Any]?, info: [String: Any], bundleID: String) -> String? {
        let candidates = [
            localized?["CFBundleDisplayName"], localized?["CFBundleName"],
            fallbackNames[bundleID],
            info["CFBundleDisplayName"], info["CFBundleName"],
        ]
        for case let name as String in candidates {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func pointIdentifier(_ info: [String: Any]) -> String? {
        (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String
    }
}
