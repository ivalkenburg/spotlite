import Foundation
import Testing
@testable import SpotliteCore

/// Serves bodies by address and records what was asked, so no test reaches the network.
private final class GalleryLoader: PluginDownloading, @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var failure: PluginInstallError?
    private(set) var requested: [(url: String, limit: Int64)] = []

    func download(_ url: URL, to destination: URL, limit: Int64,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Bool { false }

    func data(from url: URL, limit: Int64) async throws(PluginInstallError) -> Data? {
        requested.append((url.absoluteString, limit))
        if let failure { throw failure }
        return bodies[url.absoluteString]
    }
}

@Suite("Plugin gallery")
struct PluginGalleryTests {
    private static func entry(_ id: String, version: String = "1.0.0", source: String? = nil,
                              extra: String = "") -> String {
        let source = source ?? "https://github.com/octo/\(id)"
        return #"{"id":"\#(id)","name":"\#(id.capitalized)","description":"Does \#(id).","author":"Octo","version":"\#(version)","source":"\#(source)"\#(extra)}"#
    }

    private static func index(_ entries: [String], version: Int = 1) -> Data {
        Data(#"{"version":\#(version),"plugins":[\#(entries.joined(separator: ","))]}"#.utf8)
    }

    private static func installed(_ id: String, version: String?) throws -> InstalledPlugin {
        let versionKey = version.map { #""version":"\#($0)","# } ?? ""
        let json = #"{"id":"\#(id)","name":"\#(id)",\#(versionKey)"commands":[{"id":"open","title":"Open","action":{"type":"open","url":"https://example.com"}}]}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        return InstalledPlugin(directory: URL(fileURLWithPath: "/tmp/\(id)"), manifest: manifest, problem: nil)
    }

    // MARK: - Decoding

    @Test func decodesEntriesInOrder() throws {
        let data = Self.index([
            Self.entry("alpha", extra: #","homepage":"https://example.com/alpha","icon":"cup.and.saucer","tags":["Fun","util","fun"]"#),
            Self.entry("beta", source: "https://example.com/beta.zip"),
        ])
        let index = try PluginGallery.decode(data)
        #expect(index.entries.map(\.id) == ["alpha", "beta"])
        #expect(index.skipped == 0)
        let alpha = index.entries[0]
        #expect(alpha.name == "Alpha" && alpha.author == "Octo" && alpha.version == "1.0.0")
        #expect(alpha.homepage == URL(string: "https://example.com/alpha"))
        #expect(alpha.icon == "cup.and.saucer")
        #expect(alpha.tags == ["fun", "util"])
        #expect(alpha.installSource == .github(owner: "octo", repository: "alpha", ref: nil, subpath: nil))
        #expect(index.entries[1].installSource == .archive(URL(string: "https://example.com/beta.zip")!))
    }

    @Test func dropsBadEntriesOnly() throws {
        let data = Self.index([
            Self.entry("good"),
            #"{"id":"missing-source","name":"X","description":"d","author":"a","version":"1"}"#,
            Self.entry("insecure", source: "http://example.com/p.zip"),
            Self.entry("../escape"),
            Self.entry(".hidden"),
            #"{"id":"blank","name":"  ","description":"d","author":"a","version":"1","source":"https://example.com/a.zip"}"#,
            #""not an object""#,
            #"{"id":"long","name":"\#(String(repeating: "n", count: 101))","description":"d","author":"a","version":"1","source":"https://example.com/a.zip"}"#,
            Self.entry("GOOD"),
            Self.entry("second"),
        ])
        let index = try PluginGallery.decode(data)
        // A repeated id, ignoring case, keeps the first.
        #expect(index.entries.map(\.id) == ["good", "second"])
        #expect(index.skipped == 8)
    }

    @Test func dropsBadDecorationButKeepsTheEntry() throws {
        let data = Self.index([
            Self.entry("plain", extra: #","homepage":"http://example.com","icon":"https://evil.example/icon.png","tags":["ok",3,"","\#(String(repeating: "t", count: 31))"]"#),
            Self.entry("odd", extra: #","homepage":42,"icon":"Bad Name","tags":"nope""#),
        ])
        let index = try PluginGallery.decode(data)
        #expect(index.entries.map(\.id) == ["plain", "odd"])
        #expect(index.entries[0].homepage == nil && index.entries[0].icon == nil && index.entries[0].tags == ["ok"])
        #expect(index.entries[1].homepage == nil && index.entries[1].icon == nil && index.entries[1].tags.isEmpty)
    }

    @Test func capsTags() throws {
        let tags = (1...12).map { "\"t\($0)\"" }.joined(separator: ",")
        let index = try PluginGallery.decode(Self.index([Self.entry("many", extra: #","tags":[\#(tags)]"#)]))
        #expect(index.entries[0].tags.count == PluginGallery.maxTags)
    }

    @Test func refusesUnknownVersionsAndShapes() throws {
        #expect(throws: PluginInstallError.self) { try PluginGallery.decode(Self.index([], version: 2)) }
        do {
            _ = try PluginGallery.decode(Self.index([Self.entry("a")], version: 2))
            Issue.record("version 2 accepted")
        } catch {
            #expect(error.message.contains("format version 2"))
        }
        for body in ["", "[]", "{}", #"{"version":"1","plugins":[]}"#, #"{"version":1}"#, #"{"version":1,"plugins":{}}"#] {
            #expect(throws: PluginInstallError.self, "\(body)") { try PluginGallery.decode(Data(body.utf8)) }
        }
        #expect(try PluginGallery.decode(Self.index([])).entries.isEmpty)
    }

    @Test func limitsSizeAndEntries() throws {
        let big = Data(count: Int(PluginGallery.maxBytes) + 1)
        #expect(throws: PluginInstallError.self) { try PluginGallery.decode(big) }
        let entries = (0..<(PluginGallery.maxEntries + 5)).map { Self.entry("p\($0)") }
        let index = try PluginGallery.decode(Self.index(entries))
        #expect(index.entries.count == PluginGallery.maxEntries)
        #expect(index.entries.last?.id == "p\(PluginGallery.maxEntries - 1)")
        #expect(index.skipped == 5)
    }

    // MARK: - Fetching

    @Test func fetchesOverHTTPSWithTheSizeLimit() async throws {
        let loader = GalleryLoader()
        let url = PluginGallery.defaultURL
        loader.bodies[url.absoluteString] = Self.index([Self.entry("alpha")])
        let index = try await PluginGallery.fetch(from: url, loader: loader)
        #expect(index.entries.map(\.id) == ["alpha"])
        #expect(loader.requested.map(\.url) == [url.absoluteString])
        #expect(loader.requested.first?.limit == PluginGallery.maxBytes)
    }

    @Test func fetchReportsMissingAndFailedIndexes() async {
        let loader = GalleryLoader()
        await #expect(throws: PluginInstallError.download("The gallery index was not found (404).")) {
            try await PluginGallery.fetch(from: PluginGallery.defaultURL, loader: loader)
        }
        loader.failure = .download("The server redirected to an address that is not https.")
        await #expect(throws: PluginInstallError.download("The server redirected to an address that is not https.")) {
            try await PluginGallery.fetch(from: PluginGallery.defaultURL, loader: loader)
        }
    }

    @Test func fetchRefusesOtherSchemes() async throws {
        let loader = GalleryLoader()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-\(UUID().uuidString).json")
        try Self.index([Self.entry("local")]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for url in [URL(string: "http://example.com/index.json")!, file] {
            await #expect(throws: PluginInstallError.invalidAddress("Only https addresses are supported.")) {
                try await PluginGallery.fetch(from: url, loader: loader)
            }
        }
        #expect(loader.requested.isEmpty)
        // Debug builds may read a file instead.
        let index = try await PluginGallery.fetch(from: file, loader: loader, allowsFileURLs: true)
        #expect(index.entries.map(\.id) == ["local"])
        await #expect(throws: PluginInstallError.self) {
            try await PluginGallery.fetch(from: file.appendingPathExtension("missing"), loader: loader, allowsFileURLs: true)
        }
    }

    @Test func fetchLimitsFileSize() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-\(UUID().uuidString).json")
        try Data(count: Int(PluginGallery.maxBytes) + 10).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: PluginInstallError.self) {
            try await PluginGallery.fetch(from: file, loader: GalleryLoader(), allowsFileURLs: true)
        }
    }

    @Test func indexURLOverride() {
        #expect(PluginGallery.indexURL(override: nil) == PluginGallery.defaultURL)
        #expect(PluginGallery.indexURL(override: "http://example.com/i.json") == PluginGallery.defaultURL)
        #expect(PluginGallery.indexURL(override: "ftp://example.com/i.json") == PluginGallery.defaultURL)
        #expect(PluginGallery.indexURL(override: "https://example.com/i.json") == URL(string: "https://example.com/i.json"))
        #expect(PluginGallery.indexURL(override: "file:///tmp/i.json") == URL(string: "file:///tmp/i.json"))
        #expect(PluginGallery.defaultURL.scheme == "https")
    }

    // MARK: - Status and search

    @Test func statusAgainstInstalledPlugins() throws {
        let entry = try PluginGallery.decode(Self.index([Self.entry("demo", version: "1.2.0")])).entries[0]
        #expect(PluginGallery.status(of: entry, installed: []) == .notInstalled)
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("other", version: "1.0.0")]) == .notInstalled)
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("demo", version: "1.2.0")]) == .installed(version: "1.2.0"))
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("Demo", version: "v1.2")]) == .installed(version: "v1.2"))
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("demo", version: "1.10.0")]) == .installed(version: "1.10.0"))
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("demo", version: "1.1.9")]) == .updateAvailable(installed: "1.1.9"))
        #expect(PluginGallery.status(of: entry, installed: [try Self.installed("demo", version: nil)]) == .updateAvailable(installed: nil))
        let broken = InstalledPlugin(directory: URL(fileURLWithPath: "/tmp/demo"), manifest: nil, problem: "bad")
        #expect(PluginGallery.status(of: entry, installed: [broken]) == .updateAvailable(installed: nil))
    }

    @Test func searchMatchesEveryWord() throws {
        let entries = try PluginGallery.decode(Self.index([
            Self.entry("caffeinate", extra: #","tags":["power"]"#),
            Self.entry("kubectx", extra: #","tags":["kubernetes","dev"]"#),
            Self.entry("github", extra: #","tags":["dev"]"#),
        ])).entries
        #expect(PluginGallery.search(entries, query: "") .map(\.id) == ["caffeinate", "kubectx", "github"])
        #expect(PluginGallery.search(entries, query: "  ").count == 3)
        #expect(PluginGallery.search(entries, query: "DEV").map(\.id) == ["kubectx", "github"])
        #expect(PluginGallery.search(entries, query: "dev kube").map(\.id) == ["kubectx"])
        #expect(PluginGallery.search(entries, query: "does caff").map(\.id) == ["caffeinate"])
        #expect(PluginGallery.search(entries, query: "octo").count == 3)
        #expect(PluginGallery.search(entries, query: "nothing").isEmpty)
    }

    /// The index shipped in the repository decodes whole, and every source is one the
    /// installer accepts.
    @Test func repositoryIndexDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/index.json")
        let index = try PluginGallery.decode(try Data(contentsOf: url))
        #expect(index.skipped == 0)
        #expect(Set(index.entries.map(\.id)) == ["caffeinate", "kubectx", "github", "findfiles"])
        for entry in index.entries {
            guard case .github(let owner, let repository, let ref, let subpath) = entry.installSource else {
                Issue.record("\(entry.id) is not a GitHub source")
                continue
            }
            #expect(owner == "ivalkenburg" && repository == "spotlite" && ref == "main")
            #expect(subpath == "examples/plugins/\(entry.id)")
            let manifest = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("examples/plugins/\(entry.id)/plugin.json")
            let plugin = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifest))
            #expect(plugin.version == entry.version, "\(entry.id) lists \(entry.version), its manifest \(plugin.version ?? "none")")
            #expect(plugin.name == entry.name)
        }
    }
}
