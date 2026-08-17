import Foundation
import Security

enum KeychainStore {
    private static let service = "com.sherrodsoftware.BoxingDay.jamf-api"
    private static let account = "client-secret"

    static func loadClientSecret() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.operationFailed(status)
        }
        return secret
    }

    static func saveClientSecret(_ secret: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainStoreError.invalidSecret
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(updateStatus)
        }

        var newItem = query
        for (key, value) in attributes {
            newItem[key] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.operationFailed(addStatus)
        }
    }

    static func removeClientSecret() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status)
        }
    }
}

enum KeychainStoreError: LocalizedError {
    case invalidSecret
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            return "The API client secret could not be encoded."
        case .operationFailed(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map {
                "The Jamf API secret could not be stored in Keychain: \($0)"
            } ?? "The Jamf API secret could not be stored in Keychain."
        }
    }
}
