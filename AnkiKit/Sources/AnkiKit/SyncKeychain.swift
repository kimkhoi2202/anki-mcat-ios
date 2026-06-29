import Foundation
import Security

/// Sync credentials persisted after a successful `sync_login`.
///
/// The `hkey` (host key) is the long-lived auth token Anki uses in place of the
/// password for every subsequent sync — it is password-equivalent, so it is
/// stored in the Keychain rather than `UserDefaults` (cf. AnkiDroid keeping
/// `Prefs.hkey`).
public struct SyncCredentials: Codable, Sendable, Equatable {
    /// The account username/email (for display; AnkiDroid keeps `Prefs.username`).
    public var username: String
    /// The host key returned by `sync_login`, reused as `SyncAuth.hkey`.
    public var hkey: String
    /// Custom server base URL, or nil for the default (AnkiWeb).
    public var endpoint: String?

    public init(username: String, hkey: String, endpoint: String? = nil) {
        self.username = username
        self.hkey = hkey
        self.endpoint = endpoint
    }
}

/// A failure interacting with the Keychain, wrapping the raw `OSStatus`.
public struct KeychainError: Error, Sendable, Equatable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// Stores sync credentials in the system Keychain.
///
/// A single generic-password item (one per `service`/`account` pair) holds the
/// JSON-encoded ``SyncCredentials``. Items are accessible after first unlock so
/// a background sync can read them without the device being unlocked.
public enum SyncKeychain {
    /// Keychain service identifier for this app's sync credentials.
    public static let service = "com.khoilam.ankispeedrun.sync"
    /// Fixed account; this app stores a single sync identity.
    public static let account = "default"

    /// Saves (inserting or updating) the credentials. Throws ``KeychainError``
    /// on failure.
    public static func save(_ credentials: SyncCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    /// Loads the stored credentials, or nil if none are saved (or decoding fails).
    public static func load() -> SyncCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(SyncCredentials.self, from: data)
        else { return nil }
        return credentials
    }

    /// Removes any stored credentials (used on logout / auth failure).
    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
