/// The query field searches the root, a menu, or takes a template link's argument.
public enum SearchScope: Sendable {
    case root
    case menu(SearchMenu)
    case argument(AppEntry)
}

public enum SearchSelection: Sendable {
    case topHit, navigated, dismissed
}

/// Saves the exact parent context on each entry, including a dismissed completion.
/// No navigation or submenu query is persisted when the panel closes.
public struct SearchNavigation {
    public struct Location {
        public let scope: SearchScope
        public let query: String
        public let selectedID: String?
        public let selection: SearchSelection
    }

    public private(set) var scope = SearchScope.root
    private var parents: [Location] = []

    public init() {}

    public var canGoBack: Bool { !parents.isEmpty }
    /// Query memory recalls the root search, never a menu filter or link argument.
    public var rootQuery: String? { parents.first?.query }

    public mutating func enter(_ scope: SearchScope, query: String,
                               selectedID: String?, selection: SearchSelection) {
        parents.append(Location(scope: self.scope, query: query,
                                selectedID: selectedID, selection: selection))
        self.scope = scope
    }

    /// Apply the current preference on return, so a change affects scopes already open.
    @discardableResult
    public mutating func back(behavior: BackNavigationBehavior = .restoreQuery) -> Location? {
        guard let parent = parents.popLast() else { return nil }
        scope = parent.scope
        switch behavior {
        case .restoreQuery: return parent
        case .clearQuery:
            return Location(scope: parent.scope, query: "", selectedID: nil, selection: .topHit)
        }
    }

    public mutating func reset() {
        scope = .root
        parents.removeAll(keepingCapacity: true)
    }
}
