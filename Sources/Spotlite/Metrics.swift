import CoreGraphics

/// Single source of truth for layout. Every size the panel uses comes from here.
enum Metrics {
    static let inputHeight: CGFloat = 64
    static let rowHeight: CGFloat = 48
    static let maxVisibleRows = 5
    static let cornerRadius: CGFloat = 24
    static let listPadding: CGFloat = 8
    static let horizontalInset: CGFloat = 20
    static let iconSize: CGFloat = 32

    /// Transparent margin around the glass view, inside the window. The glass view's
    /// shadow is clipped hard at the window bounds, so this must exceed the shadow's
    /// full reach (blur radius + downward offset + the blur's tail) or the clip shows
    /// as a square halo. Measured: 48 left the bottom edge visibly cut, 64 faintly so.
    static let windowMargin: CGFloat = 80

    static let shadowRadius: CGFloat = 28
    static let shadowOffsetY: CGFloat = -8
    static let shadowOpacity: Float = 0.42

    /// Total distance from the window edge to the visible glass edge.
    static var chromeInset: CGFloat { windowMargin }

    /// Window width for a given visible panel width. The window is larger than the
    /// panel so the glass view's shadow isn't clipped.
    static func windowWidth(for panelWidth: CGFloat) -> CGFloat { panelWidth + chromeInset * 2 }

    /// Width of the invisible strip at each edge that resizes the panel. Deliberately
    /// unmarked: only the cursor tells you it is there.
    static let resizeEdgeWidth: CGFloat = 6

    /// How far the pointer must travel before a click on the header becomes a drag.
    /// Without it, every click to focus the field nudges the panel.
    static let dragThreshold: CGFloat = 3

    static func windowHeight(forRows rows: Int) -> CGFloat {
        height(forRows: rows) + chromeInset * 2
    }

    /// Height for a given number of matches, capped at `maxVisibleRows`.
    static func height(forRows rows: Int) -> CGFloat {
        guard rows > 0 else { return inputHeight }
        let visible = min(rows, maxVisibleRows)
        return inputHeight + CGFloat(visible) * rowHeight + listPadding * 2
    }

}
