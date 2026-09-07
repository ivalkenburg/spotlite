import AppKit

/// The window is larger than the visible panel so the glass view's shadow isn't clipped.
/// That margin is transparent but would still swallow clicks, so a click landing outside
/// the glass must fall through to whatever is behind — otherwise clicking away from the
/// panel neither dismisses it nor reaches the app underneath.
final class MarginHostView: NSView {
    weak var glass: NSView?
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let glass, glass.frame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
