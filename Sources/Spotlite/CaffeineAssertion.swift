import Foundation
import IOKit.pwr_mgt

enum CaffeineState: Equatable {
    case inactive
    case spotlite
    case external

    var isActive: Bool { self != .inactive }
}

/// Keeps the display awake while active.
///
/// Uses a power assertion directly rather than spawning `/usr/bin/caffeinate`: there is
/// no child process to supervise or leak, and the assertion is released by the kernel if
/// this process dies, so a crash cannot leave the machine permanently awake.
@MainActor
final class CaffeineAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var ownsAssertion = false
    private var externalIsActive = false
    private(set) var state: CaffeineState = .inactive
    var onChange: ((CaffeineState) -> Void)?

    /// - Returns: whether the assertion is active afterwards. A failed create leaves it
    ///   off, so the row never shows a switch claiming the machine is being held awake
    ///   when it isn't.
    @discardableResult
    func toggle() -> CaffeineState {
        if ownsAssertion { release() }
        else if state == .inactive { acquire() }
        return state
    }

    /// Refreshes assertions owned by other processes. This is intentionally called only
    /// at lifecycle boundaries and by a coalescible status-item timer, never per keystroke.
    func refresh() {
        guard let externalIsActive = CaffeineAssertion.relevantExternalAssertionState() else {
            return
        }
        self.externalIsActive = externalIsActive
        updateState(externalIsActive: externalIsActive)
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
        ownsAssertion = true
        updateState(externalIsActive: externalIsActive)
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
        ownsAssertion = false
        updateState(externalIsActive: externalIsActive)
        refresh()
    }

    private func updateState(externalIsActive: Bool) {
        let updated: CaffeineState = ownsAssertion ? .spotlite : (externalIsActive ? .external : .inactive)
        guard updated != state else { return }
        state = updated
        onChange?(updated)
    }

    /// Detects display-sleep assertions from any process and explicit `/usr/bin/caffeinate`
    /// system-sleep assertions. The latter excludes automatic assertions such as powerd's
    /// always-on "prevent sleep while display is on" entry.
    private static func relevantExternalAssertionState() -> Bool? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let assertions = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        let idleSystemType = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        let systemType = kIOPMAssertionTypePreventSystemSleep as String
        let typeKey = kIOPMAssertionTypeKey as String
        let levelKey = kIOPMAssertionLevelKey as String

        for (pid, rows) in assertions where pid.int32Value != ownPID {
            for row in rows {
                guard (row[levelKey] as? NSNumber)?.intValue ?? 0 > 0,
                      let type = row[typeKey] as? String else { continue }
                if type == displayType { return true }

                let processName = (row["Process Name"] as? String)?.lowercased()
                if processName == "caffeinate", type == idleSystemType || type == systemType {
                    return true
                }
            }
        }
        return false
    }
}
