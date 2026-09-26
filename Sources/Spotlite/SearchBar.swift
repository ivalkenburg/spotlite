import AppKit
import SpotliteCore

/// The query bar: magnifier, field, the inline completion after the typed text, and the
/// selected result's icon at the bar's right end.
///
/// Not a view. Its views go straight into the glass's content view, because the
/// secondary elements blend additively with the glass (see `Vibrancy`) and a container
/// layer between them would change what they blend with.
@MainActor
final class SearchBar {

    let field = SearchField()
    private let magnifier = NSImageView()
    /// The selected result's icon at the bar's right end.
    private let barIcon = NSImageView()
    /// Inline completion: a pill after the typed text naming what Return will do. It is
    /// drawn over the field rather than inserted as selected text, so Right Arrow and End
    /// move the caret as usual instead of accepting it, as in Spotlight.
    private let completion = PassthroughView()
    private let completionPill = NSView()
    private let completionLabel = NSTextField(labelWithString: "")
    private var completionLeading: NSLayoutConstraint!
    /// The icon being loaded for the bar, so a load that finishes after the selection
    /// moved on is dropped.
    private var pendingIconURL: URL?
    private weak var content: NSView?

    var isShowingCompletion: Bool { !completion.isHidden }

    init(in content: NSView) {
        self.content = content

        magnifier.wantsLayer = true
        field.wantsLayer = true
        completionLabel.wantsLayer = true

        barIcon.imageScaling = .scaleProportionallyDown
        barIcon.isHidden = true

        completionPill.wantsLayer = true
        completionPill.layer?.cornerRadius = Metrics.pillRadius
        completionPill.layer?.cornerCurve = .continuous
        completionLabel.font = .systemFont(ofSize: Metrics.queryFontSize, weight: .regular)
        completionLabel.lineBreakMode = .byTruncatingTail
        completionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        completion.isHidden = true
        for v in [completionPill, completionLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            completion.addSubview(v)
        }

        for v in [magnifier, field, barIcon, completion] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.magnifierInset),
            magnifier.centerYAnchor.constraint(equalTo: content.topAnchor,
                                               constant: Metrics.barCenterY + Metrics.magnifierDrop),
            magnifier.heightAnchor.constraint(equalToConstant: Metrics.magnifierWidth),
            magnifier.widthAnchor.constraint(equalToConstant: Metrics.magnifierWidth),

            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: Metrics.magnifierGap),
            field.trailingAnchor.constraint(equalTo: barIcon.leadingAnchor, constant: -8),
            // Centered against the magnifier, not stretched to the input height:
            // a text field taller than its line draws the text at the top, not the middle.
            field.centerYAnchor.constraint(equalTo: content.topAnchor,
                                           constant: Metrics.barCenterY - Metrics.queryRaise),

            barIcon.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.barIconInset),
            barIcon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.barCenterY),
            barIcon.widthAnchor.constraint(equalToConstant: Metrics.barIconSize),
            barIcon.heightAnchor.constraint(equalToConstant: Metrics.barIconSize),

            completion.topAnchor.constraint(equalTo: content.topAnchor),
            completion.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),
            completion.trailingAnchor.constraint(lessThanOrEqualTo: barIcon.leadingAnchor, constant: -8),
            completionPill.leadingAnchor.constraint(equalTo: completion.leadingAnchor),
            completionPill.trailingAnchor.constraint(equalTo: completion.trailingAnchor),
            completionPill.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.barCenterY),
            completionPill.heightAnchor.constraint(equalToConstant: Metrics.pillHeight),
            // Flush with the typed text, so "saf" + "ari" reads as one word.
            completionLabel.leadingAnchor.constraint(equalTo: completionPill.leadingAnchor),
            completionLabel.trailingAnchor.constraint(equalTo: completionPill.trailingAnchor,
                                                      constant: -Metrics.pillTrailingPadding),
            completionLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
        ])
        completionLeading = completion.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        completionLeading.isActive = true
    }

    /// Typed text is full white or black, which the additive blend leaves unchanged, so
    /// the field's one layer can carry both it and the dimmer placeholder.
    func applyVibrancy(_ mode: Vibrancy.Mode) {
        let secondary = Vibrancy.color(Vibrancy.secondary, mode)

        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            .applying(.init(paletteColors: [secondary]))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(config)
        Vibrancy.apply(mode, to: magnifier.layer)

        field.textColor = mode == .lighten ? .white : .black
        field.placeholderAttributedString = NSAttributedString(string: "Spotlite Search", attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.queryFontSize, weight: .regular),
            .foregroundColor: secondary,
        ])
        Vibrancy.apply(mode, to: field.layer)

        Vibrancy.fill(completionPill, Vibrancy.pill, mode)
        completionLabel.textColor = Vibrancy.color(Vibrancy.completion, mode)
        Vibrancy.apply(mode, to: completionLabel.layer)
    }

    /// Shows the completion and bar icon for the selected row.
    func show(_ item: ResultItem) {
        // Spotlight hides the caret while a completion shows; it would sit on the pill.
        setCaretVisible(false)
        completionLabel.stringValue = item.completion(for: field.stringValue)
        if let content { completionLeading.constant = typedTextEndX(in: content) - Metrics.pillOverlap }
        completion.isHidden = false
        showBarIcon(for: item)
    }

    /// Removes the completion and bar icon, as the first Backspace after one does.
    func clear() {
        completion.isHidden = true
        barIcon.isHidden = true
        barIcon.image = nil
        pendingIconURL = nil
        setCaretVisible(true)
    }

    private func setCaretVisible(_ visible: Bool) {
        (field.currentEditor() as? NSTextView)?.insertionPointColor = visible ? field.textColor ?? .labelColor : .clear
    }

    /// Where the typed text ends, in `view`'s coordinates, read from the field editor's
    /// own layout so the pill lands flush against the last glyph.
    func typedTextEndX(in view: NSView) -> CGFloat {
        guard let editor = field.currentEditor() as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            return field.frame.minX + field.attributedStringValue.size().width
        }
        layout.ensureLayout(for: container)
        let end = layout.usedRect(for: container).maxX + editor.textContainerOrigin.x
        return editor.convert(NSPoint(x: end, y: 0), to: view).x
    }

    private func showBarIcon(for item: ResultItem) {
        let wasHidden = barIcon.isHidden
        func reveal(_ image: NSImage?) {
            barIcon.image = image
            barIcon.isHidden = image == nil
            guard wasHidden, image != nil else { return }
            barIcon.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Metrics.barIconFadeDuration
                barIcon.animator().alphaValue = 1
            }
        }
        pendingIconURL = nil
        if let ready = item.barIcon {
            reveal(ready)
        } else if let url = item.iconURL {
            pendingIconURL = url
            IconCache.shared.load(for: url) { [weak self] loaded in
                guard let self, self.pendingIconURL == url else { return }
                self.pendingIconURL = nil
                reveal(loaded)
            }
        }
    }
}

/// A view that never takes clicks, so the completion drawn over the field leaves the
/// field itself clickable underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
