import Foundation
import Testing
@testable import SpotliteCore

@Suite struct PluginLooksTests {
    static func update(_ json: String) throws -> PluginCommandUpdate {
        try JSONDecoder().decode(PluginCommandUpdate.self, from: Data(json.utf8))
    }

    static func look(_ update: PluginCommandUpdate, process: ProcessIdentity? = nil) -> PluginLooks.Look {
        PluginLooks.Look(update: update, pluginID: "p", pluginName: "P", directory: URL(fileURLWithPath: "/tmp"),
                         commandTitle: "Command", process: process)
    }

    @Test func decodesPidAndMenuBar() throws {
        let update = try Self.update("""
        {"command":"c","icon":"cup.and.saucer.fill","subtitle":"On","pid":4321,
         "menuBar":{"actions":[
           {"title":"Off","action":{"type":"run","args":["stop"]}},
           {"title":"Pick","action":{"type":"list"}},
           {"title":"Find","action":{"type":"search"}},
           {"title":"Fixed","action":{"type":"menu","items":[]}},
           {"title":"Copy","action":{"type":"copy","text":"x"},"shortcut":"cmd"},
           {"title":"","action":{"type":"copy","text":"x"}}]}}
        """)
        #expect(update.pid == 4321)
        // Search and menu need typing the menu bar cannot give; a blank title is malformed.
        #expect(update.menuBar?.actions.map(\.title) == ["Off", "Pick", "Copy"])
        #expect(!update.isReset)
    }

