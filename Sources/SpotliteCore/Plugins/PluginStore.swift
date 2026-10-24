import Foundation

public struct InstalledPlugin: Codable, Sendable, Equatable, Identifiable {
    public var id: String { manifest.id }
    public var manifest: PluginManifest
    public var enabled: Bool
    public var globalSearch: Bool
    public var developmentPath: String?
    public var bundled: Bool
    public var showCommands: Bool
    public init(manifest: PluginManifest, enabled: Bool = true, globalSearch: Bool = false,
                developmentPath: String? = nil, bundled: Bool = false, showCommands: Bool = true) {
        self.manifest = manifest; self.enabled = enabled; self.globalSearch = globalSearch
        self.developmentPath = developmentPath; self.bundled = bundled
        self.showCommands = showCommands
    }
    private enum CodingKeys: String, CodingKey { case manifest, enabled, globalSearch, developmentPath, bundled, showCommands }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decode(PluginManifest.self, forKey: .manifest)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        globalSearch = try c.decode(Bool.self, forKey: .globalSearch)
        developmentPath = try c.decodeIfPresent(String.self, forKey: .developmentPath)
        bundled = try c.decode(Bool.self, forKey: .bundled)
        showCommands = try c.decodeIfPresent(Bool.self, forKey: .showCommands) ?? true
    }
}

