import Foundation
import Security

enum KeychainStore {
    nonisolated private static let service = "net.unwraps.Shift-Upload"
    nonisolated private static let sharedAccessGroup = "DU562ND7L2.net.unwraps.Shift-Hub.shared"

    nonisolated static func string(for account: String) -> String? {
        if let value = string(for: account, accessGroup: sharedAccessGroup) {
            return value
        }
        guard let legacyValue = string(for: account, accessGroup: nil) else {
            return nil
        }
        set(legacyValue, for: account)
        return legacyValue
    }

    nonisolated static func set(_ value: String, for account: String) {
        var query = baseQuery(for: account)
        query[kSecAttrAccessGroup as String] = sharedAccessGroup

        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    nonisolated private static func string(for account: String, accessGroup: String?) -> String? {
        var query = baseQuery(for: account)
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
