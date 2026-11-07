import Foundation
import Security
import ShelfarrCore

/// Session secrets in the Keychain: this device only, available after first unlock
/// so audio can keep saving its position with the screen locked.
final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service = "org.shelfarr.app.session"

    private func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    func read(_ name: String) -> Data? {
        var search = query(name)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ name: String, _ value: Data) {
        SecItemDelete(query(name) as CFDictionary)
        var item = query(name)
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