/// Serializes package mutations. A failed import/update never replaces working code.
public actor PluginStore {
    public nonisolated let root: URL
    private var records: [InstalledPlugin] = []
    private var removedBundled: Set<String> = []
    private var loaded = false
    private struct Registry: Codable {
        var version = 1
        var plugins: [InstalledPlugin]
        var removedBundled: Set<String>
    }

    public init(root: URL) { self.root = root }

    public nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotlite/Plugins", isDirectory: true)
    }

    public nonisolated static func snapshot(root: URL = defaultRoot) throws -> [InstalledPlugin] {
        let file = root.appendingPathComponent("registry.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        guard registry.version == 1 else { throw PluginError.invalid("Unsupported plugin registry version.") }
        return registry.plugins
    }

    public func load(bundledDirectory: URL? = nil, legacyHiddenUtilityIDs: Set<String> = []) throws -> [InstalledPlugin] {
        if !loaded {
            let file = root.appendingPathComponent("registry.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
                guard registry.version == 1 else { throw PluginError.invalid("Unsupported plugin registry version.") }
                records = registry.plugins
                removedBundled = registry.removedBundled
            }
            loaded = true
        }
        if let bundledDirectory,
           let folders = try? FileManager.default.contentsOfDirectory(at: bundledDirectory, includingPropertiesForKeys: nil) {
            for folder in folders where folder.pathExtension == "spotliteplugin" {
                let manifest = try Self.inspect(folder)
                guard !records.contains(where: { $0.id == manifest.id }), !removedBundled.contains(manifest.id) else { continue }
                _ = try install(folder, bundled: true)
                if let legacy = manifest.legacyUtilityID, legacyHiddenUtilityIDs.contains(legacy) {
                    _ = try updateRecord(manifest.id) { $0.showCommands = false }
                }
            }
        }
        return records
    }

    public nonisolated func packageURL(_ plugin: InstalledPlugin) -> URL {
        plugin.developmentPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("Packages/\(plugin.id)", isDirectory: true)
    }
    public nonisolated func dataURL(_ id: String) -> URL {
        root.appendingPathComponent("Data/\(id)", isDirectory: true)
    }
    public nonisolated func backupURL(_ id: String) -> URL {
        root.appendingPathComponent("Previous/\(id)", isDirectory: true)
    }

    @discardableResult
    public func install(_ source: URL, development: Bool = false, bundled: Bool = false,
                        expectedID: String? = nil, expectedVersion: String? = nil) throws -> InstalledPlugin {
        guard loaded else { throw PluginError.invalid("Plugin registry is not loaded.") }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath == "/" || rootPath == sourcePath || rootPath.hasPrefix(sourcePath + "/") {
            throw PluginError.invalid("The source package cannot contain Spotlite's managed plugin directory.")
        }
        let staging = root.appendingPathComponent("Staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var removeStaging = true
        defer { if removeStaging { try? FileManager.default.removeItem(at: staging) } }
        let package: URL
        if source.pathExtension.lowercased() == "zip" || source.pathExtension.lowercased() == "spotlitepluginzip" {
            guard !development else { throw PluginError.invalid("Development plugins must be folders.") }
            let archive = try PluginArchive.read(source)
            try PluginArchive.validate(archive)
            let stagedArchive = staging.appendingPathComponent("package.zip")
            try archive.write(to: stagedArchive)
            let unpacked = staging.appendingPathComponent("Unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", stagedArchive.path, unpacked.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { throw PluginError.invalid("Could not unpack the plugin ZIP.") }
            package = try Self.findPackage(in: unpacked)
        } else { package = source }
        let manifest = try Self.inspect(package)
        if let expectedID, manifest.id != expectedID {
            throw PluginError.invalid("Update contains a different plugin ID. The installed version was preserved.")
        }
        if let expectedVersion, manifest.version != expectedVersion {
            throw PluginError.invalid("Downloaded package version does not match the update. The installed version was preserved.")
        }
        let existing = records.first { $0.id == manifest.id }
        let record = InstalledPlugin(manifest: manifest, enabled: existing?.enabled ?? true,
                                     globalSearch: existing?.globalSearch ?? false,
                                     developmentPath: development ? package.standardizedFileURL.path : nil,
                                     bundled: bundled || existing?.bundled == true,
                                     showCommands: existing?.showCommands ?? true)
        let destination = root.appendingPathComponent("Packages/\(manifest.id)", isDirectory: true)
        let backup = backupURL(manifest.id)
        let previous = records
        var moves: [(source: URL, destination: URL)] = []
        do {
            if !development {
                let candidate = staging.appendingPathComponent("candidate")
                try FileManager.default.copyItem(at: package, to: candidate)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    if FileManager.default.fileExists(atPath: backup.path) {
                        let retiredBackup = staging.appendingPathComponent("previous")
                        try FileManager.default.moveItem(at: backup, to: retiredBackup)
                        moves.append((backup, retiredBackup))
                    }
                    try FileManager.default.moveItem(at: destination, to: backup)
                    moves.append((destination, backup))
                }
                try FileManager.default.moveItem(at: candidate, to: destination)
                moves.append((candidate, destination))
            }
            records.removeAll { $0.id == manifest.id }
            records.append(record)
            try save()
        } catch {
            records = previous
            do { try Self.restoreMoves(moves) }
            catch let recoveryError {
                removeStaging = false
                throw PluginError.failed("Plugin installation failed: \(error.localizedDescription) Recovery also failed: \(recoveryError.localizedDescription) Package files were retained at \(staging.path).")
            }
            throw error
        }
        return record
    }

    public func refreshDevelopment(_ id: String) throws -> InstalledPlugin {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].developmentPath != nil else {
            throw PluginError.invalid("This is not a development plugin.")
        }
        let manifest = try Self.inspect(packageURL(records[index]))
        guard manifest.id == id else { throw PluginError.invalid("A development plugin cannot change its ID.") }
        return try updateRecord(id) { $0.manifest = manifest }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws -> [InstalledPlugin] {
        _ = try updateRecord(id) { $0.enabled = enabled }
        return records
    }
    public func setGlobalSearch(_ id: String, _ enabled: Bool) throws -> [InstalledPlugin] {
        _ = try updateRecord(id) { $0.globalSearch = enabled }
        return records
    }
    public func setShowCommands(_ id: String, _ visible: Bool) throws -> [InstalledPlugin] {
        _ = try updateRecord(id) { $0.showCommands = visible }
        return records
    }

    private func updateRecord(_ id: String, _ update: (inout InstalledPlugin) -> Void) throws -> InstalledPlugin {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw PluginError.invalid("Plugin is not installed.") }
        let previous = records[index]
        update(&records[index])
        do { try save() } catch { records[index] = previous; throw error }
        return records[index]
    }

    public func rollback(_ id: String) throws -> InstalledPlugin {
        guard let current = records.first(where: { $0.id == id }), current.developmentPath == nil else {
            throw PluginError.invalid("Only installed packages can be rolled back.")
        }
        return try install(backupURL(id), bundled: current.bundled, expectedID: id)
    }

    public func uninstall(_ id: String, removeData: Bool) throws -> [InstalledPlugin] {
        guard let record = records.first(where: { $0.id == id }) else { return records }
        let staging = root.appendingPathComponent("Staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var removeStaging = true
        defer { if removeStaging { try? FileManager.default.removeItem(at: staging) } }
        let previous = records
        let oldRemoved = removedBundled
        var artifacts = [backupURL(id)]
        if record.developmentPath == nil { artifacts.append(packageURL(record)) }
        if removeData { artifacts.append(dataURL(id)) }
        var moves: [(source: URL, destination: URL)] = []
        do {
            for (index, artifact) in artifacts.enumerated() where FileManager.default.fileExists(atPath: artifact.path) {
                if let developmentPath = record.developmentPath {
                    let source = URL(fileURLWithPath: developmentPath).resolvingSymlinksInPath().standardizedFileURL.path
                    let path = artifact.resolvingSymlinksInPath().standardizedFileURL.path
                    guard source != path, !source.hasPrefix(path + "/") else {
                        throw PluginError.invalid("Cannot remove an artifact containing the development source: \(artifact.path).")
                    }
                }
                let staged = staging.appendingPathComponent(String(index))
                try FileManager.default.moveItem(at: artifact, to: staged)
                moves.append((artifact, staged))
            }
            records.removeAll { $0.id == id }
            if record.bundled { removedBundled.insert(id) }
            try save()
        } catch {
            records = previous
            removedBundled = oldRemoved
            do { try Self.restoreMoves(moves) }
            catch let recoveryError {
                removeStaging = false
                throw PluginError.failed("Plugin removal failed: \(error.localizedDescription) Recovery also failed: \(recoveryError.localizedDescription) Files were retained at \(staging.path).")
            }
            throw error
        }
        do { try FileManager.default.removeItem(at: staging) }
        catch {
            removeStaging = false
            throw PluginError.failed("Plugin was uninstalled, but its removed files could not be deleted at \(staging.path): \(error.localizedDescription)")
        }
        removeStaging = false
        return records
    }

    private nonisolated static func restoreMoves(_ moves: [(source: URL, destination: URL)]) throws {
        for move in moves.reversed() {
            try FileManager.default.moveItem(at: move.destination, to: move.source)
        }
    }

    public func settings(_ id: String) throws -> [String: PluginValue] {
        let url = dataURL(id).appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: PluginValue].self, from: Data(contentsOf: url))
    }
    public func saveSettings(_ id: String, values: [String: PluginValue]) throws {
        let dir = dataURL(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
    }

    public func storedValue(_ id: String, key: String) throws -> PluginValue {
        try storage(id)[key] ?? .null
    }

    public func storeValue(_ id: String, key: String, value: PluginValue?) throws {
        var values = try storage(id)
        values[key] = value
        let dir = dataURL(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: dir.appendingPathComponent("storage.json"), options: .atomic)
    }

    private func storage(_ id: String) throws -> [String: PluginValue] {
        let file = dataURL(id).appendingPathComponent("storage.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: PluginValue].self, from: Data(contentsOf: file))
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Registry(plugins: records, removedBundled: removedBundled))
            .write(to: root.appendingPathComponent("registry.json"), options: .atomic)
    }

    public nonisolated static func inspect(_ directory: URL) throws -> PluginManifest {
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PluginError.invalid("Choose a plugin folder, manifest.json, or ZIP package.")
        }
        let manifest = try JSONDecoder().decode(PluginManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        try manifest.validate()
        guard let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
            throw PluginError.invalid("Cannot read the plugin folder.")
        }
        var bytes = 0, files = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw PluginError.invalid("Plugin packages cannot contain symbolic links.") }
            bytes += values.fileSize ?? 0; files += 1
            guard bytes <= 64 * 1024 * 1024, files <= 10_000 else { throw PluginError.invalid("Plugin package exceeds 64 MiB or 10,000 files.") }
        }
        let entry = directory.appendingPathComponent(manifest.entryPoint)
        guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PluginError.invalid("The plugin entry file is missing.")
        }
        return manifest
    }

    private nonisolated static func findPackage(in directory: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        guard folders.count == 1,
              FileManager.default.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) else {
            throw PluginError.invalid("The ZIP must contain one plugin folder or a manifest at its root.")
        }
        return folders[0]
    }
}

