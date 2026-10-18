import CoreGraphics

/// Toast placement is independent of the launcher's size and position.
public enum ToastPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }

    /// Cocoa screen coordinates, including displays left of or below the main one.
    /// On small displays, reduce the margin before letting the toast escape the screen.
    public func frame(for size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let width = min(max(0, size.width), visibleFrame.width)
        let height = min(max(0, size.height), visibleFrame.height)
        let insetX = min(48, (visibleFrame.width - width) / 2)
        let insetY = min(48, (visibleFrame.height - height) / 2)
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = visibleFrame.minX + insetX
        case .topCenter, .bottomCenter: x = visibleFrame.midX - width / 2
        case .topRight, .bottomRight: x = visibleFrame.maxX - insetX - width
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight: y = visibleFrame.maxY - insetY - height
        case .bottomLeft, .bottomCenter, .bottomRight: y = visibleFrame.minY + insetY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
