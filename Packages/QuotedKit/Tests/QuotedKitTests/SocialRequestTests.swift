import Foundation
import QuotedCore
import Synchronization
import Testing
@testable import QuotedKit

/// What the social repositories send (accounts, posts, conversations, messages, playlists), against
/// ``StubServer``: the paths, the exact RPC argument names, explicit column lists, and writes that
/// name only granted columns.
@Suite("Social requests")
struct SocialRequestTests {
    static let me = StubServer.userID
    static let friend = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let conversationID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let playlistID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    static func select(_ columns: String) -> String { columns.filter { !$0.isWhitespace } }

    static func postJSON(_ id: UUID, at time: String = "2026-10-29T09:00:00.123456+00:00") -> String {
        """
        {"id":"\(id)","author_id":"\(friend)","starter_quote_id":null,"caption":null,"body":"Be bold","body_format":[],
         "author":null,"source":null,"creator_id":"\(friend)","creator_username":"bob","edited_from_id":null,
         "edited_from_username":null,"verified_starter_id":null,"audience":"friends","held_at":null,"created_at":"\(time)",
         "poster":{"id":"\(friend)","username":"bob","display_name":null,"accepts_text_messages":true}}
        """
    }

    static func messageJSON(_ id: UUID, kind: String = "text") -> String {
        """
        {"id":"\(id)","conversation_id":"\(conversationID)","sender_id":"\(me)","kind":"\(kind)",
         "text":\(kind == "text" ? #""hi""# : "null"),"note":null,
         "body":\(kind == "quote" ? #""Q""# : "null"),"body_format":\(kind == "quote" ? "[]" : "null"),"author":null,
         "source":null,"creator_id":null,"creator_username":null,"edited_from_id":null,"edited_from_username":null,
         "verified_starter_id":null,"starter_quote_id":null,"playlist_id":\(kind == "playlist" ? #""\#(playlistID)""# : "null"),
         "playlist_title":\(kind == "playlist" ? #""Courage""# : "null"),"created_at":"2026-10-29T09:00:00Z"}
        """
    }

    static let playlistRow = """
    {"id":"\(playlistID)","owner_id":"\(me)","title":"Courage","visibility":"friends","held_at":null,
     "created_at":"2026-10-29T09:00:00Z","updated_at":"2026-10-29T09:00:00Z"}
    """

