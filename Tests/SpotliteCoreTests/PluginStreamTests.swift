import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin streams")
struct PluginStreamTests {
    private func decode(_ chunks: [String]) -> PluginStreamDecoder {
        var decoder = PluginStreamDecoder()
        for chunk in chunks { decoder.feed(Data(chunk.utf8)) }
        decoder.finish()
        return decoder
    }

    @Test func eachLineIsARow() {
        let decoder = decode([#"{"title":"a"}"# + "\n" + #"{"title":"b","accessory":"x"}"# + "\n"])
        #expect(decoder.items.map(\.title) == ["a", "b"])
        #expect(decoder.items[1].accessory == "x")
        #expect(decoder.skipped == 0)
    }

    @Test func linesSplitAcrossChunksJoin() {
        var decoder = PluginStreamDecoder()
        let added = [decoder.feed(Data(#"{"tit"#.utf8)), decoder.feed(Data(#"le":"split"#.utf8)),
                     decoder.feed(Data("\"}\n{\"title\":\"next\"}".utf8))]
        #expect(added == [false, false, true])
        #expect(decoder.items.map(\.title) == ["split"])
        // The last line needs no newline.
        let finished = [decoder.finish(), decoder.finish()]
        #expect(finished == [true, false])
        #expect(decoder.items.map(\.title) == ["split", "next"])
    }

    @Test func byteAtATime() {
        let text = #"{"title":"één"}"# + "\r\n" + #"{"title":"two"}"# + "\n"
        var decoder = PluginStreamDecoder()
        for byte in Data(text.utf8) { decoder.feed(Data([byte])) }
        decoder.finish()
        #expect(decoder.items.map(\.title) == ["één", "two"])
    }

    @Test func crlfAndBlankLines() {
        let decoder = decode(["\r\n", #"{"title":"a"}"# + "\r\n", "  \n\n", "\t\r\n", #"{"title":"b"}"#])
        #expect(decoder.items.map(\.title) == ["a", "b"])
        #expect(decoder.skipped == 0)
    }

    @Test func malformedLinesAreSkippedOneByOne() {
        let decoder = decode([
            #"{"title":"a"}"#, "\n",
            "not json\n",
            #"{"title":42}"# + "\n",
            #"["array"]"# + "\n",
            #"{"title":"b","keywords":"wrong"}"# + "\n",
            #"{"title":"c"}"# + "\n",
        ])
        #expect(decoder.items.map(\.title) == ["a", "c"])
        #expect(decoder.skipped == 4)
        #expect(decoder.errors.count == 4)
        #expect(decoder.errors[0].hasPrefix("Line 2: "))
        #expect(decoder.errors[0].contains("not json"))
        #expect(decoder.errors[1].hasPrefix("Line 3: title"))
        #expect(decoder.summary.text == "Streamed 2 rows, skipped 4 lines")
    }

    @Test func errorsAreCappedButCounted() {
        let decoder = decode(Array(repeating: "x\n", count: 30))
        #expect(decoder.skipped == 30)
        #expect(decoder.errors.count == PluginStreamDecoder.maxErrors)
    }

    @Test func nullConfirmationDropsOnlyItsStreamedRow() {
        let decoder = decode([
            #"{"title":"Unsafe","action":{"type":"run","confirm":null}}"# + "\n",
            #"{"title":"Safe","action":{"type":"run","confirm":"Run?"}}"# + "\n",
        ])
        #expect(decoder.items.map(\.title) == ["Safe"])
        #expect(decoder.items.first?.confirm?.title == "Run?")
        #expect(decoder.skipped == 1)
    }

    @Test func responseLinesApplyAtTheEnd() {
        let decoder = decode([
            #"{"toast":"first","update":[{"command":"a","subtitle":"one"}]}"# + "\n",
            #"{"title":"row"}"# + "\n",
            #"{"items":[{"title":"batch 1"},{"title":"batch 2"}],"copy":"text"}"# + "\n",
            #"{"toast":{"text":"done","style":"failure"},"update":[{"command":"b"}]}"#,
        ])
        #expect(decoder.items.map(\.title) == ["row", "batch 1", "batch 2"])
        #expect(decoder.response.toast == PluginToast(text: "done", isFailure: true))
        #expect(decoder.response.copy == "text")
        #expect(decoder.response.update.map(\.command) == ["a", "b"])
        #expect(decoder.response.items == nil)
        // An empty object is a response with nothing in it, not an error.
        #expect(decode(["{}\n"]).skipped == 0)
    }

    @Test func rowsStopAtTheCapWhileResponseLinesStillApply() {
        var lines = (0..<600).map { #"{"title":"row \#($0)"}"# + "\n" }
        lines.insert(#"{"items":[{"title":"late"}]}"# + "\n", at: 550)
        lines.append(#"{"items":[{"title":"ignored","action":{"type":"run","confirm":null}}],"toast":"after the cap","copy":"copied","open":"https://example.com","update":[{"command":"refresh"}]}"#)
        let decoder = decode([lines.joined()])
        #expect(decoder.items.count == PluginItem.maxItems)
        #expect(decoder.items.last?.title == "row 499")
        #expect(decoder.response.toast?.text == "after the cap")
        #expect(decoder.response.copy == "copied")
        #expect(decoder.response.open == "https://example.com")
        #expect(decoder.response.update.map(\.command) == ["refresh"])
        #expect(decoder.skipped == 0)
    }

    @Test func aBatchStopsAtTheCap() {
        var lines = (0..<499).map { #"{"title":"row \#($0)"}"# + "\n" }
        lines.append(#"{"items":[{"title":"fits","action":{"type":"menu","items":[{"title":"one"},{"title":"two"}]}},{"title":"cut"}]}"#)
        let decoder = decode([lines.joined()])
        #expect(decoder.items.count == PluginItem.maxItems)
        #expect(decoder.items.last?.title == "fits")
        guard case .menu(let nested, _) = decoder.items.last?.action else { Issue.record("missing menu"); return }
        #expect(nested.map(\.title) == ["one", "two"], "the row budget must not truncate a kept row’s nested menu")
    }

    @Test func actionsDecodeTheStreamFlag() throws {
        func action(_ json: String) throws -> PluginAction {
            try JSONDecoder().decode(PluginAction.self, from: Data(json.utf8))
        }
        guard case .list(_, let list) = try action(#"{"type":"list","stream":true,"sort":false}"#),
              case .search(_, _, _, let search) = try action(#"{"type":"search","stream":true}"#),
              case .list(_, let plain) = try action(#"{"type":"list"}"#) else {
            Issue.record("unexpected actions")
            return
        }
        #expect(list.streams && !list.sorts)
        #expect(search.streams)
        #expect(!plain.streams)
        #expect(PluginSource(try action(#"{"type":"search","stream":true}"#))?.options.streams == true)
    }

    @Test func recordsSayWhatStreamed() {
        let summary = PluginStreamSummary(rows: 1, skipped: 1, errors: ["Line 2: bad"])
        let report = PluginRunReport(result: .success(PluginResponse()), status: 0, stream: summary)
        let record = PluginRunRecord(report: report, commandID: "find", action: .search, arguments: [])
        #expect(record.details.contains("Streamed 1 row, skipped 1 line\nLine 2: bad"))
    }
}
