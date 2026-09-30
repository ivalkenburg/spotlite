import Foundation

/// Scans well-known application directories. Depth 2, never inside `Contents/`.
public enum AppIndex {

    public static var searchDirectories: [URL] {
        var dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return dirs
    }

    /// Normalize paths once when preferences change, never while matching.
    public static func normalizedDirectories(_ paths: [String]) -> [URL] {
        var seen: Set<String> = []
        return paths.compactMap { raw in
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    /// The same depth-2 rule as a scan, used to drop removed roots without blanking the list.
    public static func includesApplication(at url: URL, directories: [URL]) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()
        return directories.contains(parent) || directories.contains(grandparent)
    }

    /// Returns an immediately usable cached snapshot. The cache turns a ~90ms cold scan
    /// of 88 bundles into a single small JSON read. Callers that keep running must
    /// revalidate it in the background: a cache cannot observe changes made while the
    /// process was not alive.
    public static func loadCached(directories: [URL] = searchDirectories) -> [AppEntry]? {
        guard let cached = Storage.loadIndex(directories: directories), !cached.isEmpty else { return nil }
        return cached.map(AppEntry.init(cached:))
    }

    /// Rescans and rewrites the cache. Called from the FSEvents watcher and from the
    /// staleness check when the panel opens. Settings panes are rescanned with the apps
    /// but not watched: they only change with an OS update.
    public static func refresh(directories: [URL] = searchDirectories) -> [AppEntry] {
        let scanned = scanAll(directories: directories)
        Storage.saveIndex(scanned.map(\.cached), directories: directories)
        return scanned
    }

    /// Apps and settings panes, sorted by name: what the index holds.
    public static func scanAll(directories: [URL] = searchDirectories) -> [AppEntry] {
        sortedByName(collect(directories) + SettingsPaneIndex.installed)
    }

    /// Newest modification time across the indexed directories. Comparing this on show
    /// costs a handful of syscalls and catches anything FSEvents missed while asleep.
    public static func directoriesFingerprint(directories: [URL] = searchDirectories) -> [String: Date] {
        var result: [String: Date] = [:]
        for dir in directories {
            if let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                result[dir.path] = date
            }
        }
        return result
    }

    /// Walks the search directories and returns every user-launchable app. Concrete paths
    /// are de-duplicated, but two installed copies with the same bundle ID remain visible.
    public static func scan(directories: [URL] = searchDirectories) -> [AppEntry] {
        sortedByName(collect(directories))
    }

    private static func collect(_ directories: [URL]) -> [AppEntry] {
        var seen = Set<String>()
        var results: [AppEntry] = []

        for dir in directories {
            for url in bundles(in: dir, depth: 2) {
                let path = url.standardizedFileURL.path
                guard !seen.contains(path), let entry = makeEntry(for: url) else { continue }
                seen.insert(path)
                results.append(entry)
            }
        }
        return results
    }

    public static func sortedByName(_ entries: [AppEntry]) -> [AppEntry] {
        // Keys lowercased once, not twice per comparison.
        let keyed: [(key: String, entry: AppEntry)] = entries.map { ($0.name.lowercased(), $0) }
        return keyed.sorted { a, b in
            a.key == b.key ? a.entry.instanceID < b.entry.instanceID : a.key < b.key
        }.map(\.entry)
    }

    /// Collects `.app` URLs, recursing into plain subfolders (vendor folders) but never into bundles.
    private static func bundles(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
            // NOT .skipsHiddenFiles: /Applications/Safari.app is a hidden symlink into
            // /System/Cryptexes, and skipping hidden entries silently loses it.
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for child in children {
            if child.pathExtension == "app" {
                found.append(child)
            } else if !child.lastPathComponent.hasPrefix("."),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found.append(contentsOf: bundles(in: child, depth: depth - 1))
            }
        }
        return found
    }

    /// Reads a bundle's Info.plist, rejecting background-only agents that have no UI to show.
    ///
    /// Read directly rather than through `Bundle(url:)`, which returns a process-wide
    /// cached instance: every rescan would see each app's Info.plist as it was when first
    /// indexed, and the cache would hold every bundle ever seen for the process's lifetime.
    private static func makeEntry(for url: URL) -> AppEntry? {
        guard let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as? [String: Any]
        else { return nil }

        if truthy(info["LSUIElement"]) || truthy(info["LSBackgroundOnly"]) { return nil }

        // Match what Finder shows, not an internal process name. Visual Studio Code, for
        // example, declares both bundle-name keys as "Code" while its visible name is
        // "Visual Studio Code". Resolve this once while indexing; matching remains fully
        // precomputed and pays no filesystem or localization cost per keystroke.
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        return AppEntry(url: url, name: name, bundleID: info[kCFBundleIdentifierKey as String] as? String)
    }

    /// Info.plist booleans appear as Bool, String ("1"/"YES") or NSNumber depending on how they were written.
    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s.lowercased() == "true" || s.lowercased() == "yes"
        default: return false
        }
    }
}
