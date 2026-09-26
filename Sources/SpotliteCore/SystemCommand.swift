import Foundation

/// Built-in actions that search like apps: each is an entry with its own identity, so it
/// can be hidden, given an alias and learn launch history exactly as an app does.
public enum SystemCommand: String, CaseIterable, Sendable {
    case lockScreen
    case sleep
    case sleepDisplays
    case screenSaver
    case restart
    case shutDown
    case logOut
    case emptyTrash
    case toggleDarkMode

    static let idPrefix = "com.igorv.spotlite.command."

    /// Stands in for a bundle identifier, so hiding, aliases and history key on it.
    public var id: String { SystemCommand.idPrefix + rawValue }

    public init?(id: String) {
        guard id.hasPrefix(SystemCommand.idPrefix) else { return nil }
        self.init(rawValue: String(id.dropFirst(SystemCommand.idPrefix.count)))
    }

    public var name: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .sleep: return "Sleep"
        case .sleepDisplays: return "Sleep Displays"
        case .screenSaver: return "Start Screen Saver"
        case .restart: return "Restart"
        case .shutDown: return "Shut Down"
        case .logOut: return "Log Out"
        case .emptyTrash: return "Empty Trash"
        case .toggleDarkMode: return "Toggle Dark Mode"
        }
    }

    /// Never opened: the URL only gives the entry an identity no app path can collide with.
    public var entry: AppEntry {
        AppEntry(url: URL(string: "spotlite:command/" + rawValue)!, name: name, bundleID: id, kind: .command)
    }

    public static let entries = allCases.map(\.entry)
}
