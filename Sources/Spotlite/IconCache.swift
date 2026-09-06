import AppKit

/// Icons are fetched lazily for visible rows only and rasterised once at display size.
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // Sized to hold the whole index rather than a screenful. Scrolling the Settings
        // list past 64 apps would otherwise evict entries and re-rasterise them on the
        // way back, and each rasterise is ~390µs cold. At 32pt @2x an entry is 64x64x4
        // bytes, so 160 of them cost about 2.5MB.
        cache.countLimit = 160
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let flattened = IconCache.rasterize(NSWorkspace.shared.icon(forFile: url.path),
                                            to: Metrics.iconSize)
        cache.setObject(flattened, forKey: key)
        return flattened
    }

    /// Draws the icon into a bitmap once, at display size.
    ///
    /// `NSImage(size:flipped:drawingHandler:)` looks like it does this but does not: it
    /// retains the drawing block — and through it the full multi-representation source
    /// icon — and re-runs it on every draw. The cache would then hold 64 complete icon
    /// families rather than 64 small bitmaps, which is the opposite of the intent.
    private static func rasterize(_ image: NSImage, to points: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int(points * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }

        let size = NSSize(width: points, height: points)
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let flattened = NSImage(size: size)
        flattened.addRepresentation(rep)
        return flattened
    }
}
