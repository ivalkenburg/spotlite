import Testing
@testable import SpotliteCore

@Suite("Alias conflicts")
struct AliasConflictsTests {
    @Test func comparesLikeMatcherAndExcludesTheEditedIdentity() {
        let aliases = ["a": " PS ", "b": "ps", "c": "pstore", "d": " "]
        #expect(AliasConflicts.conflictingIDs(for: "ps", excluding: "a", aliases: aliases) == ["b"])
        #expect(AliasConflicts.conflictingIDs(for: " Ps ", excluding: nil, aliases: aliases) == ["a", "b"])
        #expect(AliasConflicts.conflictingIDs(for: "p", excluding: nil, aliases: aliases).isEmpty)
        #expect(AliasConflicts.conflictingIDs(for: " ", excluding: nil, aliases: aliases).isEmpty)
        #expect(AliasConflicts.conflictingIDs(for: "other", excluding: nil, aliases: aliases).isEmpty)
    }
}
