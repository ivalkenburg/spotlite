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
    case menuItem(SearchMenuItem)
    case webSearch(query: String, engine: WebSearchEngine)
    case pluginCommand(PluginCommandReference)
    case pluginResult(PluginCommandReference, PluginResult)
    case pluginAction(PluginCommandReference, PluginResult?, PluginAction)
    case pluginNotice(title: String, message: String, symbol: String)

    init(_ result: SearchResult) {
        switch result {
        case .app(let match): self = .app(match)
        case .calculation(let expression, let value): self = .calculation(expression: expression, value: value)
        case .conversion(let expression, let result): self = .conversion(expression: expression, result: result)
        case .generateUUID: self = .generateUUID
        case .settings: self = .settings
        case .webSearch(let query, let engine): self = .webSearch(query: query, engine: engine)
        case .pluginCommand(let reference): self = .pluginCommand(reference)
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
        case .menuItem(let item): return item.id
        case .webSearch: return "webSearch"
        case .pluginCommand(let reference): return reference.id
        case .pluginResult(let reference, let result): return reference.id + ":" + result.id
        case .pluginAction(let reference, _, let action): return reference.id + ":action:" + action.id
        case .pluginNotice: return "pluginNotice"
        }
    }

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(_, let value): return Calculator.format(value)
        case .conversion(_, let result): return result
        case .generateUUID: return "Generate UUID"
        case .settings: return "Spotlite Settings"
        case .menuItem(let item): return item.title
        case .webSearch(let query, let engine): return "Search \(engine.name) for “\(query)”"
        case .pluginCommand(let reference): return reference.command.title
        case .pluginResult(_, let result): return result.title
        case .pluginAction(_, _, let action): return action.title
        case .pluginNotice(let title, _, _): return title
        }
    }

    var subtitle: String? {
        switch self {
        case .pluginCommand(let reference):
            reference.command.subtitle ?? (reference.command.title == reference.plugin.manifest.name ? nil : reference.plugin.manifest.name)
        case .pluginResult(_, let result): result.subtitle
        case .pluginNotice(_, let message, _): message
        default: nil
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

    /// Optional state provided by a plugin result.
    var switchState: Bool? {
        if case .pluginResult(_, let result) = self { return result.state }
        return nil
    }

    var submenu: SearchMenu? {
        switch self {
        case .generateUUID: return .generateUUID
        case .menuItem(let item): return item.submenu
        default: return nil
        }
    }

    /// The verb the completion pill names.
    private var action: String {
        switch self {
        case .pluginAction(_, _, let action): return action.title
        case .menuItem(let item):
            if case .generateUUID = item.action { return "Copy" }
            return item.action == nil ? "Open" : "Run"
        case .app(let match) where match.entry.kind == .command: return "Run"
        default: return "Open"
        }
    }

    /// What the pill after the query says while this row is selected.
    func completion(for query: String, appNameCompletion: AppNameCompletion) -> String {
        switch self {
        case .pluginNotice: return ""
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
    /// `running` says whether the app has an instance to quit, from the panel's snapshot:
    /// asking NSWorkspace here would enumerate every process on each render while ⌘ is held.
    func hints(modifiers: NSEvent.ModifierFlags, running: Bool) -> [Hint] {
        if case .pluginCommand = self { return [Hint(text: "Open", key: "⇥")] }
        if case .pluginResult(_, let result) = self, (result.actions?.count ?? 0) > 1 {
            return [Hint(text: "Actions", key: "⇥")]
        }
        if submenu != nil {
            return [Hint(text: "Actions", key: "⇥")]
        }
        if case .menuItem(let item) = self, case .generateUUID = item.action {
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
        case .pluginCommand(let reference): return Self.pluginIconURL(reference.command.icon ?? reference.plugin.manifest.icon, reference: reference)
        case .pluginResult(let reference, let result): return Self.pluginIconURL(result.icon ?? reference.command.icon, reference: reference)
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
        case .pluginCommand(let reference):
            return pluginIcon(reference.command.icon ?? reference.plugin.manifest.icon)
        case .pluginResult(let reference, let result): return pluginIcon(result.icon ?? reference.command.icon)
        case .pluginAction(_, _, let action): return Self.symbol(action.icon ?? "arrow.right")
        case .pluginNotice(_, _, let symbol): return Self.symbol(symbol)
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
        case .menuItem(let item):
            return ResultItem.symbol(item.symbolName)
        }
    }

    private func pluginIcon(_ name: String?) -> NSImage? {
        if let iconURL { return IconCache.shared.cached(for: iconURL) }
        return Self.symbol(name ?? "puzzlepiece.extension") ?? Self.symbol("puzzlepiece.extension")
    }

    private static func pluginIconURL(_ name: String?, reference: PluginCommandReference) -> URL? {
        guard let name, ["png", "jpg", "jpeg", "icns", "pdf", "tiff"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return reference.packageURL.appendingPathComponent(name)
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
