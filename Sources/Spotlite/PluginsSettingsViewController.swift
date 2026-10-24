import AppKit
import SpotliteCore

@MainActor
final class PluginsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: PluginManager
    private let table = NSTableView()
    private let filter = NSSearchField()
    private let detail = NSStackView()
    private let name = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let enable = NSButton(checkboxWithTitle: "Enable plugin", target: nil, action: nil)
    private let showCommands = NSButton(checkboxWithTitle: "Show commands in search", target: nil, action: nil)
    private let global = NSButton(checkboxWithTitle: "Include results in global search", target: nil, action: nil)
    private let configuration = NSStackView()
    private var form: PluginFormView?
    private var visible: [InstalledPlugin] = []
    private var selectedID: String?
    private var shownManifest: PluginManifest?
    private var busy = false
    private var configurationGeneration = 0
    private var operation: Task<Void, Never>?

    init(manager: PluginManager) { self.manager = manager; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        filter.placeholderString = "Filter plugins"
        filter.sendsSearchStringImmediately = true; filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(filterChanged)
        let add = NSButton(title: "Add Plugin…", target: self, action: #selector(addPlugin))
        add.bezelStyle = .rounded
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "More")
        for (title, selector) in [("Load Development Folder…", #selector(loadDevelopment)),
                                  ("Check for Update…", #selector(checkUpdate)),
                                  ("Roll Back…", #selector(rollback)),
                                  ("Reveal Package", #selector(revealPackage)),
                                  ("Retry Loading Plugins", #selector(retryLoad)),
                                  ("Uninstall…", #selector(uninstall))] {
            more.addItem(withTitle: title)
            more.lastItem?.target = self; more.lastItem?.action = selector
        }
        let filterRow = NSStackView(views: [filter, add, more])
        filterRow.spacing = 8
        for button in [add, more] as [NSView] { button.setContentHuggingPriority(.required, for: .horizontal) }

        table.headerView = nil; table.rowHeight = 34
        table.dataSource = self; table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin")))
        table.setAccessibilityLabel("Installed plugins")
        let list = NSScrollView()
        list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder

        name.font = .systemFont(ofSize: 15, weight: .semibold)
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 12)
        enable.target = self; enable.action = #selector(enableChanged)
        showCommands.target = self; showCommands.action = #selector(showCommandsChanged)
        global.target = self; global.action = #selector(globalChanged)
        let controls = NSStackView()
        controls.orientation = .horizontal; controls.spacing = 8
        for (title, selector) in [("Stop", #selector(stopPlugin)), ("Restart", #selector(restartPlugin)),
                                  ("Force Stop", #selector(forceStop)), ("View Log", #selector(viewLog))] {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded; button.controlSize = .small
            controls.addArrangedSubview(button)
        }
        configuration.orientation = .vertical; configuration.alignment = .leading; configuration.spacing = 12
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10
        for child in [name, descriptionLabel, state, enable, showCommands, global, controls, configuration] as [NSView] { detail.addArrangedSubview(child) }
        let document = FlippedView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detail)
        let details = NSScrollView()
        details.documentView = document; details.hasVerticalScroller = true; details.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: details.contentView.widthAnchor),
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            descriptionLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
            state.widthAnchor.constraint(equalTo: detail.widthAnchor),
            configuration.widthAnchor.constraint(equalTo: detail.widthAnchor)
        ])
        message.font = .systemFont(ofSize: 12)
        message.preferredMaxLayoutWidth = SettingsForm.width - 40
        let stack = NSStackView(views: [filterRow, list, details, message])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for child in [filterRow, list, details, message] as [NSView] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: SettingsForm.width),
            stack.heightAnchor.constraint(equalToConstant: 620),
            list.heightAnchor.constraint(equalToConstant: 150),
            details.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        view = stack
        NotificationCenter.default.addObserver(self, selector: #selector(managerChanged), name: .spotlitePluginsChanged, object: manager)
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let previous = selectedID
        visible = manager.plugins.filter { filter.stringValue.isEmpty || $0.manifest.name.localizedCaseInsensitiveContains(filter.stringValue) }
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.id == previous }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { selectedID = nil; detail.isHidden = true }
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        if manager.loadError != nil { showMessage(manager.loadError!, error: true) }
        else if !manager.isLoaded { showMessage("Loading plugins…") }
        else if visible.isEmpty { showMessage(manager.plugins.isEmpty ? "Add a plugin folder or ZIP to get started." : "No plugins match this filter.") }
        else if !busy { showMessage("Select a plugin to configure it or manage execution.") }
        updateState()
    }

    @objc private func managerChanged(_ notification: Notification) {
        if notification.userInfo?["commandsChanged"] as? Bool == true { reload() }
        else { table.reloadData(); updateState() }
    }
    @objc private func filterChanged() { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let plugin = visible[row]
        let title = NSTextField(labelWithString: plugin.manifest.name)
        let status = NSTextField(labelWithString: manager.status(plugin.id))
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.textColor = plugin.enabled ? .labelColor : .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = manager.failures[plugin.id] == nil ? .secondaryLabelColor : .systemRed
        status.setContentHuggingPriority(.required, for: .horizontal)
        let icon = NSImageView(image: ResultItem.symbol(plugin.manifest.icon ?? "puzzlepiece.extension") ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let cell = NSTableCellView()
        let stack = NSStackView(views: [icon, title, status])
        stack.spacing = 8; stack.distribution = .fill; stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard visible.indices.contains(table.selectedRow) else { return }
        let plugin = visible[table.selectedRow]
        guard plugin.id != selectedID || plugin.manifest != shownManifest else { updateState(); return }
        selectedID = plugin.id
        shownManifest = plugin.manifest
        detail.isHidden = false
        name.stringValue = plugin.manifest.name
        descriptionLabel.stringValue = [plugin.manifest.description, "Version \(plugin.manifest.version)" + (plugin.developmentPath == nil ? "" : " · Development folder")].compactMap { $0 }.joined(separator: "\n")
        configuration.arrangedSubviews.forEach { configuration.removeArrangedSubview($0); $0.removeFromSuperview() }
        form = nil
        configurationGeneration &+= 1
        let generation = configurationGeneration
        if !(plugin.manifest.settings ?? []).isEmpty {
            let loading = NSTextField(labelWithString: "Loading configuration…")
            loading.textColor = .secondaryLabelColor
            configuration.addArrangedSubview(loading)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let values = try await self.manager.host.settings(plugin)
                    guard self.selectedID == plugin.id, self.configurationGeneration == generation else { return }
                    loading.removeFromSuperview()
                    let form = PluginFormView(fields: plugin.manifest.settings ?? [], values: values)
                    self.form = form; self.configuration.addArrangedSubview(form)
                    form.onSubmit = { [weak self] in self?.saveConfiguration() }
                    form.widthAnchor.constraint(equalTo: self.configuration.widthAnchor).isActive = true
                    let save = NSButton(title: "Save Configuration", target: self, action: #selector(self.saveConfiguration))
                    save.bezelStyle = .rounded
                    self.configuration.addArrangedSubview(save)
                } catch { self.showMessage(error.localizedDescription, error: true) }
            }
        }
        updateState()
    }

    private var selected: InstalledPlugin? { manager.plugins.first { $0.id == selectedID } }
    private func updateState() {
        guard let selected else { return }
        enable.state = selected.enabled ? .on : .off
        showCommands.state = selected.showCommands ? .on : .off
        showCommands.isEnabled = !busy && selected.enabled
        global.state = selected.globalSearch ? .on : .off
        global.isHidden = !selected.manifest.commands.contains { $0.global == true }
        enable.isEnabled = !busy; global.isEnabled = !busy && selected.enabled
        state.stringValue = manager.failures[selected.id] ?? manager.status(selected.id)
        state.textColor = manager.failures[selected.id] == nil ? .secondaryLabelColor : .systemRed
    }
    private func showMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func perform(_ work: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        busy = true; updateState(); showMessage("Working…")
        operation = Task { [weak self] in
            guard let self else { return }
            do { self.showMessage(try await work()) }
            catch { self.showMessage(error.localizedDescription, error: true) }
            self.busy = false; self.operation = nil; self.updateState()
        }
    }
    @objc private func addPlugin() { choosePlugin(development: false) }
    @objc private func loadDevelopment() { choosePlugin(development: true) }
    private func choosePlugin(development: Bool) {
        guard !busy, let window = view.window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = !development
        picker.treatsFilePackagesAsDirectories = true; picker.allowsMultipleSelection = false
        picker.message = development ? "Choose a plugin folder to load directly. Restart reloads its source and manifest." : "Choose a .spotliteplugin folder, manifest.json, or plugin ZIP."
        picker.prompt = development ? "Load" : "Add"
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            self.perform { try await self.manager.install(url, development: development); return "Plugin added." }
        }
    }
    @objc private func enableChanged() {
        guard let selected else { return }
        let enabled = enable.state == .on
        perform { try await self.manager.setEnabled(selected.id, enabled); return enabled ? "Plugin enabled." : "Plugin disabled and stopped." }
    }
    @objc private func globalChanged() {
        guard let selected else { return }
        let enabled = global.state == .on
        perform { try await self.manager.setGlobalSearch(selected.id, enabled); return "Global search preference saved." }
    }
    @objc private func showCommandsChanged() {
        guard let selected else { return }
        let visible = showCommands.state == .on
        perform { try await self.manager.setShowCommands(selected.id, visible); return "Command visibility saved. Background work is unchanged." }
    }
    @objc private func stopPlugin() { if let selected { manager.stop(selected.id) } }
    @objc private func forceStop() { if let selected { manager.stop(selected.id, force: true) } }
    @objc private func restartPlugin() {
        guard let selected, selected.enabled else { return }
        perform { try await self.manager.restart(selected.id); return "Plugin restarted." }
    }
    @objc private func viewLog() {
        guard let selected else { return }
        if !NSWorkspace.shared.open(manager.logURL(selected.id)) { showMessage("This plugin has not written a log yet.") }
    }
    @objc private func revealPackage() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manager.store.packageURL(selected)])
    }
    @objc private func retryLoad() { manager.load() }
    @objc private func saveConfiguration() {
        guard let selected, let form else { return }
        do {
            let values = try form.values()
            perform { try await self.manager.host.saveSettings(selected, values: values); return "Configuration saved." }
        } catch { showMessage(error.localizedDescription, error: true) }
    }
    @objc private func checkUpdate() {
        guard let selected, let window = view.window else { return }
        guard selected.manifest.updateURL != nil else { showMessage("This plugin has no update URL. Import a replacement package to update it."); return }
        perform {
            guard let update = try await self.manager.checkUpdate(selected) else { return "\(selected.manifest.name) is up to date." }
            let alert = NSAlert()
            alert.messageText = "Update \(selected.manifest.name) to \(update.version)?"
            alert.informativeText = "The previous package will be available through Roll Back."
            alert.addButton(withTitle: "Update"); alert.addButton(withTitle: "Cancel")
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return "Update cancelled." }
            try await self.manager.applyUpdate(update, id: selected.id)
            return "Plugin updated to \(update.version)."
        }
    }
    @objc private func rollback() {
        guard let selected else { return }
        perform { try await self.manager.rollback(selected.id); return "Previous plugin version restored." }
    }
    @objc private func uninstall() {
        guard !busy, let selected, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(selected.manifest.name)?"
        alert.informativeText = "The plugin will stop and its installed package will be removed. Development source folders are preserved."
        let remove = NSButton(checkboxWithTitle: "Also remove plugin data, configuration and credentials", target: nil, action: nil)
        alert.accessoryView = remove
        alert.addButton(withTitle: "Uninstall"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.perform { try await self.manager.uninstall(selected.id, removeData: remove.state == .on); return "Plugin uninstalled." }
        }
    }
}
