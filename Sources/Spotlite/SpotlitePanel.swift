import AppKit
import SpotliteCore

/// A borderless panel that can take key focus without the app owning the Dock.
final class SpotlitePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0,
                                width: Metrics.windowWidth(for: PanelGeometry.defaultWidth),
                                height: Metrics.windowHeight(forRows: 0)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // AppKit derives a borderless window's shadow from its rectangular frame, which
        // paints a square halo outside the glass view's rounded corners. NSGlassEffectView
        // renders its own correctly-shaped shadow, so the window must not add one.
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }
}
