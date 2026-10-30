import Foundation

/// A server-built copy of a quote's words as they were when it was posted or sent: the snapshot
/// columns of `posts` and quote `messages` (`body`, `body_format`, `author`, `source`,
/// `verified_starter_id` and both provenance pairs). Only the server writes a snapshot, so nobody can
/// put words under another person's name.
///
/// It decodes from the same JSON object as the row that holds it (the columns sit beside the row's
/// own), and encodes back the same way.
public struct QuoteSnapshot: Hashable, Sendable, RichTextContent {
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    /// The Quoted Catalog quote this wording matches, or nil.
    public var verifiedStarterID: Int?
    /// Who added it. The ids are null in `profile_view` and `playlist_view`, which give usernames only.
    public var creatorID: UUID?
    public var creatorUsername: String?
    public var editedFromID: UUID?
    public var editedFromUsername: String?

    public init(
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        verifiedStarterID: Int? = nil,
        creatorID: UUID? = nil,
        creatorUsername: String? = nil,
        editedFromID: UUID? = nil,
        editedFromUsername: String? = nil
    ) {
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.verifiedStarterID = verifiedStarterID
        self.creatorID = creatorID
        self.creatorUsername = creatorUsername
        self.editedFromID = editedFromID
        self.editedFromUsername = editedFromUsername
    }

    /// Whether the wording and attribution were checked against a public-domain source.
    public var isVerified: Bool { verifiedStarterID != nil }
    /// Who added it and whether Quoted checked it.
    public var provenance: Provenance {
        Provenance(catalogID: verifiedStarterID, creatorUsername: creatorUsername, editedFromUsername: editedFromUsername)
    }
    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }
    /// What a conversation's Copy puts on the clipboard: `“body” — Author, Source`.
    public var shareText: String { RichText.shareText(body: body, author: author, source: source) }
}

extension QuoteSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case body, author, source
        case format = "body_format"
        case verifiedStarterID = "verified_starter_id"
        case creatorID = "creator_id"
        case creatorUsername = "creator_username"
        case editedFromID = "edited_from_id"
        case editedFromUsername = "edited_from_username"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        verifiedStarterID = try container.decodeIfPresent(Int.self, forKey: .verifiedStarterID)
        creatorID = try container.decodeIfPresent(UUID.self, forKey: .creatorID)
        creatorUsername = try container.decodeIfPresent(String.self, forKey: .creatorUsername)
        editedFromID = try container.decodeIfPresent(UUID.self, forKey: .editedFromID)
        editedFromUsername = try container.decodeIfPresent(String.self, forKey: .editedFromUsername)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(verifiedStarterID, forKey: .verifiedStarterID)
        try container.encode(creatorID, forKey: .creatorID)
        try container.encode(creatorUsername, forKey: .creatorUsername)
        try container.encode(editedFromID, forKey: .editedFromID)
        try container.encode(editedFromUsername, forKey: .editedFromUsername)
    }
}

/// A quote you send by reference. The client never sends words: the server copies the snapshot
/// from the source, with its creator, and refuses a source you can't see.
public enum QuoteRef: Hashable, Sendable, Codable {
    /// One of your own quotes (`source_quote_id`).
    case quote(UUID)
    /// A Quoted Catalog quote (`starter_quote_id`).
    case catalog(Int)
    /// A post you can see, forwarded as it is (`source_post_id`).
    case post(UUID)
    /// A quote message you can read, forwarded as it is (`source_message_id`).
    case message(UUID)
}

/// Someone else's quote, as the app reaches it: the route to its read-only screen and the argument
/// of the server's `save_from_*` functions (and `add_catalog_quotes`).
public enum SnapshotRef: Hashable, Sendable, Codable {
    /// A post (`save_from_post`).
    case post(UUID)
    /// A quote message (`save_from_message`).
    case message(UUID)
    /// A Quoted Catalog quote (`add_catalog_quotes`).
    case catalog(Int)
    /// A friend's favorite, by the per-viewer handle from `friend_favorites` (`save_from_favorite`).
    case favorite(friendID: UUID, handle: UUID)
    /// A playlist item, by the per-viewer handle from `playlist_view` (`save_from_playlist`).
    case playlistItem(playlistID: UUID, handle: UUID)

    /// How to send it without saving it first: posts, messages and catalog quotes forward as they
    /// are. Nil for a favorite or a playlist item, which are saved to your library and sent as yours.
    public var quoteRef: QuoteRef? {
        switch self {
        case .post(let id): .post(id)
        case .message(let id): .message(id)
        case .catalog(let id): .catalog(id)
        case .favorite, .playlistItem: nil
        }
    }
}

/// A keyset position in a newest-first list (the Feed, a conversation): the `created_at` and `id` of
/// the last row read. The next page holds the rows that sort after it (`created_at desc, id`).
public struct PageCursor: Hashable, Sendable, Codable {
    public var createdAt: Date
    public var id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
}
