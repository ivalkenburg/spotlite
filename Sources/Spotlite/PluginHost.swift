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
    private var configurations: [String: PluginConfiguration] = [:]
    private var configurationJSON: [String: String] = [:]
    private let configurationStore: PluginConfigurationStore
    /// Each plugin's most recent run, for Settings. Memory only: diagnostics never
    /// touch the disk, and a relaunch starts clean.
    private var lastRuns: [String: PluginRunRecord] = [:]
    /// Settings listens while it is open, so a run it shows never needs polling.
    var onRunRecorded: ((String) -> Void)?

    static let fallbackSymbol = "puzzlepiece.extension"

    let pluginsDirectory: URL

    init(directory: URL? = nil, configurationStore: PluginConfigurationStore? = nil) {
        self.pluginsDirectory = directory ?? Self.defaultDirectory
        if let configurationStore {
            self.configurationStore = configurationStore
        } else {
            #if DEBUG
            if let override = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGIN_SETTINGS_DIR"] {
                // Dev checks keep their secrets apart from real plugins' Keychain items.
                self.configurationStore = PluginConfigurationStore(directory: URL(fileURLWithPath: override, isDirectory: true),
                                                                   secrets: KeychainSecretStore(prefix: "com.igorv.spotlite.dev.plugin."))
                return
            }
            #endif
            self.configurationStore = PluginConfigurationStore()
        }
    }

    private static var defaultDirectory: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGINS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return PluginStore.directory
    }

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
        configurations = [:]
        configurationJSON = [:]
        for plugin in installed where plugin.isUsable {
            byID[plugin.id] = plugin
            readConfiguration(for: plugin)
            for command in plugin.manifest?.commands ?? [] {
                let id = plugin.entryID(for: command)
                commands[id] = (plugin, command)
                if let keyword = command.keyword?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty {
                    keywords[id] = keyword
                }
            }
        }
        updates = updates.filter { commands[$0.key] != nil }
        lastRuns = lastRuns.filter { byID[$0.key] != nil }
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
        if needsSetup(plugin.id) { return "Setup required" }
        return update(forEntryID: id)?.subtitle ?? command.subtitle ?? plugin.name
    }

    // MARK: - Configuration

    /// These lookups only consult state prepared when plugins load or settings change.
    func configuration(for plugin: InstalledPlugin) -> PluginConfiguration {
        loadIfNeeded()
        return configurations[plugin.id] ?? PluginConfiguration(settings: plugin.manifest?.settings ?? [])
    }

    func needsSetup(_ id: String) -> Bool { configurations[id]?.isValid == false }

    private func readConfiguration(for plugin: InstalledPlugin) {
        let fields = plugin.manifest?.settings ?? []
        var configuration = PluginConfiguration(settings: fields)
        do {
            let saved = fields.isEmpty ? [:] : try configurationStore.load(for: plugin.id, settings: fields)
            configuration = PluginConfiguration(settings: fields, saved: saved)
            if configuration.isValid { configurationJSON[plugin.id] = try configuration.json() }
        } catch {
            configuration = PluginConfiguration(settings: fields, saved: configuration.values,
                problem: "Couldn’t read plugin settings: \(error.localizedDescription)")
        }
        configurations[plugin.id] = configuration
    }

    func saveConfiguration(_ values: [String: PluginSettingValue], for plugin: InstalledPlugin) throws {
        let fields = plugin.manifest?.settings ?? []
        let configuration = PluginConfiguration(settings: fields, saved: values)
        guard configuration.isValid else { throw PluginRunError.configurationRequired }
        let json = try configuration.json()
        try configurationStore.save(configuration.values, for: plugin.id, settings: fields)
        configurations[plugin.id] = configuration
        configurationJSON[plugin.id] = json
    }

    func resetConfiguration(for plugin: InstalledPlugin) throws {
        try configurationStore.reset(for: plugin.id)
        configurationJSON[plugin.id] = nil
        readConfiguration(for: plugin)
    }

    static func icon(_ raw: String?, in plugin: InstalledPlugin) -> PluginIcon {
        raw.map { PluginIcon($0, directory: plugin.directory) } ?? .symbol(fallbackSymbol)
    }

    func apply(_ changes: [PluginCommandUpdate], from plugin: InstalledPlugin) {
        guard !changes.isEmpty, let declared = plugin.manifest?.commands, !declared.isEmpty else { return }
        // A temporary index pays off for large batches. Small responses keep the
        // linear path, without allocating a set or adding a persistent cache.
        let commandIDs = changes.count >= 128 && declared.count >= 128 && changes.count >= declared.count / 2
            ? Set(declared.map(\.id)) : nil
        for change in changes {
            guard commandIDs?.contains(change.command) ?? declared.contains(where: { $0.id == change.command }) else { continue }
            updates[plugin.entryID(forCommandID: change.command)] = change.isReset ? nil : change
        }
    }

    // MARK: - Running

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Outside its app bundle, as under `swift run`, there is no version to report.
        ?? "0.0.0"

    /// Runs the plugin's executable and reports on the main actor. Nil when the plugin
    /// has nothing to run, after reporting that as a failure. `command` is the manifest
    /// command the user started from, even for a row nested inside its list.
    ///
    /// With `rows` the output streams: `rows` receives every row so far as lines
    /// arrive, at most once per main-queue turn. A failure after some rows arrived
    /// delivers them all once more before the completion.
    @discardableResult
    func run(_ plugin: InstalledPlugin, arguments: [String], query: String,
             command: String = "", action: PluginRunAction = .run,
             rows: (@MainActor ([PluginItem]) -> Void)? = nil,
             completion: @escaping @MainActor (Result<PluginResponse, PluginRunError>) -> Void) -> PluginRun? {
        start(plugin, arguments: arguments, query: query, command: command, action: action, rows: rows) { report in
            if let rows, case .failure = report.result, !report.streamedItems.isEmpty { rows(report.streamedItems) }
            completion(report.result)
        }
    }

    /// The same run with everything the program wrote, for the debug runner in Settings.
    /// The caller decides what to show; nothing is applied.
    @discardableResult
    func debugRun(_ plugin: InstalledPlugin, command: PluginCommand, query: String,
                  completion: @escaping @MainActor (PluginRunReport) -> Void) -> PluginRun? {
        guard let action = PluginRunAction(command.action) else { return nil }
        var arguments: [String]
        var streams = false
        switch command.action {
        case .run(let args, _): arguments = args
        case .list(let args, let options): arguments = args; streams = options.streams
        case .search(let args, _, _, let options): arguments = args + [query]; streams = options.streams
        case .open, .copy, .menu: return nil
        }
        return start(plugin, arguments: arguments, query: query, command: command.id, action: action,
                     streams: streams, completion: completion)
    }

    func lastRun(for id: String) -> PluginRunRecord? { lastRuns[id] }

    /// `streams` decodes the output line by line; `rows` also shows them as they come.
    private func start(_ plugin: InstalledPlugin, arguments: [String], query: String, command: String,
                       action: PluginRunAction, streams: Bool = false, rows: (@MainActor ([PluginItem]) -> Void)? = nil,
                       completion: @escaping @MainActor (PluginRunReport) -> Void) -> PluginRun? {
        loadIfNeeded()
        let finish: @MainActor (PluginRunReport) -> Void = { [weak self] report in
            self?.record(report, for: plugin, command: command, action: action, arguments: arguments)
            completion(report)
        }
        guard !needsSetup(plugin.id), let json = configurationJSON[plugin.id] else {
            finish(PluginRunReport(result: .failure(.configurationRequired)))
            return nil
        }
        guard let executable = plugin.executableURL, let manifest = plugin.manifest else {
            finish(PluginRunReport(result: .failure(.launchFailed("\(plugin.name) has no executable"))))
            return nil
        }
        let data = PluginStore.dataDirectory(for: plugin.id)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let variables = PluginEnvironment.configurationVariables(
            ids: manifest.settings.map(\.id), values: configurations[plugin.id]?.values ?? [:])
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let environment = PluginEnvironment.make(
            for: plugin, query: query, dataDirectory: data, configurationJSON: json,
            configurationVariables: variables, command: command, action: action,
            appearance: dark ? "dark" : "light", version: Self.appVersion)
        var delivery: PluginRun.Rows?
        if let rows {
            // Delivered on the main queue, which is the main actor's.
            delivery = { items in MainActor.assumeIsolated { rows(items) } }
        }
        return PluginRun.startReporting(executable: executable, arguments: arguments, environment: environment,
                                        directory: plugin.directory, timeout: manifest.timeout,
                                        stream: streams || rows != nil, rows: delivery) { report in
            Task { @MainActor in finish(report) }
        }
    }

    private func record(_ report: PluginRunReport, for plugin: InstalledPlugin, command: String,
                        action: PluginRunAction, arguments: [String]) {
        lastRuns[plugin.id] = PluginRunRecord(report: report, commandID: command, action: action, arguments: arguments)
        onRunRecorded?(plugin.id)
    }
}

/// What a plugin's row needs beyond the row itself.
struct PluginRowContext {
    let plugin: InstalledPlugin
    /// False for a search's rows, which answer the query rather than complete it.
    let completes: Bool
    let occurrence: Int
    /// The key drawn on every row of the action list or a confirmation, which are
    /// Spotlite's rows rather than the plugin's.
    let key: String?

    init(plugin: InstalledPlugin, completes: Bool, occurrence: Int = 0, key: String? = nil) {
        self.plugin = plugin
        self.completes = completes
        self.occurrence = occurrence
        self.key = key
    }
}

extension PluginShortcut {
    /// The modifiers a plugin can bind, out of everything an event carries.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
    }
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
