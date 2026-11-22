import Foundation

/// A plugin folder read from disk. One that cannot be used is still listed, with the
/// reason, so Settings can say what is wrong instead of showing nothing.
public struct InstalledPlugin: Sendable, Equatable {
    public let directory: URL
    /// Nil when `plugin.json` is missing or invalid.
    public let manifest: PluginManifest?
    public let problem: String?

    public var id: String { manifest?.id ?? directory.lastPathComponent }
    public var name: String { manifest?.name ?? directory.lastPathComponent }
    public var isUsable: Bool { manifest != nil && problem == nil }

    public var executableURL: URL? {
        manifest?.executable.map { directory.appendingPathComponent($0).standardizedFileURL }
    }

    static let entryIDPrefix = "com.igorv.spotlite.plugin."

    /// Stands in for a bundle identifier, so hiding, aliases and history key on it.
    public func entryID(for command: PluginCommand) -> String {
        entryID(forCommandID: command.id)
    }

    public func entryID(forCommandID commandID: String) -> String {
        InstalledPlugin.entryIDPrefix + id + "/" + commandID
    }

    /// The plugin's commands as search entries.
    public var entries: [AppEntry] {
        guard isUsable, let manifest else { return [] }
        return manifest.commands.compactMap { command in
            // Never opened: the URL only gives the entry an identity.
            URL(string: "spotlite-plugin:" + id + "/" + command.id).map {
                AppEntry(url: $0, name: command.title, bundleID: entryID(for: command), kind: .plugin)
            }
        }
    }
}

/// Reads, installs and removes plugin folders. Plugins live in Application Support
/// beside the preferences: like them, an installed plugin cannot be regenerated.
public enum PluginStore {

    public static let manifestName = "plugin.json"
    public static let maxManifestBytes = 256 * 1024

    public static var directory: URL {
        Storage.supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    /// Where a plugin may keep its own state, passed to it as `SPOTLITE_PLUGIN_DATA`.
    /// Outside the plugin's folder so replacing the plugin keeps its state.
    public static func dataDirectory(for id: String, in root: URL = Storage.supportDirectory) -> URL {
        root.appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Every folder in `directory`, by name. A symbolic link to a folder counts, so a
    /// plugin under development can stay where it is edited.
    public static func scan(directory: URL = directory) -> [InstalledPlugin] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen = Set<String>()
        return children
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let plugin = load(url)
                guard plugin.isUsable, !seen.insert(plugin.id.lowercased()).inserted else { return plugin }
                return InstalledPlugin(directory: url, manifest: plugin.manifest,
                                       problem: "Another plugin already uses the id \(plugin.id), ignoring letter case.")
            }
    }

