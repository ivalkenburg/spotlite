import AppKit
import SpotliteCore

/// The installed plugins, as the panel and Settings see them. Reading the folder is
/// deferred to first use, and no plugin runs between uses: a plugin costs a manifest
/// in memory until one of its commands is picked. While a look names a process, a kqueue
/// exit source waits on it; while a menu-bar look has a deadline, one one-shot timer and
/// a wake observer do. Neither wakes Spotlite before its event.
@MainActor
final class PluginHost {
    static let shared = PluginHost()

    private var loaded = false
    private var installed: [InstalledPlugin] = []
    private var byID: [String: InstalledPlugin] = [:]
    private var commands: [String: (plugin: InstalledPlugin, command: PluginCommand)] = [:]
    /// Looks a plugin gave its commands at run time, by entry id. Kept in memory only:
    /// a plugin reports its state again the next time it runs.
    private(set) var looks = PluginLooks()
    /// Numbers runs as they start, so a late answer cannot replace a newer one.
    private var runSequence: UInt64 = 0
    /// One exit source per process a look describes. kqueue wakes nothing until it exits.
    private var processWatchers: [ProcessIdentity: DispatchSourceProcess] = [:]
    /// Armed only while a menu-bar look has a deadline.
    private var expiryTimer: DispatchSourceTimer?
    private var expiryDeadline: TimeInterval?
    private var wakeObserver: NSObjectProtocol?
    /// Told whenever a look changes: a run's update, an expiry, an exit, a reload.
    var onLooksChanged: (() -> Void)?
    /// Each command's keyword, by entry id, for commands the user gave no alias.
    private var keywords: [String: String] = [:]
    private var configurations: [String: PluginConfiguration] = [:]
    private var configurationJSON: [String: String] = [:]
    private let configurationStore: PluginConfigurationStore
    /// Each plugin's most recent run, for Settings. Memory only: diagnostics never
    /// touch the disk, and a relaunch starts clean.
    private var lastRuns: [String: PluginRunRecord] = [:]
    /// Follows the preference of the same name. Off, no run is recorded and a streamed
    /// run keeps none of its raw output; the debug runner still shows what it ran.
    var keepPluginRunDiagnostics = false {
        didSet { if !keepPluginRunDiagnostics { lastRuns = [:] } }
    }
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

