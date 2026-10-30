import Foundation

/// A 1:1 conversation between two accepted friends: one `conversations` row, from
/// `public.open_conversation` or a read. `user_a < user_b`; the server owns every column.
public struct Conversation: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userA: UUID
    public var userB: UUID
    public var createdAt: Date
    /// When the latest message still in it was sent; nil before the first.
    public var lastMessageAt: Date?
    /// Set when the two stopped being friends or one blocked the other: read only for both.
    public var closedAt: Date?
    /// The members' profiles, when the read embedded them (``Conversation`` reads in QuotedKit do;
    /// `open_conversation` does not).
    public var userAProfile: Profile?
    public var userBProfile: Profile?

    public init(
        id: UUID,
        userA: UUID,
        userB: UUID,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        closedAt: Date? = nil,
        userAProfile: Profile? = nil,
        userBProfile: Profile? = nil
    ) {
        self.id = id
        self.userA = userA
        self.userB = userB
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.closedAt = closedAt
        self.userAProfile = userAProfile
        self.userBProfile = userBProfile
    }

    /// Whether it is read only (unfriended or blocked).
    public var isClosed: Bool { closedAt != nil }

    /// The member who is not `me`.
    public func otherMemberID(for me: UUID) -> UUID { userA == me ? userB : userA }

    /// The other member's profile, if it was loaded.
    public func otherProfile(for me: UUID) -> Profile? { userA == me ? userBProfile : userAProfile }
}

extension Conversation: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case userA = "user_a"
        case userB = "user_b"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case closedAt = "closed_at"
        case userAProfile = "user_a_profile"
        case userBProfile = "user_b_profile"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userA = try container.decode(UUID.self, forKey: .userA)
        userB = try container.decode(UUID.self, forKey: .userB)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        userAProfile = EmbeddedProfile.decode(from: container, forKey: .userAProfile, fallbackID: userA)
        userBProfile = EmbeddedProfile.decode(from: container, forKey: .userBProfile, fallbackID: userB)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userA, forKey: .userA)
        try container.encode(userB, forKey: .userB)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastMessageAt, forKey: .lastMessageAt)
        try container.encode(closedAt, forKey: .closedAt)
        try container.encodeIfPresent(userAProfile, forKey: .userAProfile)
        try container.encodeIfPresent(userBProfile, forKey: .userBProfile)
    }
}

/// Your own row in `conversation_members`: your private read mark and "Delete Conversation" time.
/// Nobody reads the other member's row, so there is no "Seen".
public struct ConversationMember: Hashable, Sendable, Codable {
    public var conversationID: UUID
    public var userID: UUID
    /// Messages up to this time are read (your Inbox dot and badge).
    public var lastReadAt: Date?
    /// Messages up to this time are gone for you ("Delete Conversation").
    public var clearedAt: Date?

    public init(conversationID: UUID, userID: UUID, lastReadAt: Date? = nil, clearedAt: Date? = nil) {
        self.conversationID = conversationID
        self.userID = userID
        self.lastReadAt = lastReadAt
        self.clearedAt = clearedAt
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case userID = "user_id"
        case lastReadAt = "last_read_at"
        case clearedAt = "cleared_at"
    }
}

/// `messages.kind`.
public enum MessageKind: String, Hashable, Sendable, CaseIterable, Codable {
    case text
    case quote
    case playlist
}

/// Another name for ``Message``, for modules where supabase-swift's deprecated `Message` (Realtime)
/// is also visible.
public typealias ConversationMessage = Message

