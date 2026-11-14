import AppKit
import SpotliteCore

/// The plugin gallery: reads the index when opened, lists it with each plugin's status,
/// and hands Install and Update to the install sheet, whose confirmation shows the
/// manifest and the trust warning. Nothing is fetched until the sheet opens, and
/// nothing after it closes.
@MainActor
final class PluginGalleryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let fetch: @Sendable () async throws(PluginInstallError) -> PluginGalleryIndex
    private let installedPlugins: () -> [InstalledPlugin]
    private var index: PluginGalleryIndex?
    private var shown: [PluginGalleryEntry] = []
    private var installed: [InstalledPlugin] = []
    private var task: Task<Void, Never>?
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = SettingsForm.hint("")
    private let progress = NSProgressIndicator()
    private let width: CGFloat = SettingsForm.width - 40
    /// With every index read, so Settings can keep the last one while it is open.
    var onFetched: ((PluginGalleryIndex) -> Void)?
    /// Install or Update clicked: show the install sheet for the entry's source.
    var onInstall: ((PluginGalleryEntry) -> Void)?

    /// `cached` is an index read earlier while Settings stayed open; nil reads it now.
    init(cached: PluginGalleryIndex?, installed: @escaping () -> [InstalledPlugin],
         fetch: @escaping @Sendable () async throws(PluginInstallError) -> PluginGalleryIndex) {
        self.fetch = fetch
        self.installedPlugins = installed
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.title = "Plugin Gallery"
        configureTable()
        progress.widthAnchor.constraint(equalToConstant: width).isActive = true
        searchField.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let cached {
            index = cached
            showList()
        } else {
            load()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    /// After an install: statuses follow what is installed now.
    func refreshStatus() {
        installed = installedPlugins()
        table.reloadData()
    }

    // MARK: - Pages

    private func load() {
        task?.cancel()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        show([title("Plugin Gallery"), progress, hint("Loading the gallery…"),
              buttons([("Cancel", #selector(doneClicked), "\u{1b}")])], focus: nil)
        let fetch = fetch
        task = Task { [weak self] in
            let result: Result<PluginGalleryIndex, PluginInstallError>
            do throws(PluginInstallError) { result = .success(try await fetch()) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            switch result {
            case .success(let index):
                self.index = index
                self.onFetched?(index)
                self.showList()
            case .failure(.cancelled): break
            case .failure(let error): self.showError(error.message)
            }
        }
    }

    private func showError(_ message: String) {
        let error = hint(message, color: .systemRed, selectable: true)
        error.setAccessibilityIdentifier("galleryError")
        show([title("Couldn’t Load the Gallery"), error,
              buttons([("Close", #selector(doneClicked), "\u{1b}"), ("Retry", #selector(retryClicked), "\r")])], focus: nil)
    }

    private func showList() {
        installed = installedPlugins()
        searchField.placeholderString = "Search plugins"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search plugins")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.preferredMaxLayoutWidth = width - 40
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let warning = hint("Plugins are third-party code that runs with your permissions when you use it. The gallery only lists them: Spotlite doesn’t review or vet plugins. Install only ones you trust.",
                           color: .systemOrange)
        warning.setAccessibilityIdentifier("galleryWarning")
        var footer = "To list a plugin here, open a pull request that adds it to plugins/index.json in the Spotlite repository."
        if let skipped = index?.skipped, skipped > 0 {
            footer = (skipped == 1 ? "1 entry was skipped as invalid. " : "\(skipped) entries were skipped as invalid. ") + footer
        }
        let row = buttons([("Done", #selector(doneClicked), "\r")], leading: [("Refresh", #selector(retryClicked))])
        show([title("Plugin Gallery"), warning, searchField, scroll, hint(footer), row], focus: searchField)
        filter()
    }

    private func filter() {
        shown = PluginGallery.search(index?.entries ?? [], query: searchField.stringValue)
        table.reloadData()
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue = index?.entries.isEmpty != false ? "The gallery lists no plugins yet."
            : "No plugins match “\(searchField.stringValue)”."
    }

    // MARK: - Actions

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        filter()
    }

    @objc private func retryClicked() {
        guard task == nil else { return }
        load()
    }

    @objc private func doneClicked() {
        task?.cancel()
        task = nil
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: .OK)
        window.orderOut(nil)
    }

    private func installClicked(_ entry: PluginGalleryEntry) {
        onInstall?(entry)
    }

    // MARK: - Table

    private func configureTable() {
        table.headerView = nil
        table.rowHeight = 62
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.setAccessibilityLabel("Gallery plugins")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: GalleryRowView.reuseID, owner: self) as? GalleryRowView
            ?? {
                let v = GalleryRowView(frame: .zero)
                v.identifier = GalleryRowView.reuseID
                return v
            }()
        let entry = shown[row]
        view.configure(with: entry, status: PluginGallery.status(of: entry, installed: installed))
        view.onAction = { [weak self] in self?.installClicked(entry) }
        return view
    }

    // MARK: - Building

    private func show(_ views: [NSView], focus: NSView?) {
        let content = SettingsForm.column(views, spacing: 10)
        content.setCustomSpacing(12, after: views[0])
        if views.count > 2 { content.setCustomSpacing(18, after: views[views.count - 2]) }
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        window?.contentView = root
        root.layoutSubtreeIfNeeded()
        window?.setContentSize(root.fittingSize)
        window?.initialFirstResponder = focus
        if let focus { window?.makeFirstResponder(focus) }
    }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return label
    }

    private func hint(_ text: String, color: NSColor = .secondaryLabelColor, selectable: Bool = false) -> NSTextField {
        let label = SettingsForm.hint(text, color: color)
        label.preferredMaxLayoutWidth = width
        label.isSelectable = selectable
        return label
    }

    private func buttons(_ specs: [(String, Selector, String)], leading: [(String, Selector)] = []) -> NSStackView {
        func make(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = specs.map { title, action, key -> NSButton in
            let button = make(title, action)
            button.keyEquivalent = key
            return button
        }
        let row = SettingsForm.row(leading.map(make) + [spacer] + trailing)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
}

/// One gallery entry: icon, name, version and author, description, tags, and its
/// Install, Update or Installed state.
private final class GalleryRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("GalleryRow")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let tags = NSTextField(labelWithString: "")
    private let action = NSButton(title: "", target: nil, action: nil)
    private let homepage = NSButton()
    private var homepageURL: URL?
    var onAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        tags.font = .systemFont(ofSize: 10)
        tags.textColor = .tertiaryLabelColor
        tags.lineBreakMode = .byTruncatingTail
        for label in [title, detail, tags] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.target = self
        action.action = #selector(actionClicked)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)
        homepage.isBordered = false
        homepage.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Homepage")
        homepage.contentTintColor = .secondaryLabelColor
        homepage.target = self
        homepage.action = #selector(homepageClicked)
        for v in [icon, title, detail, tags, action, homepage] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            homepage.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 4),
            homepage.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            homepage.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            tags.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            tags.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),
            tags.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: PluginGalleryEntry, status: PluginGalleryStatus) {
        let symbol = entry.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.image = symbol ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        let name = NSMutableAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        name.append(NSAttributedString(string: "  v\(entry.version) · \(entry.author)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        title.attributedStringValue = name
        detail.stringValue = entry.description
        detail.toolTip = entry.description
        tags.stringValue = entry.tags.joined(separator: " · ")
        tags.isHidden = entry.tags.isEmpty
        homepageURL = entry.homepage
        homepage.isHidden = entry.homepage == nil
        homepage.toolTip = entry.homepage?.absoluteString
        switch status {
        case .notInstalled:
            action.title = "Install…"
            action.isEnabled = true
            action.toolTip = "Download and review “\(entry.name)” before installing it"
        case .updateAvailable(let installed):
            action.title = "Update…"
            action.isEnabled = true
            action.toolTip = "Installed: \(installed ?? "no version"). Review \(entry.version) before updating."
        case .installed(let version):
            action.title = "Installed"
            action.isEnabled = false
            action.toolTip = "Version \(version ?? "unknown") is installed"
        }
        action.setAccessibilityIdentifier("gallery-" + entry.id)
        setAccessibilityLabel("\(entry.name), \(action.title)")
    }

    @objc private func actionClicked() { onAction?() }

    @objc private func homepageClicked() {
        guard let homepageURL, homepageURL.scheme == "https" else { return }
        NSWorkspace.shared.open(homepageURL)
    }
}
