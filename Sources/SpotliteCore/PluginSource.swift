import Foundation

/// Why installing or checking a plugin from an address failed, worded for the user.
public enum PluginInstallError: Error, Equatable, Sendable {
    case invalidAddress(String)
    case download(String)
    case archive(String)
    case notAPlugin(String)
    case install(String)
    case cancelled

    public var message: String {
        switch self {
        case .invalidAddress(let message), .download(let message), .archive(let message),
             .notAPlugin(let message), .install(let message): message
        case .cancelled: "Cancelled."
        }
    }
}

/// Where a plugin can be installed from. Only `https` addresses are accepted.
public enum PluginInstallSource: Sendable, Equatable {
    /// A GitHub repository, optionally at a branch, tag or commit, and a folder in it.
    /// A nil `ref` is the default branch.
    case github(owner: String, repository: String, ref: String?, subpath: String?)
    /// A `.zip` archive, or any address that answers with one.
    case archive(URL)
    /// A git repository cloned with `git clone --depth 1`; `ref` is a branch or tag.
    case git(URL, ref: String?)

    /// Reads what the user typed. `github.com/owner/repo` may omit the scheme.
    ///
    /// GitHub `…/tree/<ref>/<folder>` addresses take the first segment as the ref.
    /// `githubCandidates` lists the other ways to split them, for refs containing `/`.
    public static func parse(_ text: String) throws(PluginInstallError) -> PluginInstallSource {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidAddress("Enter an address.") }
        if text.lowercased().hasPrefix("github.com/") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw .invalidAddress("“\(text)” is not an address.")
        }
        guard scheme == "https" else {
            throw .invalidAddress("Only https addresses are supported.")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw .invalidAddress("The address has no host.")
        }
        guard url.user == nil, url.password == nil else {
            throw .invalidAddress("Addresses with a user name or password are not supported.")
        }
        if host == "github.com" || host == "www.github.com" {
            return try github(url)
        }
        let path = url.path.lowercased()
        if path.hasSuffix(".git") {
            var plain = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let ref = plain.fragment.flatMap { $0.isEmpty ? nil : $0 }
            if let ref, !isPlainRef(ref) { throw .invalidAddress("The ref “\(ref)” is not valid.") }
            plain.fragment = nil
            return .git(plain.url!, ref: ref)
        }
        return .archive(url)
    }

    private static func github(_ url: URL) throws(PluginInstallError) -> PluginInstallSource {
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else {
            throw .invalidAddress("A GitHub address needs an owner and a repository, like https://github.com/owner/repo.")
        }
        let owner = parts.removeFirst()
        var repository = parts.removeFirst()
        if repository.lowercased().hasSuffix(".git") { repository.removeLast(4) }
        guard isPlainName(owner), isPlainName(repository) else {
            throw .invalidAddress("“\(owner)/\(repository)” is not a GitHub repository name.")
        }
        guard let kind = parts.first else {
            return .github(owner: owner, repository: repository, ref: nil, subpath: nil)
        }
        switch kind {
        case "tree", "blob":
            parts.removeFirst()
            guard let ref = parts.first, isPlainRef(ref) else {
                throw .invalidAddress("The address names no branch, tag or commit after /\(kind)/.")
            }
            parts.removeFirst()
            // A link to the manifest itself means its folder.
            if kind == "blob" {
                guard parts.last == PluginStore.manifestName else {
                    throw .invalidAddress("Link to the plugin’s folder or its \(PluginStore.manifestName), not another file.")
                }
                parts.removeLast()
            }
            let subpath = parts.isEmpty ? nil : parts.joined(separator: "/")
            if let subpath, !isPlainSubpath(subpath) {
                throw .invalidAddress("The folder “\(subpath)” is not valid.")
            }
            return .github(owner: owner, repository: repository, ref: ref, subpath: subpath)
        case "archive" where url.path.lowercased().hasSuffix(".zip"),
             "releases" where url.path.lowercased().hasSuffix(".zip"):
            return .archive(url)
        default:
            throw .invalidAddress("That GitHub address is not a repository or a folder in one.")
        }
    }

    /// Other readings of a GitHub `tree` address whose ref may contain `/`, longest
    /// folder first: `tree/feat/x/plugin` is ref `feat`, then `feat/x`, then `feat/x/plugin`.
    public var githubCandidates: [PluginInstallSource] {
        guard case .github(let owner, let repository, let ref?, let subpath) = self else { return [self] }
        let segments = [ref] + (subpath?.split(separator: "/").map(String.init) ?? [])
        return (1...segments.count).map { count in
            let rest = segments.dropFirst(count).joined(separator: "/")
            return .github(owner: owner, repository: repository,
                           ref: segments.prefix(count).joined(separator: "/"), subpath: rest.isEmpty ? nil : rest)
        }
    }

    /// The address to show and to store: a GitHub source as it would be linked.
    public var address: String {
        switch self {
        case .github(let owner, let repository, let ref, let subpath):
            var text = "https://github.com/\(owner)/\(repository)"
            if let ref { text += "/tree/" + Self.encode(ref) + (subpath.map { "/" + Self.encode($0) } ?? "") }
            return text
        case .archive(let url): return url.absoluteString
        case .git(let url, let ref): return url.absoluteString + (ref.map { "#" + $0 } ?? "")
        }
    }

    public var ref: String? {
        switch self {
        case .github(_, _, let ref, _), .git(_, let ref): ref
        case .archive: nil
        }
    }

    /// The folder inside the downloaded tree that holds `plugin.json`.
    public var subpath: String? {
        if case .github(_, _, _, let subpath) = self { return subpath }
        return nil
    }

    /// What to download: GitHub's zip of the ref, or the archive itself. Nil for git.
    public var archiveURL: URL? {
        switch self {
        case .github(let owner, let repository, let ref, _):
            // HEAD is the default branch. Codeload takes refs with `/` as they are.
            return URL(string: "https://codeload.github.com/\(owner)/\(repository)/zip/" + Self.encode(ref ?? "HEAD"))
        case .archive(let url): return url
        case .git: return nil
        }
    }

    /// The manifest alone, for an update check without downloading the plugin. Only
    /// GitHub serves one; other sources are checked by staging them.
    public var manifestURL: URL? {
        guard case .github(let owner, let repository, let ref, let subpath) = self else { return nil }
        let path = [ref ?? "HEAD", subpath, PluginStore.manifestName].compactMap { $0 }.joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/" + Self.encode(path))
    }

    private static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ";?#%"))) ?? path
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    /// Git's own rules, loosely: no spaces, control characters, `..` or `~^:?*[\`.
    static func isPlainRef(_ ref: String) -> Bool {
        !ref.isEmpty && ref.count <= 255 && !ref.contains("..") && !ref.hasPrefix("-") && !ref.hasPrefix("/")
            && !ref.hasSuffix("/") && ref.unicodeScalars.allSatisfy {
                $0.value > 0x20 && $0.value != 0x7F && !"~^:?*[\\ ".unicodeScalars.contains($0)
            }
    }

    static func isPlainSubpath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }
}

