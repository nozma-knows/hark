import Foundation
import Security

/// Minimal Keychain wrapper for storing a single user-supplied secret per
/// account (e.g., `ANTHROPIC_API_KEY`). Backed by the user's login keychain
/// via the generic-password service `co.milbo.hark`.
///
/// Why not a third-party Keychain library: the surface area is tiny —
/// read / write / delete — and the macOS Security framework is stable.
/// One file, no dependency, easy to audit.
///
/// All operations are synchronous and main-thread-safe (Security
/// framework calls are thread-safe). Tests inject a `Storage` protocol
/// to avoid touching the real keychain.
enum Keychain {
    static let service = "co.milbo.hark"

    /// Read the secret stored under `account`. Returns nil if absent or if
    /// the keychain access fails for any reason — callers should treat
    /// "no value" and "couldn't read" identically (both mean we don't
    /// have a usable secret).
    static func read(account: String, storage: Storage = SystemStorage()) -> String? {
        storage.read(service: service, account: account)
    }

    /// Write `value` under `account`. Replaces any existing entry. Throws
    /// on backing-store failures so the Settings UI can surface a real
    /// error to the user instead of silently dropping their key.
    static func write(_ value: String, account: String, storage: Storage = SystemStorage()) throws {
        try storage.write(value, service: service, account: account)
    }

    /// Remove the entry. No-op if it doesn't exist.
    static func delete(account: String, storage: Storage = SystemStorage()) {
        storage.delete(service: service, account: account)
    }

    /// Test seam — production code uses `SystemStorage`; tests inject
    /// an in-memory implementation so they don't pollute the user's
    /// real keychain.
    protocol Storage {
        func read(service: String, account: String) -> String?
        func write(_ value: String, service: String, account: String) throws
        func delete(service: String, account: String)
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                "Keychain error: \(status)"
            case .dataEncodingFailed:
                "Couldn't encode secret as UTF-8"
            }
        }
    }

    /// Real macOS Keychain implementation. Uses generic-password items
    /// scoped to our service so different secrets (api key, future
    /// Linear token, …) live side-by-side under distinct `account` keys.
    struct SystemStorage: Storage {
        func read(service: String, account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        func write(_ value: String, service: String, account: String) throws {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.dataEncodingFailed
            }
            // Upsert: try to update first, fall back to add if the entry
            // doesn't exist yet. Two-step keeps us from clobbering other
            // attributes the user (or a future Hark version) may have set.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus == errSecSuccess { return }
            if updateStatus == errSecItemNotFound {
                var addAttrs = query
                addAttrs[kSecValueData as String] = data
                let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
                if addStatus == errSecSuccess { return }
                throw KeychainError.unexpectedStatus(addStatus)
            }
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        func delete(service: String, account: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            // errSecItemNotFound is fine; anything else we ignore at this
            // layer (caller will refresh state and see the entry's still
            // there).
            SecItemDelete(query as CFDictionary)
        }
    }
}
