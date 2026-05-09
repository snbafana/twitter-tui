import Foundation
import Security

enum KeychainKey: String {
    case clientSecret
    case accessToken
    case refreshToken
    case tokenExpiresAt
}

struct KeychainStore {
    private let service = "com.snbafana.xui"

    func read(_ key: KeychainKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for key: KeychainKey) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)

        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func delete(_ key: KeychainKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain operation failed with status \(status)"
    }
}
