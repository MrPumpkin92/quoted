import Foundation
import QuotedCore

/// Sample content from the Margin mockups, for previews (`AppModel.preview()`) and the share-card demo.
/// Never shown to real users.
enum Samples {
    // MARK: Quotes

    static let emerson = quote(
        "Trust thyself: every heart vibrates to that iron string.",
        styled: ("Trust thyself", .bold),
        author: "Ralph Waldo Emerson", source: "Self-Reliance", position: 0, minutesAgo: 10, verified: 3
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
        author: "Jane Austen", source: "Pride and Prejudice", position: 5, minutesAgo: 80
    )

    /// The library, newest first. Six of the eight are in reminders.
    static let quotes: [Quote] = [emerson, shelley, seneca, whitman, thoreau, dickinson, shakespeare, austen]

    // MARK: People

    static let alex = Profile(id: uuid(1), username: "alex", displayName: "Alex")
    static let maya = Profile(id: uuid(2), username: "maya", displayName: "Maya Reyes")
    static let jordan = Profile(id: uuid(3), username: "jordan", displayName: "Jordan Lee")
    static let sam = Profile(id: uuid(4), username: "samk", displayName: "Sam Kim")
    static let riley = Profile(id: uuid(5), username: "riley", displayName: "Riley Park")

    /// Accepted friendships and pending requests, from Alex's point of view.
    static let friendships: [Friendship] = [
        friendship(5, with: maya, status: .accepted, incoming: false),
        friendship(6, with: jordan, status: .accepted, incoming: true),
        friendship(7, with: sam, status: .pending, incoming: true),
        friendship(8, with: riley, status: .pending, incoming: false),
    ]

    /// Quotes shared with Alex, newest first. Both unseen.
    static let inbox: [SharedQuote] = [
        SharedQuote(
            id: uuid(20), senderID: maya.id, sender: maya, recipientID: alex.id,
            body: austen.body, author: austen.author, source: austen.source,
            note: "Thought of you.", createdAt: Date(timeIntervalSinceNow: -2 * 3600)
        ),
        SharedQuote(
            id: uuid(21), senderID: jordan.id, sender: jordan, recipientID: alex.id,
            body: "But screw your courage to the sticking-place, and we\u{2019}ll not fail.",
            author: "William Shakespeare", source: "Macbeth",
            createdAt: Date(timeIntervalSinceNow: -26 * 3600)
        ),
    ]

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
        verified: Int? = nil
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
            verifiedStarterID: verified
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
