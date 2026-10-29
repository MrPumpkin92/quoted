import Foundation

/// One of your own playlists: a `playlists` row (owner only) with its items in order. A playlist is
/// a titled list of quotes from your library that you can send and show on your profile; it is
/// never Reminders.
public struct Playlist: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ownerID: UUID
    /// 1–60 characters.
    public var title: String
    /// "Who can see this": Only me, Friends, or Anyone once Public ships.
    public var visibility: Audience
    /// Set while Quoted reviews it: hidden from everyone but you, and Send is off.
    public var heldAt: Date?
    public var createdAt: Date
    /// Moves when the title, the visibility or an item changes (server clock).
    public var updatedAt: Date
    /// The items in playlist order (position, then when added).
    public var entries: [PlaylistEntry]

    public init(
        id: UUID,
        ownerID: UUID,
        title: String,
        visibility: Audience = .friends,
        heldAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        entries: [PlaylistEntry] = []
    ) {
        self.id = id
        self.ownerID = ownerID
        self.title = title
        self.visibility = visibility
        self.heldAt = heldAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.entries = PlaylistEntry.sorted(entries)
    }

    /// Whether Quoted holds it for review.
    public var isHeld: Bool { heldAt != nil }
    /// Your quotes' ids, in playlist order.
    public var quoteIDs: [UUID] { entries.map(\.quoteID) }
    /// How many quotes it holds.
    public var count: Int { entries.count }
    /// Whether it can take another quote (200 at most).
    public var isFull: Bool { entries.count >= Limits.playlistItemsMax }
    /// Whether `quoteID` is in it.
    public func contains(_ quoteID: UUID) -> Bool { entries.contains { $0.quoteID == quoteID } }
}

extension Playlist: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title, visibility
        case heldAt = "held_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case entries = "items"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            ownerID: try container.decode(UUID.self, forKey: .ownerID),
            title: try container.decode(String.self, forKey: .title),
            visibility: try container.decodeIfPresent(Audience.self, forKey: .visibility) ?? .onlyMe,
            heldAt: try container.decodeIfPresent(Date.self, forKey: .heldAt),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
            entries: try container.decodeIfPresent([PlaylistEntry].self, forKey: .entries) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ownerID, forKey: .ownerID)
        try container.encode(title, forKey: .title)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(heldAt, forKey: .heldAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(entries, forKey: .entries)
    }
}

/// One item of your own playlist: a `playlist_items` row, pointing at one of your quotes.
public struct PlaylistEntry: Hashable, Sendable, Codable {
    public var playlistID: UUID
    public var quoteID: UUID
    /// Order in the playlist, 0 or more. Need not be unique or dense (see ``PlaylistOrder``).
    public var position: Int
    /// Server clock.
    public var addedAt: Date

    public init(playlistID: UUID, quoteID: UUID, position: Int, addedAt: Date) {
        self.playlistID = playlistID
        self.quoteID = quoteID
        self.position = position
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case quoteID = "quote_id"
        case position
        case addedAt = "added_at"
    }

    /// Playlist order: position, then when added, then the quote id (the order `playlist_view` uses).
    public static func sorted(_ entries: [PlaylistEntry]) -> [PlaylistEntry] {
        entries.sorted {
            ($0.position, $0.addedAt, $0.quoteID.uuidString) < ($1.position, $1.addedAt, $1.quoteID.uuidString)
        }
    }
}

/// A playlist as `public.playlist_view` shows it to the caller: the owner, the title and the items
/// the caller may see, in the owner's order. Live and read only; nil from the server when it isn't
/// available (deleted, narrowed to Only me, unfriended, blocked or held).
public struct PlaylistView: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var visibility: Audience
    public var updatedAt: Date
    public var owner: Profile
    public var items: [PlaylistItem]

    public init(id: UUID, title: String, visibility: Audience, updatedAt: Date, owner: Profile, items: [PlaylistItem]) {
        self.id = id
        self.title = title
        self.visibility = visibility
        self.updatedAt = updatedAt
        self.owner = owner
        self.items = items
    }

    /// How a playlist card counts it ("12 quotes").
    public var count: Int { items.count }

    /// The route for one item's quote screen.
    public func snapshotRef(for item: PlaylistItem) -> SnapshotRef { .playlistItem(playlistID: id, handle: item.id) }
}

extension PlaylistView: Codable {
    enum CodingKeys: String, CodingKey {
        case playlist, items
    }

    enum PlaylistKeys: String, CodingKey {
        case id, title, visibility, owner
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let playlist = try container.nestedContainer(keyedBy: PlaylistKeys.self, forKey: .playlist)
        id = try playlist.decode(UUID.self, forKey: .id)
        title = try playlist.decode(String.self, forKey: .title)
        visibility = try playlist.decodeIfPresent(Audience.self, forKey: .visibility) ?? .friends
        updatedAt = try playlist.decode(Date.self, forKey: .updatedAt)
        owner = try playlist.decode(Profile.self, forKey: .owner)
        items = try container.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var playlist = container.nestedContainer(keyedBy: PlaylistKeys.self, forKey: .playlist)
        try playlist.encode(id, forKey: .id)
        try playlist.encode(title, forKey: .title)
        try playlist.encode(visibility, forKey: .visibility)
        try playlist.encode(updatedAt, forKey: .updatedAt)
        try playlist.encode(owner, forKey: .owner)
        try container.encode(items, forKey: .items)
    }
}

