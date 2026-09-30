import AppKit
import SpotliteCore

/// Indexed items and built-in utilities with visibility controls; indexed items also
/// support aliases. Links can be added, edited and removed.
@MainActor
final class ItemsSettingsViewController: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate,
                                         NSMenuDelegate {
    private let table = NSTableView()
    private let filterField = NSSearchField()
    private let caption = SettingsForm.hint("")
    private let kindPicker = NSSegmentedControl(labels: ["All", "Apps", "Settings", "Commands", "Links", "Utility"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private enum Item {
        case entry(AppEntry)
        case utility(SearchUtility)

        var name: String {
            switch self {
            case .entry(let entry): entry.name
            case .utility(let utility): utility.name
            }
        }
    }
    private static let utilityItems = SearchUtility.allCases.map(Item.utility).sorted(by: itemNameOrder)
    private var allItems: [Item] = ItemsSettingsViewController.utilityItems
    private var visibleItems: [Item] = []

    private nonisolated static func itemNameOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

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
        // Let longer labels such as Commands use more space than All.
        kindPicker.segmentDistribution = .fill
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: SettingsForm.width),
            stack.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        view = stack
        reload()
    }

    func setApps(_ apps: [AppEntry]) {
        allItems = (apps.map(Item.entry) + Self.utilityItems).sorted(by: Self.itemNameOrder)
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        caption.stringValue = showsUtilitiesOnly
            ? "Uncheck to hide from results. Hiding Caffeinate does not stop an active session."
            : "Uncheck to hide from results, or give an item a short alias. Right-click to forget launch history or edit a link."
        applyFilter()
        table.reloadData()
    }

    // MARK: - Filtering

    @objc private func filterChanged() {
        reload()
    }

    private var showsUtilitiesOnly: Bool { kindPicker.selectedSegment == Self.kinds.count }

    private var selectedKind: EntryKind? {
        Self.kinds.indices.contains(kindPicker.selectedSegment) ? Self.kinds[kindPicker.selectedSegment] : nil
    }

    private func applyFilter() {
        let query = filterField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let kind = selectedKind
        visibleItems = allItems.filter { item in
            guard query.isEmpty || item.name.lowercased().contains(query) else { return false }
            switch item {
            case .entry(let entry): return !showsUtilitiesOnly && (kind == nil || entry.kind == kind)
            case .utility: return showsUtilitiesOnly || kindPicker.selectedSegment == 0
            }
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
                      alias: AliasEditorField(string: draft?.alias ?? alias))
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
        let warning = SettingsForm.hint("", color: .systemOrange)
        warning.preferredMaxLayoutWidth = 320
        warning.widthAnchor.constraint(equalToConstant: 320).isActive = true
        warning.heightAnchor.constraint(equalToConstant: 42).isActive = true
        fields.alias.onEdit = { [weak self] alias in
            warning.stringValue = self?.model.aliasWarning(for: alias, excluding: existing?.entryID) ?? ""
            warning.toolTip = warning.stringValue
        }
        fields.alias.onEdit?(fields.alias.stringValue)
        let accessory = SettingsForm.column([grid, warning], spacing: 8)
        accessory.frame.size = accessory.fittingSize
        alert.accessoryView = accessory
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
        guard visibleItems.indices.contains(row), case .entry(let app) = visibleItems[row] else { return }
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

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: SettingsRowView.reuseID, owner: self) as? SettingsRowView
            ?? {
                let v = SettingsRowView(frame: .zero)
                v.identifier = SettingsRowView.reuseID
                return v
            }()

        view.onUtilityVisibilityChanged = nil
        if case .utility(let utility) = visibleItems[row] {
            view.onVisibilityChanged = nil
            view.onAliasEdited = nil
            view.onAliasChanged = nil
            view.onUtilityVisibilityChanged = { [weak self] utility, hidden in
                guard let self else { return }
                if hidden { self.model.preferences.hiddenUtilities.insert(utility) }
                else { self.model.preferences.hiddenUtilities.remove(utility) }
                self.model.persist()
                self.table.reloadData()
            }
            view.configure(with: utility, hidden: model.preferences.hiddenUtilities.contains(utility),
                           showsKind: kindPicker.selectedSegment == 0)
            return view
        }
        guard case .entry(let app) = visibleItems[row] else { return nil }
        view.onVisibilityChanged = { [weak self] entry, hidden in
            guard let self, let id = entry.bundleID else { return }
            if hidden { self.model.preferences.hiddenBundleIDs.insert(id) }
            else { self.model.preferences.hiddenBundleIDs.remove(id) }
            self.model.persist()
            self.table.reloadData()
        }
        view.onAliasEdited = { [weak self] entry, alias in
            self?.model.aliasWarning(for: alias, excluding: entry.id)
        }
        view.onAliasChanged = { [weak self] entry, alias in
            guard let self, let id = entry.bundleID else { return }
            let trimmed = alias.trimmingCharacters(in: .whitespaces)
            let existing = self.model.preferences.aliases[id] ?? ""
            guard trimmed != existing else { return }
            if trimmed.isEmpty { self.model.preferences.aliases.removeValue(forKey: id) }
            else { self.model.preferences.aliases[id] = trimmed }
            self.model.persist()
            self.reload()
        }

        let hidden = app.bundleID.map { model.preferences.hiddenBundleIDs.contains($0) } ?? false
        let alias = app.bundleID.flatMap { model.preferences.aliases[$0] } ?? ""
        // The kind is already the filter's label everywhere but All.
        view.configure(with: app, hidden: hidden, alias: alias, showsKind: selectedKind == nil,
                       warning: model.aliasWarning(for: alias, excluding: app.id))
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Local to the link editor: warnings update without blocking duplicate aliases.
@MainActor
private final class AliasEditorField: NSTextField, NSTextFieldDelegate {
    var onEdit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ notification: Notification) {
        onEdit?(stringValue)
    }
}
