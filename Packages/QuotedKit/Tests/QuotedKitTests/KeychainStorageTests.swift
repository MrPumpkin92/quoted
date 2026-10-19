import Foundation
import Testing
@testable import QuotedKit

/// `DeviceKeychainStorage` against the real Keychain, under a throwaway service name.
@Suite("Device Keychain storage", .serialized)
struct KeychainStorageTests {
    let storage = DeviceKeychainStorage(service: "com.hwei.quoted.tests.\(UUID().uuidString)")

    @Test func storesReadsReplacesAndRemoves() throws {
        defer { try? storage.removeAll() }
        #expect(try storage.retrieve(key: "session") == nil)
        try storage.remove(key: "session") // removing nothing succeeds

        try storage.store(key: "session", value: Data("one".utf8))
        #expect(try storage.retrieve(key: "session") == Data("one".utf8))
        try storage.store(key: "session", value: Data("two".utf8))
        #expect(try storage.retrieve(key: "session") == Data("two".utf8))

        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
    }

    @Test func removeAllClearsEveryKeyOfTheService() throws {
        let other = DeviceKeychainStorage(service: "com.hwei.quoted.tests.other.\(UUID().uuidString)")
        defer {
            try? storage.removeAll()
            try? other.removeAll()
        }
        for key in ["sb-a-auth-token", "sb-a-auth-token-code-verifier", "supabase.session"] {
            try storage.store(key: key, value: Data(key.utf8))
        }
        try other.store(key: "sb-a-auth-token", value: Data("keep".utf8))

        try storage.removeAll()
        for key in ["sb-a-auth-token", "sb-a-auth-token-code-verifier", "supabase.session"] {
            #expect(try storage.retrieve(key: key) == nil)
        }
        #expect(try other.retrieve(key: "sb-a-auth-token") == Data("keep".utf8), "other services are untouched")
        try storage.removeAll() // nothing left: still succeeds
    }
}
