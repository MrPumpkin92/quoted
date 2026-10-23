import Foundation
import QuotedCore
import Testing
@testable import QuotedKit

/// Decoding sample PostgREST responses with the decoder the backend uses (``QuotedJSON``).
@Suite("PostgREST row decoding")
struct DecodingTests {
    static let alice = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    static let bob = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try QuotedJSON.makeDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func quotesWithTimestampsFormatsAndNulls() throws {
        let json = """
        [
          {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a01","body":"Hello world","body_format":[{"start":0,"length":5,"bold":true}],
           "author":"Ada","source":null,"origin":"manual","rotation_position":0,
           "created_at":"2026-10-19T03:26:38.123456+00:00","updated_at":"2026-10-19T03:27:00+00:00"},
          {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a02","body":"Bad runs","body_format":[{"start":"x"},{"start":4,"length":99,"italic":true}],
           "author":null,"source":null,"origin":"from-the-future","rotation_position":null,
           "created_at":"2026-10-19 03:26:38+00","updated_at":"2026-10-19 03:26:38+00"}
        ]
        """
        let quotes = try decode([Quote].self, json)
        #expect(quotes.count == 2)
        #expect(quotes[0].format == [TextRun(start: 0, length: 5, bold: true)])
        #expect(quotes[0].rotationPosition == 0)
        #expect(quotes[0].author == "Ada")
        #expect(quotes[0].source == nil)
        #expect(quotes[0].updatedAt > quotes[0].createdAt)
        // A malformed run is skipped and the rest is clamped to the body; unknown origins read as manual.
        #expect(quotes[1].format == [TextRun(start: 4, length: 4, italic: true)])
        #expect(quotes[1].origin == .manual)
        #expect(quotes[1].isInRotation == false)
    }

    @Test func friendshipWithEmbeddedProfiles() throws {
        let json = """
        [{"id":"f0000000-0000-4000-8000-000000000001","requester_id":"\(Self.alice)","addressee_id":"\(Self.bob)",
          "status":"pending","created_at":"2026-10-19T03:00:00+00:00","responded_at":null,
          "requester":{"id":"\(Self.alice)","username":"alice","display_name":"Alice A."},
          "addressee":{"id":"\(Self.bob)","username":"bob","display_name":null}}]
        """
        let rows = try decode([Friendship].self, json)
        let asBob = SocialRepository.decorate(rows[0], me: Self.bob)
        #expect(asBob.otherParty == Profile(id: Self.alice, username: "alice", displayName: "Alice A."))
        #expect(asBob.isIncomingRequest(for: Self.bob))
        let asAlice = SocialRepository.decorate(rows[0], me: Self.alice)
        #expect(asAlice.otherParty?.username == "bob")
        // A null display name falls back to the username.
        #expect(asAlice.otherParty?.displayName == "bob")
        #expect(asAlice.isOutgoingRequest(for: Self.alice))
    }

    @Test func acceptedFriendshipWithoutEmbedIDs() throws {
        let json = """
        {"id":"f0000000-0000-4000-8000-000000000002","requester_id":"\(Self.alice)","addressee_id":"\(Self.bob)",
         "status":"accepted","created_at":"2026-10-19T03:00:00Z","responded_at":"2026-10-19T04:00:00Z",
         "requester":{"username":"alice","display_name":"Alice"},"addressee":{"username":"bob","display_name":"Bob"}}
        """
        let friendship = SocialRepository.decorate(try decode(Friendship.self, json), me: Self.alice)
        #expect(friendship.status == .accepted)
        #expect(friendship.respondedAt != nil)
        // The embed's missing id comes from the foreign key.
        #expect(friendship.otherParty?.id == Self.bob)
    }

