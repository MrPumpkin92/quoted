import Foundation

/// Splits pasted text such as `“Trust thyself.” — Ralph Waldo Emerson, Self-Reliance` or
/// `"…" - Name, Work` into body, author and source, and strips quotation marks that wrap the whole body.
///
/// Conservative by design: an attribution is only split off at a dash that follows a closing quotation
/// mark or starts a line, so dashes inside a quote ("I am — and therefore …") and hyphenated words
/// (Self-Reliance) never split. Round-trips `RichText.shareText` (`“body”\n— author, source`).
public enum PastedQuote {
    public struct Parts: Equatable, Sendable {
        public var body: String
        public var author: String?
        public var source: String?

        public init(body: String, author: String? = nil, source: String? = nil) {
            self.body = body
            self.author = author
            self.source = source
        }
    }

    /// The longest attribution (author, comma, source) accepted after a dash.
    public static let maxAttributionLength = Limits.authorMaxLength + Limits.sourceMaxLength + 2

    public static func parse(_ raw: String) -> Parts {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (quote, attribution) = splitAttribution(text) {
            let (author, source) = splitAuthorAndSource(attribution)
            if author != nil || source != nil {
                return Parts(body: stripWrappingQuotes(quote), author: author, source: source)
            }
        }
        return Parts(body: stripWrappingQuotes(text), author: nil, source: nil)
    }

    // MARK: Attribution

    private static let dashes: Set<Character> = ["\u{2014}", "\u{2013}", "\u{2015}", "\u{2012}", "-", "~"]
    private static let openingQuotes: Set<Character> = [
        "\u{201C}", "\"", "\u{201E}", "\u{00AB}", "\u{00BB}", "\u{2018}", "'", "\u{300C}", "\u{300E}", "\u{2039}", "\u{201D}",
    ]
    private static let closingQuotes: Set<Character> = [
        "\u{201D}", "\"", "\u{00BB}", "\u{2019}", "'", "\u{300D}", "\u{300F}", "\u{203A}", "\u{201C}",
    ]

    /// The quote and the attribution after the last qualifying dash, or nil, both trimmed.
    ///
    /// Linear in the length of `text`, so pasting a long page doesn't stall the editor: every check
    /// reads only the characters next to the dash, and the scan stops once the text after a dash is
    /// too long (or spans lines) to be an attribution, which is then true of every dash before it.
    static func splitAttribution(_ text: String) -> (String, String)? {
        let characters = Array(text)
        guard
            let contentStart = characters.firstIndex(where: { !$0.isWhitespace }),
            let contentEnd = characters.lastIndex(where: { !$0.isWhitespace })
        else { return nil }

        var index = contentEnd
        while index > 0 {
            let character = characters[index]
            guard dashes.contains(character) else {
                index -= 1
                continue
            }
            // "--" and "——" count as one dash.
            var start = index
            while start > 0, characters[start - 1] == character {
                start -= 1
            }
            defer { index = start - 1 }

            // The attribution: the text after the dash, trimmed.
            var attributionStart = index + 1
            while attributionStart <= contentEnd, characters[attributionStart].isWhitespace {
                attributionStart += 1
            }
            guard attributionStart <= contentEnd else { continue }
            let attribution = characters[attributionStart...contentEnd]
            // An earlier dash's attribution contains this one, so it can only be longer.
            if attribution.count > maxAttributionLength || attribution.contains(where: \.isNewline) { break }
            guard attribution.contains(where: \.isLetter) else { continue }

            // The quote: the text before the dash, trimmed.
            var quoteEnd = start - 1
            while quoteEnd >= contentStart, characters[quoteEnd].isWhitespace {
                quoteEnd -= 1
            }
            guard quoteEnd >= contentStart else { continue }

            // `“…” — Name`: the quote must be wrapped in marks, so `He said “no” — and left.` stays whole.
            let afterQuote = closingQuotes.contains(characters[quoteEnd]) && openingQuotes.contains(characters[contentStart])
            var lineEnd = start - 1
            while lineEnd >= 0, characters[lineEnd].isWhitespace, !characters[lineEnd].isNewline {
                lineEnd -= 1
            }
            let atLineStart = lineEnd >= 0 && characters[lineEnd].isNewline
            guard atLineStart || afterQuote else { continue }

            // A hyphen or tilde must stand apart ("” - Name"), unlike "Self-Reliance".
            if character == "-" || character == "~" {
                let spacedBefore = start == 0 || characters[start - 1].isWhitespace
                guard spacedBefore || index > start || afterQuote else { continue }
            }

            return (String(characters[contentStart...quoteEnd]), String(attribution))
        }
        return nil
    }

    /// "Name, Work" → ("Name", "Work"). Keeps suffixes with the name ("Martin Luther King, Jr., Strength to Love").
    static func splitAuthorAndSource(_ attribution: String) -> (String?, String?) {
        let parts = attribution.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 else { return (nonEmpty(attribution), nil) }
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "phd", "ph.d.", "md", "m.d."]
        var authorCount = 1
        while authorCount < parts.count - 1, suffixes.contains(parts[authorCount].lowercased()) {
            authorCount += 1
        }
        if authorCount == parts.count - 1, suffixes.contains(parts[authorCount].lowercased()) {
            return (nonEmpty(parts.joined(separator: ", ")), nil)
        }
        let author = parts[..<authorCount].joined(separator: ", ")
        let source = stripWrappingQuotes(parts[authorCount...].joined(separator: ", "))
        guard author.count <= Limits.authorMaxLength, source.count <= Limits.sourceMaxLength else {
            return (nil, nil)
        }
        return (nonEmpty(author), nonEmpty(source))
    }

    // MARK: Quotation marks

    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\u{201C}", "\u{201D}"), ("\"", "\""), ("\u{201E}", "\u{201C}"), ("\u{201E}", "\u{201D}"),
        ("\u{00AB}", "\u{00BB}"), ("\u{00BB}", "\u{00AB}"), ("\u{2018}", "\u{2019}"), ("'", "'"),
        ("\u{300C}", "\u{300D}"), ("\u{300E}", "\u{300F}"), ("\u{2039}", "\u{203A}"), ("\u{201D}", "\u{201D}"),
    ]

    /// Removes one pair of quotation marks wrapping the whole text, unless the inside has its own
    /// closing mark (`“A” and “B”` stays as is).
    static func stripWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return trimmed }
        for pair in quotePairs where first == pair.open && last == pair.close {
            let inner = trimmed.dropFirst().dropLast()
            guard !inner.contains(pair.close), !inner.contains(pair.open) else { return trimmed }
            let stripped = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? trimmed : stripped
        }
        return trimmed
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
