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

    /// A `friendships` row with both embedded profiles.
    static func friendshipJSON(_ id: UUID, other: UUID = friend) -> String {
        """
        {"id":"\(id)","requester_id":"\(other)","addressee_id":"\(me)","status":"accepted",
         "created_at":"2026-10-19T03:00:00Z","responded_at":"2026-10-19T04:00:00Z",
         "requester":{"id":"\(other)","username":"bob","display_name":null,"accepts_text_messages":true},
         "addressee":{"id":"\(me)","username":"me","display_name":null,"accepts_text_messages":true}}
        """
    }

    @Test func requiresASession() async throws {
        let server = StubServer { .notFound($0) }
        let backend = server.makeBackend()
        await #expect(throws: QuotedError.notSignedIn) { try await backend.quotes.fetchMine() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.messages.inbox() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.posts.feed() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.profiles.myAccount() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.playlists.mine() }
        await #expect(throws: QuotedError.notSignedIn) { try await backend.reports.report(.catalogQuote(1), reason: .wrongWording) }
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
            let rows = ids.dropFirst(offset).prefix(100).map { Self.friendshipJSON($0) }
            return .page(Array(rows), offset: offset, total: ids.count)
        }
        let backend = try await server.makeSignedInBackend()
        let friendships = try await backend.social.friendships()
        #expect(friendships.map(\.id) == ids)
        #expect(server.requests(table: "friendships").map { $0.query["offset"] } == ["0", "100", "200"])
    }

    @Test func pagingDropsRowsRepeatedAcrossPages() async throws {
        // A row inserted at the top while reading shifts the last row of page 1 onto page 2.
        let ids = (0..<501).map { _ in UUID() }
        let server = StubServer { request in
            let offset = Int(request.query["offset"] ?? "") ?? 0
            let rows = offset == 0
                ? ids.prefix(500).map { Self.friendshipJSON($0) }
                : [ids[499], ids[500]].map { Self.friendshipJSON($0) }
            return .page(rows, offset: offset, total: offset == 0 ? 501 : 502)
        }
        let backend = try await server.makeSignedInBackend()
        let friendships = try await backend.social.friendships()
        #expect(friendships.map(\.id) == ids)
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

    @Test func restoreInsertsTheSameRow() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/quotes" ? .json(201, "[\(Self.quoteJSON(id, body: "Back", position: 2, inserted: true))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let original = Quote(id: id, body: "Back", author: "Ada", origin: .pasted, rotationPosition: 2, creatorUsername: "me")
        let restored = try await backend.quotes.restore(original)
        #expect(restored.id == id)
        let request = try #require(server.requests(table: "quotes").first)
        #expect(request.method == "POST")
        // A plain insert: an upsert would name id and origin in its update, which the grant refuses.
        #expect(request.query["on_conflict"] == nil)
        #expect(request.header("Prefer")?.contains("resolution") == false)
        let body = try #require(request.json as? [String: Any])
        #expect(Set(body.keys) == ["id", "body", "body_format", "author", "source", "origin", "rotation_position", "is_favorite"])
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["author"] as? String == "Ada")
        #expect(body["origin"] as? String == "pasted")
        #expect(body["rotation_position"] as? Int == 2)
        #expect(body["creator_username"] == nil, "the server restores provenance from its tombstone")

        await #expect(throws: QuotedError.validation("Write the quote first.")) {
            try await backend.quotes.restore(Quote(body: "  "))
        }
    }

    @Test func restoringAQuoteThatStillExistsReturnsIt() async throws {
        let id = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/quotes"):
                .json(409, #"{"code":"23505","details":null,"hint":null,"message":"duplicate key value violates unique constraint \"quotes_pkey\""}"#)
            case ("GET", "/rest/v1/quotes"): .json(200, "[\(Self.quoteJSON(id, body: "Back"))]")
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.quotes.restore(Quote(id: id, body: "Back")).id == id)
    }

    @Test func restoreRetryOfASharedQuoteReadsItBack() async throws {
        // The first Undo restored the shared quote and used up its tombstone; the retry is refused
        // by the provenance trigger (42501, before the primary key) and must read the quote back.
        let id = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/quotes"):
                .json(403, #"{"code":"42501","details":null,"hint":null,"message":"origin \"shared\" is set by the server"}"#)
            case ("GET", "/rest/v1/quotes"): .json(200, "[\(Self.quoteJSON(id, body: "Back", origin: "shared"))]")
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let restored = try await backend.quotes.restore(Quote(id: id, body: "Back", origin: .shared))
        #expect(restored.id == id && restored.origin == .shared)
        #expect(server.requests.first { $0.method == "GET" }?.query["id"] == "in.(\(id.uuidString))")

        // Its tombstone gone and the quote not there: the refusal stands.
        server.setHandler { request in
            request.method == "POST"
                ? .json(403, #"{"code":"42501","details":null,"hint":null,"message":"origin \"shared\" is set by the server"}"#)
                : .json(200, "[]")
        }
        await #expect(throws: QuotedError.server("Permission denied: origin \"shared\" is set by the server")) {
            try await backend.quotes.restore(Quote(id: id, body: "Back", origin: .shared))
        }
    }

    @Test func createDoesNotReadBackAfterARefusal() async throws {
        // A new quote of your own is never refused by a BEFORE INSERT check; only 23505 reads back.
        let server = StubServer { request in
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"new row violates row-level security policy for table \"quotes\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: (any Error).self) { try await backend.quotes.create(QuoteDraft(body: "Hello")) }
        #expect(server.requests.allSatisfy { $0.method == "POST" })
    }

    @Test func preWriteLookupsFailFastOffline() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        StubRegistry.shared.unregister(server.id)
        // With the SDK's GET retries these would take 1 + 2 + 4 s each.
        let start = ContinuousClock.now
        await #expect(throws: QuotedError.network) { try await backend.quotes.nextRotationPosition() }
        await #expect(throws: QuotedError.network) { try await backend.playlists.add([UUID()], to: UUID()) }
        await #expect(throws: QuotedError.network) { try await backend.social.sendFriendRequest(toUsername: "bob") }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func addCatalogQuotesIsOneCallWithClientIDs() async throws {
        let ids = [UUID(), UUID()]
        let server = StubServer { request in
            guard request.path == "/rest/v1/rpc/add_catalog_quotes" else { return .notFound(request) }
            return .json(200, "[\(Self.quoteJSON(ids[0], position: 5, origin: "starter")),\(Self.quoteJSON(ids[1], position: 6, origin: "starter"))]")
        }
        let backend = try await server.makeSignedInBackend()
        let added = try await backend.quotes.addCatalogQuotes([1, 2], ids: ids, inReminders: true)
        #expect(added.map(\.rotationPosition) == [5, 6])
        #expect(added.allSatisfy { $0.origin == .starter })
        #expect(server.requests(table: "quotes").isEmpty, "never a direct insert of catalog words")

        let call = try #require(server.requests.first)
        #expect(call.method == "POST")
        #expect(call.query["select"] == Columns.quote.filter { !$0.isWhitespace })
        let body = try #require(call.json as? [String: Any])
        #expect(Set(body.keys) == ["p_starter_ids", "p_ids", "p_in_reminders"])
        #expect(body["p_starter_ids"] as? [Int] == [1, 2])
        #expect((body["p_ids"] as? [String])?.map { $0.lowercased() } == ids.map { $0.uuidString.lowercased() })
        #expect(body["p_in_reminders"] as? Bool == true)

        #expect(try await backend.quotes.addCatalogQuotes([]).isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test func createAcceptsOnlyYourOwnWords() async throws {
        let server = StubServer { .notFound($0) }
        let backend = try await server.makeSignedInBackend()
        for origin in [QuoteOrigin.starter, .shared] {
            await #expect(throws: QuotedError.self) {
                try await backend.quotes.create(QuoteDraft(body: "x"), origin: origin)
            }
        }
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: [
        (SnapshotRef.post(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!), "save_from_post", ["p_post"]),
        (.message(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!), "save_from_message", ["p_message"]),
        (.favorite(friendID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, handle: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!),
         "save_from_favorite", ["p_friend", "p_handle"]),
        (.playlistItem(playlistID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, handle: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!),
         "save_from_playlist", ["p_playlist", "p_handle"]),
    ])
    func saveGoesThroughTheSourcesFunction(source: SnapshotRef, function: String, sourceKeys: [String]) async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/\(function)"
                ? .json(200, Self.quoteJSON(id, body: "Gift", origin: "shared"))
                : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let quote = try await backend.quotes.save(source, id: id, inReminders: true)
        #expect(quote.origin == .shared)
        let call = try #require(server.requests.first)
        #expect(call.header("Accept") == "application/vnd.pgrst.object+json")
        let body = try #require(call.json as? [String: Any])
        #expect(Set(body.keys) == Set(sourceKeys + ["p_id", "p_in_reminders"]))
        #expect(body["p_id"] as? String == id.uuidString)
        #expect(body["p_in_reminders"] as? Bool == true)
        #expect(server.requests(table: "quotes").isEmpty)
    }

    @Test func saveACatalogQuoteAddsIt() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/add_catalog_quotes" ? .json(200, "[\(Self.quoteJSON(id, origin: "starter"))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.quotes.save(.catalog(4), id: id).id == id)
        let body = try #require(server.requests.first?.json as? [String: Any])
        #expect(body["p_starter_ids"] as? [Int] == [4])
        #expect(body["p_in_reminders"] as? Bool == false)
    }

    @Test func savingSomethingYouCantSeeIsUnavailable() async throws {
        let server = StubServer { _ in
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"This post is not available."}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.unavailable("This post is not available.")) {
            try await backend.quotes.save(.post(UUID()))
        }
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
                .json(200, #"{"id":"\#(Self.me)","username":"myname","display_name":null,"accepts_text_messages":true}"#)
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
        // Only the columns find_profile returns: asking for any other (accepts_text_messages) fails with 42703.
        let lookup = try #require(server.requests(table: "rpc/find_profile").first)
        #expect(lookup.query["select"]?.filter { !$0.isWhitespace } == "id,username,display_name")
    }

    /// The insert's embed can't see the addressee yet (the profiles policy runs before the new
    /// friendship exists), so the real server returns `addressee: null`.
    @Test func sentRequestNamesTheAddresseeFromTheLookup() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/rest/v1/rpc/find_profile"):
                .json(200, #"[{"id":"\#(Self.friend)","username":"bob","display_name":"Bob Ray"}]"#)
            case ("POST", "/rest/v1/friendships"):
                .json(201, """
                {"id":"\(UUID())","requester_id":"\(Self.me)","addressee_id":"\(Self.friend)","status":"pending",
                 "created_at":"2026-10-24T05:12:00+00:00","responded_at":null,
                 "requester":{"id":"\(Self.me)","username":"me","display_name":null},"addressee":null}
                """)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let request = try await backend.social.sendFriendRequest(toUsername: "bob")
        #expect(request.otherParty?.username == "bob")
        #expect(request.otherParty?.displayName == "Bob Ray")
        #expect(request.isOutgoingRequest(for: Self.me))
    }

    @Test func favoritesRequests() async throws {
        let quoteID = UUID()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("PATCH", "/rest/v1/quotes"):
                .json(200, """
                {"id":"\(quoteID)","body":"Hi","created_at":"2026-10-25T09:00:00+00:00","is_favorite":true,
                 "favorited_at":"2026-10-25T09:00:00+00:00"}
                """)
            case ("PATCH", "/rest/v1/profiles"): .noContent
            case ("POST", "/rest/v1/rpc/friend_favorites"):
                .json(200, #"[{"id":"\#(UUID())","body":"Hope","body_format":[],"author":"Emily Dickinson","source":null,"verified_starter_id":null,"creator_username":"emily","edited_from_username":null,"favorited_at":null}]"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()

        let quote = try await backend.quotes.setFavorite(id: quoteID, true)
        #expect(quote.isFavorite)
        let heart = try #require(server.requests(table: "quotes").first)
        // Only the heart travels; the server stamps favorited_at.
        #expect((heart.json as? [String: Any]).map { Set($0.keys) } == ["is_favorite"])
        #expect(heart.query["id"] == "eq.\(quoteID.uuidString)")

        try await backend.profiles.setFavoritesVisibility(.friends)
        let setting = try #require(server.requests(table: "profiles").first)
        #expect((setting.json as? [String: Any]) as NSDictionary? == ["favorites_visibility": "friends"])
        #expect(setting.query["id"] == "eq.\(Self.me.uuidString)")
        // The column isn't readable through profiles, so nothing is asked back.
        #expect(setting.header("Prefer") == "return=minimal")
        #expect(setting.query["select"] == nil)

        let favorites = try await backend.profiles.favorites(of: Self.friend)
        #expect(favorites.map(\.author) == ["Emily Dickinson"])
        #expect(favorites.first?.provenance.who(viewer: "me") == .person("emily"))
        let call = try #require(server.requests.first { $0.path == "/rest/v1/rpc/friend_favorites" })
        #expect((call.json as? [String: Any])?["p_user"] as? String == Self.friend.uuidString)
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
        #expect(request.query["select"]?.contains("addressee:profiles!friendships_addressee_id_fkey(id,username,display_name,accepts_text_messages)") == true)
    }

    @Test func createProfileMapsTheUniqueUsername() async throws {
        let server = StubServer { request in
            .json(409, #"{"code":"23505","details":"Key (username)=(ada) already exists.","hint":null,"message":"duplicate key value violates unique constraint \"profiles_username_key\""}"#)
        }
        let backend = try await server.makeSignedInBackend()
        await #expect(throws: QuotedError.usernameTaken) {
            try await backend.profiles.createProfile(username: "Ada", displayName: "Ada L.")
        }
        await #expect(throws: QuotedError.validation("Usernames need at least 3 characters.")) {
            try await backend.profiles.createProfile(username: "ab")
        }
        let requests = server.requests(table: "profiles")
        #expect(requests.count == 1)
        let body = try #require(requests.first?.json as? [String: Any])
        // Only the insert grant's columns.
        #expect(Set(body.keys) == ["id", "username", "display_name"])
        #expect(body["id"] as? String == Self.me.uuidString)
        #expect(body["username"] as? String == "ada")
        #expect(body["display_name"] as? String == "Ada L.")
        #expect(requests.first?.query["select"] == Columns.profile.filter { !$0.isWhitespace })
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

    @Test func usernameAvailabilityAsksTheServerFunction() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/is_username_available" ? .json(200, "false") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.profiles.isUsernameAvailable("@Support") == false)
        let call = try #require(server.requests.first)
        #expect(call.method == "POST")
        #expect((call.json as? [String: Any])?["p_username"] as? String == "support")
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
        await #expect(throws: QuotedError.network) { try await backend.messages.markRead(conversationID: UUID(), upTo: .now) }
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
