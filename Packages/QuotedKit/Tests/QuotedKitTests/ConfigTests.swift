import Foundation
import Testing
@testable import QuotedKit

@Suite("SupabaseConfig")
struct ConfigTests {
    @Test func readsInfoDictionary() throws {
        let config = try SupabaseConfig.fromInfoDictionary([
            "SupabaseURL": " http://127.0.0.1:54321 ",
            "SupabasePublishableKey": "sb_publishable_abc",
        ])
        #expect(config.url == URL(string: "http://127.0.0.1:54321"))
        #expect(config.publishableKey == "sb_publishable_abc")
    }

    @Test(arguments: [
        ([String: String](), SupabaseConfigError.missing("SupabaseURL")),
        (["SupabaseURL": "", "SupabasePublishableKey": "k"], .missing("SupabaseURL")),
        (["SupabaseURL": "$(SUPABASE_URL)", "SupabasePublishableKey": "k"], .missing("SupabaseURL")),
        (["SupabaseURL": "https://x.supabase.co"], .missing("SupabasePublishableKey")),
        (["SupabaseURL": "https://x.supabase.co", "SupabasePublishableKey": "$(SUPABASE_PUBLISHABLE_KEY)"], .missing("SupabasePublishableKey")),
        (["SupabaseURL": "x.supabase.co", "SupabasePublishableKey": "k"], .invalidURL("x.supabase.co")),
        (["SupabaseURL": "ftp://x.supabase.co", "SupabasePublishableKey": "k"], .invalidURL("ftp://x.supabase.co")),
        (["SupabaseURL": "https://x.supabase.co", "SupabasePublishableKey": "sb_secret_abc"], .secretKeyInClient),
    ])
    func rejectsBadValues(info: [String: String], expected: SupabaseConfigError) {
        #expect(throws: expected) { try SupabaseConfig.fromInfoDictionary(info) }
        #expect(expected.errorDescription?.isEmpty == false)
    }

    @Test func missingInfoDictionary() {
        #expect(throws: SupabaseConfigError.missing("SupabaseURL")) { try SupabaseConfig.fromInfoDictionary(nil) }
    }

    @Test func backendBuildsWithoutNetwork() {
        let backend = Backend(
            config: SupabaseConfig(url: URL(string: "http://127.0.0.1:54321")!, publishableKey: "sb_publishable_test"),
            sessionPersistence: .inMemory
        )
        #expect(backend.auth.currentUserID == nil)
        #expect(backend.config.publishableKey == "sb_publishable_test")
    }

    @Test func sessionStorageKeyMatchesTheSDKDefault() {
        #expect(Backend.sessionStorageKey(for: URL(string: "http://127.0.0.1:54321")!) == "sb-127-auth-token")
        #expect(Backend.sessionStorageKey(for: URL(string: "https://abcdefgh.supabase.co")!) == "sb-abcdefgh-auth-token")
    }

    @Test func urlSessionNeverCaches() throws {
        let configuration = Backend.makeURLSessionConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        // Stalled requests fail within seconds, not after URLSession's 60 s and 7 days.
        #expect(configuration.timeoutIntervalForRequest == Backend.requestTimeout)
        #expect(configuration.timeoutIntervalForResource == Backend.resourceTimeout)
        #expect(Backend.requestTimeout <= 20 && Backend.resourceTimeout <= 60)
    }

    @Test func purgeHTTPCachesEmptiesTheSharedCache() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:54321/rest/v1/quotes?purge-test=\(UUID().uuidString)"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data("[]".utf8)), for: request)
        #expect(URLCache.shared.cachedResponse(for: request) != nil)
        Backend.purgeHTTPCaches()
        // URLCache finishes the removal in the background.
        for _ in 0..<60 where URLCache.shared.cachedResponse(for: request) != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(URLCache.shared.cachedResponse(for: request) == nil)
    }
}
