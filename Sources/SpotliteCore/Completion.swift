/// The text Spotlight draws after the query, inside a pill, for the selected result.
///
/// When the query is a prefix of the title the pill finishes the title and names the
/// action ("saf" + "ari — Open"). Otherwise the query stays as typed and the pill names
/// the result ("gc" + " — Google Chrome"), because finishing a word the user never
/// started would read as a misprediction.
public enum Completion {
    public static func suffix(query: String, title: String, action: String) -> String {
        guard !query.isEmpty else { return "" }
        let queryChars = Array(query), titleChars = Array(title)
        let isPrefix = queryChars.count <= titleChars.count
            && String(titleChars[0..<queryChars.count]).lowercased() == query.lowercased()
        guard isPrefix else { return " — " + title }
        // The remainder keeps the title's own case, the typed part keeps the user's.
        return String(titleChars[queryChars.count...]) + " — " + action
    }
}
