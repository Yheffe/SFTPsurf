import Foundation
import Security

/// Stores bookmark passwords in the login keychain.
///
/// Items are keyed by bookmark id rather than host, so two entries pointing at
/// the same server can hold different credentials.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    private let service: String
    private let lock = NSLock()

    public init(service: String = "com.sftpsurf.SFTPsurf") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns nil when nothing is stored, when the user denies access, or when
    /// the item belongs to a different build of the app.
    public func password(for bookmarkID: UUID) -> String? {
        var query = baseQuery(account: bookmarkID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        lock.lock()
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        lock.unlock()

        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Adds or replaces the stored password. Passing nil removes it.
    @discardableResult
    public func setPassword(_ password: String?, for bookmarkID: UUID) -> Bool {
        let account = bookmarkID.uuidString
        guard let password else { return deletePassword(for: bookmarkID) }

        let data = Data(password.utf8)
        lock.lock()
        defer { lock.unlock() }

        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func deletePassword(for bookmarkID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(account: bookmarkID.uuidString) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// True when a password is already stored, without reading it.
    public func hasPassword(for bookmarkID: UUID) -> Bool {
        var query = baseQuery(account: bookmarkID.uuidString)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        lock.lock()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        lock.unlock()
        return status == errSecSuccess
    }
}
