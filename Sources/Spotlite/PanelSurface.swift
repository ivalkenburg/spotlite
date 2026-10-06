import AppKit

/// Experimental material selection. Only the selected backend is constructed: keeping
/// an unused NSGlassEffectView alive would invalidate the memory comparison.
@MainActor
final class PanelSurface {
    enum Material: String {
        case glass, hud, popover
        /// Diagnostic floor for the same AppKit contents, not a live-blur candidate.
        case solid
    }

    let material: Material
    let view: NSView
    private let glass: NSGlassEffectView?
    private let backdrop: BlurSurfaceView?

    init() {
        material = Material(rawValue: ProcessInfo.processInfo.environment["SPOTLITE_DEV_MATERIAL"] ?? "") ?? .glass
        switch material {
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.cornerRadius
            glass.style = .regular
            self.glass = glass
            backdrop = nil
            view = glass
        case .hud, .popover, .solid:
            let blur: NSVisualEffectView.Material? = switch material {
            case .hud: .hudWindow
            case .popover: .popover
            default: nil
            }
            let backdrop = BlurSurfaceView(material: blur)
            self.backdrop = backdrop
            glass = nil
            view = backdrop
        }
        view.wantsLayer = true
        if material == .glass {
            view.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(Metrics.shadowOpacity)
                shadow.shadowBlurRadius = Metrics.shadowRadius
                shadow.shadowOffset = NSSize(width: 0, height: Metrics.shadowOffsetY)
                return shadow
            }()
        } else {
            // The blur has a known rounded outline; it need not flatten its contents
            // into an AppKit NSShadow before computing that outline.
            view.layer?.shadowColor = NSColor.black.cgColor
            view.layer?.shadowOpacity = Float(Metrics.shadowOpacity)
            view.layer?.shadowRadius = Metrics.shadowRadius
            view.layer?.shadowOffset = CGSize(width: 0, height: Metrics.shadowOffsetY)
        }
    }

    func installContent(_ content: NSView) {
        if let glass {
            glass.contentView = content
        } else if let backdrop {
            // Give the flipped foreground its own backing layer so unbacked image
            // views keep their drawing scale as the panel expands.
            content.wantsLayer = true
            backdrop.addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                content.topAnchor.constraint(equalTo: backdrop.topAnchor),
                content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            ])
        }
    }

    func applyAppearance(_ appearance: NSAppearance?, dark: Bool, tint: Double) {
        view.appearance = appearance
        let color = tint > 0 ? Metrics.glassTint(dark: dark).withAlphaComponent(tint) : nil
        glass?.tintColor = color
        backdrop?.applyColors(dark: dark, tint: color)
    }
}

/// A live WindowServer backdrop with ordinary foreground layers. Keeping the content
/// beside the effect view avoids introducing material vibrancy into existing text colors.
private final class BlurSurfaceView: NSView {
    private let effect: NSVisualEffectView?
    private let tint = NSView()

    init(material: NSVisualEffectView.Material?) {
        effect = material.map { material in
            let effect = NSVisualEffectView()
            effect.material = material
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            return effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        // A stretchable alpha mask clips the server-side blur itself, including corners.
        let radius = Metrics.cornerRadius
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect?.maskImage = mask

        tint.wantsLayer = true
        tint.layer?.cornerRadius = radius
        tint.layer?.borderWidth = 0.5
        for child in [effect, tint].compactMap({ $0 }) {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyColors(dark: Bool, tint color: NSColor?) {
        tint.layer?.backgroundColor = (effect == nil ? Metrics.glassTint(dark: dark) : color)?.cgColor
        tint.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.22 : 0.55).cgColor
    }

    override func layout() {
        super.layout()
        // An explicit rounded outline avoids deriving a shadow from the whole subtree.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Metrics.cornerRadius,
                                  cornerHeight: Metrics.cornerRadius, transform: nil)
        CATransaction.commit()
    }
}
