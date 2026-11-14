import Foundation

/// Modifiers held with Return to pick one of a row's other actions.
public struct PluginShortcut: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = PluginShortcut(rawValue: 1)
    public static let option = PluginShortcut(rawValue: 2)
    public static let shift = PluginShortcut(rawValue: 4)
    public static let command = PluginShortcut(rawValue: 8)

    /// `cmd`, `opt`, `shift` or `ctrl`, or several joined by `+`, such as `cmd+shift`.
    /// Anything else is nil, so a typo never binds a different chord.
    public init?(_ string: String) {
        var shortcut: PluginShortcut = []
        for part in string.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            guard let modifier = PluginShortcut.names[part.trimmingCharacters(in: .whitespaces)] else { return nil }
            shortcut.insert(modifier)
        }
        guard !shortcut.isEmpty else { return nil }
        self = shortcut
    }

    /// Every name a part of a shortcut may have, aliases included.
    public static let names: [String: PluginShortcut] = [
        "cmd": .command, "command": .command, "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "ctrl": .control, "control": .control,
    ]

    /// The modifier glyphs in the order macOS menus draw them, then Return: `⌥⇧↩`.
    public var keyText: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text + "↩"
    }
}

/// Asks before an action runs. A bare string is the question; an object can add a
/// message, name the button and mark the action destructive.
public struct PluginConfirmation: Sendable, Equatable, Decodable {
    public let title: String
    public let message: String?
    public let button: String
    public let isDestructive: Bool

    public static let defaultButton = "Confirm"

    private enum CodingKeys: String, CodingKey { case title, message, button, destructive }

    public init(title: String, message: String? = nil, button: String? = nil, isDestructive: Bool = false) {
        self.title = title
        self.message = message.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        self.button = button.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } ?? PluginConfirmation.defaultButton
        self.isDestructive = isDestructive
    }

    public init(from decoder: Decoder) throws {
        if let title = try? decoder.singleValueContainer().decode(String.self) {
            self.init(title: title)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(title: try c.decode(String.self, forKey: .title),
                      message: try c.decodeIfPresent(String.self, forKey: .message),
                      button: try c.decodeIfPresent(String.self, forKey: .button),
                      isDestructive: try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false)
        }
        // A blank question would ask nothing; refusing it drops the action rather than
        // running it unasked.
        guard !title.allSatisfy(\.isWhitespace) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A confirmation needs a title."))
        }
    }

    /// The level that asks: the button first, where Return lands, then Cancel. The
    /// message sits beside the button, which is the row that needs it.
    public func items(icon: String?) -> [PluginItem] {
        [PluginItem(id: PluginConfirmation.confirmID, title: button, accessory: message,
                    icon: isDestructive ? "exclamationmark.triangle" : icon ?? "checkmark.circle"),
         PluginItem(id: PluginConfirmation.cancelID, title: "Cancel", icon: "xmark.circle")]
    }

    public static let confirmID = "spotlite.confirm"
    public static let cancelID = "spotlite.cancel"
}

/// The `confirm` key read from the same object as an action's `type`.
struct PluginConfirmKey: Decodable {
    let confirm: PluginConfirmation?
}

/// One of a row's or command's actions other than Return's: reached with its
/// modifiers, or from the action list (⌘K).
public struct PluginSecondaryAction: Sendable, Equatable, Decodable {
    public let title: String
    public let shortcut: PluginShortcut?
    public let icon: String?
    public let action: PluginAction
    public let confirm: PluginConfirmation?

    /// Each one is a row in the action list; more would not fit a glance.
    public static let maxCount = 16

    // No `actions`: a secondary's own list would be one level too deep to reach.
    private enum CodingKeys: String, CodingKey { case title, shortcut, icon, action }

    public init(title: String, shortcut: PluginShortcut? = nil, icon: String? = nil,
                action: PluginAction, confirm: PluginConfirmation? = nil) {
        self.title = title
        self.shortcut = shortcut
        self.icon = icon
        self.action = action
        self.confirm = confirm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title)
        guard !title.allSatisfy(\.isWhitespace) else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "An action needs a title.")
        }
        var shortcut: PluginShortcut?
        if let raw = try c.decodeIfPresent(String.self, forKey: .shortcut) {
            guard let parsed = PluginShortcut(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .shortcut, in: c,
                                                       debugDescription: "Unknown shortcut \(raw)")
            }
            shortcut = parsed
        }
        self.init(title: title, shortcut: shortcut, icon: try c.decodeIfPresent(String.self, forKey: .icon),
                  action: try c.decode(PluginAction.self, forKey: .action),
                  confirm: try c.decode(PluginConfirmKey.self, forKey: .action).confirm)
    }

    /// Per element, so one malformed action drops only itself.
    static func decodeList<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [PluginSecondaryAction] {
        guard var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var actions: [PluginSecondaryAction] = []
        while !list.isAtEnd, actions.count < maxCount {
            guard let decoded = try? list.decode(Lossy<PluginSecondaryAction>.self) else { break }
            if let action = decoded.value { actions.append(action) }
        }
        return actions
    }
}

