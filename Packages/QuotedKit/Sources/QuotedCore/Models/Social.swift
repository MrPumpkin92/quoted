import Foundation

/// A public profile: one `profiles` row (`id`, `username`, `display_name`).
///
/// Decoding a top-level `profiles` row needs `id`; profiles embedded in shares and friendships may
/// omit it. A null or missing `display_name` decodes as the username.
public struct Profile: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Lowercase handle matching `^[a-z0-9_.]{3,20}$`.
    public var username: String
    /// Shown name, 1–50 characters.
    public var displayName: String
    /// Whether accepted friends may see this user's favorite quotes (`profiles.shows_favorites`).
    /// Off by default.
    public var showsFavorites: Bool

    public init(id: UUID, username: String, displayName: String? = nil, showsFavorites: Bool = false) {
        self.id = id
        self.username = username
        self.displayName = displayName ?? username
        self.showsFavorites = showsFavorites
    }

    /// The username prefixed with "@".
    public var handle: String { "@\(username)" }
}

extension Profile: Codable {
    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case showsFavorites = "shows_favorites"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        showsFavorites = try container.decodeIfPresent(Bool.self, forKey: .showsFavorites) ?? false
        if let name = try container.decodeIfPresent(String.self, forKey: .displayName), !name.isEmpty {
            displayName = name
        } else {
            displayName = username
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(showsFavorites, forKey: .showsFavorites)
    }
}

/// One of a friend's favorite quotes, from `public.friend_favorites` (only when they show favorites).
/// `id` is a handle for this viewer, stable across loads, not the quote's own ID.
public struct FriendFavorite: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: UUID
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    /// Set when the wording and attribution match a catalog quote (the verified seal).
    public var verifiedStarterID: Int?
    public var favoritedAt: Date?

    public init(
        id: UUID,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        verifiedStarterID: Int? = nil,
        favoritedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.verifiedStarterID = verifiedStarterID
        self.favoritedAt = favoritedAt
    }

    /// Whether the wording and attribution were checked against a public-domain source.
    public var isVerified: Bool { verifiedStarterID != nil }
}

extension FriendFavorite: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, body, author, source
        case format = "body_format"
        case verifiedStarterID = "verified_starter_id"
        case favoritedAt = "favorited_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        verifiedStarterID = try container.decodeIfPresent(Int.self, forKey: .verifiedStarterID)
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
    }
}

/// A profile embedded in another row. PostgREST embeds often select only `username, display_name`,
/// so a missing `id` falls back to the foreign key that points at the profile, and a malformed
/// embed decodes as nil instead of failing the row.
struct EmbeddedProfile: Decodable {
    var id: UUID?
    var username: String
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
    }

    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        fallbackID: UUID?
    ) -> Profile? {
        guard let embedded = try? container.decodeIfPresent(EmbeddedProfile.self, forKey: key),
              let id = embedded.id ?? fallbackID
        else { return nil }
        let name = embedded.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return Profile(id: id, username: embedded.username, displayName: name)
    }
}

/// `friendships.status`.
public enum FriendshipStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case accepted
}

/// A friend request or friendship: one `friendships` row.
///
/// The other party's profile can arrive three ways: embedded as `requester` and `addressee`
/// (`requester:profiles!friendships_requester_id_fkey(username,display_name)`; a missing embedded
/// `id` falls back to the foreign key), as `other_party` from a view or RPC (must include `id`), or
/// set by the repository. ``otherParty(for:)`` picks whichever is available.
public struct Friendship: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var requesterID: UUID
    public var addresseeID: UUID
    public var status: FriendshipStatus
    public var createdAt: Date
    public var respondedAt: Date?
    /// Embedded requester profile, if selected.
    public var requester: Profile?
    /// Embedded addressee profile, if selected.
    public var addressee: Profile?
    /// The profile of the user who is not the viewer, if known.
    public var otherParty: Profile?

    public init(
        id: UUID,
        requesterID: UUID,
        addresseeID: UUID,
        status: FriendshipStatus,
        createdAt: Date,
        respondedAt: Date? = nil,
        requester: Profile? = nil,
        addressee: Profile? = nil,
        otherParty: Profile? = nil
    ) {
        self.id = id
        self.requesterID = requesterID
        self.addresseeID = addresseeID
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.requester = requester
        self.addressee = addressee
        self.otherParty = otherParty
    }

    /// The ID of the party who is not `me`.
    public func otherPartyID(for me: UUID) -> UUID {
        requesterID == me ? addresseeID : requesterID
    }

    /// The profile of the party who is not `me`, if it was loaded.
    public func otherParty(for me: UUID) -> Profile? {
        if let otherParty, otherParty.id != me { return otherParty }
        return requesterID == me ? addressee : requester
    }

    /// A pending request that `me` can accept or decline.
    public func isIncomingRequest(for me: UUID) -> Bool {
        status == .pending && addresseeID == me
    }

    /// A pending request that `me` sent and can cancel.
    public func isOutgoingRequest(for me: UUID) -> Bool {
        status == .pending && requesterID == me
    }
}

