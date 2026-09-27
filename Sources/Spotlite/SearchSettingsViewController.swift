import AppKit
import SpotliteCore

/// What results include, whether the last query comes back, and launch history.
@MainActor
final class SearchSettingsViewController: SettingsPaneController {
    private let resetHistoryButton = NSButton(title: "Reset…", target: nil, action: nil)

    private static let engines = WebSearchEngine.allCases
    /// Seconds offered for "Remember last search". Zero is Off.
    private static let retentionChoices: [TimeInterval] = [0, 5, 10, 15, 30]

    override func loadView() {
        let prefs = model.preferences

        let systemSettings = NSButton(checkboxWithTitle: "System Settings", target: self,
                                      action: #selector(toggleSystemSettings))
        systemSettings.state = prefs.showSystemSettings ? .on : .off

        let systemCommands = NSButton(checkboxWithTitle: "Commands", target: self,
                                      action: #selector(toggleSystemCommands))
        systemCommands.state = prefs.showSystemCommands ? .on : .off

        let webSearch = NSButton(checkboxWithTitle: "Web search with", target: self,
                                 action: #selector(toggleWebSearch))
        webSearch.state = prefs.showWebSearch ? .on : .off
        let enginePicker = NSPopUpButton()
        enginePicker.addItems(withTitles: Self.engines.map(\.name))
        enginePicker.selectItem(at: Self.engines.firstIndex(of: prefs.webSearchEngine) ?? 0)
        enginePicker.target = self
        enginePicker.action = #selector(engineChoiceChanged)

        let recentApps = NSButton(checkboxWithTitle: "Show recent apps", target: self,
                                  action: #selector(toggleRecentApps))
        recentApps.state = prefs.showRecentApps ? .on : .off

        let retentionPicker = NSPopUpButton()
        retentionPicker.addItems(withTitles: Self.retentionChoices.map {
            $0 > 0 ? "\(Int($0)) seconds" : "Off"
        })
        retentionPicker.selectItem(at: Self.nearestRetentionIndex(prefs.queryRetention))
        retentionPicker.target = self
        retentionPicker.action = #selector(retentionChanged)

        resetHistoryButton.target = self
        resetHistoryButton.action = #selector(confirmResetHistory)
        resetHistoryButton.bezelStyle = .rounded

        let grid = SettingsForm.grid([
            ("Include:", SettingsForm.column([
                systemSettings,
                SettingsForm.column([
                    systemCommands,
                    SettingsForm.hint("Lock Screen, Sleep, Restart and more."),
                ], spacing: 2),
                SettingsForm.row([webSearch, enginePicker], spacing: 6),
            ], spacing: 8)),
            ("Before typing:", recentApps),
            ("Remember last search:", SettingsForm.column([
                retentionPicker,
                SettingsForm.hint("Reopening Spotlite within this time brings the last query back."),
            ])),
            ("Launch history:", SettingsForm.column([
                resetHistoryButton,
                SettingsForm.hint("Apps you open often rank higher."),
            ])),
        ])
        view = SettingsForm.page(grid)
        updateHistoryState()
    }

    private static func nearestRetentionIndex(_ seconds: TimeInterval) -> Int {
        retentionChoices.indices.min { abs(retentionChoices[$0] - seconds) < abs(retentionChoices[$1] - seconds) } ?? 0
    }

    @objc private func toggleSystemSettings(_ sender: NSButton) {
        model.set(\.showSystemSettings, sender.state == .on)
    }

    @objc private func toggleSystemCommands(_ sender: NSButton) {
        model.set(\.showSystemCommands, sender.state == .on)
    }

    @objc private func toggleWebSearch(_ sender: NSButton) {
        model.set(\.showWebSearch, sender.state == .on)
    }

    @objc private func engineChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        model.set(\.webSearchEngine, Self.engines.indices.contains(index) ? Self.engines[index] : .google)
    }

    @objc private func toggleRecentApps(_ sender: NSButton) {
        model.set(\.showRecentApps, sender.state == .on)
    }

    /// Only a choice saves: an in-between value from the old slider stays as it was
    /// until one is made.
    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.retentionChoices.indices.contains(index) else { return }
        model.set(\.queryRetention, Self.retentionChoices[index])
    }

    // MARK: - Launch history

    /// Launches and per-item forgets happen while Settings is open, so this is read
    /// again whenever the tab or window comes forward.
    func updateHistoryState() {
        guard isViewLoaded else { return }
        resetHistoryButton.isEnabled = model.library.hasHistory
    }

    /// Confirmed, unlike every other setting here: the history took months of use to
    /// build and nothing can bring it back.
    @objc private func confirmResetHistory() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset launch history?"
        alert.informativeText = "Results are ranked by name alone until Spotlite learns which apps you open again."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.model.library.resetHistory()
            self.updateHistoryState()
        }
    }
}
