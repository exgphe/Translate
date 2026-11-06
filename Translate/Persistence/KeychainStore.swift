import Foundation
import Security

/// Stores API keys in the app's Keychain. Keys never go to UserDefaults, logs, or exports.
nonisolated struct KeychainStore: Sendable {
    static let shared: KeychainStore = {
        #if os(iOS)
        func group(_ key: String) -> String? {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, !value.contains("$(") else { return nil }
            return value
        }
        return KeychainStore(
            service: "wang.xiaolin.Translate",
            accessGroup: group("TranslationSharedKeychainAccessGroup"),
            legacyAccessGroup: group("TranslationLegacyKeychainAccessGroup")
        )
        #else
        return KeychainStore(service: "wang.xiaolin.Translate")
        #endif
    }()

    let service: String
    var accessGroup: String? = nil
    var legacyAccessGroup: String? = nil

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")"
            }
        }
    }

    func string(for account: String) -> String? {
        if let value = read(account: account, group: accessGroup) { return value }
        guard let legacyAccessGroup, legacyAccessGroup != accessGroup,
              let value = read(account: account, group: legacyAccessGroup) else { return nil }
        // Keep the original item until the shared write succeeds, including on devices
        // whose provisioning profile has not yet enabled Keychain Sharing.
        try? set(value, for: account)
        return value
    }

    private func read(account: String, group: String?) -> String? {
        var query = baseQuery(account: account, group: group)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(trimmed.utf8)
        let query = baseQuery(account: account, group: accessGroup)
        let attributes: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        if let legacyAccessGroup, legacyAccessGroup != accessGroup {
            try delete(account: account, group: legacyAccessGroup)
        }
    }

    func delete(account: String) throws {
        // Delete the fallback first so a removed key cannot be re-imported later.
        if let legacyAccessGroup, legacyAccessGroup != accessGroup {
            try delete(account: account, group: legacyAccessGroup)
        }
        try delete(account: account, group: accessGroup)
    }

    private func delete(account: String, group: String?) throws {
        let status = SecItemDelete(baseQuery(account: account, group: group) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String, group: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let group { query[kSecAttrAccessGroup] = group }
        return query
    }
}
