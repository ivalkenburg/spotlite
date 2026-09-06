import AppKit
import SpotliteCore

/// What a drag on the panel is doing.
enum PanelDrag {
    case move
    case resize(PanelGeometry.Edge)
}

/// Reports the phases of a panel drag. The pointer location is in screen coordinates,
/// because the views doing the reporting are themselves being moved and resized.
@MainActor
protocol PanelDragReceiver: AnyObject {
    func dragBegan(_ drag: PanelDrag, at screenPoint: NSPoint)
    func dragChanged(to screenPoint: NSPoint)
    func dragEnded()
}

/// An invisible strip at the panel's left or right edge that resizes it.
///
/// It draws nothing and changes no layout — the only sign it exists is the cursor. It
/// sits inside the glass rather than in the window's transparent margin, because that
/// margin passes clicks through to whatever is behind and that is what makes
/// click-away-to-dismiss work.
@MainActor
final class ResizeEdgeView: NSView {
    private let edge: PanelGeometry.Edge
    weak var receiver: PanelDragReceiver?

    init(edge: PanelGeometry.Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        receiver?.dragBegan(.resize(edge), at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        receiver?.dragChanged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        receiver?.dragEnded()
    }
}

/// Covers the input bar and moves the panel vertically.
///
/// It claims only the part of the bar the query text does not occupy, so clicking into
/// the text and dragging to select still works. The alternative — excluding the text
/// field's whole frame, as originally planned — leaves a handle about 64pt wide, since
/// the field spans nearly the entire bar whether or not it holds any text.
@MainActor
final class MoveHandleView: NSView {
    weak var receiver: PanelDragReceiver?
    /// X, in this view's coordinates, past which the bar is empty and so draggable.
    var textEndX: () -> CGFloat = { 0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x > textEndX() else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        receiver?.dragBegan(.move, at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        receiver?.dragChanged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        receiver?.dragEnded()
    }
}