// MARK: - Versions

/// Compares manifest versions. Semantic versions compare by number (`1.10` is newer
/// than `1.9`, missing parts are zero, a leading `v` is ignored, `1.0.0-beta` precedes
/// `1.0.0`, build metadata after `+` is ignored). Anything else only equals itself.
public enum PluginVersion {
    public enum Order: Sendable, Equatable {
        case older, same, newer
        /// Not comparable, and not the same text: the remote one is offered as an update.
        case different
    }

    /// How `remote` relates to `installed`. A missing version is the empty string.
    public static func compare(installed: String?, remote: String?) -> Order {
        let a = (installed ?? "").trimmingCharacters(in: .whitespaces)
        let b = (remote ?? "").trimmingCharacters(in: .whitespaces)
        guard let x = Parsed(a), let y = Parsed(b) else { return a == b ? .same : .different }
        switch y.compare(to: x) {
        case .orderedAscending: return .older
        case .orderedSame: return .same
        case .orderedDescending: return .newer
        }
    }

    private struct Parsed {
        let numbers: [Int]
        let prerelease: [String]

        init?(_ text: String) {
            var text = Substring(text)
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
            var pre: [String] = []
            if let dash = text.firstIndex(of: "-") {
                pre = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
                text = text[..<dash]
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 4 else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
                numbers.append(number)
            }
            self.numbers = numbers
            self.prerelease = pre
        }

