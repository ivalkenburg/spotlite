import AppKit
import SpotliteCore

/// One result row: icon, title with matched characters emboldened, optional right-hand
/// detail, and a tinted rounded rect for the selection cursor. Deliberately not
/// glass-on-glass — glass over glass reads as muddy.
final class ResultRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ResultRow")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private let stateSwitch = NSSwitch()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 10
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        highlight.isHidden = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: 17, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        detail.font = .systemFont(ofSize: 13, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        // At the narrowest width a long name and a deep path compete. The name is the
        // thing being chosen, so the path yields — from the head, because the tail
        // ("/Utilities") is what distinguishes it and "/System/Applica…" says nothing.
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        stateSwitch.controlSize = .mini
        stateSwitch.isHidden = true
        // The row owns the click; the switch only reports state.
        stateSwitch.isEnabled = false

        for v in [highlight, icon, label, detail, stateSwitch] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.listPadding),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.listPadding),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateSwitch.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                  constant: -Metrics.horizontalInset),
            stateSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Identifies which icon this reused row is currently waiting for, so a slow load
    /// that lands after the row has been recycled is discarded instead of showing the
    /// wrong app's icon.
    private var pendingIconURL: URL?

    func configure(with item: ResultItem, selected: Bool) {
        label.attributedStringValue = ResultRowView.attributed(item.title, bold: item.highlighted)
        detail.stringValue = item.detail(isSelected: selected) ?? ""
        highlight.isHidden = !selected

        if let state = item.switchState {
            stateSwitch.isHidden = false
            stateSwitch.state = state ? .on : .off
        } else {
            stateSwitch.isHidden = true
        }

        icon.layer?.removeAllAnimations()
        icon.alphaValue = 1

        if let ready = item.immediateIcon {
            pendingIconURL = nil
            icon.image = ready
            return
        }

        guard let url = item.iconURL else {
            pendingIconURL = nil
            icon.image = nil
            return
        }

        // Not cached: show the generic bundle icon now and fade the real one in, so the
        // row has stable geometry and the swap doesn't read as a flicker.
        pendingIconURL = url
        icon.image = IconCache.placeholder
        IconCache.shared.load(for: url) { [weak self] loaded in
            guard let self, self.pendingIconURL == url else { return }
            self.pendingIconURL = nil
            self.icon.image = loaded
            self.icon.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.icon.animator().alphaValue = 1
            }
        }
    }

    /// Emboldens exactly the characters the matcher consumed, so it's visible *why*
    /// a result ranked where it did.
    private static func attributed(_ title: String, bold: [Int]) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        guard !bold.isEmpty else { return base }

        let emphasis = NSFont.systemFont(ofSize: 17, weight: .bold)
        let characters = Array(title)
        for index in bold where index >= 0 && index < characters.count {
            // Character indices are not UTF-16 offsets; convert before ranging.
            let start = String(characters[0..<index]).utf16.count
            let length = String(characters[index]).utf16.count
            base.addAttribute(.font, value: emphasis, range: NSRange(location: start, length: length))
        }
        return base
    }
}
