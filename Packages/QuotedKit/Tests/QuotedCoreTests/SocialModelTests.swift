import Foundation
import Testing
@testable import QuotedCore

/// The social redesign's models decode the server's rows and JSON, and round-trip for the caches.
@Suite("Social models")
struct SocialModelTests {
    static let alice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let bob = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let aliceID = UUID(uuidString: alice)!
    static let bobID = UUID(uuidString: bob)!

    func roundTrips<T: Codable & Equatable>(_ value: T) throws -> Bool {
        try Fixture.decode(T.self, Fixture.jsonString(value)) == value
    }

    // MARK: Account

    @Test func myAccount() throws {
        let account = try Fixture.decode(MyAccount.self, """
        {"id":"\(Self.alice)","username":"alice","display_name":null,"accepts_text_messages":false,
         "favorites_visibility":"friends","terms_version":null,"terms_accepted_at":null,"current_terms_version":1,
         "is_suspended":false,"can_publish":false}
        """)
        #expect(account.displayName == nil)
        #expect(account.profile == Profile(id: Self.aliceID, username: "alice", acceptsTextMessages: false))
        #expect(account.favoritesVisibility == .friends)
        #expect(account.favoritesVisibility.audience == .friends)
        #expect(!account.hasAcceptedCurrentTerms)
        #expect(!account.needsUpdatedTerms, "never accepted: Community Terms, not Updated Terms")
        #expect(try roundTrips(account))

        var accepted = account
        accepted.termsVersion = 1
        #expect(accepted.hasAcceptedCurrentTerms)
        accepted.currentTermsVersion = 2
        #expect(!accepted.hasAcceptedCurrentTerms)
        #expect(accepted.needsUpdatedTerms)

        // Unknown visibility reads as private.
        let odd = try Fixture.decode(MyAccount.self, #"{"id":"\#(Self.alice)","username":"alice","favorites_visibility":"everyone"}"#)
        #expect(odd.favoritesVisibility == .onlyMe)
        #expect(odd.currentTermsVersion == 1 && !odd.isSuspended && odd.acceptsTextMessages)
    }

    @Test func audienceFallsBackToTheNarrowest() throws {
        #expect(try Fixture.decode([Audience].self, #"["private","friends","public","circle"]"#) == [.onlyMe, .friends, .anyone, .onlyMe])
        #expect(try Fixture.decode(Relationship.self, #""cousin""#) == Relationship.none)
    }

    // MARK: Posts

    static let postJSON = """
    {"id":"10000000-0000-4000-8000-000000000001","author_id":"\(bob)","starter_quote_id":null,"caption":"for you",
     "body":"Trust thyself 🙂","body_format":[{"start":0,"length":5,"bold":true},{"start":14,"length":9,"italic":true}],
     "author":"Ralph Waldo Emerson","source":"Self-Reliance","creator_id":"\(alice)","creator_username":"alice",
     "edited_from_id":null,"edited_from_username":null,"verified_starter_id":null,"audience":"friends","held_at":null,
     "created_at":"2026-10-29T09:00:00.123456+00:00",
     "poster":{"id":"\(bob)","username":"bob","display_name":"Bob","accepts_text_messages":true}}
    """

    @Test func post() throws {
        let post = try Fixture.decode(Post.self, Self.postJSON)
        #expect(post.posterID == Self.bobID)
        #expect(post.poster?.displayName == "Bob")
        #expect(post.quote.author == "Ralph Waldo Emerson")
        #expect(post.quote.creatorID == Self.aliceID)
        #expect(post.provenance == Provenance(creatorUsername: "alice"))
        // The runs are clamped to the body (the emoji is two UTF-16 units at 14).
        #expect(post.quote.format == [TextRun(start: 0, length: 5, bold: true), TextRun(start: 14, length: 2, italic: true)])
        #expect(post.caption == "for you")
        #expect(!post.isHeld)
        #expect(post.cursor == PageCursor(createdAt: post.createdAt, id: post.id))
        #expect(post.snapshotRef == .post(post.id))
        #expect(try roundTrips(post))
        let object = try Fixture.jsonObject(post)
        #expect(object["author_id"] as? String == Self.bob.uppercased())
        #expect(object["author"] as? String == "Ralph Waldo Emerson", "the snapshot sits beside the row's own columns")
        #expect(object["source_quote_id"] == nil)

        let held = try Fixture.decode(Post.self, """
        {"id":"10000000-0000-4000-8000-000000000002","author_id":"\(Self.bob)","body":"x","verified_starter_id":7,
         "audience":"public","held_at":"2026-10-29T10:00:00Z","created_at":"2026-10-29T09:00:00Z"}
        """)
        #expect(held.isHeld)
        #expect(held.audience == .anyone)
        #expect(held.provenance.isChecked)
        #expect(held.poster == nil)
    }

    @Test func postDraftCaption() throws {
        #expect(try PostDraft(source: .quote(Fixture.id(1)), caption: "  hi  ").validatedCaption() == "hi")
        #expect(try PostDraft(source: .catalog(3), caption: " \n ").validatedCaption() == nil)
        #expect(try PostDraft(source: .catalog(3)).validatedCaption() == nil)
        #expect(PostDraft(source: .catalog(3)).audience == .friends)
        #expect(throws: SocialTextError.captionTooLong(maximum: 280)) {
            try PostDraft(source: .catalog(3), caption: String(repeating: "c", count: 281)).validatedCaption()
        }
    }

