import Foundation

/// "Who can see this": a post's `audience`, a playlist's `visibility`. Raw values are the database's.
public enum Audience: String, Hashable, Sendable, CaseIterable, Codable {
    /// "Only me" (`private`). Playlists and favorites only.
    case onlyMe = "private"
    /// "Friends": accepted friends with no block either way.
    case friends
    /// "Anyone with your username" (`public`). Needs ``MyAccount/canPublish``; hidden until Public ships.
    case anyone = "public"

    /// A value from a newer server reads as the narrowest audience instead of failing the row.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Audience(rawValue: raw) ?? .onlyMe
    }
}

/// Whether friends can see the quotes you heart (`profiles.favorites_visibility`, which replaced
/// `shows_favorites`). Never Anyone.
public enum FavoritesVisibility: String, Hashable, Sendable, CaseIterable, Codable {
    /// "Only you can see your favorites." (`private`, the default)
    case onlyMe = "private"
    /// "Friends can see the quotes you heart."
    case friends

    /// The same choice as an ``Audience``.
    public var audience: Audience { self == .friends ? .friends : .onlyMe }

    /// An unknown value reads as private.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FavoritesVisibility(rawValue: raw) ?? .onlyMe
    }
}

/// The signed-in person's own account: one row of `public.my_account()`, the only way to read the
/// private profile fields (favorites visibility, terms, suspension and the publishing gate).
public struct MyAccount: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var username: String
    /// The display name as stored, nil when none is set (``profile`` falls back to the username).
    public var displayName: String?
    /// "Friends can text me".
    public var acceptsTextMessages: Bool
    public var favoritesVisibility: FavoritesVisibility
    /// The Terms of Use version this account accepted, or nil.
    public var termsVersion: Int?
    public var termsAcceptedAt: Date?
    /// The version everyone must accept before a social write.
    public var currentTermsVersion: Int
    /// A suspended account can read but not post, send or friend anyone.
    public var isSuspended: Bool
    /// Whether this account may make something public (terms, no suspension, Apple identity linked).
    public var canPublish: Bool

    public init(
        id: UUID,
        username: String,
        displayName: String? = nil,
        acceptsTextMessages: Bool = true,
        favoritesVisibility: FavoritesVisibility = .onlyMe,
        termsVersion: Int? = nil,
        termsAcceptedAt: Date? = nil,
        currentTermsVersion: Int = 1,
        isSuspended: Bool = false,
        canPublish: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 }
        self.acceptsTextMessages = acceptsTextMessages
        self.favoritesVisibility = favoritesVisibility
        self.termsVersion = termsVersion
        self.termsAcceptedAt = termsAcceptedAt
        self.currentTermsVersion = currentTermsVersion
        self.isSuspended = isSuspended
        self.canPublish = canPublish
    }

    /// The public face of this account.
    public var profile: Profile {
        Profile(id: id, username: username, displayName: displayName, acceptsTextMessages: acceptsTextMessages)
    }

    /// Whether the current Terms of Use are accepted, so social writes may go ahead.
    public var hasAcceptedCurrentTerms: Bool { (termsVersion ?? 0) >= currentTermsVersion }

    /// Whether this account accepted an earlier version: the Terms sheet reads "Updated Terms".
    public var needsUpdatedTerms: Bool { termsVersion != nil && !hasAcceptedCurrentTerms }
}

extension MyAccount: Codable {
    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case acceptsTextMessages = "accepts_text_messages"
        case favoritesVisibility = "favorites_visibility"
        case termsVersion = "terms_version"
        case termsAcceptedAt = "terms_accepted_at"
        case currentTermsVersion = "current_terms_version"
        case isSuspended = "is_suspended"
        case canPublish = "can_publish"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            username: try container.decode(String.self, forKey: .username),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            acceptsTextMessages: try container.decodeIfPresent(Bool.self, forKey: .acceptsTextMessages) ?? true,
            favoritesVisibility: try container.decodeIfPresent(FavoritesVisibility.self, forKey: .favoritesVisibility) ?? .onlyMe,
            termsVersion: try container.decodeIfPresent(Int.self, forKey: .termsVersion),
            termsAcceptedAt: try container.decodeIfPresent(Date.self, forKey: .termsAcceptedAt),
            currentTermsVersion: try container.decodeIfPresent(Int.self, forKey: .currentTermsVersion) ?? 1,
            isSuspended: try container.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false,
            canPublish: try container.decodeIfPresent(Bool.self, forKey: .canPublish) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(acceptsTextMessages, forKey: .acceptsTextMessages)
        try container.encode(favoritesVisibility, forKey: .favoritesVisibility)
        try container.encode(termsVersion, forKey: .termsVersion)
        try container.encode(termsAcceptedAt, forKey: .termsAcceptedAt)
        try container.encode(currentTermsVersion, forKey: .currentTermsVersion)
        try container.encode(isSuspended, forKey: .isSuspended)
        try container.encode(canPublish, forKey: .canPublish)
    }
}
