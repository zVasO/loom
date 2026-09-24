import Foundation
import Security

/// Where an extension's secrets live (an API token, a password): the system
/// Keychain, one service per extension — NFR-S, secrets stay in the Keychain.
/// Two real implementations: the Keychain, and memory for the tests.
public protocol SecretStore: Sendable {
    func secret(_ key: String, for extensionID: String) throws -> String?
    func setSecret(_ value: String, _ key: String, for extensionID: String) throws
    func deleteSecret(_ key: String, for extensionID: String) throws
    func deleteAll(for extensionID: String) throws
}

public enum SecretPolicy {
    public static let maxValueBytes = 8 * 1024

    public static func validate(key: String) throws {
        guard ExtensionManifest.matches(#"^[A-Za-z0-9._-]{1,64}$"#, key) else {
            throw BridgeError(.invalidParams, "a secret key is 1 to 64 letters, digits, . _ -")
        }
    }

    public static func validate(value: String) throws {
        guard value.utf8.count <= maxValueBytes else {
            throw BridgeError(.tooLarge, "a secret is at most \(maxValueBytes) bytes")
        }
    }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic passwords in the login keychain, service `app.loom.extension.<id>`,
/// account = the key. No data-protection keychain: it needs entitlements an
/// ad-hoc build does not have. A call can block while macOS asks the user to
/// allow access — callers keep it off the main actor.
public struct KeychainSecretStore: SecretStore {
    public static let servicePrefix = "app.loom.extension."

    public init() {}

    private func query(_ key: String?, _ extensionID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.servicePrefix + extensionID,
        ]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    public func secret(_ key: String, for extensionID: String) throws -> String? {
        var query = query(key, extensionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status)
        }
    }

    public func setSecret(_ value: String, _ key: String, for extensionID: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key, extensionID) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(key, extensionID)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Loom extension \(extensionID): \(key)"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status) }
        default:
            throw KeychainError(update)
        }
    }

    public func deleteSecret(_ key: String, for extensionID: String) throws {
        let status = SecItemDelete(query(key, extensionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    /// The file-based keychain may delete one match per call: loop until none
    /// is left (bounded, so a keychain that keeps answering success cannot
    /// spin forever).
    public func deleteAll(for extensionID: String) throws {
        for _ in 0..<1000 {
            let status = SecItemDelete(query(nil, extensionID) as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status) }
        }
    }
}

/// The tests' Keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: [String: String]] = [:]

    public init() {}

    public func secret(_ key: String, for extensionID: String) throws -> String? {
        lock.withLock { secrets[extensionID]?[key] }
    }

    public func setSecret(_ value: String, _ key: String, for extensionID: String) throws {
        lock.withLock { secrets[extensionID, default: [:]][key] = value }
    }

    public func deleteSecret(_ key: String, for extensionID: String) throws {
        lock.withLock { _ = secrets[extensionID]?.removeValue(forKey: key) }
    }

    public func deleteAll(for extensionID: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: extensionID) }
    }

    public func keys(for extensionID: String) -> [String] {
        lock.withLock { (secrets[extensionID] ?? [:]).keys.sorted() }
    }
}
