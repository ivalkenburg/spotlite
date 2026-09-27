import AppKit

/// Single source of truth for layout. Every size the panel uses comes from here.
/// Values are measured from macOS 26 Spotlight captures, so the two are indistinguishable.
enum Metrics {
    /// Height of the search bar, and of the whole panel while it is empty.
    static let inputHeight: CGFloat = 57
    /// Half the input height, as Spotlight does: a capsule while collapsed, a rounded
    /// rect once results expand it.
    static let cornerRadius: CGFloat = inputHeight / 2
    /// Spotlight caps the panel here, which cuts the seventh row off at the bottom edge.
    /// The cut-off row is what says the list scrolls.
    static let maxPanelHeight: CGFloat = 467

    static let rowHeight: CGFloat = 56
    /// Extra space after the top hit, which Spotlight spaces as a group of its own.
    static let topHitGap: CGFloat = 2
    static let listTopPadding: CGFloat = 10
    static let listBottomPadding: CGFloat = 8
    static let horizontalInset: CGFloat = 20
    /// The divider occupies the input's last point rather than sitting below it.
    static let dividerY: CGFloat = 56

    /// App icon artwork fills only ~80% of its canvas, so a 45pt frame shows the same
    /// ~36pt squircle Spotlight does. Inset and gap are measured to the frame, not the art.
    static let iconSize: CGFloat = 45
    static let rowIconInset: CGFloat = 12.75
    static let rowIconGap: CGFloat = 13.25
    /// App icon artwork sits slightly above its canvas's centre; this re-centres it.
    static let rowIconDrop: CGFloat = 0.75
    static let highlightInset: CGFloat = 10
    /// The running-app dot, centred this far below the icon frame's bottom edge. The
    /// artwork stops short of the frame, so the dot sits just under the squircle.
    static let runningDotSize: CGFloat = 4
    static let runningDotDrop: CGFloat = -1
    /// Concentric with the panel's corners: the panel radius less the highlight's inset.
    static let highlightRadius: CGFloat = cornerRadius - highlightInset
    static let titleFontSize: CGFloat = 17

    /// The magnifier's frame, independent of the row icons so resizing those never
    /// shifts the query text.
    static let magnifierInset: CGFloat = 18
    static let magnifierWidth: CGFloat = 32
    static let magnifierGap: CGFloat = 12
    static let queryFontSize: CGFloat = 26
    /// The bar's contents centre half a point above the bar's middle, and the query text
    /// sits a point higher still, both as measured against Spotlight.
    static let barCenterY: CGFloat = 28
    static let queryRaise: CGFloat = 1
    /// The magnifier glyph draws half a point high in its frame.
    static let magnifierDrop: CGFloat = 0.5

    /// The selected result's icon at the bar's right end: 26pt of artwork in its frame.
    static let barIconSize: CGFloat = 32
    static let barIconInset: CGFloat = 20

    /// The pill behind the inline completion. It starts flush at the end of the typed
    /// text and runs a little past the end of its own.
    static let pillHeight: CGFloat = 30
    static let pillRadius: CGFloat = 5.5
    static let pillTrailingPadding: CGFloat = 6
    /// The field editor's measured text end sits this far past the last glyph's edge,
    /// where Spotlight starts its pill.
    static let pillOverlap: CGFloat = 2.5

    /// The token before the argument of a template link, as Spotlight draws an app it
    /// searches inside: the pill's height, the link's icon, then its name.
    static let chipRadius: CGFloat = 8
    static let chipIconSize: CGFloat = 22
    static let chipLeadingPadding: CGFloat = 5
    static let chipIconGap: CGFloat = 4
    static let chipTrailingPadding: CGFloat = 8
    /// Between the chip and the caret.
    static let chipFieldGap: CGFloat = 6

    /// Hints on the selected row: small text, then a key badge.
    static let hintFontSize: CGFloat = 10
    static let badgeFontSize: CGFloat = 11
    static let badgeHeight: CGFloat = 18
    static let badgeRadius: CGFloat = 3.5
    static let badgePadding: CGFloat = 5.75
    static let hintBadgeGap: CGFloat = 8.5
    static let hintPairGap: CGFloat = 14

    /// The calculator's result card, which replaces a row when the query is arithmetic.
    static let cardInset: CGFloat = 18
    static let cardHeight: CGFloat = 62
    static let cardRadius: CGFloat = 16
    static let cardBorderWidth: CGFloat = 2
    static let cardSelectedBorderWidth: CGFloat = 2
    static let cardSeparatorGap: CGFloat = 8
    static let cardExpressionBaseline: CGFloat = 24.5
    static let cardValueBaseline: CGFloat = 45.5
    static let cardTextInset: CGFloat = 18.5
    static let copyButtonSize: CGFloat = 26
    static let copyButtonInset: CGFloat = 16.5
    /// Card, the gap and 1pt separator under it, then the usual space before a row.
    static var cardRowHeight: CGFloat { cardHeight + cardSeparatorGap + 1 + listTopPadding }

    /// Transparent margin around the glass view, inside the window. The glass view's
    /// shadow is clipped hard at the window bounds, so this must exceed the shadow's
    /// full reach (blur + downward offset + the blur's tail) or the clip shows as a
    /// square halo.
    static let windowMargin: CGFloat = 110

    /// The neutral colour the Tint setting blends the glass toward, per theme. At full
    /// strength the panel is solid.
    static func glassTint(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
             : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    }

    static let shadowRadius: CGFloat = 40
    static let shadowOffsetY: CGFloat = -18
    static let shadowOpacity: CGFloat = 0.6

    /// Total distance from the window edge to the visible glass edge.
    static var chromeInset: CGFloat { windowMargin }

    /// Window width for a given visible panel width. The window is larger than the
    /// panel so the glass view's shadow isn't clipped.
    static func windowWidth(for panelWidth: CGFloat) -> CGFloat { panelWidth + chromeInset * 2 }

    /// The window is always tall enough for a full list. Growing the glass inside a
    /// fixed window lets it animate; resizing the window itself makes Liquid Glass
    /// visibly nudge its top edge on every frame.
    static var windowHeight: CGFloat { maxPanelHeight + chromeInset * 2 }

    /// Width of the invisible strip at each edge that resizes the panel. Deliberately
    /// unmarked: only the cursor tells you it is there.
    static let resizeEdgeWidth: CGFloat = 6

    /// How far the pointer must travel before a click on the header becomes a drag.
    /// Without it, every click to focus the field nudges the panel.
    static let dragThreshold: CGFloat = 3

    // Animation timings, measured from a 60fps recording of Spotlight.

    /// Open: fades in while settling from slightly larger to full size.
    static let showFadeDuration: Double = 0.085
    static let showScaleDuration: Double = 0.12
    static let showStartScale: CGFloat = 1.08
    /// Close: fades out while shrinking slightly.
    static let hideDuration: Double = 0.07
    static let hideEndScale: CGFloat = 0.97
    /// Results appearing: the glass grows downward, revealing rows with its edge.
    static let growDuration: Double = 0.15
    /// The bar icon fades in shortly after its completion appears.
    static let barIconFadeDuration: Double = 0.12
}
