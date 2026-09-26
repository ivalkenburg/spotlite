import Foundation
import IOKit.pwr_mgt

/// Who is keeping the display awake. The two are independent: Spotlite's own switch
/// works regardless of what other processes hold.
struct CaffeineState: Equatable {
    /// Spotlite holds its own assertion.
    var spotlite = false
    /// A `caffeinate` process is keeping the display awake.
    var external = false

    var isActive: Bool { spotlite || external }
}

/// Keeps the display awake while active.
///
/// Uses a power assertion directly rather than spawning `/usr/bin/caffeinate`: there is
/// no child process to supervise or leak, and the assertion is released by the kernel if
/// this process dies, so a crash cannot leave the machine permanently awake.
@MainActor
final class CaffeineAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var state = CaffeineState()
    var onChange: ((CaffeineState) -> Void)?

    /// Turns Spotlite's own assertion on or off. A failed create leaves it off, so the
    /// row never shows a switch claiming the display is being held awake when it isn't.
    func toggle() {
        if state.spotlite { release() } else { acquire() }
    }

    /// Refreshes assertions owned by other processes. This is intentionally called only
    /// at lifecycle boundaries and by a coalescible status-item timer, never per keystroke.
    func refresh() {
        guard let external = CaffeineAssertion.externalCaffeinateIsActive() else { return }
        update { $0.external = external }
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
            refresh()
            return
        }
        assertionID = id
        update { $0.spotlite = true }
        refresh()
    }

    private func release() {
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            NSLog("Spotlite: could not release power assertion (\(result))")
            refresh()
            return
        }
        assertionID = IOPMAssertionID(0)
        update { $0.spotlite = false }
        refresh()
    }

    private func update(_ change: (inout CaffeineState) -> Void) {
        var updated = state
        change(&updated)
        guard updated != state else { return }
        state = updated
        onChange?(updated)
    }

    /// Whether another `caffeinate` process is keeping the display awake, as
    /// `caffeinate -d` does. Deliberately narrow: tools that only hold off system sleep
    /// (a bare `caffeinate`, or a build tool's `caffeinate -i`) leave the display free to
    /// sleep, and video players hold display assertions incidentally rather than because
    /// anyone asked for the Mac to stay awake.
    private static func externalCaffeinateIsActive() -> Bool? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let assertions = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        let typeKey = kIOPMAssertionTypeKey as String
        let levelKey = kIOPMAssertionLevelKey as String

        for (pid, rows) in assertions where pid.int32Value != ownPID {
            for row in rows where (row["Process Name"] as? String)?.lowercased() == "caffeinate" {
                if (row[levelKey] as? NSNumber)?.intValue ?? 0 > 0,
                   row[typeKey] as? String == displayType {
                    return true
                }
            }
        }
        return false
    }
}
