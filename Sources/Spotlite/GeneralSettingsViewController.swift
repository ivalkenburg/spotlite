import AppKit
import ServiceManagement

/// Shortcut, login item, menu bar icon, and Quit.
@MainActor
final class GeneralSettingsViewController: SettingsPaneController {
    private let hotKeyWarning = SettingsForm.hint(
        "That shortcut is already in use. The previous shortcut is still active.", color: .systemRed)
    private let loginItemWarning = SettingsForm.hint("", color: .systemOrange)
    private let loginItemButton = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private var hotKeyRecorder: HotKeyRecorder?

    /// A warning appearing or going changes the page's height.
    var onLayoutChange: (() -> Void)?

    override func loadView() {
        let prefs = model.preferences
        let recorder = HotKeyRecorder(keyCode: prefs.hotKeyCode, modifiers: prefs.hotKeyModifiers)
        recorder.onChange = { [weak self] code, modifiers in
            guard let self else { return false }
            let accepted = self.model.onHotKeyChange?(code, modifiers) == true
            if accepted {
                self.model.preferences.hotKeyCode = code
                self.model.preferences.hotKeyModifiers = modifiers
                self.model.persist()
            }
            self.setHidden(self.hotKeyWarning, !accepted)
            return accepted
        }
        hotKeyRecorder = recorder
        hotKeyWarning.isHidden = true

        loginItemButton.target = self
        loginItemButton.action = #selector(toggleLoginItem)

        let menuBar = NSButton(checkboxWithTitle: "Show menu bar icon", target: self,
                               action: #selector(toggleMenuBarIcon))
        menuBar.state = prefs.showMenuBarIcon ? .on : .off

        // With the menu bar icon hidden, this is the only way to quit.
        let quitButton = NSButton(title: "Quit Spotlite", target: NSApp,
                                  action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        let grid = SettingsForm.grid([
            ("Shortcut:", SettingsForm.column([recorder, hotKeyWarning])),
            ("Startup:", SettingsForm.column([loginItemButton, loginItemWarning])),
            ("Menu bar:", SettingsForm.column([
                menuBar,
                SettingsForm.hint("With the icon hidden, search “settings” in Spotlite to get back here."),
            ])),
        ])
        view = SettingsForm.page(grid, footer: quitButton)
        updateLoginItemState()
    }

    func cancelRecording() {
        hotKeyRecorder?.cancelRecording()
    }

    /// Only a page on screen reports: while it is still being built, the window has
    /// yet to fit it at all.
    private func setHidden(_ subview: NSView, _ hidden: Bool) {
        guard subview.isHidden != hidden else { return }
        subview.isHidden = hidden
        if viewIfLoaded?.window != nil { onLayoutChange?() }
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        model.set(\.showMenuBarIcon, sender.state == .on)
    }

    // MARK: - Login item

    /// SMAppService registers an absolute path. Registering from a build directory
    /// produces a login item pointing at a path that `make clean` deletes.
    private var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        guard sender.state == .off || isInstalled else {
            sender.state = .off
            updateLoginItemState()
            return
        }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Spotlite: login item change failed: \(error)")
        }
        updateLoginItemState()
    }

    /// The status changes in System Settings, so it is read again whenever the tab is
    /// shown or the window comes forward.
    func updateLoginItemState() {
        guard isViewLoaded else { return }
        let installed = isInstalled
        let status = SMAppService.mainApp.status
        loginItemButton.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        // A previously registered development copy must remain removable.
        loginItemButton.isEnabled = installed || status == .enabled || status == .requiresApproval

        switch status {
        case .requiresApproval:
            loginItemWarning.stringValue = "Allow Spotlite in System Settings › General › Login Items."
        case .notFound:
            loginItemWarning.stringValue = "macOS could not find this login item. Reinstall Spotlite in /Applications."
        default:
            loginItemWarning.stringValue = installed
                ? ""
                : "Move Spotlite to /Applications before enabling Start at login."
        }
        setHidden(loginItemWarning, loginItemWarning.stringValue.isEmpty)
    }
}
