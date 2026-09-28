import AppKit
import SpotliteCore

/// Runs the built-in commands. Each uses the least-privileged route that works: power
/// management needs no permission, while the Apple events cost a one-time Automation
/// prompt per target app.
@MainActor
enum SystemCommandRunner {

    static func run(_ command: SystemCommand, onSuccess: @escaping @MainActor @Sendable () -> Void) {
        switch command {
        case .lockScreen:
            lockScreen(onSuccess: onSuccess)
        case .sleep:
            pmset("sleepnow", onSuccess: onSuccess)
        case .sleepDisplays:
            pmset("displaysleepnow", onSuccess: onSuccess)
        case .screenSaver:
            NSWorkspace.shared.openApplication(at: screenSaverApp,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error == nil else { return }
                Task { @MainActor in onSuccess() }
            }
        // loginwindow's own confirmation dialogs, with their countdown and a Cancel
        // button: the same thing the Apple menu shows, so no second prompt of ours.
        case .restart:
            appleEvent(#"tell application "loginwindow" to «event aevtrrst»"#,
                       target: "loginwindow", onSuccess: onSuccess)
        case .shutDown:
            appleEvent(#"tell application "loginwindow" to «event aevtrsdn»"#,
                       target: "loginwindow", onSuccess: onSuccess)
        case .logOut:
            appleEvent(#"tell application "loginwindow" to «event aevtlogo»"#,
                       target: "loginwindow", onSuccess: onSuccess)
        case .emptyTrash:
            // Finder's scripted empty doesn't ask, and nothing brings the files back.
            guard confirm("Empty the Trash?",
                          detail: "The items in the Trash will be deleted immediately. You can’t undo this.",
                          button: "Empty Trash") else { return }
            appleEvent(#"tell application "Finder" to empty trash"#,
                       target: "Finder", onSuccess: onSuccess)
        case .toggleDarkMode:
            appleEvent(#"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#,
                       target: "System Events", onSuccess: onSuccess)
        }
    }

    private static let screenSaverApp = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    /// What the Control-Command-Q shortcut calls. Private, so looked up at run time; if it
    /// ever disappears, sleeping the displays still locks when a password is required.
    private static func lockScreen(onSuccess: @escaping @MainActor @Sendable () -> Void) {
        typealias Lock = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            defer { dlclose(handle) }
            if let symbol = dlsym(handle, "SACLockScreenImmediate"),
               unsafeBitCast(symbol, to: Lock.self)() == 0 {
                onSuccess()
                return
            }
        }
        pmset("displaysleepnow", onSuccess: onSuccess)
    }

    private static func pmset(_ argument: String,
                              onSuccess: @escaping @MainActor @Sendable () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [argument]
        process.terminationHandler = { finished in
            guard finished.terminationStatus == 0 else { return }
            Task { @MainActor in onSuccess() }
        }
        do { try process.run() }
        catch { NSLog("Spotlite: could not run pmset: \(error)") }
    }

    /// Through osascript, not NSAppleScript: the first run waits on the Automation prompt,
    /// which would freeze the main thread for as long as the prompt is up.
    private static func appleEvent(_ source: String, target: String,
                                   onSuccess: @escaping @MainActor @Sendable () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else {
                Task { @MainActor in onSuccess() }
                return
            }
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // The alert's modal loop must not run inside a main-queue job, where it would
            // hold back every other job (icon loads, the panel's hide) until dismissed.
            // A run-loop block is outside the queue; the Task only wakes the run loop.
            Task { @MainActor in
                RunLoop.main.perform { MainActor.assumeIsolated { report(message, target: target) } }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Spotlite: could not run osascript: \(error)")
        }
    }

    /// -1743 is a refused Automation permission, which only System Settings can undo.
    /// Anything else, such as -128 when a dialog is cancelled, is not worth an alert.
    private static func report(_ message: String, target: String) {
        NSLog("Spotlite: command failed: \(message)")
        guard message.contains("-1743") else { return }
        let alert = NSAlert()
        alert.messageText = "Spotlite isn’t allowed to control \(target)"
        alert.informativeText = "Turn on \(target) under Spotlite in System Settings › Privacy & Security › Automation."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