/// One message in a conversation: one `messages` row (every column but the insert-only sources).
public struct Message: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var senderID: UUID
    public var kind: MessageKind
    /// A text message's text (1–1000 characters).
    public var text: String?
    /// The optional note on a quote message (1–280 characters).
    public var note: String?
    /// A quote message's server-built snapshot.
    public var quote: QuoteSnapshot?
    /// The catalog quote a quote message was sent from, if any.
    public var starterQuoteID: Int?
    /// A playlist message's playlist; nil once it is deleted ("This playlist is no longer available").
    public var playlistID: UUID?
    /// The playlist's title when it was sent.
    public var playlistTitle: String?
    public var createdAt: Date

    public init(
        id: UUID,
        conversationID: UUID,
        senderID: UUID,
        kind: MessageKind,
        text: String? = nil,
        note: String? = nil,
        quote: QuoteSnapshot? = nil,
        starterQuoteID: Int? = nil,
        playlistID: UUID? = nil,
        playlistTitle: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.kind = kind
        self.text = text
        self.note = note
        self.quote = quote
        self.starterQuoteID = starterQuoteID
        self.playlistID = playlistID
        self.playlistTitle = playlistTitle
        self.createdAt = createdAt
    }

    /// What the message carries, for a `switch`.
    public enum Content: Hashable, Sendable {
        case text(String)
        case quote(QuoteSnapshot, note: String?)
        /// `id` is nil once the playlist is deleted.
        case playlist(id: UUID?, title: String)
    }

    /// What the message carries. A row whose kind and columns disagree reads as an empty text.
    public var content: Content {
        switch kind {
        case .text: return .text(text ?? "")
        case .quote:
            guard let quote else { return .text(text ?? "") }
            return .quote(quote, note: note)
        case .playlist: return .playlist(id: playlistID, title: playlistTitle ?? "")
        }
    }

    /// Whether `me` sent it.
    public func isMine(_ me: UUID) -> Bool { senderID == me }
    /// The keyset position after this message, for the next (older) page.
    public var cursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }
    /// How to save a quote message or open its quote screen; nil for text and playlists.
    public var snapshotRef: SnapshotRef? { kind == .quote ? .message(id) : nil }
    /// Who added the quote, for a quote message.
    public var provenance: Provenance? { quote?.provenance }

    /// What a conversation's Copy puts on the clipboard: a quote as `“body” — Author, Source`, a
    /// text its text, a playlist its title.
    public var copyText: String {
        switch content {
        case .text(let text): text
        case .quote(let quote, _): quote.shareText
        case .playlist(_, let title): title
        }
    }
}

extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case kind, text, note, body
        case starterQuoteID = "starter_quote_id"
        case playlistID = "playlist_id"
        case playlistTitle = "playlist_title"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        conversationID = try container.decode(UUID.self, forKey: .conversationID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        kind = try container.decode(MessageKind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        if container.contains(.body), try !container.decodeNil(forKey: .body) {
            quote = try QuoteSnapshot(from: decoder)
        } else {
            quote = nil
        }
        starterQuoteID = try container.decodeIfPresent(Int.self, forKey: .starterQuoteID)
        playlistID = try container.decodeIfPresent(UUID.self, forKey: .playlistID)
        playlistTitle = try container.decodeIfPresent(String.self, forKey: .playlistTitle)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        if let quote { try quote.encode(to: encoder) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(senderID, forKey: .senderID)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(note, forKey: .note)
        if quote == nil { try container.encodeNil(forKey: .body) }
        try container.encode(starterQuoteID, forKey: .starterQuoteID)
        try container.encode(playlistID, forKey: .playlistID)
        try container.encode(playlistTitle, forKey: .playlistTitle)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// What you send in a conversation. A quote travels by reference, never by its words.
public enum MessageDraft: Hashable, Sendable {
    /// A text message, 1–1000 characters (refused with QR004 when the friend receives quotes only).
    case text(String)
    /// A quote with an optional note of up to 280 characters.
    case quote(QuoteRef, note: String? = nil)
    /// One of your playlists that friends can see.
    case playlist(UUID)

    /// The kind of message it makes.
    public var kind: MessageKind {
        switch self {
        case .text: .text
        case .quote: .quote
        case .playlist: .playlist
        }
    }

    /// The draft as sent: text trimmed and checked, a blank note dropped.
    public func validated() throws(SocialTextError) -> MessageDraft {
        switch self {
        case .text(let text): .text(try SocialText.message(text))
        case .quote(let ref, let note): .quote(ref, note: try SocialText.note(note))
        case .playlist: self
        }
    }
}

/// One row of `public.inbox_conversations()`: a conversation you may read, the other member, the
/// latest message you can see, how many of theirs you haven't read and your read mark. Newest first.
public struct InboxConversation: Identifiable, Hashable, Sendable {
    /// The conversation's id.
    public var id: UUID
    public var otherID: UUID
    /// The other member's profile; nil if the server could not show it.
    public var other: Profile?
    /// Read only: unfriended, or you blocked them ("Read only").
    public var isClosed: Bool
    public var lastMessageAt: Date?
    public var lastMessageKind: MessageKind?
    /// Up to 140 characters: the text, the quote's body or the playlist's title.
    public var lastMessagePreview: String?
    public var lastMessageSenderID: UUID?
    /// Messages from the other member newer than your read mark.
    public var unreadCount: Int
    /// Your read mark: messages from the other member sent after it are unread. Nil before you
    /// first read the conversation (all of theirs are unread).
    public var lastReadAt: Date?

    public init(
        id: UUID,
        otherID: UUID,
        other: Profile? = nil,
        isClosed: Bool = false,
        lastMessageAt: Date? = nil,
        lastMessageKind: MessageKind? = nil,
        lastMessagePreview: String? = nil,
        lastMessageSenderID: UUID? = nil,
        unreadCount: Int = 0,
        lastReadAt: Date? = nil
    ) {
        self.id = id
        self.otherID = otherID
        self.other = other
        self.isClosed = isClosed
        self.lastMessageAt = lastMessageAt
        self.lastMessageKind = lastMessageKind
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageSenderID = lastMessageSenderID
        self.unreadCount = unreadCount
        self.lastReadAt = lastReadAt
    }

    /// Whether it shows the unread dot and counts toward the Inbox badge.
    public var isUnread: Bool { unreadCount > 0 }

    /// Whether `message`, sent by the other member, is after your read mark.
    public func isUnread(_ message: Message) -> Bool {
        guard message.senderID == otherID else { return false }
        guard let lastReadAt else { return true }
        return message.createdAt > lastReadAt
    }

    /// Whether `me` sent the latest message (the preview then starts with "You: ").
    public func lastMessageIsMine(_ me: UUID) -> Bool { lastMessageSenderID == me }

    // MARK: Marking what you have seen

    /// The read marks that "seen" sets once `shown` (the messages the app showed, for example the
    /// quotes friends sent) are on screen: for each conversation where one of them is unread, the
    /// time of the newest one shown from it. Never later: a message the app has not fetched or shown
    /// (a text, or one that arrived after the last refresh, which the Inbox row's `lastMessageAt`
    /// may already include) stays unread. A conversation with nothing unread among `shown` gets no
    /// mark.
    public static func seenMarks(_ conversations: [InboxConversation], shown: [Message]) -> [UUID: Date] {
        var newestShown: [UUID: Date] = [:]
        var hasUnread: Set<UUID> = []
        let byID = Dictionary(conversations.map { ($0.id, $0) }) { first, _ in first }
        for message in shown {
            guard let conversation = byID[message.conversationID], message.senderID == conversation.otherID
            else { continue }
            newestShown[message.conversationID] = max(newestShown[message.conversationID] ?? message.createdAt, message.createdAt)
            if conversation.isUnread(message) { hasUnread.insert(message.conversationID) }
        }
        return newestShown.filter { hasUnread.contains($0.key) }
    }

    /// This row once your read mark moved to `time` (the newest of `shown` in it), until the next
    /// refresh brings the server's count. The mark never moves back. The unread count drops by the
    /// unread messages of `shown` it covers, and to zero only when nothing in the conversation is
    /// newer than `time`; a newer message from the other member keeps it at one at least.
    public func markedRead(upTo time: Date, shown: [Message]) -> InboxConversation {
        var row = self
        row.lastReadAt = max(lastReadAt ?? time, time)
        let covered = shown.count(where: { message in
            message.conversationID == id && isUnread(message) && message.createdAt <= time
        })
        if let lastMessageAt, lastMessageAt > time {
            let remaining = max(unreadCount - covered, 0)
            row.unreadCount = lastMessageSenderID == otherID ? max(remaining, 1) : remaining
        } else {
            row.unreadCount = 0
        }
        return row
    }
}

extension InboxConversation: Codable {
    enum CodingKeys: String, CodingKey {
        case id = "conversation_id"
        case otherID = "other_id"
        case otherUsername = "other_username"
        case otherDisplayName = "other_display_name"
        case otherAcceptsTextMessages = "other_accepts_text_messages"
        case isClosed = "is_closed"
        case lastMessageAt = "last_message_at"
        case lastMessageKind = "last_message_kind"
        case lastMessagePreview = "last_message_preview"
        case lastMessageSenderID = "last_message_sender_id"
        case unreadCount = "unread_count"
        case lastReadAt = "last_read_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        otherID = try container.decode(UUID.self, forKey: .otherID)
        if let username = try container.decodeIfPresent(String.self, forKey: .otherUsername) {
            other = Profile(
                id: otherID,
                username: username,
                displayName: try container.decodeIfPresent(String.self, forKey: .otherDisplayName),
                acceptsTextMessages: try container.decodeIfPresent(Bool.self, forKey: .otherAcceptsTextMessages)
            )
        } else {
            other = nil
        }
        isClosed = try container.decodeIfPresent(Bool.self, forKey: .isClosed) ?? false
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastMessageKind = try? container.decodeIfPresent(MessageKind.self, forKey: .lastMessageKind)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastMessageSenderID = try container.decodeIfPresent(UUID.self, forKey: .lastMessageSenderID)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(otherID, forKey: .otherID)
        try container.encode(other?.username, forKey: .otherUsername)
        let displayName: String? = if let other, other.displayName != other.username { other.displayName } else { nil }
        try container.encode(displayName, forKey: .otherDisplayName)
        try container.encode(other?.acceptsTextMessages, forKey: .otherAcceptsTextMessages)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encode(lastMessageAt, forKey: .lastMessageAt)
        try container.encode(lastMessageKind, forKey: .lastMessageKind)
        try container.encode(lastMessagePreview, forKey: .lastMessagePreview)
        try container.encode(lastMessageSenderID, forKey: .lastMessageSenderID)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(lastReadAt, forKey: .lastReadAt)
    }
}

/// The Inbox tab's badge: unread conversations (each counts once) plus pending incoming friend
/// requests. Zero hides it; above 99 it reads "99+".
public struct InboxBadge: Hashable, Sendable {
    public var unreadConversations: Int
    public var friendRequests: Int

    public init(unreadConversations: Int, friendRequests: Int) {
        self.unreadConversations = max(0, unreadConversations)
        self.friendRequests = max(0, friendRequests)
    }

    /// From the Inbox rows and the number of incoming requests.
    public init(conversations: [InboxConversation], friendRequests: Int) {
        self.init(unreadConversations: conversations.filter(\.isUnread).count, friendRequests: friendRequests)
    }

    /// The total the badge counts.
    public var count: Int { unreadConversations + friendRequests }

    /// The badge text: nil at zero (hidden), "99+" above 99.
    public var label: String? {
        switch count {
        case 0: nil
        case 1...99: String(count)
        default: "99+"
        }
    }

    /// The tab's VoiceOver value, for example "2 unread conversations, 1 friend request". Nil at zero.
    public var accessibilityValue: String? {
        var parts: [String] = []
        if unreadConversations > 0 {
            parts.append("\(unreadConversations) unread \(unreadConversations == 1 ? "conversation" : "conversations")")
        }
        if friendRequests > 0 {
            parts.append("\(friendRequests) \(friendRequests == 1 ? "friend request" : "friend requests")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
