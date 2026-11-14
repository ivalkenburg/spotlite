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
    /// A row inside a plugin's level. A plugin's root commands are `.app` entries.
    case plugin(PluginItem, PluginRowContext)

    /// Commands at the root and rows inside a plugin share the same action vocabulary.
    var pluginAction: PluginAction? {
        switch self {
        case .plugin(let item, _): item.action
        case .app(let match) where match.entry.kind == .plugin:
            PluginHost.shared.command(forEntryID: match.entry.id)?.command.action
        default: nil
        }
    }

    /// Return's action and the others a plugin row or command declares. Nil for every
    /// other row, and for the action list's and a confirmation's own rows.
    var pluginActions: PluginActionSet? {
        switch self {
        case .plugin(let item, let context) where context.key == nil: PluginActionSet(item)
        case .app(let match) where match.entry.kind == .plugin:
            PluginHost.shared.command(forEntryID: match.entry.id).map { PluginActionSet($0.command) }
        default: nil
        }
    }

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
        case .plugin(let item, let context):
            return "plugin-item.\(item.id.utf8.count):\(item.id):\(context.occurrence)"
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
        case .plugin(let item, _): return item.title
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

    var submenu: SearchMenu? {
        switch self {
        case .caffeinate(let state): return .caffeinate(active: state.spotlite)
        case .generateUUID: return .generateUUID
        case .menuItem(let item, _): return item.submenu
        default: return nil
        }
    }

    /// The verb the completion pill names.
    private var action: String {
        switch self {
        case .menuItem(let item, let state):
            if item.action == .stopCaffeinate { return "Turn Off" }
            if case .startCaffeinate = item.action { return state.spotlite ? "Change" : "Start" }
            if case .generateUUID = item.action { return "Copy" }
            return item.action == nil ? "Open" : "Run"
        case .app(let match) where match.entry.kind == .command: return "Run"
        case .app(let match) where match.entry.kind == .plugin:
            if let plugin = PluginHost.shared.command(forEntryID: match.entry.id)?.plugin,
               PluginHost.shared.needsSetup(plugin.id) { return "Configure" }
            return ResultItem.verb(PluginHost.shared.command(forEntryID: match.entry.id)?.command.action)
        case .plugin(let item, _): return ResultItem.verb(item.action)
        default: return "Open"
        }
    }

    private static func verb(_ action: PluginAction?) -> String {
        switch action {
        case .copy: "Copy"
        case .run: "Run"
        default: "Open"
        }
    }

    /// What the pill after the query says while this row is selected.
    func completion(for query: String, appNameCompletion: AppNameCompletion) -> String {
        switch self {
        case .calculation(_, let value): return " = " + Calculator.format(value)
        case .conversion(_, let result): return " = " + result
        // The title repeats the query, so the pill names only the engine.
        case .webSearch(_, let engine): return " – Search \(engine.name)"
        // A search's rows answer the query; a row without an action completes nothing.
        case .plugin(let item, let context) where !context.completes || item.action == nil: return ""
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
        /// A plugin row's accessory keeps a little width beside a long title rather than
        /// yielding all of it, and loses its end rather than its start.
        var isAccessory = false
    }

    /// An app shows where it lives, which tells two copies of the same app apart.
    /// Holding a modifier swaps the path for what that modifier does, so the alternate
    /// actions are discoverable without a legend.
    ///
    /// `running` says whether the app has an instance to quit, from the panel's snapshot:
    /// asking NSWorkspace here would enumerate every process on each render while ⌘ is held.
    func hints(modifiers: NSEvent.ModifierFlags, running: Bool) -> [Hint] {
        if submenu != nil {
            return [Hint(text: "Actions", key: "⇥")]
        }
        if case .menuItem(let item, _) = self, case .generateUUID = item.action {
            return [Hint(text: "Copy UUID", key: "↩")]
        }
        if case .plugin(let item, let context) = self {
            if context.key != nil { return restingHints }
            if let entry = pluginEntry(for: modifiers) { return [Hint(text: entry.title, key: entry.keyText)] }
            return ResultItem.pluginHints(subtitle: item.subtitle, accessory: item.accessory, action: item.action)
        }
        guard case .app(let match) = self else { return [] }
        let entry = match.entry
        switch entry.kind {
        case .app:
            break
        case .plugin:
            let bound = pluginEntry(for: modifiers).map { [Hint(text: $0.title, key: $0.keyText)] } ?? []
            if modifiers.contains(.command) { return bound + [Hint(text: "Hide", key: "⌘⌫")] }
            if !bound.isEmpty { return bound }
            return ResultItem.pluginHints(
                subtitle: PluginHost.shared.subtitle(forEntryID: entry.id),
                action: PluginHost.shared.command(forEntryID: entry.id)?.command.action)
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
            // Hiding is keyed by bundle ID, so an app without one cannot be hidden.
            if entry.bundleID != nil { hints.append(Hint(text: "Hide", key: "⌘⌫")) }
            return hints
        }
        if modifiers.contains(.option) { return [Hint(text: "Copy Path", key: "⌥↩")] }
        return [Hint(text: ResultItem.abbreviate(match.entry.url.deletingLastPathComponent().path),
                     key: nil)]
    }

    /// A plugin row's subtitle and accessory, and the key that opens its next level.
    /// The accessory stays last, where it sits on every other row, so selecting a row
    /// adds the subtitle beside it rather than moving it.
    private static func pluginHints(subtitle: String?, accessory: String? = nil, action: PluginAction?) -> [Hint] {
        let key = action?.entersScope == true ? "⇥" : nil
        let text = subtitle ?? ""
        guard let accessory else { return text.isEmpty && key == nil ? [] : [Hint(text: text, key: key)] }
        return (text.isEmpty ? [] : [Hint(text: text, key: nil)]) + [Hint(text: accessory, key: key, isAccessory: true)]
    }

    /// The plugin action bound to the modifiers held, if any. Built only while one is
    /// held, and only for the selected row.
    private func pluginEntry(for modifiers: NSEvent.ModifierFlags) -> PluginActionEntry? {
        let shortcut = PluginShortcut(modifiers)
        guard !shortcut.isEmpty else { return nil }
        return pluginActions?.entry(for: shortcut)
    }

    /// What an unselected row shows at its right: only a plugin row's accessory. The
    /// action list's and a confirmation's rows show their keys too, selected or not.
    var restingHints: [Hint] {
        guard case .plugin(let item, let context) = self else { return [] }
        guard let key = context.key else {
            return item.accessory.map { [Hint(text: $0, key: nil, isAccessory: true)] } ?? []
        }
        return [Hint(text: item.accessory ?? "", key: key, isAccessory: item.accessory != nil)]
    }

    /// Running instances of this row's app, matched by bundle location rather than
    /// bundle ID so two copies of the same app are told apart.
    var runningApplications: [NSRunningApplication] {
        guard case .app(let match) = self else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL.map(AppEntry.standardizedPath) == match.entry.instanceID
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
        case .plugin(let item, let context):
            if case .file(let url) = PluginHost.icon(item.icon, in: context.plugin) { return url }
            return nil
        default: return nil
        }
    }

    /// Shared with the Settings list, so an entry looks the same in both: its own file,
    /// the app that opens a web link, or nil for a command's symbol or a link no app opens.
    static func iconURL(for entry: AppEntry) -> URL? {
        switch entry.kind {
        case .command: return nil
        case .plugin:
            if case .file(let url) = PluginHost.shared.icon(forEntryID: entry.id) { return url }
            return nil
        case .link where !entry.url.isFileURL: return handler(for: entry.url)
        default: return entry.url
        }
    }

    /// The icon when it needs no loading: a fixed symbol, or an already-cached app icon.
    var immediateIcon: NSImage? {
        switch self {
        case .app(let match) where match.entry.kind == .command:
            return ResultItem.commandIcon(match.entry)
        case .app(let match) where match.entry.kind == .plugin:
            return ResultItem.pluginImage(PluginHost.shared.icon(forEntryID: match.entry.id))
        case .plugin(let item, let context):
            return ResultItem.pluginImage(PluginHost.icon(item.icon, in: context.plugin))
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
            if item.action == .stopCaffeinate {
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

    /// A plugin's symbol, or its file's icon once that has been loaded. An unknown
    /// symbol name falls back rather than leaving the row without an icon.
    static func pluginImage(_ icon: PluginIcon) -> NSImage? {
        switch icon {
        case .symbol(let name): return symbol(name) ?? symbol(PluginHost.fallbackSymbol)
        case .file(let url): return IconCache.shared.cached(for: url)
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
