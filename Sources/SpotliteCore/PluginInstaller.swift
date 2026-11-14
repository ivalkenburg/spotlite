import Foundation

/// Fetches what the installer asks for. The real one uses URLSession; tests serve
/// local files so `swift test` never touches the network.
public protocol PluginDownloading: Sendable {
    /// Writes the body to `destination`, failing past `limit` bytes. `progress` gets
    /// bytes received and, when the server says, the total. False when the server
    /// answers 404.
    func download(_ url: URL, to destination: URL, limit: Int64,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Bool
    /// A small body, such as a manifest. Nil when the server answers 404.
    func data(from url: URL, limit: Int64) async throws(PluginInstallError) -> Data?
}

/// What the installer is doing, for a progress indicator.
public enum PluginInstallProgress: Sendable, Equatable {
    case downloading(received: Int64, expected: Int64?)
    case cloning
    case extracting
}

/// A plugin downloaded and checked, waiting for the user to confirm. Its temporary
/// folder is removed when it is installed, discarded, or released.
public final class StagedPlugin: Sendable {
    /// Loaded from the staging folder. Always usable.
    public let plugin: InstalledPlugin
    public let source: PluginInstallSource
    /// The commit that was downloaded, when the source reports one.
    public let commit: String?
    let workDirectory: URL

    init(plugin: InstalledPlugin, source: PluginInstallSource, commit: String?, workDirectory: URL) {
        self.plugin = plugin
        self.source = source
        self.commit = commit
        self.workDirectory = workDirectory
    }

    deinit { try? FileManager.default.removeItem(at: workDirectory) }

    public var manifest: PluginManifest { plugin.manifest! }

    /// Removes the downloaded files now rather than when the value is released.
    public func discard() { try? FileManager.default.removeItem(at: workDirectory) }
}

/// The result of checking one plugin's source.
public struct PluginUpdateCheck: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case upToDate
        /// The source has a newer version, or a different one that cannot be ordered.
        case available(String?)
        /// The installed version is newer than the source's.
        case installedIsNewer(String?)
        case failed(String)
    }

    public let pluginID: String
    public let installedVersion: String?
    public let status: Status
}

/// Installs plugins from an address: `prepare` downloads, extracts and validates into
/// a temporary folder; the caller shows what it found; `install` replaces the plugin
/// atomically and records where it came from. Nothing here runs unless called.
public struct PluginInstaller: Sendable {
    public let pluginsDirectory: URL
    public let sources: PluginSourceStore
    public let loader: any PluginDownloading
    public let limits: PluginInstallLimits
    let temporaryDirectory: URL
    let git: URL?
    /// Test hook: runs on the staged copy just before it replaces the installed one.
    var beforeReplace: (@Sendable (URL) throws -> Void)?

    public init(pluginsDirectory: URL = PluginStore.directory, sources: PluginSourceStore = .init(),
                loader: any PluginDownloading = URLSessionPluginDownloader(),
                limits: PluginInstallLimits = .init(),
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                git: URL? = PluginInstaller.gitExecutable()) {
        self.pluginsDirectory = pluginsDirectory
        self.sources = sources
        self.loader = loader
        self.limits = limits
        self.temporaryDirectory = temporaryDirectory
        self.git = git
    }

    // MARK: - Preparing

    /// Parses `address` and stages the plugin it names.
    public func prepare(from address: String,
                        progress: @escaping @Sendable (PluginInstallProgress) -> Void = { _ in })
        async throws(PluginInstallError) -> StagedPlugin {
        try await prepare(from: PluginInstallSource.parse(address), progress: progress)
    }