    // MARK: Conversations and messages

    @Test func conversationAndMember() throws {
        let conversation = try Fixture.decode(Conversation.self, """
        {"id":"20000000-0000-4000-8000-000000000001","user_a":"\(Self.alice)","user_b":"\(Self.bob)",
         "created_at":"2026-10-29T09:00:00Z","last_message_at":null,"closed_at":"2026-10-29T11:00:00Z",
         "user_a_profile":{"id":"\(Self.alice)","username":"alice","display_name":null,"accepts_text_messages":true},
         "user_b_profile":{"id":"\(Self.bob)","username":"bob","display_name":"Bob","accepts_text_messages":false}}
        """)
        #expect(conversation.isClosed)
        #expect(conversation.otherMemberID(for: Self.aliceID) == Self.bobID)
        #expect(conversation.otherProfile(for: Self.aliceID)?.acceptsTextMessages == false)
        #expect(conversation.otherProfile(for: Self.bobID)?.username == "alice")
        #expect(try roundTrips(conversation))

        // open_conversation returns the bare row.
        let bare = try Fixture.decode(Conversation.self, """
        {"id":"20000000-0000-4000-8000-000000000001","user_a":"\(Self.alice)","user_b":"\(Self.bob)","created_at":"2026-10-29T09:00:00Z"}
        """)
        #expect(!bare.isClosed && bare.userAProfile == nil)

        let member = try Fixture.decode(ConversationMember.self, """
        {"conversation_id":"20000000-0000-4000-8000-000000000001","user_id":"\(Self.alice)","last_read_at":"2026-10-29T09:30:00Z","cleared_at":null}
        """)
        #expect(member.lastReadAt != nil && member.clearedAt == nil)
    }

    static func messageJSON(_ fields: String) -> String {
        """
        {"id":"30000000-0000-4000-8000-000000000001","conversation_id":"20000000-0000-4000-8000-000000000001",
         "sender_id":"\(alice)",\(fields),"created_at":"2026-10-29T09:00:00.5+00:00"}
        """
    }

