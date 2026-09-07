import AppKit
import SpotliteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Shared by the launcher row and the menu-bar indicator. Keeping this outside the
    /// lazily-created controller lets the status items reflect caffeine without paying
    /// the cost of constructing the panel and its views at launch.
    private let caffeine = CaffeineAssertion()
    private var controllerInstance: SpotliteController?

    /// Built on first invocation and kept forever after — an idle agent should not
    /// carry a panel, a table and an icon cache it may never show.
    private var controller: SpotliteController {
        if let controllerInstance { return controllerInstance }

        let controller = SpotliteController(caffeine: caffeine, preferences: preferences)
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onPreferencesChanged = { [weak self] prefs in
            guard let self else { return }
            let enabledStatusItem = !self.preferences.showMenuBarIcon && prefs.showMenuBarIcon
            self.preferences = prefs
            self.applyTheme()
            self.settings?.preferencesDidChange(prefs)
            if enabledStatusItem { self.caffeine.refresh() }
            self.refreshStatusItem()
        }
        controller.onIndexChanged = { [weak self] apps in
            self?.settings?.appsDidChange(apps)
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
                self.controller.dumpFrames("collapsed")
                self.controller.field.stringValue = "a"
                self.controller.updateMatches(for: "a")
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

    private func registerHotKey() {
        hotKey = HotKey(keyCode: preferences.hotKeyCode, modifiers: preferences.hotKeyModifiers) { [weak self] in
            self?.controller.toggle()
        }

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
        guard let replacement = HotKey(keyCode: code, modifiers: modifiers, onFire: { [weak self] in
            self?.controller.toggle()
        }) else { return false }
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
        guard caffeine.state.isActive else {
            if let caffeineStatusItem { NSStatusBar.system.removeStatusItem(caffeineStatusItem) }
            caffeineStatusItem = nil
            return
        }

        let description: String
        switch caffeine.state {
        case .inactive: return
        case .spotlite: description = "Caffeinate active in Spotlite"
        case .external: description = "Caffeinate active in another app"
        }

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
        let state = NSMenuItem(title: description, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if caffeine.state == .spotlite {
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
        guard caffeine.state == .spotlite else { return }
        caffeine.toggle()
    }

    @objc private func openSettingsMenuItem() { openSettings() }

    // MARK: - Settings

    private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(preferences: preferences)
            controller.onChange = { [weak self] prefs in
                guard let self else { return }
                let enabledStatusItem = !self.preferences.showMenuBarIcon && prefs.showMenuBarIcon
                self.preferences = prefs
                self.applyTheme()
                self.controller.preferencesDidChange(prefs)
                if enabledStatusItem { self.caffeine.refresh() }
                self.refreshStatusItem()
            }
            controller.onHotKeyChange = { [weak self] code, modifiers in
                self?.rebindHotKey(code: code, modifiers: modifiers) ?? false
            }
            settings = controller
        }
        settings?.show(apps: controller.indexedApps())
    }
}
