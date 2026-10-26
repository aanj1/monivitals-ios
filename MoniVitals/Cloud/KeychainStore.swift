//
//  KeychainStore.swift
//  MoniVitals
//
//  Tiny generic Keychain wrapper (Security.framework, no dependencies) for one
//  Codable blob per account under the app's auth service. Used to persist the
//  signed-in cloud account state across launches (docs/CLOUD_SYNC.md).
//

import Foundation
import Security

enum KeychainStore {
    /// Keychain service for all MoniVitals auth blobs (per docs/CLOUD_SYNC.md).
    static let service = "com.monivitals.app.auth"

    /// Store (insert or replace) a Codable value under `account`.
    static func save<T: Codable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Fetch and decode the value stored under `account`, or nil.
    static func load<T: Codable>(_ type: T.Type, account: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Remove the value stored under `account` (no-op when absent).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
