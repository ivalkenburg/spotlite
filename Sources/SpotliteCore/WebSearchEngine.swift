import Foundation

/// Where the "Search the web" row sends the query.
public enum WebSearchEngine: String, Codable, Sendable, CaseIterable {
    case google
    case duckDuckGo
    case bing

    public static let `default` = WebSearchEngine.duckDuckGo

    public var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    private var base: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        }
    }

    public func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .queryValueAllowed)
        else { return nil }
        return URL(string: base + encoded)
    }
}

extension CharacterSet {
    /// `urlQueryAllowed` keeps `&`, `+`, `=` and `#`, which would end or alter the query.
    static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))
}
