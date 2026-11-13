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
    case list(args: [String])
    /// Enters a list the executable prints for each query, which follows `args`.
    case search(args: [String], debounce: Int, minimumQuery: Int)
    /// Enters a fixed list. No process is started.
    case menu([PluginItem])

    public static let defaultDebounce = 200
    static let debounceRange = 0...2_000

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
        case type, url, text, args, keepOpen, debounce, minQuery, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        switch type {
        case "open": self = .open(try c.decode(String.self, forKey: .url))
        case "copy": self = .copy(try c.decode(String.self, forKey: .text))
        case "run": self = .run(args: args, keepOpen: try c.decodeIfPresent(Bool.self, forKey: .keepOpen) ?? false)
        case "list": self = .list(args: args)
        case "search":
            let debounce = try c.decodeIfPresent(Int.self, forKey: .debounce) ?? PluginAction.defaultDebounce
            let range = PluginAction.debounceRange
            self = .search(args: args,
                           debounce: min(max(debounce, range.lowerBound), range.upperBound),
                           minimumQuery: max(0, try c.decodeIfPresent(Int.self, forKey: .minQuery) ?? 1))
        case "menu":
            self = .menu(PluginItem.decodeList(from: c, forKey: .items))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown action type \(type)")
        }
    }
}

/// One row a plugin shows. Without an action the row is informational.
public struct PluginItem: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// An SF Symbol name, an image file, or any other file whose Finder icon to show.
    public let icon: String?
    public let action: PluginAction?

    /// A response larger than this is cut off: nobody scrolls further, and each row
    /// costs matching metadata.
    public static let maxItems = 500

    private enum CodingKeys: String, CodingKey { case id, title, subtitle, icon, action }

    public init(id: String? = nil, title: String, subtitle: String? = nil, icon: String? = nil,
                action: PluginAction? = nil) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id), title: title,
                  subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                  icon: try c.decodeIfPresent(String.self, forKey: .icon),
                  action: try c.decodeIfPresent(PluginAction.self, forKey: .action))
    }

    /// Per element, so one malformed row does not empty the list.
    static func decodeList<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [PluginItem] {
        let decoded = (try? container.decodeIfPresent([Lossy<PluginItem>].self, forKey: key)) ?? []
        return Array(decoded.lazy.compactMap(\.value).prefix(maxItems))
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

    public static let defaultTimeout: TimeInterval = 10
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, executable, timeout, commands
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
    case items([PluginItem])
    case list(args: [String])
    case search(args: [String], debounce: Int, minimumQuery: Int)

    public init?(_ action: PluginAction) {
        switch action {
        case .menu(let items): self = .items(items)
        case .list(let args): self = .list(args: args)
        case .search(let args, let debounce, let minimumQuery):
            self = .search(args: args, debounce: debounce, minimumQuery: minimumQuery)
        case .open, .copy, .run: return nil
        }
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

    public init(pluginID: String, title: String, icon: String?, source: PluginSource) {
        self.pluginID = pluginID
        self.title = title
        self.icon = icon
        self.source = source
    }
}

/// A plugin level's rows with their matching metadata, prepared once per load.
public struct PluginList: Sendable {
    public let items: [PluginItem]
    private let corpus: SearchCorpus

    public static let empty = PluginList(items: [])

    public init(items: [PluginItem]) {
        self.items = items
        // The position stands in for an id: a plugin's own ids need not be unique.
        corpus = SearchCorpus(entries: items.enumerated().map { index, item in
            AppEntry(url: PluginList.entryURL, name: item.title, bundleID: String(index), kind: .command)
        })
    }

    private static let entryURL = URL(string: "spotlite-plugin-item:")!

    public func search(_ query: String, matcher: Matcher) -> [PluginItem] {
        if query.allSatisfy(\.isWhitespace) { return items }
        return matcher.search(query, in: corpus, limit: items.count).compactMap {
            Int($0.entry.id).map { items[$0] }
        }
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
