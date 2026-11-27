import Foundation

/// What an entry opens. Everything else shares the matcher and every per-app preference
/// with apps: hiding, aliases and launch history.
public enum EntryKind: UInt8, Codable, Sendable {
    case app
    /// A System Settings pane. Opens through a URL and ranks below an app.
    case settingsPane
    /// A built-in action such as Lock Screen, run by Spotlite itself. Ranks like a pane.
    case command
    /// A folder, file or web address the user added in Settings. Ranks like an app: the
    /// user created it to be found.
    case link
    /// A command an installed plugin contributes. Ranks like an app: the user
    /// installed it to be found.
    case plugin
}

/// The persisted shape of an indexed app. Only these fields are cached; every derived
/// field is recomputed on load, so the cache format can't go stale in a way that
/// silently corrupts matching.
public struct CachedApp: Codable, Sendable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let kind: EntryKind

    public init(path: String, name: String, bundleID: String?, kind: EntryKind = .app) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.kind = kind
    }
}

/// A launchable application, with everything the matcher needs precomputed at index
/// time. Nothing here is derived per keystroke.
///
/// The fields live in one immutable box: a match, a ranked row and a result item each
/// copy the entry, and a struct of a dozen strings and arrays cost a retain per field
/// on every copy, several times per keystroke.
public struct AppEntry: Sendable, Hashable {
    private final class Storage: Sendable {
        let url: URL
        let name: String
        let bundleID: String?
        let kind: EntryKind
        let template: String?
        let lowerChars: [Character]
        let bonus: [Int]
        let charMask: UInt32
        let initials: [Character]
        let initialBonuses: [Int]
        let id: String
        let instanceID: String

        init(url: URL, name: String, bundleID: String?, kind: EntryKind, template: String?,
             lowerChars: [Character], bonus: [Int], charMask: UInt32, initials: [Character],
             id: String, instanceID: String) {
            self.url = url
            self.name = name
            self.bundleID = bundleID
            self.kind = kind
            self.template = template
            self.lowerChars = lowerChars
            self.bonus = bonus
            self.charMask = charMask
            self.initials = initials
            self.initialBonuses = Array(repeating: Scoring.bonusBoundary, count: initials.count)
            self.id = id
            self.instanceID = instanceID
        }
    }

    private let storage: Storage

    public var url: URL { storage.url }
    public var name: String { storage.name }
    public var bundleID: String? { storage.bundleID }
    public var kind: EntryKind { storage.kind }
    /// A link's target when it contains `{query}`, filled from what is typed after Tab.
    public var template: String? { storage.template }

    /// Lowercased characters of `name`, as an array for O(1) indexing.
    public var lowerChars: [Character] { storage.lowerChars }
    /// Per-position match bonus: word starts and camelCase humps score higher.
    public var bonus: [Int] { storage.bonus }
    /// Bitmask of which a-z letters appear, for rejecting non-matches without scanning.
    public var charMask: UInt32 { storage.charMask }
    /// Word-start initials, e.g. "Google Chrome" -> "gc".
    public var initials: [Character] { storage.initials }
    /// Per-initial scoring bonus. Precomputed because the matcher would otherwise
    /// allocate this array for every candidate on every keystroke.
    public var initialBonuses: [Int] { storage.initialBonuses }

    /// Preference/history identity. Copies of the same app deliberately share aliases,
    /// visibility and frecency even though they remain separate launchable entries.
    public var id: String { storage.id }
    /// Identity of this concrete installation. Unlike `id`, this never merges two copies
    /// of an app that happen to advertise the same bundle identifier.
    public var instanceID: String { storage.instanceID }
    public var cached: CachedApp { CachedApp(path: url.path, name: name, bundleID: bundleID, kind: kind) }

    /// Only bundles are cached, so the URL is marked a directory instead of asking the
    /// file system once per entry while the index loads.
    public init(cached: CachedApp) {
        self.init(url: URL(fileURLWithPath: cached.path, isDirectory: true), name: cached.name,
                  bundleID: cached.bundleID, kind: cached.kind)
    }

