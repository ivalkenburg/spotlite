import AppKit
import IOKit.pwr_mgt
import SpotliteCore

/// Spotlite's session and external assertions keep the display awake independently.
struct CaffeineState: Equatable {
    /// Spotlite holds its own assertion.
    var session: CaffeineSession?
    var spotlite: Bool { session != nil }
    /// A `caffeinate` process is keeping the display awake.
    var external = false

    var isActive: Bool { spotlite || external }

    var sessionDescription: String? {
        guard let session else { return nil }
        if let deadline = session.deadline {
            return "Active until \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        return "Active until turned off"
    }
}

/// Keeps the display awake while active.
///
/// Uses a power assertion directly rather than spawning `/usr/bin/caffeinate`: there is
/// no child process to supervise or leak, and the assertion is released by the kernel if
/// this process dies, so a crash cannot leave the machine permanently awake.
@MainActor
final class CaffeineAssertion: NSObject {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var expirationTimer: DispatchSourceTimer?
    private(set) var state = CaffeineState()
    var onChange: ((CaffeineState) -> Void)?
    var onExpiration: ((_ succeeded: Bool, _ state: CaffeineState) -> Void)?

    #if DEBUG
    /// Development checks toggle an indefinite session.
    @discardableResult
    func toggle() -> Bool {
        state.spotlite ? stop() : start(.untilTurnedOff)
    }
    #endif

    /// Renewing an active session reuses its assertion and replaces the deadline.
    @discardableResult
    func start(_ duration: CaffeineDuration, now: Date = Date()) -> Bool {
        guard state.spotlite || acquire() else { return false }
        update { $0.session = CaffeineSession(duration: duration, now: now) }
        scheduleExpiration()
        refresh()
        return true
    }

    @discardableResult
    func stop() -> Bool {
        guard state.spotlite else { return true }
        let succeeded = releaseAssertion()
        if succeeded { refreshExternalState() }
        return succeeded
    }

    private func releaseAssertion() -> Bool {
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            NSLog("Spotlite: could not release power assertion (\(result))")
            return false
        }
        assertionID = IOPMAssertionID(0)
        cancelExpiration()
        update { $0.session = nil }
        return true
    }

    /// Refreshes assertions owned by other processes. This is intentionally called only
    /// at lifecycle boundaries and by a coalescible status-item timer, never per keystroke.
    func refresh() {
        if !expireIfNeeded() { refreshExternalState() }
    }

    private func refreshExternalState() {
        guard let external = CaffeineAssertion.externalCaffeinateIsActive() else { return }
        update { $0.external = external }
    }

    private func acquire() -> Bool {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Spotlite caffeinate" as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            NSLog("Spotlite: could not create power assertion (\(result))")
            return false
        }
        assertionID = id
        return true
    }

    private func scheduleExpiration() {
        cancelExpiration()
        guard let deadline = state.session?.deadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let seconds = deadline.timeIntervalSince1970
        let wallDeadline = DispatchWallTime(timespec: timespec(
            tv_sec: Int(seconds), tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000)))
        timer.schedule(wallDeadline: wallDeadline, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expireIfNeeded()
                // A clock adjustment or early delivery must not lose the deadline.
                if self.state.session?.deadline != nil { self.scheduleExpiration() }
            }
        }
        expirationTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        timer.resume()
    }

    private func cancelExpiration() {
        expirationTimer?.cancel()
        expirationTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { refresh() }

    /// Handles an expired session and refreshes external state before reporting it.
    /// Returns true when expiration was handled, including a failed release.
    @discardableResult
    func expireIfNeeded(now: Date = Date()) -> Bool {
        guard state.session?.hasExpired(at: now) == true else { return false }
        let succeeded = releaseAssertion()
        if !succeeded {
            // Keep the still-held assertion visible, but report the failure once.
            cancelExpiration()
            update { $0.session = CaffeineSession(duration: .untilTurnedOff) }
        }
        refreshExternalState()
        onExpiration?(succeeded, state)
        return true
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
