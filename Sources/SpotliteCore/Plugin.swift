import Foundation

/// What Return does on a plugin's command or item. Everything a plugin can make
/// Spotlite do is one of these, so a command and a row share one vocabulary.
///
/// `open`, `copy` and `menu` are answered in-process: only `run`, `list` and `search`
/// start the plugin's executable.
public enum PluginAction: Sendable, Equatable {
    /// Opens a web address, a file path or any URL an app handles.
    case open(String)
    case copy(String)
    /// Runs the executable with `args` and applies its response. With `keepOpen` the
    /// panel stays and the current list reloads; otherwise it closes first.
    case run(args: [String], keepOpen: Bool)
    /// Enters a list the executable prints once; Spotlite filters it as the user types.
    case list(args: [String], options: PluginListOptions = .init())
    /// Enters a list the executable prints for each query, which follows `args`.
    case search(args: [String], debounce: Int, minimumQuery: Int, options: PluginListOptions = .init())
    /// Enters a fixed list. No process is started.
    case menu([PluginItem], options: PluginListOptions = .init())

    public static let defaultDebounce = 200
    static let debounceRange = 0...2_000

    /// The `type` names an action may have.
    public enum Kind: String, CaseIterable, Sendable { case open, copy, run, list, search, menu }

    /// The action's `type`.
    public var kind: Kind {
        switch self {
        case .open: .open
        case .copy: .copy
        case .run: .run
        case .list: .list
        case .search: .search
        case .menu: .menu
        }
    }

    /// Whether the action opens another level rather than finishing.
    public var entersScope: Bool {
        switch self {
        case .list, .search, .menu: true
        case .open, .copy, .run: false
        }
    }

    /// The address an `open` target names: a path, or anything with a scheme.
    public static func url(for target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }
}

extension PluginAction: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, url, text, args, keepOpen, debounce, minQuery, items, sort, emptyText
        case stream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown action type \(type)")
        }
        let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        let emptyText = try c.decodeIfPresent(String.self, forKey: .emptyText)
        // Read only where Spotlite filters: a search's rows already answer the query.
        let filtered = PluginListOptions(sorts: try c.decodeIfPresent(Bool.self, forKey: .sort) ?? true,
                                         emptyText: emptyText)
        // Only an executable's output can stream; a menu's rows are already here.
        let streams = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        switch kind {
        case .open: self = .open(try c.decode(String.self, forKey: .url))
        case .copy: self = .copy(try c.decode(String.self, forKey: .text))
        case .run: self = .run(args: args, keepOpen: try c.decodeIfPresent(Bool.self, forKey: .keepOpen) ?? false)
        case .list: self = .list(args: args, options: filtered.streaming(streams))
        case .search:
            let debounce = try c.decodeIfPresent(Int.self, forKey: .debounce) ?? PluginAction.defaultDebounce
            let range = PluginAction.debounceRange
            self = .search(args: args,
                           debounce: min(max(debounce, range.lowerBound), range.upperBound),
                           minimumQuery: max(0, try c.decodeIfPresent(Int.self, forKey: .minQuery) ?? 1),
                           options: PluginListOptions(emptyText: emptyText, streams: streams))
        case .menu:
            self = .menu(PluginItem.decodeList(from: c, forKey: .items), options: filtered)
        }
    }
}

/// How a `list`, `search` or `menu` level presents its rows.
public struct PluginListOptions: Sendable, Equatable {
    /// Whether typing ranks matches by score. Off, matches keep the plugin's order.
    public var sorts: Bool
    /// Shown when the level has no rows; nil for the default.
    public var emptyText: String?
    /// Whether the executable prints one row per line, shown as each arrives.
    public var streams: Bool

    /// Blank text counts as none, so the default still shows.
    public init(sorts: Bool = true, emptyText: String? = nil, streams: Bool = false) {
        self.sorts = sorts
        self.emptyText = emptyText.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        self.streams = streams
    }

    func streaming(_ streams: Bool) -> PluginListOptions {
        var options = self
        options.streams = streams
        return options
    }
}

