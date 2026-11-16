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
        let inputs = DevViews.descendants(sheet.contentView!).compactMap { $0 as? NSControl }
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
        sheet.makeFirstResponder(name)
        if let editor = name.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("Alpha", replacementRange: editor.selectedRange())
        }
        sheet.makeFirstResponder(limit)
        try check(host.needsSetup(plugin.id) && sheet.sheetParent != nil, "Moving between fields saved the draft")
        cancel.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try check(host.needsSetup(plugin.id), "Cancel persisted draft settings")

        settings.configurePlugin(id: plugin.id)
        try await Task.sleep(for: .milliseconds(200))
        let second = try requireSheet()
        let secondInputs = DevViews.descendants(second.contentView!).compactMap { $0 as? NSControl }
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
        let migrated = DevViews.descendants(resetSheet.contentView!).compactMap { $0 as? NSControl }
        try check((migrated.first { $0.identifier?.rawValue == "format" } as? NSPopUpButton)?.titleOfSelectedItem
                    == "Unavailable: removed choice", "Unavailable saved choice was hidden")
        try check((migrated.first { $0.identifier?.rawValue == "enabled" } as? NSButton)?.state == .mixed,
                  "Incompatible saved boolean appeared valid")
        try await capture(resetSheet, name: "plugin-configuration-migration")
        DevViews.descendants(resetSheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset Settings…" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        try check(resetSheet.attachedSheet != nil, "Reset did not ask before removing saved values")
        let resetAlert = resetSheet.attachedSheet!
        DevViews.descendants(resetAlert.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset Settings" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try check(host.needsSetup(plugin.id), "Reset did not clear required settings")
        DevViews.descendants(resetSheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try Data("{".utf8).write(to: stored)
        host.reload()
        try check(host.configuration(for: plugin).problem != nil && host.needsSetup(plugin.id),
                  "Corrupt settings did not require recovery")
        settings.configurePlugin(id: plugin.id)
        try await Task.sleep(for: .milliseconds(200))
        let recovery = try requireSheet()
        try await capture(recovery, name: "plugin-configuration-recovery")
        DevViews.descendants(recovery.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        if let parent {
            try await checkLongForm(on: parent)
            try await Task.sleep(for: .milliseconds(250))
            try await checkChoiceLabels(on: parent)
            try await Task.sleep(for: .milliseconds(250))
            try await checkSecrets(on: parent)
            try await Task.sleep(for: .milliseconds(250))
            try await checkFieldTypes(on: parent)
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
        host.devApply(try changes(batch), from: original)
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
        host.devApply(try changes(captured), from: original)
        try expect(host.subtitle(forEntryID: newID) == "Original new", "Batch lookup used the new manifest for an old response")
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c1")) == "Captured 1", "Captured manifest updates were lost")
        host.devApply(try changes([["command": "c1"]]), from: original)
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c1")) == "Original 1", "Single-update reset changed behavior")
        host.devApply(try changes([["command": "c2", "subtitle": "First"], ["command": "c2", "subtitle": "Second"]]), from: original)
        try expect(host.subtitle(forEntryID: original.entryID(forCommandID: "c2")) == "Second", "Small-batch duplicate ordering changed")
        print("DEV configuration: single/batch command updates preserve unknown, duplicate, reset, expiry and captured-manifest behavior")
    }

    /// Uses the real Keychain under a dev-only service prefix and removes its item.
    private static func checkSecrets(on parent: NSWindow) async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteSecrets-" + UUID().uuidString)
        let folder = root.appendingPathComponent("secret-check")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"""
        {"id":"secret-check","name":"Secret Fixture","executable":"run.sh","commands":[],"settings":[
          {"id":"copy","label":"API token","type":"secret","required":true,"description":"A personal access token."},
          {"id":"spare","label":"Spare token","type":"secret"}]}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("plugin.json"))
        let script = folder.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\nprintf '%s' \"$SPOTLITE_CONFIG\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let keychain = KeychainSecretStore(prefix: "com.igorv.spotlite.dev.plugin.")
        let store = PluginConfigurationStore(directory: root.appendingPathComponent("values"), secrets: keychain)
        let host = PluginHost(directory: root, configurationStore: store)
        let plugin = host.plugin(id: "secret-check")!
        try host.resetConfiguration(for: plugin)
        defer {
            try? host.resetConfiguration(for: plugin)
            try? FileManager.default.removeItem(at: root)
        }
        var editor: PluginConfigurationWindowController?
        func open() async throws -> (NSWindow, NSSecureTextField, NSButton, NSButton) {
            editor = PluginConfigurationWindowController(plugin: plugin, host: host)
            let window = editor!.window!
            parent.beginSheet(window, completionHandler: { _ in })
            try await Task.sleep(for: .milliseconds(250))
            let views = DevViews.descendants(window.contentView!)
            let field = views.compactMap { $0 as? NSSecureTextField }.first { $0.identifier?.rawValue == "copy" }!
            let clear = views.compactMap { $0 as? NSButton }.first { $0.title == "Clear" && $0.identifier?.rawValue == "copy" }!
            let save = views.compactMap { $0 as? NSButton }.first { $0.title == "Save" }!
            return (window, field, clear, save)
        }
        var (window, field, clear, save) = try await open()
        try expect(!save.isEnabled && !clear.isEnabled && field.placeholderString == "Required", "Unset secret state is wrong")
        try await capture(window, name: "plugin-configuration-secret-unset")
        edit(field, text: "hunter2")
        try expect(save.isEnabled && clear.isEnabled, "Typing a secret did not enable Save and Clear")
        save.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try expect(!host.needsSetup(plugin.id), "Saving a secret did not finish setup")
        let file = try String(contentsOf: root.appendingPathComponent("values/secret-check.json"), encoding: .utf8)
        try expect(!file.contains("hunter2") && !file.contains("copy"), "A secret reached the settings file: \(file)")
        try expect(try keychain.read(plugin: plugin.id, field: "copy") == "hunter2", "The secret is not in the Keychain")
        try expect(try keychain.read(plugin: plugin.id, field: "spare") == nil, "An unset secret was stored")
        let response = try await invoke(host, plugin: plugin)
        try expect(response.copy == "hunter2", "SPOTLITE_CONFIG lacks the secret")
        host.reload()
        try expect(host.configuration(for: plugin).values["copy"] == .string("hunter2"), "Reload lost the secret")

        (window, field, clear, save) = try await open()
        try expect(field.stringValue.isEmpty && field.placeholderString == "Saved. Type to replace."
                   && clear.isEnabled && save.isEnabled, "Saved secret state is wrong or echoed")
        try await capture(window, name: "plugin-configuration-secret-saved")
        clear.performClick(nil)
        try expect(!save.isEnabled && !clear.isEnabled && field.placeholderString == "Required", "Clear did not unset the secret")
        edit(field, text: "replaced")
        save.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        try expect(try keychain.read(plugin: plugin.id, field: "copy") == "replaced", "Replacing the secret failed")
        editor = nil

        try host.resetConfiguration(for: plugin)
        try expect(try keychain.read(plugin: plugin.id, field: "copy") == nil && host.needsSetup(plugin.id),
                   "Reset did not remove the secret")
        print("DEV configuration: secrets stay out of the settings file, reach SPOTLITE_CONFIG, survive Reload, clear, replace and reset")
    }

    /// Paths with Choose…, multi-line text and lists: editing, open panels, layout,
    /// tilde expansion and `mustExist` on reload.
    private static func checkFieldTypes(on parent: NSWindow) async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteFieldTypes-" + UUID().uuidString)
        let folder = root.appendingPathComponent("field-types")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"""
        {"id":"field-types","name":"Field Types Fixture","commands":[],"settings":[
          {"id":"notes","label":"Notes","type":"text","multiline":true,"description":"Several lines of text."},
          {"id":"hosts","label":"Hosts","type":"list","required":true,"description":"One host per line."},
          {"id":"config","label":"Config file","type":"file","required":true,"mustExist":true,"extensions":["json"]},
          {"id":"workspace","label":"Workspace","type":"folder","mustExist":true,"default":"~"}]}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("plugin.json"))
        let configFile = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configFile)
        let host = PluginHost(directory: root, configurationStore: PluginConfigurationStore(
            directory: root.appendingPathComponent("values"), secrets: MemorySecretStore()))
        let plugin = host.plugin(id: "field-types")!
        var editor: PluginConfigurationWindowController? = PluginConfigurationWindowController(plugin: plugin, host: host)
        var window = editor!.window!
        parent.beginSheet(window, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        var views = DevViews.descendants(window.contentView!)
        let notes = views.compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "notes" }!
        let hosts = views.compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "hosts" }!
        let config = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "config" }!
        let workspace = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "workspace" }!
        let buttons = views.compactMap { $0 as? NSButton }
        let chooseFile = buttons.first { $0.title == "Choose…" && $0.identifier?.rawValue == "config" }!
        let chooseFolder = buttons.first { $0.title == "Choose…" && $0.identifier?.rawValue == "workspace" }!
        let save = buttons.first { $0.title == "Save" }!
        try expect(!save.isEnabled && workspace.stringValue == "~", "Initial field type state is wrong")

        // Layout: each editor fills the 260-point value column, Choose… inside it.
        let content = window.contentView!
        for (name, view) in [("notes", notes.enclosingScrollView!), ("hosts", hosts.enclosingScrollView!),
                             ("config", config.superview!), ("workspace", workspace.superview!)] {
            let frame = view.convert(view.bounds, to: content)
            print("DEV configuration field \(name): \(frame)")
            try expect(abs(frame.width - 260) < 0.5 && content.bounds.contains(frame), "\(name) is not 260 wide inside the form: \(frame)")
        }
        for (field, button) in [(config, chooseFile), (workspace, chooseFolder)] {
            let a = field.convert(field.bounds, to: content), b = button.convert(button.bounds, to: content)
            try expect(a.maxX <= b.minX && b.maxX <= a.minX + 260.5 && a.width > 120, "Choose… overlaps its field: \(a) \(b)")
        }
        try expect(notes.enclosingScrollView!.frame.height == 76, "Multi-line editor height changed")
        let form = views.compactMap { $0 as? NSScrollView }.first { $0.documentView is FlippedView }!
        let grid = form.documentView!.subviews.first as! NSGridView
        for row in 0..<grid.numberOfRows {
            let label = grid.cell(atColumnIndex: 0, rowIndex: row).contentView!, value = grid.cell(atColumnIndex: 1, rowIndex: row).contentView!
            let a = label.frame.maxY - label.firstBaselineOffsetFromTop, b = value.frame.maxY - value.firstBaselineOffsetFromTop
            print("DEV configuration types row \(row): label baseline \(a), value baseline \(b)")
            try expect(abs(a - b) < 1, "Label \(row) is not on its field's first baseline")
        }

        func type(_ view: NSTextView, _ text: String) {
            view.string = text
            editor!.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        }
        window.makeFirstResponder(notes)
        notes.doCommand(by: #selector(NSResponder.insertTab(_:)))
        try expect(window.firstResponder !== notes && notes.string.isEmpty, "Tab did not leave the multi-line field")
        type(notes, "line one\nline two")
        type(hosts, " alpha \n\n beta\n")
        try expect(!save.isEnabled, "A missing required file enabled Save")
        edit(config, text: root.appendingPathComponent("missing.json").path)
        try expect(!save.isEnabled, "A missing mustExist file enabled Save")
        edit(config, text: configFile.path)
        try expect(save.isEnabled, "Valid field types did not enable Save")
        for (tag, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await capture(window, name: "plugin-configuration-types-\(tag)")
        }

        for (button, folder) in [(chooseFile, false), (chooseFolder, true)] {
            button.performClick(nil)
            try await Task.sleep(for: .milliseconds(400))
            guard let panel = window.attachedSheet as? NSOpenPanel else { throw NSError(domain: "SpotliteConfigurationChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose… did not open a panel"]) }
            try expect(panel.canChooseDirectories == folder && panel.canChooseFiles == !folder
                       && panel.allowedContentTypes == (folder ? [] : [.json]), "Open panel is configured wrong")
            panel.cancel(nil)
            try await Task.sleep(for: .milliseconds(300))
        }
        try expect(window.attachedSheet == nil && config.stringValue == configFile.path, "Cancelling the panel changed the path")

        save.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        let configuration = host.configuration(for: plugin)
        try expect(configuration.isValid && configuration.values["notes"] == .string("line one\nline two")
                   && configuration.values["hosts"] == .list(["alpha", "beta"])
                   && configuration.values["workspace"] == .string("~"), "Saved field type values are wrong")
        let object = try JSONSerialization.jsonObject(with: Data(configuration.json().utf8)) as! [String: Any]
        try expect(object["workspace"] as? String == NSHomeDirectory() && object["hosts"] as? [String] == ["alpha", "beta"],
                   "SPOTLITE_CONFIG has unexpanded paths or a non-array list")

        editor = PluginConfigurationWindowController(plugin: plugin, host: host)
        window = editor!.window!
        parent.beginSheet(window, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        views = DevViews.descendants(window.contentView!)
        let reopened = views.compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "hosts" }!
        try expect(reopened.string == "alpha\nbeta", "A saved list did not reopen one item per line")
        parent.endSheet(window)
        window.orderOut(nil)
        editor = nil

        try FileManager.default.removeItem(at: configFile)
        try expect(!host.needsSetup(plugin.id), "Readiness reread the disk outside Reload")
        host.reload()
        try expect(host.needsSetup(plugin.id) && host.configuration(for: plugin).errors["config"] != nil,
                   "A deleted mustExist file did not require setup on Reload")
        print("DEV configuration: file, folder, multi-line text and list fields edit, lay out, expand ~ and revalidate")
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
        let pickers = DevViews.descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }
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
        let save = DevViews.descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Save" }!
        try expect(save.isEnabled, "Valid options with duplicate labels could not be saved")
        save.performClick(nil)
        try await Task.sleep(for: .milliseconds(250))
        let saved = host.configuration(for: plugin).values
        try expect(saved["duplicate"] == .string("b") && saved["optional"] == .string("none-option")
                   && saved["required"] == .string("choose-option"), "Labels changed the saved option values")
        var invalid = saved
        invalid["duplicate"] = .string("missing")
        try store.save(invalid, for: plugin.id, settings: plugin.manifest?.settings ?? [])
        host.reload()
        let migration = PluginConfigurationWindowController(plugin: plugin, host: host)
        let migrationWindow = migration.window!
        parent.beginSheet(migrationWindow, completionHandler: { _ in })
        try await Task.sleep(for: .milliseconds(250))
        let migrated = DevViews.descendants(migrationWindow.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "duplicate" }!
        try expect(migrated.numberOfItems == 4 && migrated.item(at: 0)?.isEnabled == false
                   && migrated.item(at: 3)?.representedObject as? String == "c",
                   "Unavailable value replaced a real option with the same label")
        migrated.selectItem(at: 3)
        migrated.sendAction(migrated.action, to: migrated.target)
        DevViews.descendants(migrationWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Save" }!.performClick(nil)
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
        let last = DevViews.descendants(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "field29" }!
        window.makeFirstResponder(last)
        try await Task.sleep(for: .milliseconds(150))
        let scroll = DevViews.descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first!
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
