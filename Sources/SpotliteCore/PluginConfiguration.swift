import Foundation

/// The ordinary JSON values supported by plugin settings. No credentials or secrets.
public enum PluginSettingValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        }
    }

    public var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            let text = String(value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        case .boolean(let value): return value ? "true" : "false"
        }
    }
}

public struct PluginSetting: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable { case text, number, boolean, choice }
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

    private enum CodingKeys: String, CodingKey {
        case id, label, type, description, required, min, max, options
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
        if let defaultValue, let error = validationError(for: defaultValue) {
            throw invalid("Invalid default for setting \(id): \(error)")
        }
    }

    /// An unchecked toggle has a useful typed value even without an explicit default.
    public var initialValue: PluginSettingValue? {
        defaultValue ?? (type == .boolean ? .boolean(false) : nil)
    }

    public func validationError(for value: PluginSettingValue?) -> String? {
        guard let value else { return required ? "Enter a value for \(label)." : nil }
        switch (type, value) {
        case (.text, .string(let text)):
            return required && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a value for \(label)." : nil
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
    }

    /// Only declared values cross the process boundary; obsolete saved keys stay private.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        guard data.count <= PluginConfigurationStore.maxBytes else { throw PluginConfigurationStore.Failure.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Host-owned, persistent settings, independent of both installed code and plugin-owned data.
public struct PluginConfigurationStore: Sendable {
    public static let maxBytes = 64 * 1024
    public let directory: URL

    public enum Failure: Error, LocalizedError {
        case invalidID, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidID: "The plugin id is invalid."
            case .tooLarge: "Plugin settings must fit within 64 KB. Shorten the text values."
            }
        }
    }

    public init(directory: URL = Storage.supportDirectory.appendingPathComponent("PluginSettings", isDirectory: true)) {
        self.directory = directory
    }

    private func url(for id: String) throws -> URL {
        guard PluginManifest.isValidID(id) else { throw Failure.invalidID }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    public func load(for id: String) throws -> [String: PluginSettingValue] {
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

    public func save(_ values: [String: PluginSettingValue], for id: String) throws {
        let url = try url(for: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func reset(for id: String) throws {
        let url = try url(for: id)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }
}
