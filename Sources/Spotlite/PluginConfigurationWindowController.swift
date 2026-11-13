import AppKit
import SpotliteCore

/// A transactional editor: scripts never participate in constructing or validating it.
@MainActor
final class PluginConfigurationWindowController: NSWindowController, NSTextFieldDelegate {
    private let plugin: InstalledPlugin
    private let host: PluginHost
    private let settings: [PluginSetting]
    private var controls: [String: NSControl] = [:]
    private var errors: [String: NSTextField] = [:]
    /// Preserve incompatible saved types until the user edits that particular field.
    private var incompatible: [String: PluginSettingValue] = [:]
    private let summary = SettingsForm.hint("", color: .systemRed)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    var onChange: (() -> Void)?

    init(plugin: InstalledPlugin, host: PluginHost = .shared) {
        self.plugin = plugin
        self.host = host
        self.settings = plugin.manifest?.settings ?? []
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Configure \(plugin.name)"
        panel.isReleasedWhenClosed = false
        buildForm()
        readConfiguration()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildForm() {
        let title = NSTextField(labelWithString: "Configure \(plugin.name)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let hint = SettingsForm.hint("Changes apply the next time you use this plugin.")
        hint.preferredMaxLayoutWidth = 440
        let header = SettingsForm.column([title, hint], spacing: 6)

        var rows: [(String, NSView)] = []
        for setting in settings {
            let control: NSControl
            switch setting.type {
            case .text, .number:
                let input = ConfigurationTextField(string: "")
                input.delegate = self
                input.placeholderString = setting.initialValue?.text ?? (setting.required ? "Required" : "Optional")
                control = input
            case .boolean:
                control = ConfigurationCheckbox(checkboxWithTitle: "", target: self, action: #selector(fieldChanged))
            case .choice:
                let picker = ConfigurationChoice()
                let menu = NSMenu()
                menu.autoenablesItems = false
                picker.menu = menu
                if setting.defaultValue == nil {
                    menu.addItem(NSMenuItem(title: setting.required ? "Choose…" : "None", action: nil, keyEquivalent: ""))
                }
                for option in setting.options {
                    let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
                    item.representedObject = option.value
                    menu.addItem(item)
                }
                control = picker
            }
            control.identifier = NSUserInterfaceItemIdentifier(setting.id)
            control.target = self
            control.action = control is NSTextField ? #selector(saveClicked) : #selector(fieldChanged)
            control.setAccessibilityLabel(setting.label + (setting.required ? ", required" : ""))
            control.setAccessibilityHelp(setting.description)
            if setting.type != .boolean { control.widthAnchor.constraint(equalToConstant: 260).isActive = true }
            controls[setting.id] = control
            let error = SettingsForm.hint("", color: .systemRed)
            error.preferredMaxLayoutWidth = 260
            error.widthAnchor.constraint(equalToConstant: 260).isActive = true
            errors[setting.id] = error
            var views: [NSView] = [control]
            if let description = setting.description, !description.isEmpty {
                let hint = SettingsForm.hint(description)
                hint.preferredMaxLayoutWidth = 260
                hint.widthAnchor.constraint(equalToConstant: 260).isActive = true
                views.append(hint)
            }
            views.append(error)
            rows.append((setting.label + (setting.required ? " (required)" : ""), SettingsForm.column(views)))
        }

        let grid = NSGridView(views: rows.map { title, control in
            let label = NSTextField(wrappingLabelWithString: title)
            label.alignment = .right
            label.preferredMaxLayoutWidth = 140
            label.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return [label, control]
        })
        grid.rowSpacing = 16
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])

        let reset = NSButton(title: "Reset Settings…", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = SettingsForm.row([reset, spacer, cancel, saveButton])
        summary.preferredMaxLayoutWidth = 440
        let content = SettingsForm.column([header, scroll, summary, buttons], spacing: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
            summary.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        window?.contentView = root
        // A bounded, scrolling form also accommodates long descriptions and many fields.
        grid.layoutSubtreeIfNeeded()
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 220
        scroll.heightAnchor.constraint(equalToConstant: min(max(grid.fittingSize.height + 8, 100), min(420, max(100, available)))).isActive = true
        root.setFrameSize(NSSize(width: max(480, grid.fittingSize.width + 52), height: root.fittingSize.height))
        window?.setContentSize(root.frame.size)
        window?.initialFirstResponder = settings.compactMap { controls[$0.id] }.first
    }

    private func readConfiguration() {
        let configuration = host.configuration(for: plugin)
        incompatible = [:]
        for setting in settings {
            let value = configuration.values[setting.id]
            let control = controls[setting.id]!
            switch control {
            case let input as NSTextField: input.stringValue = value?.text ?? ""
            case let picker as NSPopUpButton:
                for item in picker.itemArray where item.tag == -1 { picker.menu?.removeItem(item) }
                let index = picker.itemArray.firstIndex { ($0.representedObject as? String).map(PluginSettingValue.string) == value }
                if let value, index == nil {
                    let unavailable = NSMenuItem(title: "Unavailable: \(value.text.prefix(64))", action: nil, keyEquivalent: "")
                    unavailable.tag = -1
                    unavailable.isEnabled = false
                    picker.menu?.insertItem(unavailable, at: 0)
                }
                picker.selectItem(at: index ?? 0)
            case let toggle as NSButton:
                let invalid = setting.validationError(for: value) != nil
                toggle.allowsMixedState = invalid
                toggle.state = invalid ? .mixed : (value == .boolean(true) ? .on : .off)
            default: break
            }
            if let value, setting.validationError(for: value) != nil { incompatible[setting.id] = value }
        }
        summary.stringValue = configuration.problem.map { $0 + " Save valid settings to replace them, or reset settings." } ?? ""
        summary.isHidden = summary.stringValue.isEmpty
        validate()
    }

    private func draft() -> PluginConfiguration {
        var values = incompatible
        for setting in settings where incompatible[setting.id] == nil {
            switch controls[setting.id] {
            case let input as NSTextField:
                let text = input.stringValue
                if setting.type == .number {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        values[setting.id] = Double(trimmed).flatMap { $0.isFinite ? .number($0) : nil } ?? .string(text)
                    }
                } else { values[setting.id] = .string(text) }
            case let picker as NSPopUpButton:
                values[setting.id] = (picker.selectedItem?.representedObject as? String).map(PluginSettingValue.string)
            case let toggle as NSButton: values[setting.id] = .boolean(toggle.state == .on)
            default: break
            }
        }
        return PluginConfiguration(settings: settings, saved: values)
    }

    private func validate() {
        let configuration = draft()
        for setting in settings {
            errors[setting.id]?.stringValue = configuration.errors[setting.id] ?? ""
            errors[setting.id]?.isHidden = configuration.errors[setting.id] == nil
            controls[setting.id]?.setAccessibilityHelp([setting.description, configuration.errors[setting.id]]
                .compactMap { $0 }.joined(separator: " "))
        }
        saveButton.isEnabled = configuration.isValid
    }

    @objc private func fieldChanged(_ sender: NSControl) {
        if let id = sender.identifier?.rawValue { incompatible[id] = nil }
        if let toggle = sender as? NSButton, !(toggle is NSPopUpButton) { toggle.allowsMixedState = false }
        validate()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let control = obj.object as? NSControl { fieldChanged(control) }
    }

    @objc private func saveClicked() {
        let configuration = draft()
        validate()
        guard configuration.isValid else { return }
        do {
            try host.saveConfiguration(configuration.values, for: plugin)
            onChange?()
            endSheet(.OK)
        } catch { showError(error) }
    }

    @objc private func cancelClicked() { endSheet(.cancel) }

    private func endSheet(_ response: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: response)
        window.orderOut(nil)
    }

    @objc private func resetClicked() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset settings for “\(plugin.name)”?"
        alert.informativeText = "Saved values will be removed. Required fields without defaults will need setup again."
        alert.addButton(withTitle: "Reset Settings")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.host.resetConfiguration(for: self.plugin)
                self.readConfiguration()
                self.onChange?()
            } catch { self.showError(error) }
        }
    }

    private func showError(_ error: Error) {
        summary.stringValue = "Couldn’t save plugin settings: \(error.localizedDescription)"
        summary.isHidden = false
    }
}

/// AppKit's field editor can take focus outside a nested scrolling grid without
/// revealing its control. Scroll only when keyboard focus moves, never on a timer.
private final class ConfigurationTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        _ = scrollToVisible(bounds.insetBy(dx: 0, dy: -4))
        return super.becomeFirstResponder()
    }
}

private final class ConfigurationCheckbox: NSButton {
    override func becomeFirstResponder() -> Bool {
        _ = scrollToVisible(bounds.insetBy(dx: 0, dy: -4))
        return super.becomeFirstResponder()
    }
}

private final class ConfigurationChoice: NSPopUpButton {
    override func becomeFirstResponder() -> Bool {
        _ = scrollToVisible(bounds.insetBy(dx: 0, dy: -4))
        return super.becomeFirstResponder()
    }
}
