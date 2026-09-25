import AppKit
import QuartzCore

/// Drives values frame by frame from the display link.
///
/// NSGlassEffectView does not take part in AppKit's implicit animations: animating its
/// size constraint makes the glass jump to the final size while only its contents
/// animate. Stepping the constraint on every frame makes the glass itself move.
@MainActor
final class FrameAnimator: NSObject {
    enum Curve {
        case easeOut

        func callAsFunction(_ t: Double) -> Double {
            switch self {
            case .easeOut: return 1 - pow(1 - t, 3)
            }
        }
    }

    private struct Track {
        let start: CFTimeInterval
        let duration: Double
        let curve: Curve
        let update: (Double) -> Void
        let completion: (() -> Void)?
    }

    private var tracks: [String: Track] = [:]
    private var link: CADisplayLink?
    private weak var view: NSView?

    /// The view whose display paces the animation.
    init(view: NSView) {
        self.view = view
    }

    /// Replaces any running animation with the same key; the replaced one's completion
    /// does not run.
    func run(_ key: String, duration: Double, curve: Curve,
             update: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        tracks[key] = Track(start: CACurrentMediaTime(), duration: duration, curve: curve,
                            update: update, completion: completion)
        update(0)
        startLink()
    }

    func cancel(_ key: String) {
        tracks[key] = nil
    }

    private func startLink() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        let now = CACurrentMediaTime()
        for (key, track) in tracks {
            let t = min(1, (now - track.start) / track.duration)
            track.update(track.curve(t))
            if t >= 1 {
                tracks[key] = nil
                track.completion?()
            }
        }
        if tracks.isEmpty {
            link?.invalidate()
            link = nil
        }
    }
}
