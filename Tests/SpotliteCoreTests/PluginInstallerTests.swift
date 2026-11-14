import Foundation
import Testing
@testable import SpotliteCore

/// Serves fixed bodies by address, so installer tests never reach the network.
private struct FixtureLoader: PluginDownloading {
    var files: [String: URL] = [:]
    var bodies: [String: Data] = [:]

    func download(_ url: URL, to destination: URL, limit: Int64,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Bool {
        guard let file = files[url.absoluteString] else { return false }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        } catch { throw .download("copy failed") }
        return true
    }

    func data(from url: URL, limit: Int64) async throws(PluginInstallError) -> Data? {
        bodies[url.absoluteString]
    }
}

/// A stored (uncompressed) zip with exact control over names, modes and sizes.
private struct ZipBuilder {
    struct Item { var name: String; var data: Data; var mode: UInt32; var declaredSize: UInt32? }
    var items: [Item] = []

    mutating func file(_ name: String, _ text: String, mode: UInt32 = 0o100644, declaredSize: UInt32? = nil) {
        items.append(Item(name: name, data: Data(text.utf8), mode: mode, declaredSize: declaredSize))
    }
    mutating func link(_ name: String, to target: String) { file(name, target, mode: 0o120755) }
    mutating func directory(_ name: String) { items.append(Item(name: name, data: Data(), mode: 0o040755)) }

    func build(comment: String = "") -> Data {
        var local = Data(), central = Data()
        for item in items {
            var crc = CRC32()
            crc.update(item.data)
            let name = Data(item.name.utf8)
            let size = UInt32(item.data.count)
            let offset = UInt32(local.count)
            local.append32(0x0403_4B50); local.append16(20); local.append16(0); local.append16(0)
            local.append16(0); local.append16(0x21); local.append32(crc.value)
            local.append32(size); local.append32(item.declaredSize ?? size)
            local.append16(UInt16(name.count)); local.append16(0); local.append(name); local.append(item.data)
            central.append32(0x0201_4B50); central.append16(3 << 8 | 20); central.append16(20); central.append16(0)
            central.append16(0); central.append16(0); central.append16(0x21); central.append32(crc.value)
            central.append32(size); central.append32(item.declaredSize ?? size)
            central.append16(UInt16(name.count)); central.append16(0); central.append16(0); central.append16(0)
            central.append16(0); central.append32(item.mode << 16); central.append32(offset); central.append(name)
        }
        var data = local
        data.append(central)
        data.append32(0x0605_4B50); data.append16(0); data.append16(0)
        data.append16(UInt16(items.count)); data.append16(UInt16(items.count))
        data.append32(UInt32(central.count)); data.append32(UInt32(local.count))
        let commentData = Data(comment.utf8)
        data.append16(UInt16(commentData.count)); data.append(commentData)
        return data
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append32(_ value: UInt32) { append16(UInt16(value & 0xFFFF)); append16(UInt16(value >> 16)) }
}

@Suite("Plugin installer")
final class PluginInstallerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlite-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private var plugins: URL { root.appendingPathComponent("Plugins", isDirectory: true) }
    private var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    private func installer(_ loader: FixtureLoader) throws -> PluginInstaller {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        return PluginInstaller(pluginsDirectory: plugins,
                               sources: PluginSourceStore(directory: root.appendingPathComponent("PluginSources")),
                               loader: loader, temporaryDirectory: temporary, git: nil)
    }

    private static func manifest(id: String = "demo", version: String = "1.0.0") -> String {
        #"{"id":"\#(id)","name":"Demo","version":"\#(version)","executable":"run.sh","commands":[{"id":"main","title":"Demo","action":{"type":"run"}}]}"#
    }

