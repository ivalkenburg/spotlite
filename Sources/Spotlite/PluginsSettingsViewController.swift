import AppKit
import SpotliteCore

/// Installed plugins: switch one off, install from a folder, remove, or reload after
/// editing one. A plugin that cannot be used is listed with the reason.
@MainActor
final class PluginsSettingsViewController: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let configureButton = NSButton(title: "Configure…", target: nil, action: nil)
    private let runButton = NSButton(title: "Run…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let dataButton = NSButton(title: "Open Data Folder", target: nil, action: nil)
    private let emptyLabel = SettingsForm.hint("No plugins installed.")
    private let lastRunTitle = NSTextField(labelWithString: "Last run")
    private let lastRun = NSTextView.scrollableTextView()
    private var plugins: [InstalledPlugin] = []
    private var configurationController: PluginConfigurationWindowController?
    private var runnerController: PluginDebugRunnerWindowController?

    private static let height: CGFloat = 560

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

        let install = button("Install…", #selector(installClicked))
        install.toolTip = "Choose a folder that contains a plugin.json"
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.bezelStyle = .rounded
        configureButton.target = self
        configureButton.action = #selector(configureClicked)
        configureButton.bezelStyle = .rounded
        for (control, action) in [(runButton, #selector(runClicked)), (revealButton, #selector(revealClicked)),
                                  (dataButton, #selector(openDataClicked))] {
            control.target = self
            control.action = action
            control.bezelStyle = .rounded
        }
        runButton.toolTip = "Run a command and see its raw output, without applying it"
        revealButton.toolTip = "Show the plugin’s folder in Finder"
        dataButton.toolTip = "Open the folder where the plugin keeps its own data"
        let reloadButton = button("Reload", #selector(reloadClicked))
        reloadButton.toolTip = "Read every plugin again, after editing one"
        let folder = button("Open Folder", #selector(openFolderClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [install, removeButton, spacer, runButton, configureButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let utilitySpacer = NSView()
        utilitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let utilities = NSStackView(views: [reloadButton, folder, utilitySpacer, revealButton, dataButton])
        utilities.orientation = .horizontal
        utilities.spacing = 8

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
        lastRun.heightAnchor.constraint(equalToConstant: 110).isActive = true
        // A run that finishes while Settings is open shows without polling.
        PluginHost.shared.onRunRecorded = { [weak self] id in self?.runRecorded(id) }

        let caption = SettingsForm.hint(
            "Plugins add commands to search. A plugin is a program that runs with your permissions when you use it: install only ones you trust.")
        caption.preferredMaxLayoutWidth = SettingsForm.width - 40

        let stack = NSStackView(views: [scroll, buttons, utilities, lastRunTitle, lastRun, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(14, after: utilities)
        stack.setCustomSpacing(4, after: lastRunTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for fullWidth in [scroll, buttons, utilities, lastRunTitle, lastRun, caption] as [NSView] {
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

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// Shows what the host has now. The host itself is read again only on request.
    func reload() {
        guard isViewLoaded else { return }
        plugins = PluginHost.shared.plugins
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
        configureButton.isEnabled = selected?.isUsable == true && selected?.manifest?.settings.isEmpty == false
        runButton.isEnabled = selected?.isUsable == true
            && selected?.manifest?.commands.contains { PluginRunAction($0.action) != nil } == true
        revealButton.isEnabled = selected != nil
        dataButton.isEnabled = selected?.isUsable == true
        showLastRun()
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
        guard let window = view.window, configurationController == nil, runnerController == nil,
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
        guard let window = view.window, runnerController == nil, configurationController == nil,
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
            pluginsChanged()
            if let row = plugins.firstIndex(where: { $0.id == installed.id }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } catch {
            alert("Couldn’t install the plugin", error.message)
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
            if !PluginHost.shared.plugins.contains(where: { $0.id == plugin.id }),
               self.model.preferences.disabledPlugins.remove(plugin.id) != nil {
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
