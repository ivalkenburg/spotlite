import AppKit
import SpotliteCore

/// One sheet for installing from an address and for update checks: enter an address
/// or check sources, follow the download, then confirm what was found. Network and
/// disk work happen only between the user's clicks. Closing cancels preparation;
/// a confirmed installation finishes its atomic replacement and refreshes the host.
@MainActor
final class PluginInstallWindowController: NSWindowController {
    enum Start {
        case address
        /// An update, or any caller with a source in hand (a gallery, say).
        case source(PluginInstallSource)
        case checkUpdates([InstalledPlugin])
    }

    private let installer: PluginInstaller
    private var task: Task<Void, Never>?
    private var installing = false
    private var staged: StagedPlugin?
    private var checks: [PluginUpdateCheck] = []
    private var checkedPlugins: [InstalledPlugin] = []
    private let addressField = NSTextField(string: "")
    private let progress = NSProgressIndicator()
    /// The working page's status line, which download progress rewrites.
    private weak var status: NSTextField?
    /// The sheet then matches the Settings window.
    private let width: CGFloat = SettingsForm.width - 40
    /// After a successful install, with the installed plugin.
    var onInstalled: ((InstalledPlugin) -> Void)?
    /// After an update check, with every result.
    var onChecked: (([PluginUpdateCheck]) -> Void)?

