import AppKit
import SpotliteCore

/// What results include, whether the last query comes back, and launch history.
@MainActor
final class SearchSettingsViewController: SettingsPaneController {
    private let resetHistoryButton = NSButton(title: "Reset…", target: nil, action: nil)

    private var directoriesView: ApplicationDirectoriesView?

    private static let engines = WebSearchEngine.allCases
    private static let webSearchModes = WebSearchMode.allCases
    private static let completionModes: [AppNameCompletion] = [.off, .prefixOnly, .allMatches]
    private let enginePicker = NSPopUpButton()
    /// Seconds offered for "Remember last search". Zero is Off.
    private static let retentionChoices: [TimeInterval] = [0, 5, 10, 15, 30]
    private static let backNavigationChoices: [BackNavigationBehavior] = [.restoreQuery, .clearQuery]

    override func loadView() {
        let prefs = model.preferences

        let systemSettings = NSButton(checkboxWithTitle: "System Settings", target: self,
                                      action: #selector(toggleSystemSettings))
        systemSettings.state = prefs.showSystemSettings ? .on : .off

        let systemCommands = NSButton(checkboxWithTitle: "Commands", target: self,
                                      action: #selector(toggleSystemCommands))
        systemCommands.state = prefs.showSystemCommands ? .on : .off

        let webSearch = NSPopUpButton()
        webSearch.addItems(withTitles: Self.webSearchModes.map(\.title))
        webSearch.selectItem(at: Self.webSearchModes.firstIndex(of: prefs.webSearchMode) ?? 1)
        webSearch.target = self
        webSearch.action = #selector(webSearchModeChanged)
        enginePicker.addItems(withTitles: Self.engines.map(\.name))
        enginePicker.selectItem(at: Self.engines.firstIndex(of: prefs.webSearchEngine) ?? 0)
        enginePicker.target = self
        enginePicker.action = #selector(engineChoiceChanged)
        enginePicker.isEnabled = prefs.webSearchMode != .off

        let recentApps = NSButton(checkboxWithTitle: "Show frequently used apps", target: self,
                                  action: #selector(toggleRecentApps))
        recentApps.state = prefs.showRecentApps ? .on : .off

        let completionPicker = NSPopUpButton()
        completionPicker.addItems(withTitles: ["Off", "Prefix matches only", "All matches"])
        completionPicker.selectItem(at: Self.completionModes.firstIndex(of: prefs.appNameCompletion) ?? 2)
        completionPicker.target = self
        completionPicker.action = #selector(completionChoiceChanged)

        let retentionPicker = NSPopUpButton()
        retentionPicker.addItems(withTitles: Self.retentionChoices.map {
            $0 > 0 ? "\(Int($0)) seconds" : "Off"
        })
        retentionPicker.selectItem(at: Self.nearestRetentionIndex(prefs.queryRetention))
        retentionPicker.target = self
        retentionPicker.action = #selector(retentionChanged)

        let backNavigationPicker = NSPopUpButton()
        backNavigationPicker.addItems(withTitles: ["Restore previous query", "Clear query"])
        backNavigationPicker.selectItem(at: Self.backNavigationChoices.firstIndex(of: prefs.backNavigationBehavior) ?? 0)
        backNavigationPicker.target = self
        backNavigationPicker.action = #selector(backNavigationChanged)

        resetHistoryButton.target = self
        resetHistoryButton.action = #selector(confirmResetHistory)
        resetHistoryButton.bezelStyle = .rounded

        let directories = ApplicationDirectoriesView(model: model)
        directoriesView = directories
        let grid = SettingsForm.grid([
            ("App locations:", directories),
            ("Include:", SettingsForm.column([
                systemSettings,
                SettingsForm.column([
                    systemCommands,
                    SettingsForm.hint("Lock Screen, Sleep, Restart and more."),
                ], spacing: 2),
            ], spacing: 8)),
            ("Web search:", SettingsForm.column([
                webSearch,
                SettingsForm.row([NSTextField(labelWithString: "Engine:"), enginePicker]),
            ])),
            ("Before typing:", recentApps),
            ("App name completion:", completionPicker),
            ("Remember last search:", SettingsForm.column([
                retentionPicker,
                SettingsForm.hint("Reopening Spotlite within this time brings the last query back."),
            ])),
            ("When going back:", SettingsForm.column([
                backNavigationPicker,
                SettingsForm.hint("Backspace on empty input or Shift-Tab returns to the previous level."),
            ])),
            ("Launch history:", SettingsForm.column([
                resetHistoryButton,
                SettingsForm.hint("Apps you open often rank higher."),
            ])),
        ])
        // A directory list has no text baseline. Baseline alignment lifts its label
        // above the list; align the two cell tops instead.
        grid.row(at: 0).rowAlignment = .none
        grid.row(at: 0).yPlacement = .top
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

    @objc private func webSearchModeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.webSearchModes.indices.contains(index) else { return }
        let mode = Self.webSearchModes[index]
        enginePicker.isEnabled = mode != .off
        model.set(\.webSearchMode, mode)
    }

    @objc private func completionChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.completionModes.indices.contains(index) else { return }
        model.set(\.appNameCompletion, Self.completionModes[index])
    }

    @objc private func engineChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        model.set(\.webSearchEngine, Self.engines.indices.contains(index) ? Self.engines[index] : .default)
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

    @objc private func backNavigationChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.backNavigationChoices.indices.contains(index) else { return }
        model.set(\.backNavigationBehavior, Self.backNavigationChoices[index])
    }

    // MARK: - Launch history

    /// Launches and per-item forgets happen while Settings is open, so this is read
    /// again whenever the tab or window comes forward.
    func updateHistoryState() {
        guard isViewLoaded else { return }
        directoriesView?.reload()
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