/// One row a plugin shows. Without an action the row is informational.
public struct PluginItem: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Short text at the right of every row, selected or not: a count, a date, stars.
    public let accessory: String?
    /// More names that find the row. A title match still ranks above a keyword-only one.
    public let keywords: [String]
    /// An SF Symbol name, an image file, or any other file whose Finder icon to show.
    public let icon: String?
    public let action: PluginAction?
    /// Asks before `action` runs.
    public let confirm: PluginConfirmation?
    /// Other things the row can do, by a modifier with Return or from the action list.
    public let actions: [PluginSecondaryAction]

    /// A response larger than this is cut off: nobody scrolls further, and each row
    /// costs matching metadata.
    public static let maxItems = 500
    /// Each keyword is matched like a title, so a row's are capped as its count is.
    public static let maxKeywords = 8

    private enum CodingKeys: String, CodingKey { case id, title, subtitle, accessory, keywords, icon, action, actions }

    public init(id: String? = nil, title: String, subtitle: String? = nil, accessory: String? = nil,
                keywords: [String] = [], icon: String? = nil, action: PluginAction? = nil,
                confirm: PluginConfirmation? = nil, actions: [PluginSecondaryAction] = []) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        self.keywords = Array(keywords.lazy.filter { !$0.allSatisfy(\.isWhitespace) }.prefix(PluginItem.maxKeywords))
        self.icon = icon
        self.action = action
        self.confirm = action == nil ? nil : confirm
        self.actions = Array(actions.prefix(PluginSecondaryAction.maxCount))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title)
        // A malformed `confirm` drops the row: running it unasked is worse than not at all.
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id), title: title,
                  subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                  accessory: try c.decodeIfPresent(String.self, forKey: .accessory),
                  keywords: try c.decodeIfPresent([String].self, forKey: .keywords) ?? [],
                  icon: try c.decodeIfPresent(String.self, forKey: .icon),
                  action: try c.decodeIfPresent(PluginAction.self, forKey: .action),
                  confirm: try c.decodeIfPresent(PluginConfirmKey.self, forKey: .action)?.confirm,
                  actions: PluginSecondaryAction.decodeList(from: c, forKey: .actions))
    }

    /// Per element, so one malformed row does not empty the list.
    static func decodeList<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [PluginItem] {
        guard var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var items: [PluginItem] = []
        items.reserveCapacity(min(list.count ?? maxItems, maxItems))
        // Stop constructing rows once the visible limit is reached. A large response
        // need not allocate and decode thousands of actions that will be discarded.
        while !list.isAtEnd, items.count < maxItems {
            guard let decoded = try? list.decode(Lossy<PluginItem>.self) else { break }
            if let item = decoded.value { items.append(item) }
        }
        return items
    }
}

/// A root search entry a plugin contributes. It ranks, hides, takes an alias and learns
/// launch history like any other entry.
public struct PluginCommand: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    /// A short name that finds the command, used until the user sets their own alias.
    public let keyword: String?
    public let subtitle: String?
    public let icon: String?
    public let action: PluginAction
    /// Asks before `action` runs.
    public let confirm: PluginConfirmation?
    /// Other things the command does, by a modifier with Return or from the action list.
    public let actions: [PluginSecondaryAction]

    private enum CodingKeys: String, CodingKey { case id, title, keyword, subtitle, icon, action, actions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        action = try c.decode(PluginAction.self, forKey: .action)
        confirm = try c.decode(PluginConfirmKey.self, forKey: .action).confirm
        actions = PluginSecondaryAction.decodeList(from: c, forKey: .actions)
    }
}

/// `plugin.json` at the root of a plugin's folder.
public struct PluginManifest: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let author: String?
    /// Path of the program inside the plugin's folder. Not needed by a plugin whose
    /// actions are all `open`, `copy` or `menu`.
    public let executable: String?
    /// Seconds a run may take before it is stopped.
    public let timeout: TimeInterval
    public let commands: [PluginCommand]
    public let settings: [PluginSetting]

    public static let defaultTimeout: TimeInterval = 10
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, executable, timeout, commands, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        let seconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? PluginManifest.defaultTimeout
        let range = PluginManifest.timeoutRange
        timeout = seconds.isFinite ? min(max(seconds, range.lowerBound), range.upperBound)
            : PluginManifest.defaultTimeout
        commands = try c.decode([PluginCommand].self, forKey: .commands)
        settings = try c.decodeIfPresent([PluginSetting].self, forKey: .settings) ?? []
        guard settings.count <= 64, Set(settings.map(\.id)).count == settings.count else {
            throw DecodingError.dataCorruptedError(forKey: .settings, in: c,
                debugDescription: "Settings must have unique ids, with at most 64 fields.")
        }
    }

    /// Ids name folders and key preferences, so they stay plain.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id != "." && id != ".."
            && id.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }
}

/// A message shown after a run: a bare string, or text with a symbol and a style.
public struct PluginToast: Sendable, Equatable, Decodable {
    public let text: String
    public let symbol: String?
    /// A failure is shown even when confirmation messages are switched off.
    public let isFailure: Bool

