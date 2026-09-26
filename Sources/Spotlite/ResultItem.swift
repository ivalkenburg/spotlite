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
    case webSearch(query: String, engine: WebSearchEngine)

    init(_ result: SearchResult, caffeine: CaffeineState) {
        switch result {
        case .app(let match): self = .app(match)
        case .calculation(let expression, let value): self = .calculation(expression: expression, value: value)
        case .settings: self = .settings
        case .caffeinate: self = .caffeinate(state: caffeine)
        case .webSearch(let query, let engine): self = .webSearch(query: query, engine: engine)
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
        case .webSearch: return "webSearch"
        }
    }

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(_, let value): return Calculator.format(value)
        case .settings: return "Spotlite Settings"
        case .caffeinate: return "Caffeinate"
        case .webSearch(let query, let engine): return "Search \(engine.name) for “\(query)”"
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
        switch self {
        case .caffeinate(let state): return state.spotlite ? "Turn Off" : "Turn On"
        case .app(let match) where match.entry.kind == .command: return "Run"
        default: return "Open"
        }
    }

    /// What the pill after the query says while this row is selected.
    func completion(for query: String) -> String {
        switch self {
        case .calculation(_, let value): return " = " + Calculator.format(value)
        // The title repeats the query, so the pill names only the engine.
        case .webSearch(_, let engine): return " — Search \(engine.name)"
        default: return Completion.suffix(query: query, title: title, action: action)
        }
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
    /// `running` says whether the app has an instance to quit, from the panel's snapshot:
    /// asking NSWorkspace here would enumerate every process on each render while ⌘ is held.
    func hints(modifiers: NSEvent.ModifierFlags, running: Bool) -> [Hint] {
        if case .caffeinate(let state) = self, state.external {
            return [Hint(text: "Also active in another app", key: nil)]
        }
        guard case .app(let match) = self else { return [] }
        let entry = match.entry
        switch entry.kind {
        case .app:
            break
        // A pane or a command has no file worth revealing or copying and nothing to quit.
        case .settingsPane, .command:
            if modifiers.contains(.command) { return [Hint(text: "Hide", key: "⌘⌫")] }
            if modifiers.contains(.option) { return [] }
            return [Hint(text: entry.kind == .command ? "Command" : "System Settings", key: nil)]
        case .link:
            if modifiers.contains(.command) {
                var hints = entry.url.isFileURL ? [Hint(text: "Reveal in Finder", key: "⌘↩")] : []
                hints.append(Hint(text: "Hide", key: "⌘⌫"))
                return hints
            }
            if modifiers.contains(.option) {
                return [Hint(text: entry.url.isFileURL ? "Copy Path" : "Copy Link", key: "⌥↩")]
            }
            return [Hint(text: ResultItem.linkTarget(entry.url), key: nil)]
        }
        if modifiers.contains(.command) {
            var hints = [Hint(text: "Reveal in Finder", key: "⌘↩")]
            if running { hints.append(Hint(text: "Quit", key: "⌘Q")) }
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

    /// The text a link's row shows: a path shortened like an app's, or the address.
    static func linkTarget(_ url: URL) -> String {
        url.isFileURL ? abbreviate(url.path) : url.absoluteString
    }

    /// Whether this row is an app with a running instance, located the same way as
    /// `runningApplications`, against paths gathered once when the panel opened.
    /// `runningApplications` itself is left for the moment of quitting.
    func isRunning(in runningPaths: Set<String>) -> Bool {
        guard case .app(let match) = self, match.entry.kind == .app else { return false }
        return runningPaths.contains(match.entry.instanceID)
    }

    /// The file URL whose icon this row shows, or nil when the icon is a fixed symbol.
    /// A web link or search shows the default browser, where it will open.
    var iconURL: URL? {
        switch self {
        case .app(let match):
            switch match.entry.kind {
            case .command: return nil
            case .link where !match.entry.url.isFileURL: return ResultItem.browserURL
            default: return match.entry.url
            }
        case .webSearch: return ResultItem.browserURL
        default: return nil
        }
    }

    /// The icon when it needs no loading: a fixed symbol, or an already-cached app icon.
    var immediateIcon: NSImage? {
        switch self {
        case .app(let match) where match.entry.kind == .command:
            return ResultItem.commandIcon(match.entry)
        case .app:
            return iconURL.flatMap { IconCache.shared.cached(for: $0) }
        case .webSearch: return iconURL.flatMap { IconCache.shared.cached(for: $0) }
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
    /// Looked up once: the default browser rarely changes while Spotlite runs, and a
    /// stale icon is the only cost when it does.
    /// Shared with the Settings list, so a web link looks the same in both.
    static let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https:")!)
    private static let commandIcons: [SystemCommand: NSImage] = SystemCommand.allCases
        .reduce(into: [:]) { icons, command in icons[command] = symbol(symbolName(command)) }

    /// Shared with the Settings list, so a command looks the same in both.
    static func commandIcon(_ entry: AppEntry) -> NSImage? {
        SystemCommand(id: entry.id).flatMap { commandIcons[$0] }
    }

    private static func symbolName(_ command: SystemCommand) -> String {
        switch command {
        case .lockScreen: return "lock"
        case .sleep: return "moon"
        case .sleepDisplays: return "display"
        case .screenSaver: return "sparkles.tv"
        case .restart: return "arrow.clockwise"
        case .shutDown: return "power"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .emptyTrash: return "trash"
        case .toggleDarkMode: return "circle.lefthalf.filled"
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
