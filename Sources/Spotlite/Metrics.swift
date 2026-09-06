import CoreGraphics

/// Single source of truth for layout. Every size the panel uses comes from here.
enum Metrics {
    static let width: CGFloat = 720
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

    static var windowWidth: CGFloat { width + chromeInset * 2 }

    static func windowHeight(forRows rows: Int) -> CGFloat {
        height(forRows: rows) + chromeInset * 2
    }

    /// Height for a given number of matches, capped at `maxVisibleRows`.
    static func height(forRows rows: Int) -> CGFloat {
        guard rows > 0 else { return inputHeight }
        let visible = min(rows, maxVisibleRows)
        return inputHeight + CGFloat(visible) * rowHeight + listPadding * 2
    }

    /// Vertical placement: 22% down from the top of the screen, Spotlight-like.
    static let topFraction: CGFloat = 0.22
}
