import Foundation
import Security

/// Stores API keys in the Keychain, one item per Immich user ID.
nonisolated enum Keychain {
    private static let service = "immich-swipe.api-key"

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    static func setAPIKey(_ key: String, for userID: String) throws {
        let query = baseQuery(for: userID)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            // Readable once the device has been unlocked after boot, never synced or backed up to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func apiKey(for userID: String) throws -> String? {
        var query = baseQuery(for: userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func removeAPIKey(for userID: String) throws {
        let status = SecItemDelete(baseQuery(for: userID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private static func baseQuery(for userID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userID,
            // The modern keychain on macOS too, so behaviour matches iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
