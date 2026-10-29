import Foundation
import QuotedCore

// Request payloads and partial rows. Internal: the public API speaks QuotedCore models, which decode
// PostgREST rows directly (their CodingKeys are the snake_case column names).
//
// Payloads write explicit nulls for optional columns. That lets an update clear a column, and keeps
// every object in a bulk insert or upsert on the same keys.

/// Table names.
enum Table {
    static let profiles = "profiles"
    static let quotes = "quotes"
    static let friendships = "friendships"
    static let blocks = "blocks"
    static let reports = "reports"
    static let starterQuotes = "starter_quotes"
    static let events = "events"
    static let posts = "posts"
    static let playlists = "playlists"
    static let playlistItems = "playlist_items"
    static let conversations = "conversations"
    static let conversationMembers = "conversation_members"
    static let messages = "messages"
}

/// Database functions called through PostgREST (`/rest/v1/rpc/<name>`). Each public function is a
/// SECURITY INVOKER wrapper over its `private` half; the argument names are part of the contract.
enum RPC {
    /// `public.set_rotation(ordered uuid[], removed uuid[]) returns setof quotes` (SECURITY INVOKER).
    static let setRotation = "set_rotation"
    /// `public.find_profile(p_username text)`: at most one profile, exact username, none for a
    /// blocked pair or yourself (migration `20261021090000_abuse_limits_privacy_cleanup`).
    static let findProfile = "find_profile"
    /// `public.is_username_available(p_username text) returns boolean` (reserved names are taken).
    static let isUsernameAvailable = "is_username_available"
    /// `public.touch_activity()`: stamps the caller's `profiles.last_active_at`, at most every 12 h.
    static let touchActivity = "touch_activity"
    /// `public.friend_favorites(p_user uuid)`: an accepted friend's favorites when they share them.
    static let friendFavorites = "friend_favorites"
    /// `public.my_account()`: the caller's own profile with its private fields (one row or none).
    static let myAccount = "my_account"
    /// `public.accept_terms(p_version smallint)`.
    static let acceptTerms = "accept_terms"
    /// `public.add_catalog_quotes(p_starter_ids smallint[], p_ids uuid[], p_in_reminders boolean)`.
    static let addCatalogQuotes = "add_catalog_quotes"
    /// `public.save_from_favorite(p_friend uuid, p_handle uuid, p_id uuid, p_in_reminders boolean)`.
    static let saveFromFavorite = "save_from_favorite"
    /// `public.playlist_view(p_playlist uuid) returns jsonb`.
    static let playlistView = "playlist_view"
    /// `public.save_from_playlist(p_playlist uuid, p_handle uuid, p_id uuid, p_in_reminders boolean)`.
    static let saveFromPlaylist = "save_from_playlist"
    /// `public.save_playlist_copy(p_playlist uuid, p_title text) returns playlists`.
    static let savePlaylistCopy = "save_playlist_copy"
    /// `public.save_from_post(p_post uuid, p_id uuid, p_in_reminders boolean)`.
    static let saveFromPost = "save_from_post"
    /// `public.open_conversation(p_friend uuid) returns conversations`.
    static let openConversation = "open_conversation"
    /// `public.inbox_conversations()`: one row per conversation the caller may read.
    static let inboxConversations = "inbox_conversations"
    /// `public.received_quotes(p_after_created_at timestamptz, p_after_id uuid, p_limit integer)`:
    /// the quote messages other people sent the caller, newest first (SECURITY INVOKER, STABLE).
    static let receivedQuotes = "received_quotes"
    /// `public.save_from_message(p_message uuid, p_id uuid, p_in_reminders boolean)`.
    static let saveFromMessage = "save_from_message"
    /// `public.profile_view(p_username text, p_before timestamptz) returns jsonb`.
    static let profileView = "profile_view"
    /// `public.set_playlist_positions(p_playlist uuid, p_quote_ids uuid[], p_positions integer[])
    /// returns setof playlist_items` (SECURITY INVOKER).
    static let setPlaylistPositions = "set_playlist_positions"
}

