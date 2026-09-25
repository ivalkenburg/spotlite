import AppKit
import SpotliteCore

/// A row in the results list. Apps, the calculator, and the self-indexed Settings entry
/// all flow through the same cursor, Enter handling and rendering.
@MainActor
enum ResultItem {
    case app(MatchResult)
    case calculation(value: Double)
    case settings
    case caffeinate(state: CaffeineState)

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(let value): return Calculator.format(value)
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

    /// Character indices to embolden — the matched characters of a fuzzy hit.
    var highlighted: [Int] {
        if case .app(let match) = self { return match.positions }
        return []
    }

    /// The right-hand hint. An app shows where it lives, but only while selected —
    /// on every row it would be noise, and on the selected row it disambiguates two
    /// copies of the same app. Holding a modifier swaps the path for what that modifier
    /// does, so the alternate actions are discoverable without a legend.
    func detail(isSelected: Bool, modifiers: NSEvent.ModifierFlags = []) -> String? {
        switch self {
        case .calculation: return "return to copy"
        case .settings: return "preferences"
        case .caffeinate: return nil
        case .app(let match):
            guard isSelected else { return nil }
            if modifiers.contains(.command) {
                return runningApplications.isEmpty
                    ? "⌘↩ Reveal in Finder   ⌘⌫ Hide"
                    : "⌘↩ Reveal in Finder   ⌘Q Quit   ⌘⌫ Hide"
            }
            if modifiers.contains(.option) { return "⌥↩ Copy Path" }
            return ResultItem.abbreviate(match.entry.url.deletingLastPathComponent().path)
        }
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
        case .calculation: return ResultItem.calculationIcon
        case .settings: return ResultItem.settingsIcon
        case .caffeinate(let state):
            return state.isActive ? ResultItem.caffeineOnIcon : ResultItem.caffeineOffIcon
        }
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // Built once rather than per row render: `icon` is read every time a row is configured.
    private static let calculationIcon = symbol("equal.square")
    private static let settingsIcon = symbol("gearshape")
    private static let caffeineOffIcon = symbol("cup.and.saucer")
    private static let caffeineOnIcon = symbol("cup.and.saucer.fill")

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
