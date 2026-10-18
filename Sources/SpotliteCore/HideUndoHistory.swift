/// Consecutive hides can be undone until the query is edited or the panel closes.
/// Stores only IDs so undo never restores an outdated preferences snapshot.
public struct HideUndoHistory {
    private var bundleIDs: [String] = []

    public init() {}

    public mutating func record(_ bundleID: String) {
        bundleIDs.append(bundleID)
    }

    public mutating func pop(hiddenBundleIDs: Set<String>) -> String? {
        while let bundleID = bundleIDs.popLast() {
            if hiddenBundleIDs.contains(bundleID) { return bundleID }
        }
        return nil
    }

    public mutating func clear() {
        bundleIDs.removeAll()
    }
}