    @Test func messagesOfEveryKind() throws {
        let text = try Fixture.decode(Message.self, Self.messageJSON("""
        "kind":"text","text":"See you at 6.","note":null,"body":null,"body_format":null,"author":null,"source":null,
        "creator_id":null,"creator_username":null,"edited_from_id":null,"edited_from_username":null,"verified_starter_id":null,
        "starter_quote_id":null,"playlist_id":null,"playlist_title":null
        """))
        #expect(text.content == .text("See you at 6."))
        #expect(text.quote == nil && text.snapshotRef == nil)
        #expect(text.isMine(Self.aliceID) && !text.isMine(Self.bobID))
        #expect(text.copyText == "See you at 6.")
        #expect(try roundTrips(text))

        let quote = try Fixture.decode(Message.self, Self.messageJSON("""
        "kind":"quote","text":null,"note":"made me think of you","body":"Hope is the thing with feathers",
        "body_format":[],"author":"Emily Dickinson","source":null,"creator_id":null,"creator_username":null,
        "edited_from_id":null,"edited_from_username":null,"verified_starter_id":2,"starter_quote_id":2,"playlist_id":null,
        "playlist_title":null
        """))
        guard case .quote(let snapshot, let note) = quote.content else {
            Issue.record("expected a quote")
            return
        }
        #expect(snapshot.body == "Hope is the thing with feathers")
        #expect(note == "made me think of you")
        #expect(quote.provenance == .catalog(2))
        #expect(quote.starterQuoteID == 2)
        #expect(quote.snapshotRef == .message(quote.id))
        #expect(quote.copyText == "\u{201C}Hope is the thing with feathers\u{201D}\n\u{2014} Emily Dickinson")
        #expect(try roundTrips(quote))

        let playlist = try Fixture.decode(Message.self, Self.messageJSON("""
        "kind":"playlist","playlist_id":null,"playlist_title":"Morning Pages"
        """))
        #expect(playlist.content == .playlist(id: nil, title: "Morning Pages"), "a deleted playlist keeps its title")
        #expect(playlist.copyText == "Morning Pages")
        #expect(try roundTrips(playlist))
    }

