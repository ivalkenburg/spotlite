import AppKit

/// Mouse feedback stays separate from the launcher's keyboard selection.
class HoverResultCellView: NSTableCellView {
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        // Reloads and scrolling can move a reused cell under a stationary pointer.
        if let window, window.isKeyWindow {
            setHovered(visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream,
                                                     from: nil)))
        } else {
            setHovered(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        hoverDidChange()
    }

    /// Subclasses update only their background, leaving selection and hints alone.
    func hoverDidChange() {}
}
