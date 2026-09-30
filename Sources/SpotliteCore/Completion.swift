/// How much of the selected app's name appears after the query.
public enum AppNameCompletion: String, Codable, Sendable, CaseIterable {
    case off
    case prefixOnly
    case allMatches
}

/// Text drawn after the query for the selected result. Prefix matches finish the
/// title; other matches name the result. Opening is implicit, while other actions
/// such as Run and Copy remain explicit.
public enum Completion {
    public static func suffix(query: String, title: String, action: String,
                              mode: AppNameCompletion = .allMatches) -> String {
        guard !query.isEmpty, mode != .off else { return "" }
        let queryChars = Array(query), titleChars = Array(title)
        let isPrefix = queryChars.count <= titleChars.count
            && String(titleChars[0..<queryChars.count].map(AppEntry.typeable)).lowercased()
                == query.lowercased()
        guard isPrefix else { return mode == .allMatches ? " – " + title : "" }
        // The remainder keeps the title's own case, the typed part keeps the user's.
        let remainder = String(titleChars[queryChars.count...])
        return action == "Open" ? remainder : remainder + " – " + action
    }
}
