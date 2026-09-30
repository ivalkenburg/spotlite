import AppKit
import SpotliteCore

/// A bounded list: adding locations never makes Settings grow off screen.
@MainActor
final class ApplicationDirectoriesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let model: SettingsModel
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    init(model: SettingsModel) {
        self.model = model
        super.init(frame: .zero)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let add = NSButton(title: "Add…", target: self, action: #selector(addDirectory))
        removeButton.target = self
        removeButton.action = #selector(removeDirectory)
        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetDirectories))
        for button in [add, removeButton, reset] { button.bezelStyle = .rounded }
        let controls = SettingsForm.row([add, removeButton, reset], spacing: 6)
        let stack = SettingsForm.column([
            scroll, controls,
            SettingsForm.hint("Apps in these folders and one level of subfolders are searched."),
        ], spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 280),
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        table.reloadData()
        removeButton.isEnabled = model.preferences.applicationDirectories.indices.contains(table.selectedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.preferences.applicationDirectories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = model.preferences.applicationDirectories[row]
        let label = NSTextField(labelWithString: path)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = path
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = model.preferences.applicationDirectories.indices.contains(table.selectedRow)
    }

    @objc private func addDirectory() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.prompt = "Add"
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let paths = self.model.preferences.applicationDirectories + picker.urls.map(\.path)
            self.model.set(\.applicationDirectories, AppIndex.normalizedDirectories(paths).map(\.path))
            self.reload()
        }
    }

    @objc private func removeDirectory() {
        guard model.preferences.applicationDirectories.indices.contains(table.selectedRow) else { return }
        var paths = model.preferences.applicationDirectories
        paths.remove(at: table.selectedRow)
        model.set(\.applicationDirectories, paths)
        reload()
    }

    @objc private func resetDirectories() {
        model.set(\.applicationDirectories, AppIndex.searchDirectories.map(\.path))
        reload()
    }
}
