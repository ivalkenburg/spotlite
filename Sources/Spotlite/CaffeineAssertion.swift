import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while active.
///
/// Uses a power assertion directly rather than spawning `/usr/bin/caffeinate`: there is
/// no child process to supervise or leak, and the assertion is released by the kernel if
/// this process dies, so a crash cannot leave the machine permanently awake.
@MainActor
final class CaffeineAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var isActive = false

    /// - Returns: whether the assertion is active afterwards. A failed create leaves it
    ///   off, so the row never shows a switch claiming the machine is being held awake
    ///   when it isn't.
    @discardableResult
    func toggle() -> Bool {
        isActive ? release() : acquire()
        return isActive
    }

    private func acquire() {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Spotlite caffeinate" as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            NSLog("Spotlite: could not create power assertion (\(result))")
            return
        }
        assertionID = id
        isActive = true
    }

    private func release() {
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }
}
