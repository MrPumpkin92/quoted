import Foundation

/// The result of one search over the library and the loaded messages.
public struct SearchResults: Hashable, Sendable {
    /// Matching library quotes, best first.
    public var library: [Quote]
    /// Matching messages (quotes, texts and playlists), best first.
    public var inbox: [Message]
    /// The cleaned-up term for the "Search the web for '<term>' quotes" row. Empty for an empty query.
    public var webQuery: String

    public init(library: [Quote], inbox: [Message], webQuery: String) {
        self.library = library
        self.inbox = inbox
        self.webQuery = webQuery
    }

    /// Whether neither section has a match.
    public var isEmpty: Bool { library.isEmpty && inbox.isEmpty }

    /// The Google link-out for ``webQuery``.
    public var webURL: URL { SearchIndex.googleURL(for: webQuery) }
}

/// Client-side search over the cached library and the loaded messages.
///
/// Matching is case-, diacritic- and width-insensitive over body, author and source (for a message:
/// a quote's body, author, source and note, a text, or a playlist's title), with curly
/// quotes treated as straight ones. The query is trimmed and split on whitespace; every word must
/// appear in at least one field. Ranking: body starts with the query, then every word starts a word
/// in the body, then every word appears in the body, then author word matches, then author
/// substrings, then anything else. Ties keep the input order.
///
/// Build an index once per data change and call ``search(_:)`` per keystroke; the static
/// ``search(_:quotes:inbox:)`` does both.
public struct SearchIndex: Sendable {
    private let quotes: [Entry<Quote>]
    private let inbox: [Entry<Message>]

    public init(quotes: [Quote], inbox: [Message] = []) {
        self.quotes = quotes.map { Entry(item: $0, body: $0.body, author: $0.author, source: $0.source) }
        self.inbox = inbox.map { message in
            switch message.content {
            case .text(let text):
                Entry(item: message, body: text, author: nil, source: nil)
            case .quote(let quote, let note):
                Entry(item: message, body: quote.body, author: quote.author, source: quote.source, extra: note)
            case .playlist(_, let title):
                Entry(item: message, body: title, author: nil, source: nil)
            }
        }
    }

    /// Searches the index. An empty or whitespace-only query returns everything in input order.
    public func search(_ query: String) -> SearchResults {
        let webQuery = RichText.collapseWhitespace(query)
        let folded = Self.fold(webQuery)
        let tokens = folded.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            return SearchResults(library: quotes.map(\.item), inbox: inbox.map(\.item), webQuery: "")
        }
        return SearchResults(
            library: Self.rank(quotes, query: folded, tokens: tokens),
            inbox: Self.rank(inbox, query: folded, tokens: tokens),
            webQuery: webQuery
        )
    }

    /// Builds an index and runs one search.
    public static func search(_ query: String, quotes: [Quote], inbox: [Message] = []) -> SearchResults {
        SearchIndex(quotes: quotes, inbox: inbox).search(query)
    }

    /// `https://www.google.com/search?q=<term>%20quotes`, percent-encoded (everything but RFC 3986
    /// unreserved ASCII is escaped). " quotes" is not appended twice when the term already ends with
    /// "quote" or "quotes". An empty term searches for "quotes".
    public static func googleURL(for term: String) -> URL {
        let cleaned = RichText.collapseWhitespace(term)
        let lastWord = fold(cleaned).split(separator: " ").last.map(String.init)
        let query: String
        if cleaned.isEmpty {
            query = "quotes"
        } else if lastWord == "quote" || lastWord == "quotes" {
            query = cleaned
        } else {
            query = cleaned + " quotes"
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "quotes"
        return URL(string: "https://www.google.com/search?q=" + encoded)
            ?? URL(string: "https://www.google.com/search?q=quotes")!
    }

    /// The comparison form of `text`: case, diacritics and width folded, curly quotes straightened,
    /// whitespace collapsed.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.utf8.count)
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": result.unicodeScalars.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": result.unicodeScalars.append("\"")
            // Latin letters that have no decomposition, so diacritic folding leaves them alone.
            case "ø": result.unicodeScalars.append("o")
            case "ł": result.unicodeScalars.append("l")
            case "đ", "ð": result.unicodeScalars.append("d")
            case "ı": result.unicodeScalars.append("i")
            case "æ": result += "ae"
            case "œ": result += "oe"
            case "þ": result += "th"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return RichText.collapseWhitespace(result)
    }

    // MARK: Private

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private struct Entry<Item: Sendable>: Sendable {
        let item: Item
        let body: String
        let author: String
        let source: String
        /// Also searched, ranked last (a message's note).
        let extra: String

        init(item: Item, body: String, author: String?, source: String?, extra: String? = nil) {
            self.item = item
            self.body = SearchIndex.fold(body)
            self.author = SearchIndex.fold(author ?? "")
            self.source = SearchIndex.fold(source ?? "")
            self.extra = SearchIndex.fold(extra ?? "")
        }
    }

    private static func rank<Item>(_ entries: [Entry<Item>], query: String, tokens: [String]) -> [Item] {
        var scored: [(tier: Int, index: Int, item: Item)] = []
        for (index, entry) in entries.enumerated() {
            if let tier = tier(of: entry, query: query, tokens: tokens) {
                scored.append((tier, index, entry.item))
            }
        }
        scored.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        return scored.map(\.item)
    }

    private static func tier<Item>(of entry: Entry<Item>, query: String, tokens: [String]) -> Int? {
        for token in tokens
        where !entry.body.contains(token) && !entry.author.contains(token) && !entry.source.contains(token)
            && !entry.extra.contains(token) {
            return nil
        }
        if entry.body.hasPrefix(query) { return 0 }
        if tokens.allSatisfy({ startsWord(token: $0, in: entry.body) }) { return 1 }
        if tokens.allSatisfy({ entry.body.contains($0) }) { return 2 }
        if tokens.allSatisfy({ startsWord(token: $0, in: entry.author) }) { return 3 }
        if tokens.allSatisfy({ entry.author.contains($0) }) { return 4 }
        return 5
    }

    /// Whether `token` occurs in `text` at the start of a word.
    private static func startsWord(token: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex, let found = text.range(of: token, range: searchStart..<text.endIndex) {
            if found.lowerBound == text.startIndex {
                return true
            }
            let previous = text[text.index(before: found.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }
}