    private enum CodingKeys: String, CodingKey { case text, symbol, style }

    public init(text: String, symbol: String? = nil, isFailure: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.isFailure = isFailure
    }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text),
                  symbol: try c.decodeIfPresent(String.self, forKey: .symbol),
                  isFailure: try c.decodeIfPresent(String.self, forKey: .style) == "failure")
    }
}

/// Changes how one of the plugin's commands looks in root results, until `expires` or
/// the next update. An update naming only the command restores the manifest's look.
public struct PluginCommandUpdate: Sendable, Equatable, Decodable {
    public let command: String
    public let icon: String?
    public let subtitle: String?
    /// Seconds since 1970. Checked when the row is drawn, so nothing is scheduled.
    public let expires: TimeInterval?

    public var isReset: Bool { icon == nil && subtitle == nil }

    public func hasExpired(at now: Date) -> Bool {
        expires.map { now.timeIntervalSince1970 >= $0 } ?? false
    }
}

/// What the executable prints: one JSON object, every key optional. Nothing printed is
/// an empty response.
public struct PluginResponse: Sendable, Equatable, Decodable {
    public var items: [PluginItem]?
    public var toast: PluginToast?
    public var copy: String?
    public var open: String?
    public var update: [PluginCommandUpdate]

    private enum CodingKeys: String, CodingKey { case items, toast, copy, open, update }

    public init() { update = [] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.contains(.items) ? PluginItem.decodeList(from: c, forKey: .items) : nil
        toast = try? c.decodeIfPresent(PluginToast.self, forKey: .toast)
        copy = try? c.decodeIfPresent(String.self, forKey: .copy)
        open = try? c.decodeIfPresent(String.self, forKey: .open)
        update = ((try? c.decodeIfPresent([Lossy<PluginCommandUpdate>].self, forKey: .update)) ?? [])
            .compactMap(\.value)
    }

    public static func decode(_ data: Data) throws -> PluginResponse {
        // Whitespace only, as from a script that prints nothing but a newline.
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return PluginResponse() }
        return try JSONDecoder().decode(PluginResponse.self, from: data)
    }
}

/// Where a plugin level's rows come from.
public enum PluginSource: Sendable, Equatable {
    case items([PluginItem], options: PluginListOptions = .init())
    case list(args: [String], options: PluginListOptions = .init())
    case search(args: [String], debounce: Int, minimumQuery: Int, options: PluginListOptions = .init())

    public init?(_ action: PluginAction) {
        switch action {
        case .menu(let items, let options): self = .items(items, options: options)
        case .list(let args, let options): self = .list(args: args, options: options)
        case .search(let args, let debounce, let minimumQuery, let options):
            self = .search(args: args, debounce: debounce, minimumQuery: minimumQuery, options: options)
        case .open, .copy, .run: return nil
        }
    }

    public var options: PluginListOptions {
        switch self {
        case .items(_, let options), .list(_, let options), .search(_, _, _, let options): options
        }
    }

    /// What Spotlite says when nothing came back or typing filtered every row out.
    public static let defaultEmptyText = "No results"

    /// The text standing in for a level with no rows, or nil to show nothing.
    ///
    /// `loaded` says whether rows have arrived for what is on screen; until they do, an
    /// empty level is still waiting, not empty. A search shorter than its minimum has
    /// nothing to wait for and shows only the plugin's own text: an empty bar is what an
    /// empty root query shows too.
    public func emptyText(query: String, loaded: Bool) -> String? {
        if case .search(_, _, let minimum, let options) = self,
           query.trimmingCharacters(in: .whitespaces).count < minimum {
            return options.emptyText
        }
        return loaded ? options.emptyText ?? PluginSource.defaultEmptyText : nil
    }

    /// A search's rows answer the query already; the others are filtered by Spotlite.
    public var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}

/// A level entered from a plugin command or item, named by the chip before the query.
public struct PluginScope: Sendable, Equatable {
    public let pluginID: String
    public let title: String
    public let icon: String?
    public let source: PluginSource
    /// The manifest command this level descends from, passed as `SPOTLITE_COMMAND`.
    public let commandID: String

    public init(pluginID: String, title: String, icon: String?, source: PluginSource, commandID: String = "") {
        self.pluginID = pluginID
        self.title = title
        self.icon = icon
        self.source = source
        self.commandID = commandID
    }
}

/// A plugin level's rows, with matching metadata prepared only for local filtering.
public struct PluginList: Sendable {
    public let items: [PluginItem]
    private let corpus: SearchCorpus?
    /// One entry per keyword, named by its row's position; nil when no row has one, so a
    /// list without keywords matches exactly as before.
    private let keywordCorpus: SearchCorpus?
    private let sorts: Bool
    private let occurrences: [Int]