    public func prepare(from source: PluginInstallSource,
                        progress: @escaping @Sendable (PluginInstallProgress) -> Void = { _ in })
        async throws(PluginInstallError) -> StagedPlugin {
        let work = temporaryDirectory.appendingPathComponent("Spotlite-plugin-" + UUID().uuidString, isDirectory: true)
        do throws(PluginInstallError) {
            do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
            catch { throw PluginInstallError.install("Couldn’t create a temporary folder.") }
            var source = source
            let tree = work.appendingPathComponent("tree", isDirectory: true)
            var commit: String?
            switch source {
            case .github, .archive:
                let archive = work.appendingPathComponent("download.zip")
                progress(.downloading(received: 0, expected: nil))
                // A `tree` address with a ref containing `/` reads in several ways; the
                // first ref the server knows wins. Git refuses `feat` beside `feat/x`,
                // so at most one branch matches.
                var found = false
                for candidate in source.githubCandidates.prefix(8) where !found {
                    found = try await loader.download(candidate.archiveURL!, to: archive, limit: limits.download) {
                        progress(.downloading(received: $0, expected: $1))
                    }
                    if found { source = candidate }
                }
                guard found else { throw PluginInstallError.download("Nothing was found at that address (404).") }
                try Task.checkCancellation(or: .cancelled)
                progress(.extracting)
                try PluginArchive.extract(archive, to: tree, limits: limits)
                if case .github = source, let comment = PluginArchive.comment(of: archive),
                   comment.count == 40, comment.allSatisfy(\.isHexDigit) {
                    commit = comment
                }
                try? FileManager.default.removeItem(at: archive)
            case .git(let url, let ref):
                progress(.cloning)
                commit = try await clone(url, ref: ref, into: tree)
            }
            try Task.checkCancellation(or: .cancelled)
            let root = try Self.pluginRoot(in: tree, subpath: source.subpath)
            try PluginArchive.verifyTree(root, limit: limits.extracted)
            let plugin = PluginStore.load(root)
            guard plugin.isUsable else {
                throw PluginInstallError.notAPlugin(plugin.problem ?? "This is not a Spotlite plugin.")
            }
            return StagedPlugin(plugin: plugin, source: source, commit: commit, workDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// The folder with `plugin.json`: the requested subfolder, the top of the archive,
    /// or the archive's single top folder (as in GitHub's archives).
    static func pluginRoot(in tree: URL, subpath: String?) throws(PluginInstallError) -> URL {
        let files = FileManager.default
        let visible = ((try? files.contentsOfDirectory(at: tree, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        var base = tree
        if !files.fileExists(atPath: tree.appendingPathComponent(PluginStore.manifestName).path) || subpath != nil,
           visible.count == 1, let only = visible.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
               .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
            base = only
        }
        var root = base
        if let subpath {
            guard PluginInstallSource.isPlainSubpath(subpath) else { throw .notAPlugin("The folder “\(subpath)” is not valid.") }
            root = base.appendingPathComponent(subpath, isDirectory: true)
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                throw .notAPlugin("The download has no folder \(subpath).")
            }
        }
        guard files.fileExists(atPath: root.appendingPathComponent(PluginStore.manifestName).path) else {
            throw .notAPlugin(subpath == nil
                ? "There is no \(PluginStore.manifestName) at the top of the download. For a plugin in a subfolder of a GitHub repository, use its …/tree/<branch>/<folder> address."
                : "The folder \(subpath!) has no \(PluginStore.manifestName).")
        }
        return root
    }

    // MARK: - Installing

    /// The installed plugin with the same id, ignoring letter case.
    public func installed(id: String) -> InstalledPlugin? {
        PluginStore.scan(directory: pluginsDirectory).first { $0.id.lowercased() == id.lowercased() }
    }

    /// Whether `plugin` is a symbolic link to a folder elsewhere, such as a checkout.
    public static func isLinked(_ plugin: InstalledPlugin) -> Bool { PluginStore.isLink(plugin.directory) }

    /// Copies the staged plugin into place and records its source. A failure leaves the
    /// installed plugin as it was. Settings, secrets and `PluginData` are keyed by id
    /// and never touched. The staged files are removed either way.
    @discardableResult
    public func install(_ staged: StagedPlugin, now: Date = Date()) throws(PluginInstallError) -> InstalledPlugin {
        defer { staged.discard() }
        if let existing = installed(id: staged.plugin.id), Self.isLinked(existing) {
            throw .install("“\(existing.name)” is a link to a folder elsewhere, usually a checkout under development. Update that folder instead, or remove the link first.")
        }
        let plugin: InstalledPlugin
        do {
            plugin = try PluginStore.install(from: staged.plugin.directory, into: pluginsDirectory, beforeReplace: beforeReplace)
        } catch {
            throw .install(error.message)
        }
        let record = PluginSourceRecord(address: staged.source.address, ref: staged.source.ref, commit: staged.commit,
                                        version: plugin.manifest?.version, installedAt: now)
        do { try sources.save(record, for: plugin.id) }
        catch { throw .install("The plugin is installed, but its source couldn’t be recorded, so updates can’t be checked: \(error.localizedDescription)") }
        return plugin
    }

    // MARK: - Updates

    /// Compares the installed version with the source's. A GitHub source is checked by
    /// its manifest alone; any other source is downloaded and staged, then discarded.
    public func checkForUpdate(_ plugin: InstalledPlugin) async -> PluginUpdateCheck {
        let installedVersion = plugin.manifest?.version
        func result(_ status: PluginUpdateCheck.Status) -> PluginUpdateCheck {
            PluginUpdateCheck(pluginID: plugin.id, installedVersion: installedVersion, status: status)
        }
        guard let record = sources.load(for: plugin.id), let source = record.source else {
            return result(.failed("Installed from a folder, so there is nothing to check."))
        }
        let remote: PluginManifest
        do throws(PluginInstallError) {
            if let url = source.manifestURL {
                guard let data = try await loader.data(from: url, limit: limits.manifest) else {
                    return result(.failed("The source no longer has a \(PluginStore.manifestName)."))
                }
                do { remote = try JSONDecoder().decode(PluginManifest.self, from: data) }
                catch { return result(.failed("The source’s \(PluginStore.manifestName) is not valid.")) }
            } else {
                let staged = try await prepare(from: source)
                remote = staged.manifest
                staged.discard()
            }
        } catch {
            return result(.failed(error.message))
        }
        guard remote.id == plugin.id else {
            return result(.failed("The source now holds a different plugin, \(remote.id)."))
        }
        switch PluginVersion.compare(installed: installedVersion, remote: remote.version) {
        case .same: return result(.upToDate)
        case .newer, .different: return result(.available(remote.version))
        case .older: return result(.installedIsNewer(remote.version))
        }
    }

    // MARK: - Git

    /// A git that runs without asking to install developer tools: the developer
    /// directory's own, or Homebrew's. `/usr/bin/git` is a shim that, without the
    /// Command Line Tools, opens their installer, so it is never used.
    public static func gitExecutable() -> URL? {
        var candidates: [String] = []
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += ["/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func clone(_ url: URL, ref: String?, into tree: URL) async throws(PluginInstallError) -> String? {
        guard let git else {
            throw .download("Installing from a git address needs git, from Xcode’s Command Line Tools or Homebrew. Use a GitHub or .zip address instead.")
        }
        // No hooks, no submodules, https only, and no credentials: an empty helper
        // clears the Keychain helper git is configured with, which would otherwise
        // wait on a prompt for a repository that does not exist or is private.
        var arguments = ["-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
                         "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
                         "-c", "submodule.recurse=false", "-c", "advice.detachedHead=false",
                         "clone", "--quiet", "--depth", "1", "--single-branch", "--no-tags"]
        if let ref { arguments += ["--branch", ref] }
        arguments += ["--", url.absoluteString, tree.path]
        let status = try await run(git, arguments, timeout: 180)
        guard status.code == 0 else {
            throw .download("git couldn’t clone the repository" + (status.error.isEmpty ? "." : ": " + status.error))
        }
        let commit = try? await run(git, ["-C", tree.path, "rev-parse", "HEAD"], timeout: 10).output
        try? FileManager.default.removeItem(at: tree.appendingPathComponent(".git"))
        return commit.flatMap { $0.count == 40 ? $0 : nil }
    }

    private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval)
        async throws(PluginInstallError) -> (code: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
                           "SSH_ASKPASS": "/usr/bin/false", "GCM_INTERACTIVE": "never", "LC_ALL": "C"]
        environment["HOME"] = ProcessInfo.processInfo.environment["HOME"]
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let finished: (Int32, Data, Data)? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, Data, Data)?, Never>) in
                process.terminationHandler = { process in
                    let out = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                    let err = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
                    continuation.resume(returning: (process.terminationStatus, out, err))
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            }
        } onCancel: { [process] in
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation(or: .cancelled)
        guard let (code, out, err) = finished else { throw .download("Couldn’t start git.") }
        let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let lastError = text(err).split(separator: "\n").last.map(String.init) ?? ""
        return (code, text(out), String(lastError.prefix(300)))
    }
}

private extension Task where Success == Never, Failure == Never {
    static func checkCancellation(or error: PluginInstallError) throws(PluginInstallError) {
        if isCancelled { throw error }
    }
}

// MARK: - URLSession

/// Downloads over https only, redirects included, into a file or memory, stopping at
/// the size limit. Ephemeral: no cookies, cache or credentials are kept, and the
/// session ends with the download.
public struct URLSessionPluginDownloader: PluginDownloading {
    public init() {}

