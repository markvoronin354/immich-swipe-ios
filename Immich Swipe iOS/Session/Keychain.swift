import Foundation
import Security

/// Stores API keys, and the custom headers that go with them, in the Keychain: one item per Immich user ID.
nonisolated enum Keychain {
    private static let service = "immich-swipe.api-key"
    /// Headers can carry secrets too (a Cloudflare Access token, say), so they are kept the same way.
    private static let headersService = "immich-swipe.custom-headers"

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    static func setAPIKey(_ key: String, for userID: String) throws {
        try set(key, service: service, for: userID)
    }

    static func apiKey(for userID: String) throws -> String? {
        try read(service: service, for: userID)
    }

    static func removeAPIKey(for userID: String) throws {
        try remove(service: service, for: userID)
    }

    /// Saves an account's custom headers, or forgets them when there are none.
    static func setHeaders(_ headers: [String: String], for userID: String) throws {
        if let text = CustomHeaders.encode(headers) {
            try set(text, service: headersService, for: userID)
        } else {
            try remove(service: headersService, for: userID)
        }
    }

    static func headers(for userID: String) -> [String: String] {
        CustomHeaders.parse((try? read(service: headersService, for: userID)) ?? nil)
    }

    static func removeHeaders(for userID: String) throws {
        try remove(service: headersService, for: userID)
    }

    private static func set(_ text: String, service: String, for userID: String) throws {
        let query = baseQuery(for: userID, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(text.utf8),
            // Readable once the device has been unlocked after boot, never synced or backed up to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func read(service: String, for userID: String) throws -> String? {
        var query = baseQuery(for: userID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func remove(service: String, for userID: String) throws {
        let status = SecItemDelete(baseQuery(for: userID, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private static func baseQuery(for userID: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userID,
            // The modern keychain on macOS too, so behaviour matches iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