    /// `url.standardizedFileURL.path` without building that URL, which consults the file
    /// system: about a tenth of the cost, for every entry indexed and every running app.
    public static func standardizedPath(_ url: URL) -> String {
        (url.path as NSString).standardizingPath
    }

    public init(url: URL, name: String, bundleID: String?, kind: EntryKind = .app, template: String? = nil) {
        // A command or link is identified by its own id, not its target: a link to
        // Safari.app is not the Safari app, and two links may open the same folder.
        let instanceID: String
        switch kind {
        case .command, .link, .plugin: instanceID = bundleID ?? url.absoluteString
        case .app, .settingsPane: instanceID = AppEntry.standardizedPath(url)
        }

        let chars: [Character]
        if kind == .plugin {
            // Plugin text comes from arbitrary output. Bound preparation before
            // allocating scoring arrays, including a single enormous grapheme.
            let prefix = name.utf8.count <= Matcher.maxSupportedText * 4
                ? Array(name.prefix(Matcher.maxSupportedText + 1)) : []
            chars = prefix.count <= Matcher.maxSupportedText ? prefix : []
        } else {
            chars = Array(name)
        }
        var lower = [Character]()
        var bonuses = [Int]()
        var mask: UInt32 = 0
        var inits = [Character]()
        lower.reserveCapacity(chars.count)
        bonuses.reserveCapacity(chars.count)

        var atBoundary = true
        var previousWasLowerOrDigit = false

        for ch in chars {
            // `Character(ch.lowercased())` traps when a scalar lowercases to more than
            // one grapheme; taking the first keeps a hostile app name from killing the index.
            let lowerCh = AppEntry.typeable(ch.lowercased().first ?? ch)
            lower.append(lowerCh)

            if let ascii = lowerCh.asciiValue, ascii >= 97, ascii <= 122 {
                mask |= (1 << UInt32(ascii - 97))
            }

            if AppEntry.isSeparator(ch) {
                bonuses.append(0)
                atBoundary = true
                previousWasLowerOrDigit = false
                continue
            }

            let isCamelHump = ch.isUppercase && previousWasLowerOrDigit
            if atBoundary {
                bonuses.append(Scoring.bonusBoundary)
                inits.append(lowerCh)
            } else if isCamelHump {
                bonuses.append(Scoring.bonusCamel)
                inits.append(lowerCh)
            } else {
                bonuses.append(0)
            }

            previousWasLowerOrDigit = ch.isLowercase || ch.isNumber
            atBoundary = false
        }

        storage = Storage(url: url, name: name, bundleID: bundleID, kind: kind, template: template,
                          lowerChars: lower, bonus: bonuses, charMask: mask, initials: inits,
                          id: bundleID ?? instanceID, instanceID: instanceID)
    }

    /// Deterministic order between equally scored entries: shorter name first, then
    /// alphabetical, then path. `lowerChars.count` is O(1); `name.count` would walk the
    /// string on every comparison.
    func tieBreaksBefore(_ other: AppEntry) -> Bool {
        if lowerChars.count != other.lowerChars.count { return lowerChars.count < other.lowerChars.count }
        if name != other.name { return name < other.name }
        return instanceID < other.instanceID
    }

    /// U+2011 is the non-breaking hyphen System Settings writes in "Wi‑Fi".
    static func isSeparator(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "." || ch == "/" || ch == "("
            || ch == "\u{2010}" || ch == "\u{2011}" || ch == "\u{2012}"
    }

    /// The Unicode hyphens (U+2010-2012) match the "-" a keyboard types, so "wi-fi" finds
    /// "Wi‑Fi". One character for one, so `lowerChars` stays parallel to the name.
    static func typeable(_ ch: Character) -> Character {
        switch ch {
        case "\u{2010}", "\u{2011}", "\u{2012}": return "-"
        default: return ch
        }
    }

    public static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.storage === b.storage || a.instanceID == b.instanceID
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(instanceID) }
}
