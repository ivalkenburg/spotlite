import AppKit
import SpotliteCore

/// The installed plugins, as the panel and Settings see them. Reading the folder is
/// deferred to first use, and nothing here runs between uses: a plugin costs a manifest
/// in memory until one of its commands is picked.
@MainActor
final class PluginHost {
    static let shared = PluginHost()

    private var loaded = false
    private var installed: [InstalledPlugin] = []
    private var byID: [String: InstalledPlugin] = [:]
    private var commands: [String: (plugin: InstalledPlugin, command: PluginCommand)] = [:]
    /// Looks a plugin gave its commands at run time, by entry id. Kept in memory only:
    /// a plugin reports its state again the next time it runs.
    private var updates: [String: PluginCommandUpdate] = [:]
    /// Each command's keyword, by entry id, for commands the user gave no alias.
    private var keywords: [String: String] = [:]

    static let fallbackSymbol = "puzzlepiece.extension"

    let pluginsDirectory: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGINS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return PluginStore.directory
    }()

    var plugins: [InstalledPlugin] {
        loadIfNeeded()
        return installed
    }

    var defaultAliases: [String: String] {
        loadIfNeeded()
        return keywords
    }

    private func loadIfNeeded() {
        if !loaded { reload() }
    }

    /// Reads the plugin folder again, after an install or removal or on request.
    func reload() {
        loaded = true
        installed = PluginStore.scan(directory: pluginsDirectory)
        byID = [:]
        commands = [:]
        keywords = [:]
        for plugin in installed where plugin.isUsable {
            byID[plugin.id] = plugin
            for command in plugin.manifest?.commands ?? [] {
                let id = plugin.entryID(for: command)
                commands[id] = (plugin, command)
                if let keyword = command.keyword?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty {
                    keywords[id] = keyword
                }
            }
        }
        updates = updates.filter { commands[$0.key] != nil }
    }

    /// Search entries of every enabled plugin.
    func entries(disabled: Set<String>) -> [AppEntry] {
        plugins.filter { !disabled.contains($0.id) }.flatMap(\.entries)
    }

    func plugin(id: String) -> InstalledPlugin? {
        loadIfNeeded()
        return byID[id]
    }

    func command(forEntryID id: String) -> (plugin: InstalledPlugin, command: PluginCommand)? {
        loadIfNeeded()
        return commands[id]
    }

    // MARK: - Looks

    private func update(forEntryID id: String) -> PluginCommandUpdate? {
        guard let update = updates[id] else { return nil }
        guard !update.hasExpired(at: Date()) else {
            updates[id] = nil
            return nil
        }
        return update
    }

    func icon(forEntryID id: String) -> PluginIcon {
        guard let (plugin, command) = command(forEntryID: id) else { return .symbol(Self.fallbackSymbol) }
        return Self.icon(update(forEntryID: id)?.icon ?? command.icon, in: plugin)
    }

    /// What the selected row says at its right: the plugin's latest word, the command's
    /// own subtitle, or the plugin it belongs to.
    func subtitle(forEntryID id: String) -> String {
        guard let (plugin, command) = command(forEntryID: id) else { return "" }
        return update(forEntryID: id)?.subtitle ?? command.subtitle ?? plugin.name
    }

    static func icon(_ raw: String?, in plugin: InstalledPlugin) -> PluginIcon {
        raw.map { PluginIcon($0, directory: plugin.directory) } ?? .symbol(fallbackSymbol)
    }

    func apply(_ changes: [PluginCommandUpdate], from plugin: InstalledPlugin) {
        for change in changes {
            guard let command = plugin.manifest?.commands.first(where: { $0.id == change.command }) else { continue }
            updates[plugin.entryID(for: command)] = change.isReset ? nil : change
        }
    }

    // MARK: - Running

    /// Runs the plugin's executable and reports on the main actor. Nil when the plugin
    /// has nothing to run, after reporting that as a failure.
    @discardableResult
    func run(_ plugin: InstalledPlugin, arguments: [String], query: String,
             completion: @escaping @MainActor (Result<PluginResponse, PluginRunError>) -> Void) -> PluginRun? {
        guard let executable = plugin.executableURL, let manifest = plugin.manifest else {
            completion(.failure(.launchFailed("\(plugin.name) has no executable")))
            return nil
        }
        let data = PluginStore.dataDirectory(for: plugin.id)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return PluginRun.start(
            executable: executable, arguments: arguments,
            environment: PluginEnvironment.make(for: plugin, query: query, dataDirectory: data),
            directory: plugin.directory, timeout: manifest.timeout
        ) { result in
            Task { @MainActor in completion(result) }
        }
    }
}

/// What a plugin's row needs beyond the row itself.
struct PluginRowContext {
    let plugin: InstalledPlugin
    /// False for a search's rows, which answer the query rather than complete it.
    let completes: Bool
}

extension ToastMessage {
    init(_ toast: PluginToast) {
        self.init(text: toast.text,
                  symbol: toast.symbol ?? (toast.isFailure ? "exclamationmark.triangle" : "checkmark.circle"),
                  isConfirmation: !toast.isFailure)
    }

    static func pluginFailure(_ error: PluginRunError) -> ToastMessage {
        ToastMessage(text: error.message, symbol: "exclamationmark.triangle", isConfirmation: false)
    }
}
