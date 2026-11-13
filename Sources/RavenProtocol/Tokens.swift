import Foundation
import Security

/// OAuth token material for one account. Serialized forms stay inside
/// KeychainTokenStore; nothing here is user-facing text.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
    /// Access tokens are refreshed a minute before their stated expiry so a
    /// slow request never departs with an already-dead token.
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// Per-account token persistence in the login keychain. Generic-password
/// items scoped by account UUID; the item cannot migrate to another device.
public enum KeychainTokenStore {
    static let service = "ch.goodvantage.Nevermore.oauth-tokens"

    static func query(accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }

    public static func save(_ tokens: OAuthTokens, accountID: UUID) throws {
        let data = try JSONEncoder().encode(tokens)
        let base = query(accountID: accountID)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw RavenError.keychain(added) }
        } else if status != errSecSuccess {
            throw RavenError.keychain(status)
        }
    }

    public static func load(accountID: UUID) throws -> OAuthTokens? {
        var item = query(accountID: accountID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RavenError.keychain(status) }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public static func delete(accountID: UUID) throws {
        let status = SecItemDelete(query(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RavenError.keychain(status) }
    }
}
