import AppKit
import SpotliteCore

/// Theme, glass tint, the running-app dot, how many rows show, and where the panel opens.
@MainActor
final class AppearanceSettingsViewController: SettingsPaneController {
    /// Popup order of the Theme menu.
    private static let themeModes: [ThemeMode] = [.system, .light, .dark]

    override func loadView() {
        let prefs = model.preferences

        let themePicker = NSPopUpButton()
        themePicker.addItems(withTitles: ["System", "Light", "Dark"])
        themePicker.selectItem(at: Self.themeModes.firstIndex(of: prefs.themeMode) ?? 0)
        themePicker.target = self
        themePicker.action = #selector(themeChoiceChanged)

        let tintSlider = NSSlider(value: prefs.glassTint, minValue: 0, maxValue: 1,
                                  target: self, action: #selector(tintChanged))
        // Saved once on release rather than on every step of the drag.
        tintSlider.isContinuous = false
        tintSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let clearLabel = NSTextField(labelWithString: "Clear")
        let solidLabel = NSTextField(labelWithString: "Solid")
        for end in [clearLabel, solidLabel] {
            end.font = .systemFont(ofSize: 11)
            end.textColor = .secondaryLabelColor
        }

        let runningIndicator = NSButton(checkboxWithTitle: "Mark running apps with a dot", target: self,
                                        action: #selector(toggleRunningIndicator))
        runningIndicator.state = prefs.showRunningIndicator ? .on : .off

        let rowsPicker = NSPopUpButton()
        rowsPicker.addItems(withTitles: Preferences.visibleRowsRange.map(String.init))
        rowsPicker.selectItem(at: prefs.visibleRows - Preferences.visibleRowsRange.lowerBound)
        rowsPicker.target = self
        rowsPicker.action = #selector(visibleRowsChanged)

        let screenPicker = NSPopUpButton()
        screenPicker.addItems(withTitles: ["Display with pointer", "Main display"])
        screenPicker.selectItem(at: prefs.panelScreen == .primary ? 1 : 0)
        screenPicker.target = self
        screenPicker.action = #selector(screenChoiceChanged)

        let resetButton = NSButton(title: "Reset Size & Position", target: self,
                                   action: #selector(resetGeometry))
        resetButton.bezelStyle = .rounded

        let grid = SettingsForm.grid([
            ("Theme:", themePicker),
            ("Tint:", SettingsForm.row([clearLabel, tintSlider, solidLabel])),
            ("Results:", runningIndicator),
            ("Rows shown:", rowsPicker),
            ("Open on:", screenPicker),
            ("Panel:", resetButton),
        ])
        view = SettingsForm.page(grid)
    }

    @objc private func themeChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        model.set(\.themeMode, Self.themeModes.indices.contains(index) ? Self.themeModes[index] : .system)
    }

    @objc private func tintChanged(_ sender: NSSlider) {
        model.set(\.glassTint, sender.doubleValue)
    }

    @objc private func toggleRunningIndicator(_ sender: NSButton) {
        model.set(\.showRunningIndicator, sender.state == .on)
    }

    @objc private func visibleRowsChanged(_ sender: NSPopUpButton) {
        model.set(\.visibleRows, sender.indexOfSelectedItem + Preferences.visibleRowsRange.lowerBound)
    }

    @objc private func screenChoiceChanged(_ sender: NSPopUpButton) {
        model.set(\.panelScreen, sender.indexOfSelectedItem == 1 ? .primary : .followPointer)
    }

    /// The way back from a panel dragged somewhere unusable. Without it the only
    /// recovery is editing JSON by hand.
    @objc private func resetGeometry() {
        model.set(\.panelGeometry, .default)
    }
}
