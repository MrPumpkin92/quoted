import Foundation
import QuotedCore
import Testing
@testable import QuotedKit

/// What the repositories actually send, against ``StubServer``.
@Suite("Repository requests")
struct RequestTests {
    static let me = StubServer.userID
    static let friend = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A `quotes` row. `inserted` gives it equal timestamps, as a row the statement just inserted has.
    static func quoteJSON(_ id: UUID, body: String = "Body", position: Int? = nil, origin: String = "manual", inserted: Bool = false) -> String {
        """
        {"id":"\(id)","body":"\(body)","body_format":[],"author":null,"source":null,"origin":"\(origin)",
         "rotation_position":\(position.map(String.init) ?? "null"),
         "created_at":"2026-10-19T03:00:00.123456+00:00",
         "updated_at":"\(inserted ? "2026-10-19T03:00:00.123456+00:00" : "2026-10-19T04:30:00.654321+00:00")"}
        """
    }

    static func shareJSON(_ id: UUID, sent: Bool = false) -> String {
        let other = #"{"id":"\#(friend)","username":"bob","display_name":null}"#
        return """
        {"id":"\(id)","sender_id":"\(sent ? me : friend)","recipient_id":"\(sent ? friend : me)","quote_id":null,"body":"B",
         "body_format":[],"author":null,"source":null,"note":null,"created_at":"2026-10-19T03:00:00Z","seen_at":null,
         "saved_at":null,"\(sent ? "recipient" : "sender")":\(other)}
        """
    }

    @Test func requiresASession() async throws {
        let server = StubServer { .notFound($0) }
        let backend = server.makeBackend()
        await #expect(throws: QuotedError.notSignedIn) { try await backend.quotes.fetchMine() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.social.inbox() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.account.deleteAccount() }
        #expect(await backend.events.logWebSearchTapAndWait() == false)
        #expect(server.requests.isEmpty)
    }