/// `select` column lists, with embeds through the stable foreign-key names (`<table>_<column>_fkey`).
/// Every read lists its columns: `profiles`, `posts`, `messages` and `reports` have column grants,
/// so `*` (or an embed without a column list) fails with 42501.
enum Columns {
    /// What clients may read of any profile (the column grant).
    static let profile = "id, username, display_name, accepts_text_messages"
    /// What `public.find_profile` returns.
    static let foundProfile = "id, username, display_name"

    static let quote = """
        id, body, body_format, author, source, origin, rotation_position, created_at, updated_at, \
        verified_starter_id, is_favorite, favorited_at, creator_id, creator_username, edited_from_id, edited_from_username
        """

    static let friendship = """
        id, requester_id, addressee_id, status, created_at, responded_at, \
        requester:profiles!friendships_requester_id_fkey(\(profile)), \
        addressee:profiles!friendships_addressee_id_fkey(\(profile))
        """

    static let blockedProfile = "blocked_id, blocked:profiles!blocks_blocked_id_fkey(\(profile))"

    static let starterQuote = "id, body, body_format, author, source, sort_order, source_location, source_url"

    /// Every `posts` column clients may read (all but `source_quote_id`).
    static let post = """
        id, author_id, starter_quote_id, caption, body, body_format, author, source, creator_id, \
        creator_username, edited_from_id, edited_from_username, verified_starter_id, audience, held_at, created_at
        """

    /// Posts with the poster's profile (the Feed).
    static let feedPost = "\(post), poster:profiles!posts_author_id_fkey(\(profile))"

    /// Every `messages` column clients may read (all but the insert-only sources).
    static let message = """
        id, conversation_id, sender_id, kind, text, note, body, body_format, author, source, creator_id, \
        creator_username, edited_from_id, edited_from_username, verified_starter_id, starter_quote_id, \
        playlist_id, playlist_title, created_at
        """

    static let conversationRow = "id, user_a, user_b, created_at, last_message_at, closed_at"

    /// A conversation with both members' profiles.
    static let conversation = """
        \(conversationRow), \
        user_a_profile:profiles!conversations_user_a_fkey(\(profile)), \
        user_b_profile:profiles!conversations_user_b_fkey(\(profile))
        """

    static let conversationMember = "conversation_id, user_id, last_read_at, cleared_at"

    static let playlist = "id, owner_id, title, visibility, held_at, created_at, updated_at"

    static let playlistEntry = "playlist_id, quote_id, position, added_at"

    /// What a reporter may read back of their own reports (never the server's copy).
    static let filedReport = """
        id, reporter_id, reported_user_id, reason, details, created_at, post_id, message_id, playlist_id, \
        starter_quote_id, target_kind
        """
}

// MARK: quotes

struct QuoteInsert: Encodable, Equatable, Sendable {
    /// Chosen by the client, so a retry after a lost answer finds the first insert instead of
    /// adding a second copy (`QuotesRepository`).
    var id: UUID
    var body: String
    var format: [TextRun]
    var author: String?
    var source: String?
    var origin: QuoteOrigin
    var rotationPosition: Int?

    init(_ validated: QuoteDraft.Validated, id: UUID, origin: QuoteOrigin, rotationPosition: Int?) {
        self.id = id
        body = validated.body
        format = validated.format
        author = validated.author
        source = validated.source
        self.origin = origin
        self.rotationPosition = rotationPosition
    }

    enum CodingKeys: String, CodingKey {
        case id, body, author, source, origin
        case format = "body_format"
        case rotationPosition = "rotation_position"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(origin, forKey: .origin)
        try container.encode(rotationPosition, forKey: .rotationPosition)
    }
}

/// The editable content of a quote. Rotation membership changes only through `setRotation`.
struct QuoteContentUpdate: Encodable, Equatable, Sendable {
    var body: String
    var format: [TextRun]
    var author: String?
    var source: String?

    init(_ validated: QuoteDraft.Validated) {
        body = validated.body
        format = validated.format
        author = validated.author
        source = validated.source
    }

    enum CodingKeys: String, CodingKey {
        case body, author, source
        case format = "body_format"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
    }
}

