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

        for v in [highlight, icon, label, detail] {
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
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: ResultItem, selected: Bool) {
        label.attributedStringValue = ResultRowView.attributed(item.title, bold: item.highlighted)
        detail.stringValue = item.detail ?? ""
        icon.image = item.icon
        highlight.isHidden = !selected
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
