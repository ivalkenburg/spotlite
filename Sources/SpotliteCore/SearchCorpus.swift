import Foundation

/// The entries a query is matched against, with everything that changes only with the
/// index or preferences resolved up front: hidden entries and switched-off kinds are
/// dropped, and each entry's alias is looked up once instead of hashed per keystroke.
public struct SearchCorpus: Sendable {
    public let entries: [AppEntry]
    /// Parallel to `entries`.
    let aliases: [AliasIndex.Prepared?]
    let hasAliases: Bool

    public static let empty = SearchCorpus(entries: [])

    public init(
        entries: [AppEntry],
        aliases: AliasIndex = .empty,
        hiddenBundleIDs: Set<String> = [],
        includeSettingsPanes: Bool = true,
        includeCommands: Bool = true
    ) {
        let kept = entries.filter { entry in
            if !includeSettingsPanes, entry.kind == .settingsPane { return false }
            if !includeCommands, entry.kind == .command { return false }
            guard let bundleID = entry.bundleID else { return true }
            return !hiddenBundleIDs.contains(bundleID)
        }
        self.entries = kept
        self.aliases = aliases.isEmpty ? [] : kept.map { aliases[$0.id] }
        hasAliases = !aliases.isEmpty
    }
}