/// A whole `quotes` row for Undo of a delete (a plain insert): the same ID, content, heart and
/// position, only granted columns. `owner_id` defaults to the caller; `created_at` and `updated_at`
/// are set by the server, which also takes the origin and provenance back from its one-day
/// tombstone (the `origin` sent is replaced by the tombstone's).
struct QuoteRestoreRow: Encodable, Equatable, Sendable {
    var id: UUID
    var body: String
    var format: [TextRun]
    var author: String?
    var source: String?
    var origin: QuoteOrigin
    var rotationPosition: Int?
    var isFavorite: Bool

    init(_ quote: Quote, content: QuoteDraft.Validated) {
        id = quote.id
        body = content.body
        format = content.format
        author = content.author
        source = content.source
        origin = quote.origin
        rotationPosition = quote.rotationPosition.map { max(0, $0) }
        isFavorite = quote.isFavorite
    }

    enum CodingKeys: String, CodingKey {
        case id, body, author, source, origin
        case format = "body_format"
        case rotationPosition = "rotation_position"
        case isFavorite = "is_favorite"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(origin, forKey: .origin)
        try container.encode(rotationPosition, forKey: .rotationPosition)
        try container.encode(isFavorite, forKey: .isFavorite)
    }
}

/// The heart on one of your quotes. `favorited_at` is stamped by the server.
struct FavoriteUpdate: Encodable, Equatable, Sendable {
    var isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case isFavorite = "is_favorite"
    }
}

struct RotationPositionRow: Decodable, Sendable {
    var rotationPosition: Int?

    enum CodingKeys: String, CodingKey {
        case rotationPosition = "rotation_position"
    }
}

/// The arguments of `public.set_rotation(ordered uuid[], removed uuid[])`: IDs only, no content.
/// `ordered` is the Rotation in order without repeats (the first occurrence wins); `removed` holds
/// the quotes that leave it, minus any that are also in `ordered` (those stay in the Rotation).
struct SetRotationParams: Encodable, Equatable, Sendable {
    var ordered: [UUID]
    var removed: [UUID]

    init(ordered: [UUID], removing: [UUID]) {
        var seen = Set<UUID>()
        self.ordered = ordered.filter { seen.insert($0).inserted }
        self.removed = removing.filter { seen.insert($0).inserted }
    }

    /// Whether the call would change nothing.
    var isEmpty: Bool { ordered.isEmpty && removed.isEmpty }
}

// MARK: profiles

struct ProfileInsert: Encodable, Equatable, Sendable {
    var id: UUID
    var username: String
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(displayName, forKey: .displayName)
    }
}

struct DisplayNameUpdate: Encodable, Equatable, Sendable {
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
    }
}

/// Whether friends may see your favorites.
struct FavoritesVisibilityUpdate: Encodable, Equatable, Sendable {
    var favoritesVisibility: FavoritesVisibility

    enum CodingKeys: String, CodingKey {
        case favoritesVisibility = "favorites_visibility"
    }
}

/// "Friends can text me".
struct AcceptsTextMessagesUpdate: Encodable, Equatable, Sendable {
    var acceptsTextMessages: Bool

    enum CodingKeys: String, CodingKey {
        case acceptsTextMessages = "accepts_text_messages"
    }
}

/// The argument of `public.accept_terms`.
struct AcceptTermsParams: Encodable, Equatable, Sendable {
    var version: Int

    enum CodingKeys: String, CodingKey {
        case version = "p_version"
    }
}

/// The arguments of `public.profile_view`. `p_before` is sent as an explicit null for the first page.
struct ProfileViewParams: Encodable, Equatable, Sendable {
    var username: String
    var before: Date?

    enum CodingKeys: String, CodingKey {
        case username = "p_username"
        case before = "p_before"
    }

    /// `p_before` is left out when nil (its default): the call goes as GET, where every argument is
    /// a query item and a null would arrive as the text "null".
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(before, forKey: .before)
    }
}

/// The argument of `public.friend_favorites`.
struct FriendFavoritesParam: Encodable, Equatable, Sendable {
    var user: UUID

    enum CodingKeys: String, CodingKey {
        case user = "p_user"
    }
}

