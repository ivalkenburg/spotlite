import AppKit
import SpotliteCore

/// Where the panel sits: which display it opens on, its frame there, and dragging its
/// edges and header. The controller owns the preferences; this reads them and reports
/// geometry the user drags to.
@MainActor
final class PanelPlacement: PanelDragReceiver {

    private let panel: NSWindow
    private let preferences: () -> Preferences
    /// Called on every step of a drag that moved the panel, then once more with
    /// `finished` set when it ends, which is when the geometry is worth saving.
    var onGeometryChange: ((_ geometry: PanelGeometry, _ finished: Bool) -> Void)?

    /// Fixed for one presentation so moving the pointer to another display cannot make
    /// the panel jump while its result count changes.
    private var activeVisibleFrame: CGRect?
    /// Live drag state. Non-nil only between mouse-down and the drag ending.
    private var drag: (kind: PanelDrag, origin: NSPoint, start: PanelGeometry,
                       screen: CGRect, engaged: Bool)?

    var isDragging: Bool { drag != nil }

    init(panel: NSWindow, preferences: @escaping () -> Preferences) {
        self.panel = panel
        self.preferences = preferences
    }

    /// Placed on whichever display the user chose. Following the pointer is the default
    /// because your eyes are usually where your mouse is, but on a fixed multi-monitor
    /// setup an incidental pointer position is the wrong signal.
    func place() {
        guard let frame = selectedVisibleFrame() else { return }
        activeVisibleFrame = frame
        apply(fitted(preferences().panelGeometry, for: frame), on: frame)
    }

    /// Lets the next presentation pick its display afresh.
    func release() {
        activeVisibleFrame = nil
    }

    /// Re-applies the stored geometry while the panel is on screen, for example after a
    /// Reset Size & Position from Settings.
    func reapply(screenChanged: Bool) {
        if screenChanged { activeVisibleFrame = selectedVisibleFrame() }
        let visibleFrame = currentVisibleFrame
        apply(fitted(preferences().panelGeometry, for: visibleFrame), on: visibleFrame)
    }

    private func selectedVisibleFrame() -> CGRect? {
        let screen: NSScreen?
        switch preferences().panelScreen {
        case .followPointer:
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        case .primary:
            // `screens.first` is the one with the menu bar; `main` follows key window.
            screen = NSScreen.screens.first ?? NSScreen.main
        }
        return screen?.visibleFrame
    }

    /// Stored geometry clamped to what this screen can actually hold. The clamp is never
    /// written back: unplugging a display must not destroy the real setting.
    private func fitted(_ geometry: PanelGeometry, for visibleFrame: CGRect) -> PanelGeometry {
        geometry.fitted(visibleFrame: visibleFrame,
                        chromeInset: Metrics.chromeInset,
                        expandedHeight: Metrics.maxPanelHeight(visibleRows: preferences().visibleRows))
    }

    private var currentVisibleFrame: CGRect {
        if let drag { return drag.screen }
        return activeVisibleFrame ?? selectedVisibleFrame() ?? .zero
    }

    /// The single place the window's frame is computed, so width and vertical position
    /// can never disagree about where the panel belongs. The window is always full
    /// height; the glass inside it sizes itself to the results.
    private func apply(_ geometry: PanelGeometry, on visibleFrame: CGRect) {
        let anchorTopY = geometry.anchorTopY(visibleFrame: visibleFrame)

        let height = Metrics.windowHeight(visibleRows: preferences().visibleRows)
        let width = Metrics.windowWidth(for: geometry.width)
        let frame = NSRect(x: visibleFrame.midX - width / 2,
                           y: anchorTopY + Metrics.chromeInset - height,
                           width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Dragging

    func dragBegan(_ kind: PanelDrag, at screenPoint: NSPoint) {
        let frame = currentVisibleFrame
        drag = (kind, screenPoint, fitted(preferences().panelGeometry, for: frame), frame, engaged: false)
    }

    func dragChanged(to screenPoint: NSPoint) {
        guard var session = drag else { return }

        let dx = screenPoint.x - session.origin.x
        let dy = screenPoint.y - session.origin.y

        // A click always jitters a pixel or two; without this every click on the header
        // would nudge the panel.
        if !session.engaged {
            guard max(abs(dx), abs(dy)) >= Metrics.dragThreshold else { return }
            session.engaged = true
        }
        drag = session

        let updated: PanelGeometry
        switch session.kind {
        case .move:
            updated = session.start.moved(pointerDelta: dy, visibleHeight: session.screen.height)
        case .resize(let edge):
            updated = session.start.resized(edge: edge, pointerDelta: dx)
        }

        onGeometryChange?(updated, false)
        // Never animated: an animation here would leave the panel lagging the pointer.
        apply(fitted(updated, for: session.screen), on: session.screen)
    }

    func dragEnded() {
        guard let session = drag else { return }
        drag = nil
        guard session.engaged else { return }

        let geometry = preferences().panelGeometry
        onGeometryChange?(geometry, true)
        apply(fitted(geometry, for: session.screen), on: session.screen)
    }
}