    @Test func inboxShareWithSenderEmbed() throws {
        let json = """
        [{"id":"5e000000-0000-4000-8000-000000000001","sender_id":"\(Self.alice)","recipient_id":"\(Self.bob)",
          "quote_id":null,"body":"Be bold","body_format":[{"start":3,"length":4,"bold":true,"underline":true}],
          "author":"Anon","source":null,"note":"for you","created_at":"2026-10-19T05:00:00.5+00:00",
          "seen_at":null,"saved_at":"2026-10-19T06:00:00+00:00",
          "sender":{"id":"\(Self.alice)","username":"alice","display_name":"Alice"}}]
        """
        let shares = try decode([SharedQuote].self, json)
        let share = try #require(shares.first)
        #expect(share.sender?.handle == "@alice")
        #expect(share.recipient == nil)
        #expect(share.format == [TextRun(start: 3, length: 4, bold: true, underline: true)])
        #expect(share.note == "for you")
        #expect(!share.isSeen)
        #expect(share.isSaved)
    }

    @Test func malformedEmbedDoesNotFailTheRow() throws {
        let json = """
        {"id":"5e000000-0000-4000-8000-000000000002","sender_id":"\(Self.alice)","recipient_id":"\(Self.bob)",
         "quote_id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a01","body":"Hi","body_format":[],"author":null,"source":null,"note":null,
         "created_at":"2026-10-19T05:00:00Z","seen_at":null,"saved_at":null,"recipient":{"oops":true}}
        """
        let share = try decode(SharedQuote.self, json)
        #expect(share.recipient == nil)
        #expect(share.quoteID != nil)
    }

    @Test func starterQuotes() throws {
        let json = """
        [{"id":1,"body":"Trust thyself.","body_format":[],"author":"Ralph Waldo Emerson","source":"Self-Reliance","sort_order":1},
         {"id":2,"body":"Hope","body_format":[{"start":0,"length":4,"italic":true}],"author":"Emily Dickinson","source":null,"sort_order":2}]
        """
        let starters = try decode([StarterQuote].self, json)
        #expect(starters.map(\.sortOrder) == [1, 2])
        #expect(starters[1].format.first?.italic == true)
        #expect(starters[0].attribution == "Ralph Waldo Emerson, Self-Reliance")
    }

