import AppKit
import SpotliteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Built on first invocation and kept forever after — an idle agent should not
    /// carry a panel, a table and an icon cache it may never show.
    private lazy var controller: SpotliteController = {
        let controller = SpotliteController()
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onPreferencesChanged = { [weak self] prefs in
            self?.preferences = prefs
            self?.settings?.preferencesDidChange(prefs)
            self?.refreshStatusItem()
        }
        return controller
    }()

    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var preferences = Storage.loadPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            Task { @MainActor in self?.controller.toggle() }
        }

        if hotKey == nil {
            NSLog("Spotlite: hotkey registration failed — the chord is already claimed.")
            // A silently dead shortcut is the worst outcome: surface it where it can be changed.
            openSettings()
        }
    }

    private func rebindHotKey(code: UInt32, modifiers: UInt32) {
        hotKey = nil  // Unregister before claiming the new chord.
        preferences.hotKeyCode = code
        preferences.hotKeyModifiers = modifiers
        registerHotKey()
    }

    // MARK: - Menu bar

    private func refreshStatusItem() {
        guard preferences.showMenuBarIcon else {
            // Dropping the reference is not enough; the item must be removed explicitly.
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass.circle",
                                     accessibilityDescription: "Spotlite")

        let menu = NSMenu()
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

    @objc private func showPanel() { controller.show() }

    @objc private func openSettingsMenuItem() { openSettings() }

    // MARK: - Settings

    private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(preferences: preferences)
            controller.onChange = { [weak self] prefs in
                self?.preferences = prefs
                self?.controller.preferencesDidChange(prefs)
                self?.refreshStatusItem()
            }
            controller.onHotKeyChange = { [weak self] code, modifiers in
                self?.rebindHotKey(code: code, modifiers: modifiers)
            }
            settings = controller
        }
        settings?.show(apps: controller.indexedApps())
    }
}
