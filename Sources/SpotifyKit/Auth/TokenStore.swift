import Foundation

/// Persistence for the refresh token. SPEC.md §9.1 step 3.
///
/// Only the refresh token is stored. Access tokens live in memory for their
/// hour and are never written to disk.
public protocol TokenStore: Sendable {
    func loadRefreshToken() throws -> String?
    func save(refreshToken: String) throws
    func clear() throws
}

#if canImport(Security)
import Security

/// Keychain-backed store. §9.1 requires
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the watch must be able
/// to refresh while locked on the wrist mid-workout, but the token must not
/// travel to a backup or another device.
public struct KeychainTokenStore: TokenStore {
    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case malformedData
    }

    private let service: String
    private let account: String

    public init(service: String = "com.biorhythm.spotify", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadRefreshToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func save(refreshToken: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(refreshToken.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = baseQuery
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
#endif