    @Test func messageDraftValidation() throws {
        #expect(try MessageDraft.text("  hi \n").validated() == .text("hi"))
        #expect(throws: SocialTextError.emptyMessage) { try MessageDraft.text("  ").validated() }
        #expect(throws: SocialTextError.messageTooLong(maximum: 1000)) {
            try MessageDraft.text(String(repeating: "m", count: 1001)).validated()
        }
        #expect(try MessageDraft.text(String(repeating: "m", count: 1000)).validated() == .text(String(repeating: "m", count: 1000)))
        #expect(try MessageDraft.quote(.catalog(1), note: "  ").validated() == .quote(.catalog(1), note: nil))
        #expect(try MessageDraft.quote(.post(Fixture.id(1)), note: " yes ").validated() == .quote(.post(Fixture.id(1)), note: "yes"))
        #expect(throws: SocialTextError.noteTooLong(maximum: 280)) {
            try MessageDraft.quote(.message(Fixture.id(1)), note: String(repeating: "n", count: 281)).validated()
        }
        #expect(SocialTextError.noteTooLong(maximum: 280).errorDescription == "Notes can be up to 280 characters.")
        #expect(MessageDraft.playlist(Fixture.id(2)).kind == .playlist)
        #expect(MessageDraft.quote(.quote(Fixture.id(2))).kind == .quote)
    }

    @Test func snapshotRefsForwardOrSaveFirst() {
        #expect(SnapshotRef.post(Fixture.id(1)).quoteRef == .post(Fixture.id(1)))
        #expect(SnapshotRef.message(Fixture.id(1)).quoteRef == .message(Fixture.id(1)))
        #expect(SnapshotRef.catalog(4).quoteRef == .catalog(4))
        #expect(SnapshotRef.favorite(friendID: Fixture.id(1), handle: Fixture.id(2)).quoteRef == nil)
        #expect(SnapshotRef.playlistItem(playlistID: Fixture.id(1), handle: Fixture.id(2)).quoteRef == nil)
    }

    @Test func inboxConversations() throws {
        let rows = try Fixture.decode([InboxConversation].self, """
        [{"conversation_id":"20000000-0000-4000-8000-000000000001","other_id":"\(Self.bob)","other_username":"bob",
          "other_display_name":"Bob Ray","other_accepts_text_messages":false,"is_closed":false,
          "last_message_at":"2026-10-29T09:00:00Z","last_message_kind":"quote","last_message_preview":"Trust thyself",
          "last_message_sender_id":"\(Self.alice)","unread_count":0,"last_read_at":"2026-10-29T09:00:00.000001Z"},
         {"conversation_id":"20000000-0000-4000-8000-000000000002","other_id":"\(Self.alice)","other_username":null,
          "other_display_name":null,"other_accepts_text_messages":null,"is_closed":true,"last_message_at":null,
          "last_message_kind":null,"last_message_preview":null,"last_message_sender_id":null,"unread_count":3}]
        """)
        #expect(rows[0].other == Profile(id: Self.bobID, username: "bob", displayName: "Bob Ray", acceptsTextMessages: false))
        #expect(rows[0].lastMessageKind == .quote)
        #expect(rows[0].lastMessageIsMine(Self.aliceID))
        #expect(!rows[0].isUnread)
        #expect(rows[1].other == nil)
        #expect(rows[1].isClosed && rows[1].isUnread)
        #expect(try roundTrips(rows[0]))
        #expect(try roundTrips(rows[1]))

        // A message is unread when the other member sent it after your read mark (to the
        // microsecond); with no mark, all of theirs are.
        func message(from sender: UUID, at time: String) throws -> Message {
            Message(
                id: UUID(), conversationID: rows[0].id, senderID: sender, kind: .text, text: "Hi",
                createdAt: try #require(Timestamp.date(from: time))
            )
        }
        #expect(rows[0].lastReadAt == Timestamp.date(from: "2026-10-29T09:00:00.000001Z"))
        #expect(!rows[0].isUnread(try message(from: Self.bobID, at: "2026-10-29T09:00:00.000001Z")))
        #expect(rows[0].isUnread(try message(from: Self.bobID, at: "2026-10-29T09:00:00.000002Z")))
        #expect(!rows[0].isUnread(try message(from: Self.aliceID, at: "2026-10-29T10:00:00Z")), "your own")
        #expect(rows[1].lastReadAt == nil)
        #expect(rows[1].isUnread(try message(from: Self.aliceID, at: "2000-01-01T00:00:00Z")))

        let badge = InboxBadge(conversations: rows, friendRequests: 1)
        #expect(badge.count == 2)
        #expect(badge.label == "2")
        #expect(badge.accessibilityValue == "1 unread conversation, 1 friend request")
    }

    @Test func seenMarksStopAtWhatWasShown() throws {
        func at(_ time: String) throws -> Date { try #require(Timestamp.date(from: time)) }
        let withBob = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let withCara = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let caraID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        func quote(_ conversation: UUID, from sender: UUID, at time: String) throws -> Message {
            Message(
                id: UUID(), conversationID: conversation, senderID: sender, kind: .quote,
                quote: QuoteSnapshot(body: "Q"), createdAt: try at(time)
            )
        }
        // Bob sent quote Q1 at 09:00, then a text at 09:05 the app never fetched (the Inbox row's
        // latest message, unread 2). Cara's row is unread only because of a text: no quote of hers
        // is shown.
        let bob = InboxConversation(
            id: withBob, otherID: Self.bobID, lastMessageAt: try at("2026-10-29T09:05:00Z"),
            lastMessageKind: .text, lastMessageSenderID: Self.bobID, unreadCount: 2,
            lastReadAt: try at("2026-10-29T08:00:00Z")
        )
        let cara = InboxConversation(
            id: withCara, otherID: caraID, lastMessageAt: try at("2026-10-29T09:10:00Z"),
            lastMessageKind: .text, lastMessageSenderID: caraID, unreadCount: 1
        )
        let q1 = try quote(withBob, from: Self.bobID, at: "2026-10-29T09:00:00Z")
        let older = try quote(withBob, from: Self.bobID, at: "2026-10-29T07:00:00Z")
        let marks = InboxConversation.seenMarks([bob, cara], shown: [q1, older])
        #expect(marks == [withBob: try at("2026-10-29T09:00:00Z")], "up to Q1, not the unfetched text; nothing for Cara")

        // The local row until the next refresh: the mark moves to Q1, and the text stays unread.
        let marked = bob.markedRead(upTo: try at("2026-10-29T09:00:00Z"), shown: [q1, older])
        #expect(marked.lastReadAt == (try at("2026-10-29T09:00:00Z")))
        #expect(marked.unreadCount == 1 && marked.isUnread)
        #expect(!marked.isUnread(q1))

        // A refresh race: the quotes read saw Q3 only, the Inbox read already Q4 (newer). Marking up
        // to Q3 leaves Q4 unread for the next refresh, which then shows it as new.
        let q3 = try quote(withBob, from: Self.bobID, at: "2026-10-29T10:00:00Z")
        let raced = InboxConversation(
            id: withBob, otherID: Self.bobID, lastMessageAt: try at("2026-10-29T10:01:00Z"),
            lastMessageKind: .quote, lastMessageSenderID: Self.bobID, unreadCount: 2,
            lastReadAt: try at("2026-10-29T09:30:00Z")
        )
        #expect(InboxConversation.seenMarks([raced], shown: [q3]) == [withBob: try at("2026-10-29T10:00:00Z")])
        let q4 = try quote(withBob, from: Self.bobID, at: "2026-10-29T10:01:00Z")
        let afterRace = raced.markedRead(upTo: try at("2026-10-29T10:00:00Z"), shown: [q3])
        #expect(afterRace.isUnread(q4), "Q4 is still new")
        #expect(afterRace.unreadCount == 1)

        // Everything shown is the newest message: the row is read. Seen already: no mark.
        let caught = InboxConversation(
            id: withBob, otherID: Self.bobID, lastMessageAt: try at("2026-10-29T09:00:00Z"),
            lastMessageKind: .quote, lastMessageSenderID: Self.bobID, unreadCount: 1
        )
        #expect(caught.markedRead(upTo: try at("2026-10-29T09:00:00Z"), shown: [q1]).unreadCount == 0)
        #expect(InboxConversation.seenMarks([marked], shown: [q1, older]).isEmpty)

        // Your own messages and other conversations' are not the other member's quotes to mark;
        // a mark never moves back.
        let mine = try quote(withBob, from: Self.aliceID, at: "2026-10-29T11:00:00Z")
        #expect(InboxConversation.seenMarks([bob], shown: [mine]).isEmpty)
        let ahead = InboxConversation(id: withBob, otherID: Self.bobID, unreadCount: 0, lastReadAt: try at("2026-10-29T12:00:00Z"))
        #expect(ahead.markedRead(upTo: try at("2026-10-29T09:00:00Z"), shown: []).lastReadAt == (try at("2026-10-29T12:00:00Z")))
    }

    @Test func inboxBadge() {
        #expect(InboxBadge(unreadConversations: 0, friendRequests: 0).label == nil)
        #expect(InboxBadge(unreadConversations: 0, friendRequests: 0).accessibilityValue == nil)
        #expect(InboxBadge(unreadConversations: 2, friendRequests: 1).accessibilityValue == "2 unread conversations, 1 friend request")
        #expect(InboxBadge(unreadConversations: 0, friendRequests: 3).accessibilityValue == "3 friend requests")
        #expect(InboxBadge(unreadConversations: 99, friendRequests: 0).label == "99")
        #expect(InboxBadge(unreadConversations: 98, friendRequests: 2).label == "99+")
        #expect(InboxBadge(unreadConversations: -1, friendRequests: 0).count == 0)
    }

    // MARK: Playlists

    @Test func playlistView() throws {
        let view = try Fixture.decode(PlaylistView?.self, """
        {"playlist":{"id":"40000000-0000-4000-8000-000000000001","title":"Courage","visibility":"friends",
          "updated_at":"2026-10-29T09:00:00Z","owner":{"id":"\(Self.bob)","username":"maya","display_name":"Maya Reyes"}},
         "items":[{"handle":"50000000-0000-4000-8000-000000000001","position":0,"body":"Be bold","body_format":[],
                   "author":"Anon","source":null,"verified_starter_id":null,"creator_username":"bob","edited_from_username":"alice"},
                  {"handle":"50000000-0000-4000-8000-000000000002","position":1024,"body":"Hope","body_format":[],
                   "author":"Emily Dickinson","source":null,"verified_starter_id":3,"creator_username":null,"edited_from_username":null}]}
        """)
        let playlist = try #require(view)
        #expect(playlist.owner.displayName == "Maya Reyes")
        #expect(playlist.count == 2)
        #expect(playlist.items[0].provenance == Provenance(creatorUsername: "bob", editedFromUsername: "alice"))
        #expect(playlist.items[1].provenance == .catalog(3))
        #expect(playlist.snapshotRef(for: playlist.items[0])
            == .playlistItem(playlistID: playlist.id, handle: playlist.items[0].id))
        #expect(try roundTrips(playlist))
        #expect(try Fixture.decode(PlaylistView?.self, "null") == nil, "not available")
    }

    @Test func ownPlaylistAndItsOrder() throws {
        let json = """
        {"id":"40000000-0000-4000-8000-000000000001","owner_id":"\(Self.alice)","title":"Courage","visibility":"private",
         "held_at":null,"created_at":"2026-10-29T09:00:00Z","updated_at":"2026-10-29T10:00:00Z"}
        """
        var playlist = try Fixture.decode(Playlist.self, json)
        #expect(playlist.visibility == .onlyMe)
        #expect(playlist.entries.isEmpty, "a playlists row has no items")
        let early = Date(timeIntervalSince1970: 1)
        let late = Date(timeIntervalSince1970: 2)
        playlist = Playlist(
            id: playlist.id, ownerID: playlist.ownerID, title: playlist.title, createdAt: playlist.createdAt,
            entries: [
                PlaylistEntry(playlistID: playlist.id, quoteID: Fixture.id(3), position: 2048, addedAt: early),
                PlaylistEntry(playlistID: playlist.id, quoteID: Fixture.id(2), position: 0, addedAt: late),
                PlaylistEntry(playlistID: playlist.id, quoteID: Fixture.id(1), position: 0, addedAt: early),
            ]
        )
        #expect(playlist.quoteIDs == [Fixture.id(1), Fixture.id(2), Fixture.id(3)], "position, then when added")
        #expect(playlist.contains(Fixture.id(2)) && !playlist.contains(Fixture.id(9)))
        #expect(!playlist.isFull)
        #expect(try roundTrips(playlist))
    }

    @Test func appendedPositions() {
        #expect(PlaylistOrder.appended(count: 3, after: nil) == [0, 1024, 2048])
        #expect(PlaylistOrder.appended(count: 2, after: 5) == [1029, 2053])
        #expect(PlaylistOrder.appended(count: 0, after: 5).isEmpty)
    }

    /// Applies a plan and checks the result is strictly increasing.
    func apply(_ positions: [Int]) -> (changed: Int, result: [Int]) {
        let plan = PlaylistOrder.plan(positions)
        let result = zip(positions, plan).map { $1 ?? $0 }
        #expect(zip(result, result.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing: \(result)")
        #expect(result.allSatisfy { $0 >= 0 })
        return (plan.compactMap { $0 }.count, result)
    }

    @Test func reorderPlans() {
        #expect(PlaylistOrder.plan([]).isEmpty)
        // Already in order: nothing moves.
        #expect(apply([0, 1024, 2048]).changed == 0)
        // Moving the last item to the front: the run [0, 1024, 2048] stays and only it moves, into
        // the room below 0? There is none, so it can't go before 0 without renumbering. With room
        // (the first item at 1024) one write is enough.
        let toFront = apply([3072, 1024, 2048, 4096])
        #expect(toFront.changed == 1)
        // Moving the first to the end appends after the last.
        #expect(apply([1024, 2048, 3072, 0]).result.last == 3072 + PlaylistOrder.spacing)
        // A middle move lands between its neighbours.
        let middle = apply([0, 2048, 1024, 3072])
        #expect(middle.changed == 1)
        // Dense positions (a saved copy) have no room: everything is renumbered.
        let dense = apply([1, 0, 2])
        #expect(dense.result == [0, 1024, 2048])
        // Duplicates (positions need not be unique) end up distinct.
        _ = apply([5, 5, 5])
        _ = apply([7, 3, 3, 9, 1, 0, 12])
    }

    @Test func playlistTitles() throws {
        #expect(try SocialText.playlistTitle("  Courage ") == "Courage")
        #expect(throws: SocialTextError.emptyTitle) { try SocialText.playlistTitle("   ") }
        #expect(throws: SocialTextError.titleTooLong(maximum: 60)) { try SocialText.playlistTitle(String(repeating: "t", count: 61)) }
        #expect(try SocialText.playlistTitle(String(repeating: "t", count: 60)).count == 60)
    }

    // MARK: Profiles

    @Test func profilePage() throws {
        let page = try #require(try Fixture.decode(ProfilePage?.self, """
        {"profile":{"id":"\(Self.bob)","username":"maya","display_name":"Maya"},"relationship":"friend",
         "posts":[{"id":"10000000-0000-4000-8000-000000000001","caption":null,"body":"Be bold","body_format":[],
                   "author":"Anon","source":null,"verified_starter_id":null,"creator_username":"maya",
                   "edited_from_username":null,"audience":"friends","created_at":"2026-10-29T09:00:00Z"}],
         "playlists":[{"id":"40000000-0000-4000-8000-000000000001","title":"Courage","visibility":"friends",
                       "item_count":12,"updated_at":"2026-10-29T09:00:00Z"}],
         "favorites":[{"id":"50000000-0000-4000-8000-000000000001","body":"Hope","body_format":[],"author":"Emily Dickinson",
                       "source":null,"verified_starter_id":3,"creator_username":null,"edited_from_username":null,
                       "favorited_at":"2026-10-28T09:00:00Z"}]}
        """))
        #expect(page.relationship == .friend)
        #expect(page.posts.first?.posterID == Self.bobID, "profile_view posts belong to the page's profile")
        #expect(page.posts.first?.poster?.username == "maya")
        #expect(page.posts.first?.provenance.who(viewer: "maya") == .you)
        #expect(page.playlists.first?.itemCount == 12)
        #expect(page.favorites?.first?.provenance == .catalog(3))
        #expect(page.snapshotRef(for: try #require(page.favorites?.first)) == .favorite(friendID: Self.bobID, handle: try #require(page.favorites?.first?.id)))
        #expect(!page.isEmpty)
        #expect(page.nextPostsBefore == nil, "a short page is the last")
        #expect(try roundTrips(page))

        let blocked = try #require(try Fixture.decode(ProfilePage?.self, """
        {"profile":{"id":"\(Self.bob)","username":"maya","display_name":null},"relationship":"you_blocked",
         "posts":[],"playlists":[],"favorites":null}
        """))
        #expect(blocked.relationship == .youBlocked)
        #expect(blocked.favorites == nil)
        #expect(blocked.isEmpty)
        #expect(try Fixture.decode(ProfilePage?.self, "null") == nil)
    }

    // MARK: Reports

    @Test func reportTargets() {
        let user = Fixture.id(1)
        #expect(ReportTarget.profile(userID: user).reportedUserID == user)
        #expect(ReportTarget.post(id: Fixture.id(2), posterID: user).kind == "post")
        #expect(ReportTarget.message(id: Fixture.id(2), senderID: user).reportedUserID == user)
        #expect(ReportTarget.playlist(id: Fixture.id(2), ownerID: user).kind == "playlist")
        #expect(ReportTarget.catalogQuote(3).reportedUserID == nil)
        #expect(ReportTarget.catalogQuote(3).kind == "catalog_quote")

        let created = Date(timeIntervalSince1970: 0)
        let message = Message(
            id: Fixture.id(3), conversationID: Fixture.id(4), senderID: user, kind: .quote, note: "n",
            quote: QuoteSnapshot(body: "B", author: "A", source: "S"), createdAt: created
        )
        #expect(ReportContent(message: message) == ReportContent(body: "B", author: "A", source: "S", note: "n"))
        let post = Post(id: Fixture.id(5), posterID: user, quote: QuoteSnapshot(body: "P"), caption: "c", createdAt: created)
        #expect(ReportContent(post: post) == ReportContent(body: "P", note: "c"))
    }
}
