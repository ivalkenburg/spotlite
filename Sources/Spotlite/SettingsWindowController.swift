import AppKit
import SpotliteCore

/// Settings, in toolbar tabs: General, Appearance, Search, and Items (the full list of
/// apps, panes, commands and links). All changes apply live — macOS settings behave that
/// way everywhere, and an OK button would just add a state to get wrong.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {

    private enum Tab: String, CaseIterable {
        case general, appearance, search, items

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .search: "Search"
            case .items: "Items"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .search: "magnifyingglass"
            case .items: "list.bullet"
            }
        }

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
    }

    /// UI state, not a setting, so it lives in user defaults rather than Preferences.
    private static let selectedTabKey = "SettingsSelectedTab"

    private var window: NSWindow?
    private var currentTab: Tab?
    private let model: SettingsModel
    private let general: GeneralSettingsViewController
    private let appearance: AppearanceSettingsViewController
    private let search: SearchSettingsViewController
    private let items: ItemsSettingsViewController

    var onChange: ((Preferences) -> Void)? {
        get { model.onChange }
        set { model.onChange = newValue }
    }

    var onHotKeyChange: ((UInt32, UInt32) -> Bool)? {
        get { model.onHotKeyChange }
        set { model.onHotKeyChange = newValue }
    }

    init(preferences: Preferences, library: AppLibrary) {
        model = SettingsModel(preferences: preferences, library: library)
        general = GeneralSettingsViewController(model: model)
        appearance = AppearanceSettingsViewController(model: model)
        search = SearchSettingsViewController(model: model)
        items = ItemsSettingsViewController(model: model)
        super.init()
        general.onLayoutChange = { [weak self] in
            if self?.currentTab == .general { self?.fitWindow(animated: true) }
        }
    }

    func show(apps: [AppEntry]) {
        items.setApps(apps)

        if window == nil {
            buildWindow()
            let saved = UserDefaults.standard.string(forKey: Self.selectedTabKey).flatMap(Tab.init)
            select(saved ?? .general)
            window?.center()
        }

        // Stay .accessory and force activation: flipping to .regular would make a Dock
        // icon appear and disappear, which reads as a bug.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func preferencesDidChange(_ updated: Preferences) {
        model.preferences = updated
        items.reload()
    }

    func appsDidChange(_ apps: [AppEntry]) {
        items.setApps(apps)
    }

    // MARK: - Window and tabs

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsForm.width, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSView()

        let toolbar = NSToolbar(identifier: "SpotliteSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        self.window = window
    }

    private func controller(for tab: Tab) -> NSViewController {
        switch tab {
        case .general: general
        case .appearance: appearance
        case .search: search
        case .items: items
        }
    }

    @objc private func tabClicked(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab)
    }

    private func select(_ tab: Tab) {
        guard let window, let container = window.contentView, tab != currentTab else { return }
        window.toolbar?.selectedItemIdentifier = tab.identifier
        window.title = tab.title
        UserDefaults.standard.set(tab.rawValue, forKey: Self.selectedTabKey)
        currentTab = tab
        // Recording listens for keys app-wide, so it must not outlive its page.
        general.cancelRecording()

        switch tab {
        case .general: general.updateLoginItemState()
        case .search: search.updateHistoryState()
        case .appearance, .items: break
        }

        container.subviews.forEach { $0.removeFromSuperview() }
        let page = controller(for: tab).view
        container.addSubview(page)
        // Pinned to the top only, so the page keeps its own size while the window
        // animates to it.
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        fitWindow(animated: window.isVisible)
    }

    /// Resizes the window to the current page, keeping its top edge where it is.
    private func fitWindow(animated: Bool) {
        guard let window, let tab = currentTab else { return }
        let page = controller(for: tab).view
        page.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: page.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        // A window dragged low grows upward instead of past the bottom of the screen.
        if let visible = window.screen?.visibleFrame { frame.origin.y = max(frame.minY, visible.minY) }
        window.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(tabClicked)
        return item
    }

    // MARK: - NSWindowDelegate

    /// Also covers `show()`: making the window key lands here.
    func windowDidBecomeKey(_ notification: Notification) {
        general.updateLoginItemState()
        search.updateHistoryState()
    }

    func windowDidResignKey(_ notification: Notification) {
        general.cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        general.cancelRecording()
    }
}