/// The argument of `public.find_profile` and `public.is_username_available`.
struct UsernameParam: Encodable, Equatable, Sendable {
    var username: String

    enum CodingKeys: String, CodingKey {
        case username = "p_username"
    }
}

// MARK: friendships and blocks

struct FriendRequestInsert: Encodable, Equatable, Sendable {
    var addresseeID: UUID

    enum CodingKeys: String, CodingKey {
        case addresseeID = "addressee_id"
    }
}

struct FriendshipStatusUpdate: Encodable, Equatable, Sendable {
    var status: FriendshipStatus
}

struct BlockInsert: Encodable, Equatable, Sendable {
    var blockedID: UUID

    enum CodingKeys: String, CodingKey {
        case blockedID = "blocked_id"
    }
}

struct BlockedRow: Decodable, Identifiable, Sendable {
    var blockedID: UUID
    var blocked: Profile?

    var id: UUID { blockedID }

    enum CodingKeys: String, CodingKey {
        case blockedID = "blocked_id"
        case blocked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockedID = try container.decode(UUID.self, forKey: .blockedID)
        blocked = try? container.decodeIfPresent(Profile.self, forKey: .blocked)
    }
}

// MARK: saving other people's quotes

/// The arguments of `public.add_catalog_quotes`: one client id per catalog id, so a retry returns the
/// quotes the first call made.
struct AddCatalogQuotesParams: Encodable, Equatable, Sendable {
    var starterIDs: [Int]
    var ids: [UUID]
    var inReminders: Bool

    enum CodingKeys: String, CodingKey {
        case starterIDs = "p_starter_ids"
        case ids = "p_ids"
        case inReminders = "p_in_reminders"
    }
}

/// The arguments of `save_from_post`, `save_from_message`, `save_from_favorite` and
/// `save_from_playlist`: the source's own arguments, then the client id and Reminders.
struct SaveParams: Encodable, Equatable, Sendable {
    var source: SnapshotRef
    var id: UUID
    var inReminders: Bool

    enum CodingKeys: String, CodingKey {
        case post = "p_post"
        case message = "p_message"
        case friend = "p_friend"
        case playlist = "p_playlist"
        case handle = "p_handle"
        case id = "p_id"
        case inReminders = "p_in_reminders"
    }

    /// The function this source is saved through, or nil for a catalog quote (`add_catalog_quotes`).
    var function: String? {
        switch source {
        case .post: RPC.saveFromPost
        case .message: RPC.saveFromMessage
        case .favorite: RPC.saveFromFavorite
        case .playlistItem: RPC.saveFromPlaylist
        case .catalog: nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .post(let post):
            try container.encode(post, forKey: .post)
        case .message(let message):
            try container.encode(message, forKey: .message)
        case .favorite(let friend, let handle):
            try container.encode(friend, forKey: .friend)
            try container.encode(handle, forKey: .handle)
        case .playlistItem(let playlist, let handle):
            try container.encode(playlist, forKey: .playlist)
            try container.encode(handle, forKey: .handle)
        case .catalog:
            break
        }
        try container.encode(id, forKey: .id)
        try container.encode(inReminders, forKey: .inReminders)
    }
}

// MARK: posts

/// A new post: the quote by reference, never its words. Explicit nulls for the other source.
struct PostInsert: Encodable, Equatable, Sendable {
    /// Chosen by the client (see ``QuoteInsert/id``).
    var id: UUID
    var source: PostDraft.Source
    var caption: String?
    var audience: Audience

    enum CodingKeys: String, CodingKey {
        case id, caption, audience
        case sourceQuoteID = "source_quote_id"
        case starterQuoteID = "starter_quote_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch source {
        case .quote(let quoteID):
            try container.encode(quoteID, forKey: .sourceQuoteID)
            try container.encodeNil(forKey: .starterQuoteID)
        case .catalog(let catalogID):
            try container.encodeNil(forKey: .sourceQuoteID)
            try container.encode(catalogID, forKey: .starterQuoteID)
        }
        try container.encode(caption, forKey: .caption)
        try container.encode(audience, forKey: .audience)
    }
}

