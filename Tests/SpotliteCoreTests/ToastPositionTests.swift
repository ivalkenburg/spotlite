import CoreGraphics
import Testing
@testable import SpotliteCore

@Suite("Toast placement")
struct ToastPositionTests {
    @Test func positionsRespectVisibleEdgesOnAnOffsetDisplay() {
        // A secondary display left of and below the primary, with Dock/menu bar excluded.
        let visible = CGRect(x: -1920, y: -240, width: 1920, height: 1055)
        let size = CGSize(width: 300, height: 44)
        let expected: [(ToastPosition, CGPoint)] = [
            (.topLeft, CGPoint(x: -1872, y: 723)),
            (.topCenter, CGPoint(x: -1110, y: 723)),
            (.topRight, CGPoint(x: -348, y: 723)),
            (.bottomLeft, CGPoint(x: -1872, y: -192)),
            (.bottomCenter, CGPoint(x: -1110, y: -80)),
            (.bottomRight, CGPoint(x: -348, y: -192)),
        ]
        for (position, origin) in expected {
            let frame = position.frame(for: size, in: visible)
            #expect(frame.origin == origin)
            #expect(frame.size == size)
            #expect(visible.contains(frame))
        }
    }

    @Test func smallDisplaysReduceMarginsAndClampOversizedToasts() {
        let visible = CGRect(x: 1200, y: 50, width: 320, height: 90)
        for position in ToastPosition.allCases {
            let fitted = position.frame(for: CGSize(width: 300, height: 60), in: visible)
            #expect(fitted == CGRect(x: 1210, y: 65, width: 300, height: 60))
            #expect(position.frame(for: CGSize(width: 900, height: 200), in: visible) == visible)
        }
    }
}
