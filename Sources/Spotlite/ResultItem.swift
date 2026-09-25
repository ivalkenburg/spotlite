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

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(_, let value): return Calculator.format(value)
        case .settings: return "Spotlite Settings"
        case .caffeinate: return "Caffeinate"
        }
    }

    /// Rows that carry a switch instead of a detail label. The switch is the state, so
    /// the row needs no words to say whether it is on.
    var switchState: Bool? {
        if case .caffeinate(let state) = self { return state.isActive }
        return nil
    }

    /// The verb the completion pill names.
    private var action: String {
        if case .caffeinate(let state) = self { return state.isActive ? "Turn Off" : "Turn On" }
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
    func hints(modifiers: NSEvent.ModifierFlags) -> [Hint] {
        guard case .app(let match) = self else { return [] }
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
            return state.isActive ? ResultItem.caffeineOnIcon : ResultItem.caffeineOffIcon
        }
    }

    /// The icon at the bar's right end. Spotlight shows the app a result belongs to,
    /// so Settings shows Spotlite itself rather than the row's gear.
    var barIcon: NSImage? {
        if case .settings = self { return NSApp.applicationIconImage }
        return immediateIcon
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // Built once rather than per row render: `icon` is read every time a row is configured.
    private static let calculatorIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
    private static let settingsIcon = symbol("gearshape")
    private static let caffeineOffIcon = symbol("cup.and.saucer")
    private static let caffeineOnIcon = symbol("cup.and.saucer.fill")

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
