import Foundation
import Security

/// Where the reader's GIF service keys live. A key is a credential for the
/// reader's own developer account, so it goes to the Keychain, never to
/// defaults or logs, and Nevermore ships none.
public protocol GIFServiceKeyStoring: Sendable {
    func key(for provider: GIFProvider) -> String?
    func setKey(_ key: String?, for provider: GIFProvider) throws
}

public enum GIFServiceKeyError: Error, LocalizedError, Equatable {
    case implausible
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .implausible: return "That does not look like a GIF service key. Paste the key from the service's developer page."
        case .keychain(let status): return "The key could not be saved in the Keychain (\(status))."
        }
    }
}

/// One generic-password item per service, on this Mac only.
public struct KeychainGIFServiceKeyStore: GIFServiceKeyStoring {
    static let service = "ch.goodvantage.Nevermore.gif-service-key"

    public init() {}

    private func query(_ provider: GIFProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: provider.rawValue]
    }

    public func key(for provider: GIFProvider) -> String? {
        var item = query(provider)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), GIFSearchRequest.isPlausibleKey(key) else { return nil }
        return key
    }

    /// A nil or empty key removes the stored one.
    public func setKey(_ key: String?, for provider: GIFProvider) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw GIFServiceKeyError.keychain(status) }
            return
        }
        guard GIFSearchRequest.isPlausibleKey(trimmed) else { throw GIFServiceKeyError.implausible }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GIFServiceKeyError.keychain(added) }
        } else if status != errSecSuccess {
            throw GIFServiceKeyError.keychain(status)
        }
    }
}

extension GIFPreferences {
    /// A random identifier KLIPY asks for, so it can tell its users apart
    /// without knowing who they are. Made once and kept in defaults; it is
    /// not derived from any Raven account.
    public static let clientIDKey = "gifClientID"

    public static func clientID(_ defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: clientIDKey), UUID(uuidString: stored) != nil { return stored }
        let made = UUID().uuidString
        defaults.set(made, forKey: clientIDKey)
        return made
    }

    /// The search client for the reader's chosen service, or nil without
    /// a key for it.
    public static func searchClient(defaults: UserDefaults = .standard, keys: any GIFServiceKeyStoring = KeychainGIFServiceKeyStore(), locale: Locale = .current) -> GIFSearchClient? {
        let provider = GIFProvider(storedValue: defaults.string(forKey: GIFProvider.defaultsKey))
        guard let key = keys.key(for: provider) else { return nil }
        let request = GIFSearchRequest(provider: provider, key: key, rating: GIFRating(storedValue: defaults.string(forKey: GIFRating.defaultsKey)),
                                       language: locale.language.languageCode?.identifier ?? "en", region: locale.region?.identifier, clientID: clientID(defaults))
        return GIFSearchClient(request: request)
    }
}