    @Test func profilesAndBlocks() throws {
        let profile = try decode(Profile?.self, #"{"id":"\#(Self.alice)","username":"alice","display_name":"Alice"}"#)
        #expect(profile?.username == "alice")
        #expect(try decode(Profile?.self, "null") == nil)

        let blocks = try decode([BlockedRow].self, """
        [{"blocked_id":"\(Self.bob)","blocked":{"id":"\(Self.bob)","username":"bob","display_name":null}},
         {"blocked_id":"\(Self.alice)"}]
        """)
        #expect(blocks.map(\.blockedID) == [Self.bob, Self.alice])
        #expect(blocks[0].blocked?.username == "bob")
        #expect(blocks[1].blocked == nil)
    }

    @Test func partialRows() throws {
        let rows = try decode([RotationPositionRow].self, #"[{"rotation_position":7},{"rotation_position":null}]"#)
        #expect(rows.map(\.rotationPosition) == [7, nil])
    }
}

/// Request payloads: snake_case keys and explicit nulls.
@Suite("Request payloads")
struct PayloadTests {
    func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try QuotedJSON.makeEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func isNull(_ value: Any?) -> Bool { value is NSNull }

    @Test func quoteInsertWritesExplicitNulls() throws {
        let validated = try QuoteDraft(body: "  Hello  ", format: [TextRun(start: 2, length: 5, bold: true)]).validated()
        let json = try object(QuoteInsert(validated, id: UUID(), origin: .pasted, rotationPosition: nil))
        #expect(json["body"] as? String == "Hello")
        #expect(isNull(json["author"]))
        #expect(isNull(json["source"]))
        #expect(isNull(json["rotation_position"]))
        #expect(json["origin"] as? String == "pasted")
        let runs = try #require(json["body_format"] as? [[String: Any]])
        // Trimming the two leading spaces shifts the run back to 0.
        #expect(runs.first?["start"] as? Int == 0)
        #expect(runs.first?["length"] as? Int == 5)
        #expect(runs.first?["bold"] as? Bool == true)
        #expect(runs.first?["italic"] == nil)
        #expect(Set(json.keys) == ["id", "body", "body_format", "author", "source", "origin", "rotation_position"])
    }

    @Test func contentUpdateCanClearAuthorAndNeverTouchesRotation() throws {
        let quote = Quote(body: "Body", author: "", source: "Book", rotationPosition: 3)
        let json = try object(QuoteContentUpdate(try QuoteDraft(quote: quote).validated()))
        #expect(isNull(json["author"]))
        #expect(json["source"] as? String == "Book")
        #expect(json["rotation_position"] == nil)
        #expect(json["owner_id"] == nil)
    }

    @Test func setRotationParamsDropRepeatsAndKeepOrderedOverRemoved() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let params = SetRotationParams(ordered: [c, a, c], removing: [b, a, d, b])
        #expect(params.ordered == [c, a])
        #expect(params.removed == [b, d])
        #expect(!params.isEmpty)
        #expect(SetRotationParams(ordered: [], removing: []).isEmpty)

        let json = try object(params)
        #expect(Set(json.keys) == ["ordered", "removed"])
        #expect((json["ordered"] as? [String])?.map { $0.lowercased() } == [c, a].map { $0.uuidString.lowercased() })
        #expect((json["removed"] as? [String])?.map { $0.lowercased() } == [b, d].map { $0.uuidString.lowercased() })
    }

    @Test func restoreRowKeepsIdentityAndLeavesTimestampsToTheServer() throws {
        let quote = Quote(body: " Back ", author: "", source: "Notes", origin: .shared, rotationPosition: 4)
        let json = try object(QuoteRestoreRow(quote, content: try QuoteDraft(quote: quote).validated()))
        #expect(Set(json.keys) == ["id", "body", "body_format", "author", "source", "origin", "rotation_position"])
        #expect(json["id"] as? String == quote.id.uuidString)
        #expect(json["body"] as? String == "Back")
        #expect(isNull(json["author"]))
        #expect(json["origin"] as? String == "shared")
        #expect(json["rotation_position"] as? Int == 4)
    }

    @Test func shareProfileReportAndEventPayloads() throws {
        let share = try object(ShareInsert(id: UUID(), recipientID: UUID(), quoteID: nil, body: "b", format: [], author: nil, source: "s", note: nil))
        #expect(Set(share.keys) == ["id", "recipient_id", "quote_id", "body", "body_format", "author", "source", "note"])
        #expect(isNull(share["quote_id"]) && isNull(share["note"]))
        #expect(share["sender_id"] == nil)

        let profile = try object(ProfileInsert(id: UUID(), username: "ada", displayName: nil))
        #expect(isNull(profile["display_name"]))

        let report = try object(ReportInsert(shareID: nil, reportedUserID: UUID(), reason: .harassment, details: nil))
        #expect(report["reason"] as? String == "harassment")
        #expect(isNull(report["share_id"]))
        #expect(report["reporter_id"] == nil)

        #expect(try object(EventInsert.webSearchTap) as NSDictionary == ["name": "web_search_tap"])
        #expect(try object(FriendshipStatusUpdate(status: .accepted)) as NSDictionary == ["status": "accepted"])
        #expect(try object(FriendRequestInsert(addresseeID: DecodingTests.bob))["addressee_id"] as? String
            == DecodingTests.bob.uuidString)
    }

    @Test func timestampsUsePostgresFormat() throws {
        let date = Date(timeIntervalSince1970: 1_792_380_398.25)
        let json = try object(ShareSeenUpdate(seenAt: date))
        let text = try #require(json["seen_at"] as? String)
        #expect(text.hasSuffix("Z"))
        #expect(Timestamp.date(from: text) == date)
    }
}
