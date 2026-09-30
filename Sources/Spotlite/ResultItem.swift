import AppKit
import SpotliteCore

/// A row in the results list. Apps, the calculator, and the self-indexed Settings entry
/// all flow through the same cursor, Enter handling and rendering.
@MainActor
enum ResultItem {
    case app(MatchResult)
    /// The expression is kept as typed: the card shows it above the result.
    case calculation(expression: String, value: Double)
    case conversion(expression: String, result: String)
    case generateUUID
    case settings
    case caffeinate(state: CaffeineState)
    case menuItem(SearchMenuItem, state: CaffeineState)
    case webSearch(query: String, engine: WebSearchEngine)

    init(_ result: SearchResult, caffeine: CaffeineState) {
        switch result {
        case .app(let match): self = .app(match)
        case .calculation(let expression, let value): self = .calculation(expression: expression, value: value)
        case .conversion(let expression, let result): self = .conversion(expression: expression, result: result)
        case .generateUUID: self = .generateUUID
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
        case .conversion: return "conversion"
        case .generateUUID: return "generateUUID"
        case .settings: return "settings"
        case .caffeinate: return "caffeinate"
        case .menuItem(let item, _): return item.id
        case .webSearch: return "webSearch"
        }
    }

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(_, let value): return Calculator.format(value)
        case .conversion(_, let result): return result
        case .generateUUID: return "Generate UUID"
        case .settings: return "Spotlite Settings"
        case .caffeinate: return "Caffeinate"
        case .menuItem(let item, _): return item.title
        case .webSearch(let query, let engine): return "Search \(engine.name) for “\(query)”"
        }
    }

    var isCard: Bool {
        switch self {
        case .calculation, .conversion: true
        default: false
        }
    }

    var cardContent: (expression: String, result: String)? {
        switch self {
        case .calculation(let expression, let value): return (expression, Calculator.format(value))
        case .conversion(let expression, let result): return (expression, result)
        default: return nil
        }
    }

    /// Rows that carry a switch. The switch is the state, so the row needs no words to
    /// say whether it is on. For Caffeinate it is Spotlite's own assertion only: exactly
    /// what Return toggles.
    var switchState: Bool? {
        if case .menuItem(let item, let state) = self, item.action == .toggleCaffeinate {
            return state.spotlite
        }
        return nil
    }

    var submenu: SearchMenu? {
        switch self {
        case .caffeinate: return .caffeinate
        case .generateUUID: return .generateUUID
        case .menuItem(let item, _): return item.submenu
        default: return nil
        }
    }

    /// The verb the completion pill names.
    private var action: String {
        switch self {
        case .menuItem(let item, let state):
            if item.action == .toggleCaffeinate { return state.spotlite ? "Turn Off" : "Turn On" }
            if case .generateUUID = item.action { return "Copy" }
            return item.action == nil ? "Open" : "Run"
        case .app(let match) where match.entry.kind == .command: return "Run"
        default: return "Open"
        }
    }

    /// What the pill after the query says while this row is selected.
    func completion(for query: String, appNameCompletion: AppNameCompletion) -> String {
        switch self {
        case .calculation(_, let value): return " = " + Calculator.format(value)
        case .conversion(_, let result): return " = " + result
        // The title repeats the query, so the pill names only the engine.
        case .webSearch(_, let engine): return " – Search \(engine.name)"
        case .app(let match) where match.entry.kind == .app:
            return Completion.suffix(query: query, title: title, action: action, mode: appNameCompletion)
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
    /// The Caffeinate toggle says when another process is also keeping the display
    /// awake, since its switch shows only Spotlite's own assertion.
    /// `running` says whether the app has an instance to quit, from the panel's snapshot:
    /// asking NSWorkspace here would enumerate every process on each render while ⌘ is held.
    func hints(modifiers: NSEvent.ModifierFlags, running: Bool) -> [Hint] {
        if submenu != nil {
            return [Hint(text: "Actions", key: "⇥")]
        }
        if case .menuItem(let item, let state) = self,
           item.action == .toggleCaffeinate, state.external {
            return [Hint(text: "Also active in another app", key: nil)]
        }
        if case .menuItem(let item, _) = self, case .generateUUID = item.action {
            return [Hint(text: "Copy UUID", key: "↩")]
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
            // The user named the link, so its target goes unsaid; a template shows only the
            // key that takes its argument.
            return entry.template == nil ? [] : [Hint(text: "", key: "⇥")]
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

    /// Whether this row is an app with a running instance, located the same way as
    /// `runningApplications`, against paths gathered once when the panel opened.
    /// `runningApplications` itself is left for the moment of quitting.
    func isRunning(in runningPaths: Set<String>) -> Bool {
        guard case .app(let match) = self, match.entry.kind == .app else { return false }
        return runningPaths.contains(match.entry.instanceID)
    }

    /// The file URL whose icon this row shows, or nil when the icon is a fixed symbol.
    /// A web link or search shows the app that will open it: the default browser, or
    /// Shortcuts for a `shortcuts:` link.
    var iconURL: URL? {
        switch self {
        case .app(let match): return ResultItem.iconURL(for: match.entry)
        case .webSearch: return ResultItem.handler(for: ResultItem.webURL)
        default: return nil
        }
    }

    /// Shared with the Settings list, so an entry looks the same in both: its own file,
    /// the app that opens a web link, or nil for a command's symbol or a link no app opens.
    static func iconURL(for entry: AppEntry) -> URL? {
        switch entry.kind {
        case .command: return nil
        case .link where !entry.url.isFileURL: return handler(for: entry.url)
        default: return entry.url
        }
    }

    /// The icon when it needs no loading: a fixed symbol, or an already-cached app icon.
    var immediateIcon: NSImage? {
        switch self {
        case .app(let match) where match.entry.kind == .command:
            return ResultItem.commandIcon(match.entry)
        case .app:
            // Only a link whose scheme no app handles has no file to take an icon from.
            guard let url = iconURL else { return ResultItem.linkIcon }
            return IconCache.shared.cached(for: url)
        case .webSearch: return iconURL.flatMap { IconCache.shared.cached(for: $0) }
        case .calculation, .conversion: return ResultItem.calculatorIcon
        case .generateUUID: return ResultItem.symbol("number")
        case .settings: return ResultItem.settingsIcon
        case .caffeinate(let state):
            return state.spotlite ? ResultItem.caffeineOnIcon : ResultItem.caffeineOffIcon
        case .menuItem(let item, let state):
            if item.action == .toggleCaffeinate {
                return state.spotlite ? ResultItem.caffeineOnIcon : ResultItem.caffeineOffIcon
            }
            return ResultItem.symbol(item.symbolName)
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
    /// Shared with the Settings list, for a link no app opens.
    static let linkIcon = symbol("link")
    private static let webURL = URL(string: "https:")!
    /// The app that opens each URL scheme, looked up when a row first needs it rather
    /// than per render. Emptied on each panel open, so an app installed or a default
    /// changed shows by the next one; a nil value remembers that no app answers.
    private static var handlers: [String: URL?] = [:]

    private static func handler(for url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        if let known = handlers[scheme] { return known }
        let found = NSWorkspace.shared.urlForApplication(toOpen: url)
        handlers[scheme] = found
        return found
    }

    static func forgetHandlers() { handlers.removeAll() }
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

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration) else { return nil }
        symbols[name] = image
        return image
    }
}
