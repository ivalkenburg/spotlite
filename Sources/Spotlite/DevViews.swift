#if DEBUG
import AppKit

/// View-tree helpers shared by the dev checks.
@MainActor
enum DevViews {
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Frames in the root's coordinates, and any view that pokes outside the root.
    static func dumpFrames(_ root: NSView, tag: String) {
        root.layoutSubtreeIfNeeded()
        print("DEV frames \(tag): root \(root.bounds.size)")
        for view in descendants(root) where view is NSControl || view is NSScrollView {
            guard !view.isHidden, view.enclosingScrollView == nil || view is NSScrollView else { continue }
            let frame = view.convert(view.bounds, to: root)
            let label = (view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue.prefix(30).description
                ?? String(describing: type(of: view))
            let outside = root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) ? "" : "  OUTSIDE"
            print("  \(label): \(frame.integral)\(outside)")
        }
    }
}
#endif
