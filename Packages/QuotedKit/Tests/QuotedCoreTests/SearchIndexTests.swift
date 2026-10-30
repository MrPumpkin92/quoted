import Foundation
import Testing
@testable import QuotedCore

@Suite("SearchIndex")
struct SearchIndexTests {
    static let created = Date(timeIntervalSince1970: 1_000)

    static func quote(_ n: Int, _ body: String, author: String? = nil, source: String? = nil) -> Quote {
        Quote(id: Fixture.id(n), body: body, author: author, source: source, createdAt: created)
    }

    let library = [
        quote(1, "Be yourself; everyone else is already taken.", author: "Oscar Wilde"),
        quote(2, "Imagination is more important than knowledge.", author: "Albert Einstein", source: "Interview, 1929"),
        quote(3, "Café conversations change the world.", author: "Anonymous"),
        quote(4, "Life can only be understood backwards; but it must be lived forwards.", author: "Søren Kierkegaard"),
        quote(5, "Don’t count the days, make the days count.", author: "Muhammad Ali"),
        quote(6, "The unexamined life is not worth living.", author: "Socrates", source: "Apology"),
        quote(7, "Whatever you are, be a good one.", author: "Abraham Lincoln"),
    ]

    let inbox = [
        Message(
            id: Fixture.id(100), conversationID: Fixture.id(300), senderID: Fixture.id(200), kind: .quote,
            note: "for the interview",
            quote: QuoteSnapshot(body: "Stay hungry, stay foolish.", author: "Steve Jobs", source: "Stanford commencement"),
            createdAt: created
        ),
        Message(
            id: Fixture.id(101), conversationID: Fixture.id(300), senderID: Fixture.id(200), kind: .text,
            text: "See you at the zoo", createdAt: created
        ),
        Message(
            id: Fixture.id(102), conversationID: Fixture.id(300), senderID: Fixture.id(200), kind: .playlist,
            playlistID: Fixture.id(400), playlistTitle: "Morning Pages", createdAt: created
        ),
    ]

    func ids(_ query: String) -> [Int] {
        SearchIndex.search(query, quotes: library, inbox: inbox).library.map { library.firstIndex(of: $0)! + 1 }
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(ids("cafe") == [3])
        #expect(ids("CAFÉ") == [3])
        #expect(ids("soren") == [4])
        #expect(ids("KIERKEGAARD") == [4])
        #expect(ids("ｃａｆｅ") == [3]) // full-width
        #expect(ids("don't") == [5]) // straight apostrophe finds the curly one
    }

    @Test func trimsAndRequiresEveryWord() {
        let results = SearchIndex.search("   life   lived  ", quotes: library, inbox: inbox)
        #expect(results.webQuery == "life lived")
        #expect(results.library.map(\.id) == [Fixture.id(4)])
        #expect(ids("life pizza").isEmpty)
        // Words may match different fields.
        #expect(ids("imagination einstein") == [2])
        #expect(ids("apology socrates") == [6])
        #expect(ids("1929") == [2])
    }

    @Test func ranksBodyPrefixThenWordsThenSubstringsThenAuthor() {
        let corpus = [
            Self.quote(1, "A friend of Ali once said this.", author: "Unknown"),
            Self.quote(2, "Others call it a salient point.", author: "Unknown"),
            Self.quote(3, "Something else entirely.", author: "Muhammad Ali"),
            Self.quote(4, "Ali was the greatest.", author: "Unknown"),
            Self.quote(5, "Nothing here.", author: "Talia Shire"),
            Self.quote(6, "Nothing at all.", author: "Unknown", source: "Ali's book"),
        ]
        let results = SearchIndex.search("ali", quotes: corpus, inbox: [])
        #expect(results.library.map(\.id) == [4, 1, 2, 3, 5, 6].map(Fixture.id))
    }

    @Test func tiesKeepInputOrder() {
        let results = SearchIndex.search("be", quotes: library, inbox: [])
        // "Be yourself" starts with the query, two bodies contain "be" as a word (kept in input
        // order), and "Albert Einstein" only matches inside the author's name.
        #expect(results.library.map(\.id) == [1, 4, 7, 2].map(Fixture.id))
    }

    @Test func searchesMessages() {
        let results = SearchIndex.search("hungry jobs", quotes: library, inbox: inbox)
        #expect(results.library.isEmpty)
        #expect(results.inbox.map(\.id) == [Fixture.id(100)])
        #expect(!results.isEmpty)
        // A quote's note, a text and a playlist's title are searched too.
        #expect(SearchIndex.search("interview", quotes: library, inbox: inbox).inbox.map(\.id) == [Fixture.id(100)])
        #expect(SearchIndex.search("zoo", quotes: library, inbox: inbox).inbox.map(\.id) == [Fixture.id(101)])
        #expect(SearchIndex.search("morning", quotes: library, inbox: inbox).inbox.map(\.id) == [Fixture.id(102)])
        #expect(SearchIndex.search("zebra", quotes: library, inbox: inbox).isEmpty)
    }

    @Test func emptyQueryReturnsEverything() {
        let results = SearchIndex.search("  \n ", quotes: library, inbox: inbox)
        #expect(results.library == library)
        #expect(results.inbox == inbox)
        #expect(results.webQuery.isEmpty)
    }

    @Test func reusableIndex() {
        let index = SearchIndex(quotes: library, inbox: inbox)
        #expect(index.search("wilde").library.map(\.id) == [Fixture.id(1)])
        #expect(index.search("count").library.map(\.id) == [Fixture.id(5)])
    }

    @Test("Google link-out is percent-encoded", arguments: [
        ("be yourself", "https://www.google.com/search?q=be%20yourself%20quotes"),
        ("  be   yourself ", "https://www.google.com/search?q=be%20yourself%20quotes"),
        ("café & co", "https://www.google.com/search?q=caf%C3%A9%20%26%20co%20quotes"),
        ("a+b/c?d=e#f", "https://www.google.com/search?q=a%2Bb%2Fc%3Fd%3De%23f%20quotes"),
        ("love quotes", "https://www.google.com/search?q=love%20quotes"),
        ("Einstein Quote", "https://www.google.com/search?q=Einstein%20Quote"),
        ("", "https://www.google.com/search?q=quotes"),
        ("🙂", "https://www.google.com/search?q=%F0%9F%99%82%20quotes"),
        ("don't", "https://www.google.com/search?q=don%27t%20quotes"),
    ])
    func googleURL(term: String, expected: String) {
        #expect(SearchIndex.googleURL(for: term).absoluteString == expected)
    }

    @Test func resultsCarryTheWebURL() {
        let results = SearchIndex.search(" stoic  calm ", quotes: library, inbox: inbox)
        #expect(results.webURL.absoluteString == "https://www.google.com/search?q=stoic%20calm%20quotes")
    }

    @Test func foldNormalizesForComparison() {
        #expect(SearchIndex.fold("  Ærø  Straße “Hi” ") == "aero strasse \"hi\"")
    }
}