    /// Where plugins installed from an address record their source.
    private(set) lazy var sources: PluginSourceStore = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SPOTLITE_DEV_PLUGINS_DIR"] != nil || environment["SPOTLITE_DEV_PLUGIN_SOURCES_DIR"] != nil {
            // Dev runs keep source records away from the real ones.
            return PluginSourceStore(directory: URL(fileURLWithPath: environment["SPOTLITE_DEV_PLUGIN_SOURCES_DIR"]
                ?? NSTemporaryDirectory() + "spotlite-dev-plugin-sources", isDirectory: true))
        }
        #endif
        return PluginSourceStore()
    }()

    #if DEBUG
    /// Dev checks serve archives from disk instead of the network.
    var devLoader: (any PluginDownloading)?
    #endif

    /// Installs into this host's folder. Made per use: it holds no state between installs.
    func installer() -> PluginInstaller {
        #if DEBUG
        if let devLoader { return PluginInstaller(pluginsDirectory: pluginsDirectory, sources: sources, loader: devLoader) }
        #endif
        return PluginInstaller(pluginsDirectory: pluginsDirectory, sources: sources)
    }

    #if DEBUG
    /// Dev checks point the gallery at a local index.
    var devGalleryURL: URL?
    #endif

    /// The gallery index: the published one, or in debug builds `SPOTLITE_DEV_GALLERY_URL`,
    /// which may be a `file:` URL.
    var galleryURL: URL {
        #if DEBUG
        return devGalleryURL ?? PluginGallery.indexURL(override: ProcessInfo.processInfo.environment["SPOTLITE_DEV_GALLERY_URL"])
        #else
        return PluginGallery.defaultURL
        #endif
    }

    /// Reads the gallery index now. Called only when the user opens or refreshes it.
    func galleryFetcher() -> @Sendable () async throws(PluginInstallError) -> PluginGalleryIndex {
        let url = galleryURL, loader = installer().loader
        #if DEBUG
        let allowsFiles = true
        #else
        let allowsFiles = false
        #endif
        return { () async throws(PluginInstallError) -> PluginGalleryIndex in
            try await PluginGallery.fetch(from: url, loader: loader, allowsFileURLs: allowsFiles)
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
        // A look whose command went away stays while its process runs: the menu bar
        // still shows what keeps running, and offers to stop it.
        let looksChanged = looks.retain(commands: { self.commands[$0] != nil }, orphans: { $0.process?.isRunning == true })
        lastRuns = lastRuns.filter { byID[$0.key] != nil }
        // Last: the callback reaches the panel, which may read the host again.
        if looksChanged { looksDidChange() }
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
        looks.look(for: id, at: Date())?.update
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
        return update(forEntryID: id)?.displaySubtitle() ?? command.subtitle ?? plugin.name
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
        // Values read with a problem may not be what the Keychain holds, so every secret is written then.
        let previous = configurations[plugin.id].flatMap { $0.problem == nil ? $0.values : nil }
        try configurationStore.save(configuration.values, for: plugin.id, settings: fields, previous: previous)
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

    /// Applies a run's updates. `sequence` is the run's, taken when it started.
    private func apply(_ changes: [PluginCommandUpdate], from plugin: InstalledPlugin, sequence: UInt64,
                       fromRun: Bool = false) {
        guard !changes.isEmpty else { return }
        // A run that ends after its plugin was removed or switched commands applies only
        // to what still exists, unless its process still runs.
        let installed: (String) -> Bool = { [commands] in commands[$0]?.plugin.directory == plugin.directory }
        if looks.apply(changes, from: plugin, installed: installed, sequence: sequence, fromRun: fromRun) { looksDidChange() }
    }

    #if DEBUG
    /// Dev checks apply updates as from a run newer than every other.
    func devApply(_ changes: [PluginCommandUpdate], from plugin: InstalledPlugin) {
        apply(changes, from: plugin, sequence: nextRunSequence())
    }
    #endif

    private func nextRunSequence() -> UInt64 {
        runSequence &+= 1
        return runSequence
    }

    /// Ends the process a look describes, after checking it is still the same one.
    /// Offered only for a look whose plugin is switched off or removed.
    func stopProcess(forEntryID id: String) {
        guard let process = looks.looks[id]?.process, process.isRunning else { return }
        kill(process.pid, SIGTERM)
    }

    /// Watches each look's process and deadline, then tells the menu bar. Nothing is
    /// armed while no look needs it.
    private func looksDidChange() {
        // A root row's look past its deadline would otherwise wait for its process.
        looks.removeExpired(at: Date())
        let needed = looks.processes
        for (process, source) in processWatchers where !needed.contains(process) {
            source.cancel()
            processWatchers[process] = nil
        }
        for process in needed where processWatchers[process] == nil {
            // Fires at once for a process that already exited, so none is missed.
            let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processExited(process) }
            }
            processWatchers[process] = source
            source.resume()
        }
        scheduleExpiry()
        onLooksChanged?()
    }

    private func processExited(_ process: ProcessIdentity) {
        processWatchers.removeValue(forKey: process)?.cancel()
        if looks.processExited(process) { looksDidChange() }
    }

    private func runEnded(_ pluginID: String) {
        if looks.runEnded(pluginID: pluginID) { looksDidChange() }
    }

    private func scheduleExpiry() {
        let deadline = looks.nextMenuBarDeadline
        guard deadline != expiryDeadline else { return }
        expiryTimer?.cancel()
        expiryTimer = nil
        expiryDeadline = deadline
        guard let deadline else {
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
            wakeObserver = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let whole = floor(deadline)
        // Wall time keeps counting while the Mac sleeps, as the deadline does.
        timer.schedule(wallDeadline: DispatchWallTime(timespec: timespec(tv_sec: Int(min(whole, 1e11)),
                                                                          tv_nsec: Int((deadline - whole) * 1e9))),
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.expireLooks() }
        }
        expiryTimer = timer
        timer.resume()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireLooks() }
            }
        }
    }

    /// Also called when a menu finds a look's deadline passed before the timer or the
    /// wake caught it.
    func expireLooks() {
        if looks.removeExpired(at: Date()) {
            looksDidChange()
        } else {
            // Early delivery or a clock change: arm again for the same deadline.
            expiryDeadline = nil
            scheduleExpiry()
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
    /// arrive, at most once per frame. A failure after some rows arrived
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
        var query = query
        var arguments: [String]
        var streams = false
        switch command.action {
        case .run(let args, _): arguments = args
        case .list(let args, let options): arguments = args; streams = options.streams
        case .search(let args, _, _, let options):
            // The query a search level would send for the same text.
            query = Self.searchQuery(query)
            arguments = args + [query]; streams = options.streams
        case .open, .copy, .menu: return nil
        }
        return start(plugin, arguments: arguments, query: query, command: command.id, action: action,
                     streams: streams, keepsOutput: true, applies: false, completion: completion)
    }

    func lastRun(for id: String) -> PluginRunRecord? { lastRuns[id] }

    /// What a search level sends for the text typed: trimmed, and bounded so a pasted
    /// page never becomes an argument.
    static func searchQuery(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespaces).prefix(512))
    }

    /// `streams` decodes the output line by line; `rows` also shows them as they come.
    /// `keepsOutput` defaults to the diagnostics preference.
    private func start(_ plugin: InstalledPlugin, arguments: [String], query: String, command: String,
                       action: PluginRunAction, streams: Bool = false, keepsOutput: Bool? = nil, applies: Bool = true,
                       rows: (@MainActor ([PluginItem]) -> Void)? = nil,
                       completion: @escaping @MainActor (PluginRunReport) -> Void) -> PluginRun? {
        loadIfNeeded()
        let sequence = nextRunSequence()
        // Only a `run` restarts what a look describes. The debug runner applies nothing.
        let counted = action == .run && applies
        let finish: @MainActor (PluginRunReport) -> Void = { [weak self] report in
            self?.record(report, for: plugin, command: command, action: action, arguments: arguments)
            // Applied here, in run order, rather than by each caller.
            if applies, case .success(let response) = report.result {
                self?.apply(response.update, from: plugin, sequence: sequence, fromRun: counted)
            }
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
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let environment = PluginEnvironment.make(
            for: plugin, query: query, dataDirectory: data, configurationJSON: json,
            configurationVariables: configurations[plugin.id]?.variables ?? [:], command: command, action: action,
            appearance: dark ? "dark" : "light", version: Self.appVersion)
        var cancelled: (@Sendable () -> Void)?
        if counted {
            looks.runStarted(pluginID: plugin.id)
            let pluginID = plugin.id
            cancelled = { [weak self] in Task { @MainActor in self?.runEnded(pluginID) } }
        }
        var delivery: PluginRun.Rows?
        if let rows {
            // Delivered on the main queue, which is the main actor's.
            delivery = { items in MainActor.assumeIsolated { rows(items) } }
        }
        return PluginRun.startReporting(executable: executable, arguments: arguments, environment: environment,
                                        directory: plugin.directory, timeout: manifest.timeout,
                                        stream: streams || rows != nil,
                                        keepsOutput: keepsOutput ?? keepPluginRunDiagnostics,
                                        rows: delivery, cancelled: cancelled) { [weak self] report in
            Task { @MainActor in
                finish(report)
                if counted { self?.runEnded(plugin.id) }
            }
        }
    }

    private func record(_ report: PluginRunReport, for plugin: InstalledPlugin, command: String,
                        action: PluginRunAction, arguments: [String]) {
        guard keepPluginRunDiagnostics else { return }
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
