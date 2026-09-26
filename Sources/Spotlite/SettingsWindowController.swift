import AppKit
import ServiceManagement
import SpotliteCore

/// Settings: theme, hotkey, launch-at-login, menu bar visibility, launch history, and the
/// full app list with checkboxes. All changes apply live — macOS settings behave that way everywhere, and
/// an OK button would just add a state to get wrong.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                      NSMenuDelegate {

    private var window: NSWindow?
    private let table = NSTableView()
    private let filterField = NSSearchField()
    private let loginItemWarning = NSTextField(labelWithString: "")
    private let hotKeyWarning = NSTextField(labelWithString: "")
    private let retentionValue = NSTextField(labelWithString: "")
    private var loginItemButton: NSButton?
    private var resetHistoryButton: NSButton?
    private var hotKeyRecorder: HotKeyRecorder?

    private var preferences: Preferences
    private let library: AppLibrary
    private var allApps: [AppEntry] = []
    private var visibleApps: [AppEntry] = []

    /// Popup order of the Appearance menu.
    private static let themeModes: [ThemeMode] = [.system, .light, .dark]

    var onChange: ((Preferences) -> Void)?
    var onHotKeyChange: ((UInt32, UInt32) -> Bool)?

    init(preferences: Preferences, library: AppLibrary) {
        self.preferences = preferences
        self.library = library
        super.init()
    }

    func show(apps: [AppEntry]) {
        allApps = apps  // AppIndex returns them sorted by name already.
        applyFilter()

        if window == nil { buildWindow() }
        table.reloadData()
        updateLoginItemState()
        updateHistoryState()

        // Stay .accessory and force activation: flipping to .regular would make a Dock
        // icon appear and disappear, which reads as a bug.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    // MARK: - Construction

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
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
        themePicker.selectItem(at: Self.themeModes.firstIndex(of: preferences.themeMode) ?? 0)
        themePicker.target = self
        themePicker.action = #selector(themeChoiceChanged)
        let themeRow = NSStackView(views: [themeLabel, themePicker])
        themeRow.orientation = .horizontal
        themeRow.spacing = 12

        let tintLabel = NSTextField(labelWithString: "Tint")
        let tintSlider = NSSlider(value: preferences.glassTint, minValue: 0, maxValue: 1,
                                  target: self, action: #selector(tintChanged))
        // Saved once on release rather than on every step of the drag.
        tintSlider.isContinuous = false
        tintSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let clearLabel = NSTextField(labelWithString: "Clear")
        let solidLabel = NSTextField(labelWithString: "Solid")
        for end in [clearLabel, solidLabel] {
            end.font = .systemFont(ofSize: 11)
            end.textColor = .secondaryLabelColor
        }
        let tintRow = NSStackView(views: [tintLabel, clearLabel, tintSlider, solidLabel])
        tintRow.orientation = .horizontal
        tintRow.spacing = 8
        tintRow.setCustomSpacing(12, after: tintLabel)

        let retentionLabel = NSTextField(labelWithString: "Remember last search")
        let retentionSlider = NSSlider(value: preferences.queryRetention, minValue: 0,
                                       maxValue: QueryMemory.maxRetention,
                                       target: self, action: #selector(retentionChanged))
        // Continuous so the label follows the drag; the value is saved on release.
        retentionSlider.isContinuous = true
        retentionSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        retentionValue.stringValue = Self.retentionText(preferences.queryRetention)
        retentionValue.textColor = .secondaryLabelColor
        retentionValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let retentionRow = NSStackView(views: [retentionLabel, retentionSlider, retentionValue])
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 8
        retentionRow.setCustomSpacing(12, after: retentionLabel)

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

        let historyLabel = NSTextField(labelWithString: "Launch history")
        let resetHistory = NSButton(title: "Reset…", target: self, action: #selector(confirmResetHistory))
        resetHistory.bezelStyle = .rounded
        resetHistory.controlSize = .small
        resetHistoryButton = resetHistory
        let historyRow = NSStackView(views: [historyLabel, resetHistory])
        historyRow.orientation = .horizontal
        historyRow.spacing = 12
        let historyHint = NSTextField(labelWithString:
            "Apps you open often rank higher. Right-click an app below to forget just that one.")
        historyHint.font = .systemFont(ofSize: 11)
        historyHint.textColor = .secondaryLabelColor

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
        let rowMenu = NSMenu()
        rowMenu.autoenablesItems = false
        rowMenu.delegate = self
        table.menu = rowMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let hotKeyRow = NSStackView(views: [hotKeyLabel, recorder])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 12

        let stack = NSStackView(views: [
            hotKeyRow, hotKeyWarning, themeRow, tintRow, retentionRow, screenRow, loginItem, loginItemWarning, menuBar, hint,
            historyRow, historyHint, listLabel, filterField, scroll,
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

    /// SMAppService registers an absolute path. Registering from a build directory
    /// produces a login item pointing at a path that `make clean` deletes.
    private var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        guard sender.state == .off || isInstalled else {
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

    private func updateLoginItemState() {
        let installed = isInstalled
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
        let index = sender.indexOfSelectedItem
        preferences.themeMode = Self.themeModes.indices.contains(index) ? Self.themeModes[index] : .system
        persist()
    }

    @objc private func tintChanged(_ sender: NSSlider) {
        preferences.glassTint = sender.doubleValue
        persist()
    }

    @objc private func retentionChanged(_ sender: NSSlider) {
        let seconds = sender.doubleValue.rounded()
        retentionValue.stringValue = Self.retentionText(seconds)
        guard NSApp.currentEvent?.type != .leftMouseDragged else { return }
        preferences.queryRetention = seconds
        persist()
    }

    private static func retentionText(_ seconds: TimeInterval) -> String {
        seconds > 0 ? "\(Int(seconds)) s" : "Off"
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        preferences.showMenuBarIcon = (sender.state == .on)
        persist()
    }

    // MARK: - Launch history

    /// Launches can happen while Settings is open, so this is refreshed whenever the
    /// window comes forward rather than only when it is built.
    private func updateHistoryState() {
        resetHistoryButton?.isEnabled = library.hasHistory
    }

    /// Confirmed, unlike every other setting here: the history took months of use to
    /// build and nothing can bring it back.
    @objc private func confirmResetHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset launch history?"
        alert.informativeText = "Results are ranked by name alone until Spotlite learns which apps you open again."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.library.resetHistory()
            self.updateHistoryState()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard visibleApps.indices.contains(row) else { return }
        let app = visibleApps[row]
        let item = NSMenuItem(title: "Forget Launch History", action: #selector(forgetHistory),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = app.id
        item.isEnabled = library.hasHistory(for: app.id)
        menu.addItem(item)
    }

    @objc private func forgetHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        library.forgetHistory(for: id)
        updateHistoryState()
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

    func windowDidBecomeKey(_ notification: Notification) {
        updateHistoryState()
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
