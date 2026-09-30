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

    /// A cache written before panes were indexed has no `kind`: everything in it is an app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        kind = try c.decodeIfPresent(EntryKind.self, forKey: .kind) ?? .app
    }
}

/// A launchable application, with everything the matcher needs precomputed at index
/// time. Nothing here is derived per keystroke.
public struct AppEntry: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let kind: EntryKind
    /// A link's target when it contains `{query}`, filled from what is typed after Tab.
    public let template: String?

    /// Lowercased characters of `name`, as an array for O(1) indexing.
    public let lowerChars: [Character]
    /// Per-position match bonus: word starts and camelCase humps score higher.
    public let bonus: [Int]
    /// Bitmask of which a-z letters appear, for rejecting non-matches without scanning.
    public let charMask: UInt32
    /// Word-start initials, e.g. "Google Chrome" -> "gc".
    public let initials: [Character]
    /// Index into `lowerChars` of each character in `initials`.
    public let initialIndices: [Int]
    /// Per-initial scoring bonus. Precomputed because the matcher would otherwise
    /// allocate this array for every candidate on every keystroke.
    public let initialBonuses: [Int]

    /// Preference/history identity. Copies of the same app deliberately share aliases,
    /// visibility and frecency even though they remain separate launchable entries.
    public let id: String
    /// Identity of this concrete installation. Unlike `id`, this never merges two copies
    /// of an app that happen to advertise the same bundle identifier.
    public let instanceID: String
    public var cached: CachedApp { CachedApp(path: url.path, name: name, bundleID: bundleID, kind: kind) }

    public init(cached: CachedApp) {
        self.init(url: URL(fileURLWithPath: cached.path), name: cached.name, bundleID: cached.bundleID,
                  kind: cached.kind)
    }

    public init(url: URL, name: String, bundleID: String?, kind: EntryKind = .app, template: String? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.kind = kind
        self.template = template
        // A command or link is identified by its own id, not its target: a link to
        // Safari.app is not the Safari app, and two links may open the same folder.
        switch kind {
        case .command, .link: instanceID = bundleID ?? url.absoluteString
        case .app, .settingsPane: instanceID = url.standardizedFileURL.path
        }
        id = bundleID ?? instanceID

        let chars = Array(name)
        var lower = [Character]()
        var bonuses = [Int]()
        var mask: UInt32 = 0
        var inits = [Character]()
        var initIdx = [Int]()
        lower.reserveCapacity(chars.count)
        bonuses.reserveCapacity(chars.count)

        var atBoundary = true
        var previousWasLowerOrDigit = false

        for (i, ch) in chars.enumerated() {
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
                initIdx.append(i)
            } else if isCamelHump {
                bonuses.append(Scoring.bonusCamel)
                inits.append(lowerCh)
                initIdx.append(i)
            } else {
                bonuses.append(0)
            }

            previousWasLowerOrDigit = ch.isLowercase || ch.isNumber
            atBoundary = false
        }

        self.lowerChars = lower
        self.bonus = bonuses
        self.charMask = mask
        self.initials = inits
        self.initialIndices = initIdx
        self.initialBonuses = Array(repeating: Scoring.bonusBoundary, count: inits.count)
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
    /// "Wi‑Fi". One character for one, so highlight positions still index the name.
    static func typeable(_ ch: Character) -> Character {
        switch ch {
        case "\u{2010}", "\u{2011}", "\u{2012}": return "-"
        default: return ch
        }
    }

    public static func == (a: AppEntry, b: AppEntry) -> Bool { a.instanceID == b.instanceID }
    public func hash(into hasher: inout Hasher) { hasher.combine(instanceID) }
}
