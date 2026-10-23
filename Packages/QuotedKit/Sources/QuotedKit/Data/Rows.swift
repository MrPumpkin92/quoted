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
    static let shares = "shares"
    static let reports = "reports"
    static let starterQuotes = "starter_quotes"
    static let events = "events"
}

/// Database functions called through PostgREST (`/rest/v1/rpc/<name>`).
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
}

/// `select` column lists, with embeds through the stable foreign-key names (`<table>_<column>_fkey`).
enum Columns {
    static let profile = "id, username, display_name"

    static let quote = "id, body, body_format, author, source, origin, rotation_position, created_at, updated_at"

    static let friendship = """
        id, requester_id, addressee_id, status, created_at, responded_at, \
        requester:profiles!friendships_requester_id_fkey(\(profile)), \
        addressee:profiles!friendships_addressee_id_fkey(\(profile))
        """

    static let shareFields = "id, sender_id, recipient_id, quote_id, body, body_format, author, source, note, created_at, seen_at, saved_at"

    /// Received shares, with the sender's profile.
    static let inboxShare = "\(shareFields), sender:profiles!shares_sender_id_fkey(\(profile))"

    /// Sent shares, with the recipient's profile.
    static let sentShare = "\(shareFields), recipient:profiles!shares_recipient_id_fkey(\(profile))"

    static let blockedProfile = "blocked_id, blocked:profiles!blocks_blocked_id_fkey(\(profile))"

    static let starterQuote = "id, body, body_format, author, source, sort_order"
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

/// A whole `quotes` row for Undo of a delete: the same ID, content, origin and position.
/// `owner_id` defaults to the caller; `created_at` and `updated_at` are set by the server.
struct QuoteRestoreRow: Encodable, Equatable, Sendable {
    var id: UUID
    var body: String
    var format: [TextRun]
    var author: String?
    var source: String?
    var origin: QuoteOrigin
    var rotationPosition: Int?

    init(_ quote: Quote, content: QuoteDraft.Validated) {
        id = quote.id
        body = content.body
        format = content.format
        author = content.author
        source = content.source
        origin = quote.origin
        rotationPosition = quote.rotationPosition.map { max(0, $0) }
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

// MARK: shares and reports

struct ShareInsert: Encodable, Equatable, Sendable {
    /// Chosen by the client (see ``QuoteInsert/id``).
    var id: UUID
    var recipientID: UUID
    var quoteID: UUID?
    var body: String
    var format: [TextRun]
    var author: String?
    var source: String?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recipientID = "recipient_id"
        case quoteID = "quote_id"
        case body
        case format = "body_format"
        case author, source, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recipientID, forKey: .recipientID)
        try container.encode(quoteID, forKey: .quoteID)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(note, forKey: .note)
    }
}

struct ShareSeenUpdate: Encodable, Equatable, Sendable {
    var seenAt: Date

    enum CodingKeys: String, CodingKey {
        case seenAt = "seen_at"
    }
}

struct ShareSavedUpdate: Encodable, Equatable, Sendable {
    var savedAt: Date

    enum CodingKeys: String, CodingKey {
        case savedAt = "saved_at"
    }
}

/// A `reports` row. The `content_*` columns are a snapshot of the reported content, because a block
/// deletes the share and `share_id` becomes null. When `share_id` is set, the server replaces the
/// snapshot with the share's own content (trigger `private.reports_snapshot_share`). Without a
/// `share_id` it is stored as sent, so a report filed after the share is gone still says what the
/// reporter saw.
struct ReportInsert: Encodable, Equatable, Sendable {
    var shareID: UUID?
    var reportedUserID: UUID
    var reason: ReportReason
    var details: String?
    var contentBody: String? = nil
    var contentAuthor: String? = nil
    var contentSource: String? = nil

    enum CodingKeys: String, CodingKey {
        case shareID = "share_id"
        case reportedUserID = "reported_user_id"
        case reason, details
        case contentBody = "content_body"
        case contentAuthor = "content_author"
        case contentSource = "content_source"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shareID, forKey: .shareID)
        try container.encode(reportedUserID, forKey: .reportedUserID)
        try container.encode(reason, forKey: .reason)
        try container.encode(details, forKey: .details)
        try container.encode(contentBody, forKey: .contentBody)
        try container.encode(contentAuthor, forKey: .contentAuthor)
        try container.encode(contentSource, forKey: .contentSource)
    }
}

extension ReportInsert {
    /// A report on a received share, carrying its content as the snapshot. (In an extension so the
    /// memberwise initializer stays available.)
    init(share: SharedQuote, reason: ReportReason, details: String?) {
        self.init(
            shareID: share.id,
            reportedUserID: share.senderID,
            reason: reason,
            details: details,
            contentBody: Self.snapshot(share.body, maxLength: Limits.bodyLength.upperBound),
            contentAuthor: Self.snapshot(share.author, maxLength: Limits.authorMaxLength),
            contentSource: Self.snapshot(share.source, maxLength: Limits.sourceMaxLength)
        )
    }

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
