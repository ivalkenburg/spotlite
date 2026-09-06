import Foundation

/// The persisted shape of an indexed app. Only these three fields are cached; every
/// derived field is recomputed on load, so the cache format can't go stale in a way
/// that silently corrupts matching.
public struct CachedApp: Codable, Sendable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String?

    public init(path: String, name: String, bundleID: String?) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
    }
}

/// A launchable application, with everything the matcher needs precomputed at index
/// time. Nothing here is derived per keystroke.
public struct AppEntry: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String?

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

    public var id: String { bundleID ?? url.path }
    public var cached: CachedApp { CachedApp(path: url.path, name: name, bundleID: bundleID) }

    public init(cached: CachedApp) {
        self.init(url: URL(fileURLWithPath: cached.path), name: cached.name, bundleID: cached.bundleID)
    }

    public init(url: URL, name: String, bundleID: String?) {
        self.url = url
        self.name = name
        self.bundleID = bundleID

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
            let lowerCh = ch.lowercased().first ?? ch
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

    static func isSeparator(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "." || ch == "/" || ch == "("
    }

    public static func == (a: AppEntry, b: AppEntry) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
