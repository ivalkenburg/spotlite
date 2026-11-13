#if DEBUG
import AppKit
import SpotliteCore

/// Native integration checks use an isolated settings directory and offline fixtures.
@MainActor
enum PluginConfigurationDevChecks {
    static func run(controller: SpotliteController, library: AppLibrary, preferences: Preferences) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        guard ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGIN_SETTINGS_DIR"] != nil,
              let plugin = PluginHost.shared.plugin(id: "configuration") else {
            throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Set SPOTLITE_DEV_PLUGIN_SETTINGS_DIR to a scratch directory and SPOTLITE_DEV_PLUGINS_DIR to Tests/Fixtures/Plugins"])
        }
        let host = PluginHost.shared
        try host.resetConfiguration(for: plugin)
        let selectedTab = UserDefaults.standard.object(forKey: "SettingsSelectedTab")
        defer {
            if let selectedTab { UserDefaults.standard.set(selectedTab, forKey: "SettingsSelectedTab") }
            else { UserDefaults.standard.removeObject(forKey: "SettingsSelectedTab") }
            try? host.resetConfiguration(for: plugin)
        }
        try check(host.needsSetup(plugin.id), "Missing required settings did not require setup")
        var blocked: Result<PluginResponse, PluginRunError>?
        let run = host.run(plugin, arguments: [], query: "") { blocked = $0 }
        try check(run == nil && blocked == .failure(.configurationRequired), "Unconfigured plugin started a process")

        let settings = SettingsWindowController(preferences: preferences, library: library)
        var requested: String?
        controller.runDevSetupRoutingCheck(plugin: plugin) { id in
            requested = id
            settings.show(apps: library.entries)
            settings.configurePlugin(id: id)
        }
        try await Task.sleep(for: .milliseconds(300))
        try check(requested == plugin.id, "Command did not route to configuration")
        let sheet = try requireSheet()
        try check(sheet.sheetParent != nil, "Configure did not open a sheet")
        let inputs = descendants(sheet.contentView!).compactMap { $0 as? NSControl }
        let name = inputs.first { $0.identifier?.rawValue == "copy" } as! NSTextField
        let limit = inputs.first { $0.identifier?.rawValue == "limit" } as! NSTextField
        let toggle = inputs.first { $0.identifier?.rawValue == "enabled" } as! NSButton
        let choice = inputs.first { $0.identifier?.rawValue == "format" } as! NSPopUpButton
        let save = inputs.compactMap { $0 as? NSButton }.first { $0.title == "Save" }!
        let cancel = inputs.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
        try check(!save.isEnabled && toggle.state == .on && choice.titleOfSelectedItem == "Brief",
                  "Initial form state is wrong: save=\(save.isEnabled), toggle=\(toggle.state.rawValue), choice=\(choice.titleOfSelectedItem ?? "nil"), name=\(name.stringValue)")
        try await capture(sheet, name: "plugin-configuration-required")
        edit(name, text: "Alpha")
        edit(limit, text: "99")
        try check(!save.isEnabled, "Out-of-range number enabled Save")
        try await capture(sheet, name: "plugin-configuration-invalid")
        edit(limit, text: "3")
        try check(!choice.itemTitles.contains("Choose…"), "A defaulted choice offered an ambiguous placeholder")
        choice.selectItem(at: 1)
        choice.sendAction(choice.action, to: choice.target)
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        try check(save.isEnabled, "Valid configuration did not enable Save")
        cancel.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try check(host.needsSetup(plugin.id), "Cancel persisted draft settings")

        settings.configurePlugin(id: plugin.id)
        try await Task.sleep(for: .milliseconds(200))
        let second = try requireSheet()
        let secondInputs = descendants(second.contentView!).compactMap { $0 as? NSControl }
        let secondName = secondInputs.first { $0.identifier?.rawValue == "copy" } as! NSTextField
        try check(secondName.stringValue.isEmpty, "Cancelled values returned on reopening")
        edit(secondName, text: "Alpha")
        for (tag, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            second.appearance = NSAppearance(named: appearance)
            try await capture(second, name: "plugin-configuration-\(tag)")
        }
        let parent = second.sheetParent
        second.makeFirstResponder(secondName)
        let returnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: second.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(returnEvent)
        try await Task.sleep(for: .milliseconds(250))
        try check(!host.needsSetup(plugin.id) && parent?.attachedSheet == nil, "Save did not finish setup")
        let values = host.configuration(for: plugin).values
        try check(values["copy"] == .string("Alpha") && values["limit"] == .number(5)
                  && values["enabled"] == .boolean(true) && values["format"] == .string("brief"), "Defaults lost their types")

