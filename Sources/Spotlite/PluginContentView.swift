import AppKit
import SpotliteCore

/// Shared native fields for plugin preferences and in-panel forms.
@MainActor
final class PluginFormView: NSView, NSTextFieldDelegate {
    private let fields: [PluginField]
    private var controls: [String: NSControl] = [:]
    private let stack = NSStackView()
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    init(fields: [PluginField], values: [String: PluginValue]) {
        self.fields = fields
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for field in fields {
            let value = values[field.id] ?? field.defaultValue ?? .null
            let control: NSControl
            switch field.type {
            case "toggle":
                let checkbox = NSButton(checkboxWithTitle: field.title, target: nil, action: nil)
                checkbox.state = value.bool == true ? .on : .off
                control = checkbox
            case "select":
                let popup = NSPopUpButton()
                popup.addItems(withTitles: field.options ?? [])
                if let text = value.string { popup.selectItem(withTitle: text) }
                control = popup
            default:
                let text: NSTextField = field.type == "secret" ? NSSecureTextField() : NSTextField()
                text.stringValue = value.string ?? value.number.map { String($0) } ?? ""
                text.placeholderString = field.placeholder
                text.lineBreakMode = .byTruncatingTail
                text.delegate = self
                control = text
            }
            control.setAccessibilityLabel(field.title)
            controls[field.id] = control
            let group = NSStackView()
            group.orientation = .vertical; group.alignment = .leading; group.spacing = 4
            if field.type != "toggle" {
                let title = NSTextField(labelWithString: field.title + (field.required == true ? " *" : ""))
                title.font = .systemFont(ofSize: 13, weight: .medium)
                group.addArrangedSubview(title)
            }
            group.addArrangedSubview(control)
            if let description = field.description, !description.isEmpty {
                let hint = NSTextField(wrappingLabelWithString: description)
                hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
                hint.preferredMaxLayoutWidth = 400
                group.addArrangedSubview(hint)
                hint.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if field.type != "toggle" { control.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit { onSubmit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)), let onCancel { onCancel(); return true }
        return false
    }

    func values() throws -> [String: PluginValue] {
        var result: [String: PluginValue] = [:]
        for field in fields {
            guard let control = controls[field.id] else { continue }
            if let popup = control as? NSPopUpButton { result[field.id] = .string(popup.titleOfSelectedItem ?? "") }
            else if let checkbox = control as? NSButton { result[field.id] = .bool(checkbox.state == .on) }
            else {
                let text = control.stringValue
                if field.required == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    window?.makeFirstResponder(control)
                    throw PluginError.invalid("Enter \(field.title.lowercased()).")
                }
                if field.type == "number", !text.isEmpty {
                    guard let number = Double(text), number.isFinite else {
                        window?.makeFirstResponder(control)
                        throw PluginError.invalid("\(field.title) must be a number.")
                    }
                    result[field.id] = .number(number)
                } else { result[field.id] = .string(text) }
            }
        }
        return result
    }
    func focusFirstControl() -> Bool {
        for field in fields {
            if let control = controls[field.id], control.isEnabled, window?.makeFirstResponder(control) == true { return true }
        }
        return false
    }
}

@MainActor
final class PluginContentView: NSView {
    private let scroll = NSScrollView()
    private let actions = NSStackView()
    private let problem = NSTextField(wrappingLabelWithString: "")
    private var form: PluginFormView?
    private var pluginView: PluginView?
    var onAction: ((PluginAction, [String: PluginValue]) -> Void)?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        actions.orientation = .horizontal; actions.spacing = 8
        problem.textColor = .systemRed; problem.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [scroll, problem, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            problem.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ view: PluginView) {
        pluginView = view
        form = nil
        problem.isHidden = true
        actions.arrangedSubviews.forEach { actions.removeArrangedSubview($0); $0.removeFromSuperview() }
        if view.type == "form" {
            let form = PluginFormView(fields: view.fields ?? [], values: view.values ?? [:])
            self.form = form
            form.onSubmit = { [weak self] in self?.submit() }
            form.onCancel = { [weak self] in self?.onBack?() }
            form.translatesAutoresizingMaskIntoConstraints = false
            let document = FlippedView()
            document.addSubview(form)
            scroll.documentView = document
            NSLayoutConstraint.activate([
                form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
                form.topAnchor.constraint(equalTo: document.topAnchor),
                form.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            document.translatesAutoresizingMaskIntoConstraints = false
        } else {
            let text = NSTextView()
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.textContainerInset = NSSize(width: 0, height: 0)
            text.isHorizontallyResizable = false; text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            let source = view.markdown ?? ""
            let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let rich = NSMutableAttributedString(attributedString: parsed.map(NSAttributedString.init) ?? NSAttributedString(string: source))
            rich.addAttributes([.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: rich.length))
            text.textStorage?.setAttributedString(rich)
            scroll.documentView = text
        }
        for (index, action) in (view.actions ?? []).enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(actionClicked))
            button.bezelStyle = .rounded; button.tag = index
            if index == 0 { button.keyEquivalent = "\r" }
            actions.addArrangedSubview(button)
        }
        actions.isHidden = (view.actions ?? []).isEmpty
    }

    @objc private func actionClicked(_ sender: NSButton) { submit(index: sender.tag) }
    func submit(index: Int = 0) {
        guard let action = pluginView?.actions?[safe: index] else { return }
        do {
            let values = try form?.values() ?? [:]
            problem.isHidden = true
            onAction?(action, values)
        } catch { problem.stringValue = error.localizedDescription; problem.isHidden = false }
    }
    func showError(_ message: String) { problem.stringValue = message; problem.isHidden = false }
    func formValues() throws -> [String: PluginValue] { try form?.values() ?? [:] }
    func focusForm() -> Bool { form?.focusFirstControl() ?? false }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
