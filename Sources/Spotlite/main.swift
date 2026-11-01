import SpotliteCore
import AppKit

// A quarter less footprint at no measured latency cost, but libmalloc reads this only as
// the process starts, so it takes a re-exec. It works for every launch path, unlike
// LSEnvironment. Cleared afterwards so nothing Spotlite spawns inherits it, which also
// stops this looping. If exec fails, Spotlite carries on with the default allocator.
if getenv("MallocSpaceEfficient") == nil {
    if let path = Bundle.main.executablePath {
        setenv("MallocSpaceEfficient", "1", 1)
        execv(path, CommandLine.unsafeArgv)
    }
}
unsetenv("MallocSpaceEfficient")

func configuredDirectories(_ preferences: Preferences = Storage.loadPreferences()) -> [URL] {
    AppIndex.normalizedDirectories(preferences.applicationDirectories)
}

// Headless dev entry point: verify the index without launching the UI.
if CommandLine.arguments.contains("--dump") {
    let entries = AppIndex.scan(directories: configuredDirectories())
    print("indexed \(entries.count) apps")
    for e in entries.prefix(200) { print("  \(e.name)  [\(e.initials)]") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    let q = CommandLine.arguments[i + 1]
    for m in Matcher().search(q, in: AppIndex.scan(directories: configuredDirectories())).prefix(6) {
        print("  \(m.score)\t\(m.entry.name)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--bench") {
    let preferences = Storage.loadPreferences()
    let entries = AppIndex.scanAll(directories: configuredDirectories(preferences)) + preferences.extraEntries
    let matcher = Matcher()
    let corpus = SearchCorpus(entries: entries, aliases: AliasIndex(aliases: preferences.aliases),
                              hiddenBundleIDs: preferences.hiddenBundleIDs,
                              includeSettingsPanes: preferences.showSystemSettings,
                              includeCommands: preferences.showSystemCommands)
    let frecency = Storage.loadFrecency()
    let queries = ["s", "sa", "saf", "safa", "safar", "safari", "gc", "term", "a", "cal", "xyz", "ca", "se", "uu"]
    var sink = 0
    // The same call each keystroke makes: calculator, matcher, ranking and built-ins.
    func search(_ q: String) -> Int {
        SearchResults.build(for: q, corpus: corpus, matcher: matcher, frecency: frecency,
                            webSearch: preferences.webSearchEngine,
                            webSearchMode: preferences.webSearchMode,
                            hiddenUtilities: preferences.hiddenUtilities).count
    }
    // Warm up, then time enough iterations to escape timer granularity.
    for q in queries { sink &+= search(q) }

    let iterations = 2000
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        for q in queries { sink &+= search(q) }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let perSearch = Double(elapsed) / Double(iterations * queries.count) / 1000.0
    print("apps indexed: \(entries.count)")
    print(String(format: "per keystroke: %.1f µs  (%d searches, sink %d)",
                 perSearch, iterations * queries.count, sink))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