        // Starting and then saving different values must leave the first process's snapshot intact.
        var changed = values
        changed["copy"] = .string("Beta")
        let firstResponse: PluginResponse = try await withCheckedThrowingContinuation { continuation in
            let run = host.run(plugin, arguments: ["slow"], query: "") {
                continuation.resume(with: $0.mapError { $0 as any Error })
            }
            do { try host.saveConfiguration(changed, for: plugin) }
            catch { run?.cancel(); continuation.resume(throwing: error) }
        }
        try check(firstResponse.copy == "Alpha", "A running process saw later settings")
        let nextResponse = try await invoke(host, plugin: plugin)
        try check(nextResponse.copy == "Beta", "Next invocation missed saved settings")
        host.reload()
        try check(host.configuration(for: plugin).values["copy"] == .string("Beta"), "Reload lost saved settings")

        // External changes are deliberately picked up on Reload, never while matching.
        let stored = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGIN_SETTINGS_DIR"]!)
            .appendingPathComponent("configuration.json")
        try Data(#"{"copy":"Beta","limit":99,"enabled":"old type","format":"removed choice"}"#.utf8).write(to: stored)
        try check(!host.needsSetup(plugin.id), "Checking readiness unexpectedly reread the disk")
        host.reload()
        try check(host.needsSetup(plugin.id) && host.configuration(for: plugin).errors.count == 3,
                  "Reload did not revalidate incompatible settings")
        settings.configurePlugin(id: plugin.id)
        try await Task.sleep(for: .milliseconds(200))
        let resetSheet = try requireSheet()
        let migrated = descendants(resetSheet.contentView!).compactMap { $0 as? NSControl }
        try check((migrated.first { $0.identifier?.rawValue == "format" } as? NSPopUpButton)?.titleOfSelectedItem
                    == "Unavailable: removed choice", "Unavailable saved choice was hidden")
        try check((migrated.first { $0.identifier?.rawValue == "enabled" } as? NSButton)?.state == .mixed,
                  "Incompatible saved boolean appeared valid")
        try await capture(resetSheet, name: "plugin-configuration-migration")
        descendants(resetSheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset Settings…" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        try check(resetSheet.attachedSheet != nil, "Reset did not ask before removing saved values")
        let resetAlert = resetSheet.attachedSheet!
        descendants(resetAlert.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset Settings" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try check(host.needsSetup(plugin.id), "Reset did not clear required settings")
        descendants(resetSheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try Data("{".utf8).write(to: stored)
        host.reload()
        try check(host.configuration(for: plugin).problem != nil && host.needsSetup(plugin.id),
                  "Corrupt settings did not require recovery")
        settings.configurePlugin(id: plugin.id)
        try await Task.sleep(for: .milliseconds(200))
        let recovery = try requireSheet()
        try await capture(recovery, name: "plugin-configuration-recovery")
        descendants(recovery.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        if let parent {
            try await checkLongForm(on: parent)
            try await Task.sleep(for: .milliseconds(250))
            try await checkChoiceLabels(on: parent)
        }
        parent?.orderOut(nil)
        try checkCommandUpdates()
        print("DEV configuration: setup routing, validation, Cancel, keyboard Save, defaults, snapshots, schema revalidation and Reset passed")
    }

    private static func checkCommandUpdates() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteUpdates-" + UUID().uuidString)
        let folder = root.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var commands: [[String: Any]] = (0..<500).map { index in
            ["id": "c\(index)", "title": "Command \(index)", "subtitle": "Original \(index)",
             "action": ["type": "copy", "text": String(index)]]
        }
        func writeManifest() throws {
            let manifest: [String: Any] = ["id": "batch", "name": "Batch Updates", "commands": commands]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
        }
        func changes(_ values: [[String: Any]]) throws -> [PluginCommandUpdate] {
            try JSONDecoder().decode([PluginCommandUpdate].self, from: JSONSerialization.data(withJSONObject: values))
        }
        try writeManifest()
        let host = PluginHost(directory: root, configurationStore: PluginConfigurationStore(directory: root.appendingPathComponent("values")))
        let original = host.plugin(id: "batch")!
        var batch: [[String: Any]] = (0..<500).map { ["command": "c\($0)", "subtitle": "Batch \($0)", "icon": "star"] }
        batch += [["command": "new-command", "subtitle": "Unknown"], ["command": "c5", "subtitle": "Last duplicate"],
                  ["command": "c6"], ["command": "c7", "subtitle": "Expired", "expires": 0]]
        host.apply(try changes(batch), from: original)
        for index in 0..<500 {
            let expected = index == 5 ? "Last duplicate" : ([6, 7].contains(index) ? "Original \(index)" : "Batch \(index)")
            try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c\(index)")) == expected,
                       "Batch update changed ordering, reset or expiry behavior for command \(index)")
        }
        try expect(host.icon(forEntryID: original.entryID(forCommandID: "c0")) == .symbol("star"), "Batch icon update was lost")

        // A response from an in-flight invocation belongs to the manifest it started with.
        commands.removeFirst()
        commands.append(["id": "new-command", "title": "New command", "subtitle": "Original new",
                         "action": ["type": "copy", "text": "new"]])
        try writeManifest()
        host.reload()
        let newID = original.entryID(forCommandID: "new-command")
        try expect(host.subtitle(forEntryID: newID) == "Original new", "Unknown update survived a later manifest reload")
        var captured: [[String: Any]] = (0..<500).map { ["command": "c\($0)", "subtitle": "Captured \($0)"] }
        captured.append(["command": "new-command", "subtitle": "Wrong manifest"])
        host.apply(try changes(captured), from: original)
        try expect(host.subtitle(forEntryID: newID) == "Original new", "Batch lookup used the new manifest for an old response")
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c1")) == "Captured 1", "Captured manifest updates were lost")
        host.apply(try changes([["command": "c1"]]), from: original)
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c1")) == "Original 1", "Single-update reset changed behavior")
        host.apply(try changes([["command": "c2", "subtitle": "First"], ["command": "c2", "subtitle": "Second"]]), from: original)
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c2")) == "Second", "Small-batch duplicate ordering changed")
        print("DEV configuration: single/batch command updates preserve unknown, duplicate, reset, expiry and captured-manifest behavior")
    }

    private static func checkChoiceLabels(on parent: NSWindow) async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteChoiceLabels-" + UUID().uuidString)
        let folder = root.appendingPathComponent("choices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"""
        {"id":"choices","name":"Choice Labels Fixture","commands":[],"settings":[
          {"id":"duplicate","label":"Duplicate labels","type":"choice","default":"a","options":[
            {"value":"a","label":"Same"},{"value":"b","label":"Same"},{"value":"c","label":"Unavailable: missing"}]},
          {"id":"optional","label":"Optional choice","type":"choice","options":[
            {"value":"none-option","label":"None"},{"value":"other","label":"Other"}]},
          {"id":"required","label":"Required choice","type":"choice","required":true,"options":[
            {"value":"choose-option","label":"Choose…"},{"value":"other","label":"Other"}]}]}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("plugin.json"))
        let store = PluginConfigurationStore(directory: root.appendingPathComponent("values"))
        let host = PluginHost(directory: root, configurationStore: store)
        let plugin = host.plugin(id: "choices")!
        let editor = PluginConfigurationWindowController(plugin: plugin, host: host)
        let window = editor.window!
        parent.beginSheet(window, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        let pickers = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }
        let duplicate = pickers.first { $0.identifier?.rawValue == "duplicate" }!
        let optional = pickers.first { $0.identifier?.rawValue == "optional" }!
        let required = pickers.first { $0.identifier?.rawValue == "required" }!
        try expect(duplicate.numberOfItems == 3 && optional.numberOfItems == 3 && required.numberOfItems == 3,
                   "Repeated labels or placeholder labels collapsed menu items")
        try expect(duplicate.selectedItem?.representedObject as? String == "a", "Duplicate default selected a different value")
        for (picker, index) in [(duplicate, 1), (optional, 1), (required, 1)] {
            picker.selectItem(at: index)
            picker.sendAction(picker.action, to: picker.target)
        }
        let save = descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Save" }!
        try expect(save.isEnabled, "Valid options with duplicate labels could not be saved")
        save.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        let saved = host.configuration(for: plugin).values
        try expect(saved["duplicate"] == .string("b") && saved["optional"] == .string("none-option")
                   && saved["required"] == .string("choose-option"), "Labels changed the saved option values")
        var invalid = saved
        invalid["duplicate"] = .string("missing")
        try store.save(invalid, for: plugin.id)
        host.reload()
        let migration = PluginConfigurationWindowController(plugin: plugin, host: host)
        let migrationWindow = migration.window!
        parent.beginSheet(migrationWindow, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        let migrated = descendants(migrationWindow.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "duplicate" }!
        try expect(migrated.numberOfItems == 4 && migrated.item(at: 0)?.isEnabled == false
                   && migrated.item(at: 3)?.representedObject as? String == "c",
                   "Unavailable value replaced a real option with the same label")
        migrated.selectItem(at: 3)
        migrated.sendAction(migrated.action, to: migrated.target)
        descendants(migrationWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Save" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try expect(host.configuration(for: plugin).values["duplicate"] == .string("c"), "Unavailable-label recovery saved the wrong value")
        print("DEV configuration: duplicate labels and placeholder-label collisions preserve selectable values")
    }

    private static func checkLongForm(on parent: NSWindow) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteLongForm-" + UUID().uuidString)
        let folder = root.appendingPathComponent("long-form")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = (0..<30).map { index in
            ["id": "field\(index)", "label": "Repository organization or workspace identifier \(index)", "type": "text",
             "description": "Choose a repository organization or workspace. This longer description should wrap within the form.",
             "default": "Example value \(index)"]
        }
        let manifest: [String: Any] = ["id": "long-form", "name": "Long Form Fixture", "commands": [], "settings": fields]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
        let host = PluginHost(directory: root, configurationStore: PluginConfigurationStore(directory: root.appendingPathComponent("values")))
        let plugin = host.plugins.first!
        let editor = PluginConfigurationWindowController(plugin: plugin, host: host)
        let window = editor.window!
        parent.beginSheet(window, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        try await capture(window, name: "plugin-configuration-long-top")
        let last = descendants(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "field29" }!
        window.makeFirstResponder(last)
        try await Task.sleep(for: .milliseconds(150))
        let scroll = descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first!
        let rect = last.convert(last.bounds, to: scroll.documentView)
        print("DEV configuration long form: document=\(scroll.documentView!.frame), visible=\(scroll.documentVisibleRect), last=\(rect), responder=\(String(describing: window.firstResponder))")
        guard scroll.documentVisibleRect.contains(rect) else {
            throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keyboard focus did not reveal the last field"])
        }
        try await capture(window, name: "plugin-configuration-long-bottom")
        parent.endSheet(window)
        window.orderOut(nil)
        print("DEV configuration: long labels/descriptions and keyboard access through a 30-field form passed")
    }

    private static func requireSheet() throws -> NSWindow {
        guard let sheet = NSApp.windows.first(where: { $0.isVisible && $0.title == "Configure Configuration Fixture" }) else {
            throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing configuration sheet"])
        }
        return sheet
    }

    private static func edit(_ input: NSTextField, text: String) {
        input.stringValue = text
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
    }

    private static func invoke(_ host: PluginHost, plugin: InstalledPlugin, arguments: [String] = []) async throws -> PluginResponse {
        try await withCheckedThrowingContinuation { continuation in
            host.run(plugin, arguments: arguments, query: "") { continuation.resume(with: $0.mapError { $0 as any Error }) }
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func capture(_ window: NSWindow, name: String) async throws {
        let directory = URL(fileURLWithPath: "build/configuration-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        if CGPreflightScreenCaptureAccess() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
            try process.run()
            process.waitUntilExit()
            try checkCaptureStatus(process.terminationStatus)
        }
        print("DEV configuration frame \(name): window=\(window.frame), content=\(window.contentView?.frame ?? .zero)")
    }

    private static func checkCaptureStatus(_ status: Int32) throws {
        guard status == 0 else { throw NSError(domain: "SpotliteConfigurationCapture", code: Int(status)) }
    }
}
#endif
