import Foundation

/// A person's public face: one `profiles` row as clients may read it (`id`, `username`,
/// `display_name`, `accepts_text_messages`; the column grant allows nothing else). Your own private
/// fields come from ``MyAccount``.
///
/// Decoding a top-level `profiles` row needs `id`; profiles embedded in other rows may omit it. A
/// null or missing `display_name` decodes as the username. A missing `accepts_text_messages` stays
/// nil (unknown): `profile_view` and `playlist_view` leave it out, and reading it as on would offer
/// text to a friend who receives quotes only.
public struct Profile: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Lowercase handle matching `^[a-z0-9_.]{3,20}$`.
    public var username: String
    /// Shown name, 1–50 characters, or the username when none is set.
    public var displayName: String
    /// "Friends can text me". Off means friends can send quotes and playlists, not text (QR004).
    /// Nil when the source didn't say (profile pages, playlist owners): ask a source that does
    /// (the Inbox row, the conversation, the `profiles` row) before offering text.
    public var acceptsTextMessages: Bool?

    public init(id: UUID, username: String, displayName: String? = nil, acceptsTextMessages: Bool? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? username
        self.acceptsTextMessages = acceptsTextMessages
    }

    /// The username prefixed with "@".
    public var handle: String { "@\(username)" }
}

extension Profile: Codable {
    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case acceptsTextMessages = "accepts_text_messages"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            username: try container.decode(String.self, forKey: .username),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            acceptsTextMessages: try container.decodeIfPresent(Bool.self, forKey: .acceptsTextMessages)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(acceptsTextMessages, forKey: .acceptsTextMessages)
    }
}

/// One of a friend's favorite quotes, from `public.friend_favorites` or `profile_view` (only when
/// they share favorites with friends). `id` is a handle for this viewer, stable across loads, never
/// the quote's own ID: pass it to ``SnapshotRef/favorite(friendID:handle:)`` to save it.
public struct FriendFavorite: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: UUID
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    /// Set when the wording and attribution match a Quoted Catalog quote (`catalog_quotes.id`; the
    /// filled seal).
    public var verifiedStarterID: Int?
    /// Who added it (null for checked quotes).
    public var creatorUsername: String?
    public var editedFromUsername: String?
    public var favoritedAt: Date?

    public init(
        id: UUID,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        verifiedStarterID: Int? = nil,
        creatorUsername: String? = nil,
        editedFromUsername: String? = nil,
        favoritedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.verifiedStarterID = verifiedStarterID
        self.creatorUsername = creatorUsername
        self.editedFromUsername = editedFromUsername
        self.favoritedAt = favoritedAt
    }

    /// Whether the wording and attribution were checked against a public-domain source.
    public var isVerified: Bool { verifiedStarterID != nil }
    /// Who added it and whether Quoted checked it.
    public var provenance: Provenance {
        Provenance(catalogID: verifiedStarterID, creatorUsername: creatorUsername, editedFromUsername: editedFromUsername)
    }
    /// The quote as a snapshot.
    public var snapshot: QuoteSnapshot {
        QuoteSnapshot(
            body: body, format: format, author: author, source: source, verifiedStarterID: verifiedStarterID,
            creatorUsername: creatorUsername, editedFromUsername: editedFromUsername
        )
    }
}

extension FriendFavorite: Codable {
    enum CodingKeys: String, CodingKey {
        case id, body, author, source
        case format = "body_format"
        case verifiedStarterID = "verified_starter_id"
        case creatorUsername = "creator_username"
        case editedFromUsername = "edited_from_username"
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
        creatorUsername = try container.decodeIfPresent(String.self, forKey: .creatorUsername)
        editedFromUsername = try container.decodeIfPresent(String.self, forKey: .editedFromUsername)
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(verifiedStarterID, forKey: .verifiedStarterID)
        try container.encode(creatorUsername, forKey: .creatorUsername)
        try container.encode(editedFromUsername, forKey: .editedFromUsername)
        try container.encode(favoritedAt, forKey: .favoritedAt)
    }
}

/// A profile embedded in another row. PostgREST embeds often select only `username, display_name`,
/// so a missing `id` falls back to the foreign key that points at the profile, and a malformed
/// embed decodes as nil instead of failing the row.
struct EmbeddedProfile: Decodable {
    var id: UUID?
    var username: String
    var displayName: String?
    var acceptsTextMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case acceptsTextMessages = "accepts_text_messages"
    }

    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        fallbackID: UUID?
    ) -> Profile? {
        guard let embedded = try? container.decodeIfPresent(EmbeddedProfile.self, forKey: key),
              let id = embedded.id ?? fallbackID
        else { return nil }
        return Profile(
            id: id, username: embedded.username, displayName: embedded.displayName,
            acceptsTextMessages: embedded.acceptsTextMessages
        )
    }
}

/// Someone you blocked (Blocked users). `profile` is nil when you can no longer read their profile
/// because they blocked you too; you can still unblock or report them by `id`.
public struct BlockedUser: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var profile: Profile?

    public init(id: UUID, profile: Profile? = nil) {
        self.id = id
        self.profile = profile
    }

    /// Someone you blocked whose profile you can read.
    public init(_ profile: Profile) {
        self.init(id: profile.id, profile: profile)
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
    /// Always checked, with no creator: "Quoted Catalog".
    public var provenance: Provenance { .catalog(id) }
    /// The provenance block's status line: "Checked word for word against <work>, <location>".
    public var statusLine: String { ProvenanceCopy.statusLine(checked: true, work: source, location: sourceLocation) }
    /// The quote as a snapshot.
    public var snapshot: QuoteSnapshot {
        QuoteSnapshot(body: body, format: format, author: author, source: source, verifiedStarterID: id)
    }
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
