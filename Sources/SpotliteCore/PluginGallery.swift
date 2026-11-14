import Foundation

/// One plugin listed in the gallery index. Every address in `source` is one the
/// installer accepts, so installing goes through the usual confirmation.
public struct PluginGalleryEntry: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let description: String
    public let author: String
    public let version: String
    public let source: String
    public let homepage: URL?
    /// An SF Symbol name. Remote images are never fetched.
    public let icon: String?
    public let tags: [String]

    public init(id: String, name: String, description: String, author: String, version: String, source: String,
                homepage: URL? = nil, icon: String? = nil, tags: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.source = source
        self.homepage = homepage
        self.icon = icon
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, author, version, source, homepage, icon, tags }

    /// Strict for what the gallery needs, forgiving for decoration: a bad `homepage`,
    /// `icon` or tag is left out, a bad required field drops the entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, max: Int) throws -> String {
            let value = try container.decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= max else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Empty or too long")
            }
            return value
        }
        id = try text(.id, max: 100)
        guard PluginManifest.isValidID(id), !id.hasPrefix(".") else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid id")
        }
        name = try text(.name, max: 100)
        description = try text(.description, max: 500)
        author = try text(.author, max: 100)
        version = try text(.version, max: 50)
        source = try text(.source, max: 2048)
        guard (try? PluginInstallSource.parse(source)) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "Not an install address")
        }
        let page = (try? container.decodeIfPresent(String.self, forKey: .homepage)).flatMap { $0 }.flatMap(URL.init(string:))
        homepage = page?.scheme?.lowercased() == "https" && page?.host?.isEmpty == false ? page : nil
        let symbol = (try? container.decodeIfPresent(String.self, forKey: .icon)).flatMap { $0 }
        icon = symbol.flatMap(Self.isSymbolName) == true ? symbol : nil
        let tags = (try? container.decodeIfPresent([Lossy<String>].self, forKey: .tags)).flatMap { $0 } ?? []
        var seen = Set<String>()
        self.tags = tags.compactMap { $0.value?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 30 && seen.insert($0).inserted }
            .prefix(PluginGallery.maxTags).map { $0 }
    }

    /// `cup.and.saucer`, `1.circle`: lowercase letters, digits and dots.
    static func isSymbolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 100 && !name.hasPrefix(".") && !name.hasSuffix(".")
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }
    }

    /// The parsed `source`. Never nil for a decoded entry.
    public var installSource: PluginInstallSource? { try? PluginInstallSource.parse(source) }
}

/// The gallery's list after decoding: usable entries in the index's order, and how many
/// were left out as invalid, duplicate or past the entry limit.
public struct PluginGalleryIndex: Sendable, Equatable {
    public let entries: [PluginGalleryEntry]
    public let skipped: Int

    public init(entries: [PluginGalleryEntry], skipped: Int = 0) {
        self.entries = entries
        self.skipped = skipped
    }
}

/// Where an entry stands against what is installed.
public enum PluginGalleryStatus: Sendable, Equatable {
    case notInstalled
    /// The same version, or a newer one than the gallery lists.
    case installed(version: String?)
    /// The gallery lists a newer version, or a different one that cannot be ordered.
    case updateAvailable(installed: String?)
}

/// The plugin gallery: one JSON index of plugins and their install addresses, read only
/// when the user opens the gallery. It lists plugins; it doesn't review them.
public enum PluginGallery {
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/ivalkenburg/spotlite/main/plugins/index.json")!
    public static let formatVersion = 1
    public static let maxBytes: Int64 = 1024 * 1024
    public static let maxEntries = 500
    static let maxTags = 8

    /// The index address: `defaultURL`, or a debug override that may be a `file:` URL.
    /// Anything else in the override is ignored.
    public static func indexURL(override: String?) -> URL {
        guard let override, let url = URL(string: override.trimmingCharacters(in: .whitespaces)) else { return defaultURL }
        switch url.scheme?.lowercased() {
        case "https" where url.host?.isEmpty == false, "file": return url
        default: return defaultURL
        }
    }

    /// Reads the index: over https through `loader` (redirects stay https), or a `file:`
    /// URL from disk when `allowsFileURLs`, which only debug builds pass.
    public static func fetch(from url: URL, loader: any PluginDownloading,
                             allowsFileURLs: Bool = false) async throws(PluginInstallError) -> PluginGalleryIndex {
        let data: Data
        switch url.scheme?.lowercased() {
        case "file" where allowsFileURLs:
            guard let file = try? FileHandle(forReadingFrom: url) else {
                throw .download("There is no gallery index at \(url.path).")
            }
            defer { try? file.close() }
            guard let read = try? file.read(upToCount: Int(maxBytes) + 1) else { throw .download("Couldn’t read the gallery index.") }
            data = read
        case "https":
            guard let body = try await loader.data(from: url, limit: maxBytes) else {
                throw .download("The gallery index was not found (404).")
            }
            data = body
        default:
            throw .invalidAddress("Only https addresses are supported.")
        }
        guard data.count <= maxBytes else {
            throw .download("The gallery index is larger than \(PluginArchive.megabytes(maxBytes)).")
        }
        return try decode(data)
    }

    /// Decodes an index. An unknown format version is an error; an invalid entry is
    /// skipped, as is a later entry repeating an id, and anything past `maxEntries`.
    public static func decode(_ data: Data) throws(PluginInstallError) -> PluginGalleryIndex {
        guard data.count <= maxBytes else {
            throw .download("The gallery index is larger than \(PluginArchive.megabytes(maxBytes)).")
        }
        // The version first: a later format may change everything else.
        let version: Int
        do { version = try JSONDecoder().decode(Version.self, from: data).version }
        catch { throw .download("The gallery index is not valid: it needs a JSON object with a format version.") }
        guard version == formatVersion else {
            throw .download("The gallery index uses format version \(version), which this version of Spotlite can’t read. Updating Spotlite may help.")
        }
        let list: [Lossy<PluginGalleryEntry>]
        do { list = try JSONDecoder().decode(List.self, from: data).plugins }
        catch { throw .download("The gallery index has no plugin list.") }
        var seen = Set<String>()
        var entries: [PluginGalleryEntry] = []
        for item in list {
            guard entries.count < maxEntries, let entry = item.value, seen.insert(entry.id.lowercased()).inserted else { continue }
            entries.append(entry)
        }
        return PluginGalleryIndex(entries: entries, skipped: list.count - entries.count)
    }

    /// Compares an entry with the installed plugin of the same id, ignoring letter case.
    public static func status(of entry: PluginGalleryEntry, installed: [InstalledPlugin]) -> PluginGalleryStatus {
        guard let plugin = installed.first(where: { $0.id.lowercased() == entry.id.lowercased() }) else { return .notInstalled }
        let version = plugin.manifest?.version
        switch PluginVersion.compare(installed: version, remote: entry.version) {
        case .same, .older: return .installed(version: version)
        case .newer, .different: return .updateAvailable(installed: version)
        }
    }

    /// Entries whose name, id, description, author or tags contain every word of `query`,
    /// ignoring case and diacritics, in the index's order.
    public static func search(_ entries: [PluginGalleryEntry], query: String) -> [PluginGalleryEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = ([entry.name, entry.id, entry.description, entry.author] + entry.tags).joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private struct Version: Decodable { let version: Int }
    private struct List: Decodable { let plugins: [Lossy<PluginGalleryEntry>] }
}
