import Foundation

/// Uses the same normalization as AliasIndex; copies sharing an ID are one item.
public enum AliasConflicts {
    public static func conflictingIDs(for alias: String, excluding id: String?,
                                      aliases: [String: String]) -> [String] {
        let normalized = alias.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return [] }
        return aliases.compactMap { key, value in
            key != id && value.trimmingCharacters(in: .whitespaces).lowercased() == normalized ? key : nil
        }.sorted()
    }
}