extension Friendship: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
        case createdAt = "created_at"
        case respondedAt = "responded_at"
        case requester
        case addressee
        case otherParty = "other_party"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requesterID = try container.decode(UUID.self, forKey: .requesterID)
        addresseeID = try container.decode(UUID.self, forKey: .addresseeID)
        status = try container.decode(FriendshipStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        respondedAt = try container.decodeIfPresent(Date.self, forKey: .respondedAt)
        requester = EmbeddedProfile.decode(from: container, forKey: .requester, fallbackID: requesterID)
        addressee = EmbeddedProfile.decode(from: container, forKey: .addressee, fallbackID: addresseeID)
        otherParty = EmbeddedProfile.decode(from: container, forKey: .otherParty, fallbackID: nil)
    }
}

/// A quote a friend sent: one `shares` row with its content snapshot.
public struct SharedQuote: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: UUID
    public var senderID: UUID
    /// Embedded sender profile (`sender:profiles!shares_sender_id_fkey(username,display_name)`).
    public var sender: Profile?
    public var recipientID: UUID
    /// Embedded recipient profile, for the sent list.
    public var recipient: Profile?
    /// The sender's original quote. Null once the sender deletes it.
    public var quoteID: UUID?
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    /// Optional note from the sender, up to 280 characters.
    public var note: String?
    public var createdAt: Date
    public var seenAt: Date?
    public var savedAt: Date?
    /// The catalog quote this share's wording, author and source match exactly, or nil. Set by the
    /// server only (trigger `shares_set_verified`).
    public var verifiedStarterID: Int?

    public init(
        id: UUID,
        senderID: UUID,
        sender: Profile? = nil,
        recipientID: UUID,
        recipient: Profile? = nil,
        quoteID: UUID? = nil,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        note: String? = nil,
        createdAt: Date,
        seenAt: Date? = nil,
        savedAt: Date? = nil,
        verifiedStarterID: Int? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.sender = sender
        self.recipientID = recipientID
        self.recipient = recipient
        self.quoteID = quoteID
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.note = note
        self.createdAt = createdAt
        self.seenAt = seenAt
        self.savedAt = savedAt
        self.verifiedStarterID = verifiedStarterID
    }

    /// Whether the wording and attribution were checked against a public-domain source.
    public var isVerified: Bool { verifiedStarterID != nil }
    /// Whether the recipient has opened it.
    public var isSeen: Bool { seenAt != nil }
    /// Whether the recipient saved it to their library.
    public var isSaved: Bool { savedAt != nil }
    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }
    /// Plain text for the share sheet and clipboard.
    public var shareText: String { RichText.shareText(body: body, author: author, source: source) }
}

extension SharedQuote: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case senderID = "sender_id"
        case sender
        case recipientID = "recipient_id"
        case recipient
        case quoteID = "quote_id"
        case body
        case format = "body_format"
        case author
        case source
        case note
        case createdAt = "created_at"
        case seenAt = "seen_at"
        case savedAt = "saved_at"
        case verifiedStarterID = "verified_starter_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        sender = EmbeddedProfile.decode(from: container, forKey: .sender, fallbackID: senderID)
        recipientID = try container.decode(UUID.self, forKey: .recipientID)
        recipient = EmbeddedProfile.decode(from: container, forKey: .recipient, fallbackID: recipientID)
        quoteID = try container.decodeIfPresent(UUID.self, forKey: .quoteID)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        seenAt = try container.decodeIfPresent(Date.self, forKey: .seenAt)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
        verifiedStarterID = try container.decodeIfPresent(Int.self, forKey: .verifiedStarterID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(senderID, forKey: .senderID)
        try container.encodeIfPresent(sender, forKey: .sender)
        try container.encode(recipientID, forKey: .recipientID)
        try container.encodeIfPresent(recipient, forKey: .recipient)
        try container.encode(quoteID, forKey: .quoteID)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(seenAt, forKey: .seenAt)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(verifiedStarterID, forKey: .verifiedStarterID)
    }
}

/// One onboarding starter quote from `starter_quotes` (the live starters in `catalog_quotes`; see
/// ``CatalogQuote``). Every one was checked word for word against the public-domain text at
/// `sourceURL` (docs/starter-pack-sources.md).
public struct StarterQuote: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: Int
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    public var sortOrder: Int
    /// Where the quote is in the work, for people ("1831 edition, Chapter 20").
    public var sourceLocation: String?
    /// The full text it was checked against (Project Gutenberg or Wikisource).
    public var sourceURL: URL?

    public init(
        id: Int,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        sortOrder: Int = 0,
        sourceLocation: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.sortOrder = sortOrder
        self.sourceLocation = sourceLocation
        self.sourceURL = sourceURL
    }

    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }
}

extension StarterQuote: Codable {
    enum CodingKeys: String, CodingKey {
        case id, body
        case format = "body_format"
        case author, source
        case sortOrder = "sort_order"
        case sourceLocation = "source_location"
        case sourceURL = "source_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? id
        sourceLocation = try container.decodeIfPresent(String.self, forKey: .sourceLocation)
        // A malformed link drops only the link, not the row.
        sourceURL = (try? container.decodeIfPresent(String.self, forKey: .sourceURL)).flatMap { $0.flatMap(URL.init(string:)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(sourceLocation, forKey: .sourceLocation)
        try container.encodeIfPresent(sourceURL?.absoluteString, forKey: .sourceURL)
    }
}

/// `reports.reason`.
public enum ReportReason: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case spam
    case harassment
    case inappropriate
    case other

    public var id: String { rawValue }

    /// A short label for the report sheet.
    public var title: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment or bullying"
        case .inappropriate: "Inappropriate content"
        case .other: "Something else"
        }
    }
}
