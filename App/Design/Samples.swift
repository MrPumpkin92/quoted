import Foundation
import QuotedCore

/// Sample content from the Margin mockups, for previews (`AppModel.preview()`) and the share-card demo.
/// Never shown to real users.
enum Samples {
    // MARK: Quotes

    static let emerson = quote(
        "Trust thyself: every heart vibrates to that iron string.",
        styled: ("Trust thyself", .bold),
        author: "Ralph Waldo Emerson", source: "Self-Reliance", position: 0, minutesAgo: 10, verified: 3,
        favoritedMinutesAgo: 5
    )
    static let shelley = quote(
        "Beware; for I am fearless, and therefore powerful.",
        styled: ("fearless", .italic),
        author: "Mary Shelley", source: "Frankenstein", position: 1, minutesAgo: 20, verified: 1
    )
    static let seneca = quote(
        "While we are postponing, life speeds by.",
        styled: ("life", .underline),
        author: "Seneca", source: "Letters to Lucilius", position: 2, minutesAgo: 30
    )
    static let whitman = quote(
        "I am large, I contain multitudes.",
        author: "Walt Whitman", source: "Song of Myself", minutesAgo: 40
    )
    static let thoreau = quote(
        "I went to the woods because I wished to live deliberately.",
        author: "Henry David Thoreau", source: "Walden", position: 3, minutesAgo: 50
    )
    static let dickinson = quote(
        "\u{201C}Hope\u{201D} is the thing with feathers \u{2013} That perches in the soul \u{2013}",
        author: "Emily Dickinson", minutesAgo: 60
    )
    static let shakespeare = quote(
        "This above all: to thine own self be true.",
        author: "William Shakespeare", source: "Hamlet", position: 4, minutesAgo: 70
    )
    static let austen = quote(
        "There is a stubbornness about me that never can bear to be frightened at the will of others. My courage always rises at every attempt to intimidate me.",
        author: "Jane Austen", source: "Pride and Prejudice", position: 5, minutesAgo: 80,
        favoritedMinutesAgo: 15
    )

    /// The library, newest first. Six of the eight are in reminders.
    static let quotes: [Quote] = [emerson, shelley, seneca, whitman, thoreau, dickinson, shakespeare, austen]

    // MARK: People

    static let alex = Profile(id: uuid(1), username: "alex", displayName: "Alex")
    /// Maya shows her favorites to friends (`mayaFavorites`).
    static let maya = Profile(id: uuid(2), username: "maya", displayName: "Maya Reyes")
    static let jordan = Profile(id: uuid(3), username: "jordan", displayName: "Jordan Lee")
    static let sam = Profile(id: uuid(4), username: "samk", displayName: "Sam Kim")
    static let riley = Profile(id: uuid(5), username: "riley", displayName: "Riley Park")

    /// Maya's favorites, as her profile shows them to Alex (she shows them to friends).
    static let mayaFavorites: [FriendFavorite] = [
        FriendFavorite(
            id: uuid(40),
            body: shelley.body,
            format: shelley.format,
            author: shelley.author,
            source: shelley.source,
            verifiedStarterID: shelley.verifiedStarterID,
            favoritedAt: Date(timeIntervalSinceNow: -2 * 3600)
        ),
        FriendFavorite(
            id: uuid(41),
            body: "Not all those who wander are lost.",
            author: "J. R. R. Tolkien",
            source: "The Fellowship of the Ring",
            favoritedAt: Date(timeIntervalSinceNow: -26 * 3600)
        ),
    ]

    /// Accepted friendships and pending requests, from Alex's point of view.
    static let friendships: [Friendship] = [
        friendship(5, with: maya, status: .accepted, incoming: false),
        friendship(6, with: jordan, status: .accepted, incoming: true),
        friendship(7, with: sam, status: .pending, incoming: true),
        friendship(8, with: riley, status: .pending, incoming: false),
    ]

    /// Alex's conversations with Maya and Jordan, newest first, each with one unread quote.
    static let conversations: [InboxConversation] = [
        InboxConversation(
            id: uuid(30), otherID: maya.id, other: maya, lastMessageAt: inboxMessages[0].createdAt,
            lastMessageKind: .quote, lastMessagePreview: austen.body, lastMessageSenderID: maya.id, unreadCount: 1
        ),
        InboxConversation(
            id: uuid(31), otherID: jordan.id, other: jordan, lastMessageAt: inboxMessages[1].createdAt,
            lastMessageKind: .quote, lastMessagePreview: inboxMessages[1].quote?.body, lastMessageSenderID: jordan.id,
            unreadCount: 1
        ),
    ]

