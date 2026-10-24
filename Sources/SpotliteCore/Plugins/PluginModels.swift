import Foundation

/// The wire format is deliberately shared by manifests, host calls and view data.
public enum PluginValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([PluginValue]), object([String: PluginValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([PluginValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: PluginValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    public subscript(_ key: String) -> PluginValue {
        if case .object(let v) = self { return v[key] ?? .null }
        return .null
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var array: [PluginValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: PluginValue]? { if case .object(let v) = self { return v }; return nil }

    public static func encode<T: Encodable>(_ value: T) throws -> PluginValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public static let supportedAPIVersion = 1
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var entry: String?
    public var description: String?
    public var author: String?
    public var icon: String?
    public var activation: String?
    public var background: Bool?
    public var updateURL: String?
    public var legacyUtilityID: String?
    public var testEntry: String?
    public var commands: [PluginCommand]
    public var settings: [PluginField]?

    public var entryPoint: String { entry ?? "main.lua" }
    public var startsAtLaunch: Bool { activation == "startup" }
    public var keepsAlive: Bool { background == true }

    public func validate() throws {
        guard Self.validID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              PluginVersion(version) != nil else { throw PluginError.invalid("Invalid plugin ID, name or semantic version.") }
        guard apiVersion == Self.supportedAPIVersion else {
            throw PluginError.invalid("\(name) requires API \(apiVersion). This version of Spotlite supports API 1.")
        }
        guard activation == nil || ["demand", "startup"].contains(activation!),
              Self.relativePath(entryPoint), !commands.isEmpty else {
            throw PluginError.invalid("A plugin needs commands, a relative entry path, and demand or startup activation.")
        }
        guard Set(commands.map(\.id)).count == commands.count,
              commands.allSatisfy({ Self.validID($0.id) && !$0.title.isEmpty &&
                  ($0.searchMode == nil || ["automatic", "enter"].contains($0.searchMode!)) &&
                  ($0.prefix == nil || (!($0.prefix?.isEmpty ?? true) && !($0.prefix?.contains(where: \.isWhitespace) ?? true))) }) else {
            throw PluginError.invalid("Command IDs must be unique; titles and prefixes must be valid.")
        }
        try PluginField.validate(settings ?? [])
        if let testEntry, !Self.relativePath(testEntry) { throw PluginError.invalid("Test entry must be a relative path.") }
        if let updateURL {
            guard let url = URL(string: updateURL), url.scheme == "https", url.host != nil else {
                throw PluginError.invalid("The update URL must use HTTPS.")
            }
        }
    }

    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." &&
        value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }

    public static func relativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty })
    }
}

public struct PluginCommand: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var keywords: [String]?
    public var prefix: String?
    public var global: Bool?
    public var searchMode: String?
    public var debounceMilliseconds: Int?
}

public struct PluginField: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var type: String?
    public var placeholder: String?
    public var description: String?
    public var required: Bool?
    public var options: [String]?
    public var defaultValue: PluginValue?

    public static func validate(_ fields: [PluginField]) throws {
        guard Set(fields.map(\.id)).count == fields.count,
              fields.allSatisfy({ PluginManifest.validID($0.id) && !$0.title.isEmpty &&
                  ["text", "secret", "toggle", "select", "number"].contains($0.type ?? "text") &&
                  ($0.type != "select" || !($0.options ?? []).isEmpty) }) else {
            throw PluginError.invalid("Form fields need unique IDs, titles, and supported field types.")
        }
    }
}

public struct PluginAction: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    public var key: String?
    public var close: Bool?
    public var data: PluginValue?
}

public struct PluginResult: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var state: Bool?
    public var actions: [PluginAction]?
    public var data: PluginValue?
}

public struct PluginView: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var type: String?
    public var placeholder: String?
    public var items: [PluginResult]?
    public var markdown: String?
    public var fields: [PluginField]?
    public var values: [String: PluginValue]?
    public var actions: [PluginAction]?
    public var searchMode: String?
    public var data: PluginValue?

    public init(id: String, title: String, type: String = "list", placeholder: String? = nil,
                items: [PluginResult] = [], markdown: String? = nil, fields: [PluginField]? = nil,
                values: [String: PluginValue]? = nil, actions: [PluginAction]? = nil,
                searchMode: String? = nil, data: PluginValue? = nil) {
        self.id = id; self.title = title; self.type = type; self.placeholder = placeholder
        self.items = items; self.markdown = markdown; self.fields = fields; self.values = values
        self.actions = actions; self.searchMode = searchMode; self.data = data
    }

    public func validate() throws {
        guard !id.isEmpty, ["list", "detail", "form"].contains(type ?? "list"),
              Set((items ?? []).map(\.id)).count == (items ?? []).count,
              (items ?? []).allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }),
              searchMode == nil || ["automatic", "enter"].contains(searchMode!) else {
            throw PluginError.invalid("Invalid plugin view or duplicate result IDs.")
        }
        try PluginField.validate(fields ?? [])
        for list in [actions ?? []] + (items ?? []).map({ $0.actions ?? [] }) {
            guard Set(list.map(\.id)).count == list.count, list.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }) else {
                throw PluginError.invalid("Actions need unique IDs and nonempty titles.")
            }
        }
    }
}

/// One JSON object per line in each direction. IDs are strings to avoid numeric truncation.
public struct PluginMessage: Codable, Sendable {
    public var id: String?
    public var method: String?
    public var params: PluginValue?
    public var result: PluginValue?
    public var error: String?

    public init(id: String? = nil, method: String? = nil, params: PluginValue? = nil,
                result: PluginValue? = nil, error: String? = nil) {
        self.id = id; self.method = method; self.params = params; self.result = result; self.error = error
    }
}

public enum PluginError: LocalizedError, Sendable {
    case invalid(String), stopped, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .failed(let message): message
        case .stopped: "Plugin execution stopped."
        }
    }
}

public struct PluginVersion: Comparable, Sendable {
    private let numbers: [Int]
    private let prerelease: [String]
    public init?(_ value: String) {
        guard value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#,
                          options: .regularExpression) != nil else { return nil }
        let core = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = raw.compactMap { Int($0) }
        guard raw.count == 3, numbers.count == 3,
              zip(raw, numbers).allSatisfy({ String($0.1) == $0.0 && $0.1 >= 0 }) else { return nil }
        self.numbers = numbers
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        if parts.count == 2 && prerelease.isEmpty { return nil }
        if prerelease.contains(where: { $0.allSatisfy(\.isNumber) && $0.count > 1 && $0.hasPrefix("0") }) { return nil }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            if let li = Int(l), let ri = Int(r) { return li < ri }
            if Int(l) != nil { return true }
            if Int(r) != nil { return false }
            return l < r
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
