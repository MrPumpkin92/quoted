import Foundation
import QuotedCore
import Supabase
import Testing
@testable import QuotedKit

/// Reports carry a copy of the reported content (`reports.content_*`), because a block deletes the
/// share and `share_id` becomes null. See `supabase/migrations/20261019050000_report_snapshot.sql`.
@Suite("Report snapshot")
struct ReportSnapshotTests {
    static let me = StubServer.userID
    static let friend = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let reportKeys: Set<String> = [
        "share_id", "reported_user_id", "reason", "details", "content_body", "content_author", "content_source",
    ]

    static func share(body: String = "Be kind.", author: String? = "Ann", source: String? = "Notebook") -> SharedQuote {
        SharedQuote(id: UUID(), senderID: friend, recipientID: me, body: body, author: author, source: source, createdAt: Date())
    }

    func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try QuotedJSON.makeEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Payload

    @Test func shareReportPayloadCarriesTheShareContent() throws {
        let share = Self.share()
        let json = try object(ReportInsert(share: share, reason: .harassment, details: nil))
        #expect(Set(json.keys) == Self.reportKeys)
        #expect(json["share_id"] as? String == share.id.uuidString)
        #expect(json["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(json["content_body"] as? String == "Be kind.")
        #expect(json["content_author"] as? String == "Ann")
        #expect(json["content_source"] as? String == "Notebook")
        #expect(json["reporter_id"] == nil)
    }

    @Test func userReportPayloadHasAnEmptySnapshot() throws {
        let json = try object(ReportInsert(shareID: nil, reportedUserID: Self.friend, reason: .other, details: nil))
        #expect(Set(json.keys) == Self.reportKeys)
        #expect(json["content_body"] is NSNull)
        #expect(json["content_author"] is NSNull)
        #expect(json["content_source"] is NSNull)
    }

    @Test func snapshotIsCutToTheColumnLimitInUnicodeScalars() throws {
        #expect(ReportInsert.snapshot(nil, maxLength: 10) == nil)
        #expect(ReportInsert.snapshot("short", maxLength: 10) == "short")
        #expect(ReportInsert.snapshot("exactly 10", maxLength: 10) == "exactly 10")
        // 👍🏽 is two scalars (the thumb and a skin-tone modifier), like Postgres char_length counts it.
        let long = String(repeating: "a", count: 1999) + "👍🏽"
        let cut = try #require(ReportInsert.snapshot(long, maxLength: Limits.bodyLength.upperBound))
        #expect(cut.unicodeScalars.count == 2000)
        #expect(cut.hasSuffix("a👍"))
    }

    @Test func oversizedShareContentIsCutBeforeSending() throws {
        let share = Self.share(
            body: String(repeating: "b", count: 2100),
            author: String(repeating: "c", count: 250),
            source: String(repeating: "d", count: 250)
        )
        let json = try object(ReportInsert(share: share, reason: .spam, details: nil))
        #expect((json["content_body"] as? String)?.unicodeScalars.count == Limits.bodyLength.upperBound)
        #expect((json["content_author"] as? String)?.unicodeScalars.count == Limits.authorMaxLength)
        #expect((json["content_source"] as? String)?.unicodeScalars.count == Limits.sourceMaxLength)
    }

    // MARK: Requests

    @Test func reportingAShareSendsItsContent() async throws {
        let server = StubServer { _ in .json(201, "") }
        let backend = try await server.makeSignedInBackend()
        let share = Self.share(author: nil)
        try await backend.social.report(share: share, reason: .inappropriate, details: " Not okay ")

        let request = try #require(server.requests(table: "reports").first)
        #expect(request.method == "POST")
        #expect(request.header("Prefer") == "return=minimal")
        let body = try #require(request.json as? [String: Any])
        #expect(Set(body.keys) == Self.reportKeys)
        #expect(body["share_id"] as? String == share.id.uuidString)
        #expect(body["content_body"] as? String == "Be kind.")
        #expect(body["content_author"] is NSNull)
        #expect(body["content_source"] as? String == "Notebook")
        #expect(body["details"] as? String == "Not okay")
    }

