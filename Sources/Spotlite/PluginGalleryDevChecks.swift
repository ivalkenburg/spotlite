#if DEBUG
import AppKit
import SpotliteCore

/// The gallery through Settings, offline: the index is a local file named by
/// `SPOTLITE_DEV_GALLERY_URL`, and its `https://example.invalid` sources are zips built
/// here and served from disk.
@MainActor
enum PluginGalleryDevChecks {
    static func run(library: AppLibrary, preferences: Preferences) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteGalleryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let host = PluginHost.shared
        try check(environment["SPOTLITE_DEV_PLUGINS_DIR"] != nil, "Set SPOTLITE_DEV_PLUGINS_DIR to a scratch folder")
        guard let fixture = environment["SPOTLITE_DEV_GALLERY_URL"].flatMap(URL.init(string:)), fixture.isFileURL else {
            return try check(false, "Set SPOTLITE_DEV_GALLERY_URL to file://$PWD/Tests/Fixtures/Gallery/index.json")
        }
        try check(host.galleryURL == fixture, "The gallery reads \(host.galleryURL), not the override")
        try check(host.plugins.allSatisfy { !$0.id.hasPrefix("devgallery") }, "Start from a folder without devgallery plugins")
        let ids = ["devgallery-new", "devgallery-old", "devgallery-same"]
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("spotlite-devgallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let loader = PluginInstallDevChecks.Loader()
        host.devLoader = loader
        // A copy of the fixture, so the check can break it and mend it.
        let index = scratch.appendingPathComponent("index.json")
        host.devGalleryURL = index
        defer {
            for id in ids {
                try? FileManager.default.removeItem(at: host.pluginsDirectory.appendingPathComponent(id))
                host.sources.remove(for: id)
            }
            try? FileManager.default.removeItem(at: scratch)
            host.devLoader = nil
            host.devGalleryURL = nil
            host.reload()
        }
        let good = try Data(contentsOf: fixture)
        try Data(#"{"version":99,"plugins":[]}"#.utf8).write(to: index)
        loader.serve("devgallery-new.zip", try PluginInstallDevChecks.archive("devgallery-new", version: "1.0.0",
                                                                             name: "Gallery New", in: scratch))
        loader.serve("devgallery-old.zip", try PluginInstallDevChecks.archive("devgallery-old", version: "2.0.0",
                                                                             name: "Gallery Old", in: scratch))
        for id in ["devgallery-old", "devgallery-same"] {
            let folder = try PluginInstallDevChecks.folder(id, version: "1.0.0", name: id, in: scratch)
            try PluginStore.install(from: folder, into: host.pluginsDirectory)
        }
        host.reload()

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
        guard let window = settingsWindow else { return try check(false, "Settings has no window") }
        let install = DevViews.descendants(pane.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Add Plugin" }?.menu
        try check(install != nil, "No Browse Gallery… in the Install menu")
        DevViews.dumpFrames(pane.view, tag: "plugins-pane-gallery")

        func views(_ sheet: NSWindow) -> [NSView] { DevViews.descendants(sheet.contentView!) }
        func button(_ title: String, in sheet: NSWindow) -> NSButton? {
            views(sheet).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func texts(_ sheet: NSWindow) -> String {
            views(sheet).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator: "\n")
        }
        func fail(_ message: String) -> NSError {
            NSError(domain: "SpotliteGalleryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func sheet(on parent: NSWindow) async throws -> NSWindow {
            for _ in 0..<100 {
                if let sheet = parent.attachedSheet { return sheet }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw fail("No sheet on \(parent.title)")
        }
        func page(_ title: String, in sheet: NSWindow) async throws -> NSButton {
            for _ in 0..<250 {
                if let found = button(title, in: sheet), found.window != nil { return found }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw fail("No \(title) button; sheet shows: \(texts(sheet))")
        }
        func rowButton(_ id: String, in sheet: NSWindow) -> NSButton? {
            // A reloaded table makes its row views on the next layout.
            sheet.contentView?.layoutSubtreeIfNeeded()
            return views(sheet).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "gallery-" + id }
        }
        func table(_ sheet: NSWindow) -> NSTableView? { views(sheet).compactMap { $0 as? NSTableView }.first }
        func search(_ text: String, in sheet: NSWindow) {
            guard let field = views(sheet).compactMap({ $0 as? NSSearchField }).first else { return }
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        func closed(_ parent: NSWindow) async throws {
            for _ in 0..<100 where parent.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
            try check(parent.attachedSheet == nil, "A sheet stayed open on \(parent.title)")
        }

        // An index in an unknown format: a clear error, then Retry reads it again.
        install!.performActionForItem(at: install!.indexOfItem(withTitle: "Browse Gallery…"))
        let gallery = try await sheet(on: window)
        let retry = try await page("Retry", in: gallery)
        try check(texts(gallery).contains("format version 99"), "Error page: \(texts(gallery))")
        DevViews.dumpFrames(gallery.contentView!, tag: "gallery-error")
        try await SettingsForm.captureWindow(gallery, name: "gallery-error")
        try good.write(to: index)
        retry.performClick(nil)
        _ = try await page("Done", in: gallery)
        print("DEV gallery: unknown version error, Retry passed")

        // The list: statuses from the installed plugins, the skipped entry, the warning.
        let listed = texts(gallery)
        for expected in ["third-party code", "doesn’t review or vet", "1 entry was skipped", "plugins/index.json"]
        where !listed.contains(expected) {
            try check(false, "Gallery lacks \(expected): \(listed)")
        }
        try check(table(gallery)?.numberOfRows == 3, "Rows: \(table(gallery)?.numberOfRows ?? -1)")
        try check(rowButton("devgallery-new", in: gallery)?.title == "Install…", "New: \(rowButton("devgallery-new", in: gallery)?.title ?? "none")")
        try check(rowButton("devgallery-old", in: gallery)?.title == "Update…", "Old: \(rowButton("devgallery-old", in: gallery)?.title ?? "none")")
        let same = rowButton("devgallery-same", in: gallery)
        try check(same?.title == "Installed" && same?.isEnabled == false, "Same: \(same?.title ?? "none")")
        try check(!listed.contains("Insecure"), "The http entry is listed")
        DevViews.dumpFrames(gallery.contentView!, tag: "gallery-list")
        try await SettingsForm.captureWindow(gallery, name: "gallery-list")
        print("DEV gallery: list, statuses, skipped entry, trust warning passed")

        // Search by name, tag and nothing.
        search("old", in: gallery)
        try check(table(gallery)?.numberOfRows == 1, "Search old: \(table(gallery)?.numberOfRows ?? -1)")
        search("demo", in: gallery)
        try check(table(gallery)?.numberOfRows == 2, "Search tag demo: \(table(gallery)?.numberOfRows ?? -1)")
        search("zzz", in: gallery)
        try check(table(gallery)?.numberOfRows == 0 && texts(gallery).contains("No plugins match “zzz”."), "Search zzz: \(texts(gallery))")
        DevViews.dumpFrames(gallery.contentView!, tag: "gallery-empty-search")
        search("", in: gallery)
        try check(table(gallery)?.numberOfRows == 3, "Cleared search")
        print("DEV gallery: search passed")

        // Install goes through the usual confirmation, on top of the gallery.
        rowButton("devgallery-new", in: gallery)!.performClick(nil)
        var confirmation = try await sheet(on: gallery)
        let confirm = try await page("Install", in: confirmation)
        let details = texts(confirmation)
        for expected in ["Install “Gallery New”?", "devgallery-new", "https://example.invalid/devgallery-new.zip",
                         "run with your permissions"] where !details.contains(expected) {
            try check(false, "Confirmation lacks \(expected): \(details)")
        }
        try check(host.plugin(id: "devgallery-new") == nil, "Installed before confirming")
        DevViews.dumpFrames(confirmation.contentView!, tag: "gallery-confirm")
        try await SettingsForm.captureWindow(confirmation, name: "gallery-confirm")
        confirm.performClick(nil)
        try await closed(gallery)
        try check(window.attachedSheet === gallery, "The gallery closed with the confirmation")
        try check(host.plugin(id: "devgallery-new")?.manifest?.version == "1.0.0", "Not installed")
        try check(host.sources.load(for: "devgallery-new")?.address == "https://example.invalid/devgallery-new.zip",
                  "No source record")
        try check(rowButton("devgallery-new", in: gallery)?.title == "Installed", "Status not refreshed after install")
        print("DEV gallery: install through the confirmation, status refreshed passed")

        // Update, and Cancel on a confirmation installs nothing.
        rowButton("devgallery-old", in: gallery)!.performClick(nil)
        confirmation = try await sheet(on: gallery)
        _ = try await page("Update", in: confirmation)
        try check(texts(confirmation).contains("1.0.0 → 2.0.0"), "Update confirmation: \(texts(confirmation))")
        button("Cancel", in: confirmation)!.performClick(nil)
        try await closed(gallery)
        try check(host.plugin(id: "devgallery-old")?.manifest?.version == "1.0.0", "Cancel changed the plugin")
        try check(PluginInstallDevChecks.stagingLeftovers().isEmpty, "Staging left behind")
        rowButton("devgallery-old", in: gallery)!.performClick(nil)
        confirmation = try await sheet(on: gallery)
        try await page("Update", in: confirmation).performClick(nil)
        try await closed(gallery)
        try check(host.plugin(id: "devgallery-old")?.manifest?.version == "2.0.0", "Not updated")
        try check(rowButton("devgallery-old", in: gallery)?.title == "Installed", "Status not refreshed after update")
        print("DEV gallery: update through the confirmation, cancel installs nothing passed")

        // Reopening while Settings is open uses the index in memory; Refresh reads again.
        button("Done", in: gallery)!.performClick(nil)
        try await closed(window)
        try Data("not json".utf8).write(to: index)
        install!.performActionForItem(at: install!.indexOfItem(withTitle: "Browse Gallery…"))
        let reopened = try await sheet(on: window)
        _ = try await page("Done", in: reopened)
        try check(table(reopened)?.numberOfRows == 3, "Reopened without the kept index")
        button("Refresh", in: reopened)!.performClick(nil)
        let again = try await page("Retry", in: reopened)
        try check(texts(reopened).contains("not valid"), "Refresh error: \(texts(reopened))")
        try good.write(to: index)
        again.performClick(nil)
        _ = try await page("Done", in: reopened)
        try check(table(reopened)?.numberOfRows == 3, "Retry after Refresh")
        button("Done", in: reopened)!.performClick(nil)
        try await closed(window)
        print("DEV gallery: kept index on reopen, Refresh and Retry passed")

        // The Settings controller is reused after closing its window. Its index
        // must be released, so the next gallery opening fetches again.
        window.close()
        try Data(#"{"version":99,"plugins":[]}"#.utf8).write(to: index)
        settings.show(apps: library.entries)
        install!.performActionForItem(at: install!.indexOfItem(withTitle: "Browse Gallery…"))
        let newSession = try await sheet(on: window)
        _ = try await page("Retry", in: newSession)
        try check(texts(newSession).contains("format version 99"), "Settings retained its old gallery index")
        button("Close", in: newSession)!.performClick(nil)
        try await closed(window)
        print("DEV gallery: closing Settings releases the cached index passed")
    }
}
#endif