    /// A plugin folder zipped by ditto, inside a top folder like GitHub's archives.
    private func archive(top: String = "repo-abc", sub: String? = nil, id: String = "demo",
                         version: String = "1.0.0", comment: String? = nil) throws -> URL {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        let folder = source.appendingPathComponent(top).appendingPathComponent(sub ?? "")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.manifest(id: id, version: version).write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let script = folder.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho '{}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "readme".write(to: source.appendingPathComponent(top).appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.appendingPathComponent(top).path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
        if let comment {
            // Replace the empty comment ditto writes with the commit, as GitHub's has.
            var data = try Data(contentsOf: zip)
            #expect(data[data.count - 2] == 0 && data[data.count - 1] == 0)
            data.removeLast(2)
            data.append16(UInt16(comment.utf8.count))
            data.append(Data(comment.utf8))
            try data.write(to: zip)
        }
        return zip
    }

    private func write(_ builder: ZipBuilder) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try builder.build().write(to: url)
        return url
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
    }

    // MARK: - Addresses

    @Test func parsesGitHubAddresses() throws {
        #expect(try PluginInstallSource.parse("https://github.com/octo/tools")
                == .github(owner: "octo", repository: "tools", ref: nil, subpath: nil))
        #expect(try PluginInstallSource.parse(" github.com/octo/tools.git/ ")
                == .github(owner: "octo", repository: "tools", ref: nil, subpath: nil))
        #expect(try PluginInstallSource.parse("https://github.com/octo/tools/tree/v2")
                == .github(owner: "octo", repository: "tools", ref: "v2", subpath: nil))
        let nested = try PluginInstallSource.parse("https://github.com/octo/tools/tree/main/plugins/kube")
        #expect(nested == .github(owner: "octo", repository: "tools", ref: "main", subpath: "plugins/kube"))
        #expect(try PluginInstallSource.parse("https://github.com/octo/tools/blob/main/plugins/kube/plugin.json") == nested)
        #expect(nested.archiveURL?.absoluteString == "https://codeload.github.com/octo/tools/zip/main")
        #expect(nested.manifestURL?.absoluteString == "https://raw.githubusercontent.com/octo/tools/main/plugins/kube/plugin.json")
        #expect(nested.address == "https://github.com/octo/tools/tree/main/plugins/kube")
        #expect(try PluginInstallSource.parse(nested.address) == nested)
        let plain = try PluginInstallSource.parse("https://github.com/octo/tools")
        #expect(plain.archiveURL?.absoluteString == "https://codeload.github.com/octo/tools/zip/HEAD")
        #expect(plain.manifestURL?.absoluteString == "https://raw.githubusercontent.com/octo/tools/HEAD/plugin.json")
        #expect(try PluginInstallSource.parse("https://github.com/octo/tools/archive/refs/heads/main.zip")
                == .archive(URL(string: "https://github.com/octo/tools/archive/refs/heads/main.zip")!))
    }

    @Test func treeAddressesOfferEverySplitOfTheRef() throws {
        let source = try PluginInstallSource.parse("https://github.com/o/r/tree/feat/x/plugin")
        #expect(source.githubCandidates == [
            .github(owner: "o", repository: "r", ref: "feat", subpath: "x/plugin"),
            .github(owner: "o", repository: "r", ref: "feat/x", subpath: "plugin"),
            .github(owner: "o", repository: "r", ref: "feat/x/plugin", subpath: nil),
        ])
        #expect(PluginInstallSource.github(owner: "o", repository: "r", ref: "feat/x", subpath: "plugin").archiveURL?
            .absoluteString == "https://codeload.github.com/o/r/zip/feat/x")
    }

    @Test func parsesOtherAddresses() throws {
        #expect(try PluginInstallSource.parse("https://example.com/p/plugin.zip")
                == .archive(URL(string: "https://example.com/p/plugin.zip")!))
        #expect(try PluginInstallSource.parse("https://git.example.com/me/plugin.git#v1.2")
                == .git(URL(string: "https://git.example.com/me/plugin.git")!, ref: "v1.2"))
        #expect(PluginInstallSource.git(URL(string: "https://git.example.com/me/plugin.git")!, ref: "v1.2").address
                == "https://git.example.com/me/plugin.git#v1.2")
    }

    @Test func rejectsUnsafeAddresses() {
        for bad in ["http://github.com/o/r", "file:///tmp/plugin.zip", "ftp://example.com/a.zip", "",
                    "https://user:pass@example.com/a.zip", "https://github.com/o", "https://github.com/o/r/issues",
                    "https://github.com/o/r/tree/main/../x", "https://github.com/o/r/blob/main/run.sh",
                    "https://github.com/o/r/tree/..", "javascript:alert(1)", "https://git.example.com/a.git#-x"] {
            #expect(throws: PluginInstallError.self, "\(bad)") { try PluginInstallSource.parse(bad) }
        }
        #expect(throws: PluginInstallError.invalidAddress("Only https addresses are supported.")) {
            try PluginInstallSource.parse("http://example.com/a.zip")
        }
    }

    // MARK: - Versions

    @Test func comparesVersions() {
        typealias V = PluginVersion
        #expect(V.compare(installed: "1.0.0", remote: "1.0.1") == .newer)
        #expect(V.compare(installed: "1.9", remote: "1.10") == .newer)
        #expect(V.compare(installed: "1.2", remote: "1.2.0") == .same)
        #expect(V.compare(installed: "v1.2.0", remote: "1.2.0+build.7") == .same)
        #expect(V.compare(installed: "2.0.0", remote: "1.9.9") == .older)
        #expect(V.compare(installed: "1.0.0-beta", remote: "1.0.0") == .newer)
        #expect(V.compare(installed: "1.0.0", remote: "1.0.0-rc.1") == .older)
        #expect(V.compare(installed: "1.0.0-alpha.2", remote: "1.0.0-alpha.10") == .newer)
        #expect(V.compare(installed: "1.0.0-alpha", remote: "1.0.0-alpha.1") == .newer)
        #expect(V.compare(installed: "2024-05", remote: "2024-05") == .same)
        #expect(V.compare(installed: "nightly", remote: "nightly-2") == .different)
        #expect(V.compare(installed: nil, remote: "1.0.0") == .different)
        #expect(V.compare(installed: nil, remote: nil) == .same)
    }

    // MARK: - Source records

    @Test func sourceRecordsRoundTrip() throws {
        let store = PluginSourceStore(directory: root.appendingPathComponent("PluginSources"))
        #expect(store.load(for: "demo") == nil)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let record = PluginSourceRecord(address: "https://github.com/o/r/tree/main/p", ref: "main",
                                        commit: String(repeating: "a", count: 40), version: "1.0.0", installedAt: date)
        try store.save(record, for: "demo")
        #expect(store.load(for: "demo") == record)
        #expect(store.load(for: "demo")?.source == .github(owner: "o", repository: "r", ref: "main", subpath: "p"))
        #expect(throws: (any Error).self) { try store.save(record, for: "../escape") }
        store.remove(for: "demo")
        #expect(store.load(for: "demo") == nil)
    }

    // MARK: - Archives

    @Test func extractsPreservingExecutableBits() throws {
        let zip = try archive()
        let out = root.appendingPathComponent("out")
        try PluginArchive.extract(zip, to: out)
        let script = out.appendingPathComponent("repo-abc/run.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(!FileManager.default.isExecutableFile(atPath: out.appendingPathComponent("repo-abc/plugin.json").path))
        #expect(try String(contentsOf: script, encoding: .utf8) == "#!/bin/sh\necho '{}'\n")
    }

    @Test func rejectsPathTraversal() throws {
        for name in ["../evil.sh", "a/../../evil.sh", "/tmp/evil.sh", "a/./../../evil.sh"] {
            var zip = ZipBuilder()
            zip.file("plugin.json", "{}")
            zip.file(name, "x")
            let out = root.appendingPathComponent("out-\(UUID().uuidString)/inner")
            #expect(throws: PluginInstallError.self, "\(name)") { try PluginArchive.extract(try write(zip), to: out) }
            #expect(!FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("evil.sh").path))
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("plugin.json").path), "checked before writing")
        }
        #expect(PluginArchive.safePath("./a//b") == nil)
        #expect(PluginArchive.safePath("./a/b/") == "a/b")
    }

    @Test func rejectsLinksOutOfTheArchive() throws {
        for target in ["../../etc", "/etc/passwd", "./../.."] {
            var zip = ZipBuilder()
            zip.file("p/plugin.json", "{}")
            zip.link("p/link", to: target)
            #expect(throws: PluginInstallError.self, "\(target)") {
                try PluginArchive.extract(try write(zip), to: root.appendingPathComponent("out-\(UUID().uuidString)"))
            }
        }
        #expect(PluginArchive.isContained(link: "a/b/l", target: "../c"))
        #expect(!PluginArchive.isContained(link: "a/l", target: "../../c"))
    }

    @Test func rejectsLinkChainsThatEscapeWhenResolved() throws {
        // Each target looks contained on its own; through l3 the second resolves above the root.
        var zip = ZipBuilder()
        zip.file("p/plugin.json", "{}")
        zip.link("p/a/b/l3", to: "../..")
        zip.link("p/a/b/l4", to: "l3/..")
        let out = root.appendingPathComponent("out")
        try PluginArchive.extract(try write(zip), to: out)
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.verifyTree(out.appendingPathComponent("p"), limit: 1 << 20)
        }
        // A link inside the plugin, and the archive tree as a whole, are fine.
        var good = ZipBuilder()
        good.file("p/plugin.json", "{}")
        good.file("p/lib/tool.sh", "x")
        good.link("p/tool", to: "lib/tool.sh")
        let fine = root.appendingPathComponent("fine")
        try PluginArchive.extract(try write(good), to: fine)
        try PluginArchive.verifyTree(fine.appendingPathComponent("p"), limit: 1 << 20)
        // The same link is outside a plugin rooted at p/lib.
        var sibling = ZipBuilder()
        sibling.file("p/plugin.json", "{}")
        sibling.file("p/lib/plugin.json", "{}")
        sibling.link("p/lib/up", to: "../plugin.json")
        let nested = root.appendingPathComponent("nested")
        try PluginArchive.extract(try write(sibling), to: nested)
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.verifyTree(nested.appendingPathComponent("p/lib"), limit: 1 << 20)
        }
    }

    @Test func enforcesSizesAndShape() throws {
        var limits = PluginInstallLimits()
        limits.extracted = 100
        var big = ZipBuilder()
        big.file("a", String(repeating: "x", count: 200))
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.extract(try write(big), to: root.appendingPathComponent("big"), limits: limits)
        }
        // An entry larger than the directory declares is refused while it is written.
        var lying = ZipBuilder()
        lying.file("a", String(repeating: "x", count: 200), declaredSize: 10)
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.extract(try write(lying), to: root.appendingPathComponent("lying"))
        }
        var twice = ZipBuilder()
        twice.file("a", "1")
        twice.file("A", "2")
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.extract(try write(twice), to: root.appendingPathComponent("twice"))
        }
        var many = ZipBuilder()
        for index in 0..<5 { many.file("f\(index)", "") }
        limits = PluginInstallLimits()
        limits.entries = 4
        #expect(throws: PluginInstallError.self) {
            try PluginArchive.extract(try write(many), to: root.appendingPathComponent("many"), limits: limits)
        }
        let html = root.appendingPathComponent("page.zip")
        try "<html>not a zip</html>".write(to: html, atomically: true, encoding: .utf8)
        #expect(throws: PluginInstallError.self) { try PluginArchive.extract(html, to: root.appendingPathComponent("html")) }
        var tree = ZipBuilder()
        tree.directory("t/")
        tree.file("t/x", "x")
        let limited = root.appendingPathComponent("limited")
        try PluginArchive.extract(try write(tree), to: limited)
        #expect(throws: PluginInstallError.self) { try PluginArchive.verifyTree(limited, limit: 0) }
    }

    @Test func refusesArchivesItCannotReadSafely() throws {
        func failure(_ data: Data) -> String? {
            let name = UUID().uuidString
            let url = root.appendingPathComponent(name + ".zip")
            do {
                try data.write(to: url)
                try PluginArchive.extract(url, to: root.appendingPathComponent(name))
                return nil
            } catch let error as PluginInstallError { return error.message } catch { return "\(error)" }
        }
        var plain = ZipBuilder()
        plain.file("plugin.json", "{}")
        let good = plain.build()
        #expect(failure(good) == nil)
        let central = try #require(good.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let end = try #require(good.range(of: Data([0x50, 0x4B, 0x05, 0x06]))).lowerBound

        var encrypted = good
        encrypted[central + 8] |= 1
        #expect(failure(encrypted)?.contains("Encrypted") == true)
        var zip64 = good
        zip64.replaceSubrange((end + 10)..<(end + 12), with: [0xFF, 0xFF])
        #expect(failure(zip64)?.contains("ZIP64") == true)
        var method = good
        method[central + 10] = 9
        #expect(failure(method)?.contains("compression method") == true)
        var corrupt = good
        corrupt[30 + "plugin.json".utf8.count] ^= 0xFF
        #expect(failure(corrupt)?.contains("damaged") == true, "a checksum mismatch is refused")
        var fifo = ZipBuilder()
        fifo.file("pipe", "", mode: 0o010644)
        #expect(failure(fifo.build())?.contains("special file") == true)
    }

    // MARK: - Roots

    @Test func findsThePluginRoot() throws {
        let files = FileManager.default
        func tree(_ paths: [String]) throws -> URL {
            let base = root.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
            for path in paths {
                let url = base.appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "{}".write(to: url, atomically: true, encoding: .utf8)
            }
            return base
        }
        let flat = try tree(["plugin.json", "run.sh"])
        #expect(try PluginInstaller.pluginRoot(in: flat, subpath: nil) == flat)
        let single = try tree(["repo-1/plugin.json", "__MACOSX/._x"])
        #expect(try PluginInstaller.pluginRoot(in: single, subpath: nil).lastPathComponent == "repo-1")
        let nested = try tree(["repo-1/README", "repo-1/plugins/kube/plugin.json"])
        #expect(try PluginInstaller.pluginRoot(in: nested, subpath: "plugins/kube").lastPathComponent == "kube")
        #expect(throws: PluginInstallError.self) { try PluginInstaller.pluginRoot(in: nested, subpath: nil) }
        #expect(throws: PluginInstallError.self) { try PluginInstaller.pluginRoot(in: nested, subpath: "plugins/missing") }
        let two = try tree(["a/plugin.json", "b/plugin.json"])
        #expect(throws: PluginInstallError.self) { try PluginInstaller.pluginRoot(in: two, subpath: nil) }
    }

    // MARK: - Prepare and install

    @Test func preparesAndInstallsFromGitHub() async throws {
        let commit = String(repeating: "c", count: 40)
        let zip = try archive(sub: "plugins/demo", comment: commit)
        let loader = FixtureLoader(files: ["https://codeload.github.com/o/r/zip/main": zip])
        let installer = try installer(loader)
        let staged = try await installer.prepare(from: "https://github.com/o/r/tree/main/plugins/demo")
        #expect(staged.plugin.isUsable && staged.manifest.id == "demo")
        #expect(staged.commit == commit)
        #expect(leftovers().count == 1)

        let installed = try installer.install(staged, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(installed.directory.lastPathComponent == "demo")
        #expect(FileManager.default.isExecutableFile(atPath: plugins.appendingPathComponent("demo/run.sh").path))
        #expect(!FileManager.default.fileExists(atPath: plugins.appendingPathComponent("demo/README").path))
        #expect(leftovers().isEmpty, "staging removed after installing")
        let record = installer.sources.load(for: "demo")
        #expect(record == PluginSourceRecord(address: "https://github.com/o/r/tree/main/plugins/demo", ref: "main",
                                             commit: commit, version: "1.0.0", installedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func resolvesRefsWithSlashes() async throws {
        let zip = try archive(sub: "examples/demo")
        let loader = FixtureLoader(
            files: ["https://codeload.github.com/o/r/zip/feat/plugins": zip])
        let staged = try await installer(loader).prepare(from: "https://github.com/o/r/tree/feat/plugins/examples/demo")
        #expect(staged.source == .github(owner: "o", repository: "r", ref: "feat/plugins", subpath: "examples/demo"))
    }

    @Test func failuresLeaveNothingBehind() async throws {
        var zip = ZipBuilder()
        zip.file("top/plugin.json", #"{"id":"x"}"#)
        let broken = try write(zip)
        let installer = try installer(FixtureLoader(files: ["https://example.com/broken.zip": broken,
                                                            "https://example.com/slip.zip": try write({
                                                                var slip = ZipBuilder()
                                                                slip.file("../x", "x")
                                                                return slip
                                                            }())]))
        for address in ["https://example.com/broken.zip", "https://example.com/slip.zip", "https://example.com/missing.zip"] {
            await #expect(throws: PluginInstallError.self, "\(address)") { try await installer.prepare(from: address) }
            #expect(leftovers().isEmpty, "\(address)")
        }
        do {
            _ = try await installer.prepare(from: "https://example.com/broken.zip")
        } catch {
            #expect(error.message.contains("plugin.json is not valid"))
        }
        // A git address without git says so instead of running /usr/bin/git.
        await #expect(throws: PluginInstallError.self) { try await installer.prepare(from: "https://example.com/a.git") }
    }

    @Test func discardingAStagedPluginRemovesIt() async throws {
        let installer = try installer(FixtureLoader(files: ["https://example.com/p.zip": try archive()]))
        var staged: StagedPlugin? = try await installer.prepare(from: "https://example.com/p.zip")
        #expect(leftovers().count == 1)
        staged = nil
        #expect(staged == nil && leftovers().isEmpty)
    }

    @Test func updatesKeepDataAndReplaceAtomically() async throws {
        let v1 = try archive(version: "1.0.0"), v2 = try archive(version: "2.0.0")
        var installer = try installer(FixtureLoader(files: ["https://example.com/v1.zip": v1, "https://example.com/v2.zip": v2]))
        try installer.install(try await installer.prepare(from: "https://example.com/v1.zip"))
        // Plugin-owned state lives beside the plugin, so replacing it keeps the state.
        let data = PluginStore.dataDirectory(for: "demo", in: root)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try "state".write(to: data.appendingPathComponent("state"), atomically: true, encoding: .utf8)
        // So are its settings and secrets, which are keyed by id away from its folder.
        let fields = try JSONDecoder().decode([PluginSetting].self, from: Data(#"""
            [{"id":"org","label":"Org","type":"text"},{"id":"token","label":"Token","type":"secret"}]
            """#.utf8))
        let secrets = MemorySecretStore()
        let settings = PluginConfigurationStore(directory: root.appendingPathComponent("PluginSettings"), secrets: secrets)
        try settings.save(["org": .string("acme"), "token": .string("hunter2")], for: "demo", settings: fields)

        // A failure just before the swap leaves version 1 and its record in place.
        installer.beforeReplace = { _ in throw CocoaError(.fileWriteUnknown) }
        let staged = try await installer.prepare(from: "https://example.com/v2.zip")
        #expect(throws: PluginInstallError.self) { try installer.install(staged) }
        #expect(PluginStore.load(plugins.appendingPathComponent("demo")).manifest?.version == "1.0.0")
        #expect(installer.sources.load(for: "demo")?.address == "https://example.com/v1.zip")
        #expect(try FileManager.default.contentsOfDirectory(atPath: plugins.path) == ["demo"], "no staging left in Plugins")
        #expect(leftovers().isEmpty)

        installer.beforeReplace = nil
        try installer.install(try await installer.prepare(from: "https://example.com/v2.zip"))
        #expect(PluginStore.load(plugins.appendingPathComponent("demo")).manifest?.version == "2.0.0")
        #expect(installer.sources.load(for: "demo")?.version == "2.0.0")
        #expect(try String(contentsOf: data.appendingPathComponent("state"), encoding: .utf8) == "state")
        #expect(try settings.load(for: "demo", settings: fields) == ["org": .string("acme"), "token": .string("hunter2")])
    }

    @Test func refusesToReplaceALinkedPlugin() async throws {
        let checkout = root.appendingPathComponent("checkout/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Self.manifest(version: "0.1").write(to: checkout.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let script = checkout.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plugins.appendingPathComponent("dev-demo"), withDestinationURL: checkout)

        let installer = try installer(FixtureLoader(files: ["https://example.com/p.zip": try archive()]))
        let staged = try await installer.prepare(from: "https://example.com/p.zip")
        #expect(installer.installed(id: "demo").map(PluginInstaller.isLinked) == true)
        #expect(throws: PluginInstallError.self) { try installer.install(staged) }
        #expect(PluginStore.load(checkout).manifest?.version == "0.1", "the checkout is untouched")
        #expect(installer.sources.load(for: "demo") == nil)
        #expect(leftovers().isEmpty)
    }

    // MARK: - Update checks

    @Test func checksGitHubManifests() async throws {
        let zip = try archive(version: "1.0.0")
        let raw = "https://raw.githubusercontent.com/o/r/HEAD/plugin.json"
        var loader = FixtureLoader(files: ["https://codeload.github.com/o/r/zip/HEAD": zip])
        var installer = try installer(loader)
        let plugin = try installer.install(try await installer.prepare(from: "https://github.com/o/r"))

        func check(_ manifest: String?) async throws -> PluginUpdateCheck.Status {
            loader.bodies[raw] = manifest.map { Data($0.utf8) }
            installer = try self.installer(loader)
            return await installer.checkForUpdate(plugin).status
        }
        #expect(try await check(Self.manifest(version: "1.0.0")) == .upToDate)
        #expect(try await check(Self.manifest(version: "1.1.0")) == .available("1.1.0"))
        #expect(try await check(Self.manifest(version: "0.9.0")) == .installedIsNewer("0.9.0"))
        guard case .failed = try await check(Self.manifest(id: "other", version: "2.0.0")) else { Issue.record("id change"); return }
        guard case .failed = try await check(nil) else { Issue.record("missing manifest"); return }
        guard case .failed = try await check("not json") else { Issue.record("invalid manifest"); return }

        // Without a record, as for a plugin installed from a folder, there is nothing to check.
        installer.sources.remove(for: "demo")
        guard case .failed = await installer.checkForUpdate(plugin).status else { Issue.record("no source"); return }
    }

    @Test func checksArchivesByStagingThem() async throws {
        var loader = FixtureLoader(files: ["https://example.com/p.zip": try archive(version: "1.0.0")])
        let first = try installer(loader)
        let plugin = try first.install(try await first.prepare(from: "https://example.com/p.zip"))
        loader.files["https://example.com/p.zip"] = try archive(version: "1.2.0")
        let check = await (try installer(loader)).checkForUpdate(plugin)
        #expect(check.status == .available("1.2.0") && check.installedVersion == "1.0.0")
        #expect(leftovers().isEmpty)
    }

    @Test func gitIsNeverTheDeveloperToolsShim() {
        #expect(PluginInstaller.gitExecutable()?.path != "/usr/bin/git")
    }
}
