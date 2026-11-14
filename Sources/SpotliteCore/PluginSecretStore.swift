import Foundation
import Security

/// Where `secret` setting values live instead of the settings JSON. Read only at the
/// configuration boundaries (first use, Reload, save, reset), never while matching.
public protocol PluginSecretStore: Sendable {
    /// Nil when the field has no value.
    func read(plugin: String, field: String) throws -> String?
    func write(_ value: String, plugin: String, field: String) throws
    func delete(plugin: String, field: String) throws
    /// Removes every value of the plugin, including fields its manifest no longer declares.
    func deleteAll(plugin: String) throws
}

public struct PluginSecretStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return "Keychain: \(message)"
    }
}

/// Generic passwords in the login keychain, one per field: service
/// `<prefix><plugin id>`, account `<field id>`.
///
/// The data protection keychain would avoid per-app ACLs, but it needs a
/// `keychain-access-groups` entitlement and so a provisioning profile; without one every
/// call fails with `errSecMissingEntitlement`. The file-based keychain trusts the app by
/// its designated requirement, which a build signed with the same Apple Development
/// certificate and bundle id keeps, so updates read and update items without a prompt.
/// Only the exact binary that created an item may delete it (`errSecInvalidOwnerEdit`
/// otherwise, with no prompt), so deleting falls back to overwriting the value with a
/// single NUL byte, which reads back as no value. Updating to empty data is silently
/// ignored, and a text field cannot produce a NUL.
public struct KeychainSecretStore: PluginSecretStore {
    public static let defaultPrefix = "com.igorv.spotlite.plugin."
    private static let tombstone = Data([0])
    public let prefix: String

    public init(prefix: String = defaultPrefix) {
        self.prefix = prefix
    }

    private func query(plugin: String, field: String? = nil) throws -> [String: Any] {
        guard PluginManifest.isValidID(plugin), field.map(PluginManifest.isValidID) != false else {
            throw PluginConfigurationStore.Failure.invalidID
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: prefix + plugin,
        ]
        if let field { query[kSecAttrAccount as String] = field }
        return query
    }

    public func read(plugin: String, field: String) throws -> String? {
        var query = try query(plugin: plugin, field: field)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PluginSecretStoreError(status: status) }
        guard let data = result as? Data, !data.isEmpty, data != Self.tombstone else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, plugin: String, field: String) throws {
        try store(Data(value.utf8), plugin: plugin, field: field)
    }

    private func store(_ data: Data, plugin: String, field: String) throws {
        let query = try query(plugin: plugin, field: field)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound, data != Self.tombstone {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Spotlite plugin \(plugin): \(field)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PluginSecretStoreError(status: status) }
    }

    public func delete(plugin: String, field: String) throws {
        let status = SecItemDelete(try query(plugin: plugin, field: field) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        case errSecInvalidOwnerEdit: try store(Self.tombstone, plugin: plugin, field: field)
        default: throw PluginSecretStoreError(status: status)
        }
    }

    public func deleteAll(plugin: String) throws {
        // Listing attributes decrypts nothing, so it never prompts.
        var query = try query(plugin: plugin)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw PluginSecretStoreError(status: status) }
        let fields = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        for field in Set(fields) where PluginManifest.isValidID(field) { try delete(plugin: plugin, field: field) }
    }
}

/// An in-memory store for tests and isolated checks.
public final class MemorySecretStore: PluginSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]

    public init() {}

    public var snapshot: [String: [String: String]] { lock.withLock { values } }

    public func read(plugin: String, field: String) throws -> String? { lock.withLock { values[plugin]?[field] } }
    public func write(_ value: String, plugin: String, field: String) throws { lock.withLock { values[plugin, default: [:]][field] = value } }
    public func delete(plugin: String, field: String) throws { lock.withLock { _ = values[plugin]?.removeValue(forKey: field) } }
    public func deleteAll(plugin: String) throws { lock.withLock { _ = values.removeValue(forKey: plugin) } }
}
