import CoreGraphics
import Foundation

/// The user-adjustable part of the panel's placement: how wide it is, and how far down
/// the screen it sits. X is not here because the panel is always centred horizontally.
///
/// All the arithmetic lives in this type rather than in the controller because it is the
/// part that can actually be tested. Every geometry bug in this app so far has been a
/// calculation that read as obviously correct and wasn't.
public struct PanelGeometry: Sendable, Equatable, Codable {

    public static let defaultWidth: CGFloat = 720
    public static let minWidth: CGFloat = 480
    public static let maxWidth: CGFloat = 1200

    /// Distance from the top of the visible frame to the panel's top edge, as a fraction
    /// of the visible frame's height. A fraction rather than points so the panel lands in
    /// the same visual place on a laptop screen and a large external display.
    public static let defaultVerticalFraction: CGFloat = 0.22
    public static let minVerticalFraction: CGFloat = 0.05
    public static let maxVerticalFraction: CGFloat = 0.70

    public private(set) var width: CGFloat
    public private(set) var verticalFraction: CGFloat

    public static let `default` = PanelGeometry()

    public init(width: CGFloat = PanelGeometry.defaultWidth,
                verticalFraction: CGFloat = PanelGeometry.defaultVerticalFraction) {
        self.width = min(max(width, PanelGeometry.minWidth), PanelGeometry.maxWidth)
        self.verticalFraction = min(max(verticalFraction, PanelGeometry.minVerticalFraction),
                                    PanelGeometry.maxVerticalFraction)
    }

    // MARK: - Dragging

    public enum Edge: Sendable {
        case leading, trailing
    }

    /// Width after dragging `edge` by `pointerDelta` horizontal points.
    ///
    /// The panel stays centred, so the width has to change by twice the pointer movement
    /// for the grabbed edge to stay under the pointer. This is the one place the
    /// interaction cannot behave exactly like an ordinary window.
    public func resized(edge: Edge, pointerDelta: CGFloat) -> PanelGeometry {
        let signed = (edge == .trailing) ? pointerDelta : -pointerDelta
        return PanelGeometry(width: width + signed * 2, verticalFraction: verticalFraction)
    }

    /// Vertical position after dragging by `pointerDelta` points, in Cocoa coordinates
    /// where positive is upward.
    public func moved(pointerDelta: CGFloat, visibleHeight: CGFloat) -> PanelGeometry {
        guard visibleHeight > 0 else { return self }
        // Dragging up raises the top edge, which lowers the fraction.
        return PanelGeometry(width: width,
                             verticalFraction: verticalFraction - pointerDelta / visibleHeight)
    }

    // MARK: - Fitting

    /// A copy that fits the given screen. Applied when placing the panel, never written
    /// back to preferences: unplugging a display must not destroy the real setting.
    ///
    /// - Parameter expandedHeight: the panel's height with a full list showing. Clamping
    ///   against the collapsed height would look fine until the user typed.
    public func fitted(visibleFrame: CGRect, chromeInset: CGFloat, expandedHeight: CGFloat) -> PanelGeometry {
        let widthLimit = max(PanelGeometry.minWidth, visibleFrame.width - chromeInset * 2)

        // The lowest top edge that still leaves room for a full list below it.
        let room = visibleFrame.height - expandedHeight
        let fractionLimit = room > 0
            ? min(PanelGeometry.maxVerticalFraction, room / visibleFrame.height)
            : PanelGeometry.minVerticalFraction

        return PanelGeometry(width: min(width, widthLimit),
                             verticalFraction: min(verticalFraction, fractionLimit))
    }

    /// Decoded through `init(width:verticalFraction:)` so a hand-edited or corrupted
    /// file cannot produce a panel too small to read or parked off the screen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? PanelGeometry.defaultWidth,
            verticalFraction: try c.decodeIfPresent(CGFloat.self, forKey: .verticalFraction)
                ?? PanelGeometry.defaultVerticalFraction
        )
    }

    /// Screen-coordinate Y of the panel's top edge.
    public func anchorTopY(visibleFrame: CGRect) -> CGFloat {
        visibleFrame.maxY - visibleFrame.height * verticalFraction
    }
}
