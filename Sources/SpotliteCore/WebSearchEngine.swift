import Foundation

/// Where the "Search the web" row sends the query.
public enum WebSearchEngine: String, Codable, Sendable, CaseIterable {
    case google
    case duckDuckGo
    case bing
    case kagi

    public var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        }
    }

    private var base: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        case .kagi: return "https://kagi.com/search?q="
        }
    }

    /// `urlQueryAllowed` keeps `&`, `+`, `=` and `#`, which would end or alter the query.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))

    public func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
        else { return nil }
        return URL(string: base + encoded)
    }
}
