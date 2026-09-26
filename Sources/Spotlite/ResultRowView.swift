import AppKit
import SpotliteCore

/// How a row shows the selection. Spotlight marks the top hit softly and turns the
/// selection solid accent blue once the user starts moving it with the arrow keys.
enum RowSelection {
    case none, topHit, navigated
}

/// One result row: icon, title, the selected row's hints, and the selection highlight.
/// Deliberately not glass-on-glass: glass over glass reads as muddy.
final class ResultRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ResultRow")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hintStack = NSStackView()
    private let highlight = NSView()
    private let stateSwitch = NSSwitch()
    /// Hints end at the row's edge, or just before the switch on rows that carry one.
    private var hintsBeforeEdge: NSLayoutConstraint!
    private var hintsBeforeSwitch: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = Metrics.highlightRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = Metrics.hintPairGap
        // At the narrowest width a long name and a deep path compete. The name is the
        // thing being chosen, so the hints yield.
        hintStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateSwitch.controlSize = .mini
        stateSwitch.isHidden = true
        // The row owns the click; the switch only reports state.
        stateSwitch.isEnabled = false

        for v in [highlight, icon, label, hintStack, stateSwitch] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Everything centres on the highlight, not the row: the top hit's row is taller
        // by the gap that follows it.
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.highlightInset),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.highlightInset),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.rowIconInset),
            icon.centerYAnchor.constraint(equalTo: highlight.centerYAnchor, constant: Metrics.rowIconDrop),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.rowIconGap),
            label.centerYAnchor.constraint(equalTo: highlight.centerYAnchor),

            hintStack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            hintStack.centerYAnchor.constraint(equalTo: highlight.centerYAnchor),

            stateSwitch.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                  constant: -Metrics.horizontalInset),
            stateSwitch.centerYAnchor.constraint(equalTo: highlight.centerYAnchor),
        ])
        hintsBeforeEdge = hintStack.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                              constant: -Metrics.horizontalInset)
        hintsBeforeSwitch = hintStack.trailingAnchor.constraint(equalTo: stateSwitch.leadingAnchor,
                                                                constant: -Metrics.hintPairGap)
        hintsBeforeEdge.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastConfiguration: (item: ResultItem, selection: RowSelection,
                                    modifiers: NSEvent.ModifierFlags)?

    /// Colours depend on the appearance, so a theme change re-applies them.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let last = lastConfiguration else { return }
        configure(with: last.item, selection: last.selection, modifiers: last.modifiers)
    }

    /// Identifies which icon this reused row is currently waiting for, so a slow load
    /// that lands after the row has been recycled is discarded instead of showing the
    /// wrong app's icon.
    private var pendingIconURL: URL?

    func configure(with item: ResultItem, selection: RowSelection, modifiers: NSEvent.ModifierFlags) {
        lastConfiguration = (item, selection, modifiers)
        let mode = Vibrancy.mode(for: effectiveAppearance)

        label.stringValue = item.title
        // Spotlight's titles are full white or black, not the slightly translucent label colour.
        label.textColor = selection == .navigated || mode == .lighten ? .white : .black

        switch selection {
        case .none:
            highlight.isHidden = true
        case .topHit:
            highlight.isHidden = false
            Vibrancy.fill(highlight, Vibrancy.fill, mode)
        case .navigated:
            highlight.isHidden = false
            highlight.layer?.compositingFilter = nil
            highlight.layer?.backgroundColor = Vibrancy.selectionColor.cgColor
        }

        let hints = selection == .none ? [] : item.hints(modifiers: modifiers)
        // Over the blue, hints lighten in both themes: darkening would muddy the accent.
        buildHints(hints, mode: selection == .navigated ? .lighten : mode)

        if let state = item.switchState {
            stateSwitch.isHidden = false
            stateSwitch.state = state ? .on : .off
        } else {
            stateSwitch.isHidden = true
        }
        // Deactivate before activating, so the two are never both active.
        let showsSwitch = !stateSwitch.isHidden
        NSLayoutConstraint.deactivate([showsSwitch ? hintsBeforeEdge : hintsBeforeSwitch])
        NSLayoutConstraint.activate([showsSwitch ? hintsBeforeSwitch : hintsBeforeEdge])

        configureIcon(for: item)
    }

    /// What the hint stack shows now. Every keystroke re-renders the selected row, and
    /// its hints rarely change, so identical ones keep their views.
    private var shownHints: (hints: [ResultItem.Hint], mode: Vibrancy.Mode)?

    private func buildHints(_ hints: [ResultItem.Hint], mode: Vibrancy.Mode) {
        if let shown = shownHints, shown.hints == hints, shown.mode == mode { return }
        shownHints = (hints, mode)
        hintStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for hint in hints {
            let pair = NSStackView()
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = Metrics.hintBadgeGap

            let text = ResultRowView.vibrantLabel(hint.text, size: Metrics.hintFontSize, mode: mode)
            // The tail of a path ("/Utilities") is what distinguishes it, so it truncates
            // from the head.
            text.lineBreakMode = .byTruncatingHead
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pair.addArrangedSubview(text)
            if let key = hint.key { pair.addArrangedSubview(KeyBadge(key, textMode: mode)) }
            hintStack.addArrangedSubview(pair)
        }
    }

    static func vibrantLabel(_ string: String, size: CGFloat, mode: Vibrancy.Mode) -> NSTextField {
        let text = NSTextField(labelWithString: string)
        text.font = .systemFont(ofSize: size, weight: .regular)
        text.textColor = Vibrancy.color(Vibrancy.hint, mode)
        text.wantsLayer = true
        Vibrancy.apply(mode, to: text.layer)
        return text
    }

    private func configureIcon(for item: ResultItem) {
        // App icons fill the frame; symbols keep their own size, or they would scale up
        // to the app icon's padded canvas and read far larger than the artwork beside them.
        icon.imageScaling = item.iconURL == nil ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
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
}

/// A keyboard key drawn as Spotlight draws its "tab" badge. The badge always lightens,
/// in both themes and over the blue selection alike; that is what Spotlight measures as.
final class KeyBadge: NSView {
    init(_ key: String, textMode: Vibrancy.Mode) {
        super.init(frame: .zero)
        Vibrancy.fill(self, Vibrancy.badge, .lighten)
        layer?.cornerRadius = Metrics.badgeRadius
        layer?.cornerCurve = .continuous

        let text = ResultRowView.vibrantLabel(key, size: Metrics.badgeFontSize, mode: textMode)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.badgeHeight),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.badgePadding),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.badgePadding),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
