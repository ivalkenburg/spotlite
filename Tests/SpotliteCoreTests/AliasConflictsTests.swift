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

    @Test func unicodeHyphensConflictLikeTheyMatch() {
        let aliases = ["a": "wi\u{2010}fi", "b": "Wi\u{2011}Fi", "c": "wi\u{2012}fi"]
        #expect(AliasConflicts.conflictingIDs(for: "wi-fi", excluding: nil, aliases: aliases) == ["a", "b", "c"])
    }

    @Test func aliasesAreTrimmedLowercasedAndBlanksDropped() throws {
        let index = AliasIndex(aliases: ["a": "  PS ", "b": "   ", "c": "wi\u{2011}fi"])
        let alias = try #require(index["a"])
        #expect(String(alias.chars) == "ps")
        #expect(alias.bonus == [Scoring.bonusBoundary, Scoring.bonusBoundary])
        #expect(index["b"] == nil)
        #expect(index["c"].map { String($0.chars) } == "wi-fi")
        #expect(!index.isEmpty)
        #expect(AliasIndex.empty.isEmpty)
    }
}
