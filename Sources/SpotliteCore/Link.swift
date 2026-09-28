import Foundation

/// A folder, file or web address the user added in Settings, found by name like an app.
/// A target containing `{query}` is a template: Tab on it takes an argument that fills
/// the placeholder.
public struct Link: Codable, Sendable, Equatable, Identifiable {
    /// Stable across edits, so a renamed or retargeted link keeps its alias and history.
    public let id: String
    public var name: String
    /// As typed: `~/Downloads`, `/Volumes/Work`, `github.com`, `https://…`, `mailto:…`.
    public var target: String

    public init(id: String = UUID().uuidString, name: String, target: String) {
        self.id = id
        self.name = name
        self.target = target
    }

    static let idPrefix = "com.igorv.spotlite.link."
    public static let placeholder = "{query}"

    public var isTemplate: Bool { target.contains(Link.placeholder) }

    /// Stands in for a bundle identifier, so hiding, aliases and history key on it.
    public var entryID: String { Link.idPrefix + id }

    /// A template resolves with its placeholder empty, as Return with nothing typed opens it.
    public var url: URL? { Link.resolve(target) }

    /// Nil when the target can't be understood; Settings refuses those, so only a
    /// hand-edited file produces one.
    public var entry: AppEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url else { return nil }
        return AppEntry(url: url, name: trimmed, bundleID: entryID, kind: .link,
                        template: isTemplate ? target : nil)
    }

    /// Paths start with `/` or `~`. Anything with a scheme is taken as written. A bare
    /// host such as `github.com/ivalkenburg` becomes an https address, as a browser's
    /// address bar would treat it.
    ///
    /// `argument` replaces every `{query}`: as typed in a path, percent-encoded as a query
    /// value in an address so `&`, `#` or a space can't break it. The target's shape is
    /// judged before filling, so `tel:{query}` stays a scheme when the argument is digits.
    public static func resolve(_ target: String, argument: String = "",
                               home: String = NSHomeDirectory()) -> URL? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)

        if t == "~" || t.hasPrefix("~/") || t.hasPrefix("/") {
            let path = t.replacingOccurrences(of: placeholder, with: value)
            return URL(fileURLWithPath: path.hasPrefix("~") ? home + path.dropFirst() : path)
        }
        // `./Downloads` is a relative path, which has nothing to be relative to here.
        guard !t.hasPrefix("."), !t.contains(where: \.isWhitespace) else { return nil }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .queryValueAllowed) ?? ""
        let address = t.replacingOccurrences(of: placeholder, with: encoded)

        // Local servers rarely speak https. Match the whole host, not names such as
        // `localhostish.com`, and check it before interpreting a port as a URL scheme.
        if t == "localhost" || t.hasPrefix("localhost:") || t.hasPrefix("localhost/")
            || isIPv4Host(t) { return URL(string: "http://" + address) }
        // A dotted prefix with digits after the colon is a host with a port. A
        // syntactically valid prefix otherwise names a scheme, including numeric
        // values such as `tel:0612345678` and `sms:12345`.
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
           let colon = t.firstIndex(of: ":"),
           !t[..<colon].contains(".") || t[t.index(after: colon)...].first?.isNumber == false {
            return URL(string: address)
        }
        if t.contains(".") { return URL(string: "https://" + address) }
        return nil
    }

    /// `192.168.1.1`, optionally followed by a port or path.
    private static func isIPv4Host(_ t: String) -> Bool {
        t.range(of: #"^\d{1,3}(\.\d{1,3}){3}([:/]|$)"#, options: .regularExpression) != nil
    }
}
