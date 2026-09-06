import AppKit
import ServiceManagement
import SpotliteCore

/// Settings: hotkey, launch-at-login, menu bar visibility, and the full app list with
/// checkboxes. All changes apply live — macOS settings behave that way everywhere, and
/// an OK button would just add a state to get wrong.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow?
    private let table = NSTableView()
    private let filterField = NSSearchField()
    private var loginItemWarning = NSTextField(labelWithString: "")

    private var preferences: Preferences
    private var allApps: [AppEntry] = []
    private var visibleApps: [AppEntry] = []

    var onChange: ((Preferences) -> Void)?
    var onHotKeyChange: ((UInt32, UInt32) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    func show(apps: [AppEntry]) {
        allApps = apps  // AppIndex returns them sorted by name already.
        applyFilter()

        if window == nil { buildWindow() }
        table.reloadData()
        updateLoginItemWarning()

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
            guard let self else { return }
            self.preferences.hotKeyCode = code
            self.preferences.hotKeyModifiers = modifiers
            self.persist()
            self.onHotKeyChange?(code, modifiers)
        }

        let loginItem = NSButton(checkboxWithTitle: "Start at login", target: self,
                                 action: #selector(toggleLoginItem))
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        loginItemWarning.font = .systemFont(ofSize: 11)
        loginItemWarning.textColor = .systemOrange
        loginItemWarning.lineBreakMode = .byWordWrapping
        loginItemWarning.maximumNumberOfLines = 2

        let menuBar = NSButton(checkboxWithTitle: "Show menu bar icon", target: self,
                               action: #selector(toggleMenuBarIcon))
        menuBar.state = preferences.showMenuBarIcon ? .on : .off

        let hint = NSTextField(labelWithString:
            "With the icon hidden, search “settings” in Spotlite to get back here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let listLabel = NSTextField(labelWithString: "Apps  (uncheck to hide from results)")
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
            hotKeyRow, loginItem, loginItemWarning, menuBar, hint, listLabel, filterField, scroll,
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

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Spotlite: login item change failed: \(error)")
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
        updateLoginItemWarning()
    }

    /// SMAppService registers an absolute path. Registering from a build directory
    /// produces a login item pointing at a path that `make clean` deletes.
    private func updateLoginItemWarning() {
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/")
        let enabled = SMAppService.mainApp.status == .enabled
        loginItemWarning.stringValue = (enabled && !installed)
            ? "Running from \(path) — move the app to /Applications, or the login item will break."
            : ""
        loginItemWarning.isHidden = loginItemWarning.stringValue.isEmpty
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        preferences.showMenuBarIcon = (sender.state == .on)
        persist()
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        guard visibleApps.indices.contains(sender.tag),
              let bundleID = visibleApps[sender.tag].bundleID else { return }

        if sender.state == .on {
            preferences.hiddenBundleIDs.remove(bundleID)
        } else {
            preferences.hiddenBundleIDs.insert(bundleID)
        }
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

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = visibleApps[row]

        // The checkbox keeps its own glyph: setting `image` on an NSButton checkbox
        // replaces the checkmark, leaving no visible on/off state.
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleHidden))
        checkbox.tag = row
        let hidden = app.bundleID.map { preferences.hiddenBundleIDs.contains($0) } ?? false
        checkbox.state = hidden ? .off : .on

        let icon = NSImageView()
        icon.image = IconCache.shared.icon(for: app.url)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: app.name)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = hidden ? .tertiaryLabelColor : .labelColor

        let stack = NSStackView(views: [checkbox, icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