    public static func load(_ directory: URL) -> InstalledPlugin {
        func broken(_ problem: String, _ manifest: PluginManifest? = nil) -> InstalledPlugin {
            InstalledPlugin(directory: directory, manifest: manifest, problem: problem)
        }
        guard let file = try? FileHandle(forReadingFrom: directory.appendingPathComponent(manifestName)) else {
            return broken("No \(manifestName) in this folder.")
        }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maxManifestBytes + 1) else {
            return broken("Couldn’t read \(manifestName).")
        }
        guard data.count <= maxManifestBytes else {
            return broken("\(manifestName) must fit within 256 KB.")
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return broken("\(manifestName) is not valid: \(describe(error))")
        }
        guard PluginManifest.isValidID(manifest.id), !manifest.id.hasPrefix(".") else {
            return broken("The plugin id may only contain letters, digits, dots, dashes and underscores, and cannot start with a dot.")
        }
        var commandIDs = Set<String>()
        for command in manifest.commands {
            guard PluginManifest.isValidID(command.id), commandIDs.insert(command.id).inserted else {
                return broken("Command ids must be unique and plain: \(command.id)", manifest)
            }
        }
        let plugin = InstalledPlugin(directory: directory, manifest: manifest, problem: nil)
        if let executable = plugin.executableURL {
            // The program must be the plugin's own: a manifest is not a way to name
            // an arbitrary path.
            let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
            let program = executable.resolvingSymlinksInPath().path
            guard program.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                return broken("The executable must be inside the plugin’s folder.", manifest)
            }
            // A folder is "executable" too, to the file system.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path) else {
                return broken("\(manifest.executable ?? "") is missing or not executable.", manifest)
            }
        } else if manifest.commands.contains(where: { command in
            needsExecutable(command.action) || command.actions.contains { needsExecutable($0.action) }
        }) {
            return broken("A command runs the plugin, but the manifest names no executable.", manifest)
        }
        return plugin
    }

    public enum InstallError: Error, Equatable {
        case invalid(String)
        case failed(String)

        public var message: String {
            switch self {
            case .invalid(let message), .failed(let message): message
            }
        }
    }

    /// Copies a plugin folder into the store, replacing its installed copy. The copy is
    /// checked before it is used, and the old one survives a failed replacement.
    /// `finalize` persists associated state after the swap; if it fails, the swap is
    /// undone. The backup stays on disk until finalization succeeds.
    @discardableResult
    public static func install(from source: URL, into directory: URL = directory,
                               beforeReplace: ((URL) throws -> Void)? = nil,
                               finalize: ((InstalledPlugin) throws -> Void)? = nil) throws(InstallError) -> InstalledPlugin {
        // Copy the folder itself, even when the selected path is a symbolic link.
        // Copying a relative link would make it point somewhere else after installing.
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = load(source)
        guard candidate.isUsable else {
            throw .invalid(candidate.problem ?? "This folder is not a Spotlite plugin.")
        }
        let files = FileManager.default
        // Manually installed folders and development links need not be named by id.
        // Replace the same plugin Settings identified instead of creating a duplicate.
        let installed = scan(directory: directory)
        if let collision = installed.first(where: { $0.id != candidate.id && $0.id.lowercased() == candidate.id.lowercased() }) {
            throw .invalid("The id \(candidate.id) differs from installed plugin \(collision.id) only by letter case. Choose a different id.")
        }
        let existing = installed.first { $0.manifest?.id == candidate.id }
        let destination = existing?.directory ?? directory.appendingPathComponent(candidate.id, isDirectory: true)
        if existing == nil, files.fileExists(atPath: destination.path) || isLink(destination) {
            throw .invalid("The folder \(destination.lastPathComponent) is already occupied. Rename that folder or choose a different plugin id.")
        }
        guard source != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            do { try finalize?(candidate) }
            catch let error as InstallError { throw error }
            catch { throw .failed(error.localizedDescription) }
            return candidate
        }
        let staging = directory.appendingPathComponent(".installing-" + UUID().uuidString, isDirectory: true)
        let backup = directory.appendingPathComponent(".replaced-" + UUID().uuidString, isDirectory: true)
        var replaced = false
        var backedUp = false
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: staging)
            let staged = load(staging)
            guard staged.isUsable, staged.id == candidate.id else {
                throw InstallError.invalid(staged.problem ?? "The plugin changed while it was being installed.")
            }
            try beforeReplace?(staging)
            if !isLink(destination), files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staging,
                                            backupItemName: finalize == nil ? nil : backup.lastPathComponent,
                                            options: finalize == nil ? [] : [.withoutDeletingBackupItem])
                backedUp = finalize != nil
            } else {
                // A link gives way to the copy, dangling or not; what it points at stays.
                if isLink(destination) {
                    try files.moveItem(at: destination, to: backup)
                    backedUp = true
                }
                try files.moveItem(at: staging, to: destination)
            }
            replaced = true
            let installed = load(destination)
            try finalize?(installed)
            if backedUp { try? files.removeItem(at: backup) }
            return installed
        } catch {
            try? files.removeItem(at: staging)
            if replaced || backedUp {
                do {
                    if backedUp {
                        // Rename restores the original directory or link without
                        // copying its contents a second time.
                        if isLink(backup) {
                            // replaceItemAt can follow the replacement link. Move
                            // the link itself so its target remains untouched.
                            if files.fileExists(atPath: destination.path) || isLink(destination) {
                                try files.removeItem(at: destination)
                            }
                            try files.moveItem(at: backup, to: destination)
                        } else if files.fileExists(atPath: destination.path) || isLink(destination) {
                            _ = try files.replaceItemAt(destination, withItemAt: backup)
                        } else {
                            try files.moveItem(at: backup, to: destination)
                        }
                    } else {
                        try files.removeItem(at: destination)
                    }
                } catch {
                    let recovery = backedUp ? "Its backup is at \(backup.path)." : "The new copy is at \(destination.path)."
                    throw .failed("Couldn’t undo the installation: \(error.localizedDescription) \(recovery)")
                }
            }
            if let error = error as? InstallError { throw error }
            throw .failed(error.localizedDescription)
        }
    }

    /// Moves the plugin to the Trash, so a removal can be undone from Finder. A linked
    /// plugin loses only its link.
    public static func remove(_ plugin: InstalledPlugin) throws {
        if isLink(plugin.directory) {
            try FileManager.default.removeItem(atPath: plugin.directory.path)
        } else {
            try FileManager.default.trashItem(at: plugin.directory, resultingItemURL: nil)
        }
    }

    /// By path, which has no trailing slash: with one, a link would answer for its target.
    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func needsExecutable(_ action: PluginAction) -> Bool {
        switch action {
        case .run, .list, .search: true
        case .open, .copy: false
        // A menu row's secondary actions run the plugin as surely as its Return does.
        case .menu(let items, _): items.contains { item in
            (item.action.map(needsExecutable) ?? false) || item.actions.contains { needsExecutable($0.action) }
        }
        }
    }

    /// The decoder's own wording names the key, which is what a plugin author needs.
    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): "missing “\(key.stringValue)”."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            (context.codingPath.map(\.stringValue) + [context.debugDescription]).joined(separator: ": ")
        default: error.localizedDescription
        }
    }
}
