import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin list presentation")
struct PluginListTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func titles(_ list: PluginList, _ query: String) -> [String] {
        list.matchingIndices(query, matcher: Matcher()).map { list.items[$0].title }
    }

    @Test func decodesAccessoryAndKeywords() throws {
        let item = try decode(PluginItem.self, #"{"title":"Repo","accessory":"★ 1.2k","keywords":["swift","ios"]}"#)
        #expect(item.accessory == "★ 1.2k")
        #expect(item.keywords == ["swift", "ios"])
        let plain = try decode(PluginItem.self, #"{"title":"Plain","accessory":"  ","keywords":[" ",""]}"#)
        #expect(plain.accessory == nil && plain.keywords.isEmpty)
        let many = (0..<20).map { "\"k\($0)\"" }.joined(separator: ",")
        #expect(try decode(PluginItem.self, #"{"title":"Many","keywords":[\#(many)]}"#).keywords.count
                == PluginItem.maxKeywords)
    }

    @Test func malformedDecorationsDropOnlyTheirRow() throws {
        let response = try PluginResponse.decode(Data(#"""
        {"items":[{"title":"Bad","accessory":5},{"title":"Worse","keywords":"one"},{"title":"Good","accessory":"3"}]}
        """#.utf8))
        #expect(response.items == [PluginItem(title: "Good", accessory: "3")])
    }

    @Test func decodesSortAndEmptyText() throws {
        #expect(try decode(PluginAction.self, #"{"type":"list","sort":false,"emptyText":"No contexts"}"#)
                == .list(args: [], options: PluginListOptions(sorts: false, emptyText: "No contexts")))
        #expect(try decode(PluginAction.self, #"{"type":"menu","items":[],"sort":false}"#)
                == .menu([], options: PluginListOptions(sorts: false)))
        // A search's rows keep the plugin's order whatever `sort` says.
        #expect(try decode(PluginAction.self, #"{"type":"search","sort":false,"emptyText":"Type a name"}"#)
                == .search(args: [], debounce: PluginAction.defaultDebounce, minimumQuery: 1,
                           options: PluginListOptions(emptyText: "Type a name")))
        #expect(try decode(PluginAction.self, #"{"type":"list","emptyText":" "}"#) == .list(args: []))
        let source = PluginSource(.menu([], options: PluginListOptions(sorts: false, emptyText: "E")))
        #expect(source?.options == PluginListOptions(sorts: false, emptyText: "E"))
    }

    @Test func emptyTextWaitsForRowsAndCoversShortQueries() {
        let list = PluginSource.list(args: [])
        #expect(list.emptyText(query: "", loaded: false) == nil)
        #expect(list.emptyText(query: "x", loaded: true) == PluginSource.defaultEmptyText)
        let custom = PluginSource.list(args: [], options: PluginListOptions(emptyText: "Nothing here"))
        #expect(custom.emptyText(query: "", loaded: true) == "Nothing here")

        let search = PluginSource.search(args: [], debounce: 0, minimumQuery: 2,
                                         options: PluginListOptions(emptyText: "Type a repository"))
        #expect(search.emptyText(query: " a ", loaded: false) == "Type a repository")
        #expect(search.emptyText(query: "ab", loaded: false) == nil)
        #expect(search.emptyText(query: "ab", loaded: true) == "Type a repository")
        // Without text of its own, a short query leaves the bar empty, as an empty root query does.
        let bare = PluginSource.search(args: [], debounce: 0, minimumQuery: 2)
        #expect(bare.emptyText(query: "a", loaded: true) == nil)
        #expect(bare.emptyText(query: "ab", loaded: true) == PluginSource.defaultEmptyText)
    }

    @Test func titleMatchesRankAboveKeywordOnlyMatches() {
        let list = PluginList(items: [
            PluginItem(title: "Production", keywords: ["kube"]),
            PluginItem(title: "Kubernetes Dashboard"),
            PluginItem(title: "Staging", keywords: ["kubectl", "kube-stage"]),
            PluginItem(title: "Other"),
        ])
        #expect(titles(list, "kube") == ["Kubernetes Dashboard", "Production", "Staging"])
        // A keyword finds the row once, however many of its keywords match.
        #expect(titles(list, "stage") == ["Staging"])
        #expect(titles(list, "zzz").isEmpty)
        #expect(titles(list, " ") == ["Production", "Kubernetes Dashboard", "Staging", "Other"])
    }

    @Test func unsortedListsNarrowButKeepThePluginsOrder() {
        let items = [
            PluginItem(title: "Bar Code"),
            PluginItem(title: "Code"),
            PluginItem(title: "Nothing"),
            PluginItem(title: "Zed", keywords: ["code"]),
            PluginItem(title: "Codec"),
        ]
        #expect(titles(PluginList(items: items), "code") == ["Code", "Codec", "Bar Code", "Zed"])
        #expect(titles(PluginList(items: items, sorts: false), "code") == ["Bar Code", "Code", "Zed", "Codec"])
        #expect(titles(PluginList(items: items, sorts: false), "") == items.map(\.title))
    }

    /// Keystroke cost for a full list, sorted with keywords and not, against the plain
    /// title-only list it extends. Printed, not asserted: timing varies by machine.
    @Test func keystrokeCostForAFullList() {
        let words = ["alpha", "beta", "gamma", "delta", "kube", "prod", "stage", "swift", "react", "infra"]
        let items = (0..<PluginItem.maxItems).map { i in
            PluginItem(title: "\(words[i % 10])-\(words[(i / 10) % 10]) service \(i)",
                       keywords: [words[(i + 3) % 10], "team-\(i % 17)"])
        }
        let plain = PluginList(items: items.map { PluginItem(title: $0.title) })
        let keyed = PluginList(items: items)
        let unsorted = PluginList(items: items, sorts: false)
        let matcher = Matcher()
        let queries = ["k", "ku", "kub", "kube", "kube-p", "sv", "team", "a", "stg", "zz"]
        func time(_ list: PluginList) -> Double {
            for q in queries { _ = list.matchingIndices(q, matcher: matcher) }
            let start = DispatchTime.now().uptimeNanoseconds
            let rounds = 20
            for _ in 0..<rounds { for q in queries { _ = list.matchingIndices(q, matcher: matcher) } }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds * queries.count) / 1_000
        }
        print(String(format: "plugin list keystroke (500 rows): title only %.1f µs, keywords %.1f µs, unsorted %.1f µs",
                     time(plain), time(keyed), time(unsorted)))
    }
}
