import Foundation
import QuotedCore
import Supabase
import Testing
@testable import QuotedKit

/// Reports name a target (post, message, playlist or catalog quote) and the person it is about; the
/// server copies the content from its own row (`reports_snapshot_target`, migration
/// `20261029090300_conversations_and_messages`). When the target is gone the app files a profile
/// report carrying what it showed.
@Suite("Report snapshot")
struct ReportSnapshotTests {
    static let me = StubServer.userID
    static let friend = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let reportKeys: Set<String> = [
        "reported_user_id", "reason", "details", "post_id", "message_id", "playlist_id", "starter_quote_id",
        "content_body", "content_author", "content_source", "content_note",
    ]

    func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try QuotedJSON.makeEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Payload

    @Test func targetedReportsNameTheTargetAndNoContent() throws {
        let messageID = UUID()
        let json = try object(ReportInsert(target: .message(id: messageID, senderID: Self.friend), reason: .harassment, details: nil))
        #expect(Set(json.keys) == Self.reportKeys)
        #expect(json["message_id"] as? String == messageID.uuidString)
        #expect(json["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(json["post_id"] is NSNull && json["playlist_id"] is NSNull && json["starter_quote_id"] is NSNull)
        #expect(json["content_body"] is NSNull, "the server takes its own copy")
        #expect(json["reporter_id"] == nil && json["target_kind"] == nil, "server-owned")

        let catalog = try object(ReportInsert(target: .catalogQuote(7), reason: .wrongWording, details: nil))
        #expect(catalog["starter_quote_id"] as? Int == 7)
        #expect(catalog["reported_user_id"] is NSNull, "a catalog report names nobody")
        #expect(catalog["reason"] as? String == "wrong_wording")

        let playlist = try object(ReportInsert(target: .playlist(id: messageID, ownerID: Self.friend), reason: .copyright, details: "x"))
        #expect(playlist["playlist_id"] as? String == messageID.uuidString)
        #expect(playlist["reason"] as? String == "copyright")
    }

    @Test func profileReportCarriesWhatTheReporterSaw() throws {
        let json = try object(ReportInsert(
            userID: Self.friend, reason: .spam, details: nil,
            content: ReportContent(body: "Be kind.", author: "Ann", source: nil, note: "for you")
        ))
        #expect(Set(json.keys) == Self.reportKeys)
        #expect(json["content_body"] as? String == "Be kind.")
        #expect(json["content_author"] as? String == "Ann")
        #expect(json["content_source"] is NSNull)
        #expect(json["content_note"] as? String == "for you")
        #expect(json["message_id"] is NSNull)

        let bare = try object(ReportInsert(userID: Self.friend, reason: .other, details: nil, content: nil))
        #expect(bare["content_body"] is NSNull && bare["content_note"] is NSNull)
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

        let json = try object(ReportInsert(
            userID: Self.friend, reason: .spam, details: nil,
            content: ReportContent(
                body: String(repeating: "b", count: 2100), author: String(repeating: "c", count: 250),
                source: String(repeating: "d", count: 250), note: String(repeating: "n", count: 1200)
            )
        ))
        #expect((json["content_body"] as? String)?.unicodeScalars.count == Limits.bodyLength.upperBound)
        #expect((json["content_author"] as? String)?.unicodeScalars.count == Limits.authorMaxLength)
        #expect((json["content_source"] as? String)?.unicodeScalars.count == Limits.sourceMaxLength)
        #expect((json["content_note"] as? String)?.unicodeScalars.count == ReportInsert.contentNoteMaxLength)
    }

    // MARK: Requests

    @Test func reportingAPostSendsItsIDOnly() async throws {
        let server = StubServer { _ in .json(201, "") }
        let backend = try await server.makeSignedInBackend()
        let postID = UUID()
        try await backend.reports.report(.post(id: postID, posterID: Self.friend), reason: .inappropriate, details: " Not okay ")

        let request = try #require(server.requests(table: "reports").first)
        #expect(request.method == "POST")
        #expect(request.header("Prefer") == "return=minimal")
        let body = try #require(request.json as? [String: Any])
        #expect(Set(body.keys) == Self.reportKeys)
        #expect(body["post_id"] as? String == postID.uuidString)
        #expect(body["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(body["details"] as? String == "Not okay")
        #expect(body["content_body"] is NSNull)
    }

