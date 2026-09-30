import Foundation
import Testing
@testable import SpotliteCore

@Suite("Scoped menus")
struct SearchMenuTests {
    private let menu = SearchMenu(id: "test", title: "Test", items: [
        SearchMenuItem(id: "toggle", title: "Toggle Caffeinate", action: .toggleCaffeinate),
        SearchMenuItem(id: "settings", title: "Open Settings"),
        SearchMenuItem(id: "stop", title: "Stop"),
    ])

    @Test func emptyQueryPreservesMenuOrder() {
        let matcher = Matcher()
        #expect(menu.search("", matcher: matcher).map(\.id) == ["toggle", "settings", "stop"])
        #expect(menu.search(" \n\t", matcher: matcher).map(\.id) == ["toggle", "settings", "stop"])
    }

    @Test func fuzzySearchStaysWithinTheMenu() {
        let matcher = Matcher()
        #expect(menu.search("tgc", matcher: matcher).map(\.id) == ["toggle"])
        #expect(menu.search("OS", matcher: matcher).map(\.id) == ["settings"])
        #expect(menu.search("2+2", matcher: matcher).isEmpty)
        #expect(menu.search("Safari", matcher: matcher).isEmpty)
        #expect(menu.search(String(repeating: "t", count: 10_000), matcher: matcher).isEmpty)
    }

    @Test func prefixMatchRanksBeforeScatteredMatch() {
        let matcher = Matcher()
        #expect(menu.search("st", matcher: matcher).first?.id == "stop")
    }

    @Test func caffeineMenuHasOnlyTheToggleAndStaysOpen() throws {
        let item = try #require(SearchMenu.caffeinate.items.first)
        #expect(SearchMenu.caffeinate.items.count == 1)
        #expect(item.title == "Toggle Caffeinate")
        #expect(item.action == .toggleCaffeinate)
        #expect(!item.closesPanelOnAction)
        #expect(item.submenu == nil)
    }

    @Test func nestedNavigationRestoresEachParent() throws {
        let child = SearchMenu(id: "child", title: "Child", items: [])
        let parent = SearchMenu(id: "parent", title: "Parent", items: [
            SearchMenuItem(id: "child", title: "Child", submenu: child),
        ])
        var navigation = SearchNavigation()
        navigation.enter(.menu(parent), query: "par", selectedID: "parent", selection: .navigated)
        navigation.enter(.menu(child), query: "chi", selectedID: "child", selection: .topHit)
        #expect(navigation.rootQuery == "par")

        let menuLocation = navigation.back()
        let restoredMenu = try #require(menuLocation)
        guard case .menu(let restored) = navigation.scope else { Issue.record("Expected parent menu"); return }
        #expect(restored.id == "parent")
        #expect(restoredMenu.query == "chi")
        #expect(restoredMenu.selectedID == "child")
        #expect(restoredMenu.selection == .topHit)

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

    @Test func templateArgumentReturnsToItsParentMenu() throws {
        let entry = try #require(Link(name: "Docs", target: "https://example.com/?q={query}").entry)
        var navigation = SearchNavigation()
        navigation.enter(.menu(menu), query: "menu", selectedID: "test", selection: .topHit)
        navigation.enter(.argument(entry), query: "docs", selectedID: entry.instanceID, selection: .dismissed)
        guard case .argument(let argument) = navigation.scope else { Issue.record("Expected argument"); return }
        #expect(argument.template == entry.template)
        let location = navigation.back()
        let restored = try #require(location)
        #expect(restored.query == "docs")
        #expect(restored.selection == .dismissed)
        guard case .menu(let parent) = navigation.scope else { Issue.record("Expected menu"); return }
        #expect(parent.id == menu.id)
        #expect(navigation.rootQuery == "menu")
    }

    @Test func clearingAtEachLevelDropsItsQueryAndSelection() throws {
        var navigation = SearchNavigation()
        navigation.enter(.menu(menu), query: "test", selectedID: "test", selection: .navigated)
        navigation.enter(.menu(.caffeinate), query: "tgc", selectedID: "toggle", selection: .dismissed)

        let menuLocation = navigation.back(behavior: .clearQuery)
        let restoredMenu = try #require(menuLocation)
        guard case .menu(let parent) = navigation.scope else { Issue.record("Expected menu"); return }
        #expect(parent.id == menu.id)
        #expect(restoredMenu.query.isEmpty)
        #expect(restoredMenu.selectedID == nil)
        #expect(restoredMenu.selection == .topHit)
        #expect(parent.search(restoredMenu.query, matcher: Matcher()).map(\.id) == menu.items.map(\.id))
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
        navigation.enter(.menu(menu), query: "test", selectedID: "test", selection: .navigated)
        navigation.enter(.menu(.caffeinate), query: "tog", selectedID: "toggle", selection: .dismissed)
        let menuLocation = navigation.back(behavior: .clearQuery)
        #expect(try #require(menuLocation).query.isEmpty)
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
        navigation.enter(.menu(menu), query: "caf", selectedID: "caffeinate", selection: .navigated)
        navigation.enter(.menu(menu), query: "tog", selectedID: "toggle", selection: .topHit)
        navigation.reset()
        guard case .root = navigation.scope else { Issue.record("Expected root"); return }
        #expect(!navigation.canGoBack)
        #expect(navigation.rootQuery == nil)
        #expect(navigation.back() == nil)
    }
}
