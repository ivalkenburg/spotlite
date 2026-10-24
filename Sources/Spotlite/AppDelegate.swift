import AppKit
import SpotliteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let toasts = ToastPresenter()
    private lazy var plugins = PluginManager(legacyHiddenUtilityIDs: preferences.legacyHiddenUtilityIDs,
        root: ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGIN_ROOT"].map { URL(fileURLWithPath: $0) } ?? PluginStore.defaultRoot)
    private var libraryInstance: AppLibrary?
    /// Opening Settings needs the index, but an idle agent need not load launch history
    /// or start the directory watcher before either Settings or search is used.
    private var library: AppLibrary {
        if let libraryInstance { return libraryInstance }
        let created = AppLibrary(directories: preferences.applicationDirectories)
        created.extras = preferences.extraEntries
        created.onChange = { [weak self] apps, scanned in
            guard let self else { return }
            if scanned { IconCache.shared.invalidateAll() }
            self.controllerInstance?.libraryDidChange()
            self.settings?.appsDidChange(apps)
        }
        libraryInstance = created
        return created
    }
    private var controllerInstance: SpotliteController?

    /// Built on first invocation and kept forever after — an idle agent should not
    /// carry a panel, a table and an icon cache it may never show.
    private var controller: SpotliteController {
        if let controllerInstance { return controllerInstance }

        let controller = SpotliteController(library: library,
                                            preferences: preferences, toasts: toasts, plugins: plugins)
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onPreferencesChanged = { [weak self] prefs in
            self?.adoptPreferences(prefs) { self?.settings?.preferencesDidChange($0) }
        }
        controllerInstance = controller
        return controller
    }

    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var preferences = Storage.loadPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        registerHotKey()
        refreshStatusItem()
        plugins.load()
        plugins.host.onToast = { [weak self] message in
            guard let self else { return }
            self.toasts.show(message, position: self.preferences.toastPosition)
        }

        if !preferences.hasCompletedFirstRun {
            preferences.hasCompletedFirstRun = true
            Storage.save(preferences)
            // An invisible app with an unknown shortcut is unusable, so say it once.
            // Start-at-login stays off until the user asks for it.
            openSettings()
        }

        if ProcessInfo.processInfo.environment["SPOTLITE_SHOW_ON_LAUNCH"] == "1" {
            Task { @MainActor in self.controller.show() }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_FRAMES"] == "1" {
            Task { @MainActor in
                self.controller.show()
                // show() prefills SPOTLITE_DEV_QUERY; clear it so this really is collapsed.
                self.controller.field.stringValue = ""
                self.controller.updateMatches(for: "")
                self.controller.dumpFrames("collapsed")
                let query = ProcessInfo.processInfo.environment["SPOTLITE_DEV_QUERY"] ?? "a"
                self.controller.field.stringValue = query
                self.controller.updateMatches(for: query)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.controller.dumpFrames("expanded")
                    exit(0)
                }
            }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_SEQUENCE"] == "1" {
            Task { @MainActor in self.controller.runDevSequence() }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_UTILITIES"] == "1" {
            Task { @MainActor in
                do {
                    try await self.controller.runDevUtilityChecks()
                    exit(0)
                } catch {
                    print("DEV utilities failed: \(error)")
                    exit(1)
                }
            }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGINS"] == "1" {
            Task { @MainActor in
                do {
                    try await self.controller.runDevPluginChecks()
                    self.plugins.shutdown()
                    exit(0)
                } catch {
                    self.plugins.shutdown()
                    print("DEV plugins failed: \(error)")
                    exit(1)
                }
            }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_COMPLETION"] == "1" {
            Task { @MainActor in
                await self.controller.runDevCompletionChecks()
                exit(0)
            }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_MENU"] == "1" {
            Task { @MainActor in
                await self.controller.runDevMenuFrames()
                exit(0)
            }
        }
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_TOAST"] == "1" {
            Task { @MainActor in
                let previousController = self.controllerInstance
                let previousLibrary = self.libraryInstance
                do {
                    try await self.toasts.runDevChecks()
                    precondition(self.controllerInstance === previousController)
                    precondition(self.libraryInstance === previousLibrary)
                    print("DEV toast: launcher and library remained lazy")
                    exit(0)
                } catch {
                    print("DEV toast failed: \(error)")
                    exit(1)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        plugins.shutdown()
        toasts.dismiss()
    }

    /// Launching the app again while it is already running opens Settings. This is the
    /// safety net for a hidden menu bar icon: double-clicking the app in Finder always
    /// gets you back to the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - Hotkey

    private func makeHotKey(code: UInt32, modifiers: UInt32) -> HotKey? {
        HotKey(keyCode: code, modifiers: modifiers) { [weak self] in self?.controller.toggle() }
    }

    private func registerHotKey() {
        hotKey = makeHotKey(code: preferences.hotKeyCode, modifiers: preferences.hotKeyModifiers)

        if hotKey == nil {
            NSLog("Spotlite: hotkey registration failed — the chord is already claimed.")
            // A silently dead shortcut is the worst outcome: surface it where it can be changed.
            openSettings()
        }
    }

    private func rebindHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        if code == preferences.hotKeyCode, modifiers == preferences.hotKeyModifiers { return true }
        // Register first. The currently working chord remains live if the replacement is
        // already claimed or event-handler installation fails.
        guard let replacement = makeHotKey(code: code, modifiers: modifiers) else { return false }
        hotKey = replacement
        preferences.hotKeyCode = code
        preferences.hotKeyModifiers = modifiers
        return true
    }

    // MARK: - Menu bar

    private func refreshStatusItem() {
        if !preferences.showMenuBarIcon {
            // Dropping the reference is not enough; the item must be removed explicitly.
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        } else if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "magnifyingglass.circle",
                                         accessibilityDescription: "Spotlite")
            item.button?.toolTip = "Spotlite"
            let menu = NSMenu()
            menu.delegate = self
            menu.addItem(withTitle: "Search…", action: #selector(showPanel), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenuItem), keyEquivalent: ",")
                .target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Spotlite", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        }

    }

    private func applyTheme() {
        switch preferences.themeMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func showPanel() { controller.show() }

    @objc private func openSettingsMenuItem() { openSettings() }

    // MARK: - Settings

    private func openSettings() {
        library.loadIfNeeded()
        if settings == nil {
            let controller = SettingsWindowController(preferences: preferences,
                                                      library: library, plugins: plugins)
            controller.onChange = { [weak self] prefs in
                self?.adoptPreferences(prefs) { self?.controllerInstance?.preferencesDidChange($0) }
            }
            controller.onHotKeyChange = { [weak self] code, modifiers in
                self?.rebindHotKey(code: code, modifiers: modifiers) ?? false
            }
            controller.onToast = { [weak self] message in
                guard let self else { return }
                self.toasts.show(message, position: self.preferences.toastPosition)
            }
            settings = controller
        }
        settings?.show(apps: library.entries)
    }

    /// Applies preferences changed by the panel or by Settings. `forward` hands them to
    /// the other side after the theme is applied, since the panel resolves its appearance
    /// from the app's.
    private func adoptPreferences(_ prefs: Preferences, forward: (Preferences) -> Void) {
        let directoriesChanged = preferences.applicationDirectories != prefs.applicationDirectories
        let linksChanged = preferences.links != prefs.links
        preferences = prefs
        if directoriesChanged { libraryInstance?.setDirectories(prefs.applicationDirectories) }
        if linksChanged { library.extras = prefs.extraEntries }
        applyTheme()
        forward(prefs)
        refreshStatusItem()
    }
}
