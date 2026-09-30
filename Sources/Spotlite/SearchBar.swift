import AppKit
import SpotliteCore

/// The query bar: magnifier, field, the inline completion after the typed text, the
/// selected result's icon at the bar's right end, and the chip of a template link.
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
    /// The active menu or template link, before the query. Pill, icon and name are
    /// siblings like the completion's, so the icon is not blended with the pill.
    private let chip = PassthroughView()
    private let chipPill = NSView()
    private let chipIcon = NSImageView()
    private let chipLabel = NSTextField(labelWithString: "")
    /// The field starts after the magnifier, or after the chip while it shows.
    private var fieldAfterMagnifier: NSLayoutConstraint!
    private var fieldAfterChip: NSLayoutConstraint!
    /// The icon being loaded for the chip; see `pendingIconURL`.
    private var pendingChipIconURL: URL?
    /// Hidden while the chip shows, which names what the field is for.
    private var placeholder: NSAttributedString?
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

        chipPill.wantsLayer = true
        chipPill.layer?.cornerRadius = Metrics.chipRadius
        chipPill.layer?.cornerCurve = .continuous
        chipIcon.imageScaling = .scaleProportionallyUpOrDown
        chipLabel.wantsLayer = true
        chipLabel.font = .systemFont(ofSize: Metrics.queryFontSize, weight: .regular)
        chipLabel.lineBreakMode = .byTruncatingTail
        chipLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chip.isHidden = true
        for v in [chipPill, chipIcon, chipLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(v)
        }

        for v in [magnifier, field, barIcon, completion, chip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.magnifierInset),
            magnifier.centerYAnchor.constraint(equalTo: content.topAnchor,
                                               constant: Metrics.barCenterY + Metrics.magnifierDrop),
            magnifier.heightAnchor.constraint(equalToConstant: Metrics.magnifierWidth),
            magnifier.widthAnchor.constraint(equalToConstant: Metrics.magnifierWidth),

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

            chip.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: Metrics.magnifierGap),
            chip.topAnchor.constraint(equalTo: content.topAnchor),
            chip.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),
            // A long name truncates rather than leaving no room to type.
            chip.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.5),
            chipPill.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            chipPill.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            chipPill.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.barCenterY),
            chipPill.heightAnchor.constraint(equalToConstant: Metrics.pillHeight),
            chipIcon.leadingAnchor.constraint(equalTo: chipPill.leadingAnchor, constant: Metrics.chipLeadingPadding),
            chipIcon.centerYAnchor.constraint(equalTo: chipPill.centerYAnchor),
            chipIcon.widthAnchor.constraint(equalToConstant: Metrics.chipIconSize),
            chipIcon.heightAnchor.constraint(equalToConstant: Metrics.chipIconSize),
            chipLabel.leadingAnchor.constraint(equalTo: chipIcon.trailingAnchor, constant: Metrics.chipIconGap),
            chipLabel.trailingAnchor.constraint(equalTo: chipPill.trailingAnchor,
                                                constant: -Metrics.chipTrailingPadding),
            chipLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
        ])
        fieldAfterMagnifier = field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor,
                                                             constant: Metrics.magnifierGap)
        fieldAfterChip = field.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: Metrics.chipFieldGap)
        fieldAfterMagnifier.isActive = true
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
        placeholder = NSAttributedString(string: "Spotlite Search", attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.queryFontSize, weight: .regular),
            .foregroundColor: secondary,
        ])
        setPlaceholder(chip.isHidden ? placeholder : nil)
        Vibrancy.apply(mode, to: field.layer)

        Vibrancy.fill(chipPill, Vibrancy.pill, mode)
        chipLabel.textColor = field.textColor
        Vibrancy.apply(mode, to: chipLabel.layer)

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

    /// The current menu or template link appears before the query field.
    func showChip(title: String, icon: NSImage?, iconURL: URL? = nil) {
        chipLabel.stringValue = title
        pendingChipIconURL = nil
        chipIcon.imageScaling = iconURL == nil ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
        chipIcon.image = icon ?? iconURL.flatMap { IconCache.shared.cached(for: $0) }
        if chipIcon.image == nil, let url = iconURL {
            pendingChipIconURL = url
            IconCache.shared.load(for: url) { [weak self] loaded in
                guard let self, self.pendingChipIconURL == url else { return }
                self.pendingChipIconURL = nil
                self.chipIcon.image = loaded
            }
        }
        chip.isHidden = false
        setPlaceholder(nil)
        fieldAfterMagnifier.isActive = false
        fieldAfterChip.isActive = true
        // The completion is placed from the field's frame straight after either swap.
        content?.layoutSubtreeIfNeeded()
    }

    func hideChip() {
        guard !chip.isHidden else { return }
        chip.isHidden = true
        chipIcon.image = nil
        pendingChipIconURL = nil
        setPlaceholder(placeholder)
        fieldAfterChip.isActive = false
        fieldAfterMagnifier.isActive = true
        content?.layoutSubtreeIfNeeded()
    }

    func dumpFrames(_ tag: String) {
        print("[\(tag)] field=\(field.frame) chip=\(chip.frame) chipHidden=\(chip.isHidden)")
    }

    /// The field editor copies the placeholder when editing starts, so a change made
    /// mid-edit is handed to it too.
    private func setPlaceholder(_ text: NSAttributedString?) {
        field.placeholderAttributedString = text
        guard let editor = field.currentEditor() else { return }
        field.cell?.setUpFieldEditorAttributes(editor)
        editor.needsDisplay = true
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
        func reveal(_ image: NSImage?) {
            let wasHidden = barIcon.isHidden
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
        } else {
            // A newly selected row must not wear the previous row's icon while its
            // own icon is still loading (or if no app handles its URL).
            reveal(nil)
            if let url = item.iconURL {
                pendingIconURL = url
                IconCache.shared.load(for: url) { [weak self] loaded in
                    guard let self, self.pendingIconURL == url else { return }
                    self.pendingIconURL = nil
                    reveal(loaded)
                }
            }
        }
    }
}

/// A view that never takes clicks, so the completion drawn over the field leaves the
/// field itself clickable underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