/// A post's or playlist's audience change.
struct AudienceUpdate: Encodable, Equatable, Sendable {
    var audience: Audience
}

// MARK: conversations and messages

/// The argument of `public.open_conversation`.
struct FriendParam: Encodable, Equatable, Sendable {
    var friend: UUID

    enum CodingKeys: String, CodingKey {
        case friend = "p_friend"
    }
}

/// The arguments of `public.received_quotes`: a page of `limit` rows after `cursor` (the last row
/// of the page before), or the first page without one. Sent as GET query items, so the cursor is
/// left out when nil (a null would arrive as the text "null"), and its time is written with
/// microseconds (``Timestamp/string(from:)``) so the next page starts exactly after that row.
struct ReceivedQuotesParams: Encodable, Equatable, Sendable {
    var cursor: PageCursor?
    var limit: Int

    enum CodingKeys: String, CodingKey {
        case afterCreatedAt = "p_after_created_at"
        case afterID = "p_after_id"
        case limit = "p_limit"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let cursor {
            try container.encode(Timestamp.string(from: cursor.createdAt), forKey: .afterCreatedAt)
            try container.encode(cursor.id, forKey: .afterID)
        }
        try container.encode(limit, forKey: .limit)
    }
}

/// A new message. Only the columns its kind uses are sent (no nulls for the others), so the body
/// names only granted columns: a quote names exactly one source.
struct MessageInsert: Encodable, Equatable, Sendable {
    /// Chosen by the client (see ``QuoteInsert/id``).
    var id: UUID
    var conversationID: UUID
    var draft: MessageDraft

    enum CodingKeys: String, CodingKey {
        case id, kind, text, note
        case conversationID = "conversation_id"
        case sourceQuoteID = "source_quote_id"
        case starterQuoteID = "starter_quote_id"
        case sourcePostID = "source_post_id"
        case sourceMessageID = "source_message_id"
        case playlistID = "playlist_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(draft.kind, forKey: .kind)
        switch draft {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .quote(let ref, let note):
            switch ref {
            case .quote(let id): try container.encode(id, forKey: .sourceQuoteID)
            case .catalog(let id): try container.encode(id, forKey: .starterQuoteID)
            case .post(let id): try container.encode(id, forKey: .sourcePostID)
            case .message(let id): try container.encode(id, forKey: .sourceMessageID)
            }
            try container.encodeIfPresent(note, forKey: .note)
        case .playlist(let id):
            try container.encode(id, forKey: .playlistID)
        }
    }
}

/// Your read mark: the time of the newest message you have shown. The server keeps it, but never
/// later than its clock, and never moves the mark back.
struct LastReadUpdate: Encodable, Equatable, Sendable {
    var lastReadAt: Date

    enum CodingKeys: String, CodingKey {
        case lastReadAt = "last_read_at"
    }
}

/// "Delete Conversation", for you only. The server replaces the time with its clock.
struct ClearedUpdate: Encodable, Equatable, Sendable {
    var clearedAt: Date

    enum CodingKeys: String, CodingKey {
        case clearedAt = "cleared_at"
    }
}

// MARK: playlists

struct PlaylistInsert: Encodable, Equatable, Sendable {
    /// Chosen by the client (see ``QuoteInsert/id``).
    var id: UUID
    var title: String
    var visibility: Audience
}

struct PlaylistTitleUpdate: Encodable, Equatable, Sendable {
    var title: String
}

struct VisibilityUpdate: Encodable, Equatable, Sendable {
    var visibility: Audience
}

struct PlaylistItemInsert: Encodable, Equatable, Sendable {
    var playlistID: UUID
    var quoteID: UUID
    var position: Int

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case quoteID = "quote_id"
        case position
    }
}

/// The arguments of `public.set_playlist_positions`: `quoteIDs[i]` moves to `positions[i]`.
struct SetPlaylistPositionsParams: Encodable, Equatable, Sendable {
    var playlist: UUID
    var quoteIDs: [UUID]
    var positions: [Int]

    enum CodingKeys: String, CodingKey {
        case playlist = "p_playlist"
        case quoteIDs = "p_quote_ids"
        case positions = "p_positions"
    }
}

