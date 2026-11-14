#if DEBUG
import AppKit
import SpotliteCore

/// Run context, last-run records, the Settings folder buttons and the debug runner,
/// against the offline diagnostics fixture.
@MainActor
enum PluginDiagnosticsDevChecks {
    static func run(library: AppLibrary, preferences: Preferences) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteDiagnosticsChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        let host = PluginHost.shared
        guard let plugin = host.plugin(id: "diagnostics") else {
            return try check(false, "Set SPOTLITE_DEV_PLUGINS_DIR to Tests/Fixtures/Plugins")
        }
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }
        }

        // The environment names the command, action, appearance, version and plain settings.
        let response = try await invoke(host, plugin, ["env"], command: "env", action: .run).get()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let expected = "env|run|\(dark ? "dark" : "light")|\(PluginHost.appVersion)|3|unset|"
        try check(response.copy == expected, "Environment gave \(response.copy ?? "nothing"), expected \(expected)")
        try check(host.lastRun(for: plugin.id)?.errorOutput == "debug note\n", "Last run lost standard error")
        print("DEV diagnostics: command, action, appearance, version and per-field settings passed")

        let failed = await invoke(host, plugin, ["fail"], command: "fail", action: .run)
        try check(failed == .failure(.failed(status: 3, message: "fatal: it broke")), "Failure gave \(failed)")
        let record = host.lastRun(for: plugin.id)
        try check(record?.failed == true && record?.status == 3 && record?.errorOutput == "starting\nfatal: it broke\n",
                  "Failure record: \(String(describing: record))")
        let invalid = await invoke(host, plugin, ["invalid"], command: "invalid", action: .list)
        guard case .failure(.invalidOutput(let detail)) = invalid, detail.contains("Output began: not json") else {
            return try check(false, "Invalid output gave \(invalid)")
        }
        print("DEV diagnostics: stderr tail, last error line and invalid JSON detail passed")

        let selectedTab = UserDefaults.standard.object(forKey: "SettingsSelectedTab")
        let settings = SettingsWindowController(preferences: preferences, library: library)
        var settingsWindow: NSWindow?
        defer {
            settingsWindow?.close()
            if let selectedTab { UserDefaults.standard.set(selectedTab, forKey: "SettingsSelectedTab") }
            else { UserDefaults.standard.removeObject(forKey: "SettingsSelectedTab") }
        }
        settings.show(apps: library.entries)
        let pane = settings.devShowPlugins()
        try await Task.sleep(for: .milliseconds(300))
        settingsWindow = pane.view.window
        let views = DevViews.descendants(pane.view)
        let table = views.compactMap { $0 as? NSTableView }.first!
        // The per-plugin actions live in the More menu, enabled by validation as it opens.
        guard let more = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "More" }) else {
            return try check(false, "No More menu")
        }
        func items() -> [NSMenuItem] {
            more.menu!.update()
            return ["Run Command…", "Reveal in Finder", "Open Data Folder", "Open Plugins Folder"].map { more.menu!.item(withTitle: $0)! }
        }
        table.deselectAll(nil)
        try check(items().prefix(3).allSatisfy { !$0.isEnabled } && items()[3].isEnabled,
                  "Plugin actions enabled without a selection")
        let row = PluginHost.shared.plugins.firstIndex { $0.id == plugin.id }!
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try check(items().allSatisfy(\.isEnabled), "Plugin actions disabled with a selection")
        try check(table.menu?.items.map(\.title) == ["Configure…", "Run Command…", "Reveal in Finder", "Open Data Folder", "", "Remove…"],
                  "Row menu: \(table.menu?.items.map(\.title) ?? [])")
        let lastRun = views.compactMap { $0 as? NSTextView }.first { $0.enclosingScrollView?.accessibilityLabel() == "Last run" }!
        let title = views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Last error ·") }
        try check(title != nil && lastRun.string.contains("invalid · list · invalid") && lastRun.string.contains("not json"),
                  "Last run area shows: \(lastRun.string)")
        // A run that finishes while Settings is open replaces what it shows.
        _ = await invoke(host, plugin, ["env"], command: "env", action: .run)
        try check(lastRun.string.hasPrefix("env · run · env\nexit 0"), "Last run did not refresh: \(lastRun.string)")
        DevViews.dumpFrames(pane.view, tag: "plugins-pane")
        if let window = settingsWindow { try await SettingsForm.captureWindow(window, name: "plugins-pane") }
        print("DEV diagnostics: Settings actions and last run passed")

        // The debug runner shows raw output and applies nothing.
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        more.menu!.performActionForItem(at: more.menu!.indexOfItem(withTitle: "Run Command…"))
        try await Task.sleep(for: .milliseconds(300))
        guard let sheet = settingsWindow?.attachedSheet else { return try check(false, "Run… did not open a sheet") }
        let controls = DevViews.descendants(sheet.contentView!)
        let picker = controls.compactMap { $0 as? NSPopUpButton }.first!
        let query = controls.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        let runButton = controls.compactMap { $0 as? NSButton }.first { $0.title == "Run" }!
        let identified = { (id: String) in controls.first { $0.identifier?.rawValue == id } }
        let texts = [identified("stdout") as! NSTextView, identified("stderr") as! NSTextView]
        let status = identified("status") as! NSTextField
        try check(picker.itemTitles == ["Diagnostics Env (run)", "Diagnostics Fail (run)", "Diagnostics Invalid (list)",
                                        "Diagnostics Slow (search)"], "Runner offers \(picker.itemTitles)")
        sheet.makeFirstResponder(query)
        if let editor = query.currentEditor() as? NSTextView {
            editor.insertText("unsent query", replacementRange: editor.selectedRange())
        }
        sheet.makeFirstResponder(picker)
        try await Task.sleep(for: .milliseconds(100))
        try check(status.stringValue.isEmpty && runButton.title == "Run" && texts[0].string.isEmpty,
                  "Leaving the query field started a command")
        query.stringValue = "typed"
        runButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(500))
        try check(status.stringValue.contains("exit 0") && status.stringValue.contains("Valid response: toast, copy"),
                  "Runner status: \(status.stringValue)")
        try check(texts[0].string.contains("\"copy\" : \"env|run|") && texts[0].string.contains("|typed\""),
                  "Runner output: \(texts[0].string)")
        try check(texts[1].string == "debug note\n", "Runner stderr: \(texts[1].string)")
        try check(pasteboard.string(forType: .string) == "untouched", "The debug runner applied the response")
        DevViews.dumpFrames(sheet.contentView!, tag: "debug-runner")
        try await SettingsForm.captureWindow(sheet, name: "debug-runner")

        picker.selectItem(at: 2)
        runButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(500))
        try check(status.stringValue.contains("invalid JSON") && status.stringValue.contains("Output began: not json"),
                  "Invalid status: \(status.stringValue)")
        try await SettingsForm.captureWindow(sheet, name: "debug-runner-invalid")

        // Stop and Close both end a run that would otherwise take ten seconds.
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spotlite-diagnostics-slow.pid")
        func slowRun() async throws -> pid_t {
            try? FileManager.default.removeItem(at: pidFile)
            picker.selectItem(at: 3)
            runButton.performClick(nil)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(50))
            return pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        var pid = try await slowRun()
        try check(runButton.title == "Stop", "Running did not offer Stop")
        runButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(1_500))
        try check(pid > 0 && kill(pid, 0) == -1, "Stop left the plugin running")
        try check(status.stringValue == "Stopped." && runButton.title == "Run", "Stop status: \(status.stringValue)")

        weak var released: NSWindowController? = sheet.windowController
        pid = try await slowRun()
        controls.compactMap { $0 as? NSButton }.first { $0.title == "Close" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(1_500))
        try check(settingsWindow?.attachedSheet == nil, "Close left the sheet open")
        try check(released == nil, "Closing kept the runner alive")
        try check(pid > 0 && kill(pid, 0) == -1, "Close left the plugin running")
        try? FileManager.default.removeItem(at: pidFile)
        print("DEV diagnostics: debug runner output, no side effects, Stop and Close passed")
    }

    private static func invoke(_ host: PluginHost, _ plugin: InstalledPlugin, _ arguments: [String],
                               command: String, action: PluginRunAction) async -> Result<PluginResponse, PluginRunError> {
        await withCheckedContinuation { continuation in
            host.run(plugin, arguments: arguments, query: "", command: command, action: action) {
                continuation.resume(returning: $0)
            }
        }
    }
}
#endif