    @Test func filtersMenuBarActionsBeforeCapping() throws {
        let search = (0..<4).map { #"{"title":"S\#($0)","action":{"type":"search"}}"# }
        let run = (0..<8).map { #"{"title":"R\#($0)","action":{"type":"run"}}"# }
        let update = try Self.update(#"{"command":"c","menuBar":{"actions":[\#((search + run).joined(separator: ","))]}}"#)
        #expect(update.menuBar?.actions.map(\.title) == (0..<8).map { "R\($0)" })
    }

    @Test func rejectsExpiresOutOfRange() throws {
        for value in ["1e300", "-1e300", "100000000001"] {
            #expect(throws: (any Error).self) { try Self.update(#"{"command":"c","expires":\#(value)}"#) }
        }
        #expect(try Self.update(#"{"command":"c","expires":100000000000}"#).expires == 1e11)
    }

    @Test func capsMenuBarActions() throws {
        let actions = (0..<12).map { #"{"title":"A\#($0)","action":{"type":"copy","text":"x"}}"# }.joined(separator: ",")
        let update = try Self.update(#"{"command":"c","menuBar":{"actions":[\#(actions)]}}"#)
        #expect(update.menuBar?.actions.count == PluginMenuBar.maxActions)
        // A look with only a menu bar is not a reset.
        #expect(!update.isReset)
    }

    @Test func rejectsPidsThatNameGroups() throws {
        for pid in ["0", "1", "-5", "4294967296"] {
            #expect(throws: (any Error).self) { try Self.update(#"{"command":"c","pid":\#(pid)}"#) }
        }
        // In a response, such an update drops alone.
        let response = try PluginResponse.decode(Data(#"{"update":[{"command":"a","pid":0},{"command":"b","subtitle":"x"}]}"#.utf8))
        #expect(response.update.map(\.command) == ["b"])
    }

    @Test func formatsExpiresPlaceholder() throws {
        let deadline = Date(timeIntervalSince1970: 1_794_601_717)
        let update = try Self.update(#"{"command":"c","subtitle":"{expires} to {expires}","expires":\#(deadline.timeIntervalSince1970)}"#)
        let time = deadline.formatted(date: .omitted, time: .shortened)
        // Every placeholder is replaced; today shows the time alone.
        #expect(update.displaySubtitle(now: deadline) == "\(time) to \(time)")
        // Another day shows the date too.
        let dated = deadline.formatted(date: .abbreviated, time: .shortened)
        #expect(update.displaySubtitle(now: deadline.addingTimeInterval(-3 * 86_400)) == "\(dated) to \(dated)")
        #expect(try Self.update(#"{"command":"c","subtitle":"Plain"}"#).displaySubtitle() == "Plain")
        #expect(try Self.update(#"{"command":"c","subtitle":"At {expires}"}"#).displaySubtitle() == "At ")
        #expect(try Self.update(#"{"command":"c","icon":"x","expires":5}"#).displaySubtitle() == nil)
    }

    @Test func pidAndExpiresAloneAreAReset() throws {
        #expect(try Self.update(#"{"command":"c","pid":4321,"expires":5}"#).isReset)
    }

    @Test func olderRunCannotReplaceNewerUpdate() throws {
        var looks = PluginLooks()
        let on = Self.look(try Self.update(#"{"command":"c","subtitle":"On"}"#))
        let off = Self.look(try Self.update(#"{"command":"c","subtitle":"Off"}"#))
        do { let changed = looks.apply(on, entryID: "e", sequence: 5); #expect(changed) }
        // A list that started before the run that turned it on finishes later.
        do { let changed = looks.apply(off, entryID: "e", sequence: 3); #expect(!changed) }
        #expect(looks.look(for: "e", at: Date())?.update.subtitle == "On")
        // A reset is remembered, so an older run cannot undo it either.
        do { let changed = looks.apply(nil, entryID: "e", sequence: 6); #expect(changed) }
        do { let changed = looks.apply(on, entryID: "e", sequence: 5); #expect(!changed) }
        #expect(looks.look(for: "e", at: Date()) == nil)
        // The same run may update the command twice; the last wins.
        do { let changed = looks.apply(on, entryID: "e", sequence: 7); #expect(changed) }
        do { let changed = looks.apply(off, entryID: "e", sequence: 7); #expect(changed) }
        #expect(looks.look(for: "e", at: Date())?.update.subtitle == "Off")
        // The same look again changes nothing, so nothing redraws.
        do { let changed = looks.apply(off, entryID: "e", sequence: 8); #expect(!changed) }
        // A reset update is a reset.
        do { let changed = looks.apply(Self.look(try Self.update(#"{"command":"c"}"#)), entryID: "e", sequence: 9); #expect(changed) }
        #expect(looks.looks.isEmpty)
    }

    @Test func olderRunStaysOutAfterExitOrExpiry() throws {
        let mine = ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0)
        var looks = PluginLooks()
        let on = Self.look(try Self.update(#"{"command":"c","subtitle":"On","expires":100,"menuBar":{}}"#), process: mine)
        looks.apply(on, entryID: "e", sequence: 4)
        looks.removeLooks(of: mine)
        do { let changed = looks.apply(on, entryID: "e", sequence: 3); #expect(!changed) }
        looks.apply(on, entryID: "e", sequence: 5)
        looks.removeExpired(at: Date(timeIntervalSince1970: 200))
        do { let changed = looks.apply(on, entryID: "e", sequence: 4); #expect(!changed) }
        #expect(looks.looks.isEmpty)
    }

    @Test func retainForgetsRemovedCommands() throws {
        var looks = PluginLooks()
        let on = Self.look(try Self.update(#"{"command":"c","subtitle":"On"}"#))
        looks.apply(on, entryID: "e", sequence: 9)
        do { let changed = looks.retain(commands: { _ in false }, orphans: { _ in false }); #expect(changed) }
        do { let changed = looks.retain(commands: { _ in false }, orphans: { _ in false }); #expect(!changed) }
        // Reinstalled, the command starts over: an earlier-numbered run applies again.
        do { let changed = looks.apply(on, entryID: "e", sequence: 1); #expect(changed) }
    }

    @Test func expiresAndSchedulesOnlyMenuBarLooks() throws {
        var looks = PluginLooks()
        looks.apply(Self.look(try Self.update(#"{"command":"a","subtitle":"x","expires":100}"#)), entryID: "a", sequence: 1)
        // A root row checks its own deadline when drawn; no timer is needed for it.
        #expect(looks.nextMenuBarDeadline == nil)
        looks.apply(Self.look(try Self.update(#"{"command":"b","expires":300,"menuBar":{}}"#)), entryID: "b", sequence: 2)
        looks.apply(Self.look(try Self.update(#"{"command":"c","expires":200,"menuBar":{}}"#)), entryID: "c", sequence: 3)
        #expect(looks.nextMenuBarDeadline == 200)
        #expect(looks.look(for: "a", at: Date(timeIntervalSince1970: 150)) == nil)
        do { let changed = looks.removeExpired(at: Date(timeIntervalSince1970: 250)); #expect(changed) }
        #expect(Set(looks.looks.keys) == ["b"])
        #expect(looks.nextMenuBarDeadline == 300)
        do { let changed = looks.removeExpired(at: Date(timeIntervalSince1970: 250)); #expect(!changed) }
    }

    @Test func dropsLooksOfExitedProcess() throws {
        let mine = ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0)
        let other = ProcessIdentity(pid: mine.pid, startSeconds: mine.startSeconds + 1, startMicroseconds: 0)
        var looks = PluginLooks()
        looks.apply(Self.look(try Self.update(#"{"command":"a","subtitle":"x"}"#), process: mine), entryID: "a", sequence: 1)
        looks.apply(Self.look(try Self.update(#"{"command":"b","subtitle":"x"}"#)), entryID: "b", sequence: 2)
        #expect(looks.processes == [mine])
        // A later process with the reused pid is another process.
        do { let changed = looks.removeLooks(of: other); #expect(!changed) }
        do { let changed = looks.removeLooks(of: mine); #expect(changed) }
        #expect(Set(looks.looks.keys) == ["b"])
    }

    @Test func retainKeepsRunningOrphans() throws {
        var looks = PluginLooks()
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let process = try #require(ProcessIdentity.of(sleeper.processIdentifier))
        let running = Self.look(try Self.update(#"{"command":"a","subtitle":"x"}"#), process: process)
        looks.apply(running, entryID: "gone.a", sequence: 1)
        looks.apply(Self.look(try Self.update(#"{"command":"b","subtitle":"x"}"#)), entryID: "gone.b", sequence: 2)
        looks.apply(Self.look(try Self.update(#"{"command":"c","subtitle":"x"}"#)), entryID: "kept.c", sequence: 3)
        looks.retain(commands: { $0.hasPrefix("kept.") }, orphans: { $0.process?.isRunning == true })
        #expect(Set(looks.looks.keys) == ["gone.a", "kept.c"])
    }

    @Test func processIdentity() throws {
        // Spotlite's own pid is refused, so Stop can never end Spotlite.
        #expect(ProcessIdentity.of(getpid()) == nil)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let child = try #require(ProcessIdentity.of(sleeper.processIdentifier))
        #expect(child.isRunning)
        // Same pid, other start time: a different process.
        #expect(!ProcessIdentity(pid: child.pid, startSeconds: child.startSeconds + 1, startMicroseconds: 0).isRunning)
        // launchd belongs to root, and pid 1 is refused outright.
        #expect(ProcessIdentity.of(1) == nil)
        // A child that exited and was reaped is gone.
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        #expect(ProcessIdentity.of(done.processIdentifier) == nil)
    }

    @Test func environmentCarriesSpotlitePID() throws {
        let plugin = InstalledPlugin(directory: URL(fileURLWithPath: "/tmp/p"), manifest: nil, problem: nil)
        let environment = PluginEnvironment.make(for: plugin, query: "", base: [:], spotlitePID: 4242)
        #expect(environment["SPOTLITE_PID"] == "4242")
    }

    // MARK: - Applying runs, exits held during runs

    static let plugin: InstalledPlugin = {
        let json = #"{"id":"p","name":"P","commands":[{"id":"c","title":"C","action":{"type":"list"}}]}"#
        let manifest = try! JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        return InstalledPlugin(directory: URL(fileURLWithPath: "/tmp/p"), manifest: manifest, problem: nil)
    }()
    static let entry = plugin.entryID(forCommandID: "c")
    static let old = ProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
    static let new = ProcessIdentity(pid: 200, startSeconds: 2, startMicroseconds: 0)

    /// `alive` are the processes `identify` still finds.
    static func apply(_ json: String, to looks: inout PluginLooks, sequence: UInt64,
                      installed: Bool = true, alive: Set<ProcessIdentity> = [old, new]) throws -> Bool {
        looks.apply([try update(json)], from: plugin, installed: { _ in installed }, sequence: sequence,
                    identify: { pid in alive.first { $0.pid == pid } })
    }

    @Test func applyBuildsLooksAndSkipsUnknownCommands() throws {
        var looks = PluginLooks()
        #expect(try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1))
        #expect(looks.looks[Self.entry]?.process == Self.old)
        #expect(looks.looks[Self.entry]?.commandTitle == "C")
        #expect(!(try Self.apply(#"{"command":"other","subtitle":"x"}"#, to: &looks, sequence: 2)))
        // A pid that is gone ends only the look of that process, not one of a live one.
        #expect(!(try Self.apply(#"{"command":"c","subtitle":"On","pid":300}"#, to: &looks, sequence: 3)))
        #expect(looks.looks[Self.entry]?.process == Self.old)
        #expect(try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 4, alive: []))
        #expect(looks.looks.isEmpty)
    }

    @Test func lateAnswerOfRemovedPluginKeepsOnlyARunningProcess() throws {
        var looks = PluginLooks()
        #expect(!(try Self.apply(#"{"command":"c","subtitle":"On","expires":9e9,"menuBar":{}}"#, to: &looks,
                                 sequence: 1, installed: false)))
        #expect(looks.nextMenuBarDeadline == nil)
        #expect(try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 2, installed: false))
    }

    @Test func goneProcessDuringARunIsLeftToTheRun() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1)
        looks.runStarted(pluginID: "p")
        // A list that read the old pid before the run killed it does not reset the look.
        #expect(!(try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 2, alive: [Self.new])))
        #expect(looks.looks[Self.entry]?.process == Self.old)
    }

    @Test func exitWithoutARunGoesAtOnce() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1)
        do { let changed = looks.processExited(Self.old); #expect(changed) }
        #expect(looks.looks.isEmpty)
        do { let changed = looks.processExited(Self.old); #expect(!changed) }
    }

    @Test func restartDuringARunReplacesTheLook() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1)
        looks.runStarted(pluginID: "p")
        // The run ends the old process first; its exit waits.
        do { let changed = looks.processExited(Self.old); #expect(!changed) }
        #expect(looks.looks[Self.entry] != nil)
        #expect(looks.processes.isEmpty, "An exited process must not be watched again")
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":200}"#, to: &looks, sequence: 2)
        do { let changed = looks.runEnded(pluginID: "p"); #expect(!changed) }
        #expect(looks.looks[Self.entry]?.process == Self.new)
        #expect(looks.processes == [Self.new])
    }

    @Test func heldExitClearsWhenEveryRunEnds() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1)
        looks.runStarted(pluginID: "p")
        looks.runStarted(pluginID: "p")
        do { let changed = looks.processExited(Self.old); #expect(!changed) }
        // The first run failed or was cancelled: it applied nothing, and one run remains.
        do { let changed = looks.runEnded(pluginID: "p"); #expect(!changed) }
        #expect(looks.looks[Self.entry] != nil)
        do { let changed = looks.runEnded(pluginID: "p"); #expect(changed) }
        #expect(looks.looks.isEmpty)
        // Extra ends never go below zero, so later exits are not held.
        looks.runEnded(pluginID: "p")
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":200}"#, to: &looks, sequence: 2)
        do { let changed = looks.processExited(Self.new); #expect(changed) }
    }

    @Test func earlyTimerKeepsTheDeadline() throws {
        var looks = PluginLooks()
        looks.apply(Self.look(try Self.update(#"{"command":"c","expires":300,"menuBar":{}}"#)), entryID: "c", sequence: 1)
        do { let changed = looks.removeExpired(at: Date(timeIntervalSince1970: 299.9)); #expect(!changed) }
        #expect(looks.nextMenuBarDeadline == 300)
    }

    @Test func expiresFollowsTheCalendarTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_GB")
        // 23:30 UTC is the same day at 23:00 UTC, and the day before at 00:30 UTC the next day.
        let deadline = Date(timeIntervalSince1970: 1_794_526_200) // 2026-11-12 23:30 UTC
        let update = try Self.update(#"{"command":"c","subtitle":"{expires}","expires":\#(deadline.timeIntervalSince1970)}"#)
        #expect(update.displaySubtitle(now: deadline.addingTimeInterval(-1_800), calendar: calendar) == "23:30")
        let nextDay = update.displaySubtitle(now: deadline.addingTimeInterval(3_600), calendar: calendar) ?? ""
        #expect(nextDay.hasSuffix("23:30") && nextDay.contains("12"), "Got \(nextDay)")
    }

    @Test func runReportingADeadPidResetsItsOwnLook() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"Was"}"#, to: &looks, sequence: 1)
        looks.runStarted(pluginID: "p")
        // The run's own answer names a process that already died: nothing will replace it.
        let changed = looks.apply([try Self.update(#"{"command":"c","subtitle":"On","pid":300}"#)], from: Self.plugin,
                                  installed: { _ in true }, sequence: 2, fromRun: true, identify: { _ in nil })
        #expect(changed && looks.looks.isEmpty)
    }

    @Test func staleListDoesNotEndANewerSession() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"New","pid":200}"#, to: &looks, sequence: 1)
        // A list read the old pid 100, which has since exited; no run is in flight.
        #expect(!(try Self.apply(#"{"command":"c","subtitle":"Old","pid":100}"#, to: &looks, sequence: 2, alive: [Self.new])))
        #expect(looks.looks[Self.entry]?.process == Self.new)
        // The same pid gone ends its look.
        #expect(try Self.apply(#"{"command":"c","subtitle":"New","pid":200}"#, to: &looks, sequence: 3, alive: []))
        #expect(looks.looks.isEmpty)
    }

    @Test func anotherPluginsRunHoldsNothing() throws {
        var looks = PluginLooks()
        _ = try Self.apply(#"{"command":"c","subtitle":"On","pid":100}"#, to: &looks, sequence: 1)
        looks.runStarted(pluginID: "q")
        do { let changed = looks.processExited(Self.old); #expect(changed) }
        #expect(looks.looks.isEmpty)
    }
}