    @Test func signInStoresTheSessionAndSendsTheBearer() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/quotes" ? .json(200, "[]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        #expect(backend.auth.currentUserID == Self.me)
        _ = try await backend.quotes.fetchMine()
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.header("Authorization") == "Bearer \(StubServer.accessToken)")
        #expect(request.header("apikey") == StubServer.publishableKey)
    }

    @Test func fetchMineFiltersByOwnerNewestFirst() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/quotes" ? .json(200, "[\(Self.quoteJSON(id))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let quotes = try await backend.quotes.fetchMine()
        #expect(quotes.map(\.id) == [id])
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.method == "GET")
        #expect(request.query["owner_id"] == "eq.\(Self.me.uuidString)")
        #expect(request.query["order"] == "created_at.desc.nullslast,id.asc.nullslast")
        #expect(request.query["select"] == Columns.quote.replacingOccurrences(of: " ", with: ""))
        #expect(request.query["offset"] == "0")
        #expect(request.query["limit"] == "\(Paging.pageSize)")
        #expect(request.header("Prefer")?.contains("count=exact") == true)
    }

    @Test func fetchMineReadsEveryPagePastMaxRows() async throws {
        let ids = (0..<1_203).map { _ in UUID() }
        let server = StubServer { request in
            guard request.path == "/rest/v1/quotes" else { return .notFound(request) }
            let offset = Int(request.query["offset"] ?? "") ?? 0
            let limit = Int(request.query["limit"] ?? "") ?? 0
            let rows = ids.dropFirst(offset).prefix(limit).map { Self.quoteJSON($0) }
            return .page(Array(rows), offset: offset, total: ids.count)
        }
        let backend = try await server.makeSignedInBackend()
        let quotes = try await backend.quotes.fetchMine()
        #expect(quotes.map(\.id) == ids)
        #expect(server.requests(table: "quotes").map { $0.query["offset"] } == ["0", "500", "1000"])
    }

    @Test func pagingKeepsReadingWhenTheServerCapsPagesLower() async throws {
        // A server whose max_rows (100) is below the page size still returns every row.
        let ids = (0..<250).map { _ in UUID() }
        let server = StubServer { request in
            let offset = Int(request.query["offset"] ?? "") ?? 0
            let rows = ids.dropFirst(offset).prefix(100).map { Self.shareJSON($0) }
            return .page(Array(rows), offset: offset, total: ids.count)
        }
        let backend = try await server.makeSignedInBackend()
        let inbox = try await backend.social.inbox()
        #expect(inbox.map(\.id) == ids)
        #expect(server.requests(table: "shares").map { $0.query["offset"] } == ["0", "100", "200"])
        #expect(server.requests(table: "shares").allSatisfy { $0.query["recipient_id"] == "eq.\(Self.me.uuidString)" })
    }

    @Test func pagingDropsRowsRepeatedAcrossPages() async throws {
        // A row inserted at the top while reading shifts the last row of page 1 onto page 2.
        let ids = (0..<501).map { _ in UUID() }
        let server = StubServer { request in
            let offset = Int(request.query["offset"] ?? "") ?? 0
            let rows = offset == 0
                ? ids.prefix(500).map { Self.shareJSON($0, sent: true) }
                : [ids[499], ids[500]].map { Self.shareJSON($0, sent: true) }
            return .page(rows, offset: offset, total: offset == 0 ? 501 : 502)
        }
        let backend = try await server.makeSignedInBackend()
        let sent = try await backend.social.sent()
        #expect(sent.map(\.id) == ids)
        #expect(server.requests.count == 2)
    }

    @Test func createValidatesAndAsksForTheRow() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/quotes" ? .json(201, "[\(Self.quoteJSON(id, body: "Hello", origin: "pasted"))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()

        await #expect(throws: QuotedError.validation("Write the quote first.")) {
            try await backend.quotes.create(QuoteDraft(body: "   "))
        }
        #expect(server.requests.isEmpty)

        let quote = try await backend.quotes.create(QuoteDraft(body: " Hello ", author: "  "), id: id, origin: .pasted)
        #expect(quote.id == id)
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.method == "POST")
        #expect(request.header("Prefer")?.contains("return=representation") == true)
        let body = try #require(request.json as? [String: Any])
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["body"] as? String == "Hello")
        #expect(body["author"] is NSNull)
        #expect(body["origin"] as? String == "pasted")
        #expect(body["owner_id"] == nil)
    }

    @Test func createRetryAfterALostAnswerReturnsTheFirstInsert() async throws {
        // The first Save reached the server but its answer was lost; the retry with the same id hits
        // the primary key, and the repository reads that quote back instead of adding a copy.
        let id = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/quotes"):
                .json(409, #"{"code":"23505","details":"Key (id)=(\#(id.uuidString.lowercased())) already exists.","hint":null,"message":"duplicate key value violates unique constraint \"quotes_pkey\""}"#)
            case ("GET", "/rest/v1/quotes"):
                .json(200, "[\(Self.quoteJSON(id, body: "Hello", origin: "manual"))]")
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let quote = try await backend.quotes.create(QuoteDraft(body: "Hello"), id: id)
        #expect(quote.id == id)
        let read = try #require(server.requests.first { $0.method == "GET" })
        #expect(read.query["id"] == "in.(\(id.uuidString))")
    }

    @Test func createConflictOnAnotherKeyIsStillAnError() async throws {
        // A unique violation whose row is not ours (or not there) is a real conflict.
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/quotes"):
                .json(409, #"{"code":"23505","details":null,"hint":null,"message":"duplicate key value violates unique constraint \"quotes_owner_rotation_position_key\""}"#)
            case ("GET", "/rest/v1/quotes"): .json(200, "[]")
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.validation("That already exists.")) {
            try await backend.quotes.create(QuoteDraft(body: "Hello"))
        }
    }

    @Test func quoteCapAndDailyLimitsReadAsLimits() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/quotes"
                ? .json(400, #"{"code":"QR002","details":null,"hint":null,"message":"quote limit reached"}"#)
                : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.validation("You've reached the limit of \(Limits.quotesPerAccount.formatted()) quotes.")) {
            try await backend.quotes.create(QuoteDraft(body: "Hello"))
        }
    }

    @Test func updateMapsAMissingRowToNotFound() async throws {
        let server = StubServer { request in
            .json(406, #"{"code":"PGRST116","details":"The result contains 0 rows","hint":null,"message":"Cannot coerce the result to a single JSON object"}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.notFound) {
            try await backend.quotes.update(Quote(body: "x"))
        }
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.method == "PATCH")
        let body = try #require(request.json as? [String: Any])
        #expect(Set(body.keys) == ["body", "body_format", "author", "source"])
    }

    @Test func setRotationIsOneRPCWithIDsOnly() async throws {
        let a = Quote(body: "A", author: "Ada")
        let b = Quote(body: "B", format: [TextRun(start: 0, length: 1, italic: true)], origin: .starter)
        let c = Quote(body: "C", source: "Notes", rotationPosition: 5)
        let server = StubServer { request in
            guard request.path == "/rest/v1/rpc/set_rotation", request.method == "POST" else { return .notFound(request) }
            return .json(200, "[\(Self.quoteJSON(b.id, position: 1)),\(Self.quoteJSON(c.id)),\(Self.quoteJSON(a.id, position: 0))]")
        }
        let backend = try await server.makeSignedInBackend()
        let updated = try await backend.quotes.setRotation(ordered: [a, b, a], removing: [c, a])
        #expect(updated.map(\.id) == [a.id, b.id, c.id], "Rotation first, in order")

        #expect(server.requests(table: "quotes").isEmpty, "no lookup and no upsert on the table")
        let calls = server.requests.filter { $0.path == "/rest/v1/rpc/set_rotation" }
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.query["select"]?.contains("rotation_position") == true)
        #expect(call.query["ordered"] == nil, "no IDs in the URL")
        let body = try #require(call.json as? [String: Any])
        #expect(Set(body.keys) == ["ordered", "removed"], "IDs only: no content travels")
        #expect((body["ordered"] as? [String])?.map { $0.lowercased() } == [a, b].map { $0.id.uuidString.lowercased() })
        #expect((body["removed"] as? [String])?.map { $0.lowercased() } == [c.id.uuidString.lowercased()])
    }

    @Test func setRotationWithNothingToDoSendsNothing() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.quotes.setRotation(ordered: [], removing: []).isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func restoreUpsertsTheSameRow() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/quotes" ? .json(201, Self.quoteJSON(id, body: "Back", position: 2, inserted: true)) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let original = Quote(id: id, body: "Back", author: "Ada", origin: .pasted, rotationPosition: 2)
        let restored = try await backend.quotes.restore(original)
        #expect(restored.id == id)
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.method == "POST")
        #expect(request.query["on_conflict"] == "id")
        #expect(request.header("Accept") == "application/vnd.pgrst.object+json")
        let body = try #require(request.json as? [String: Any])
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["author"] as? String == "Ada")
        #expect(body["origin"] as? String == "pasted")
        #expect(body["rotation_position"] as? Int == 2)
        #expect(body["created_at"] == nil && body["updated_at"] == nil, "timestamps are server-owned")

        await #expect(throws: QuotedError.validation("Write the quote first.")) {
            try await backend.quotes.restore(Quote(body: "  "))
        }
    }

    @Test func preWriteLookupsFailFastOffline() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        StubRegistry.shared.unregister(server.id)
        // With the SDK's GET retries these would take 1 + 2 + 4 s each.
        let start = ContinuousClock.now
        await #expect(throws: QuotedError.network) { try await backend.quotes.nextRotationPosition() }
        await #expect(throws: QuotedError.network) {
            try await backend.quotes.importStarter([StarterQuote(id: 1, body: "One", author: "A", sortOrder: 1)], addToRotation: true)
        }
        await #expect(throws: QuotedError.network) { try await backend.social.sendFriendRequest(toUsername: "bob") }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func importStarterAppendsToTheRotation() async throws {
        let server = StubServer { request in
            guard request.path == "/rest/v1/quotes" else { return .notFound(request) }
            if request.method == "GET" { return .json(200, #"[{"rotation_position":4}]"#) }
            return .json(201, "[\(Self.quoteJSON(UUID(), position: 6, origin: "starter")),\(Self.quoteJSON(UUID(), position: 5, origin: "starter"))]")
        }
        let backend = try await server.makeSignedInBackend()
        let starters = [StarterQuote(id: 1, body: "One", author: "A", sortOrder: 1), StarterQuote(id: 2, body: "Two", author: "B", sortOrder: 2)]
        let imported = try await backend.quotes.importStarter(starters, addToRotation: true)
        #expect(imported.map(\.rotationPosition) == [5, 6])
        #expect(imported.allSatisfy { $0.origin == .starter })

        let requests = server.requests(table: "quotes")
        #expect(requests[0].query["order"] == "rotation_position.desc.nullslast")
        #expect(requests[0].query["rotation_position"] == "not.is.null")
        let rows = try #require(requests[1].json as? [[String: Any]])
        #expect(rows.map { $0["rotation_position"] as? Int } == [5, 6])
        #expect(rows.map { $0["origin"] as? String } == ["starter", "starter"])
        #expect(rows.map { $0["author"] as? String } == ["A", "B"])
    }

    @Test func saveSharedCopiesThenStampsSavedAt() async throws {
        let shareID = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/quotes"): .json(201, "[\(Self.quoteJSON(UUID(), body: "Gift", origin: "shared"))]")
            case ("PATCH", "/rest/v1/shares"): .json(500, #"{"code":"XX000","message":"boom"}"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let share = SharedQuote(id: shareID, senderID: Self.friend, recipientID: Self.me, body: "Gift", createdAt: Date())
        // The stamp fails, but the copy exists, so the save still succeeds.
        let quote = try await backend.quotes.saveShared(share, addToRotation: false)
        #expect(quote.origin == .shared)
        let patch = try #require(server.requests(table: "shares").first)
        #expect(patch.query["id"] == "eq.\(shareID.uuidString)")
        #expect((patch.json as? [String: Any])?["saved_at"] is String)

        let notMine = SharedQuote(id: UUID(), senderID: Self.me, recipientID: Self.friend, body: "x", createdAt: Date())
        await #expect(throws: QuotedError.notFound) { try await backend.quotes.saveShared(notMine, addToRotation: false) }
    }

    @Test func friendRequestLooksUpTheUsernameFirst() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/rpc/find_profile"):
                (request.json as? [String: Any])?["p_username"] as? String == "bob"
                    ? .json(200, #"[{"id":"\#(Self.friend)","username":"bob","display_name":null}]"#)
                    : .json(200, "[]")
            case ("GET", "/rest/v1/profiles"):
                // myProfile(), asked only when the lookup is empty (your own name is never found).
                .json(200, #"{"id":"\#(Self.me)","username":"myname","display_name":null}"#)
            case ("POST", "/rest/v1/friendships"):
                .json(403, #"{"code":"42501","details":null,"hint":null,"message":"new row violates row-level security policy for table \"friendships\""}"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.notFound) { try await backend.social.sendFriendRequest(toUsername: "nobody") }
        await #expect(throws: QuotedError.validation("That's your own username.")) {
            try await backend.social.sendFriendRequest(toUsername: "MyName")
        }
        // A block (RLS) reads exactly like an unknown username.
        await #expect(throws: QuotedError.notFound) {
            try await backend.social.sendFriendRequest(toUsername: "@Bob")
        }
        let insert = try #require(server.requests(table: "friendships").first)
        #expect((insert.json as? [String: Any])?["addressee_id"] as? String == Self.friend.uuidString)
        #expect(insert.query["select"]?.contains("requester:profiles!friendships_requester_id_fkey") == true)
    }

    @Test func friendshipsAskForBothPartiesProfiles() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/friendships" ? .json(200, """
            [{"id":"\(UUID())","requester_id":"\(Self.friend)","addressee_id":"\(Self.me)","status":"pending",
              "created_at":"2026-10-19T03:00:00Z","responded_at":null,
              "requester":{"id":"\(Self.friend)","username":"bob","display_name":"Bob"},
              "addressee":{"id":"\(Self.me)","username":"me","display_name":null}}]
            """) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let friendships = try await backend.social.friendships()
        #expect(friendships.first?.otherParty?.username == "bob")
        #expect(friendships.first?.isIncomingRequest(for: Self.me) == true)
        let request = try #require(server.requests.first)
        #expect(request.query["or"] == "(requester_id.eq.\(Self.me.uuidString),addressee_id.eq.\(Self.me.uuidString))")
        #expect(request.query["select"]?.contains("addressee:profiles!friendships_addressee_id_fkey(id,username,display_name)") == true)
    }

    @Test func createProfileMapsTheUniqueUsername() async throws {
        let server = StubServer { request in
            .json(409, #"{"code":"23505","details":"Key (username)=(ada) already exists.","hint":null,"message":"duplicate key value violates unique constraint \"profiles_username_key\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.usernameTaken) {
            try await backend.social.createProfile(username: "Ada", displayName: "Ada L.")
        }
        await #expect(throws: QuotedError.validation("Usernames need at least 3 characters.")) {
            try await backend.social.createProfile(username: "ab")
        }
        let requests = server.requests(table: "profiles")
        #expect(requests.count == 1)
        let body = try #require(requests.first?.json as? [String: Any])
        #expect(body["id"] as? String == Self.me.uuidString)
        #expect(body["username"] as? String == "ada")
        #expect(body["display_name"] as? String == "Ada L.")
    }

    @Test func blockIsIdempotent() async throws {
        let server = StubServer { request in
            .json(409, #"{"code":"23505","details":null,"hint":null,"message":"duplicate key value violates unique constraint \"blocks_pkey\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.block(userID: Self.friend)
        await #expect(throws: QuotedError.validation("You can't block yourself.")) {
            try await backend.social.block(userID: Self.me)
        }
        let insert = try #require(server.requests(table: "blocks").first)
        #expect(insert.header("Prefer") == "return=minimal")
    }

    @Test func shareSendsOneSnapshotPerFriendAndRetriesWithoutTheLink() async throws {
        let quote = Quote(body: "Shared words", format: [TextRun(start: 0, length: 6, italic: true)], author: "Me")
        let server = StubServer { request in
            guard request.path == "/rest/v1/shares" else { return .notFound(request) }
            let rows = request.json as? [[String: Any]] ?? []
            if rows.first?["quote_id"] is String {
                return .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"shares\""}"#)
            }
            return .json(201, """
            [{"id":"\(UUID())","sender_id":"\(Self.me)","recipient_id":"\(Self.friend)","quote_id":null,"body":"Shared words",
              "body_format":[{"start":0,"length":6,"italic":true}],"author":"Me","source":null,"note":"hi",
              "created_at":"2026-10-19T03:00:00Z","seen_at":null,"saved_at":null,
              "recipient":{"id":"\(Self.friend)","username":"bob","display_name":null}}]
            """)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.validation("Choose at least one friend.")) {
            try await backend.social.share(quote, to: [Self.me])
        }
        let sent = try await backend.social.share(quote, to: [Self.friend, Self.me, Self.friend], note: "  hi ")
        #expect(sent.first?.recipient?.username == "bob")

        let requests = server.requests(table: "shares")
        #expect(requests.count == 2)
        let first = try #require(requests[0].json as? [[String: Any]])
        #expect(first.count == 1)
        #expect(first[0]["recipient_id"] as? String == Self.friend.uuidString)
        #expect(first[0]["quote_id"] as? String == quote.id.uuidString)
        #expect(first[0]["note"] as? String == "hi")
        #expect(first[0]["body"] as? String == "Shared words")
        #expect((first[0]["body_format"] as? [[String: Any]])?.first?["italic"] as? Bool == true)
        let retry = try #require(requests[1].json as? [[String: Any]])
        #expect(retry[0]["quote_id"] is NSNull)
    }

    @Test func markSeenSendsLargeListsInBatches() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/shares" ? .noContent : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let ids = (0..<(SocialRepository.deleteBatchSize + 50)).map { _ in UUID() }
        try await backend.social.markSeen(ids)
        let patches = server.requests(table: "shares")
        #expect(patches.count == 2)
        #expect(patches.allSatisfy { $0.method == "PATCH" && $0.query["seen_at"]?.lowercased() == "is.null" })
    }

    @Test func usernameAvailabilityAsksTheServerFunction() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/is_username_available" ? .json(200, "false") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.social.isUsernameAvailable("@Support") == false)
        let call = try #require(server.requests.first)
        #expect(call.method == "POST")
        #expect((call.json as? [String: Any])?["p_username"] as? String == "support")
    }

    @Test func shareRetryAfterALostAnswerReturnsTheSentShares() async throws {
        let shareID = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/shares"):
                .json(409, #"{"code":"23505","details":null,"hint":null,"message":"duplicate key value violates unique constraint \"shares_pkey\""}"#)
            case ("GET", "/rest/v1/shares"):
                .json(200, "[\(Self.shareJSON(shareID, sent: true))]")
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let sent = try await backend.social.share(Quote(body: "B"), to: [Self.friend], ids: [Self.friend: shareID])
        #expect(sent.map(\.id) == [shareID])
        let insert = try #require(server.requests.first { $0.method == "POST" })
        #expect((insert.json as? [[String: Any]])?.first?["id"] as? String == shareID.uuidString)
        let read = try #require(server.requests.first { $0.method == "GET" })
        #expect(read.query["sender_id"] == "eq.\(Self.me.uuidString)")
    }

    @Test func markSeenOnlyStampsUnseenReceivedShares() async throws {
        let server = StubServer { _ in .noContent }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.markSeen([])
        #expect(server.requests.isEmpty)
        let id = UUID()
        try await backend.social.markSeen([id, id])
        let request = try #require(server.requests(table: "shares").first)
        #expect(request.method == "PATCH")
        #expect(request.query["id"] == "in.(\(id.uuidString))")
        #expect(request.query["recipient_id"] == "eq.\(Self.me.uuidString)")
        #expect(request.query["seen_at"]?.lowercased() == "is.null")
    }

    @Test func markSavedOnlyStampsUnsavedReceivedShares() async throws {
        let server = StubServer { _ in .noContent }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.markSaved([])
        #expect(server.requests.isEmpty)
        let id = UUID()
        try await backend.social.markSaved([id, id])
        let request = try #require(server.requests(table: "shares").first)
        #expect(request.method == "PATCH")
        #expect(request.query["id"] == "in.(\(id.uuidString))")
        #expect(request.query["recipient_id"] == "eq.\(Self.me.uuidString)")
        #expect(request.query["saved_at"]?.lowercased() == "is.null")
        let body = try #require(request.json as? [String: Any])
        #expect(Set(body.keys) == ["saved_at"])
    }

    @Test func reportFallsBackToTheUserWhenTheShareIsGone() async throws {
        let server = StubServer { request in
            let body = request.json as? [String: Any]
            if body?["share_id"] is String {
                return .json(403, #"{"code":"42501","message":"new row violates row-level security policy for table \"reports\""}"#)
            }
            return .json(201, "")
        }
        let backend = try await server.makeSignedInBackend()
        let share = SharedQuote(id: UUID(), senderID: Self.friend, recipientID: Self.me, body: "x", createdAt: Date())
        try await backend.social.report(share: share, reason: .spam, details: "  ")
        let requests = server.requests(table: "reports")
        #expect(requests.count == 2)
        let retry = try #require(requests[1].json as? [String: Any])
        #expect(retry["share_id"] is NSNull)
        #expect(retry["reported_user_id"] as? String == Self.friend.uuidString)
        #expect(retry["reason"] as? String == "spam")
        #expect(retry["details"] is NSNull)

        await #expect(throws: QuotedError.validation("Details can be at most 500 characters.")) {
            try await backend.social.report(share: share, reason: .other, details: String(repeating: "x", count: 501))
        }
    }

    @Test func webSearchTapNeverThrowsAndAsksForNothingBack() async throws {
        let server = StubServer { _ in .json(201, "") }
        let backend = try await server.makeSignedInBackend()
        #expect(await backend.events.logWebSearchTapAndWait())
        let request = try #require(server.requests(table: "events").first)
        #expect(request.header("Prefer") == "return=minimal")
        // Anonymous: the name only, no user ID.
        #expect((request.json as? [String: Any])?.keys.sorted() == ["name"])
        #expect((request.json as? [String: Any])?["name"] as? String == "web_search_tap")

        server.setHandler { _ in .json(500, #"{"message":"down"}"#) }
        #expect(await backend.events.logWebSearchTapAndWait() == false)
    }

    @Test func deleteAccountPostsWithTheUserTokenThenSignsOut() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/functions/v1/delete-account": .json(200, #"{"deleted":true}"#)
            case "/auth/v1/logout": .json(403, #"{"code":"user_not_found","message":"User not found"}"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.account.deleteAccount()
        let invoke = try #require(server.requests.first { $0.path == "/functions/v1/delete-account" })
        #expect(invoke.method == "POST")
        #expect(invoke.header("Authorization") == "Bearer \(StubServer.accessToken)")
        #expect(backend.auth.currentUserID == nil)
    }

    @Test func deleteAccountFailureKeepsTheSession() async throws {
        let server = StubServer { request in
            request.path == "/functions/v1/delete-account" ? .json(500, #"{"error":"delete_failed"}"#) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.server(#"HTTP 500: {"error":"delete_failed"}"#)) {
            try await backend.account.deleteAccount()
        }
        #expect(backend.auth.currentUserID == Self.me)
    }

    @Test func deleteAccountRetryAfterTheUserIsGoneSucceeds() async throws {
        let server = StubServer { request in
            switch request.path {
            // The first call deleted the user; its response was lost. The token still verifies.
            case "/functions/v1/delete-account": .json(401, #"{"error":"unauthorized"}"#)
            case "/auth/v1/user": .authError(403, code: "user_not_found", message: "User from sub claim in JWT does not exist")
            case "/auth/v1/logout": .json(403, #"{"code":"user_not_found","message":"User not found"}"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.account.deleteAccount()
        #expect(backend.auth.currentUserID == nil)
        let probe = try #require(server.requests.first { $0.path == "/auth/v1/user" })
        #expect(probe.header("Authorization") == "Bearer \(StubServer.accessToken)")
    }

    @Test func deleteAccountKeepsARealAuthFailure() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/functions/v1/delete-account": .json(401, #"{"error":"unauthorized"}"#)
            // The user exists, so the 401 was not "already deleted".
            case "/auth/v1/user": .json(200, #"{"id":"\#(Self.me.uuidString.lowercased())","aud":"authenticated","role":"authenticated","email":"stub@example.com","app_metadata":{},"user_metadata":{},"created_at":"2026-10-19T00:00:00Z","updated_at":"2026-10-19T00:00:00Z","is_anonymous":false}"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.notSignedIn) { try await backend.account.deleteAccount() }
        #expect(backend.auth.currentUserID == Self.me)

        // An expired or otherwise rejected token cannot prove anything either.
        server.setHandler { request in
            switch request.path {
            case "/functions/v1/delete-account": .json(401, #"{"error":"unauthorized"}"#)
            case "/auth/v1/user": .authError(403, code: "bad_jwt", message: "invalid JWT: token is expired")
            default: .notFound(request)
            }
        }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.account.deleteAccount() }
    }

    @Test func offlineMapsToNetwork() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        // Remove the server so the protocol fails the load like a dropped connection. (A PATCH: the
        // SDK retries failed GETs with backoff, which would only slow the test down.)
        StubRegistry.shared.unregister(server.id)
        await #expect(throws: QuotedError.network) { try await backend.social.markSeen([UUID()]) }
    }

    @Test func authCallbackLinks() async throws {
        let server = StubServer { .notFound($0) }
        let backend = server.makeBackend()
        await #expect(throws: QuotedError.validation("This isn't a sign-in link.")) {
            try await backend.auth.handle(url: URL(string: "quoted://quote/\(UUID())")!)
        }
        await #expect(throws: QuotedError.validation("This link has expired or was already used. Try signing in.")) {
            try await backend.auth.handle(url: URL(string: "quoted://auth-callback?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!)
        }
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: [
        (#"{"sub":"x","amr":[{"method":"otp","timestamp":1792397550}]}"#, false),
        (#"{"sub":"x","amr":[{"method":"recovery","timestamp":1792397550}]}"#, true),
        (#"{"sub":"x","amr":["pwd","recovery"]}"#, true),
        (#"{"sub":"x"}"#, false),
    ])
    func authCallbackReportsPasswordRecovery(claims: String, isRecovery: Bool) async throws {
        let token = StubServer.jwt(claims)
        let server = StubServer { request in
            request.path == "/auth/v1/token" && request.query["grant_type"] == "pkce"
                ? .json(200, StubServer.sessionJSON(accessToken: token))
                : .notFound(request)
        }
        let backend = server.makeBackend()
        // GoTrue's PKCE redirect carries only the code, for confirmations and resets alike.
        let result = try await backend.auth.handle(url: URL(string: "quoted://auth-callback/?code=abc")!)
        #expect(result == (isRecovery ? .passwordRecovery(Self.me) : .signedIn(Self.me)))
        #expect(result.userID == Self.me)
        #expect(backend.auth.currentUserID == Self.me)
    }

    @Test func recoveryDetection() {
        let plain = StubServer.jwt(#"{"amr":[{"method":"password","timestamp":1}]}"#)
        #expect(AuthService.isPasswordRecovery(url: URL(string: "quoted://auth-callback?code=a&type=recovery")!, accessToken: plain))
        #expect(AuthService.isPasswordRecovery(url: URL(string: "quoted://auth-callback#access_token=t&type=recovery")!, accessToken: plain))
        #expect(!AuthService.isPasswordRecovery(url: URL(string: "quoted://auth-callback?code=a&type=signup")!, accessToken: plain))
        #expect(AuthService.authenticationMethods(in: "not-a-jwt").isEmpty)
        #expect(AuthService.authenticationMethods(in: "a.%%%.c").isEmpty)
    }

    @Test func clearLocalSessionRemovesTheStoredSessionWithoutANetworkCall() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        let auth = backend.auth
        #expect(auth.storageKey == "sb-stub-auth-token")
        #expect(try auth.storage.retrieve(key: auth.storageKey) != nil, "the SDK stores the session under this key")
        #expect(auth.clearLocalSession())
        #expect(auth.currentUserID == nil)
        #expect(try auth.storage.retrieve(key: auth.storageKey) == nil)
        #expect(server.requests.isEmpty)
        await #expect(throws: QuotedError.notSignedIn) { try await backend.quotes.fetchMine() }
    }

    @Test func deleteSharesBatchesIDs() async throws {
        let server = StubServer { _ in .noContent }
        let backend = try await server.makeSignedInBackend()
        try await backend.social.deleteShares(ids: [])
        #expect(server.requests.isEmpty)

        let ids = (0..<250).map { _ in UUID() }
        try await backend.social.deleteShares(ids: ids + ids.prefix(10))
        let requests = server.requests(table: "shares")
        #expect(requests.map(\.method) == ["DELETE", "DELETE", "DELETE"])
        #expect(requests.allSatisfy { $0.header("Prefer") == "return=minimal" })
        let sent = requests.flatMap { request in
            (request.query["id"] ?? "").dropFirst(4).dropLast().split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }
        #expect(sent == ids)
    }

    @Test func signUpReportsConfirmation() async throws {
        let server = StubServer { request in
            // With "Confirm email" on, GoTrue answers with the user only (no session).
            request.path == "/auth/v1/signup" ? .json(200, """
            {"id":"\(Self.me.uuidString.lowercased())","aud":"authenticated","role":"authenticated","email":"new@example.com",
             "app_metadata":{"provider":"email"},"user_metadata":{},"created_at":"2026-10-19T00:00:00Z",
             "updated_at":"2026-10-19T00:00:00Z","confirmation_sent_at":"2026-10-19T00:00:00Z","is_anonymous":false}
            """) : .notFound(request)
        }
        let backend = server.makeBackend()
        let result = try await backend.auth.signUp(email: " new@example.com ", password: "secret123")
        #expect(result == .confirmationRequired(email: "new@example.com"))
        #expect(backend.auth.currentUserID == nil)
        let request = try #require(server.requests.first)
        #expect(request.query["redirect_to"] == "quoted://auth-callback")
        await #expect(throws: QuotedError.validation("Enter your password.")) {
            _ = try await backend.auth.signUp(email: "new@example.com", password: "")
        }
        await #expect(throws: QuotedError.validation("Check your email address.")) {
            _ = try await backend.auth.signUp(email: "not-an-email", password: "secret123")
        }
    }

    @Test func signInAnonymouslyCreatesAnAccountWithoutEmail() async throws {
        let server = StubServer { request in
            request.path == "/auth/v1/signup" ? .json(200, StubServer.sessionJSON(anonymous: true)) : .notFound(request)
        }
        let backend = server.makeBackend()
        var iterator = backend.auth.sessionChanges.makeAsyncIterator()
        #expect(await iterator.next() == .some(nil))
        let id = try await backend.auth.signInAnonymously()
        #expect(id == Self.me)
        #expect(await iterator.next() == .some(Self.me))
        #expect(backend.auth.currentUserID == Self.me)
        #expect(backend.auth.isAnonymous)
        #expect(backend.auth.currentEmail == nil)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        let body = try #require(request.body)
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["email"] == nil)
        #expect(fields["password"] == nil)
    }

    @Test func signInAnonymouslyExplainsADisabledProvider() async throws {
        let server = StubServer { request in
            request.path == "/auth/v1/signup"
                ? .authError(422, code: "anonymous_provider_disabled", message: "Anonymous sign-ins are disabled")
                : .notFound(request)
        }
        let backend = server.makeBackend()
        await #expect(throws: QuotedError.validation("Quoted can't create your account right now: anonymous sign-ins are turned off on the server.")) {
            try await backend.auth.signInAnonymously()
        }
        #expect(backend.auth.currentUserID == nil)
        #expect(!backend.auth.isAnonymous)
    }

    @Test func sessionChangesFollowSignInAndOut() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/auth/v1/token": .json(200, StubServer.sessionJSON())
            case "/auth/v1/logout": .noContent
            default: .notFound(request)
            }
        }
        let backend = server.makeBackend()
        var iterator = backend.auth.sessionChanges.makeAsyncIterator()
        #expect(await iterator.next() == .some(nil))
        try await backend.auth.signIn(email: " stub@example.com ", password: "pw")
        #expect(await iterator.next() == .some(Self.me))
        try await backend.auth.signOut()
        #expect(await iterator.next() == .some(nil))
        #expect(backend.auth.currentUserID == nil)
    }
}
