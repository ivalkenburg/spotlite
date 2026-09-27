import AppKit
import SpotliteCore

/// Every app, System Settings pane, command and link, each with a visibility checkbox
/// and an alias field; plus adding, editing and removing links.
@MainActor
final class ItemsSettingsViewController: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate,
                                         NSMenuDelegate {
    private let table = NSTableView()
    private let filterField = NSSearchField()
    private let kindPicker = NSSegmentedControl(labels: ["All", "Apps", "Settings", "Commands", "Links"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private var allApps: [AppEntry] = []
    private var visibleApps: [AppEntry] = []

    /// Segment order of the kind picker. Nil shows every kind.
    private static let kinds: [EntryKind?] = [nil, .app, .settingsPane, .command, .link]
    private static let height: CGFloat = 560

    override func loadView() {
        kindPicker.selectedSegment = 0
        kindPicker.target = self
        kindPicker.action = #selector(filterChanged)

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

        let addLink = NSButton(title: "Add Link…", target: self, action: #selector(addLinkClicked))
        addLink.bezelStyle = .rounded
        addLink.toolTip = "A folder, file or web address to find by name, like an app"
        addLink.setContentHuggingPriority(.required, for: .horizontal)
        let filterRow = NSStackView(views: [filterField, addLink])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 8

        let caption = SettingsForm.hint(
            "Uncheck to hide from results, or give one a short alias. Right-click to forget its launch history, or to edit a link.")
        caption.preferredMaxLayoutWidth = SettingsForm.width - 40

        let stack = NSStackView(views: [kindPicker, filterRow, scroll, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for fullWidth in [kindPicker, filterRow, scroll, caption] as [NSView] {
            fullWidth.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        kindPicker.segmentDistribution = .fillEqually
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: SettingsForm.width),
            stack.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        view = stack
        reload()
    }

    func setApps(_ apps: [AppEntry]) {
        allApps = apps  // AppIndex returns them sorted by name already.
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        applyFilter()
        table.reloadData()
    }

    // MARK: - Filtering

    @objc private func filterChanged() {
        reload()
    }

    private var selectedKind: EntryKind? {
        Self.kinds.indices.contains(kindPicker.selectedSegment) ? Self.kinds[kindPicker.selectedSegment] : nil
    }

    private func applyFilter() {
        let query = filterField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let kind = selectedKind
        visibleApps = allApps.filter {
            (kind == nil || $0.kind == kind) && (query.isEmpty || $0.name.lowercased().contains(query))
        }
    }

    // MARK: - Links

    @objc private func addLinkClicked() {
        editLink(nil)
    }

    @objc private func editLinkClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let link = model.preferences.links.first(where: { $0.entryID == id }) else { return }
        editLink(link)
    }

    @objc private func removeLinkClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.preferences.links.removeAll { $0.entryID == id }
        // Nothing else will ever use these keys again.
        model.preferences.aliases.removeValue(forKey: id)
        model.preferences.hiddenBundleIDs.remove(id)
        model.library.forgetHistory(for: id)
        model.persist()
    }

    /// A sheet with the link's name, target and alias. An invalid entry reopens the sheet
    /// with what was typed and a line saying what is wrong, rather than losing the input.
    private func editLink(_ existing: Link?, draft: (name: String, target: String, alias: String)? = nil,
                          problem: String? = nil) {
        guard let window = view.window else { return }
        let alias = existing.flatMap { model.preferences.aliases[$0.entryID] } ?? ""
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
            ?? "A folder, file or web address, found by its name or alias like an app. "
            + "Put \(Link.placeholder) in it to type a search after pressing Tab."
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
        // A template's path depends on what is typed after Tab.
        if url.isFileURL, !target.contains(Link.placeholder), !FileManager.default.fileExists(atPath: url.path) {
            return "Nothing exists at \(url.path)."
        }
        return nil
    }

    private func saveLink(_ existing: Link?, name: String, target: String, alias: String) {
        var link = existing ?? Link(name: name, target: target)
        link.name = name
        link.target = target
        if let index = model.preferences.links.firstIndex(where: { $0.id == link.id }) {
            model.preferences.links[index] = link
        } else {
            model.preferences.links.append(link)
        }
        if alias.isEmpty { model.preferences.aliases.removeValue(forKey: link.entryID) }
        else { model.preferences.aliases[link.entryID] = alias }
        model.persist()
    }

    // MARK: - Row menu

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
        item.isEnabled = model.library.hasHistory(for: app.id)
        menu.addItem(item)
    }

    @objc private func forgetHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.library.forgetHistory(for: id)
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
            if hidden { self.model.preferences.hiddenBundleIDs.insert(id) }
            else { self.model.preferences.hiddenBundleIDs.remove(id) }
            self.model.persist()
            self.table.reloadData()
        }
        view.onAliasChanged = { [weak self] entry, alias in
            guard let self, let id = entry.bundleID else { return }
            let trimmed = alias.trimmingCharacters(in: .whitespaces)
            let existing = self.model.preferences.aliases[id] ?? ""
            guard trimmed != existing else { return }
            if trimmed.isEmpty { self.model.preferences.aliases.removeValue(forKey: id) }
            else { self.model.preferences.aliases[id] = trimmed }
            self.model.persist()
        }

        let hidden = app.bundleID.map { model.preferences.hiddenBundleIDs.contains($0) } ?? false
        let alias = app.bundleID.flatMap { model.preferences.aliases[$0] } ?? ""
        // The kind is already the filter's label everywhere but All.
        view.configure(with: app, hidden: hidden, alias: alias, showsKind: selectedKind == nil)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