    @Test func aGoneTargetFallsBackToAProfileReportWithWhatWasSeen() async throws {
        let server = StubServer { request in
            if request.method == "GET" { return .json(200, "[]") }
            let body = request.json as? [String: Any]
            if body?["message_id"] is String {
                return .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"reports\""}"#)
            }
            return .json(201, "")
        }
        let backend = try await server.makeSignedInBackend()
        let seen = ReportContent(body: "Be kind.", author: "Ann", source: "Notebook", note: "hi")
        let messageID = UUID()
        try await backend.reports.report(.message(id: messageID, senderID: Self.friend), reason: .spam, seen: seen)

        // First: did you already report it? (Your own reports, by that message.)
        let check = try #require(server.requests(table: "reports").first { $0.method == "GET" })
        #expect(check.query["reporter_id"] == "eq.\(Self.me.uuidString)")
        #expect(check.query["message_id"] == "eq.\(messageID.uuidString)")
        let requests = server.requests(table: "reports").filter { $0.method == "POST" }
        #expect(requests.count == 2)
        let retry = try #require(requests.last?.json as? [String: Any])
        #expect(retry["message_id"] is NSNull)
        #expect(retry["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(retry["content_body"] as? String == "Be kind.")
        #expect(retry["content_note"] as? String == "hi")
    }

    @Test func aPostYouAlreadyReportedIsNotReportedAgainAsItsPoster() async throws {
        // You no longer see a post you reported, so a second report (or the retry of one whose answer
        // was lost) is refused like a gone post. Your report of it stands: no profile report follows.
        let postID = UUID()
        let server = StubServer { request in
            request.method == "GET"
                ? .json(200, #"[{"id":"\#(UUID())"}]"#)
                : .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"reports\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.reports.report(.post(id: postID, posterID: Self.friend), reason: .spam, seen: ReportContent(body: "Words"))
        let requests = server.requests(table: "reports")
        #expect(requests.map(\.method) == ["POST", "GET"])
        #expect(requests.last?.query["post_id"] == "eq.\(postID.uuidString)")
    }

    @Test func catalogAndProfileReportsHaveNothingToFallBackTo() async throws {
        let server = StubServer { _ in
            .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"reports\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.self) {
            try await backend.reports.report(.catalogQuote(3), reason: .wrongWording)
        }
        #expect(server.requests(table: "reports").count == 1)
    }

    @Test func duplicatesSucceedAndBadReportsNeverLeave() async throws {
        let server = StubServer { _ in
            .json(409, #"{"code":"23505","message":"duplicate key value violates unique constraint \"reports_reporter_reported_target_key\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.reports.report(.profile(userID: Self.friend), reason: .other)
        #expect(server.requests(table: "reports").count == 1)

        await #expect(throws: QuotedError.validation("You can't report yourself.")) {
            try await backend.reports.report(.profile(userID: Self.me), reason: .spam)
        }
        await #expect(throws: QuotedError.validation("Wrong wording is only for Quoted Catalog quotes.")) {
            try await backend.reports.report(.post(id: UUID(), posterID: Self.friend), reason: .wrongWording)
        }
        await #expect(throws: QuotedError.validation("Details can be at most 500 characters.")) {
            try await backend.reports.report(.profile(userID: Self.friend), reason: .other, details: String(repeating: "x", count: 501))
        }
        #expect(server.requests(table: "reports").count == 1)
    }
}

/// Reports against the local stack: the server copies the content (ignoring what the client sent),
/// the reporter reads back only what they filed, the reported message disappears for its reporter,
/// and an unsent message still reports its sender. Runs only with `QUOTED_LOCAL_SUPABASE=1`.
@Suite(
    "Report snapshot on the local stack",
    .enabled(if: LocalStack.isEnabled, "Set QUOTED_LOCAL_SUPABASE=1 with `supabase start` running"),
    .serialized
)
struct ReportSnapshotLocalStackTests {
    /// A `reports` row as its reporter may read it back (the column grant).
    struct FiledReport: Decodable, Equatable {
        var reportedUserID: UUID?
        var reason: ReportReason
        var messageID: UUID?
        var starterQuoteID: Int?
        var targetKind: String