    static func error(_ status: Int, _ code: String, _ message: String) -> StubServer.Response {
        .json(status, #"{"code":"\#(code)","details":null,"hint":null,"message":"\#(message)"}"#)
    }

    // MARK: Account and profiles

    @Test func myAccountReadsTheFunctionsOneRow() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/my_account" ? .json(200, """
            [{"id":"\(Self.me)","username":"me","display_name":"Me","accepts_text_messages":true,"favorites_visibility":"private",
              "terms_version":1,"terms_accepted_at":"2026-10-29T08:00:00Z","current_terms_version":1,"is_suspended":false,
              "can_publish":false}]
            """) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let account = try #require(try await backend.profiles.myAccount())
        #expect(account.hasAcceptedCurrentTerms)
        #expect(account.profile.displayName == "Me")
        let call = try #require(server.requests.first)
        #expect(call.method == "GET", "a read the SDK retries")
        #expect(call.body == nil && call.query.isEmpty, "no arguments")

        server.setHandler { _ in .json(200, "[]") }
        #expect(try await backend.profiles.myAccount() == nil, "no profile yet")

        // Before a write (the terms check) it is not retried: offline fails at once.
        server.setHandler { _ in Self.error(503, "PGRST000", "Could not connect") }
        let before = server.requests.count
        await #expect(throws: (any Error).self) { try await backend.profiles.myAccount(retry: false) }
        #expect(server.requests.count == before + 1)
    }

    @Test func acceptTermsSendsTheVersion() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/accept_terms" ? .noContent : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        try await backend.profiles.acceptTerms(version: 1)
        #expect((server.requests.first?.json as? [String: Any]) as NSDictionary? == ["p_version": 1])

        server.setHandler { _ in Self.error(400, "22023", "Unknown terms version.") }
        await #expect(throws: QuotedError.validation("The Terms of Use were just updated. Read them again, then accept.")) {
            try await backend.profiles.acceptTerms(version: 7)
        }
    }

    @Test func profileUpdatesSendOneGrantedColumn() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/profiles"
                ? .json(200, #"{"id":"\#(Self.me)","username":"me","display_name":null,"accepts_text_messages":false}"#)
                : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let profile = try await backend.profiles.setAcceptsTextMessages(false)
        #expect(profile.acceptsTextMessages == false)
        let patch = try #require(server.requests.first)
        #expect(patch.method == "PATCH")
        #expect((patch.json as? [String: Any]) as NSDictionary? == ["accepts_text_messages": false])
        #expect(patch.query["id"] == "eq.\(Self.me.uuidString)")
        #expect(patch.query["select"] == Self.select(Columns.profile))

        _ = try await backend.profiles.updateDisplayName("  ")
        #expect((server.requests.last?.json as? [String: Any])?["display_name"] is NSNull)

        server.setHandler { _ in Self.error(400, "QR003", "Quoted doesn't allow some words in posts and messages.") }
        await #expect(throws: QuotedError.blockedWords("Quoted doesn't allow some words in names.")) {
            _ = try await backend.profiles.updateDisplayName("Rude")
        }
    }

    @Test func profileViewSendsBothArguments() async throws {
        let before = Date(timeIntervalSince1970: 1_792_380_398.25)
        let server = StubServer { request in
            request.path == "/rest/v1/rpc/profile_view" ? .json(200, """
            {"profile":{"id":"\(Self.friend)","username":"maya","display_name":null},"relationship":"incoming",
             "posts":[],"playlists":[],"favorites":null}
            """) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let page = try #require(try await backend.profiles.profileView(username: " @Maya "))
        #expect(page.relationship == .incoming)
        // The page leaves out accepts_text_messages: unknown, never read as on.
        #expect(page.profile.acceptsTextMessages == nil)
        // A GET (retried by the SDK): the arguments are query items, and a nil p_before is left out
        // (a query item can't say null).
        let first = try #require(server.requests.first)
        #expect(first.method == "GET" && first.body == nil)
        #expect(first.query == ["p_username": "maya"])

        _ = try await backend.profiles.profileView(username: "maya", before: before)
        let next = try #require(server.requests.last)
        #expect(Timestamp.date(from: try #require(next.query["p_before"])) == before)

        server.setHandler { _ in .json(200, "null") }
        #expect(try await backend.profiles.profileView(username: "maya") == nil, "no such profile, or they blocked you")
        let count = server.requests.count
        #expect(try await backend.profiles.profileView(username: "not a name!") == nil)
        #expect(server.requests.count == count, "an invalid username never leaves the phone")
    }

    // MARK: Posts

    @Test func feedReadsPostsWithThePosterNewestFirst() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/posts" ? .json(200, "[\(Self.postJSON(id))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let feed = try await backend.posts.feed()
        #expect(feed.map(\.id) == [id])
        #expect(feed.first?.poster?.username == "bob")
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.query["select"] == Self.select(Columns.feedPost))
        #expect(request.query["select"]?.contains("source_quote_id") == false, "not readable by clients")
        #expect(request.query["select"]?.contains("poster:profiles!posts_author_id_fkey(id,username,display_name,accepts_text_messages)") == true)
        #expect(request.query["order"] == "created_at.desc.nullslast,id.asc.nullslast")
        #expect(request.query["limit"] == "30")
        #expect(request.query["or"] == nil)

        // The next page: older, or as old with a later id.
        let cursor = try #require(feed.last?.cursor)
        _ = try await backend.posts.feed(after: cursor, limit: 10)
        let next = try #require(server.requests.last)
        let time = Timestamp.string(from: cursor.createdAt)
        #expect(time == "2026-10-29T09:00:00.123456Z", "the cursor keeps microseconds")
        #expect(next.query["or"] == #"(created_at.lt."\#(time)",and(created_at.eq."\#(time)",id.gt.\#(id.uuidString.lowercased())))"#)
        #expect(next.query["limit"] == "10")

        _ = try await backend.posts.posts(by: Self.friend)
        #expect(server.requests.last?.query["author_id"] == "eq.\(Self.friend.uuidString)")
    }

    @Test func createPostSendsTheReferenceNeverTheWords() async throws {
        let id = UUID(), quoteID = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/posts" ? .json(201, Self.postJSON(id)) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        _ = try await backend.posts.create(PostDraft(source: .quote(quoteID), caption: "  for you  "), id: id)
        let insert = try #require(server.requests.first)
        #expect(insert.method == "POST")
        #expect(insert.header("Prefer")?.contains("return=representation") == true)
        #expect(insert.header("Accept") == "application/vnd.pgrst.object+json")
        #expect(insert.query["select"] == Self.select(Columns.post))
        let body = try #require(insert.json as? [String: Any])
        #expect(Set(body.keys) == ["id", "source_quote_id", "starter_quote_id", "caption", "audience"])
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["source_quote_id"] as? String == quoteID.uuidString)
        #expect(body["caption"] as? String == "for you")
        #expect(body["audience"] as? String == "friends")

        await #expect(throws: QuotedError.validation("Shorten the caption to 280 characters.")) {
            try await backend.posts.create(PostDraft(source: .catalog(1), caption: String(repeating: "c", count: 281)))
        }
        #expect(server.requests.count == 1, "a long caption never leaves the phone")
    }

    @Test func createPostRetryAndRefusals() async throws {
        let id = UUID()
        let server = StubServer { request in
            switch request.method {
            case "POST": Self.error(409, "23505", #"duplicate key value violates unique constraint \"posts_pkey\""#)
            case "GET": .json(200, Self.postJSON(id))
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.posts.create(PostDraft(source: .catalog(2)), id: id).id == id)
        let read = try #require(server.requests.last)
        #expect(read.query["id"] == "eq.\(id.uuidString)")
        #expect(read.query["author_id"] == "eq.\(Self.me.uuidString)")

        for (response, expected) in [
            (Self.error(403, "42501", "Accept the Terms of use first."), QuotedError.termsRequired),
            (Self.error(400, "QR003", "Quoted doesn't allow some words in posts and messages."),
             .blockedWords("Quoted doesn't allow some words in posts and messages.")),
            (Self.error(400, "QR001", "You can post at most 20 quotes a day."), .validation("You can post at most 20 quotes a day.")),
            (Self.error(403, "42501", "You can post only quotes from your Library or the Quoted Catalog."),
             .unavailable("That quote is no longer in your library.")),
        ] {
            server.setHandler { _ in response }
            await #expect(throws: expected) { try await backend.posts.create(PostDraft(source: .quote(UUID()))) }
        }
    }

    @Test func postAudienceAndDelete() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.method == "PATCH" ? .json(200, Self.postJSON(id)) : .noContent
        }
        let backend = try await server.makeSignedInBackend()
        _ = try await backend.posts.setAudience(.friends, for: id)
        let patch = try #require(server.requests.first)
        #expect((patch.json as? [String: Any]) as NSDictionary? == ["audience": "friends"])
        #expect(patch.query["id"] == "eq.\(id.uuidString)")
        try await backend.posts.delete(id: id)
        let delete = try #require(server.requests.last)
        #expect(delete.method == "DELETE")
        #expect(delete.header("Prefer") == "return=minimal")
        #expect(delete.query["id"] == "eq.\(id.uuidString)")
    }

    // MARK: Conversations and messages

    @Test func openConversationAndTheInbox() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/rest/v1/rpc/open_conversation":
                .json(200, #"{"id":"\#(Self.conversationID)","user_a":"\#(Self.me)","user_b":"\#(Self.friend)","created_at":"2026-10-29T09:00:00Z","last_message_at":null,"closed_at":null}"#)
            case "/rest/v1/rpc/inbox_conversations":
                .json(200, """
                [{"conversation_id":"\(Self.conversationID)","other_id":"\(Self.friend)","other_username":"bob",
                  "other_display_name":null,"other_accepts_text_messages":true,"is_closed":false,"last_message_at":null,
                  "last_message_kind":null,"last_message_preview":null,"last_message_sender_id":null,"unread_count":2,
                  "last_read_at":"2026-10-29T09:00:00.123456+00:00"}]
                """)
            case "/rest/v1/conversations":
                .json(200, """
                {"id":"\(Self.conversationID)","user_a":"\(Self.me)","user_b":"\(Self.friend)","created_at":"2026-10-29T09:00:00Z",
                 "last_message_at":null,"closed_at":null,
                 "user_a_profile":{"id":"\(Self.me)","username":"me","display_name":null,"accepts_text_messages":true},
                 "user_b_profile":{"id":"\(Self.friend)","username":"bob","display_name":null,"accepts_text_messages":false}}
                """)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let conversation = try await backend.messages.openConversation(with: Self.friend)
        #expect(conversation.otherMemberID(for: Self.me) == Self.friend)
        let open = try #require(server.requests.first)
        #expect((open.json as? [String: Any]) as NSDictionary? == ["p_friend": Self.friend.uuidString])
        #expect(open.query["select"] == Self.select(Columns.conversationRow))

        let inbox = try await backend.messages.inbox()
        #expect(InboxBadge(conversations: inbox, friendRequests: 0).label == "1")
        #expect(inbox.first?.lastReadAt == Timestamp.date(from: "2026-10-29T09:00:00.123456Z"), "your read mark")
        #expect(server.requests.last?.method == "GET", "a read the SDK retries")
        #expect(server.requests.last?.body == nil)

        let read = try #require(try await backend.messages.conversation(id: Self.conversationID))
        #expect(read.otherProfile(for: Self.me)?.acceptsTextMessages == false)
        let get = try #require(server.requests.last)
        #expect(get.query["select"]?.contains("user_b_profile:profiles!conversations_user_b_fkey(") == true)
        #expect(get.query["id"] == "eq.\(Self.conversationID.uuidString)")
    }

    @Test func blockedUsersKeepSomeoneWhoBlockedYouBack() async throws {
        let sam = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let server = StubServer { request in
            request.path == "/rest/v1/blocks" ? .json(200, """
            [{"blocked_id":"\(Self.friend)","blocked":null},
             {"blocked_id":"\(sam)","blocked":{"id":"\(sam)","username":"sam","display_name":null}}]
            """) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let blocked = try await backend.social.blockedUsers()
        // Bob blocked you back, so his profile is hidden from you; he stays listed, to unblock.
        #expect(blocked == [BlockedUser(id: Self.friend), BlockedUser(Profile(id: sam, username: "sam"))])
        #expect(server.requests.first?.query["blocker_id"] == "eq.\(Self.me.uuidString)")
    }

    @Test func inboxReadIsRetriedAfterA503() async throws {
        let calls = Mutex(0)
        let server = StubServer { request in
            guard request.path == "/rest/v1/rpc/inbox_conversations" else { return .notFound(request) }
            let call = calls.withLock { count in
                count += 1
                return count
            }
            return call == 1 ? Self.error(503, "PGRST000", "Could not connect") : .json(200, "[]")
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.messages.inbox().isEmpty)
        #expect(server.requests.count == 2, "the SDK retried the GET once")
    }

    @Test func receivedQuotesReadEveryPageAcrossConversations() async throws {
        let ids = (1...5).map { UUID(uuidString: "3e000000-0000-4000-8000-00000000000\($0)")! }
        // Five quote messages, two per page: three pages, the last one short.
        let server = StubServer { request in
            guard request.path == "/rest/v1/rpc/received_quotes" else { return .notFound(request) }
            let pages = [Array(ids[0..<2]), Array(ids[2..<4]), Array(ids[4...])]
            let after = request.query["p_after_id"]
            let index = after == nil ? 0 : (after == ids[1].uuidString ? 1 : 2)
            return .json(200, "[" + pages[index].map { Self.messageJSON($0, kind: "quote") }.joined(separator: ",") + "]")
        }
        let backend = try await server.makeSignedInBackend()
        let received = try await backend.messages.receivedQuotes(pageSize: 2)
        #expect(received.map(\.id) == ids)
        #expect(server.requests.count == 3)
        let first = try #require(server.requests.first)
        #expect(first.method == "GET", "a read the SDK retries")
        #expect(first.body == nil)
        #expect(first.query == ["p_limit": "2"], "the first page has no cursor (a null would arrive as the text \"null\")")
        // The next page starts after the last row, its time to the microsecond.
        let second = server.requests[1]
        #expect(second.query["p_after_id"] == ids[1].uuidString)
        #expect(second.query["p_after_created_at"] == "2026-10-29T09:00:00.000000Z")
        #expect(second.query["p_limit"] == "2")
        #expect(server.requests[2].query["p_after_id"] == ids[3].uuidString)
        #expect(server.requests.allSatisfy { $0.path != "/rest/v1/messages" }, "never a filter on the messages table")
    }

    @Test func receivedQuotesParamsKeepMicroseconds() throws {
        let cursor = PageCursor(createdAt: Date(timeIntervalSince1970: 1_793_271_600.123456), id: Self.conversationID)
        let data = try JSONEncoder().encode(ReceivedQuotesParams(cursor: cursor, limit: 500))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["p_after_created_at"] as? String == "2026-10-29T11:00:00.123456Z")
        #expect(json["p_after_id"] as? String == Self.conversationID.uuidString)
        #expect(json["p_limit"] as? Int == 500)
        let first = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(ReceivedQuotesParams(cursor: nil, limit: 500)))
        #expect((first as? [String: Any])?.keys.sorted() == ["p_limit"])
    }

    @Test func messagePagesAreNewestFirst() async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/messages" ? .json(200, "[\(Self.messageJSON(id))]") : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let page = try await backend.messages.messages(in: Self.conversationID)
        #expect(page.map(\.id) == [id])
        let request = try #require(server.requests.first)
        #expect(request.query["conversation_id"] == "eq.\(Self.conversationID.uuidString)")
        #expect(request.query["order"] == "created_at.desc.nullslast,id.asc.nullslast")
        #expect(request.query["limit"] == "50")
        #expect(request.query["select"] == Self.select(Columns.message))
        #expect(request.query["select"]?.contains("source_") == false, "the sources are insert-only")

        _ = try await backend.messages.messages(in: Self.conversationID, after: try #require(page.last).cursor)
        #expect(server.requests.last?.query["or"]?.hasPrefix(#"(created_at.lt."2026-10-29T09:00:00.000000Z""#) == true)
    }

    /// Each kind names only its own columns (no nulls), so the body never names a column without
    /// an insert grant.
    @Test(arguments: [
        (MessageDraft.text(" hi "), ["text": "hi"] as [String: String]),
        (.quote(.quote(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!), note: " n "),
         ["source_quote_id": "77777777-7777-4777-8777-777777777777", "note": "n"]),
        (.quote(.catalog(3)), ["starter_quote_id": "3"]),
        (.quote(.post(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)), ["source_post_id": "77777777-7777-4777-8777-777777777777"]),
        (.quote(.message(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!), note: "fwd"),
         ["source_message_id": "77777777-7777-4777-8777-777777777777", "note": "fwd"]),
        (.playlist(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!), ["playlist_id": "44444444-4444-4444-8444-444444444444"]),
    ])
    func sendNamesOnlyItsKindsColumns(draft: MessageDraft, expected: [String: String]) async throws {
        let id = UUID()
        let server = StubServer { request in
            request.path == "/rest/v1/messages" ? .json(201, Self.messageJSON(id, kind: draft.kind.rawValue)) : .notFound(request)
        }
        let backend = try await server.makeSignedInBackend()
        let message = try await backend.messages.send(draft, in: Self.conversationID, id: id)
        #expect(message.kind == draft.kind)
        let insert = try #require(server.requests.first)
        #expect(insert.header("Accept") == "application/vnd.pgrst.object+json")
        #expect(insert.query["select"] == Self.select(Columns.message))
        let body = try #require(insert.json as? [String: Any])
        #expect(Set(body.keys) == Set(["id", "conversation_id", "kind"] + expected.keys))
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["conversation_id"] as? String == Self.conversationID.uuidString)
        #expect(body["kind"] as? String == draft.kind.rawValue)
        for (key, value) in expected {
            #expect(body[key].map { "\($0)" } == value, "\(key)")
        }
    }

    @Test func sendRetryAndRefusals() async throws {
        let id = UUID()
        let server = StubServer { request in
            switch request.method {
            case "POST": Self.error(409, "23505", #"duplicate key value violates unique constraint \"messages_pkey\""#)
            case "GET": .json(200, Self.messageJSON(id))
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.messages.send(.text("hi"), in: Self.conversationID, id: id).id == id)
        let read = try #require(server.requests.last)
        #expect(read.query["sender_id"] == "eq.\(Self.me.uuidString)")

        server.setHandler { request in request.method == "GET" ? .json(406, #"{"code":"PGRST116","details":"The result contains 0 rows","hint":null,"message":"x"}"#) : Self.error(409, "23505", "duplicate key value violates unique constraint") }
        await #expect(throws: QuotedError.validation("That already exists.")) {
            try await backend.messages.send(.text("hi"), in: Self.conversationID, id: id)
        }

        for (response, expected) in [
            (Self.error(403, "42501", "This account is suspended."), QuotedError.suspended),
            (Self.error(403, "42501", "This conversation is closed."), .conversationClosed),
            (Self.error(403, "42501", "This conversation is not available."), .unavailable("This conversation is not available.")),
            (Self.error(400, "QR004", "This friend receives quotes only."), .textsOff),
            (Self.error(400, "QR001", "You can send at most 300 messages a day."), .validation("You can send at most 300 messages a day.")),
            (Self.error(403, "42501", "You can send only quotes from your Library or the Quoted Catalog."),
             .unavailable("That quote is no longer in your library.")),
            (Self.error(403, "42501", "This quote is not available."), .unavailable("This quote is not available.")),
        ] {
            server.setHandler { _ in response }
            await #expect(throws: expected) { try await backend.messages.send(.text("hi"), in: Self.conversationID) }
        }

        let count = server.requests.count
        await #expect(throws: QuotedError.validation("Notes can be up to 280 characters.")) {
            try await backend.messages.send(.quote(.catalog(1), note: String(repeating: "n", count: 281)), in: Self.conversationID)
        }
        #expect(server.requests.count == count)
    }

    @Test func unsendReadMarkAndDeleteConversation() async throws {
        let server = StubServer { request in
            request.path == "/rest/v1/conversation_members"
                ? .json(200, #"[{"conversation_id":"\#(Self.conversationID)","user_id":"\#(Self.me)","last_read_at":"2026-10-29T09:00:00Z","cleared_at":null}]"#)
                : .noContent
        }
        let backend = try await server.makeSignedInBackend()
        let messageID = UUID()
        try await backend.messages.unsend(messageID: messageID)
        let delete = try #require(server.requests.first)
        #expect(delete.method == "DELETE" && delete.path == "/rest/v1/messages")
        #expect(delete.query["id"] == "eq.\(messageID.uuidString)")

        // The mark is the time of the newest message shown, sent to the microsecond (the server
        // compares it with created_at, so a rounded time would leave that message unread).
        let shown = try #require(Timestamp.date(from: "2026-10-29T09:00:00.123456+00:00"))
        let member = try await backend.messages.markRead(conversationID: Self.conversationID, upTo: shown)
        #expect(member?.lastReadAt != nil)
        let read = try #require(server.requests.last)
        #expect(read.method == "PATCH")
        #expect((read.json as? [String: Any]) as NSDictionary? == ["last_read_at": "2026-10-29T09:00:00.123456Z"])
        #expect(read.query["conversation_id"] == "eq.\(Self.conversationID.uuidString)")
        #expect(read.query["user_id"] == "eq.\(Self.me.uuidString)")
        #expect(read.query["select"] == Self.select(Columns.conversationMember))

        _ = try await backend.messages.clear(conversationID: Self.conversationID)
        #expect((server.requests.last?.json as? [String: Any]).map { Set($0.keys) } == ["cleared_at"])

        server.setHandler { _ in .json(200, "[]") }
        #expect(try await backend.messages.markRead(conversationID: UUID(), upTo: shown) == nil, "not your conversation")
    }

    // MARK: Playlists

    @Test func minePagesPlaylistsThenTheirItems() async throws {
        let quoteA = UUID(), quoteB = UUID()
        let server = StubServer { request in
            switch request.path {
            case "/rest/v1/playlists": .page([Self.playlistRow], offset: 0, total: 1)
            case "/rest/v1/playlist_items":
                .page([
                    #"{"playlist_id":"\#(Self.playlistID)","quote_id":"\#(quoteB)","position":1024,"added_at":"2026-10-29T09:00:00Z"}"#,
                    #"{"playlist_id":"\#(Self.playlistID)","quote_id":"\#(quoteA)","position":0,"added_at":"2026-10-29T09:00:00Z"}"#,
                ], offset: 0, total: 2)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let mine = try await backend.playlists.mine()
        #expect(mine.map(\.id) == [Self.playlistID])
        #expect(mine.first?.quoteIDs == [quoteA, quoteB])
        let playlists = try #require(server.requests(table: "playlists").first)
        #expect(playlists.query["owner_id"] == "eq.\(Self.me.uuidString)")
        #expect(playlists.query["order"] == "updated_at.desc.nullslast,id.asc.nullslast")
        #expect(playlists.query["select"] == Self.select(Columns.playlist))
        let items = try #require(server.requests(table: "playlist_items").first)
        #expect(items.query["playlist_id"] == "in.(\(Self.playlistID.uuidString))")
    }

    @Test func createRenameNarrowAndDelete() async throws {
        let server = StubServer { request in
            request.method == "DELETE" ? .noContent : .json(200, Self.playlistRow)
        }
        let backend = try await server.makeSignedInBackend()
        _ = try await backend.playlists.create(title: "  Courage ", visibility: .onlyMe, id: Self.playlistID)
        let insert = try #require(server.requests.first)
        #expect((insert.json as? [String: Any]) as NSDictionary? == [
            "id": Self.playlistID.uuidString, "title": "Courage", "visibility": "private",
        ])
        #expect(insert.query["select"] == Self.select(Columns.playlist))

        _ = try await backend.playlists.rename(Self.playlistID, to: "Grace")
        #expect((server.requests.last?.json as? [String: Any]) as NSDictionary? == ["title": "Grace"])
        _ = try await backend.playlists.setVisibility(.friends, for: Self.playlistID)
        #expect((server.requests.last?.json as? [String: Any]) as NSDictionary? == ["visibility": "friends"])
        try await backend.playlists.delete(id: Self.playlistID)
        #expect(server.requests.last?.method == "DELETE")

        let count = server.requests.count
        await #expect(throws: QuotedError.validation("Give the playlist a title.")) {
            try await backend.playlists.create(title: "  ")
        }
        await #expect(throws: QuotedError.validation("Playlist titles can be at most 60 characters.")) {
            try await backend.playlists.rename(Self.playlistID, to: String(repeating: "t", count: 61))
        }
        #expect(server.requests.count == count)

        for (response, expected) in [
            (Self.error(400, "QR003", "Quoted doesn't allow some words in posts and messages."),
             QuotedError.blockedWords("Quoted doesn't allow some words in playlist titles.")),
            (Self.error(400, "QR001", "You can make at most 20 playlists a day."),
             .validation("You can make 20 playlists a day. Try again tomorrow.")),
            (Self.error(400, "QR002", "You can keep at most 100 playlists."),
             .validation("You can keep up to 100 playlists. Delete one to make another.")),
            (Self.error(403, "42501", "Accept the Terms of use first."), .termsRequired),
        ] {
            server.setHandler { _ in response }
            await #expect(throws: expected) { try await backend.playlists.create(title: "Courage") }
        }
    }

    @Test func addAppendsAfterTheLastPositionAndSkipsDuplicates() async throws {
        let a = UUID(), b = UUID()
        let server = StubServer { request in
            switch request.method {
            case "GET": .json(200, #"[{"position":2048}]"#)
            case "POST": .json(201, #"[{"playlist_id":"\#(Self.playlistID)","quote_id":"\#(a)","position":3072,"added_at":"2026-10-29T09:00:00Z"}]"#)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        let added = try await backend.playlists.add([a, b, a], to: Self.playlistID)
        #expect(added.map(\.quoteID) == [a])

        let lookup = try #require(server.requests.first)
        #expect(lookup.query["order"] == "position.desc.nullslast")
        #expect(lookup.query["limit"] == "1")
        let insert = try #require(server.requests.last)
        #expect(insert.query["on_conflict"] == "playlist_id,quote_id")
        #expect(insert.header("Prefer")?.contains("resolution=ignore-duplicates") == true)
        let rows = try #require(insert.json as? [[String: Any]])
        #expect(rows.map { $0["quote_id"] as? String } == [a.uuidString, b.uuidString])
        #expect(rows.map { $0["position"] as? Int } == [3072, 4096])
        #expect(rows.allSatisfy { Set($0.keys) == ["playlist_id", "quote_id", "position"] })

        server.setHandler { request in
            request.method == "GET" ? .json(200, "[]") : Self.error(400, "QR002", "A playlist can hold at most 200 quotes.")
        }
        await #expect(throws: QuotedError.validation("A playlist holds up to 200 quotes.")) {
            try await backend.playlists.add([a], to: Self.playlistID)
        }
    }

    @Test func removeRestoreAndReorder() async throws {
        let server = StubServer { request in
            request.method == "POST"
                ? .json(201, #"[{"playlist_id":"\#(Self.playlistID)","quote_id":"\#(Self.friend)","position":0,"added_at":"2026-10-29T09:00:00Z"}]"#)
                : .noContent
        }
        let backend = try await server.makeSignedInBackend()
        let quoteID = Self.friend
        try await backend.playlists.remove(quoteID: quoteID, from: Self.playlistID)
        let delete = try #require(server.requests.first)
        #expect(delete.query["playlist_id"] == "eq.\(Self.playlistID.uuidString)")
        #expect(delete.query["quote_id"] == "eq.\(quoteID.uuidString)")

        let entry = PlaylistEntry(playlistID: Self.playlistID, quoteID: quoteID, position: 0, addedAt: Date())
        _ = try await backend.playlists.restore(entry)
        #expect((server.requests.last?.json as? [[String: Any]])?.first?["position"] as? Int == 0)

        // [0, 1024, 2048, 3072] with the last moved between the first two: one item moves.
        let ids = (0..<4).map { _ in UUID() }
        let entries = ids.enumerated().map { PlaylistEntry(playlistID: Self.playlistID, quoteID: $1, position: $0 * 1024, addedAt: Date()) }
        var before = server.requests.count
        let reordered = try await backend.playlists.reorder(Self.playlistID, entries: [entries[0], entries[3], entries[1], entries[2]])
        var calls = server.requests.dropFirst(before)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "POST" && call.path == "/rest/v1/rpc/set_playlist_positions")
        #expect((call.json as? [String: Any]) as NSDictionary? == [
            "p_playlist": Self.playlistID.uuidString, "p_quote_ids": [ids[3].uuidString], "p_positions": [512],
        ])
        #expect(reordered.map(\.position) == [0, 512, 1024, 2048])

        // A renumbering moves several items, still in one call: it lands whole or not at all.
        before = server.requests.count
        let dense = ids.enumerated().map { PlaylistEntry(playlistID: Self.playlistID, quoteID: $1, position: $0, addedAt: Date()) }
        let renumbered = try await backend.playlists.reorder(Self.playlistID, entries: [dense[3], dense[0], dense[1], dense[2]])
        calls = server.requests.dropFirst(before)
        #expect(calls.count == 1)
        #expect(((calls.first?.json as? [String: Any])?["p_quote_ids"] as? [String])?.count == 4)
        #expect(renumbered.map(\.position) == [0, 1024, 2048, 3072])

        // Nothing to move: no call.
        before = server.requests.count
        _ = try await backend.playlists.reorder(Self.playlistID, entries: reordered)
        #expect(server.requests.count == before)
    }

    @Test func viewAndSaveACopy() async throws {
        let copyID = UUID()
        let server = StubServer { request in
            switch request.path {
            case "/rest/v1/rpc/playlist_view": .json(200, "null")
            case "/rest/v1/rpc/save_playlist_copy":
                .json(200, #"{"id":"\#(copyID)","owner_id":"\#(Self.me)","title":"Courage","visibility":"private","held_at":null,"created_at":"2026-10-29T09:00:00Z","updated_at":"2026-10-29T09:00:00Z"}"#)
            case "/rest/v1/playlist_items":
                .page([#"{"playlist_id":"\#(copyID)","quote_id":"\#(Self.friend)","position":0,"added_at":"2026-10-29T09:00:00Z"}"#], offset: 0, total: 1)
            default: .notFound(request)
            }
        }
        let backend = try await server.makeSignedInBackend()
        #expect(try await backend.playlists.view(id: Self.playlistID) == nil, "no longer available")
        #expect((server.requests.first?.json as? [String: Any]) as NSDictionary? == ["p_playlist": Self.playlistID.uuidString])

        let copy = try await backend.playlists.saveCopy(of: Self.playlistID)
        #expect(copy.id == copyID && copy.visibility == .onlyMe)
        #expect(copy.quoteIDs == [Self.friend])
        let call = try #require(server.requests.first { $0.path == "/rest/v1/rpc/save_playlist_copy" })
        let body = try #require(call.json as? [String: Any])
        #expect(Set(body.keys) == ["p_playlist", "p_title"] && body["p_title"] is NSNull)
        #expect(call.query["select"] == Self.select(Columns.playlist))

        server.setHandler { _ in Self.error(403, "42501", "This playlist is not available.") }
        await #expect(throws: QuotedError.unavailable("This playlist is not available.")) {
            try await backend.playlists.saveCopy(of: Self.playlistID, title: "Mine")
        }
    }
}
