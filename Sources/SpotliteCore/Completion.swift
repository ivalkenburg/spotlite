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
        var end = title.startIndex
        for typed in query {
            guard end < title.endIndex,
                  AppEntry.typeable(title[end]).lowercased() == AppEntry.typeable(typed).lowercased()
            else { return mode == .allMatches ? " – " + title : "" }
            title.formIndex(after: &end)
        }
        let remainder = String(title[end...])
        return action == "Open" ? remainder : remainder + " – " + action
    }
}
