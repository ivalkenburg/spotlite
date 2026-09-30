import Foundation

/// Actions are dispatched by the AppKit layer; menu definitions stay headless.
public enum SearchMenuAction: Sendable, Equatable {
    case toggleCaffeinate
    case generateUUID(UUIDVersion)
}

/// An item can have a direct Return action, a submenu, or both. Without an action,
/// Return enters its submenu; Tab always enters the submenu when one exists.
public struct SearchMenuItem: Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let action: SearchMenuAction?
    public let closesPanelOnAction: Bool
    public let submenu: SearchMenu?

    public init(id: String, title: String, symbolName: String = "folder",
                action: SearchMenuAction? = nil, closesPanelOnAction: Bool = true,
                submenu: SearchMenu? = nil) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.action = action
        self.closesPanelOnAction = closesPanelOnAction
        self.submenu = submenu
    }
}

/// Search only these items, with no root results, history, calculator or web search.
/// Matching metadata is prepared once when the menu is defined.
public struct SearchMenu: Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let items: [SearchMenuItem]
    private let corpus: SearchCorpus
    private let byID: [String: Int]

    public init(id: String, title: String, symbolName: String = "folder",
                items: [SearchMenuItem]) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.items = items
        self.corpus = SearchCorpus(entries: items.map {
            AppEntry(url: URL(string: "spotlite-menu:")!, name: $0.title,
                     bundleID: $0.id, kind: .command)
        })
        self.byID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    public func search(_ query: String, matcher: Matcher) -> [SearchMenuItem] {
        if query.allSatisfy(\.isWhitespace) { return items }
        return matcher.search(query, in: corpus, limit: items.count).compactMap {
            byID[$0.entry.id].map { items[$0] }
        }
    }

    public static let generateUUID = SearchMenu(
        id: "generateUUID", title: "Generate UUID", symbolName: "number",
        items: [
            SearchMenuItem(id: "uuid.v4", title: "v4 — Random", symbolName: "dice",
                           action: .generateUUID(.v4)),
            SearchMenuItem(id: "uuid.v7", title: "v7 — Time ordered", symbolName: "clock",
                           action: .generateUUID(.v7)),
        ]
    )

    public static let caffeinate = SearchMenu(
        id: "caffeinate", title: "Caffeinate", symbolName: "cup.and.saucer",
        items: [SearchMenuItem(id: "caffeinate.toggle", title: "Toggle Caffeinate",
                               symbolName: "cup.and.saucer", action: .toggleCaffeinate,
                               closesPanelOnAction: false)]
    )
}