/// Validate directory entries before the system extractor touches disk. ZIP64 and
/// symlinks are unnecessary for small source packages and are rejected explicitly.
public enum PluginArchive {
    private static let maximumSize = 80 * 1024 * 1024

    fileprivate static func read(_ source: URL) throws -> Data {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumSize else {
            throw PluginError.invalid("Invalid or oversized plugin ZIP.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumSize {
            guard let chunk = try handle.read(upToCount: maximumSize + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumSize else { throw PluginError.invalid("Invalid or oversized plugin ZIP.") }
        return data
    }

    public static func validate(_ data: Data) throws {
        guard data.count >= 22, data.count <= maximumSize else { throw PluginError.invalid("Invalid or oversized plugin ZIP.") }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == bytes.count }) else {
            throw PluginError.invalid("Invalid ZIP directory.")
        }
        let count = u16(end + 10)
        var offset = u32(end + 16), total = 0
        guard u16(end + 4) == 0, u16(end + 6) == 0, count == u16(end + 8), count <= 10_000,
              offset <= end, u32(end + 12) == end - offset else { throw PluginError.invalid("Unsupported ZIP format.") }
        var names = Set<String>()
        for _ in 0..<count {
            guard offset >= 0, offset + 46 <= end, u32(offset) == 0x02014b50 else { throw PluginError.invalid("Invalid ZIP entry.") }
            let length = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32)
            guard offset + 46 + length + extra + comment <= end,
                  let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + length)], encoding: .utf8) else {
                throw PluginError.invalid("Invalid ZIP filename.")
            }
            let clean = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard PluginManifest.relativePath(clean), names.insert(name).inserted,
                  (u32(offset + 38) >> 16) & 0xf000 != 0xa000,
                  u16(offset + 8) & 1 == 0 else { throw PluginError.invalid("ZIP contains an unsafe path, duplicate, symlink or encrypted entry.") }
            let size = u32(offset + 24), local = u32(offset + 42)
            total += size
            guard size != 0xffff_ffff, total <= 64 * 1024 * 1024,
                  local + 30 <= offset, u32(local) == 0x04034b50,
                  u16(local + 26) == length, local + 30 + length <= offset,
                  bytes[(local + 30)..<(local + 30 + length)].elementsEqual(bytes[(offset + 46)..<(offset + 46 + length)]) else {
                throw PluginError.invalid("ZIP entries are inconsistent or exceed 64 MiB.")
            }
            offset += 46 + length + extra + comment
        }
        guard offset == end else { throw PluginError.invalid("Invalid ZIP directory length.") }
    }
}
