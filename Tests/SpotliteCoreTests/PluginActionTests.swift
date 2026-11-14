import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin secondary actions and confirmation")
struct PluginActionTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func shortcutsNameModifiersAndCombinations() {
        #expect(PluginShortcut("cmd") == .command)
        #expect(PluginShortcut("opt") == .option)
        #expect(PluginShortcut("Shift") == .shift)
        #expect(PluginShortcut("ctrl") == .control)
        #expect(PluginShortcut("cmd+shift") == [.command, .shift])
        #expect(PluginShortcut("option + command") == [.command, .option])
        for bad in ["", "+", "cmd+", "hyper", "cmd+k", "return"] {
            #expect(PluginShortcut(bad) == nil, "\(bad)")
        }
        #expect(PluginShortcut.command.keyText == "⌘↩")
        #expect(PluginShortcut([.command, .shift, .option, .control]).keyText == "⌃⌥⇧⌘↩")
    }

    @Test func rowsDecodeSecondaryActionsLossily() throws {
        let item = try decode(PluginItem.self, #"""
        {"title":"octo/app","action":{"type":"open","url":"https://github.com/octo/app"},
         "actions":[
           {"title":"Copy Clone URL","shortcut":"cmd","icon":"doc.on.doc",
            "action":{"type":"copy","text":"git@github.com:octo/app.git"}},
           {"title":"No action"},
           {"title":"Bad shortcut","shortcut":"hyper","action":{"type":"copy","text":"x"}},
           {"title":"Bad type","action":{"type":"launch"}},
           {"title":"   ","action":{"type":"copy","text":"x"}},
           {"title":"Branches","action":{"type":"list","args":["branches"]},
            "actions":[{"title":"Nested","action":{"type":"copy","text":"n"}}]}
         ]}
        """#)
        #expect(item.actions == [
            PluginSecondaryAction(title: "Copy Clone URL", shortcut: .command, icon: "doc.on.doc",
                                  action: .copy("git@github.com:octo/app.git")),
            PluginSecondaryAction(title: "Branches", action: .list(args: ["branches"])),
        ])
        // Not an array: the row stays, without actions.
        #expect(try decode(PluginItem.self, #"{"title":"A","actions":5}"#).actions.isEmpty)
    }

    @Test func secondaryActionsAreCapped() throws {
        let actions = (0..<40).map { #"{"title":"A\#($0)","action":{"type":"copy","text":"\#($0)"}}"# }
        let item = try decode(PluginItem.self, #"{"title":"Row","actions":[\#(actions.joined(separator: ","))]}"#)
        #expect(item.actions.count == PluginSecondaryAction.maxCount)
        #expect(item.actions.last?.title == "A15")
    }

    @Test func commandsTakeActionsAndConfirm() throws {
        let manifest = try decode(PluginManifest.self, #"""
        {"id":"git","name":"Git","commands":[
          {"id":"prune","title":"Prune","action":{"type":"run","args":["prune"],"confirm":"Prune branches?"},
           "actions":[{"title":"Dry Run","shortcut":"opt","action":{"type":"run","args":["prune","-n"]}}]}]}
        """#)
        let command = manifest.commands[0]
        #expect(command.confirm == PluginConfirmation(title: "Prune branches?"))
        #expect(command.actions.map(\.shortcut) == [.option])
        // A command's malformed confirm fails the manifest, as any malformed action does.
        #expect(throws: DecodingError.self) {
            try decode(PluginManifest.self, #"{"id":"g","name":"G","commands":[{"id":"c","title":"C","action":{"type":"copy","text":"x","confirm":4}}]}"#)
        }
    }

    @Test func confirmTakesAStringOrAnObject() throws {
        let plain = try decode(PluginConfirmation.self, #""Delete branch main?""#)
        #expect(plain == PluginConfirmation(title: "Delete branch main?", button: "Confirm"))
        let full = try decode(PluginConfirmation.self,
            #"{"title":"Delete main?","message":"This cannot be undone.","button":"Delete","destructive":true}"#)
        #expect(full == PluginConfirmation(title: "Delete main?", message: "This cannot be undone.", button: "Delete",
                                           isDestructive: true))
        #expect(try decode(PluginConfirmation.self, #"{"title":"Sure?","button":" ","message":""}"#)
                == PluginConfirmation(title: "Sure?"))
        for bad in [#""""#, #"" ""#, #"{"message":"m"}"#, "5", #"{"title":"t","destructive":"yes"}"#] {
            #expect(throws: DecodingError.self, "\(bad)") { try decode(PluginConfirmation.self, bad) }
        }
    }

    @Test func malformedConfirmDropsTheRowNotTheResponse() throws {
        let response = try PluginResponse.decode(Data(#"""
        {"items":[{"title":"Asks","action":{"type":"run","confirm":{"title":"Sure?","button":"Go"}}},
                  {"title":"Broken","action":{"type":"run","confirm":{"button":"Go"}}},
                  {"title":"Plain","action":{"type":"run"}}]}
        """#.utf8))
        #expect(response.items?.map(\.title) == ["Asks", "Plain"])
        #expect(response.items?[0].confirm == PluginConfirmation(title: "Sure?", button: "Go"))
        #expect(response.items?[1].confirm == nil)
        // A secondary's confirm is read from its own action.
        let item = try decode(PluginItem.self, #"""
        {"title":"Row","actions":[{"title":"Delete","action":{"type":"run","args":["rm"],"confirm":"Delete?"}},
                                  {"title":"Broken","action":{"type":"run","confirm":[]}}]}
        """#)
        #expect(item.actions.map(\.title) == ["Delete"])
        #expect(item.actions[0].confirm?.title == "Delete?")
        // An informational row has nothing to confirm.
        #expect(PluginItem(title: "Info", confirm: PluginConfirmation(title: "?")).confirm == nil)
    }

    @Test func modifiersPickTheirAction() {
        let set = PluginActionSet(
            primary: .open("https://example.com/a"), confirm: nil,
            secondaries: [
                PluginSecondaryAction(title: "Clone URL", shortcut: .command, action: .copy("git")),
                PluginSecondaryAction(title: "Also command", shortcut: .command, action: .copy("second")),
                PluginSecondaryAction(title: "List only", action: .copy("list")),
                PluginSecondaryAction(title: "Both", shortcut: [.command, .shift], action: .copy("both")),
            ],
            title: "octo/app", icon: "book")
        #expect(set.entry(for: [])?.action == .open("https://example.com/a"))
        #expect(set.entry(for: .command)?.title == "Clone URL")
        #expect(set.entry(for: [.command, .shift])?.title == "Both")
        // Exact chords only: Shift alone is unbound.
        #expect(set.entry(for: .shift) == nil)
        // The built-in copy keeps ⌥ for an open row that does not claim it.
        #expect(set.entry(for: .option) == PluginActionEntry(title: "Copy Link", icon: "link", shortcut: .option,
            action: .copy("https://example.com/a"), confirm: nil, levelTitle: "octo/app", levelIcon: "book"))
        #expect(set.items.map(\.item.title) == ["Open", "Clone URL", "Also command", "List only", "Both", "Copy Link"])
        // A second claim on a chord stays reachable from the list, without the key.
        #expect(set.items.map(\.key) == ["↩", "⌘↩", nil, nil, "⇧⌘↩", "⌥↩"])
        #expect(set.entries[1].levelTitle == "Clone URL" && set.entries[0].levelTitle == "octo/app")
    }

    @Test func aDeclaredOptionReplacesTheBuiltInCopy() {
        let declared = PluginActionSet(
            primary: .open("https://example.com"), confirm: nil,
            secondaries: [PluginSecondaryAction(title: "Copy Name", shortcut: .option, action: .copy("name"))],
            title: "Row", icon: nil)
        #expect(declared.entry(for: .option)?.title == "Copy Name")
        #expect(!declared.entries.contains { $0.title == "Copy Link" })
        // Not an address: nothing to copy unless declared.
        let run = PluginActionSet(primary: .run(args: [], keepOpen: false), confirm: nil, secondaries: [],
                                  title: "Row", icon: nil)
        #expect(run.entry(for: .option) == nil)
        #expect(run.items.map(\.item.title) == ["Run"])
    }

    @Test func aRowWithoutAnActionStillListsItsSecondaries() {
        let set = PluginActionSet(PluginItem(title: "Info", actions: [
            PluginSecondaryAction(title: "Copy", shortcut: .command, action: .copy("c"),
                                  confirm: PluginConfirmation(title: "Copy?")),
        ]))
        #expect(set.primary == nil && set.entry(for: []) == nil)
        #expect(set.items.map(\.key) == ["⌘↩"])
        #expect(set.entry(for: .command)?.confirm?.title == "Copy?")
    }

    @Test func confirmationRowsPutTheButtonFirst() {
        let rows = PluginConfirmation(title: "Delete main?", message: "Also on origin.", button: "Delete",
                                      isDestructive: true).items(icon: "trash")
        #expect(rows.map(\.id) == [PluginConfirmation.confirmID, PluginConfirmation.cancelID])
        #expect(rows[0].title == "Delete" && rows[0].accessory == "Also on origin.")
        #expect(rows[0].icon == "exclamationmark.triangle")
        #expect(PluginConfirmation(title: "Run?").items(icon: "play")[0].icon == "play")
        #expect(rows.allSatisfy { $0.action == nil })
    }
}