struct PositionRow: Decodable, Sendable {
    var position: Int
}

/// The argument of `public.playlist_view`.
struct PlaylistParam: Encodable, Equatable, Sendable {
    var playlist: UUID

    enum CodingKeys: String, CodingKey {
        case playlist = "p_playlist"
    }
}

/// The arguments of `public.save_playlist_copy`. A null title keeps the original.
struct SavePlaylistCopyParams: Encodable, Equatable, Sendable {
    var playlist: UUID
    var title: String?

    enum CodingKeys: String, CodingKey {
        case playlist = "p_playlist"
        case title = "p_title"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playlist, forKey: .playlist)
        try container.encode(title, forKey: .title)
    }
}

// MARK: reports

/// A `reports` row as filed. With a target (post, message, playlist or catalog quote) the server
/// copies the content from its own row and ignores the `content_*` columns; a profile report keeps
/// the content the client sends (what the reporter saw of an item that is already gone),
/// unverified. `target_kind`, `reporter_id` and the snapshot flags are server-owned.
struct ReportInsert: Encodable, Equatable, Sendable {
    var reportedUserID: UUID?
    var reason: ReportReason
    var details: String?
    var postID: UUID? = nil
    var messageID: UUID? = nil
    var playlistID: UUID? = nil
    var starterQuoteID: Int? = nil
    var contentBody: String? = nil
    var contentAuthor: String? = nil
    var contentSource: String? = nil
    var contentNote: String? = nil

    enum CodingKeys: String, CodingKey {
        case reportedUserID = "reported_user_id"
        case reason, details
        case postID = "post_id"
        case messageID = "message_id"
        case playlistID = "playlist_id"
        case starterQuoteID = "starter_quote_id"
        case contentBody = "content_body"
        case contentAuthor = "content_author"
        case contentSource = "content_source"
        case contentNote = "content_note"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reportedUserID, forKey: .reportedUserID)
        try container.encode(reason, forKey: .reason)
        try container.encode(details, forKey: .details)
        try container.encode(postID, forKey: .postID)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(playlistID, forKey: .playlistID)
        try container.encode(starterQuoteID, forKey: .starterQuoteID)
        try container.encode(contentBody, forKey: .contentBody)
        try container.encode(contentAuthor, forKey: .contentAuthor)
        try container.encode(contentSource, forKey: .contentSource)
        try container.encode(contentNote, forKey: .contentNote)
    }
}

extension ReportInsert {
    /// A report about `target`. (In an extension so the memberwise initializer stays available.)
    init(target: ReportTarget, reason: ReportReason, details: String?) {
        self.init(reportedUserID: target.reportedUserID, reason: reason, details: details)
        switch target {
        case .profile: break
        case .post(let id, _): postID = id
        case .message(let id, _): messageID = id
        case .playlist(let id, _): playlistID = id
        case .catalogQuote(let id): starterQuoteID = id
        }
    }

    /// A profile report about `userID` carrying what the reporter saw, cut to the column limits.
    init(userID: UUID, reason: ReportReason, details: String?, content: ReportContent?) {
        self.init(
            reportedUserID: userID,
            reason: reason,
            details: details,
            contentBody: Self.snapshot(content?.body, maxLength: Limits.bodyLength.upperBound),
            contentAuthor: Self.snapshot(content?.author, maxLength: Limits.authorMaxLength),
            contentSource: Self.snapshot(content?.source, maxLength: Limits.sourceMaxLength),
            contentNote: Self.snapshot(content?.note, maxLength: Self.contentNoteMaxLength)
        )
    }

    /// `reports.content_note` holds up to 1000 characters.
    static let contentNoteMaxLength = 1000

    /// `text` cut to the column limit, counted in Unicode scalars like Postgres `char_length`, so an
    /// oversized snapshot can never make the report itself fail.
    static func snapshot(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars
        guard scalars.count > maxLength else { return text }
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars.prefix(maxLength))
        return String(prefix)
    }
}

// MARK: events

struct EventInsert: Encodable, Equatable, Sendable {
    static let webSearchTap = EventInsert(name: "web_search_tap")
    var name: String
}
