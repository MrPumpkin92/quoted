import Foundation

/// A post in the Feed: one `posts` row (every column but `source_quote_id`, which no client may read),
/// or one entry of `profile_view`'s posts.
///
/// `posterID` is the person who posted (`author_id`); `quote.author` is the quote's author.
public struct Post: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Who posted it (`author_id`).
    public var posterID: UUID
    /// The poster's profile, when the read embedded it (the Feed) or the profile page supplied it.
    public var poster: Profile?
    /// The server's copy of the quote at post time.
    public var quote: QuoteSnapshot
    /// The Quoted Catalog quote it was posted from, or nil (a library quote, or the catalog row is gone).
    public var starterQuoteID: Int?
    /// Optional, 1–280 characters, under the quote.
    public var caption: String?
    /// `friends`, or `public` once Public ships.
    public var audience: Audience
    /// Set while Quoted reviews it: only the poster sees it ("Only you can see this while Quoted
    /// reviews it."). `profile_view` never says, so posts from there read as not held.
    public var heldAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        posterID: UUID,
        poster: Profile? = nil,
        quote: QuoteSnapshot,
        starterQuoteID: Int? = nil,
        caption: String? = nil,
        audience: Audience = .friends,
        heldAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.posterID = posterID
        self.poster = poster
        self.quote = quote
        self.starterQuoteID = starterQuoteID
        self.caption = caption
        self.audience = audience
        self.heldAt = heldAt
        self.createdAt = createdAt
    }

    /// Whether Quoted holds it for review.
    public var isHeld: Bool { heldAt != nil }
    /// Who added the quote and whether Quoted checked it.
    public var provenance: Provenance { quote.provenance }
    /// The keyset position after this post, for the next page.
    public var cursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }
    /// How to save it or open its quote screen.
    public var snapshotRef: SnapshotRef { .post(id) }
}

extension Post: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case posterID = "author_id"
        case poster
        case starterQuoteID = "starter_quote_id"
        case caption, audience
        case heldAt = "held_at"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        posterID = try container.decode(UUID.self, forKey: .posterID)
        poster = EmbeddedProfile.decode(from: container, forKey: .poster, fallbackID: posterID)
        quote = try QuoteSnapshot(from: decoder)
        starterQuoteID = try container.decodeIfPresent(Int.self, forKey: .starterQuoteID)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        audience = try container.decodeIfPresent(Audience.self, forKey: .audience) ?? .friends
        heldAt = try container.decodeIfPresent(Date.self, forKey: .heldAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        try quote.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(posterID, forKey: .posterID)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encode(starterQuoteID, forKey: .starterQuoteID)
        try container.encode(caption, forKey: .caption)
        try container.encode(audience, forKey: .audience)
        try container.encode(heldAt, forKey: .heldAt)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// What the post composer sends: the quote by reference (the server builds the snapshot), an
/// optional caption and the audience.
public struct PostDraft: Hashable, Sendable {
    /// The quote to post. Someone else's quote is saved to your library first, then posted as yours.
    public enum Source: Hashable, Sendable, Codable {
        /// One of your own quotes (`source_quote_id`).
        case quote(UUID)
        /// A Quoted Catalog quote (`starter_quote_id`).
        case catalog(Int)
    }

    public var source: Source
    public var caption: String?
    public var audience: Audience

    public init(source: Source, caption: String? = nil, audience: Audience = .friends) {
        self.source = source
        self.caption = caption
        self.audience = audience
    }

    /// The caption as sent: trimmed, blank as nil, at most 280 characters.
    public func validatedCaption() throws(SocialTextError) -> String? {
        try SocialText.caption(caption)
    }
}