/// One quote in a playlist you view through `playlist_view`. `id` is a per-viewer handle, never the
/// quote's id: pass it to ``SnapshotRef/playlistItem(playlistID:handle:)`` to save it.
public struct PlaylistItem: Identifiable, Hashable, Sendable, RichTextContent {
    /// The handle (`md5(quote id, viewer)`).
    public var id: UUID
    public var position: Int
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    public var verifiedStarterID: Int?
    /// Null for checked quotes.
    public var creatorUsername: String?
    public var editedFromUsername: String?

    public init(
        id: UUID,
        position: Int = 0,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        verifiedStarterID: Int? = nil,
        creatorUsername: String? = nil,
        editedFromUsername: String? = nil
    ) {
        self.id = id
        self.position = position
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.verifiedStarterID = verifiedStarterID
        self.creatorUsername = creatorUsername
        self.editedFromUsername = editedFromUsername
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

extension PlaylistItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id = "handle"
        case position, body, author, source
        case format = "body_format"
        case verifiedStarterID = "verified_starter_id"
        case creatorUsername = "creator_username"
        case editedFromUsername = "edited_from_username"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        verifiedStarterID = try container.decodeIfPresent(Int.self, forKey: .verifiedStarterID)
        creatorUsername = try container.decodeIfPresent(String.self, forKey: .creatorUsername)
        editedFromUsername = try container.decodeIfPresent(String.self, forKey: .editedFromUsername)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(verifiedStarterID, forKey: .verifiedStarterID)
        try container.encode(creatorUsername, forKey: .creatorUsername)
        try container.encode(editedFromUsername, forKey: .editedFromUsername)
    }
}

/// A playlist as a profile lists it (`profile_view`): enough for a `PlaylistRow`; open it with
/// `playlist_view`. `itemCount` is what `playlist_view` would show the caller.
public struct PlaylistSummary: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var visibility: Audience
    public var itemCount: Int
    public var updatedAt: Date

    public init(id: UUID, title: String, visibility: Audience, itemCount: Int, updatedAt: Date) {
        self.id = id
        self.title = title
        self.visibility = visibility
        self.itemCount = itemCount
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, visibility
        case itemCount = "item_count"
        case updatedAt = "updated_at"
    }
}

/// Positions for playlist items. Positions need not be unique or dense, so items are spaced
/// ``spacing`` apart and a move usually rewrites only the items that moved.
public enum PlaylistOrder {
    /// The gap between consecutive new positions.
    public static let spacing = 1024

    /// Positions for `count` quotes appended after the highest position `last` (nil when empty).
    public static func appended(count: Int, after last: Int?) -> [Int] {
        guard count > 0 else { return [] }
        let start = last.map { $0 + spacing } ?? 0
        return (0..<count).map { start + $0 * spacing }
    }

    /// New positions that make `positions` (the items' current positions, listed in the new order)
    /// strictly increasing, changing as few items as possible: the longest run already in order
    /// keeps its positions and the others fit into the gaps. When a gap is too small, every item is
    /// renumbered ``spacing`` apart. Returns the new position for each index, nil where it stays.
    public static func plan(_ positions: [Int]) -> [Int?] {
        guard !positions.isEmpty else { return [] }
        let kept = longestIncreasing(positions)
        var result = [Int?](repeating: nil, count: positions.count)
        var index = 0
        var lower = -1
        while index < positions.count {
            if kept.contains(index) {
                lower = positions[index]
                index += 1
                continue
            }
            var end = index
            while end < positions.count, !kept.contains(end) { end += 1 }
            let run = end - index
            if end == positions.count {
                for offset in 0..<run { result[index + offset] = lower + spacing * (offset + 1) }
            } else {
                let upper = positions[end]
                guard upper - lower - 1 >= run else { return renumbered(positions) }
                let step = (upper - lower) / (run + 1)
                for offset in 0..<run { result[index + offset] = lower + step * (offset + 1) }
            }
            index = end
        }
        // A trailing run always follows a kept item: a non-empty list keeps at least one.
        return result
    }

    /// Every item `spacing` apart from 0, nil where the position already matches.
    static func renumbered(_ positions: [Int]) -> [Int?] {
        positions.enumerated().map { index, position in
            let target = index * spacing
            return position == target ? nil : target
        }
    }

    /// The indexes of one longest strictly increasing subsequence (patience sorting).
    static func longestIncreasing(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = []          // index of the smallest tail for each length
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result = Set<Int>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.insert(cursor)
            cursor = previous[cursor]
        }
        return result
    }
}
