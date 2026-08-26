import Foundation
import Security

/* The collector token, in the Keychain and nowhere else.
 *
 * **Never UserDefaults.** A bearer token for a mailbox is the one value this
 * app holds that would matter if it leaked, and a preferences plist is a
 * world-readable file inside the container.
 *
 * A sandboxed build signed ad-hoc has no team prefix on its keychain access
 * group, and the daemon answers `errSecMissingEntitlement` (-34018) to every
 * request. That is a real condition on a locally built app rather than a
 * programming error, so it is handled rather than trapped: the token is held
 * in memory for the life of the process and the settings sheet says so. It is
 * still never written to disk by this app.
 */

enum TokenStore {

    private static let service = "com.example.charon.collector"
    private static let account = "bearer"

    /// The session fallback, used only when the Keychain refuses the process.
    private static var memory: String?
    private(set) static var keychainRefused = false

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if status != errSecItemNotFound {
            keychainRefused = true
        }
        return memory ?? ""
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        memory = token.isEmpty ? nil : token

        if token.isEmpty {
            let status = SecItemDelete(query() as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { keychainRefused = true }
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }

        if status != errSecSuccess { keychainRefused = true }
        return status == errSecSuccess
    }
}
