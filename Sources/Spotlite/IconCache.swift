import AppKit

/// Icons are loaded only for rows that are actually on screen, and never on the main
/// thread: fetching plus a first rasterise costs roughly 670µs per icon, which would be
/// several milliseconds of stall the first time a screenful of results appears.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()
    /// Serial: icon work is I/O bound and ordering keeps the visible rows first.
    private let queue = DispatchQueue(label: "com.igorv.spotlite.icons", qos: .userInitiated)
    /// Every waiter for an in-flight icon, not just the first. Each keystroke re-renders
    /// the row and asks again; dropping those later requests left rows stuck on the
    /// placeholder, because the load that did finish had nobody left to notify.
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    private init() {
        // Sized to hold the whole index rather than a screenful. Scrolling the Settings
        // list past 64 apps would otherwise evict entries and re-rasterise them on the
        // way back. At 45pt @2x an entry is 90x90x4 bytes, so 160 cost about 5MB.
        cache.countLimit = 160
    }

    /// The icon if it is already in memory. Never touches the disk.
    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// Loads off the main thread and calls back on it. It does not consult the cache, so
    /// check `cached(for:)` first rather than paying for a second load.
    func load(for url: URL, completion: @escaping (NSImage) -> Void) {
        let key = url.path

        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]

        queue.async {
            // Resolved first: an app in /Applications that is a symlink (Safari, into its
            // cryptex) would otherwise carry Finder's alias arrow, which Spotlight omits.
            let icon = NSWorkspace.shared.icon(forFile: (key as NSString).resolvingSymlinksInPath)
            let flattened = IconCache.rasterize(icon, to: Metrics.iconSize)
            Task { @MainActor in
                self.cache.setObject(flattened, forKey: key as NSString)
                let waiters = self.waiting.removeValue(forKey: key) ?? []
                for waiter in waiters { waiter(flattened) }
            }
        }
    }

    /// Shown while the real icon loads, so a row never renders as a hole. Rasterised once.
    static let placeholder: NSImage = {
        rasterize(NSWorkspace.shared.icon(for: .applicationBundle), to: Metrics.iconSize)
    }()

    /// Draws the icon into a bitmap once, at display size.
    ///
    /// `NSImage(size:flipped:drawingHandler:)` looks like it does this but does not: it
    /// retains the drawing block — and through it the full multi-representation source
    /// icon — and re-runs it on every draw.
    nonisolated private static func rasterize(_ image: NSImage, to points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)

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
