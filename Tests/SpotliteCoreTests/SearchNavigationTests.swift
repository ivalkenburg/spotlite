import Foundation
import Testing
@testable import SpotliteCore

@Suite("Scoped navigation")
struct SearchNavigationTests {
    private func level(_ id: String) -> PluginScope {
        PluginScope(pluginID: id, title: id.capitalized, icon: nil, source: PluginSource(.menu([]))!)
    }

    private func pluginID(_ scope: SearchScope) -> String? {
        if case .plugin(let plugin) = scope { return plugin.pluginID }
        return nil
    }

    @Test func nestedNavigationRestoresEachParent() throws {
        var navigation = SearchNavigation()
        navigation.enter(.plugin(level("parent")), query: "par", selectedID: "parent", selection: .navigated)
        navigation.enter(.plugin(level("child")), query: "chi", selectedID: "child", selection: .topHit)
        #expect(navigation.rootQuery == "par")

        let parentLocation = navigation.back()
        let restoredParent = try #require(parentLocation)
        #expect(pluginID(navigation.scope) == "parent")
        #expect(restoredParent.query == "chi")
        #expect(restoredParent.selectedID == "child")
        #expect(restoredParent.selection == .topHit)

        let rootLocation = navigation.back()
        let restoredRoot = try #require(rootLocation)
        guard case .root = navigation.scope else { Issue.record("Expected root"); return }
        #expect(restoredRoot.query == "par")
        #expect(restoredRoot.selectedID == "parent")
        #expect(restoredRoot.selection == .navigated)
        #expect(!navigation.canGoBack)
        #expect(navigation.back() == nil)
        #expect(navigation.rootQuery == nil)
    }

    @Test func templateArgumentReturnsToItsParentLevel() throws {
        let entry = try #require(Link(name: "Docs", target: "https://example.com/?q={query}").entry)
        var navigation = SearchNavigation()
        navigation.enter(.plugin(level("test")), query: "menu", selectedID: "test", selection: .topHit)
        navigation.enter(.argument(entry), query: "docs", selectedID: entry.instanceID, selection: .dismissed)
        guard case .argument(let argument) = navigation.scope else { Issue.record("Expected argument"); return }
        #expect(argument.template == entry.template)
        let location = navigation.back()
        let restored = try #require(location)
        #expect(restored.query == "docs")
        #expect(restored.selection == .dismissed)
        #expect(pluginID(navigation.scope) == "test")
        #expect(navigation.rootQuery == "menu")
    }

    @Test func clearingAtEachLevelDropsItsQueryAndSelection() throws {
        var navigation = SearchNavigation()
        navigation.enter(.plugin(level("test")), query: "test", selectedID: "test", selection: .navigated)
        navigation.enter(.plugin(level("child")), query: "tgc", selectedID: "toggle", selection: .dismissed)

        let parentLocation = navigation.back(behavior: .clearQuery)
        let restoredParent = try #require(parentLocation)
        #expect(pluginID(navigation.scope) == "test")
        #expect(restoredParent.query.isEmpty)
        #expect(restoredParent.selectedID == nil)
        #expect(restoredParent.selection == .topHit)
        #expect(navigation.rootQuery == "test")

        let rootLocation = navigation.back(behavior: .clearQuery)
        let restoredRoot = try #require(rootLocation)
        guard case .root = navigation.scope else { Issue.record("Expected root"); return }
        #expect(restoredRoot.query.isEmpty)
        #expect(restoredRoot.selectedID == nil)
        #expect(restoredRoot.selection == .topHit)
        #expect(navigation.rootQuery == nil)
        #expect(!navigation.canGoBack)
    }

    @Test func behaviorIsChosenWhenReturningRatherThanEntering() throws {
        var navigation = SearchNavigation()
        navigation.enter(.plugin(level("test")), query: "test", selectedID: "test", selection: .navigated)
        navigation.enter(.plugin(level("child")), query: "tog", selectedID: "toggle", selection: .dismissed)
        let parentLocation = navigation.back(behavior: .clearQuery)
        #expect(try #require(parentLocation).query.isEmpty)
        // Clearing one level leaves its ancestors available if the preference changes.
        let rootLocation = navigation.back(behavior: .restoreQuery)
        let restored = try #require(rootLocation)
        #expect(restored.query == "test")
        #expect(restored.selectedID == "test")
        #expect(restored.selection == .navigated)
    }

    @Test(arguments: [BackNavigationBehavior.restoreQuery, .clearQuery])
    func templateArgumentReturnObeysBehavior(_ behavior: BackNavigationBehavior) throws {
        let entry = try #require(Link(name: "Docs", target: "https://example.com/?q={query}").entry)
        var navigation = SearchNavigation()
        navigation.enter(.argument(entry), query: "docs", selectedID: entry.instanceID, selection: .navigated)
        let location = navigation.back(behavior: behavior)
        let restored = try #require(location)
        guard case .root = navigation.scope else { Issue.record("Expected root"); return }
        #expect(restored.query == (behavior == .restoreQuery ? "docs" : ""))
        #expect(restored.selectedID == (behavior == .restoreQuery ? entry.instanceID : nil))
        #expect(restored.selection == (behavior == .restoreQuery ? .navigated : .topHit))
    }

    @Test func closingDropsTheWholeNavigationStack() {
        var navigation = SearchNavigation()
        navigation.enter(.plugin(level("test")), query: "caf", selectedID: "test", selection: .navigated)
        navigation.enter(.plugin(level("child")), query: "tog", selectedID: "toggle", selection: .topHit)
        navigation.reset()
        guard case .root = navigation.scope else { Issue.record("Expected root"); return }
        #expect(!navigation.canGoBack)
        #expect(navigation.rootQuery == nil)
        #expect(navigation.back() == nil)
    }
}
