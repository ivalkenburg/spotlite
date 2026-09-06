import CoreGraphics
import Foundation
import Testing
@testable import SpotliteCore

@Suite("Panel geometry")
struct PanelGeometryTests {

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)

    @Test func initClampsBothValues() {
        #expect(PanelGeometry(width: 100).width == PanelGeometry.minWidth)
        #expect(PanelGeometry(width: 5000).width == PanelGeometry.maxWidth)
        #expect(PanelGeometry(verticalFraction: -1).verticalFraction == PanelGeometry.minVerticalFraction)
        #expect(PanelGeometry(verticalFraction: 9).verticalFraction == PanelGeometry.maxVerticalFraction)
    }

    /// The grabbed edge must stay under the pointer, so a centred panel widens by twice
    /// the pointer movement.
    @Test func resizingIsSymmetricAboutTheCentre() {
        let start = PanelGeometry(width: 700)
        #expect(start.resized(edge: .trailing, pointerDelta: 50).width == 800)
        #expect(start.resized(edge: .leading, pointerDelta: -50).width == 800)
        #expect(start.resized(edge: .trailing, pointerDelta: -50).width == 600)
        #expect(start.resized(edge: .leading, pointerDelta: 50).width == 600)
    }

    @Test func resizingCannotEscapeTheBounds() {
        #expect(PanelGeometry(width: 700).resized(edge: .trailing, pointerDelta: 9999).width
                == PanelGeometry.maxWidth)
        #expect(PanelGeometry(width: 700).resized(edge: .trailing, pointerDelta: -9999).width
                == PanelGeometry.minWidth)
    }

    @Test func draggingUpRaisesTheTopEdge() {
        let start = PanelGeometry(verticalFraction: 0.4)
        let up = start.moved(pointerDelta: 113, visibleHeight: 1130)
        #expect(abs(up.verticalFraction - 0.3) < 0.0001)

        let down = start.moved(pointerDelta: -113, visibleHeight: 1130)
        #expect(abs(down.verticalFraction - 0.5) < 0.0001)
    }

    @Test func anchorIsMeasuredFromTheTopOfTheVisibleFrame() {
        let geometry = PanelGeometry(verticalFraction: 0.22)
        // 1130 tall, top at y=1130, so 22% down is 1130 - 248.6.
        #expect(abs(geometry.anchorTopY(visibleFrame: screen) - 881.4) < 0.01)
    }

    // MARK: - Fitting

    @Test func fittingNarrowsToADisplayThatCannotHoldTheWidth() {
        let small = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let fitted = PanelGeometry(width: 1200).fitted(visibleFrame: small, chromeInset: 80,
                                                       expandedHeight: 320)
        // 1024 - 160 of chrome leaves 864 for the panel itself.
        #expect(fitted.width == 864)
    }

    @Test func fittingLeavesRoomForAFullList() {
        // 0.70 of 1130 is 791; a 320pt panel from there would run 0.5pt off the bottom.
        let fitted = PanelGeometry(verticalFraction: 0.70).fitted(visibleFrame: screen,
                                                                  chromeInset: 80,
                                                                  expandedHeight: 320)
        let top = fitted.anchorTopY(visibleFrame: screen)
        #expect(top - 320 >= screen.minY)
    }

    /// The clamp is applied on use only. Losing a display must not rewrite the setting.
    @Test func fittingDoesNotMutateTheOriginal() {
        let stored = PanelGeometry(width: 1200, verticalFraction: 0.70)
        let small = CGRect(x: 0, y: 0, width: 1024, height: 500)
        _ = stored.fitted(visibleFrame: small, chromeInset: 80, expandedHeight: 320)
        #expect(stored.width == 1200)
        #expect(stored.verticalFraction == 0.70)
    }

    @Test func fittingIsAnIdentityWhenEverythingAlreadyFits() {
        let geometry = PanelGeometry(width: 720, verticalFraction: 0.22)
        #expect(geometry.fitted(visibleFrame: screen, chromeInset: 80, expandedHeight: 320) == geometry)
    }

    /// A screen too short for a full list at any position must still yield something on it.
    @Test func fittingSurvivesAScreenShorterThanThePanel() {
        let tiny = CGRect(x: 0, y: 0, width: 900, height: 200)
        let fitted = PanelGeometry(verticalFraction: 0.5).fitted(visibleFrame: tiny, chromeInset: 80,
                                                                 expandedHeight: 320)
        #expect(fitted.verticalFraction == PanelGeometry.minVerticalFraction)
    }
}