        func compare(to other: Parsed) -> ComparisonResult {
            for index in 0..<max(numbers.count, other.numbers.count) {
                let a = index < numbers.count ? numbers[index] : 0
                let b = index < other.numbers.count ? other.numbers[index] : 0
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
            // A prerelease precedes its release.
            switch (prerelease.isEmpty, other.prerelease.isEmpty) {
            case (true, true): return .orderedSame
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            case (false, false): break
            }
            for (a, b) in zip(prerelease, other.prerelease) where a != b {
                let numeric = { (text: String) in text.utf8.allSatisfy { (48...57).contains($0) } }
                switch (numeric(a), numeric(b)) {
                case (true, true):
                    // Semver places no machine-integer bound on numeric identifiers.
                    let x = a.drop { $0 == "0" }, y = b.drop { $0 == "0" }
                    if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
                    if x != y { return x < y ? .orderedAscending : .orderedDescending }
                case (true, false): return .orderedAscending
                case (false, true): return .orderedDescending
                case (false, false): return a < b ? .orderedAscending : .orderedDescending
                }
            }
            return prerelease.count == other.prerelease.count ? .orderedSame
                : prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
        }
    }
}

// MARK: - Source records

/// Where an installed plugin came from, so Settings can check it for an update.
/// Only plugins installed from an address have one.
public struct PluginSourceRecord: Codable, Sendable, Equatable {
    /// The source's `address`: what `PluginInstallSource.parse` reads back.
    public var address: String
    /// The ref asked for; nil is the default branch.
    public var ref: String?
    /// The commit that was installed, when the source reports one.
    public var commit: String?
    /// The manifest's version when it was installed.
    public var version: String?
    public var installedAt: Date

    public init(address: String, ref: String?, commit: String?, version: String?, installedAt: Date) {
        self.address = address
        self.ref = ref
        self.commit = commit
        self.version = version
        self.installedAt = installedAt
    }

    public var source: PluginInstallSource? {
        guard let source = try? PluginInstallSource.parse(address) else { return nil }
        // The saved ref disambiguates slashes that could also belong to the folder.
        // Do not reinterpret a successfully resolved ref on the next update.
        return ref.flatMap { ref in source.githubCandidates.first { $0.ref == ref } } ?? source
    }
}

/// Source records, one small JSON file per plugin id in
/// `Application Support/Spotlite/PluginSources`. Not in the plugin's folder, which an
/// update replaces and whose contents the plugin's author controls, and not in Caches,
/// because a lost record cannot be regenerated.
public struct PluginSourceStore: Sendable {
    public let directory: URL
    static let maxBytes = 16 * 1024

    public init(directory: URL = Storage.supportDirectory.appendingPathComponent("PluginSources", isDirectory: true)) {
        self.directory = directory
    }

    private func url(for id: String) -> URL? {
        guard PluginManifest.isValidID(id), !id.hasPrefix(".") else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    /// Nil when there is none, or it cannot be read.
    public func load(for id: String) -> PluginSourceRecord? {
        guard let url = url(for: id), let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PluginSourceRecord.self, from: data)
    }

    public func save(_ record: PluginSourceRecord, for id: String) throws {
        guard let url = url(for: id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func remove(for id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
