import AppKit

/// Spotlight composites its fills and secondary text additively onto the glass. In dark
/// mode each one adds a fixed amount of light (plus-lighter); in light mode it removes
/// one (plus-darker). Measured over a black-and-orange backdrop, the change is the same
/// over both. An alpha blend cannot do that: it pulls every colour toward grey, where an
/// additive layer keeps the backdrop's hue at full saturation.
@MainActor
enum Vibrancy {
    /// How far an element moves the backdrop, as a fraction of full white or black.
    /// Spotlight darkens less in light mode than it lightens in dark mode.
    struct Strength {
        let dark: CGFloat
        let light: CGFloat
        init(dark: CGFloat, light: CGFloat) { self.dark = dark; self.light = light }
        init(_ both: CGFloat) { self.init(dark: both, light: both) }
    }

    // Measured from Spotlight over the same backdrop in both themes. The card's light
    // values are unmeasured and scaled from the fill's ratio.
    static let fill = Strength(dark: 0.14, light: 0.09)
    static let card = Strength(dark: 0.15, light: 0.1)
    /// Drawn over the card fill, so the border reads as the sum of the two.
    static let cardBorder = Strength(dark: 0.12, light: 0.08)
    static let pill = Strength(dark: 0.17, light: 0.15)
    static let hint = Strength(dark: 0.26, light: 0.235)
    static let secondary = Strength(0.48)
    /// Slightly weaker than `secondary`: it sits on the pill, which already lightens.
    static let completion = Strength(0.47)
    /// Key badges always lighten, even in light mode and over the blue selection.
    static let badge = Strength(0.14)

    /// Spotlight's selection blue is the accent colour with this much light added, the
    /// same in both themes (#007AFF becomes #158EFF). Computed from the accent so other
    /// accent colours behave the same way.
    static let selectionLift: CGFloat = 0.082
    /// The calculator card's selection ring is the accent colour darkened per channel,
    /// more in blue than in red and green (#007AFF becomes #006ED1).
    static let ringScale: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.9, 0.9, 0.82)

    static var selectionColor: NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return NSColor(srgbRed: min(1, accent.redComponent + selectionLift),
                       green: min(1, accent.greenComponent + selectionLift),
                       blue: min(1, accent.blueComponent + selectionLift), alpha: 1)
    }

    static var ringColor: NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return NSColor(srgbRed: accent.redComponent * ringScale.red,
                       green: accent.greenComponent * ringScale.green,
                       blue: accent.blueComponent * ringScale.blue, alpha: 1)
    }

    enum Mode { case lighten, darken }

    static func mode(for appearance: NSAppearance) -> Mode {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .lighten : .darken
    }

    /// The colour to draw with so that, once `apply` sets the blend, the backdrop moves
    /// by `strength`. Plus-darker computes backdrop + colour - 1, hence the inversion.
    static func color(_ strength: Strength, _ mode: Mode) -> NSColor {
        let level = mode == .lighten ? strength.dark : 1 - strength.light
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }

    static func apply(_ mode: Mode, to layer: CALayer?) {
        layer?.compositingFilter = mode == .lighten ? "plusL" : "plusD"
    }

    /// Fills a layer-backed view so it shifts the backdrop by `strength`.
    static func fill(_ view: NSView, _ strength: Strength, _ mode: Mode) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color(strength, mode).cgColor
        apply(mode, to: view.layer)
    }
}
