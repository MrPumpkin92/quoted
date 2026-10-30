import Foundation

/// How the caller stands with a profile, from `profile_view`.
public enum Relationship: String, Hashable, Sendable, CaseIterable, Codable {
    /// Your own profile (`self`).
    case me = "self"
    /// An accepted friend.
    case friend
    /// They asked you: "Wants to be friends".
    case incoming
    /// You asked them: "Requested".
    case outgoing
    /// A stranger.
    case none
    /// You blocked them: the page offers Unblock and shows nothing else.
    case youBlocked = "you_blocked"

    /// A value from a newer server reads as a stranger.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Relationship(rawValue: raw) ?? .none
    }
}

/// One profile page from `public.profile_view(username, before)`: the person, how you stand with
/// them, and the posts (30 per page), playlists and favorites you may see. The server answers null
/// (no page) when there is no such profile or that person blocked you.
public struct ProfilePage: Hashable, Sendable {
    public var profile: Profile
    public var relationship: Relationship
    /// Newest first, 30 per page; ``Post/poster`` is ``profile``.
    public var posts: [Post]
    /// Most recently changed first.
    public var playlists: [PlaylistSummary]
    /// Your own 100 newest, or a friend's when they share them; nil when not shared with you.
    public var favorites: [FriendFavorite]?

    public init(
        profile: Profile,
        relationship: Relationship,
        posts: [Post] = [],
        playlists: [PlaylistSummary] = [],
        favorites: [FriendFavorite]? = nil
    ) {
        self.profile = profile
        self.relationship = relationship
        self.posts = posts
        self.playlists = playlists
        self.favorites = favorites
    }

    /// Whether nothing on the page is visible to you ("@alice hasn't shared anything with friends yet.").
    public var isEmpty: Bool { posts.isEmpty && playlists.isEmpty && (favorites ?? []).isEmpty }

    /// The route for one of the favorites' quote screens.
    public func snapshotRef(for favorite: FriendFavorite) -> SnapshotRef {
        .favorite(friendID: profile.id, handle: favorite.id)
    }

    /// The `before` argument for the next page of posts, or nil when the last page was short.
    public var nextPostsBefore: Date? {
        posts.count >= ProfilePage.postsPerPage ? posts.last?.createdAt : nil
    }

    /// Posts per `profile_view` page.
    public static let postsPerPage = 30
}

extension ProfilePage: Codable {
    enum CodingKeys: String, CodingKey {
        case profile, relationship, posts, playlists, favorites
    }

    /// A post as `profile_view` lists it: no poster id (it is the page's profile), no held flag.
    private struct PagePost: Codable {
        var id: UUID
        var caption: String?
        var audience: Audience?
        var createdAt: Date
        var quote: QuoteSnapshot

        enum CodingKeys: String, CodingKey {
            case id, caption, audience
            case createdAt = "created_at"
        }

        init(_ post: Post) {
            id = post.id
            caption = post.caption
            audience = post.audience
            createdAt = post.createdAt
            quote = post.quote
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            caption = try container.decodeIfPresent(String.self, forKey: .caption)
            audience = try container.decodeIfPresent(Audience.self, forKey: .audience)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            quote = try QuoteSnapshot(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try quote.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(caption, forKey: .caption)
            try container.encode(audience, forKey: .audience)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profile = try container.decode(Profile.self, forKey: .profile)
        self.profile = profile
        relationship = try container.decodeIfPresent(Relationship.self, forKey: .relationship) ?? .none
        posts = (try container.decodeIfPresent([PagePost].self, forKey: .posts) ?? []).map { row in
            Post(
                id: row.id, posterID: profile.id, poster: profile, quote: row.quote,
                caption: row.caption, audience: row.audience ?? .friends, createdAt: row.createdAt
            )
        }
        playlists = try container.decodeIfPresent([PlaylistSummary].self, forKey: .playlists) ?? []
        favorites = try container.decodeIfPresent([FriendFavorite].self, forKey: .favorites)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        try container.encode(relationship, forKey: .relationship)
        try container.encode(posts.map(PagePost.init), forKey: .posts)
        try container.encode(playlists, forKey: .playlists)
        try container.encode(favorites, forKey: .favorites)
    }
}