/// An action as Return, a modifier or the action list runs it.
public struct PluginActionEntry: Sendable, Equatable {
    public let title: String
    public let icon: String?
    public let shortcut: PluginShortcut?
    public let action: PluginAction
    public let confirm: PluginConfirmation?
    /// What the chip says if the action enters a level: the row's own title for Return.
    public let levelTitle: String
    public let levelIcon: String?

    /// The key drawn beside the entry in the action list; nil when only the list reaches it.
    public var keyText: String? { shortcut?.keyText }
}

/// Everything Return does on a row or command, with and without modifiers.
public struct PluginActionSet: Sendable, Equatable {
    /// Return's action first, then the plugin's in its order, then ⌥↩'s built-in copy.
    public let entries: [PluginActionEntry]
    /// Return's own action, when the row has one: a row without only informs.
    public let primary: PluginActionEntry?
    /// The row's, for the action list's chip.
    public let title: String
    public let icon: String?

    /// `title` and `icon` are the row's. A later action naming a chord already taken is
    /// listed without it, so each chord does one thing.
    public init(primary: PluginAction?, confirm: PluginConfirmation?, secondaries: [PluginSecondaryAction],
                title: String, icon: String?) {
        var entries: [PluginActionEntry] = []
        if let primary {
            entries.append(PluginActionEntry(title: primary.verb, icon: primary.symbol, shortcut: nil, action: primary,
                                             confirm: confirm, levelTitle: title, levelIcon: icon))
        }
        var taken: Set<PluginShortcut> = []
        for secondary in secondaries.prefix(PluginSecondaryAction.maxCount) {
            let shortcut = secondary.shortcut.flatMap { taken.insert($0).inserted ? $0 : nil }
            entries.append(PluginActionEntry(title: secondary.title, icon: secondary.icon ?? secondary.action.symbol,
                                             shortcut: shortcut, action: secondary.action, confirm: secondary.confirm,
                                             levelTitle: secondary.title, levelIcon: secondary.icon ?? icon))
        }
        // ⌥↩ copies an address unless the plugin gave the chord a meaning of its own.
        if case .open(let target) = primary, !taken.contains(.option) {
            entries.append(PluginActionEntry(title: "Copy Link", icon: "link", shortcut: .option, action: .copy(target),
                                             confirm: nil, levelTitle: title, levelIcon: icon))
        }
        self.entries = entries
        self.primary = primary == nil ? nil : entries.first
        self.title = title
        self.icon = icon
    }

    public init(_ item: PluginItem) {
        self.init(primary: item.action, confirm: item.confirm, secondaries: item.actions,
                  title: item.title, icon: item.icon)
    }

    public init(_ command: PluginCommand) {
        self.init(primary: command.action, confirm: command.confirm, secondaries: command.actions,
                  title: command.title, icon: command.icon)
    }

    /// Return's action without modifiers; otherwise the action bound to exactly these.
    public func entry(for modifiers: PluginShortcut) -> PluginActionEntry? {
        modifiers.isEmpty ? primary : entries.first { $0.shortcut == modifiers }
    }

    /// The rows of the action list, each with the key that reaches it directly.
    public var items: [(item: PluginItem, key: String?)] {
        entries.enumerated().map { index, entry in
            (PluginItem(id: "spotlite.action.\(index)", title: entry.title, icon: entry.icon, action: entry.action),
             index == 0 && primary != nil ? "↩" : entry.keyText)
        }
    }
}

extension PluginAction {
    /// What the action list calls Return's action.
    public var verb: String {
        switch self {
        case .open: "Open"
        case .copy: "Copy"
        case .run: "Run"
        case .list, .search, .menu: "Show"
        }
    }

    /// The action list's icon for an action without one of its own.
    public var symbol: String {
        switch self {
        case .open: "arrow.up.forward.square"
        case .copy: "doc.on.doc"
        case .run: "play"
        case .list, .search, .menu: "list.bullet"
        }
    }
}