    /// Quotes Maya and Jordan sent Alex, newest first.
    static let inboxMessages: [ConversationMessage] = [
        ConversationMessage(
            id: uuid(20), conversationID: uuid(30), senderID: maya.id, kind: .quote, note: "Thought of you.",
            quote: QuoteSnapshot(
                body: austen.body, author: austen.author, source: austen.source,
                creatorID: maya.id, creatorUsername: maya.username
            ),
            createdAt: Date(timeIntervalSinceNow: -2 * 3600)
        ),
        ConversationMessage(
            id: uuid(21), conversationID: uuid(31), senderID: jordan.id, kind: .quote,
            quote: QuoteSnapshot(
                body: "But screw your courage to the sticking-place, and we\u{2019}ll not fail.",
                author: "William Shakespeare", source: "Macbeth"
            ),
            createdAt: Date(timeIntervalSinceNow: -26 * 3600)
        ),
    ]

    /// The quotes in `inboxMessages`, as "Shared with you" shows them.
    static let inbox: [InboxQuote] = [
        InboxQuote(message: inboxMessages[0], sender: maya),
        InboxQuote(message: inboxMessages[1], sender: jordan),
    ].compactMap { $0 }

    /// A few starter-pack quotes.
    static let starters: [StarterQuote] = [shelley, thoreau, emerson, dickinson, seneca, shakespeare]
        .enumerated()
        .map { index, quote in
            StarterQuote(
                id: index + 1, body: quote.body, format: quote.format, author: quote.author, source: quote.source,
                sortOrder: index + 1, sourceLocation: sourceLocations[index + 1],
                sourceURL: URL(string: "https://www.gutenberg.org/ebooks/42324")
            )
        }

    /// The verified catalog for Verified Quotes: the sample starters with themes, then two quotes from
    /// a later batch (one spoken by a character).
    static let catalog: [CatalogQuote] = {
        let themes: [[CatalogTheme]] = [[.courage], [.nature, .purpose], [.selfhood, .courage], [.courage], [.time, .purpose], [.selfhood]]
        let starters = zip(Samples.starters, themes).map { starter, themes in
            var quote = CatalogQuote(starter: starter)
            quote.themes = themes
            return quote
        }
        return starters + [
            CatalogQuote(
                id: 61, body: "A thing of beauty is a joy for ever:", author: "John Keats", source: "Endymion",
                sourceLocation: "Book I, line 1", sourceURL: URL(string: "https://www.gutenberg.org/ebooks/24280"),
                themes: [.nature, .love]
            ),
            CatalogQuote(
                id: 62, body: "There is nothing either good or bad, but thinking makes it so.",
                author: "William Shakespeare", source: "Hamlet",
                sourceLocation: "Act 2, Scene 2", sourceURL: URL(string: "https://www.gutenberg.org/ebooks/1524"),
                speaker: "Hamlet", themes: [.calm, .selfhood]
            ),
        ]
    }()

    /// Where two sample starters are in their works (ids as in `starters`).
    private static let sourceLocations = [1: "1831 edition, Chapter 20", 3: "Essays: First Series (1841), 3rd paragraph"]

    // MARK: Helpers

    /// A quote whose `styled` phrase carries the given flags (offsets computed in UTF-16).
    static func quote(
        _ body: String,
        styled: (String, TextFlags)? = nil,
        author: String?,
        source: String? = nil,
        position: Int? = nil,
        minutesAgo: Double,
        verified: Int? = nil,
        favoritedMinutesAgo: Double? = nil
    ) -> Quote {
        var runs: [TextRun] = []
        if let styled, let range = body.range(of: styled.0) {
            let start = body.utf16.distance(from: body.utf16.startIndex, to: range.lowerBound)
            runs = [TextRun(start: start, length: styled.0.utf16.count, flags: styled.1)]
        }
        return Quote(
            id: UUID(),
            body: body,
            format: runs,
            author: author,
            source: source,
            origin: .manual,
            rotationPosition: position,
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            verifiedStarterID: verified,
            isFavorite: favoritedMinutesAgo != nil,
            favoritedAt: favoritedMinutesAgo.map { Date(timeIntervalSinceNow: -$0 * 60) }
        )
    }

    private static func friendship(_ seed: UInt8, with other: Profile, status: FriendshipStatus, incoming: Bool) -> Friendship {
        Friendship(
            id: uuid(seed),
            requesterID: incoming ? other.id : alex.id,
            addresseeID: incoming ? alex.id : other.id,
            status: status,
            createdAt: Date(timeIntervalSinceNow: -Double(seed) * 3600),
            otherParty: other
        )
    }

    /// A fixed UUID per seed, so avatar tints stay stable across preview runs.
    static func uuid(_ seed: UInt8) -> UUID {
        UUID(uuid: (seed, 0x51, 0x55, 0x4F, 0x54, 0x45, 0x44, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, seed))
    }
}
