import Foundation
import Security
import Branding

/// Read/write access to small secrets. PluginKit uses it to keep the HMAC integrity
/// key for the permission-decision file in the login Keychain instead of next to the
/// records it protects (docs/plugin-store-phase1.md §9). Tests inject a fake.
public protocol SecretProviding: Sendable {
    /// The stored secret, or nil when nothing has been stored for the account yet.
    func data(forKey account: String) throws -> Data?
    /// Create or replace the secret for the account.
    func store(_ data: Data, forKey account: String) throws
}

public struct KeychainSecretStore: SecretProviding {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    private let service: String

    public init(service: String = Brand.bundleIdentifier.appending(".plugins")) {
        self.service = service
    }

    public func data(forKey account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func store(_ data: Data, forKey account: String) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            // This-device-only keeps the key off iCloud keychain sync.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
