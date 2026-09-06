import Foundation

/// Scans well-known application directories. Depth 2, never inside `Contents/`.
public enum AppIndex {

    public static var searchDirectories: [URL] {
        var dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return dirs
    }

    /// Loads the cached index if present, otherwise scans. The cache turns a ~90ms
    /// cold scan of 88 bundles into a single small JSON read.
    public static func loadCachedOrScan() -> [AppEntry] {
        if let cached = Storage.loadIndex(), !cached.isEmpty {
            return cached.map(AppEntry.init(cached:))
        }
        let scanned = scan()
        Storage.saveIndex(scanned.map(\.cached))
        return scanned
    }

    /// Rescans and rewrites the cache. Called from the FSEvents watcher and from the
    /// staleness check when the panel opens.
    public static func refresh() -> [AppEntry] {
        let scanned = scan()
        Storage.saveIndex(scanned.map(\.cached))
        return scanned
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

    /// Walks the search directories and returns every user-launchable app, de-duplicated by bundle ID.
    public static func scan(directories: [URL] = searchDirectories) -> [AppEntry] {
        var seen = Set<String>()
        var results: [AppEntry] = []

        for dir in directories {
            for url in bundles(in: dir, depth: 2) {
                guard let entry = makeEntry(for: url) else { continue }
                if seen.insert(entry.id).inserted {
                    results.append(entry)
                }
            }
        }
        return results.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Collects `.app` URLs, recursing into plain subfolders (vendor folders) but never into bundles.
    private static func bundles(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
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
    private static func makeEntry(for url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }

        if truthy(info["LSUIElement"]) || truthy(info["LSBackgroundOnly"]) { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        return AppEntry(url: url, name: name, bundleID: bundle.bundleIdentifier)
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
