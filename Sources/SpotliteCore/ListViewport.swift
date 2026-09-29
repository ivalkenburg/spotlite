import CoreGraphics

/// The part of the result list on screen, which only ever shows whole rows. At rest it
/// holds the first rows, the taller lead row (top hit or calculator card) included. Once
/// scrolled it holds only regular rows, starting on a row boundary, with whatever is left
/// of the resting height empty.
///
/// Positions are in the list's own coordinates: 0 is the top of the lead row.
public struct ListViewport: Sendable, Equatable {
    public let count: Int
    public let leadHeight: CGFloat
    public let rowHeight: CGFloat
    public let visibleRows: Int

    public init(count: Int, leadHeight: CGFloat, rowHeight: CGFloat, visibleRows: Int) {
        self.count = count
        self.leadHeight = leadHeight
        self.rowHeight = rowHeight
        self.visibleRows = visibleRows
    }

    /// The first rows up to `visibleRows`.
    public var restingHeight: CGFloat {
        let shown = min(count, visibleRows)
        return shown == 0 ? 0 : leadHeight + CGFloat(shown - 1) * rowHeight
    }

    /// Regular rows that fit in the resting height.
    public var scrolledRowCount: Int { Int(restingHeight / rowHeight) }

    /// The viewport's height with `first` as its top row.
    public func height(from first: Int) -> CGFloat {
        first == 0 ? restingHeight : CGFloat(scrolledRowCount) * rowHeight
    }

    public func top(of row: Int) -> CGFloat {
        row == 0 ? 0 : leadHeight + CGFloat(row - 1) * rowHeight
    }

    /// The top row that brings `cursor` fully into view, or nil if it already is. Moving
    /// up puts the cursor at the top; moving down puts it at the bottom.
    public func firstRow(showing cursor: Int, offset: CGFloat, height: CGFloat) -> Int? {
        let rowTop = top(of: cursor)
        let rowBottom = rowTop + (cursor == 0 ? leadHeight : rowHeight)
        if rowTop < offset { return cursor }
        if rowBottom > offset + height { return max(cursor - scrolledRowCount + 1, 0) }
        return nil
    }
}