    init(installer: PluginInstaller, start: Start) {
        self.installer = installer
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        addressField.widthAnchor.constraint(equalToConstant: width).isActive = true
        // Replacing the page ends editing, which must not start another download.
        addressField.cell?.sendsActionOnEndEditing = false
        progress.widthAnchor.constraint(equalToConstant: width).isActive = true
        switch start {
        case .address: showAddress(error: nil)
        case .source(let source): prepare(source)
        case .checkUpdates(let plugins): check(plugins)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Closing Settings with the sheet open must not leave a download running.
    deinit {
        task?.cancel()
        staged?.discard()
    }

    // MARK: - Pages

    private func showAddress(error: String?) {
        window?.title = "Install from URL"
        let hint = hint("A GitHub repository or folder (https://github.com/owner/repo, …/tree/<branch>/<folder>), an https .zip, or an https git address ending in .git.")
        addressField.placeholderString = "https://github.com/owner/repo"
        addressField.setAccessibilityLabel("Address")
        addressField.target = self
        addressField.action = #selector(continueClicked)
        var views: [NSView] = [title("Install from URL"), hint, addressField]
        if let error { views.append(self.hint(error, color: .systemRed, selectable: true)) }
        views.append(buttons([("Cancel", #selector(cancelClicked), "\u{1b}"), ("Continue", #selector(continueClicked), "\r")]))
        show(views, focus: addressField)
    }

    private func showWorking(_ text: String, allowsCancel: Bool = true) {
        progress.isIndeterminate = true
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.startAnimation(nil)
        let status = hint(text)
        self.status = status
        var views: [NSView] = [title(window?.title ?? "Install"), progress, status]
        if allowsCancel { views.append(buttons([("Cancel", #selector(cancelClicked), "\u{1b}")])) }
        show(views, focus: nil)
    }

    private func showConfirmation(_ staged: StagedPlugin) {
        let existing = installer.installed(id: staged.plugin.id)
        let verb: String
        switch existing.map({ PluginVersion.compare(installed: $0.manifest?.version, remote: staged.manifest.version) }) {
        case nil: verb = "Install"
        case .newer?, .different?: verb = "Update"
        case .same?, .older?: verb = "Reinstall"
        }
        window?.title = verb + " Plugin"
        let details = NSTextView.scrollableTextView()
        let text = details.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.textStorage?.setAttributedString(Self.attributed(staged.details(replacing: existing)))
        text.setAccessibilityIdentifier("installDetails")
        details.borderType = .bezelBorder
        details.translatesAutoresizingMaskIntoConstraints = false
        details.widthAnchor.constraint(equalToConstant: width).isActive = true
        details.heightAnchor.constraint(equalToConstant: 240).isActive = true

        var views: [NSView] = [title("\(verb) “\(staged.manifest.name)”?"), details]
        let linked = existing.map(PluginInstaller.isLinked) == true
        if linked {
            views.append(hint("The installed copy is a link to a folder elsewhere, usually a checkout under development. Spotlite won’t replace it: update that folder instead, or remove the link first.",
                              color: .systemRed))
        } else if existing != nil {
            views.append(hint("Its settings, secrets and data are kept."))
        }
        views.append(hint("Plugins run with your permissions when you use them. Install only plugins you trust.", color: .systemOrange))
        let row = buttons([("Cancel", #selector(cancelClicked), "\u{1b}"), (verb, #selector(installClicked), "\r")])
        (row.arrangedSubviews.last as? NSButton)?.isEnabled = !linked
        views.append(row)
        show(views, focus: nil)
    }

    private func showChecks() {
        window?.title = "Plugin Updates"
        var rows: [NSView] = []
        for (index, check) in checks.enumerated() {
            let name = checkedPlugins.first { $0.id == check.pluginID }?.name ?? check.pluginID
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            let installed = check.installedVersion ?? "no version"
            let state: NSTextField
            var update: NSButton?
            switch check.status {
            case .upToDate: state = hint("\(installed), up to date")
            case .available(let remote):
                state = hint("\(installed) → \(remote ?? "no version")", color: .labelColor)
                let button = NSButton(title: "Update…", target: self, action: #selector(updateClicked(_:)))
                button.bezelStyle = .rounded
                button.tag = index
                update = button
            case .installedIsNewer(let remote): state = hint("\(installed), newer than the source’s \(remote ?? "no version")")
            case .failed(let message): state = hint(message, color: .systemRed, selectable: true)
            }
            state.preferredMaxLayoutWidth = width - 120
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let line = SettingsForm.row([SettingsForm.column([label, state], spacing: 2), spacer] + (update.map { [$0] } ?? []))
            line.alignment = .centerY
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            rows.append(line)
        }
        if rows.isEmpty { rows.append(hint("No plugin was installed from an address, so there is nothing to check.")) }
        let available = checks.filter { if case .available = $0.status { true } else { false } }.count
        let failed = checks.filter { if case .failed = $0.status { true } else { false } }.count
        var summary = available == 0 ? "No updates available." : available == 1 ? "1 update available." : "\(available) updates available."
        if failed > 0 {
            summary = available == 0 ? "" : summary + " "
            summary += failed == 1 ? "1 update check failed." : "\(failed) update checks failed."
        }
        show([title("Plugin Updates"), hint(rows.count == checks.count && !checks.isEmpty ? summary : "")]
             + rows + [buttons([("Done", #selector(cancelClicked), "\r")])], focus: nil)
    }

    // MARK: - Work

    @objc private func continueClicked() {
        // Return in the field and the button both land here; one download at a time.
        guard task == nil, staged == nil else { return }
        let text = addressField.stringValue
        do {
            prepare(try PluginInstallSource.parse(text))
        } catch {
            showAddress(error: error.message)
        }
    }

    private func prepare(_ source: PluginInstallSource) {
        if window?.title.isEmpty != false { window?.title = "Install from URL" }
        showWorking("Connecting to \(Self.host(of: source))…")
        let installer = installer
        let report: @Sendable (PluginInstallProgress) -> Void = { [weak self] step in
            guard let self else { return }
            Task { @MainActor in self.progressed(step) }
        }
        task = Task { [weak self] in
            do throws(PluginInstallError) {
                let staged = try await installer.prepare(from: source, progress: report)
                guard let self, !Task.isCancelled else { return staged.discard() }
                self.task = nil
                self.staged = staged
                self.showConfirmation(staged)
            } catch {
                guard let self, error != .cancelled else { return }
                self.task = nil
                self.showAddress(error: error.message)
                self.addressField.stringValue = source.address
            }
        }
    }

    private func progressed(_ step: PluginInstallProgress) {
        guard task != nil, let status else { return }
        switch step {
        case .downloading(let received, let expected):
            let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            if let expected, expected > 0 {
                progress.isIndeterminate = false
                progress.doubleValue = Double(received) / Double(expected)
                status.stringValue = "Downloading… \(done) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
            } else {
                status.stringValue = "Downloading… \(done)"
            }
        case .cloning: status.stringValue = "Cloning with git…"
        case .extracting:
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            status.stringValue = "Checking the plugin…"
        }
    }

    @objc private func installClicked() {
        guard task == nil, let staged else { return }
        self.staged = nil
        installing = true
        showWorking("Installing…", allowsCancel: false)
        let installer = installer
        // Once confirmed, finish the atomic replacement and refresh the host even
        // if Settings closes while the background copy is in progress.
        task = Task { [self] in
            // A copy of up to the size limit: off the main thread.
            let result = await Task.detached { () -> Result<InstalledPlugin, PluginInstallError> in
                do throws(PluginInstallError) { return .success(try installer.install(staged)) } catch { return .failure(error) }
            }.value
            self.task = nil
            self.installing = false
            switch result {
            case .success(let plugin):
                self.onInstalled?(plugin)
                self.close(.OK)
            case .failure(let error):
                self.showAddress(error: error.message)
                self.addressField.stringValue = staged.source.address
            }
        }
    }

    private func check(_ plugins: [InstalledPlugin]) {
        window?.title = "Plugin Updates"
        checkedPlugins = plugins
        showWorking(plugins.count == 1 ? "Checking 1 plugin…" : "Checking \(plugins.count) plugins…")
        let installer = installer
        task = Task { [weak self] in
            let results = await withTaskGroup(of: (Int, PluginUpdateCheck).self) { group in
                for (index, plugin) in plugins.enumerated() {
                    group.addTask { (index, await installer.checkForUpdate(plugin)) }
                }
                var results: [(Int, PluginUpdateCheck)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.checks = results
            self.onChecked?(results)
            self.showChecks()
        }
    }

    @objc private func updateClicked(_ sender: NSButton) {
        guard checks.indices.contains(sender.tag),
              let source = installer.sources.load(for: checks[sender.tag].pluginID)?.source else { return }
        window?.title = "Update Plugin"
        prepare(source)
    }

    @objc private func cancelClicked() {
        guard !installing else { return }
        task?.cancel()
        task = nil
        staged?.discard()
        staged = nil
        close(.cancel)
    }

    private func close(_ code: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: code)
        window.orderOut(nil)
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

    private func buttons(_ specs: [(String, Selector, String)]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let views = specs.map { title, action, key -> NSButton in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.keyEquivalent = key
            return button
        }
        let row = SettingsForm.row([spacer] + views)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private static func attributed(_ rows: [(label: String, value: String)]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 96)]
        paragraph.headIndent = 96
        paragraph.paragraphSpacing = 4
        let text = NSMutableAttributedString()
        for (label, value) in rows {
            text.append(NSAttributedString(string: label + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph]))
            // Lines of a multi-line value stay in the value column.
            text.append(NSAttributedString(string: value.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        return text
    }

    private static func host(of source: PluginInstallSource) -> String {
        switch source {
        case .github: "GitHub"
        case .archive(let url), .git(let url, _): url.host ?? url.absoluteString
        }
    }
}
