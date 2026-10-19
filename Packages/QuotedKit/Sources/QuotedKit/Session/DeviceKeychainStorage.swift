import Foundation
import Security
import Supabase

/// Keeps the Supabase session in the Keychain, readable only on this device and only after its
/// first unlock (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
///
/// The SDK's `KeychainLocalStorage` writes `kSecAttrAccessibleAfterFirstUnlock`, which an encrypted
/// backup carries to another device. This storage uses the same service (`supabase.gotrue.swift`)
/// and account (the storage key), so a session saved by an earlier build is still found, and its
/// next write (every token refresh) converts it to this-device-only.
///
/// Keychain items survive deleting the app. The app clears them on the first launch after an
/// install with ``AuthService/clearLocalSession()``.
struct DeviceKeychainStorage: AuthLocalStorage {
    /// The SDK's default Keychain service name.
    static let defaultService = "supabase.gotrue.swift"

    let service: String

    init(service: String = DeviceKeychainStorage.defaultService) {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        let query = itemQuery(key: key)
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return try Self.check(status) }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        try Self.check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
    }

    func retrieve(key: String) throws -> Data? {
        var query = itemQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(itemQuery(key: key) as CFDictionary)
        if status == errSecItemNotFound { return }
        try Self.check(status)
    }

    /// Deletes every item of this service: the session and PKCE verifier for any project URL, and
    /// keys left by older SDK versions.
    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // iOS deletes every match at once; the file-based macOS keychain deletes one per call.
        for _ in 0..<64 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            try Self.check(status)
        }
    }

    private func itemQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainStatusError(status: status) }
    }
}

/// A failed Keychain call.
struct KeychainStatusError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}
