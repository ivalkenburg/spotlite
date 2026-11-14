import Foundation

/// The JSON values supported by plugin settings. A secret is a string here; only where
/// it is stored differs.
public enum PluginSettingValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode([String].self) { self = .list(value) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        case .list(let value): try c.encode(value)
        }
    }

    /// A list edited one item per line: lines are trimmed and blank ones dropped.
    public static func list(lines text: String) -> PluginSettingValue {
        .list(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    public var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            let text = String(value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        case .boolean(let value): return value ? "true" : "false"
        case .list(let value): return value.joined(separator: "\n")
        }
    }
}

public struct PluginSetting: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable, CaseIterable { case text, number, boolean, choice, secret, file, folder, list }
    public struct Option: Decodable, Sendable, Equatable {
        public let value: String
        public let label: String
    }

    public let id: String
    public let label: String
    public let type: Kind
    public let description: String?
    public let required: Bool
    public let defaultValue: PluginSettingValue?
    public let min: Double?
    public let max: Double?
    public let options: [Option]
    /// A multi-line editor for `text`.
    public let multiline: Bool
    /// A `file` or `folder` path must name an existing item of that kind.
    public let mustExist: Bool
    /// Filename extensions offered by a `file` field's open panel, without dots.
    public let extensions: [String]

    private enum CodingKeys: String, CodingKey {
        case id, label, type, description, required, min, max, options, multiline, mustExist, extensions
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        type = try c.decode(Kind.self, forKey: .type)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try c.decodeIfPresent(PluginSettingValue.self, forKey: .defaultValue)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
        mustExist = try c.decodeIfPresent(Bool.self, forKey: .mustExist) ?? false
        extensions = try (c.decodeIfPresent([String].self, forKey: .extensions) ?? []).map {
            $0.hasPrefix(".") ? String($0.dropFirst()) : $0
        }

        func invalid(_ reason: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: reason))
        }
        guard PluginManifest.isValidID(id), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("Settings need a plain id and a nonempty label.")
        }
        guard min?.isFinite != false, max?.isFinite != false,
              min == nil || max == nil || min! <= max!,
              type == .number || (min == nil && max == nil) else {
            throw invalid("Invalid number bounds for setting \(id).")
        }
        if type == .choice {
            guard !options.isEmpty, Set(options.map(\.value)).count == options.count,
                  options.allSatisfy({ !$0.value.isEmpty && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw invalid("Choice setting \(id) needs unique, nonempty options.")
            }
        } else if !options.isEmpty {
            throw invalid("Only choice settings can have options: \(id).")
        }
        guard !multiline || type == .text, !mustExist || type == .file || type == .folder,
              extensions.isEmpty || type == .file else {
            throw invalid("multiline, mustExist or extensions do not apply to setting \(id).")
        }
        guard extensions.allSatisfy({ !$0.isEmpty && !$0.contains("/") }) else {
            throw invalid("File setting \(id) has an invalid extension.")
        }
        guard type != .secret || defaultValue == nil else {
            throw invalid("Secret setting \(id) cannot have a default.")
        }
        // Whether a default path exists depends on the machine, not the schema.
        if let defaultValue, let error = validationError(for: defaultValue, checkingFiles: false) {
            throw invalid("Invalid default for setting \(id): \(error)")
        }
    }

    /// An unchecked toggle has a useful typed value even without an explicit default.
    public var initialValue: PluginSettingValue? {
        defaultValue ?? (type == .boolean ? .boolean(false) : nil)
    }

    /// A leading `~` in a `file` or `folder` value stands for the home folder.
    public static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// `checkingFiles` checks `mustExist` paths on disk, so this runs at load and save
    /// boundaries and while editing the form, never while matching.
    public func validationError(for value: PluginSettingValue?, checkingFiles: Bool = true) -> String? {
        guard let value else { return required ? "Enter a value for \(label)." : nil }
        switch (type, value) {
        case (.text, .string(let text)), (.secret, .string(let text)):
            return required && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a value for \(label)." : nil
        case (.file, .string(let path)), (.folder, .string(let path)):
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return required ? "Choose a \(type.rawValue) for \(label)." : nil
            }
            guard mustExist, checkingFiles else { return nil }
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: Self.expandedPath(path), isDirectory: &isFolder)
            return exists && isFolder.boolValue == (type == .folder) ? nil : "Choose an existing \(type.rawValue) for \(label)."
        case (.list, .list(let items)):
            if items.contains(where: { $0.contains(where: \.isNewline) || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "Each item in \(label) must be one nonblank line."
            }
            return required && items.isEmpty ? "Enter at least one item for \(label)." : nil
        case (.number, .number(let number)):
            guard number.isFinite else { return "Enter a finite number." }
            if let min, number < min { return "Enter a number of at least \(PluginSettingValue.number(min).text)." }
            if let max, number > max { return "Enter a number no greater than \(PluginSettingValue.number(max).text)." }
            return nil
        case (.boolean, .boolean): return nil
        case (.choice, .string(let choice)):
            return options.contains { $0.value == choice } ? nil : "Choose an available option for \(label)."
        default:
            return type == .number ? "Enter a number." : "Choose a valid value for \(label)."
        }
    }
}

