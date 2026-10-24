import Foundation

public struct PluginCommandReference: Sendable, Equatable {
    public let plugin: InstalledPlugin
    public let command: PluginCommand
    public let packageURL: URL
    public var id: String { "plugin:\(plugin.id):\(command.id)" }
    public init(plugin: InstalledPlugin, command: PluginCommand, packageURL: URL? = nil) {
        self.plugin = plugin; self.command = command
        self.packageURL = packageURL ?? plugin.developmentPath.map { URL(fileURLWithPath: $0) }
            ?? PluginStore.defaultRoot.appendingPathComponent("Packages/\(plugin.id)")
    }
}

/// Only static metadata participates in synchronous matching. No Lua process, file
/// access, network request or plugin callback runs on the keystroke path.
public struct PluginCommandIndex: Sendable {
    private let corpus: SearchCorpus
    public let commands: [PluginCommandReference]
    private let byID: [String: PluginCommandReference]

    public init(plugins: [InstalledPlugin], root: URL = PluginStore.defaultRoot) {
        var entries: [AppEntry] = []
        var references: [PluginCommandReference] = []
        var byID: [String: PluginCommandReference] = [:]
        for plugin in plugins where plugin.enabled && plugin.showCommands {
            for command in plugin.manifest.commands {
                let path = plugin.developmentPath.map { URL(fileURLWithPath: $0) }
                    ?? root.appendingPathComponent("Packages/\(plugin.id)")
                let reference = PluginCommandReference(plugin: plugin, command: command, packageURL: path)
                references.append(reference)
                let names = [command.title] + (command.keywords ?? []) + (command.prefix.map { [$0] } ?? [])
                for (i, name) in names.enumerated() {
                    let id = reference.id + ":\(i)"
                    byID[id] = reference
                    entries.append(AppEntry(url: URL(string: "spotlite-plugin:")!, name: name, bundleID: id, kind: .command))
                }
            }
        }
        self.commands = references.sorted { $0.id < $1.id }
        self.byID = byID
        self.corpus = SearchCorpus(entries: entries)
    }

    public func search(_ query: String, matcher: Matcher) -> [PluginCommandReference] {
        guard !query.allSatisfy(\.isWhitespace) else { return [] }
        var seen = Set<String>()
        return matcher.search(query, in: corpus, limit: corpus.entries.count).compactMap { match in
            guard let reference = byID[match.entry.id],
                  seen.insert(reference.id).inserted else { return nil }
            return reference
        }
    }
}
