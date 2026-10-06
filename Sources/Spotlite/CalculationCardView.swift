import AppKit
import SpotliteCore

/// The calculator result as Spotlight draws it: a bordered card holding the expression
/// and its value, a round copy button, and a separator between it and the rows below.
///
/// Top-hit selection uses the completion pill. Arrow navigation adds an accent ring.
final class CalculationCardView: HoverResultCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("CalculationCard")

    private let card = NSView()
    private let border = NSView()
    private let expression = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let copyCircle = NSView()
    private let copyGlyph = NSImageView()
    private let separator = NSView()

    private var lastConfiguration: (expression: String, value: String, selection: RowSelection,
                                    showsSeparator: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for v in [card, border, copyCircle] {
            v.wantsLayer = true
            v.layer?.cornerCurve = .continuous
        }
        card.layer?.cornerRadius = Metrics.cardRadius
        border.layer?.cornerRadius = Metrics.cardRadius
        copyCircle.layer?.cornerRadius = Metrics.copyButtonSize / 2

        expression.font = .systemFont(ofSize: 13, weight: .regular)
        expression.wantsLayer = true
        value.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
        value.textColor = .labelColor
        value.lineBreakMode = .byTruncatingTail
        expression.lineBreakMode = .byTruncatingTail

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyGlyph.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(config)
        copyGlyph.contentTintColor = .labelColor

        for v in [card, border, expression, value, copyCircle, copyGlyph, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.cardInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.cardInset),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.heightAnchor.constraint(equalToConstant: Metrics.cardHeight),

            border.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            border.topAnchor.constraint(equalTo: card.topAnchor),
            border.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            expression.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardTextInset),
            expression.firstBaselineAnchor.constraint(equalTo: card.topAnchor,
                                                      constant: Metrics.cardExpressionBaseline),
            expression.trailingAnchor.constraint(lessThanOrEqualTo: copyCircle.leadingAnchor, constant: -8),
            value.leadingAnchor.constraint(equalTo: expression.leadingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardValueBaseline),
            value.trailingAnchor.constraint(lessThanOrEqualTo: copyCircle.leadingAnchor, constant: -8),

            copyCircle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.copyButtonInset),
            copyCircle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            copyCircle.widthAnchor.constraint(equalToConstant: Metrics.copyButtonSize),
            copyCircle.heightAnchor.constraint(equalToConstant: Metrics.copyButtonSize),
            copyGlyph.centerXAnchor.constraint(equalTo: copyCircle.centerXAnchor),
            copyGlyph.centerYAnchor.constraint(equalTo: copyCircle.centerYAnchor),

            // Runs from the usual inset all the way to the panel's right edge, as
            // Spotlight's does.
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: card.bottomAnchor, constant: Metrics.cardSeparatorGap),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let last = lastConfiguration else { return }
        configure(expression: last.expression, value: last.value, selection: last.selection,
                  showsSeparator: last.showsSeparator)
    }

    var hasValidGeometry: Bool {
        let valueAlignment = value.alignmentRect(forFrame: value.frame)
        let copyAlignment = copyCircle.alignmentRect(forFrame: copyCircle.frame)
        return bounds.contains(card.frame)
            && card.frame.contains(expression.frame) && card.frame.contains(value.frame)
            && valueAlignment.maxX <= copyAlignment.minX - 8 + 0.01
    }

    func dumpFrames(_ tag: String) {
        print("[\(tag)] card=\(card.frame) expression=\(expression.frame) value=\(value.frame) copy=\(copyCircle.frame)")
    }

    func configure(expression text: String, value result: String, selection: RowSelection,
                   showsSeparator: Bool) {
        lastConfiguration = (text, result, selection, showsSeparator)
        separator.isHidden = !showsSeparator
        let mode = Vibrancy.mode(for: effectiveAppearance)

        expression.stringValue = text + " ="
        expression.textColor = Vibrancy.color(Vibrancy.secondary, mode)
        Vibrancy.apply(mode, to: expression.layer)
        value.stringValue = result
        value.toolTip = result
        expression.toolTip = text

        updateCardFill(mode)
        Vibrancy.fill(copyCircle, Vibrancy.fill, mode)
        Vibrancy.fill(separator, Vibrancy.fill, mode)

        border.layer?.backgroundColor = nil
        if selection == .navigated {
            border.layer?.compositingFilter = nil
            border.layer?.borderWidth = Metrics.cardSelectedBorderWidth
            border.layer?.borderColor = Vibrancy.ringColor.cgColor
        } else {
            border.layer?.borderWidth = Metrics.cardBorderWidth
            border.layer?.borderColor = Vibrancy.color(Vibrancy.cardBorder, mode).cgColor
            Vibrancy.apply(mode, to: border.layer)
        }
    }

    override func hoverDidChange() {
        updateCardFill(Vibrancy.mode(for: effectiveAppearance))
    }

    private func updateCardFill(_ mode: Vibrancy.Mode) {
        guard let last = lastConfiguration else { return }
        let strength = isHovered && last.selection == .none ? Vibrancy.cardHover : Vibrancy.card
        Vibrancy.fill(card, strength, mode)
    }
}