/// A schema's current values and readiness, computed at load/save boundaries, never
/// during matching. Values with errors remain available for correction in Settings.
public struct PluginConfiguration: Sendable, Equatable {
    public let values: [String: PluginSettingValue]
    public let errors: [String: String]
    public let problem: String?
    /// Fields whose values never leave memory except for the Keychain and the plugin.
    public let secretIDs: Set<String>
    private let pathIDs: Set<String>
    /// Every declared field, in the manifest's order.
    private let ids: [String]
    public var isValid: Bool { problem == nil && errors.isEmpty }

    public init(settings: [PluginSetting], saved: [String: PluginSettingValue] = [:], problem: String? = nil) {
        var values: [String: PluginSettingValue] = [:]
        var errors: [String: String] = [:]
        for setting in settings {
            let value = saved[setting.id] ?? setting.initialValue
            values[setting.id] = value
            if let error = setting.validationError(for: value) { errors[setting.id] = error }
        }
        self.values = values
        self.errors = errors
        self.problem = problem
        self.secretIDs = Set(settings.filter { $0.type == .secret }.map(\.id))
        self.pathIDs = Set(settings.filter { $0.type == .file || $0.type == .folder }.map(\.id))
        self.ids = settings.map(\.id)
    }

    /// The values as the plugin receives them: paths expanded. Only declared values
    /// cross the process boundary; obsolete saved keys stay private.
    private var pluginValues: [String: PluginSettingValue] {
        var values = values
        for id in pathIDs {
            if case .string(let path)? = values[id] { values[id] = .string(PluginSetting.expandedPath(path)) }
        }
        return values
    }

    /// `SPOTLITE_CONFIG`.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pluginValues)
        guard data.count <= PluginConfigurationStore.maxBytes else { throw PluginConfigurationStore.Failure.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    /// `SPOTLITE_CONFIG_<ID>`, with the same values as `json()`.
    public var variables: [String: String] {
        PluginEnvironment.configurationVariables(ids: ids, values: pluginValues)
    }
}

/// Host-owned, persistent settings, independent of both installed code and plugin-owned data.
/// Secret fields go to `secrets` and are never written to the JSON file.
public struct PluginConfigurationStore: Sendable {
    public static let maxBytes = 64 * 1024
    public let directory: URL
    public let secrets: any PluginSecretStore

    public enum Failure: Error, LocalizedError {
        case invalidID, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidID: "The plugin id is invalid."
            case .tooLarge: "Plugin settings must fit within 64 KB. Shorten the text values."
            }
        }
    }

    public init(directory: URL = Storage.supportDirectory.appendingPathComponent("PluginSettings", isDirectory: true),
                secrets: any PluginSecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private func url(for id: String) throws -> URL {
        guard PluginManifest.isValidID(id) else { throw Failure.invalidID }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    /// The saved values of `settings`' secret fields come from the secret store; the file's
    /// own copies of them, if someone wrote any, are ignored.
    public func load(for id: String, settings: [PluginSetting]) throws -> [String: PluginSettingValue] {
        var values = try loadFile(for: id)
        for setting in settings where setting.type == .secret {
            values[setting.id] = try secrets.read(plugin: id, field: setting.id).map(PluginSettingValue.string)
        }
        return values
    }

    private func loadFile(for id: String) throws -> [String: PluginSettingValue] {
        let url = try url(for: id)
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maxBytes + 1) ?? Data()
            guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
            return try JSONDecoder().decode([String: PluginSettingValue].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        }
    }

    /// An unset or empty secret removes its stored value.
    public func save(_ values: [String: PluginSettingValue], for id: String, settings: [PluginSetting]) throws {
        let url = try url(for: id)
        let secretFields = settings.filter { $0.type == .secret }.map(\.id)
        var stored = values
        for field in secretFields { stored[field] = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        for field in secretFields {
            if case .string(let secret)? = values[field], !secret.isEmpty {
                try secrets.write(secret, plugin: id, field: field)
            } else {
                try secrets.delete(plugin: id, field: field)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func reset(for id: String) throws {
        let url = try url(for: id)
        try secrets.deleteAll(plugin: id)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }
}
