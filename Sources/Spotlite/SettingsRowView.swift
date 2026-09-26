import AppKit
import SpotliteCore

/// One row of the Settings app list: visibility checkbox, icon, name, alias field.
@MainActor
final class SettingsRowView: NSView, NSTextFieldDelegate {
    static let reuseID = NSUserInterfaceItemIdentifier("SettingsRow")

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let aliasField = NSTextField()

    private var entry: AppEntry?
    private var pendingIconURL: URL?

    var onVisibilityChanged: ((AppEntry, Bool) -> Void)?
    var onAliasChanged: ((AppEntry, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.target = self
        checkbox.action = #selector(visibilityToggled)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        aliasField.placeholderString = "alias"
        aliasField.font = .systemFont(ofSize: 12)
        aliasField.alignment = .center
        aliasField.delegate = self

        let stack = NSStackView(views: [checkbox, iconView, label, aliasField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        // .fill, not the default gravity distribution: without it the stack sizes every
        // view to its intrinsic width and the alias fields end up ragged instead of
        // forming a column the eye can scan.
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            aliasField.widthAnchor.constraint(equalToConstant: 76),
        ])
        // Only the name may absorb slack. Everything else hugs its content, or the
        // stack hands the extra width to the checkbox and shunts the whole row right.
        for fixed in [checkbox, iconView, aliasField] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
        }
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: AppEntry, hidden: Bool, alias: String) {
        self.entry = entry
        checkbox.state = hidden ? .off : .on
        switch entry.kind {
        case .app: label.stringValue = entry.name
        case .settingsPane: label.stringValue = "\(entry.name) (System Settings)"
        case .command: label.stringValue = "\(entry.name) (Command)"
        case .link: label.stringValue = "\(entry.name) (Link)"
        }
        label.textColor = hidden ? .tertiaryLabelColor : .labelColor
        aliasField.stringValue = alias
        // Hiding and aliases are keyed by bundle ID. Without one the checkbox would
        // untick while the app stayed visible.
        checkbox.isEnabled = entry.bundleID != nil
        aliasField.isEnabled = entry.bundleID != nil

        // The same icons as the panel: a command's symbol, and for a web link the
        // browser it opens in.
        if entry.kind == .command {
            pendingIconURL = nil
            iconView.image = ResultItem.commandIcon(entry)
            return
        }
        guard let iconURL = entry.url.isFileURL ? entry.url : ResultItem.browserURL else {
            pendingIconURL = nil
            iconView.image = IconCache.placeholder
            return
        }
        if let ready = IconCache.shared.cached(for: iconURL) {
            pendingIconURL = nil
            iconView.image = ready
            return
        }
        pendingIconURL = iconURL
        iconView.image = IconCache.placeholder
        IconCache.shared.load(for: iconURL) { [weak self] loaded in
            guard let self, self.pendingIconURL == iconURL else { return }
            self.pendingIconURL = nil
            self.iconView.image = loaded
        }
    }

    @objc private func visibilityToggled() {
        guard let entry else { return }
        onVisibilityChanged?(entry, checkbox.state == .off)
    }

    /// Commit on blur and on return, so an alias typed and then dismissed isn't lost.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let entry else { return }
        onAliasChanged?(entry, aliasField.stringValue)
    }
}