    @Test func fallbackForADeletedShareKeepsTheSnapshot() async throws {
        let server = StubServer { request in
            let body = request.json as? [String: Any]
            if body?["share_id"] is String {
                return .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"reports\""}"#)
            }
            return .json(201, "")
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.report(share: Self.share(), reason: .spam)

        let requests = server.requests(table: "reports")
        #expect(requests.count == 2)
        let retry = try #require(requests.last?.json as? [String: Any])
        #expect(retry["share_id"] is NSNull)
        #expect(retry["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(retry["content_body"] as? String == "Be kind.")
        #expect(retry["content_author"] as? String == "Ann")
        #expect(retry["content_source"] as? String == "Notebook")
    }

    @Test func reportingAUserSendsNoSnapshot() async throws {
        let server = StubServer { _ in .json(201, "") }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.report(userID: Self.friend, reason: .other)

        let body = try #require(server.requests(table: "reports").first?.json as? [String: Any])
        #expect(body["share_id"] is NSNull)
        #expect(body["content_body"] is NSNull)
        #expect(body["content_author"] is NSNull)
        #expect(body["content_source"] is NSNull)
    }
}

/// The snapshot against the local stack: the server copies it from the share (ignoring what the
/// client sent) and it survives the block that deletes the share. Runs only with
/// `QUOTED_LOCAL_SUPABASE=1 swift test`.
@Suite(
    "Report snapshot on the local stack",
    .enabled(if: LocalStack.isEnabled, "Set QUOTED_LOCAL_SUPABASE=1 with `supabase start` running"),
    .serialized
)
struct ReportSnapshotLocalStackTests {
    /// A `reports` row as its reporter reads it back.
    struct StoredReport: Decodable, Equatable {
        var shareID: UUID?
        var reason: ReportReason
        var contentBody: String?
        var contentAuthor: String?
        var contentSource: String?

        enum CodingKeys: String, CodingKey {
            case shareID = "share_id"
            case reason
            case contentBody = "content_body"
            case contentAuthor = "content_author"
            case contentSource = "content_source"
        }
    }

    static func reports(of user: TestUser) async throws -> [StoredReport] {
        try await user.backend.client.from(Table.reports)
            .select("share_id, reason, content_body, content_author, content_source")
            .order("created_at")
            .execute()
            .value
    }

    @Test func snapshotSurvivesTheBlock() async throws {
        let alice = try await TestUser.signUp("snapa")
        let bob: TestUser
        do {
            bob = try await TestUser.signUp("snapb")
        } catch {
            await LocalStack.cleanUp([alice])
            throw error
        }
        do {
            try await scenario(alice: alice, bob: bob)
        } catch {
            await LocalStack.cleanUp([alice, bob])
            throw error
        }
        await LocalStack.cleanUp([alice, bob])
    }

    private func scenario(alice: TestUser, bob: TestUser) async throws {
        _ = try await alice.social.createProfile(username: alice.username)
        _ = try await bob.social.createProfile(username: bob.username)
        let request = try await alice.social.sendFriendRequest(toUsername: bob.username)
        _ = try await bob.social.accept(friendshipID: request.id)

        let quote = try await alice.quotes.create(QuoteDraft(body: "Reported words", author: "Ann", source: "Notebook"))
        _ = try await alice.social.share(quote, to: [bob.id])
        let received = try #require(try await bob.social.inbox().first)

        // A tampered copy: the server takes the content from the share, not from the client.
        var tampered = received
        tampered.body = "Something alice never sent"
        tampered.author = "Mallory"
        tampered.source = nil
        try await bob.social.report(share: tampered, reason: .spam, details: "QuotedKit snapshot test")

        var stored = try await Self.reports(of: bob)
        #expect(stored == [
            StoredReport(shareID: received.id, reason: .spam, contentBody: "Reported words", contentAuthor: "Ann", contentSource: "Notebook"),
        ])

        // The block deletes the share. The report loses share_id but keeps the content.
        try await bob.social.block(userID: alice.id)
        #expect(try await bob.social.inbox().isEmpty)

        // Reporting after the block falls back to a user report that carries the app's copy.
        try await bob.social.report(share: received, reason: .harassment)

        stored = try await Self.reports(of: bob)
        #expect(stored == [
            StoredReport(shareID: nil, reason: .spam, contentBody: "Reported words", contentAuthor: "Ann", contentSource: "Notebook"),
            StoredReport(shareID: nil, reason: .harassment, contentBody: "Reported words", contentAuthor: "Ann", contentSource: "Notebook"),
        ])

        // The reported user never sees the reports or their snapshots.
        #expect(try await Self.reports(of: alice).isEmpty)
    }
}
