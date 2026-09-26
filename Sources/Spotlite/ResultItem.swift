import AppKit
import SpotliteCore

/// A row in the results list. Apps, the calculator, and the self-indexed Settings entry
/// all flow through the same cursor, Enter handling and rendering.
@MainActor
enum ResultItem {
    case app(MatchResult)
    /// The expression is kept as typed: the card shows it above the result.
    case calculation(expression: String, value: Double)
    case settings
    case caffeinate(state: CaffeineState)

    init(_ result: SearchResult, caffeine: CaffeineState) {
        switch result {
        case .app(let match): self = .app(match)
        case .calculation(let expression, let value): self = .calculation(expression: expression, value: value)
        case .settings: self = .settings
        case .caffeinate: self = .caffeinate(state: caffeine)
        }
    }

    /// Unchanged when the list is rebuilt for the same query, so a selection can follow
    /// its row. An app's is its path, which cannot collide with the fixed names.
    var identity: String {
        switch self {
        case .app(let match): return match.entry.instanceID
        case .calculation: return "calculation"
        case .settings: return "settings"
        case .caffeinate: return "caffeinate"
        }
    }

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(_, let value): return Calculator.format(value)
        case .settings: return "Spotlite Settings"
        case .caffeinate: return "Caffeinate"
        }
    }

    /// Rows that carry a switch. The switch is the state, so the row needs no words to
    /// say whether it is on. For Caffeinate it is Spotlite's own assertion only: exactly
    /// what Return toggles.
    var switchState: Bool? {
        if case .caffeinate(let state) = self { return state.spotlite }
        return nil
    }

    /// The verb the completion pill names.
    private var action: String {
        if case .caffeinate(let state) = self { return state.spotlite ? "Turn Off" : "Turn On" }
        return "Open"
    }

    /// What the pill after the query says while this row is selected.
    func completion(for query: String) -> String {
        if case .calculation(_, let value) = self { return " = " + Calculator.format(value) }
        return Completion.suffix(query: query, title: title, action: action)
    }

    /// Text drawn at the right of the selected row, each optionally followed by a key
    /// badge, the way Spotlight draws "Search Safari" and a "tab" key.
    struct Hint: Equatable {
        let text: String
        let key: String?
    }

    /// An app shows where it lives, which tells two copies of the same app apart.
    /// Holding a modifier swaps the path for what that modifier does, so the alternate
    /// actions are discoverable without a legend.
    ///
    /// Caffeinate says when another process is also keeping the display awake, since its
    /// switch shows only Spotlite's own assertion.
    func hints(modifiers: NSEvent.ModifierFlags) -> [Hint] {
        if case .caffeinate(let state) = self, state.external {
            return [Hint(text: "Also active in another app", key: nil)]
        }
        guard case .app(let match) = self else { return [] }
        // A pane has no file worth revealing or copying and nothing to quit.
        if match.entry.kind == .settingsPane {
            if modifiers.contains(.command) { return [Hint(text: "Hide", key: "⌘⌫")] }
            if modifiers.contains(.option) { return [] }
            return [Hint(text: "System Settings", key: nil)]
        }
        if modifiers.contains(.command) {
            var hints = [Hint(text: "Reveal in Finder", key: "⌘↩")]
            if !runningApplications.isEmpty { hints.append(Hint(text: "Quit", key: "⌘Q")) }
            hints.append(Hint(text: "Hide", key: "⌘⌫"))
            return hints
        }
        if modifiers.contains(.option) { return [Hint(text: "Copy Path", key: "⌥↩")] }
        return [Hint(text: ResultItem.abbreviate(match.entry.url.deletingLastPathComponent().path),
                     key: nil)]
    }

    /// Running instances of this row's app, matched by bundle location rather than
    /// bundle ID so two copies of the same app are told apart.
    var runningApplications: [NSRunningApplication] {
        guard case .app(let match) = self else { return [] }
        let url = match.entry.url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == url
        }
    }

    /// The file URL whose icon this row shows, or nil when the icon is a fixed symbol.
    var iconURL: URL? {
        if case .app(let match) = self { return match.entry.url }
        return nil
    }

    /// The icon when it needs no loading: a fixed symbol, or an already-cached app icon.
    var immediateIcon: NSImage? {
        switch self {
        case .app(let match): return IconCache.shared.cached(for: match.entry.url)
        case .calculation: return ResultItem.calculatorIcon
        case .settings: return ResultItem.settingsIcon
        case .caffeinate(let state):
            return state.spotlite ? ResultItem.caffeineOnIcon : ResultItem.caffeineOffIcon
        }
    }

    /// The icon at the bar's right end. Spotlight shows the app a result belongs to,
    /// so Settings shows Spotlite itself rather than the row's gear, and a pane shows
    /// System Settings.
    var barIcon: NSImage? {
        switch self {
        case .settings: return NSApp.applicationIconImage
        case .app(let match) where match.entry.kind == .settingsPane: return ResultItem.systemSettingsIcon
        default: return immediateIcon
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Only a whole leading component: "/Users/ann" must not shorten "/Users/anna/…".
    private static func abbreviate(_ path: String) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // Built once rather than per row render: `icon` is read every time a row is configured.
    private static let calculatorIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
    private static let settingsIcon = symbol("gearshape")
    private static let systemSettingsIcon = NSWorkspace.shared.icon(forFile: SettingsPaneIndex.systemSettingsApp.path)
    private static let caffeineOffIcon = symbol("cup.and.saucer")
    private static let caffeineOnIcon = symbol("cup.and.saucer.fill")

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
