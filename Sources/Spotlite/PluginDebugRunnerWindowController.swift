import AppKit
import SpotliteCore

/// Runs one of a plugin's commands the way search would and shows what it wrote,
/// without applying the response. Exists only while the sheet is open.
@MainActor
final class PluginDebugRunnerWindowController: NSWindowController {
    private let plugin: InstalledPlugin
    private let host: PluginHost
    private let commands: [PluginCommand]
    private let commandPicker = NSPopUpButton()
    private let queryField = NSTextField(string: "")
    private let status = SettingsForm.hint("")
    private let output = PluginDebugRunnerWindowController.textView()
    private let errors = PluginDebugRunnerWindowController.textView()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private var run: PluginRun?
    /// Tells a late answer from a stopped run apart from the current one.
    private var generation = 0

    init(plugin: InstalledPlugin, host: PluginHost = .shared) {
        self.plugin = plugin
        self.host = host
        self.commands = (plugin.manifest?.commands ?? []).filter { PluginRunAction($0.action) != nil }
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Run \(plugin.name)"
        panel.isReleasedWhenClosed = false
        build()
        showReady()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Settings may close with the sheet still open; the run must not outlive it.
    deinit { run?.cancel() }

    private static func textView() -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return (scroll, text)
    }

    private func build() {
        let title = NSTextField(labelWithString: "Run \(plugin.name)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let hint = SettingsForm.hint("Runs a command as search would, with the same environment and settings. Nothing in the response is applied.")
        hint.preferredMaxLayoutWidth = 520

        for command in commands {
            let action = PluginRunAction(command.action)?.rawValue ?? ""
            commandPicker.addItem(withTitle: "\(command.title) (\(action))")
        }
        commandPicker.setAccessibilityLabel("Command")
        queryField.placeholderString = "SPOTLITE_QUERY, and the last argument of a search"
        queryField.setAccessibilityLabel("Query")
        queryField.target = self
        queryField.action = #selector(runClicked)
        queryField.cell?.sendsActionOnEndEditing = false
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Command:"), commandPicker],
            [NSTextField(labelWithString: "Query:"), queryField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        queryField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        status.preferredMaxLayoutWidth = 520
        status.isSelectable = true
        // The full error is in the record and the output below; keep the sheet's size steady.
        status.maximumNumberOfLines = 4
        status.cell?.truncatesLastVisibleLine = true
        status.identifier = NSUserInterfaceItemIdentifier("status")
        output.text.identifier = NSUserInterfaceItemIdentifier("stdout")
        output.text.setAccessibilityLabel("Standard output")
        errors.text.identifier = NSUserInterfaceItemIdentifier("stderr")
        errors.text.setAccessibilityLabel("Standard error")
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = SettingsForm.row([spacer, close, runButton])

        let content = SettingsForm.column([
            SettingsForm.column([title, hint], spacing: 6), grid, status,
            section("Standard output"), output.scroll,
            section("Standard error"), errors.scroll, buttons,
        ], spacing: 10)
        content.setCustomSpacing(16, after: content.arrangedSubviews[0])
        content.setCustomSpacing(4, after: content.arrangedSubviews[3])
        content.setCustomSpacing(4, after: content.arrangedSubviews[5])
        content.setCustomSpacing(16, after: errors.scroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 520),
            output.scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            output.scroll.heightAnchor.constraint(equalToConstant: 200),
            errors.scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            errors.scroll.heightAnchor.constraint(equalToConstant: 90),
            status.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        window?.contentView = root
        root.setFrameSize(root.fittingSize)
        window?.setContentSize(root.frame.size)
        window?.initialFirstResponder = queryField
    }

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Setup comes first: a run without valid settings would only report that.
    private func showReady() {
        if host.needsSetup(plugin.id) {
            show(status: "Setup required. Configure the plugin before running it.", failed: true)
            runButton.isEnabled = false
        } else if commands.isEmpty {
            show(status: "This plugin has no command that starts its executable.", failed: false)
            runButton.isEnabled = false
        } else {
            show(status: "", failed: false)
        }
    }

    private func show(status text: String, failed: Bool) {
        status.stringValue = text
        status.textColor = failed ? .systemRed : .secondaryLabelColor
        status.isHidden = text.isEmpty
    }

    @objc private func runClicked() {
        if run != nil { return stop() }
        guard commands.indices.contains(commandPicker.indexOfSelectedItem), !host.needsSetup(plugin.id) else { return }
        let command = commands[commandPicker.indexOfSelectedItem]
        generation &+= 1
        let current = generation
        output.text.string = ""
        errors.text.string = ""
        show(status: "Running…", failed: false)
        run = host.debugRun(plugin, command: command, query: queryField.stringValue) { [weak self] report in
            guard let self, self.generation == current else { return }
            self.run = nil
            self.runButton.title = "Run"
            self.show(report)
        }
        runButton.title = run == nil ? "Run" : "Stop"
    }

    private func stop() {
        generation &+= 1
        run?.cancel()
        run = nil
        runButton.title = "Run"
        show(status: "Stopped.", failed: false)
    }

    private func show(_ report: PluginRunReport) {
        let facts = [report.status.map { "exit \($0)" }, PluginDiagnostics.duration(report.duration)]
            .compactMap { $0 }.joined(separator: " · ")
        // A stream says how many rows it decoded and why lines were skipped.
        let streamed = report.stream.map { ([$0.text] + $0.errors).joined(separator: "\n") }
        switch report.result {
        case .success(let response):
            show(status: [facts + " · " + PluginDiagnostics.summary(of: response), streamed]
                .compactMap { $0 }.joined(separator: "\n"), failed: false)
        case .failure(let error):
            show(status: [facts + " · " + error.detail, streamed].compactMap { $0 }.joined(separator: "\n"), failed: true)
        }
        output.text.string = report.output.isEmpty ? "" : PluginDiagnostics.formatted(report.output)
        errors.text.string = report.errorText
    }

    @objc private func closeClicked() {
        stop()
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: .cancel)
        window.orderOut(nil)
    }
}
