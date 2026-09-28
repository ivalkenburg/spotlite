import AppKit
import QuartzCore

/// Drives values frame by frame from the display link.
///
/// NSGlassEffectView does not take part in AppKit's implicit animations: animating its
/// size constraint makes the glass jump to the final size while only its contents
/// animate. Stepping the constraint on every frame makes the glass itself move.
@MainActor
final class FrameAnimator: NSObject {
    private struct Track {
        let start: CFTimeInterval
        let duration: Double
        let update: (Double) -> Void
    }

    private var track: Track?
    private var link: CADisplayLink?
    private weak var view: NSView?

    /// The view whose display paces the animation.
    init(view: NSView) {
        self.view = view
    }

    /// Replaces the current height animation.
    func run(duration: Double, update: @escaping (Double) -> Void) {
        track = Track(start: CACurrentMediaTime(), duration: duration, update: update)
        update(0)
        startLink()
    }

    func cancel() {
        track = nil
        link?.invalidate()
        link = nil
    }

    private func startLink() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        guard let track else { cancel(); return }
        let now = CACurrentMediaTime()
        let t = min(1, (now - track.start) / track.duration)
        track.update(1 - pow(1 - t, 3))
        if t >= 1 { cancel() }
    }
}
