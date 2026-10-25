import Foundation

/// How a quote entered the library. Raw values match `quotes.origin` in the database.
public enum QuoteOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    /// Typed in Add.
    case manual
    /// Picked from the starter pack during onboarding.
    case starter
    /// Saved from a quote a friend shared.
    case shared
    /// Brought back with the PasteButton (for example from a web search).
    case pasted

    /// Unknown values (from a newer server) decode as `.manual` instead of failing the whole row.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QuoteOrigin(rawValue: raw) ?? .manual
    }
}

/// A quote in the signed-in user's library: one `quotes` row.
///
/// Coding keys match the columns (`body_format`, `rotation_position`, `created_at`, `updated_at`), so
/// PostgREST rows decode directly with ``QuotedJSON/makeDecoder()``. Decoding clamps `format` to
/// `body`, and encoding writes explicit nulls for `author`, `source` and `rotation_position`.
public struct Quote: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: UUID
    /// Plain text, 1–2000 characters.
    public var body: String
    /// Normalized UTF-16 runs over `body` (`body_format`).
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    public var origin: QuoteOrigin
    /// Position in the Rotation, or nil when the quote is not in it.
    public var rotationPosition: Int?
    public var createdAt: Date
    public var updatedAt: Date
    /// The starter quote whose wording, author and source this quote matches exactly, or nil. Set by
    /// the server only (trigger `quotes_set_verified`); editing the text clears it.
    public var verifiedStarterID: Int?
    /// The owner's heart. Friends see favorites only when the owner shows them (`Profile.showsFavorites`).
    public var isFavorite: Bool
    /// When it became a favorite (server clock), or nil.
    public var favoritedAt: Date?

    /// Whether the quote is part of the Rotation.
    public var isInRotation: Bool { rotationPosition != nil }
    /// Whether the wording and attribution were checked against a public-domain source.
    public var isVerified: Bool { verifiedStarterID != nil }

    /// Creates a quote. `format` is normalized against `body`; `updatedAt` defaults to `createdAt`.
    public init(
        id: UUID = UUID(),
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        origin: QuoteOrigin = .manual,
        rotationPosition: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        verifiedStarterID: Int? = nil,
        isFavorite: Bool = false,
        favoritedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.origin = origin
        self.rotationPosition = rotationPosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.verifiedStarterID = verifiedStarterID
        self.isFavorite = isFavorite
        self.favoritedAt = isFavorite ? favoritedAt : nil
    }

    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }

    /// Plain text for the share sheet and clipboard.
    public var shareText: String { RichText.shareText(body: body, author: author, source: source) }
}

extension Quote: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case body
        case format = "body_format"
        case author
        case source
        case origin
        case rotationPosition = "rotation_position"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case verifiedStarterID = "verified_starter_id"
        case isFavorite = "is_favorite"
        case favoritedAt = "favorited_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        origin = try container.decodeIfPresent(QuoteOrigin.self, forKey: .origin) ?? .manual
        rotationPosition = try container.decodeIfPresent(Int.self, forKey: .rotationPosition)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        verifiedStarterID = try container.decodeIfPresent(Int.self, forKey: .verifiedStarterID)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        favoritedAt = isFavorite ? try container.decodeIfPresent(Date.self, forKey: .favoritedAt) : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(origin, forKey: .origin)
        try container.encode(rotationPosition, forKey: .rotationPosition)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(verifiedStarterID, forKey: .verifiedStarterID)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(favoritedAt, forKey: .favoritedAt)
    }
}