        enum CodingKeys: String, CodingKey {
            case reportedUserID = "reported_user_id"
            case reason
            case messageID = "message_id"
            case starterQuoteID = "starter_quote_id"
            case targetKind = "target_kind"
        }
    }

    static func reports(of user: TestUser) async throws -> [FiledReport] {
        try await user.backend.client.from(Table.reports)
            .select(Columns.filedReport)
            .order("created_at")
            .execute()
            .value
    }

    @Test func reportersReadBackOnlyWhatTheyFiled() async throws {
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
        try await LocalStack.makeFriends(alice, bob)
        let conversation = try await alice.backend.messages.openConversation(with: bob.id)
        let quote = try await alice.quotes.create(QuoteDraft(body: "Reported words", author: "Ann", source: "Notebook"))
        let sent = try await alice.backend.messages.send(.quote(.quote(quote.id), note: "for you"), in: conversation.id)

        // The client's copy is ignored for a message that exists: the server copies its own.
        try await bob.backend.reports.report(
            .message(id: sent.id, senderID: alice.id), reason: .spam, details: "QuotedKit snapshot test",
            seen: ReportContent(body: "Something alice never sent", author: "Mallory")
        )
        var filed = try await Self.reports(of: bob)
        #expect(filed == [FiledReport(reportedUserID: alice.id, reason: .spam, messageID: sent.id, targetKind: "message")])

        // The copy is the founder's evidence: the reporter can't read it back (no column grant).
        await #expect(throws: (any Error).self) {
            let _: [AnyJSON] = try await bob.backend.client.from(Table.reports)
                .select("content_body")
                .execute()
                .value
        }
        // A reported message disappears for its reporter at once, and not for its sender.
        #expect(try await bob.backend.messages.messages(in: conversation.id).isEmpty)
        #expect(try await alice.backend.messages.messages(in: conversation.id).map(\.id) == [sent.id])

        // Reporting again is harmless.
        try await bob.backend.reports.report(.message(id: sent.id, senderID: alice.id), reason: .spam)
        #expect(try await Self.reports(of: bob).count == 1)

        // An unsent message can no longer be reported as a message: the person is reported instead,
        // with what the app showed. A second unsent message is a second report, never a duplicate
        // of the first; the same one again is.
        let second = try await alice.backend.messages.send(.text("Second"), in: conversation.id)
        let third = try await alice.backend.messages.send(.text("Third"), in: conversation.id)
        try await alice.backend.messages.unsend(messageID: second.id)
        try await alice.backend.messages.unsend(messageID: third.id)
        for gone in [second, third, third] {
            try await bob.backend.reports.report(
                .message(id: gone.id, senderID: alice.id), reason: .harassment,
                seen: ReportContent(message: gone)
            )
        }
        // A post bob reported disappears for him: reporting it again (or a retry whose answer was
        // lost) files nothing more, and never a report about alice instead.
        let post = try await alice.backend.posts.create(PostDraft(source: .quote(quote.id)))
        for _ in 0..<2 {
            try await bob.backend.reports.report(.post(id: post.id, posterID: alice.id), reason: .spam, seen: ReportContent(post: post))
        }
        // A catalog quote names nobody.
        let catalog = try await bob.backend.starter.fetchAll()
        if let first = catalog.first {
            try await bob.backend.reports.report(.catalogQuote(first.id), reason: .wrongWording)
        }

        filed = try await Self.reports(of: bob)
        #expect(filed.map(\.targetKind) == ["message", "profile", "profile", "post"] + (catalog.isEmpty ? [] : ["catalog_quote"]))
        #expect(filed[1].reportedUserID == alice.id && filed[2].reportedUserID == alice.id)
        #expect(filed.last?.starterQuoteID == catalog.first?.id)

        // A block keeps the reports, and the reported user never sees them.
        try await bob.social.block(userID: alice.id)
        #expect(try await Self.reports(of: bob).count == filed.count)
        #expect(try await Self.reports(of: alice).isEmpty)
    }
}
