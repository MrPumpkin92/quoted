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

    @Test func feedPostWithPosterEmbed() throws {
        let json = """
        [{"id":"5e000000-0000-4000-8000-000000000001","author_id":"\(Self.alice)","starter_quote_id":null,"caption":"for you",
          "body":"Be bold","body_format":[{"start":3,"length":4,"bold":true,"underline":true}],"author":"Anon","source":null,
          "creator_id":"\(Self.bob)","creator_username":"bob","edited_from_id":null,"edited_from_username":null,
          "verified_starter_id":null,"audience":"friends","held_at":null,"created_at":"2026-10-19T05:00:00.5+00:00",
          "poster":{"id":"\(Self.alice)","username":"alice","display_name":"Alice","accepts_text_messages":true}}]
        """
        let post = try #require(try decode([Post].self, json).first)
        #expect(post.poster?.handle == "@alice")
        #expect(post.quote.format == [TextRun(start: 3, length: 4, bold: true, underline: true)])
        #expect(post.caption == "for you")
        #expect(post.provenance.who(viewer: "alice") == .person("bob"))
        #expect(post.quote.creatorID == Self.bob)
    }

    @Test func malformedEmbedDoesNotFailTheRow() throws {
        let json = """
        {"id":"5e000000-0000-4000-8000-000000000002","author_id":"\(Self.alice)","body":"Hi","body_format":[],
         "author":null,"source":null,"caption":null,"created_at":"2026-10-19T05:00:00Z","poster":{"oops":true}}
        """
        let post = try decode(Post.self, json)
        #expect(post.poster == nil)
        #expect(post.quote.body == "Hi")
    }

    @Test func messagePageAndInboxRows() throws {
        let messages = try decode([Message].self, """
        [{"id":"30000000-0000-4000-8000-000000000002","conversation_id":"20000000-0000-4000-8000-000000000001",
          "sender_id":"\(Self.bob)","kind":"text","text":"See you at 6.","note":null,"body":null,"body_format":null,
          "author":null,"source":null,"creator_id":null,"creator_username":null,"edited_from_id":null,
          "edited_from_username":null,"verified_starter_id":null,"starter_quote_id":null,"playlist_id":null,
          "playlist_title":null,"created_at":"2026-10-29T09:01:00+00:00"},
         {"id":"30000000-0000-4000-8000-000000000001","conversation_id":"20000000-0000-4000-8000-000000000001",
          "sender_id":"\(Self.alice)","kind":"quote","text":null,"note":"for you","body":"Trust thyself.",
          "body_format":[],"author":"Ralph Waldo Emerson","source":"Self-Reliance","creator_id":null,
          "creator_username":null,"edited_from_id":null,"edited_from_username":null,"verified_starter_id":1,
          "starter_quote_id":1,"playlist_id":null,"playlist_title":null,"created_at":"2026-10-29T09:00:00+00:00"}]
        """)
        #expect(messages.map(\.kind) == [.text, .quote])
        #expect(messages[1].quote?.isVerified == true)
        #expect(messages[1].note == "for you")

        let inbox = try decode([InboxConversation].self, """
        [{"conversation_id":"20000000-0000-4000-8000-000000000001","other_id":"\(Self.bob)","other_username":"bob",
          "other_display_name":null,"other_accepts_text_messages":true,"is_closed":false,
          "last_message_at":"2026-10-29T09:01:00+00:00","last_message_kind":"text","last_message_preview":"See you at 6.",
          "last_message_sender_id":"\(Self.bob)","unread_count":1}]
        """)
        #expect(inbox.first?.other?.displayName == "bob")
        #expect(inbox.first?.isUnread == true)
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

    @Test func catalogQuotes() throws {
        let json = """
        [{"id":1,"body":"Trust thyself.","body_format":[],"author":"Ralph Waldo Emerson","source":"Self-Reliance",
          "source_location":"Essays: First Series (1841), 3rd paragraph","source_url":"https://www.gutenberg.org/ebooks/2944",
          "speaker":null,"themes":["self","courage"],"is_starter":true,"sort_order":1,"status":"live"},
         {"id":61,"body":"A thing of beauty is a joy for ever:","body_format":[{"start":2,"length":5,"italic":true}],
          "author":"John Keats","source":"Endymion","source_location":"Book I, line 1",
          "source_url":"https://www.gutenberg.org/ebooks/24280","speaker":null,"themes":["nature"],
          "is_starter":false,"sort_order":null,"status":"retired"}]
        """
        let quotes = try decode([CatalogQuote].self, json)
        #expect(quotes.map(\.id) == [1, 61])
        #expect(quotes.map(\.isStarter) == [true, false])
        #expect(quotes.map(\.sortOrder) == [1, nil])
        #expect(quotes.map(\.themes) == [[.selfhood, .courage], [.nature]])
        #expect(quotes.map(\.status) == [.live, .retired])
        #expect(quotes.map(\.libraryOrigin) == [.starter, .catalog])
        #expect(quotes[1].format == [TextRun(start: 2, length: 5, italic: true)])
        #expect(quotes[0].sourceURL?.host() == "www.gutenberg.org")
        #expect(CatalogQuote.sections(quotes).map(\.theme) == [.nature, .selfhood])
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

    @Test func quoteProvenanceColumns() throws {
        let quote = try decode(Quote.self, """
        {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a01","body":"Mine now","created_at":"2026-10-19T03:26:38+00:00",
         "origin":"shared","creator_id":"\(Self.alice)","creator_username":"alice","edited_from_id":"\(Self.bob)",
         "edited_from_username":"bob"}
        """)
        #expect(quote.creatorID == Self.alice)
        #expect(quote.editedFromID == Self.bob)
        #expect(quote.provenance.who(viewer: "alice") == .you)
        #expect(quote.provenance.editedFrom(viewer: "alice") == .person("bob"))
        // Older rows and caches have none of the columns: "Added by a person".
        let older = try decode(Quote.self, #"{"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a02","body":"Hi","created_at":"2026-10-19T03:26:38+00:00"}"#)
        #expect(older.provenance == Provenance())
        // The cache keeps them.
        let cached = try decode(Quote.self, String(decoding: try QuotedJSON.makeEncoder().encode(quote), as: UTF8.self))
        #expect(cached == quote)
    }

    @Test func verificationFields() throws {
        let quote = try decode(Quote.self, """
        {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a01","body":"Trust thyself.","body_format":[],"author":"Ralph Waldo Emerson",
         "source":"Self-Reliance","origin":"starter","rotation_position":null,"created_at":"2026-10-19T03:26:38+00:00",
         "updated_at":"2026-10-19T03:26:38+00:00","verified_starter_id":1}
        """)
        #expect(quote.verifiedStarterID == 1)
        #expect(quote.isVerified)
        // Rows and caches from before the column existed read as not verified.
        let older = try decode(Quote.self, #"{"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a02","body":"Hi","created_at":"2026-10-19T03:26:38+00:00"}"#)
        #expect(older.isVerified == false)
        // The local cache keeps it.
        let cached = try decode(Quote.self, String(decoding: try QuotedJSON.makeEncoder().encode(quote), as: UTF8.self))
        #expect(cached.verifiedStarterID == 1)

        #expect(quote.provenance.isChecked)

        let starters = try decode([StarterQuote].self, """
        [{"id":1,"body":"Trust thyself.","body_format":[],"author":"Ralph Waldo Emerson","source":"Self-Reliance","sort_order":1,
          "source_location":"Essays: First Series (1841), 3rd paragraph","source_url":"https://www.gutenberg.org/ebooks/2944"},
         {"id":2,"body":"Hope","body_format":[],"author":"Emily Dickinson","source":null,"sort_order":2,
          "source_location":"Stanza 1","source_url":"not a url"}]
        """)
        #expect(starters[0].sourceLocation == "Essays: First Series (1841), 3rd paragraph")
        #expect(starters[0].sourceURL?.host() == "www.gutenberg.org")
        // A malformed link drops only the link.
        #expect(starters[1].sourceLocation == "Stanza 1")
        #expect(starters[1].sourceURL?.scheme == nil)
    }

    @Test func favoritesAndProfileVisibility() throws {
        let quote = try decode(Quote.self, """
        {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a01","body":"Hi","created_at":"2026-10-19T03:26:38+00:00",
         "is_favorite":true,"favorited_at":"2026-10-25T09:00:00+00:00"}
        """)
        #expect(quote.isFavorite)
        #expect(quote.favoritedAt != nil)
        // Older rows and caches have neither field.
        let older = try decode(Quote.self, #"{"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a02","body":"Hi","created_at":"2026-10-19T03:26:38+00:00"}"#)
        #expect(older.isFavorite == false)
        #expect(older.favoritedAt == nil)

        let quiet = try decode(Profile.self, #"{"id":"\#(Self.alice)","username":"alice","display_name":null,"accepts_text_messages":false}"#)
        #expect(quiet.acceptsTextMessages == false)
        let embedded = try decode(Profile.self, #"{"id":"\#(Self.alice)","username":"alice","display_name":null}"#)
        #expect(embedded.acceptsTextMessages == nil, "unknown, never read as on")

        let favorites = try decode([FriendFavorite].self, """
        [{"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a03","body":"Trust thyself.","body_format":[{"start":0,"length":5,"bold":true}],
          "author":"Ralph Waldo Emerson","source":"Self-Reliance","verified_starter_id":1,"creator_username":null,
          "edited_from_username":null,"favorited_at":"2026-10-25T09:00:00+00:00"},
         {"id":"0b9e6f1c-3a52-4d55-9c1f-7f6f3c1e2a04","body":"Mine","body_format":[],"author":null,"source":null,
          "verified_starter_id":null,"creator_username":"alice","edited_from_username":"bob","favorited_at":null}]
        """)
        #expect(favorites.first?.isVerified == true)
        #expect(favorites.first?.format.first?.bold == true)
        #expect(favorites[1].provenance == Provenance(creatorUsername: "alice", editedFromUsername: "bob"))
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
        // The heart comes back with Undo; timestamps stay the server's.
        #expect(Set(json.keys) == ["id", "body", "body_format", "author", "source", "origin", "rotation_position", "is_favorite"])
        #expect(json["id"] as? String == quote.id.uuidString)
        #expect(json["body"] as? String == "Back")
        #expect(isNull(json["author"]))
        #expect(json["origin"] as? String == "shared")
        #expect(json["rotation_position"] as? Int == 4)
    }

    @Test func profileReportAndEventPayloads() throws {
        let profile = try object(ProfileInsert(id: UUID(), username: "ada", displayName: nil))
        #expect(isNull(profile["display_name"]))
        #expect(Set(profile.keys) == ["id", "username", "display_name"])

        let report = try object(ReportInsert(userID: UUID(), reason: .harassment, details: nil, content: nil))
        #expect(report["reason"] as? String == "harassment")
        #expect(isNull(report["message_id"]))
        #expect(report["reporter_id"] == nil)

        #expect(try object(EventInsert.webSearchTap) as NSDictionary == ["name": "web_search_tap"])
        #expect(try object(FriendshipStatusUpdate(status: .accepted)) as NSDictionary == ["status": "accepted"])
        #expect(try object(FriendRequestInsert(addresseeID: DecodingTests.bob))["addressee_id"] as? String
            == DecodingTests.bob.uuidString)
        #expect(try object(FavoritesVisibilityUpdate(favoritesVisibility: .onlyMe)) as NSDictionary == ["favorites_visibility": "private"])
        #expect(try object(AcceptsTextMessagesUpdate(acceptsTextMessages: false)) as NSDictionary == ["accepts_text_messages": false])
        #expect(try object(AcceptTermsParams(version: 1)) as NSDictionary == ["p_version": 1])
        // profile_view goes as GET: a nil p_before is left out (its default), never sent as "null".
        let view = try object(ProfileViewParams(username: "maya", before: nil))
        #expect(view as NSDictionary == ["p_username": "maya"])
        let set = try object(SetPlaylistPositionsParams(playlist: DecodingTests.bob, quoteIDs: [DecodingTests.bob], positions: [3]))
        #expect(set as NSDictionary == [
            "p_playlist": DecodingTests.bob.uuidString, "p_quote_ids": [DecodingTests.bob.uuidString], "p_positions": [3],
        ])
    }

    @Test func postPayloadsNameOneSource() throws {
        let id = UUID(), quoteID = UUID()
        let own = try object(PostInsert(id: id, source: .quote(quoteID), caption: nil, audience: .friends))
        #expect(Set(own.keys) == ["id", "source_quote_id", "starter_quote_id", "caption", "audience"])
        #expect(own["source_quote_id"] as? String == quoteID.uuidString)
        #expect(isNull(own["starter_quote_id"]) && isNull(own["caption"]))
        #expect(own["audience"] as? String == "friends")
        let catalog = try object(PostInsert(id: id, source: .catalog(5), caption: "hi", audience: .anyone))
        #expect(catalog["starter_quote_id"] as? Int == 5 && isNull(catalog["source_quote_id"]))
        #expect(catalog["audience"] as? String == "public")
        #expect(try object(AudienceUpdate(audience: .friends)) as NSDictionary == ["audience": "friends"])
    }

    /// A message names only the columns its kind uses, so it never names a column without a grant.
    @Test(arguments: [
        (MessageDraft.text("hi"), ["text"]),
        (.quote(.quote(UUID()), note: "n"), ["source_quote_id", "note"]),
        (.quote(.catalog(3)), ["starter_quote_id"]),
        (.quote(.post(UUID())), ["source_post_id"]),
        (.quote(.message(UUID()), note: "fwd"), ["source_message_id", "note"]),
        (.playlist(UUID()), ["playlist_id"]),
    ])
    func messagePayloads(draft: MessageDraft, keys: [String]) throws {
        let json = try object(MessageInsert(id: UUID(), conversationID: UUID(), draft: draft))
        #expect(Set(json.keys) == Set(["id", "conversation_id", "kind"] + keys))
        #expect(json["kind"] as? String == draft.kind.rawValue)
        #expect(json.values.allSatisfy { !($0 is NSNull) })
    }

    @Test func saveAndPlaylistPayloads() throws {
        let id = UUID(), source = UUID(), handle = UUID()
        let fromPost = try object(SaveParams(source: .post(source), id: id, inReminders: false))
        #expect(Set(fromPost.keys) == ["p_post", "p_id", "p_in_reminders"])
        let fromFavorite = try object(SaveParams(source: .favorite(friendID: source, handle: handle), id: id, inReminders: true))
        #expect(Set(fromFavorite.keys) == ["p_friend", "p_handle", "p_id", "p_in_reminders"])
        #expect(SaveParams(source: .catalog(1), id: id, inReminders: false).function == nil)
        #expect(SaveParams(source: .playlistItem(playlistID: source, handle: handle), id: id, inReminders: false).function
            == "save_from_playlist")

        #expect(Set(try object(PlaylistInsert(id: id, title: "T", visibility: .onlyMe)).keys) == ["id", "title", "visibility"])
        #expect(try object(PlaylistInsert(id: id, title: "T", visibility: .onlyMe))["visibility"] as? String == "private")
        #expect(Set(try object(PlaylistItemInsert(playlistID: id, quoteID: source, position: 0)).keys)
            == ["playlist_id", "quote_id", "position"])
        let copy = try object(SavePlaylistCopyParams(playlist: id, title: nil))
        #expect(Set(copy.keys) == ["p_playlist", "p_title"] && isNull(copy["p_title"]))
        #expect(try object(PlaylistParam(playlist: id)) as NSDictionary == ["p_playlist": id.uuidString])
        #expect(try object(FriendParam(friend: id)) as NSDictionary == ["p_friend": id.uuidString])
    }

    @Test func timestampsUsePostgresFormat() throws {
        let date = Date(timeIntervalSince1970: 1_792_380_398.25)
        let json = try object(LastReadUpdate(lastReadAt: date))
        let text = try #require(json["last_read_at"] as? String)
        #expect(text.hasSuffix("Z"))
        #expect(Timestamp.date(from: text) == date)
    }
}
