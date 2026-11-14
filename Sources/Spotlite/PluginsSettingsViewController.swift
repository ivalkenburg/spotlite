import AppKit
import SpotliteCore

/// Installed plugins: switch one off, install from a folder or an address, check for
/// updates, remove, or reload after editing one. A plugin that cannot be used is listed
/// with the reason.
@MainActor
final class PluginsSettingsViewController: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate,
                                           NSMenuItemValidation, NSMenuDelegate {
    private let table = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let moreButton = NSButton()
    private let configureButton = NSButton(title: "Configure…", target: nil, action: nil)
    /// The selected plugin's actions on a right click, beside the ones the buttons show.
    private let rowMenu = NSMenu()
    private let emptyLabel = SettingsForm.hint("No plugins installed.")
    private let lastRunTitle = NSTextField(labelWithString: "Last run")
    private let lastRun = NSTextView.scrollableTextView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private var plugins: [InstalledPlugin] = []
    /// Read with the list, only while Settings shows it.
    private var sources: [String: PluginSourceRecord] = [:]
    /// Found by the last check, in memory: nothing checks on its own.
    private var availableUpdates: [String: String?] = [:]
    private var installController: PluginInstallWindowController?
    private var galleryController: PluginGalleryWindowController?
    /// The last index read while Settings is open, so reopening the gallery doesn't
    /// fetch again. Cleared when Settings closes.
    private var galleryIndex: PluginGalleryIndex?
    private var configurationController: PluginConfigurationWindowController?
    private var runnerController: PluginDebugRunnerWindowController?

    private static let height: CGFloat = 560

    func settingsClosed() {
        galleryIndex = nil
        galleryController?.onFetched = nil
        // Settings keeps its pane controllers for reuse. End their sheets explicitly
        // so downloads and the debug runner do not survive closing the window.
        let controllers: [NSWindowController?] = [installController, configurationController, runnerController, galleryController]
        for controller in controllers {
            guard let window = controller?.window else { continue }
            window.sheetParent?.endSheet(window, returnCode: .cancel)
            window.orderOut(nil)
        }
        installController = nil
        configurationController = nil
        runnerController = nil
        galleryController = nil
    }

    override func loadView() {
        table.headerView = nil
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(configureClicked)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin")))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)

        // Few buttons: add, remove, the rest of what a plugin or the folder can do in
        // one menu, and Configure, which is what a selected plugin most often needs.
        menuButton(addButton, symbol: "plus", label: "Add Plugin", items: [
            item("Install from Folder…", #selector(installClicked), tip: "Choose a folder that contains a plugin.json"),
            item("Install from URL…", #selector(installFromURLClicked),
                 tip: "A GitHub repository, an https .zip or a git address"),
            .separator(),
            item("Browse Gallery…", #selector(browseGalleryClicked),
                 tip: "Plugins listed in Spotlite’s gallery. Loaded only when opened."),
        ])
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Plugin")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = "Move the selected plugin to the Trash"
        removeButton.widthAnchor.constraint(equalToConstant: Self.symbolWidth).isActive = true
        menuButton(moreButton, symbol: "ellipsis", label: "More", items: [
            item("Run Command…", #selector(runClicked), tip: "Run a command and see its raw output, without applying it"),
            item("Reveal in Finder", #selector(revealClicked), tip: "Show the plugin’s folder in Finder"),
            item("Open Data Folder", #selector(openDataClicked), tip: "Open the folder where the plugin keeps its own data"),
            .separator(),
            item("Check for Updates", #selector(checkUpdatesClicked),
                 tip: "Ask each plugin’s source for a newer version. Spotlite never checks on its own."),
            item("Reload Plugins", #selector(reloadClicked), tip: "Read every plugin again, after editing one"),
            item("Open Plugins Folder", #selector(openFolderClicked), tip: nil),
        ])
        configureButton.target = self
        configureButton.action = #selector(configureClicked)
        configureButton.bezelStyle = .rounded
        for menuItem in [item("Configure…", #selector(configureClicked)), item("Run Command…", #selector(runClicked)),
                         item("Reveal in Finder", #selector(revealClicked)), item("Open Data Folder", #selector(openDataClicked)),
                         .separator(), item("Remove…", #selector(removeClicked))] {
            rowMenu.addItem(menuItem)
        }
        rowMenu.delegate = self
        table.menu = rowMenu

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addButton, removeButton, spacer, moreButton, configureButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setCustomSpacing(4, after: addButton)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.setAccessibilityLabel("Source")

        lastRunTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        lastRunTitle.textColor = .secondaryLabelColor
        lastRunTitle.lineBreakMode = .byTruncatingTail
        let lastRunText = lastRun.documentView as! NSTextView
        lastRunText.isEditable = false
        lastRunText.isSelectable = true
        lastRunText.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        lastRunText.textContainerInset = NSSize(width: 3, height: 3)
        lastRun.borderType = .bezelBorder
        lastRun.setAccessibilityLabel("Last run")
        lastRun.heightAnchor.constraint(equalToConstant: 96).isActive = true
        // A run that finishes while Settings is open shows without polling.
        PluginHost.shared.onRunRecorded = { [weak self] id in self?.runRecorded(id) }

        let caption = SettingsForm.hint(
            "Plugins add commands to search. A plugin is a program that runs with your permissions when you use it: install only ones you trust.")
        caption.preferredMaxLayoutWidth = SettingsForm.width - 40

        let stack = NSStackView(views: [scroll, buttons, sourceLabel, lastRunTitle, lastRun, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(6, after: buttons)
        stack.setCustomSpacing(16, after: sourceLabel)
        stack.setCustomSpacing(4, after: lastRunTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for fullWidth in [scroll, buttons, sourceLabel, lastRunTitle, lastRun, caption] as [NSView] {
            fullWidth.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: SettingsForm.width),
            stack.heightAnchor.constraint(equalToConstant: Self.height),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = stack
        reload()
    }

    private func item(_ title: String, _ action: Selector, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = tip
        return item
    }

    /// A symbol button that opens a menu below itself, the same size as the plain
    /// buttons beside it. Its items are enabled by `validateMenuItem`.
    private func menuButton(_ button: NSButton, symbol: String, label: String, items: [NSMenuItem]) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(showButtonMenu(_:))
        button.setAccessibilityLabel(label)
        button.toolTip = label
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        button.menu = menu
        button.widthAnchor.constraint(equalToConstant: Self.symbolWidth).isActive = true
    }

    @objc private func showButtonMenu(_ sender: NSButton) {
        sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private static let symbolWidth: CGFloat = 36

    /// Shows what the host has now. The host itself is read again only on request.
    func reload() {
        guard isViewLoaded else { return }
        plugins = PluginHost.shared.plugins
        let store = PluginHost.shared.sources
        sources = Dictionary(plugins.compactMap { plugin in store.load(for: plugin.id).map { (plugin.id, $0) } },
                             uniquingKeysWith: { first, _ in first })
        table.reloadData()
        emptyLabel.isHidden = !plugins.isEmpty
        updateRemoveButton()
    }

    private var selectedPlugin: InstalledPlugin? {
        plugins.indices.contains(table.selectedRow) ? plugins[table.selectedRow] : nil
    }

    private func updateRemoveButton() {
        let selected = selectedPlugin
        removeButton.isEnabled = selected != nil
        configureButton.isEnabled = canConfigure(selected)
        showSource()
        showLastRun()
    }

    private func canConfigure(_ plugin: InstalledPlugin?) -> Bool {
        plugin?.isUsable == true && plugin?.manifest?.settings.isEmpty == false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selected = selectedPlugin
        switch menuItem.action {
        case #selector(configureClicked): return canConfigure(selected)
        case #selector(runClicked):
            return selected?.isUsable == true
                && selected?.manifest?.commands.contains { PluginRunAction($0.action) != nil } == true
        case #selector(revealClicked), #selector(removeClicked): return selected != nil
        case #selector(openDataClicked): return selected?.isUsable == true
        case #selector(checkUpdatesClicked): return !sources.isEmpty
        default: return true
        }
    }

    /// A right click acts on the row under the pointer, so it becomes the selection.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === rowMenu, table.clickedRow >= 0, table.clickedRow != table.selectedRow else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
    }

    /// Where the selected plugin came from, which decides whether it can be updated.
    private func showSource() {
        guard let plugin = selectedPlugin else {
            sourceLabel.stringValue = ""
            sourceLabel.toolTip = nil
            return
        }
        if PluginInstaller.isLinked(plugin) {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: plugin.directory.path)) ?? ""
            sourceLabel.stringValue = "Linked folder " + (target as NSString).abbreviatingWithTildeInPath
        } else if let record = sources[plugin.id] {
            var parts = ["From " + record.address]
            if let commit = record.commit { parts.append(String(commit.prefix(7))) }
            parts.append("Installed " + record.installedAt.formatted(date: .abbreviated, time: .omitted))
            if let update = availableUpdates[plugin.id] { parts.append("Update available: " + (update ?? "new version")) }
            sourceLabel.stringValue = parts.joined(separator: " · ")
        } else {
            sourceLabel.stringValue = "Installed from a folder"
        }
        sourceLabel.toolTip = sourceLabel.stringValue
    }

    /// The selected plugin's last run since launch, from the host's memory.
    private func showLastRun() {
        let text = lastRun.documentView as! NSTextView
        guard let plugin = selectedPlugin else {
            lastRunTitle.stringValue = "Last run"
            lastRunTitle.textColor = .secondaryLabelColor
            text.string = "Select a plugin to see its last run."
            return
        }
        guard let record = PluginHost.shared.lastRun(for: plugin.id) else {
            lastRunTitle.stringValue = "Last run"
            lastRunTitle.textColor = .secondaryLabelColor
            text.string = "No runs since Spotlite started."
            return
        }
        let time = record.date.formatted(date: .omitted, time: .standard)
        lastRunTitle.stringValue = (record.failed ? "Last error" : "Last run") + " · " + time
        lastRunTitle.textColor = record.failed ? .systemRed : .secondaryLabelColor
        text.string = record.details
        text.scrollToBeginningOfDocument(nil)
    }

    private func runRecorded(_ id: String) {
        guard isViewLoaded, selectedPlugin?.id == id else { return }
        showLastRun()
    }

    func configure(pluginID: String) {
        guard let window = view.window, configurationController == nil, runnerController == nil, installController == nil,
              let row = plugins.firstIndex(where: { $0.id == pluginID && $0.isUsable }),
              plugins[row].manifest?.settings.isEmpty == false else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let editor = PluginConfigurationWindowController(plugin: plugins[row])
        editor.onChange = { [weak self] in
            self?.reload()
            self?.model.onPluginConfigurationChanged?()
        }
        configurationController = editor
        guard let sheet = editor.window else { configurationController = nil; return }
        window.beginSheet(sheet) { [weak self] _ in self?.configurationController = nil }
    }

    @objc private func runClicked() {
        guard let window = view.window, runnerController == nil, configurationController == nil, installController == nil,
              let plugin = selectedPlugin, plugin.isUsable else { return }
        let runner = PluginDebugRunnerWindowController(plugin: plugin)
        runnerController = runner
        guard let sheet = runner.window else { runnerController = nil; return }
        // Dropping the controller releases the run, its output and the sheet.
        window.beginSheet(sheet) { [weak self] _ in self?.runnerController = nil }
    }

    @objc private func revealClicked() {
        guard let plugin = selectedPlugin else { return }
        NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
    }

    @objc private func openDataClicked() {
        guard let plugin = selectedPlugin, plugin.isUsable else { return }
        let directory = PluginStore.dataDirectory(for: plugin.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func configureClicked() {
        guard plugins.indices.contains(table.selectedRow) else { return }
        configure(pluginID: plugins[table.selectedRow].id)
    }

    /// After the folder changed: the host reads it, search takes the new commands.
    private func pluginsChanged() {
        PluginHost.shared.reload()
        model.onPluginsChanged?()
        reload()
    }

    // MARK: - Actions

    @objc private func installClicked() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a plugin folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Let the open panel's sheet finish closing before another may open.
            DispatchQueue.main.async { self.install(from: url) }
        }
    }

    @objc private func installFromURLClicked() {
        present(.address)
    }

    @objc private func checkUpdatesClicked() {
        present(.checkUpdates(plugins.filter { sources[$0.id] != nil && !PluginInstaller.isLinked($0) }))
    }

    @objc private func browseGalleryClicked() {
        presentGallery()
    }

    /// The gallery sheet. Its Install and Update open the install sheet on top of it.
    @discardableResult
    func presentGallery() -> PluginGalleryWindowController? {
        guard let window = view.window, galleryController == nil, installController == nil,
              configurationController == nil, runnerController == nil else { return nil }
        let controller = PluginGalleryWindowController(cached: galleryIndex, installed: { PluginHost.shared.plugins },
                                                       fetch: PluginHost.shared.galleryFetcher())
        controller.onFetched = { [weak self] index in self?.galleryIndex = index }
        controller.onInstall = { [weak self, weak controller] entry in
            guard let self, let source = entry.installSource, let sheet = controller?.window else { return }
            self.present(.source(source), over: sheet)
        }
        galleryController = controller
        guard let sheet = controller.window else { galleryController = nil; return nil }
        window.beginSheet(sheet) { [weak self] _ in self?.galleryController = nil }
        return controller
    }

    /// The address flow in one sheet: what it installs, Settings shows as a folder install.
    /// `parent` is the window it attaches to: Settings, or the gallery's sheet.
    @discardableResult
    func present(_ start: PluginInstallWindowController.Start, over parent: NSWindow? = nil) -> PluginInstallWindowController? {
        guard let window = parent ?? view.window, installController == nil, configurationController == nil,
              runnerController == nil else { return nil }
        let controller = PluginInstallWindowController(installer: PluginHost.shared.installer(), start: start)
        controller.onInstalled = { [weak self] installed in
            self?.availableUpdates[installed.id] = nil
            self?.installed(installed)
            self?.galleryController?.refreshStatus()
        }
        controller.onChecked = { [weak self] checks in
            guard let self else { return }
            for check in checks {
                if case .available(let version) = check.status { self.availableUpdates[check.pluginID] = .some(version) }
                else { self.availableUpdates[check.pluginID] = nil }
            }
            self.showSource()
        }
        installController = controller
        guard let sheet = controller.window else { installController = nil; return nil }
        // Dropping the controller cancels whatever it was downloading.
        window.beginSheet(sheet) { [weak self] _ in self?.installController = nil }
        return controller
    }

    private func install(from url: URL) {
        let candidate = PluginStore.load(url)
        guard candidate.isUsable else {
            alert("This folder is not a usable plugin", candidate.problem ?? "")
            return
        }
        let existing = PluginHost.shared.plugins.first { $0.id == candidate.id }
        guard let existing, let window = view.window else {
            finishInstall(from: url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace “\(existing.name)”?"
        alert.informativeText = "A plugin with the id \(candidate.id) is already installed."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { self?.finishInstall(from: url) }
        }
    }

    private func finishInstall(from url: URL) {
        do {
            let installed = try PluginStore.install(from: url, into: PluginHost.shared.pluginsDirectory)
            // A folder replaces whatever an address installed: it has no source to check.
            PluginHost.shared.sources.remove(for: installed.id)
            availableUpdates[installed.id] = nil
            self.installed(installed)
        } catch {
            alert("Couldn’t install the plugin", error.message)
        }
    }

    private func installed(_ plugin: InstalledPlugin) {
        pluginsChanged()
        if let row = plugins.firstIndex(where: { $0.id == plugin.id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    @objc private func removeClicked() {
        guard plugins.indices.contains(table.selectedRow), let window = view.window else { return }
        let plugin = plugins[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = "Remove “\(plugin.name)”?"
        alert.informativeText = "The plugin is moved to the Trash."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try PluginStore.remove(plugin)
            } catch {
                DispatchQueue.main.async {
                    self.alert("Couldn’t remove the plugin", error.localizedDescription)
                }
                return
            }
            PluginHost.shared.reload()
            // A plugin installed again later starts enabled. A twin that still uses the
            // id keeps its switch.
            let gone = !PluginHost.shared.plugins.contains(where: { $0.id == plugin.id })
            if gone {
                PluginHost.shared.sources.remove(for: plugin.id)
                self.availableUpdates[plugin.id] = nil
            }
            if gone, self.model.preferences.disabledPlugins.remove(plugin.id) != nil {
                // Search takes the change with the preferences.
                self.model.persist()
            } else {
                self.model.onPluginsChanged?()
            }
            self.reload()
        }
    }

    @objc private func reloadClicked() {
        pluginsChanged()
    }

    @objc private func openFolderClicked() {
        let directory = PluginHost.shared.pluginsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func alert(_ message: String, _ detail: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { plugins.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: PluginRowView.reuseID, owner: self) as? PluginRowView
            ?? {
                let v = PluginRowView(frame: .zero)
                v.identifier = PluginRowView.reuseID
                return v
            }()
        let plugin = plugins[row]
        view.configure(with: plugin, enabled: !model.preferences.disabledPlugins.contains(plugin.id),
                       needsSetup: PluginHost.shared.needsSetup(plugin.id))
        view.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled { self.model.preferences.disabledPlugins.remove(plugin.id) }
            else { self.model.preferences.disabledPlugins.insert(plugin.id) }
            self.model.persist()
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }
}

/// One installed plugin: its switch, name and version, and what it does or why it
/// cannot be used.
private final class PluginRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("PluginRow")

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    var onEnabledChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.target = self
        checkbox.action = #selector(toggled)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for v in [checkbox, title, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with plugin: InstalledPlugin, enabled: Bool, needsSetup: Bool) {
        checkbox.state = enabled && plugin.isUsable ? .on : .off
        checkbox.isEnabled = plugin.isUsable
        checkbox.setAccessibilityLabel("Enable \(plugin.name)")

        let name = NSMutableAttributedString(string: plugin.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: plugin.isUsable && enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ])
        let extras = [plugin.manifest?.version.map { "v" + $0 }, plugin.manifest?.author]
            .compactMap { $0 }.joined(separator: " · ")
        if !extras.isEmpty {
            name.append(NSAttributedString(string: "  " + extras, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        title.attributedStringValue = name

        if let problem = plugin.problem {
            detail.stringValue = problem
            detail.textColor = .systemRed
        } else {
            let commands = plugin.manifest?.commands.map(\.title).joined(separator: ", ") ?? ""
            detail.stringValue = needsSetup ? "Setup required. Configure this plugin before using its commands."
                : plugin.manifest?.description ?? commands
            detail.textColor = .secondaryLabelColor
        }
        detail.toolTip = detail.stringValue
    }

    @objc private func toggled() {
        onEnabledChanged?(checkbox.state == .on)
    }
}
