import Foundation
import Testing
@testable import SpotliteCore

@Suite("UUID generation")
struct UUIDGeneratorTests {
    @Test func versionsHaveCorrectLayoutAndLowercaseFormatting() throws {
        for version in UUIDVersion.allCases {
            let text = UUIDGenerator.generate(version)
            let parsed = try #require(UUID(uuidString: text))
            #expect(text == text.lowercased())
            #expect(text.count == 36)
            #expect(parsed.uuid.6 >> 4 == (version == .v4 ? 4 : 7))
            #expect(parsed.uuid.8 >> 6 == 2)
        }
    }

    @Test func v7EncodesUnixMillisecondsAndUsesFreshRandomness() throws {
        let date = Date(timeIntervalSince1970: 1)
        let values = (0..<100).map { _ in UUIDGenerator.generate(.v7, now: date) }
        #expect(Set(values).count == values.count)
        #expect(values.allSatisfy { $0.hasPrefix("00000000-03e8-7") })
        #expect(UUIDGenerator.generate(.v7, now: date)
                < UUIDGenerator.generate(.v7, now: date.addingTimeInterval(0.001)))
    }

    @Test func rootOpensMenuAndMenuActionsClosePanel() throws {
        let results = SearchResults.build(for: "uuid", corpus: .empty, matcher: Matcher(), frecency: Frecency())
        guard case .generateUUID = try #require(results.first) else {
            Issue.record("Expected Generate UUID"); return
        }
        let menu = SearchMenu.generateUUID
        #expect(menu.items.count == 2)
        #expect(menu.search("v7", matcher: Matcher()).map(\.id) == ["uuid.v7"])
        for (item, version) in zip(menu.items, UUIDVersion.allCases) {
            #expect(item.closesPanelOnAction)
            guard case .generateUUID(let actual) = item.action else {
                Issue.record("Missing generation action"); continue
            }
            #expect(actual == version)
        }
    }
}
