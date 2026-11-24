import Foundation
import Security

/// Stores the TV's pairing client-key. It's a bearer credential for controlling
/// the TV, so it lives in the Keychain, never in UserDefaults or logs.
enum Keychain {
    private static let service = "com.buraksakalli.tvcompanion.client-key"

    static func clientKey(for host: String) -> String? {
        var query = base(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setClientKey(_ key: String, for host: String) -> Bool {
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base(host) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(host)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "TV Companion pairing key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func deleteClientKey(for host: String) {
        SecItemDelete(base(host) as CFDictionary)
    }

    private static func base(_ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }
}
