import AppKit
import ServiceManagement
import SpotliteCore

/// Settings: theme, hotkey, launch-at-login, menu bar visibility, and the full app list with
/// checkboxes. All changes apply live — macOS settings behave that way everywhere, and
/// an OK button would just add a state to get wrong.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow?
    private let table = NSTableView()
    private let filterField = NSSearchField()
    private var loginItemWarning = NSTextField(labelWithString: "")
    private var hotKeyWarning = NSTextField(labelWithString: "")
    private var loginItemButton: NSButton?
    private var hotKeyRecorder: HotKeyRecorder?

    private var preferences: Preferences
    private var allApps: [AppEntry] = []
    private var visibleApps: [AppEntry] = []

    var onChange: ((Preferences) -> Void)?
    var onHotKeyChange: ((UInt32, UInt32) -> Bool)?

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    func show(apps: [AppEntry]) {
        allApps = apps  // AppIndex returns them sorted by name already.
        applyFilter()

        if window == nil { buildWindow() }
        table.reloadData()
        updateLoginItemState()

        // Stay .accessory and force activation: flipping to .regular would make a Dock
        // icon appear and disappear, which reads as a bug.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    // MARK: - Construction

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Spotlite Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let hotKeyLabel = NSTextField(labelWithString: "Shortcut")
        let recorder = HotKeyRecorder(keyCode: preferences.hotKeyCode, modifiers: preferences.hotKeyModifiers)
        recorder.onChange = { [weak self] code, modifiers in
            guard let self else { return false }
            guard self.onHotKeyChange?(code, modifiers) == true else {
                self.hotKeyWarning.stringValue = "That shortcut is already in use. The previous shortcut is still active."
                self.hotKeyWarning.isHidden = false
                return false
            }
            self.preferences.hotKeyCode = code
            self.preferences.hotKeyModifiers = modifiers
            self.persist()
            self.hotKeyWarning.isHidden = true
            return true
        }
        hotKeyRecorder = recorder

        hotKeyWarning.font = .systemFont(ofSize: 11)
        hotKeyWarning.textColor = .systemRed
        hotKeyWarning.lineBreakMode = .byWordWrapping
        hotKeyWarning.maximumNumberOfLines = 2
        hotKeyWarning.isHidden = true

        let loginItem = NSButton(checkboxWithTitle: "Start at login", target: self,
                                 action: #selector(toggleLoginItem))
        loginItemButton = loginItem

        loginItemWarning.font = .systemFont(ofSize: 11)
        loginItemWarning.textColor = .systemOrange
        loginItemWarning.lineBreakMode = .byWordWrapping
        loginItemWarning.maximumNumberOfLines = 2

        let menuBar = NSButton(checkboxWithTitle: "Show menu bar icon", target: self,
                               action: #selector(toggleMenuBarIcon))
        menuBar.state = preferences.showMenuBarIcon ? .on : .off

        let themeLabel = NSTextField(labelWithString: "Appearance")
        let themePicker = NSPopUpButton()
        themePicker.addItems(withTitles: ["System", "Light", "Dark"])
        switch preferences.themeMode {
        case .system: themePicker.selectItem(at: 0)
        case .light: themePicker.selectItem(at: 1)
        case .dark: themePicker.selectItem(at: 2)
        }
        themePicker.target = self
        themePicker.action = #selector(themeChoiceChanged)
        let themeRow = NSStackView(views: [themeLabel, themePicker])
        themeRow.orientation = .horizontal
        themeRow.spacing = 12

        let screenLabel = NSTextField(labelWithString: "Open on")
        let screenPicker = NSPopUpButton()
        screenPicker.addItems(withTitles: ["Display with pointer", "Main display"])
        screenPicker.selectItem(at: preferences.panelScreen == .primary ? 1 : 0)
        screenPicker.target = self
        screenPicker.action = #selector(screenChoiceChanged)
        let resetButton = NSButton(title: "Reset Size & Position", target: self,
                                   action: #selector(resetGeometry))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small

        let screenRow = NSStackView(views: [screenLabel, screenPicker, resetButton])
        screenRow.orientation = .horizontal
        screenRow.spacing = 12

        let hint = NSTextField(labelWithString:
            "With the icon hidden, search “settings” in Spotlite to get back here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let listLabel = NSTextField(labelWithString: "Apps  (uncheck to hide, or give one a short alias)")
        listLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true

        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let hotKeyRow = NSStackView(views: [hotKeyLabel, recorder])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 12

        let stack = NSStackView(views: [
            hotKeyRow, hotKeyWarning, themeRow, screenRow, loginItem, loginItemWarning, menuBar, hint,
            listLabel, filterField, scroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            filterField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        self.window = window
        updateLoginItemState()
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        applyFilter()
        table.reloadData()
    }

    private func applyFilter() {
        let query = filterField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        visibleApps = query.isEmpty
            ? allApps
            : allApps.filter { $0.name.lowercased().contains(query) }
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        guard sender.state == .off || installed else {
            sender.state = .off
            updateLoginItemState()
            return
        }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Spotlite: login item change failed: \(error)")
        }
        updateLoginItemState()
    }

    /// SMAppService registers an absolute path. Registering from a build directory
    /// produces a login item pointing at a path that `make clean` deletes.
    private func updateLoginItemState() {
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/")
        let status = SMAppService.mainApp.status
        loginItemButton?.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        // A previously registered development copy must remain removable.
        loginItemButton?.isEnabled = installed || status == .enabled || status == .requiresApproval

        switch status {
        case .requiresApproval:
            loginItemWarning.stringValue = "Allow Spotlite in System Settings › General › Login Items."
        case .notFound:
            loginItemWarning.stringValue = "macOS could not find this login item. Reinstall Spotlite in /Applications."
        default:
            loginItemWarning.stringValue = installed
                ? ""
                : "Move Spotlite to /Applications before enabling Start at login."
        }
        loginItemWarning.isHidden = loginItemWarning.stringValue.isEmpty
    }

    /// The way back from a panel dragged somewhere unusable. Without it the only
    /// recovery is editing JSON by hand.
    @objc private func resetGeometry() {
        preferences.panelGeometry = .default
        persist()
    }

    @objc private func screenChoiceChanged(_ sender: NSPopUpButton) {
        preferences.panelScreen = (sender.indexOfSelectedItem == 1) ? .primary : .followPointer
        persist()
    }

    @objc private func themeChoiceChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1: preferences.themeMode = .light
        case 2: preferences.themeMode = .dark
        default: preferences.themeMode = .system
        }
        persist()
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        preferences.showMenuBarIcon = (sender.state == .on)
        persist()
    }

    private func persist() {
        Storage.save(preferences)
        onChange?(preferences)
    }

    func preferencesDidChange(_ updated: Preferences) {
        preferences = updated
        table.reloadData()
    }

    func appsDidChange(_ apps: [AppEntry]) {
        allApps = apps
        applyFilter()
        table.reloadData()
    }

    func windowDidResignKey(_ notification: Notification) {
        hotKeyRecorder?.cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        hotKeyRecorder?.cancelRecording()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = visibleApps[row]
        let view = tableView.makeView(withIdentifier: SettingsRowView.reuseID, owner: self) as? SettingsRowView
            ?? {
                let v = SettingsRowView(frame: .zero)
                v.identifier = SettingsRowView.reuseID
                return v
            }()

        view.onVisibilityChanged = { [weak self] entry, hidden in
            guard let self, let id = entry.bundleID else { return }
            if hidden { self.preferences.hiddenBundleIDs.insert(id) }
            else { self.preferences.hiddenBundleIDs.remove(id) }
            self.persist()
            self.table.reloadData()
        }
        view.onAliasChanged = { [weak self] entry, alias in
            guard let self, let id = entry.bundleID else { return }
            let trimmed = alias.trimmingCharacters(in: .whitespaces)
            let existing = self.preferences.aliases[id] ?? ""
            guard trimmed != existing else { return }
            if trimmed.isEmpty { self.preferences.aliases.removeValue(forKey: id) }
            else { self.preferences.aliases[id] = trimmed }
            self.persist()
        }

        let hidden = app.bundleID.map { preferences.hiddenBundleIDs.contains($0) } ?? false
        let alias = app.bundleID.flatMap { preferences.aliases[$0] } ?? ""
        view.configure(with: app, hidden: hidden, alias: alias)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
