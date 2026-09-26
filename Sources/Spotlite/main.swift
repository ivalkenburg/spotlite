import SpotliteCore
import AppKit

// Headless dev entry point: verify the index without launching the UI.
if CommandLine.arguments.contains("--dump") {
    let entries = AppIndex.scan()
    print("indexed \(entries.count) apps")
    for e in entries.prefix(200) { print("  \(e.name)  [\(e.initials)]") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    let q = CommandLine.arguments[i + 1]
    for m in Matcher().search(q, in: AppIndex.scan()).prefix(6) {
        print("  \(m.score)\t\(m.entry.name)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--bench") {
    let entries = AppIndex.scanAll()
    let matcher = Matcher()
    let preferences = Storage.loadPreferences()
    let corpus = SearchCorpus(entries: entries, aliases: AliasIndex(aliases: preferences.aliases),
                              hiddenBundleIDs: preferences.hiddenBundleIDs,
                              includeSettingsPanes: preferences.showSystemSettings)
    let frecency = Storage.loadFrecency()
    let queries = ["s", "sa", "saf", "safa", "safar", "safari", "gc", "term", "a", "cal", "xyz"]
    var sink = 0
    // The same call each keystroke makes: calculator, matcher, ranking and built-ins.
    func search(_ q: String) -> Int {
        SearchResults.build(for: q, corpus: corpus, matcher: matcher, frecency: frecency).count
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
