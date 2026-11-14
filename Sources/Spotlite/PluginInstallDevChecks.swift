#if DEBUG
import AppKit
import SpotliteCore

/// Install from URL, the confirmation, update checks and refusals, through Settings,
/// offline: archives are built from scratch and served from disk under https names.
@MainActor
enum PluginInstallDevChecks {
    /// Serves local zips for `https://example.invalid/<name>`.
    final class Loader: PluginDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: URL] = [:]

        func serve(_ name: String, _ file: URL) {
            lock.withLock { files["https://example.invalid/" + name] = file }
        }

        func download(_ url: URL, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Bool {
            guard let file = lock.withLock({ files[url.absoluteString] }) else { return false }
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: file, to: destination)
            } catch { throw .download(error.localizedDescription) }
            let size = Int64((try? Data(contentsOf: destination).count) ?? 0)
            progress(size, size)
            return true
        }

        func data(from url: URL, limit: Int64) async throws(PluginInstallError) -> Data? { nil }
    }

    static func run(library: AppLibrary, preferences: Preferences) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteInstallChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        let host = PluginHost.shared
        try check(ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGINS_DIR"] != nil,
                  "Set SPOTLITE_DEV_PLUGINS_DIR to a scratch folder")
        try check(host.plugins.allSatisfy { !$0.id.hasPrefix("devinstall") }, "Start from a folder without devinstall plugins")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("spotlite-devinstall-\(UUID().uuidString)")
        let loader = Loader()
        host.devLoader = loader
        defer {
            for id in ["devinstall", "devlinked"] {
                try? FileManager.default.removeItem(at: host.pluginsDirectory.appendingPathComponent(id))
                host.sources.remove(for: id)
            }
            try? FileManager.default.removeItem(at: scratch)
            host.devLoader = nil
            host.reload()
        }
        loader.serve("v1.zip", try archive("devinstall", version: "1.0.0", in: scratch))
        loader.serve("slip.zip", try slipArchive(in: scratch))
        loader.serve("linked.zip", try archive("devlinked", version: "2.0.0", in: scratch))

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
        let views = descendants(pane.view)
        let install = views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Add Plugin" }?.menu
        let more = views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "More" }
        /// Enabled as the menu opens, by the pane's validation.
        func updatesEnabled() -> Bool? {
            more?.menu?.update()
            return more?.menu?.item(withTitle: "Check for Updates")?.isEnabled
        }
        let source = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Source" }
        try check(install?.items.map(\.title) == ["Install from Folder…", "Install from URL…", "", "Browse Gallery…"],
                  "Install menu: \(install?.items.map(\.title) ?? [])")
        try check(updatesEnabled() == false, "Check for Updates enabled without a source")
        dumpFrames(pane.view, tag: "plugins-pane-install")

        func sheet() async throws -> NSWindow {
            for _ in 0..<100 {
                if let sheet = window.attachedSheet { return sheet }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "SpotliteInstallChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "No sheet"])
        }
        func controls(_ sheet: NSWindow) -> [NSView] { descendants(sheet.contentView!) }
        func button(_ title: String, in sheet: NSWindow) -> NSButton? {
            controls(sheet).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func texts(_ sheet: NSWindow) -> String {
            controls(sheet).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator: "\n")
        }
        /// Waits for a page with `title` as a button, while downloads and checks run.
        func page(_ title: String, in sheet: NSWindow) async throws -> NSButton {
            for _ in 0..<250 {
                if let found = button(title, in: sheet) { return found }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "SpotliteInstallChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No \(title) button; sheet shows: \(texts(sheet))"])
        }
        func enter(_ address: String) async throws -> NSWindow {
            install!.performActionForItem(at: 1)
            let entry = try await sheet()
            let field = controls(entry).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
            field.stringValue = address
            button("Continue", in: entry)!.performClick(nil)
            return entry
        }

        // An address that is not https never leaves the sheet.
        var current = try await enter("http://example.invalid/v1.zip")
        try check(texts(current).contains("Only https addresses are supported."), "http accepted: \(texts(current))")
        dumpFrames(current.contentView!, tag: "install-address-error")
        try await SettingsForm.captureWindow(current, name: "install-address-error")

        // An archive that escapes its folder is refused, and nothing is left behind.
        let field = controls(current).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        field.stringValue = "https://example.invalid/slip.zip"
        button("Continue", in: current)!.performClick(nil)
        _ = try await page("Continue", in: current)
        try await Task.sleep(for: .milliseconds(100))
        try check(texts(current).contains("unsafe path"), "Zip-slip archive: \(texts(current))")
        try check(stagingLeftovers().isEmpty, "Staging left behind: \(stagingLeftovers())")
        button("Cancel", in: current)!.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        try check(window.attachedSheet == nil, "Cancel left the sheet open")
        print("DEV install: https only, unsafe archive refused, staging cleaned passed")

        // Install: the confirmation names what the plugin is and does.
        current = try await enter("https://example.invalid/v1.zip")
        let confirm = try await page("Install", in: current)
        let details = texts(current)
        for expected in ["Install “Dev Install”?", "devinstall", "1.0.0", "Dev Tester", "https://example.invalid/v1.zip",
                         "Run Dev (run)", "List Dev (list", "run.sh", "Token (secret)", "run with your permissions"]
        where !details.contains(expected) {
            try check(false, "Confirmation lacks \(expected): \(details)")
        }
        dumpFrames(current.contentView!, tag: "install-confirm")
        try await SettingsForm.captureWindow(current, name: "install-confirm")
        confirm.performClick(nil)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        try check(window.attachedSheet == nil, "Install left the sheet open")
        try check(host.plugin(id: "devinstall")?.manifest?.version == "1.0.0", "Not installed")
        try check(host.sources.load(for: "devinstall")?.address == "https://example.invalid/v1.zip", "No source record")
        try check(source?.stringValue.hasPrefix("From https://example.invalid/v1.zip") == true,
                  "Source line: \(source?.stringValue ?? "")")
        try check(updatesEnabled() == true, "Check for Updates disabled with a source")
        // Settings saved for the plugin survive its update.
        let plugin = host.plugin(id: "devinstall")!
        try host.saveConfiguration(["token": .string("dev-secret")], for: plugin)
        print("DEV install: confirmation details, install, source record passed")

        // Check for Updates finds the newer archive, and Update… goes through the confirmation.
        loader.serve("v1.zip", try archive("devinstall", version: "1.1.0", in: scratch))
        more!.menu!.performActionForItem(at: more!.menu!.indexOfItem(withTitle: "Check for Updates"))
        current = try await sheet()
        let update = try await page("Update…", in: current)
        try check(texts(current).contains("1.0.0 → 1.1.0") && texts(current).contains("1 update available."),
                  "Update list: \(texts(current))")
        try check(source?.stringValue.contains("Update available: 1.1.0") == true, "Source line: \(source?.stringValue ?? "")")
        dumpFrames(current.contentView!, tag: "install-updates")
        try await SettingsForm.captureWindow(current, name: "install-updates")
        update.performClick(nil)
        let apply = try await page("Update", in: current)
        try check(texts(current).contains("Update “Dev Install”?") && texts(current).contains("1.0.0 → 1.1.0")
                  && texts(current).contains("settings, secrets and data are kept"), "Update confirmation: \(texts(current))")
        apply.performClick(nil)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        try check(host.plugin(id: "devinstall")?.manifest?.version == "1.1.0", "Not updated")
        try check(host.sources.load(for: "devinstall")?.version == "1.1.0", "Record not updated")
        try check(host.configuration(for: host.plugin(id: "devinstall")!).values["token"] == .string("dev-secret"),
                  "The update lost the plugin's settings")
        try check(source?.stringValue.contains("Update available") == false, "Stale update notice")
        try host.resetConfiguration(for: host.plugin(id: "devinstall")!)
        print("DEV install: update check, update through confirmation, settings kept passed")

        // A linked development folder with the same id is never replaced.
        let checkout = scratch.appendingPathComponent("checkout/devlinked")
        try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try folder("devlinked", version: "1.0.0", in: scratch), to: checkout)
        try FileManager.default.createSymbolicLink(at: host.pluginsDirectory.appendingPathComponent("devlinked"),
                                                   withDestinationURL: checkout)
        host.reload()
        pane.reload()
        current = try await enter("https://example.invalid/linked.zip")
        let refused = try await page("Update", in: current)
        try check(!refused.isEnabled && texts(current).contains("Spotlite won’t replace it"), "Linked: \(texts(current))")
        dumpFrames(current.contentView!, tag: "install-linked")
        button("Cancel", in: current)!.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        try check(PluginStore.load(checkout).manifest?.version == "1.0.0", "The checkout changed")
        try check(stagingLeftovers().isEmpty, "Staging left behind: \(stagingLeftovers())")
        print("DEV install: linked plugin kept, staging cleaned passed")
    }

    static func stagingLeftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("Spotlite-plugin-") }
    }

    static func folder(_ id: String, version: String, name: String = "Dev Install", in scratch: URL) throws -> URL {
        let folder = scratch.appendingPathComponent("src-\(UUID().uuidString)/\(id)-main")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        {"id":"\(id)","name":"\(name)","version":"\(version)","author":"Dev Tester","description":"Installed by a dev check.",
         "executable":"run.sh","settings":[{"id":"token","label":"Token","type":"secret"}],
         "commands":[{"id":"run","title":"Run Dev","action":{"type":"run"}},
                     {"id":"list","title":"List Dev","keyword":"devlist","action":{"type":"list"}}]}
        """
        try manifest.write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let script = folder.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho '{}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return folder
    }

    static func archive(_ id: String, version: String, name: String = "Dev Install", in scratch: URL) throws -> URL {
        let source = try folder(id, version: version, name: name, in: scratch)
        let zip = scratch.appendingPathComponent("\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return zip
    }

    /// One stored entry named `../escaped`.
    private static func slipArchive(in scratch: URL) throws -> URL {
        let name = Data("../escaped".utf8)
        var local = Data([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        local += Data(count: 12) + Data([UInt8(name.count), 0, 0, 0]) + name
        var central = Data([0x50, 0x4B, 0x01, 0x02, 20, 3, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        central += Data(count: 12) + Data([UInt8(name.count), 0]) + Data(count: 12) + Data(count: 4) + name
        var data = local + central
        data += Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, UInt8(central.count), 0, 0, 0,
                      UInt8(local.count), 0, 0, 0, 0, 0])
        let url = scratch.appendingPathComponent("slip.zip")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Frames in the root's coordinates, and any view that pokes outside the root.
    static func dumpFrames(_ root: NSView, tag: String) {
        root.layoutSubtreeIfNeeded()
        print("DEV frames \(tag): root \(root.bounds.size)")
        for view in descendants(root) where view is NSControl || view is NSScrollView {
            guard !view.isHidden, view.enclosingScrollView == nil || view is NSScrollView else { continue }
            let frame = view.convert(view.bounds, to: root)
            let label = (view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue.prefix(30).description
                ?? String(describing: type(of: view))
            let outside = root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) ? "" : "  OUTSIDE"
            print("  \(label): \(frame.integral)\(outside)")
        }
    }
}
#endif