    public static let empty = PluginList(items: [])

    public init(items: [PluginItem], filterLocally: Bool = true, sorts: Bool = true) {
        self.init(items: items, after: nil, filterLocally: filterLocally, sorts: sorts)
    }

    /// The same list with more rows after its own, as a stream delivers them: `items`
    /// begins with this list's rows, and only the rows after them are prepared.
    public func appending(_ items: [PluginItem]) -> PluginList {
        PluginList(items: items, after: self, filterLocally: corpus != nil, sorts: sorts)
    }

    private init(items: [PluginItem], after previous: PluginList?, filterLocally: Bool, sorts: Bool) {
        self.items = items
        self.sorts = sorts
        let start = previous.map { min($0.items.count, items.count) } ?? 0
        var counts: [String: Int] = [:]
        for index in 0..<start { counts[items[index].id, default: 0] += 1 }
        occurrences = Array((previous?.occurrences ?? []).prefix(start)) + items[start...].map {
            let occurrence = counts[$0.id, default: 0]
            counts[$0.id] = occurrence + 1
            return occurrence
        }
        guard filterLocally else { corpus = nil; keywordCorpus = nil; return }
        // The position stands in for an id: a plugin's own ids need not be unique.
        let titles = items[start...].enumerated().map { offset, item in
            AppEntry(url: PluginList.entryURL, name: item.title, bundleID: String(start + offset), kind: .command)
        }
        let keywords = items[start...].enumerated().flatMap { offset, item in
            item.keywords.map { AppEntry(url: PluginList.entryURL, name: $0, bundleID: String(start + offset), kind: .command) }
        }
        let earlierTitles = Array((previous?.corpus?.entries ?? []).prefix(start))
        // Keywords are in row order, so the earlier rows' are those naming a row before `start`.
        let earlierKeywords = (previous?.keywordCorpus?.entries ?? []).filter { Int($0.bundleID ?? "").map { $0 < start } ?? false }
        corpus = SearchCorpus(entries: earlierTitles + titles)
        let allKeywords = earlierKeywords + keywords
        keywordCorpus = allKeywords.isEmpty ? nil : SearchCorpus(entries: allKeywords)
    }

    private static let entryURL = URL(string: "spotlite-plugin-item:")!

    /// Original list positions survive filtering; ids and titles need not be unique.
    ///
    /// Title matches rank first and keyword-only matches follow, each by score. Without
    /// sorting, the same matches keep the plugin's order.
    public func matchingIndices(_ query: String, matcher: Matcher) -> [Int] {
        // Remote search rows already answer the query and retain the plugin's order.
        guard !items.isEmpty, let corpus, !query.allSatisfy(\.isWhitespace) else { return Array(items.indices) }
        if !sorts {
            var matched = [Bool](repeating: false, count: items.count)
            for match in matcher.matches(query, in: corpus) { Int(match.entry.id).map { matched[$0] = true } }
            if let keywordCorpus {
                for match in matcher.matches(query, in: keywordCorpus) { Int(match.entry.id).map { matched[$0] = true } }
            }
            return items.indices.filter { matched[$0] }
        }
        var ranked = matcher.search(query, in: corpus, limit: items.count).compactMap { Int($0.entry.id) }
        guard let keywordCorpus else { return ranked }
        var seen = [Bool](repeating: false, count: items.count)
        for index in ranked { seen[index] = true }
        // A row with several matching keywords appears once, at its best.
        for match in matcher.search(query, in: keywordCorpus, limit: keywordCorpus.entries.count) {
            guard let index = Int(match.entry.id), !seen[index] else { continue }
            seen[index] = true
            ranked.append(index)
        }
        return ranked
    }

    public func occurrence(at index: Int) -> Int {
        occurrences[index]
    }
}

/// How a plugin's `icon` string is drawn.
public enum PluginIcon: Sendable, Equatable {
    case symbol(String)
    /// An image to draw, or any other file whose Finder icon to show.
    case file(URL)

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "pdf", "icns", "svg"]

    /// A string with a slash or an image extension is a path, relative to the plugin's
    /// folder unless absolute. Anything else names an SF Symbol, which may contain dots.
    public init(_ raw: String, directory: URL) {
        let isPath = raw.contains("/")
            || PluginIcon.imageExtensions.contains((raw as NSString).pathExtension.lowercased())
        guard isPath else {
            self = .symbol(raw)
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        self = .file(expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : directory.appendingPathComponent(expanded))
    }
}
