import Darwin
import Foundation

/// A running process, told apart from a later one that reuses its pid by its start time.
public struct ProcessIdentity: Sendable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    /// The process now running as `pid`, when it belongs to this user and has not
    /// exited. Nil for a process that is gone, a zombie, or another user's.
    public static func of(_ pid: Int32) -> ProcessIdentity? {
        // Spotlite's own pid would make Stop end Spotlite, and its exit is never seen.
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    /// Whether this exact process still runs: same pid, same start time.
    public var isRunning: Bool { ProcessIdentity.of(pid) == self }
}

/// The looks plugins gave their commands at run time, by entry id. Kept in memory only:
/// a plugin reports its state again the next time it runs.
///
/// Runs finish in any order, so each update carries the sequence number of the run that
/// made it, taken when the run started. An update older than the one already applied
/// for its command is dropped: a slow list that read the state before a newer action
/// changed it cannot bring the old state back.
///
/// A `run` can restart what a look describes: it ends the old process before it reports
/// the new one. An exit that arrives while a `run` of the look's plugin is in flight is
/// held until that run ends, so the look is replaced rather than removed and drawn again.
public struct PluginLooks: Sendable {
    public struct Look: Sendable, Equatable {
        public let update: PluginCommandUpdate
        public let pluginID: String
        public let pluginName: String
        public let directory: URL
        public let commandTitle: String
        /// The process the look describes, checked when the update arrived.
        public let process: ProcessIdentity?

        public init(update: PluginCommandUpdate, pluginID: String, pluginName: String, directory: URL,
                    commandTitle: String, process: ProcessIdentity? = nil) {
            self.update = update
            self.pluginID = pluginID
            self.pluginName = pluginName
            self.directory = directory
            self.commandTitle = commandTitle
            self.process = process
        }
    }

    public private(set) var looks: [String: Look] = [:]
    /// The newest run applied per entry, kept after a reset so an older run cannot undo it.
    private var sequences: [String: UInt64] = [:]
    /// `run` actions in flight per plugin.
    private var runsInFlight: [String: Int] = [:]
    /// Processes that exited while a `run` of a plugin whose look names them was in flight.
    private var heldExits: Set<ProcessIdentity> = []

    public init() {}

    /// Applies a run's updates from `plugin`. `installed` is false once the plugin or the
    /// command is gone: a late answer then keeps a look only for a process still running.
    /// `identify` checks a reported pid, `ProcessIdentity.of` outside tests. `fromRun` is
    /// true for a counted `run`'s own answer, which is not one to wait for. Returns
    /// whether any look changed.
    @discardableResult
    public mutating func apply(_ changes: [PluginCommandUpdate], from plugin: InstalledPlugin,
                               installed: (String) -> Bool, sequence: UInt64, fromRun: Bool = false,
                               identify: (Int32) -> ProcessIdentity? = ProcessIdentity.of) -> Bool {
        guard let declared = plugin.manifest?.commands, !declared.isEmpty else { return false }
        let titles = Dictionary(declared.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for change in changes {
            guard let title = titles[change.command] else { continue }
            let entryID = plugin.entryID(forCommandID: change.command)
            var look: Look?
            if !change.isReset {
                let process = change.pid.flatMap(identify)
                if let pid = change.pid, process == nil {
                    // The process is gone, so the state it stood for is over. During
                    // another run, though, it may be a restart reported late by a slower
                    // list: that run will say what replaced it.
                    if runsInFlight[plugin.id, default: 0] - (fromRun ? 1 : 0) > 0 { continue }
                    // Only the look of that process ends; a newer session's stays.
                    if let current = looks[entryID]?.process, current.pid != pid { continue }
                } else if installed(entryID) || process != nil {
                    look = Look(update: change, pluginID: plugin.id, pluginName: plugin.name,
                                directory: plugin.directory, commandTitle: title, process: process)
                } else {
                    continue
                }
            }
            changed = apply(look, entryID: entryID, sequence: sequence) || changed
        }
        return changed
    }

    /// Applies `look`, or resets the entry when its update is a reset. Returns whether
    /// the entry changed: false when a newer run already spoke for it, or when the look
    /// is the one it had.
    @discardableResult
    mutating func apply(_ look: Look?, entryID: String, sequence: UInt64) -> Bool {
        if let applied = sequences[entryID], applied > sequence { return false }
        sequences[entryID] = sequence
        let new = look.flatMap { $0.update.isReset ? nil : $0 }
        guard looks[entryID] != new else { return false }
        looks[entryID] = new
        return true
    }

    /// The entry's look, unless it has expired.
    public func look(for entryID: String, at now: Date) -> Look? {
        guard let look = looks[entryID], !look.update.hasExpired(at: now) else { return nil }
        return look
    }

    /// Drops every look past its deadline. Returns whether any went.
    @discardableResult
    public mutating func removeExpired(at now: Date) -> Bool {
        let before = looks.count
        looks = looks.filter { !$0.value.update.hasExpired(at: now) }
        return looks.count != before
    }

    /// Drops every look of a process that exited. Returns whether any went.
    @discardableResult
    mutating func removeLooks(of process: ProcessIdentity) -> Bool {
        heldExits.remove(process)
        let before = looks.count
        looks = looks.filter { $0.value.process != process }
        return looks.count != before
    }

    // MARK: - Runs and exits

    public mutating func runStarted(pluginID: String) {
        runsInFlight[pluginID, default: 0] += 1
    }

    /// A `run` reported or was cancelled. Exits it held clear the looks that still name
    /// those processes, which a new session's look no longer does. Returns whether any
    /// look went.
    @discardableResult
    public mutating func runEnded(pluginID: String) -> Bool {
        let remaining = runsInFlight[pluginID, default: 1] - 1
        runsInFlight[pluginID] = remaining > 0 ? remaining : nil
        var changed = false
        for process in heldExits where !isHeld(process) {
            changed = removeLooks(of: process) || changed
        }
        return changed
    }

    /// A process exited. Its looks go now, or when the `run` in flight for their plugin
    /// ends. Returns whether any look went now.
    @discardableResult
    public mutating func processExited(_ process: ProcessIdentity) -> Bool {
        if isHeld(process) {
            heldExits.insert(process)
            return false
        }
        return removeLooks(of: process)
    }

    private func isHeld(_ process: ProcessIdentity) -> Bool {
        looks.values.contains { $0.process == process && runsInFlight[$0.pluginID, default: 0] > 0 }
    }

    /// The earliest deadline among looks shown in the menu bar, which nothing redraws
    /// on its own. A root row checks its deadline when drawn.
    public var nextMenuBarDeadline: TimeInterval? {
        looks.values.lazy.filter { $0.update.menuBar != nil }.compactMap(\.update.expires).min()
    }

    /// The processes to watch: those some look describes, less those already exited.
    public var processes: Set<ProcessIdentity> {
        Set(looks.values.compactMap(\.process)).subtracting(heldExits)
    }
}

extension PluginLooks {
    /// After plugins are read again: keeps the looks of commands that still exist, and
    /// those `keepOrphan` accepts, such as one whose process still runs. Returns whether
    /// any look went.
    @discardableResult
    public mutating func retain(commands keepCommand: (String) -> Bool, orphans keepOrphan: (Look) -> Bool) -> Bool {
        let before = looks.count
        looks = looks.filter { keepCommand($0.key) || keepOrphan($0.value) }
        sequences = sequences.filter { keepCommand($0.key) || looks[$0.key] != nil }
        return looks.count != before
    }
}
