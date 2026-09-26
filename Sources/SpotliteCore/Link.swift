import Foundation

/// A folder, file or web address the user added in Settings, found by name like an app.
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

    /// Stands in for a bundle identifier, so hiding, aliases and history key on it.
    public var entryID: String { Link.idPrefix + id }

    public var url: URL? { Link.resolve(target) }

    /// Nil when the target can't be understood; Settings refuses those, so only a
    /// hand-edited file produces one.
    public var entry: AppEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url else { return nil }
        return AppEntry(url: url, name: trimmed, bundleID: entryID, kind: .link)
    }

    /// Paths start with `/` or `~`. Anything with a scheme is taken as written. A bare
    /// host such as `github.com/ivalkenburg` becomes an https address, as a browser's
    /// address bar would treat it.
    public static func resolve(_ target: String, home: String = NSHomeDirectory()) -> URL? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        if t == "~" || t.hasPrefix("~/") {
            return URL(fileURLWithPath: home + t.dropFirst())
        }
        if t.hasPrefix("/") { return URL(fileURLWithPath: t) }
        // `./Downloads` is a relative path, which has nothing to be relative to here.
        guard !t.hasPrefix("."), !t.contains(where: \.isWhitespace) else { return nil }

        // A scheme followed by a non-digit: `mailto:a@b`, `x-apple.systempreferences:…`,
        // but not `localhost:3000`, whose colon starts a port.
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:[^0-9]", options: .regularExpression) != nil {
            return URL(string: t)
        }
        // Local servers rarely speak https.
        if t.hasPrefix("localhost") || isIPv4Host(t) { return URL(string: "http://" + t) }
        if t.contains(".") { return URL(string: "https://" + t) }
        return nil
    }

    /// `192.168.1.1`, optionally followed by a port or path.
    private static func isIPv4Host(_ t: String) -> Bool {
        t.range(of: #"^\d{1,3}(\.\d{1,3}){3}([:/]|$)"#, options: .regularExpression) != nil
    }
}