    public func download(_ url: URL, to destination: URL, limit: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Bool {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw .download("Couldn’t create the download file.")
        }
        defer { try? handle.close() }
        return try await fetch(url, limit: limit, file: handle, progress: progress) != nil
    }

    public func data(from url: URL, limit: Int64) async throws(PluginInstallError) -> Data? {
        try await fetch(url, limit: limit, file: nil, progress: { _, _ in })
    }

    private func fetch(_ url: URL, limit: Int64, file: FileHandle?,
                       progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(PluginInstallError) -> Data? {
        guard url.scheme?.lowercased() == "https" else { throw .invalidAddress("Only https addresses are supported.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "Spotlite"]
        let delegate = DownloadDelegate(limit: limit, file: file, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: URLRequest(url: url))
        let result: Result<Data?, PluginInstallError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return try result.get()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only on the session's serial delegate queue, and `continuation` once
    // before the task starts.
    let limit: Int64
    let file: FileHandle?
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Result<Data?, PluginInstallError>, Never>?
    private var buffer = Data()
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: PluginInstallError?
    private var notFound = false

    init(limit: Int64, file: FileHandle?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.limit = limit
        self.file = file
        self.progress = progress
    }

    private var tooLarge: PluginInstallError {
        .download("The download is larger than \(PluginArchive.megabytes(limit)).")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            failure = .download("The server redirected to an address that is not https.")
            task.cancel()
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            notFound = true
            return completionHandler(.cancel)
        }
        guard (200..<300).contains(status) else {
            failure = .download("The server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status))).")
            return completionHandler(.cancel)
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let expected, expected > limit {
            failure = tooLarge
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= limit else {
            failure = tooLarge
            return dataTask.cancel()
        }
        if let file {
            do { try file.write(contentsOf: data) } catch {
                failure = .download("Couldn’t save the download: \(error.localizedDescription)")
                return dataTask.cancel()
            }
        } else {
            buffer.append(data)
        }
        progress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Data?, PluginInstallError>
        if let failure {
            result = .failure(failure)
        } else if notFound {
            result = .success(nil)
        } else if let error = error as? URLError {
            result = .failure(error.code == .cancelled ? .cancelled : .download(error.localizedDescription))
        } else if let error {
            result = .failure(.download(error.localizedDescription))
        } else {
            result = .success(file == nil ? buffer : Data())
        }
        continuation?.resume(returning: result)
        continuation = nil
    }
}

// MARK: - Confirmation

extension StagedPlugin {
    /// What the user should know before installing, as label and value pairs, in order.
    /// `existing` is the installed plugin this one would replace.
    public func details(replacing existing: InstalledPlugin?) -> [(label: String, value: String)] {
        let manifest = manifest
        let version = manifest.version ?? "none"
        var rows: [(String, String)] = [("Name", manifest.name), ("ID", manifest.id)]
        if let existing {
            rows.append(("Version", (existing.manifest?.version ?? "none") + " → " + version))
        } else {
            rows.append(("Version", version))
        }
        if let author = manifest.author { rows.append(("Author", author)) }
        if let description = manifest.description { rows.append(("Description", description)) }
        rows.append(("Source", source.address + (commit.map { " @ " + $0.prefix(12) } ?? "")))
        rows.append(("Commands", manifest.commands.map { command in
            "\(command.title) (\(Self.kind(of: command.action))" + (command.keyword.map { ", keyword “\($0)”" } ?? "") + ")"
        }.joined(separator: "\n")))
        rows.append(("Executable", manifest.executable.map { "\($0), runs when a command needs it" } ?? "None"))
        rows.append(("Settings", manifest.settings.isEmpty ? "None"
            : manifest.settings.map { "\($0.label) (\($0.type.rawValue)\($0.required ? ", required" : ""))" }.joined(separator: "\n")))
        return rows
    }

    /// The manifest's `type`: every action case carries values, so the case's label is it.
    private static func kind(of action: PluginAction) -> String {
        Mirror(reflecting: action).children.first?.label ?? String(describing: action)
    }
}
