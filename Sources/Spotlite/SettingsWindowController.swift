import AppKit
import ServiceManagement
import SpotliteCore

/// Settings: theme, hotkey, launch-at-login, menu bar visibility, what results include,
/// launch history, and the full list of apps, commands and links with checkboxes. All changes apply live — macOS settings behave that way everywhere, and
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
    private static let engines = WebSearchEngine.allCases

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
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

        let systemSettings = NSButton(checkboxWithTitle: "Show System Settings in results", target: self,
                                      action: #selector(toggleSystemSettings))
        systemSettings.state = preferences.showSystemSettings ? .on : .off

        let systemCommands = NSButton(checkboxWithTitle: "Show commands in results (Lock Screen, Sleep, Restart…)",
                                      target: self, action: #selector(toggleSystemCommands))
        systemCommands.state = preferences.showSystemCommands ? .on : .off

        let recentApps = NSButton(checkboxWithTitle: "Show recent apps before you type", target: self,
                                  action: #selector(toggleRecentApps))
        recentApps.state = preferences.showRecentApps ? .on : .off

        let runningIndicator = NSButton(checkboxWithTitle: "Mark running apps with a dot", target: self,
                                        action: #selector(toggleRunningIndicator))
        runningIndicator.state = preferences.showRunningIndicator ? .on : .off

        let webSearch = NSButton(checkboxWithTitle: "Offer web search with", target: self,
                                 action: #selector(toggleWebSearch))
        webSearch.state = preferences.showWebSearch ? .on : .off
        let enginePicker = NSPopUpButton()
        enginePicker.addItems(withTitles: Self.engines.map(\.name))
        enginePicker.selectItem(at: Self.engines.firstIndex(of: preferences.webSearchEngine) ?? 0)
        enginePicker.target = self
        enginePicker.action = #selector(engineChoiceChanged)
        let webSearchRow = NSStackView(views: [webSearch, enginePicker])
        webSearchRow.orientation = .horizontal
        webSearchRow.spacing = 6

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
            "Apps you open often rank higher. Right-click one below to forget it, or a link to edit it.")
        historyHint.font = .systemFont(ofSize: 11)
        historyHint.textColor = .secondaryLabelColor

        let listLabel = NSTextField(labelWithString: "Apps, commands and links  (uncheck to hide, or give one a short alias)")
        listLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        let addLink = NSButton(title: "Add Link…", target: self, action: #selector(addLinkClicked))
        addLink.bezelStyle = .rounded
        addLink.toolTip = "A folder, file or web address to find by name, like an app"
        addLink.setContentHuggingPriority(.required, for: .horizontal)
        let filterRow = NSStackView(views: [filterField, addLink])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8

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

        // With the menu bar icon hidden, this is the only way to quit.
        let quitButton = NSButton(title: "Quit Spotlite", target: NSApp,
                                  action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            hotKeyRow, hotKeyWarning, themeRow, tintRow, retentionRow, screenRow, loginItem, loginItemWarning, menuBar, hint,
            systemSettings, systemCommands, recentApps, runningIndicator, webSearchRow,
            historyRow, historyHint, listLabel, filterRow, scroll, quitButton,
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
            filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
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

    @objc private func toggleSystemSettings(_ sender: NSButton) {
        preferences.showSystemSettings = (sender.state == .on)
        persist()
    }

    @objc private func toggleSystemCommands(_ sender: NSButton) {
        preferences.showSystemCommands = (sender.state == .on)
        persist()
    }

    @objc private func toggleRecentApps(_ sender: NSButton) {
        preferences.showRecentApps = (sender.state == .on)
        persist()
    }

    @objc private func toggleRunningIndicator(_ sender: NSButton) {
        preferences.showRunningIndicator = (sender.state == .on)
        persist()
    }

    @objc private func toggleWebSearch(_ sender: NSButton) {
        preferences.showWebSearch = (sender.state == .on)
        persist()
    }

    @objc private func engineChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        preferences.webSearchEngine = Self.engines.indices.contains(index) ? Self.engines[index] : .google
        persist()
    }

    // MARK: - Links

    @objc private func addLinkClicked() {
        editLink(nil)
    }

    @objc private func editLinkClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let link = preferences.links.first(where: { $0.entryID == id }) else { return }
        editLink(link)
    }

    @objc private func removeLinkClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.links.removeAll { $0.entryID == id }
        // Nothing else will ever use these keys again.
        preferences.aliases.removeValue(forKey: id)
        preferences.hiddenBundleIDs.remove(id)
        library.forgetHistory(for: id)
        updateHistoryState()
        persist()
    }

    /// A sheet with the link's name, target and alias. An invalid entry reopens the sheet
    /// with what was typed and a line saying what is wrong, rather than losing the input.
    private func editLink(_ existing: Link?, draft: (name: String, target: String, alias: String)? = nil,
                          problem: String? = nil) {
        guard let window else { return }
        let alias = existing.flatMap { preferences.aliases[$0.entryID] } ?? ""
        let fields = (name: NSTextField(string: draft?.name ?? existing?.name ?? ""),
                      target: NSTextField(string: draft?.target ?? existing?.target ?? ""),
                      alias: NSTextField(string: draft?.alias ?? alias))
        fields.name.placeholderString = "Downloads"
        fields.target.placeholderString = "~/Downloads or github.com"
        fields.alias.placeholderString = "Optional, e.g. dl"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), fields.name],
            [NSTextField(labelWithString: "Opens"), fields.target],
            [NSTextField(labelWithString: "Alias"), fields.alias],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 240
        grid.frame.size = grid.fittingSize

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Link" : "Edit Link"
        alert.informativeText = problem
            ?? "A folder, file or web address, found by its name or alias like an app."
        alert.accessoryView = grid
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields.name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let draft = (name: fields.name.stringValue.trimmingCharacters(in: .whitespaces),
                         target: fields.target.stringValue.trimmingCharacters(in: .whitespaces),
                         alias: fields.alias.stringValue.trimmingCharacters(in: .whitespaces))
            if let problem = Self.problem(name: draft.name, target: draft.target) {
                // After this sheet has gone: a window shows one sheet at a time.
                DispatchQueue.main.async { self.editLink(existing, draft: draft, problem: problem) }
                return
            }
            self.saveLink(existing, name: draft.name, target: draft.target, alias: draft.alias)
        }
    }

    private static func problem(name: String, target: String) -> String? {
        if name.isEmpty { return "Give the link a name." }
        guard let url = Link.resolve(target) else {
            return "“Opens” needs a path starting with / or ~, or a web address."
        }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            return "Nothing exists at \(url.path)."
        }
        return nil
    }

    private func saveLink(_ existing: Link?, name: String, target: String, alias: String) {
        var link = existing ?? Link(name: name, target: target)
        link.name = name
        link.target = target
        if let index = preferences.links.firstIndex(where: { $0.id == link.id }) {
            preferences.links[index] = link
        } else {
            preferences.links.append(link)
        }
        if alias.isEmpty { preferences.aliases.removeValue(forKey: link.entryID) }
        else { preferences.aliases[link.entryID] = alias }
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
        if app.kind == .link {
            for (title, action) in [("Edit Link…", #selector(editLinkClicked)),
                                    ("Remove Link", #selector(removeLinkClicked))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = app.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
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
