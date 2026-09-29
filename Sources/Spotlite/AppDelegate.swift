import AppKit
import SpotliteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Shared by the launcher row and the menu-bar indicator. Keeping this outside the
    /// lazily-created controller lets the status items reflect caffeine without paying
    /// the cost of constructing the panel and its views at launch.
    private let caffeine = CaffeineAssertion()
    private var libraryInstance: AppLibrary?
    /// Opening Settings needs the index, but an idle agent need not load launch history
    /// or start the directory watcher before either Settings or search is used.
    private var library: AppLibrary {
        if let libraryInstance { return libraryInstance }
        let created = AppLibrary()
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

        let controller = SpotliteController(library: library, caffeine: caffeine, preferences: preferences)
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onPreferencesChanged = { [weak self] prefs in
            self?.adoptPreferences(prefs) { self?.settings?.preferencesDidChange($0) }
        }
        controllerInstance = controller
        return controller
    }

    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var caffeineStatusItem: NSStatusItem?
    private var caffeineRefreshTimer: DispatchSourceTimer?
    private var settings: SettingsWindowController?
    private var preferences = Storage.loadPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        // Query before drawing the status item so an assertion that predates Spotlite is
        // represented immediately. Later changes all flow through this single callback.
        caffeine.refresh()
        caffeine.onChange = { [weak self] _ in
            guard let self else { return }
            self.refreshCaffeineStatusItem()
            self.controllerInstance?.caffeineStateDidChange()
        }
        registerHotKey()
        refreshStatusItem()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeineRefreshTimer()
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

        refreshCaffeineStatusItem()
        startCaffeineRefreshTimer()
    }

    private func applyTheme() {
        switch preferences.themeMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The cup is a separate, transient status item. The normal Spotlite icon never
    /// changes identity, and no empty cup occupies menu-bar space while caffeine is off.
    private func refreshCaffeineStatusItem() {
        let state = caffeine.state
        guard state.isActive else {
            if let caffeineStatusItem { NSStatusBar.system.removeStatusItem(caffeineStatusItem) }
            caffeineStatusItem = nil
            return
        }

        // One line per source, so turning Spotlite's off and seeing the cup stay makes sense.
        var lines: [String] = []
        if state.spotlite { lines.append("Caffeinate active in Spotlite") }
        if state.external {
            lines.append(state.spotlite ? "Also active in another app" : "Caffeinate active in another app")
        }
        let description = lines.joined(separator: "\n")

        if caffeineStatusItem == nil {
            caffeineStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        guard let item = caffeineStatusItem, let button = item.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: "cup.and.saucer.fill",
                            accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = description

        let menu = NSMenu()
        menu.delegate = self
        for line in lines {
            let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        if state.spotlite {
            menu.addItem(.separator())
            let turnOff = menu.addItem(withTitle: "Turn Off Caffeinate",
                                       action: #selector(turnOffCaffeine), keyEquivalent: "")
            turnOff.target = self
        }
        item.menu = menu
    }

    /// macOS does not publish a notification when arbitrary processes add or remove
    /// power assertions. A coalescible timer is the smallest reliable way
    /// to keep the independent caffeine status icon current.
    private func startCaffeineRefreshTimer() {
        guard caffeineRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(5),
                       repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.caffeine.refresh()
            }
        }
        timer.resume()
        caffeineRefreshTimer = timer
    }

    private func stopCaffeineRefreshTimer() {
        caffeineRefreshTimer?.cancel()
        caffeineRefreshTimer = nil
    }

    func menuWillOpen(_ menu: NSMenu) { caffeine.refresh() }

    @objc private func showPanel() { controller.show() }

    @objc private func turnOffCaffeine() {
        guard caffeine.state.spotlite else { return }
        caffeine.toggle()
    }

    @objc private func openSettingsMenuItem() { openSettings() }

    // MARK: - Settings

    private func openSettings() {
        library.loadIfNeeded()
        if settings == nil {
            let controller = SettingsWindowController(preferences: preferences,
                                                      library: library)
            controller.onChange = { [weak self] prefs in
                self?.adoptPreferences(prefs) { self?.controllerInstance?.preferencesDidChange($0) }
            }
            controller.onHotKeyChange = { [weak self] code, modifiers in
                self?.rebindHotKey(code: code, modifiers: modifiers) ?? false
            }
            settings = controller
        }
        settings?.show(apps: library.entries)
    }

    /// Applies preferences changed by the panel or by Settings. `forward` hands them to
    /// the other side after the theme is applied, since the panel resolves its appearance
    /// from the app's.
    private func adoptPreferences(_ prefs: Preferences, forward: (Preferences) -> Void) {
        let enabledStatusItem = !preferences.showMenuBarIcon && prefs.showMenuBarIcon
        let linksChanged = preferences.links != prefs.links
        preferences = prefs
        if linksChanged { library.extras = prefs.extraEntries }
        applyTheme()
        forward(prefs)
        if enabledStatusItem { caffeine.refresh() }
        refreshStatusItem()
    }
}
