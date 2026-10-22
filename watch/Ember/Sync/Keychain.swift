import Foundation
import Security

/// The server's address and token, kept in the Keychain on this watch.
///
/// An app built unsigned, as `scripts/watch.sh sim` builds it for the
/// simulator, may not use the Keychain at all (errSecMissingEntitlement).
/// Then they go in a file only this app can read, protected until the
/// watch is first unlocked, so pairing still holds.
enum Keychain {
    private static let service = "Ember"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data {
            return String(data: data, encoding: .utf8)
        }
        return Locked.read()[account]
    }

    /// Keep VALUE for ACCOUNT, or forget it when VALUE is empty. Whether it
    /// was kept.
    @discardableResult
    static func write(_ value: String?, for account: String) -> Bool {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(item as CFDictionary)
        var kept = Locked.read()
        if kept.removeValue(forKey: account) != nil { Locked.write(kept) }
        guard let value, !value.isEmpty else { return true }

        var adding = item
        adding[kSecValueData as String] = Data(value.utf8)
        // Readable while the watch is locked on the wrist, so it can sync
        // in the background; never copied to another device.
        adding[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(adding as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecMissingEntitlement else { return false }
        kept[account] = value
        return Locked.write(kept)
    }

    /// The file used when the Keychain can't be.
    private enum Locked {
        static var url: URL {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return support.appendingPathComponent("server.json")
        }

        static func read() -> [String: String] {
            guard let data = try? Data(contentsOf: url),
                  let found = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return found
        }

        @discardableResult
        static func write(_ values: [String: String]) -> Bool {
            do {
                if values.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                    return true
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(values).write(
                    to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                return false
            }
        }
    }
}
