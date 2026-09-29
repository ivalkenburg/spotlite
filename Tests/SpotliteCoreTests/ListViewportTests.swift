import CoreGraphics
import Testing
@testable import SpotliteCore

@Suite("List viewport")
struct ListViewportTests {

    /// The app's sizes: 56pt rows, led by a top hit of the same height or an 81pt
    /// calculator card.
    private func list(_ count: Int, lead: CGFloat = 56, rows: Int = 7) -> ListViewport {
        ListViewport(count: count, leadHeight: lead, rowHeight: 56, visibleRows: rows)
    }

    @Test func restingHeightHoldsTheFirstRows() {
        #expect(list(0).restingHeight == 0)
        #expect(list(3).restingHeight == CGFloat(56 + 2 * 56))
        #expect(list(20).restingHeight == CGFloat(56 + 6 * 56))
        #expect(list(20, lead: 81).restingHeight == CGFloat(81 + 6 * 56))
        #expect(list(20, rows: 4).restingHeight == CGFloat(56 + 3 * 56))
    }

    /// Scrolled, the list shows as many whole rows as at rest, with or without the card.
    @Test func scrolledHeightIsWholeRows() {
        #expect(list(20).scrolledRowCount == 7)
        #expect(list(20).height(from: 1) == CGFloat(7 * 56))
        #expect(list(20, lead: 81).scrolledRowCount == 7)
        #expect(list(20).height(from: 0) == list(20).restingHeight)
    }

    @Test func rowTops() {
        #expect(list(20).top(of: 0) == 0)
        #expect(list(20).top(of: 1) == 56)
        #expect(list(20).top(of: 3) == CGFloat(56 + 2 * 56))
    }

    @Test func visibleCursorStays() {
        let l = list(20)
        #expect(l.firstRow(showing: 6, offset: 0, height: l.restingHeight) == nil)
        #expect(l.firstRow(showing: 3, offset: l.top(of: 1), height: l.height(from: 1)) == nil)
    }

    @Test func movingDownPastTheBottomScrollsOneRow() {
        let l = list(20)
        #expect(l.firstRow(showing: 7, offset: 0, height: l.restingHeight) == 1)
        #expect(l.firstRow(showing: 8, offset: l.top(of: 1), height: l.height(from: 1)) == 2)
    }

    @Test func movingUpPastTheTopPutsTheCursorFirst() {
        let l = list(20)
        #expect(l.firstRow(showing: 4, offset: l.top(of: 5), height: l.height(from: 5)) == 4)
        #expect(l.firstRow(showing: 0, offset: l.top(of: 1), height: l.height(from: 1)) == 0)
    }

    /// Up from the top hit wraps to the last row, which lands flush with the list's end.
    @Test func wrappingToTheLastRowShowsTheEnd() {
        let l = list(48)
        #expect(l.firstRow(showing: 47, offset: 0, height: l.restingHeight) == 41)
    }

    /// A trackpad can leave the list between rows; the cursor row is still made whole.
    @Test func realignsAfterAFreeScroll() {
        let l = list(20)
        #expect(l.firstRow(showing: 1, offset: 70, height: l.restingHeight) == 1)
    }
}
