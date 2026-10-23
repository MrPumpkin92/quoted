import Foundation
import Testing
@testable import QuotedCore

@Suite("PastedQuote")
struct PastedQuoteTests {
    typealias Parts = PastedQuote.Parts

    @Test func splitsAQuotedAttribution() {
        #expect(PastedQuote.parse("“Trust thyself: every heart vibrates to that iron string.” — Ralph Waldo Emerson, Self-Reliance") == Parts(
            body: "Trust thyself: every heart vibrates to that iron string.",
            author: "Ralph Waldo Emerson",
            source: "Self-Reliance"
        ))
        #expect(PastedQuote.parse("\"Know thyself\" - Socrates") == Parts(body: "Know thyself", author: "Socrates"))
        #expect(PastedQuote.parse("\"Know thyself\" -- Socrates") == Parts(body: "Know thyself", author: "Socrates"))
    }

    @Test func roundTripsShareText() {
        let shared = "“Hope is the thing with feathers\nThat perches in the soul,”\n— Emily Dickinson, Hope"
        #expect(PastedQuote.parse(shared) == Parts(
            body: "Hope is the thing with feathers\nThat perches in the soul,",
            author: "Emily Dickinson",
            source: "Hope"
        ))
    }

    @Test func splitsAtADashThatStartsALine() {
        #expect(PastedQuote.parse("While we are postponing, life speeds by.\n  — Seneca") == Parts(
            body: "While we are postponing, life speeds by.",
            author: "Seneca"
        ))
    }

    @Test func keepsNameSuffixesWithTheAuthor() {
        let parts = PastedQuote.parse("“Darkness cannot drive out darkness.” — Martin Luther King, Jr., Strength to Love")
        #expect(parts.author == "Martin Luther King, Jr.")
        #expect(parts.source == "Strength to Love")
    }

    @Test func leavesDashesInsideTheQuoteAlone() {
        let texts = [
            "Beware; for I am fearless — and therefore powerful.",
            "He said “no” — and left.",
            "The only way out is through. — Robert Frost",
            "Read Self-Reliance twice.",
        ]
        for text in texts {
            #expect(PastedQuote.parse(text) == Parts(body: text), "\(text)")
        }
    }

    @Test func rejectsAttributionsThatAreTooLongOrSpanLines() {
        let long = String(repeating: "x", count: PastedQuote.maxAttributionLength + 1)
        #expect(PastedQuote.splitAttribution("“Quote” — \(long)") == nil)
        #expect(PastedQuote.splitAttribution("“Quote” — Name\nMore") == nil)
        #expect(PastedQuote.splitAttribution("“Quote” — 1984") == nil, "an attribution needs a letter")
        #expect(PastedQuote.splitAttribution("— Name") == nil, "a quote is needed before the dash")
    }

    /// Pasting part of a web page used to take seconds: every dash rebuilt the whole text before it.
    @Test func longPastesStayFast() {
        let page = String(repeating: "a - b, c — d ", count: 5_000) // 65,000 characters, 10,000 dashes
        var parts: Parts?
        let elapsed = ContinuousClock().measure {
            parts = PastedQuote.parse(page)
        }
        #expect(parts == Parts(body: page.trimmingCharacters(in: .whitespaces)))
        #expect(elapsed < .seconds(1))

        let attributed = page + "\n— Someone, Somewhere"
        let split = ContinuousClock().measure {
            parts = PastedQuote.parse(attributed)
        }
        #expect(parts?.author == "Someone")
        #expect(parts?.source == "Somewhere")
        #expect(split < .seconds(1))
    }
}
