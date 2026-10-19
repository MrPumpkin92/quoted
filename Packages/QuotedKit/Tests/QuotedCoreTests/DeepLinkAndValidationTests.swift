import Foundation
import Testing
@testable import QuotedCore

@Suite("DeepLink")
struct DeepLinkTests {
    let id = UUID(uuidString: "8F0C5B8E-3F5E-4C1A-9A51-0D8C1C7E2B11")!

    @Test("Parses auth callbacks with their full URL", arguments: [
        "quoted://auth-callback",
        "quoted://auth-callback#access_token=abc&refresh_token=def&type=signup",
        "quoted://auth-callback?code=123&type=signup",
        "QUOTED://Auth-Callback?code=1",
    ])
    func parsesAuthCallback(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(DeepLink.parse(url) == .authCallback(url))
        #expect(DeepLink(url: url)?.url == url)
    }

    @Test func parsesQuoteAndRotation() throws {
        #expect(DeepLink.parse(URL(string: "quoted://quote/8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11")!) == .quote(id))
        #expect(DeepLink.parse(URL(string: "Quoted://QUOTE/8F0C5B8E-3F5E-4C1A-9A51-0D8C1C7E2B11")!) == .quote(id))
        #expect(DeepLink.parse(URL(string: "quoted://quote/8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11/")!) == .quote(id))
        #expect(DeepLink.parse(URL(string: "quoted://rotation")!) == .rotation)
        #expect(DeepLink.parse(URL(string: "quoted://rotation/")!) == .rotation)
    }

    @Test("Rejects unknown links", arguments: [
        "quoted://quote/not-a-uuid",
        "quoted://quote",
        "quoted://quote/8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11/extra",
        "quoted://rotation/extra",
        "quoted://settings",
        "https://quote/8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11",
        "quoted:quote",
        "mailto:someone@example.com",
    ])
    func rejects(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(DeepLink.parse(url) == nil)
    }

    @Test func buildsURLs() {
        #expect(DeepLink.url(for: .quote(id)).absoluteString == "quoted://quote/8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11")
        #expect(DeepLink.url(for: .rotation).absoluteString == "quoted://rotation")
        #expect(DeepLink.authCallbackURL.absoluteString == "quoted://auth-callback")
        for link in [DeepLink.quote(id), .rotation, .authCallback(DeepLink.authCallbackURL)] {
            #expect(DeepLink.parse(link.url) == link)
        }
    }
}

@Suite("Validation")
struct ValidationTests {
    @Test("Accepts and normalizes usernames", arguments: [
        ("ada", "ada"),
        ("  @Hwei.92 ", "hwei.92"),
        ("UNDER_SCORE", "under_score"),
        ("a.b", "a.b"),
        ("abcdefghijklmnopqrst", "abcdefghijklmnopqrst"),
    ])
    func acceptsUsernames(input: String, expected: String) throws {
        #expect(try Username.validate(input) == expected)
        #expect(Username.isValid(input))
    }

    @Test("Rejects usernames with a friendly reason", arguments: [
        ("", UsernameError.empty),
        ("  @ ", .empty),
        ("ab", .tooShort(minimum: 3)),
        ("abcdefghijklmnopqrstu", .tooLong(maximum: 20)),
        ("héllo", .invalidCharacters),
        ("with space", .invalidCharacters),
        ("a-b-c", .invalidCharacters),
        ("emoji😀", .invalidCharacters),
        ("İstanbul", .invalidCharacters),
    ])
    func rejectsUsernames(input: String, error: UsernameError) {
        #expect(throws: error) { try Username.validate(input) }
        #expect(!Username.isValid(input))
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func displayNames() throws {
        #expect(try DisplayName.validate("  Ada Lovelace ") == "Ada Lovelace")
        #expect(throws: DisplayNameError.empty) { try DisplayName.validate(" \n") }
        #expect(try DisplayName.validate(String(repeating: "é", count: 50)).count == 50)
        #expect(throws: DisplayNameError.tooLong(maximum: 50)) { try DisplayName.validate(String(repeating: "x", count: 51)) }
    }

    @Test func draftTrimsAndShiftsRuns() throws {
        let draft = QuoteDraft(
            body: "  \n hello world \n",
            format: [TextRun(start: 4, length: 5, bold: true), TextRun(start: 0, length: 2, italic: true)],
            author: "  Ada  ",
            source: "   "
        )
        let validated = try draft.validated()
        #expect(validated.body == "hello world")
        #expect(validated.format == [TextRun(start: 0, length: 5, bold: true)])
        #expect(validated.author == "Ada")
        #expect(validated.source == nil)
        #expect(draft.isValid)
    }

    @Test func draftLimits() throws {
        #expect(throws: QuoteDraftError.emptyBody) { try QuoteDraft(body: " \n\t ").validated() }
        #expect(throws: QuoteDraftError.emptyBody) { try QuoteDraft(body: "").validated() }
        #expect(try QuoteDraft(body: String(repeating: "a", count: 2000)).validated().body.count == 2000)
        #expect(throws: QuoteDraftError.bodyTooLong(maximum: 2000)) { try QuoteDraft(body: String(repeating: "a", count: 2001)).validated() }
        // Limits count Unicode scalars like Postgres char_length, not UTF-16 units.
        #expect(try QuoteDraft(body: String(repeating: "😀", count: 2000)).validated().body.utf16.count == 4000)
        #expect(throws: QuoteDraftError.authorTooLong(maximum: 200)) {
            try QuoteDraft(body: "x", author: String(repeating: "a", count: 201)).validated()
        }
        #expect(throws: QuoteDraftError.sourceTooLong(maximum: 200)) {
            try QuoteDraft(body: "x", source: String(repeating: "a", count: 201)).validated()
        }
        #expect(try QuoteDraft(body: "x", author: String(repeating: "a", count: 200)).validated().author?.count == 200)

        let body = String(repeating: "ab", count: 201)
        let runs = (0..<201).map { TextRun(start: $0 * 2, length: 1, bold: true) }
        #expect(throws: QuoteDraftError.tooMuchFormatting(maximum: 200)) { try QuoteDraft(body: body, format: runs).validated() }
        #expect(try QuoteDraft(body: body, format: Array(runs.prefix(200))).validated().format.count == 200)
    }

    @Test func notes() throws {
        #expect(try QuoteDraft.validatedNote("  thought of you ") == "thought of you")
        #expect(try QuoteDraft.validatedNote(" \n ") == nil)
        #expect(try QuoteDraft.validatedNote(String(repeating: "n", count: 280))?.count == 280)
        #expect(throws: QuoteDraftError.noteTooLong(maximum: 280)) { try QuoteDraft.validatedNote(String(repeating: "n", count: 281)) }
        #expect(QuoteDraftError.noteTooLong(maximum: 280).errorDescription?.contains("280") == true)
    }

    @Test func draftsFromExistingContent() {
        let created = Date(timeIntervalSince1970: 0)
        let quote = Quote(body: "Q", format: [TextRun(start: 0, length: 1, underline: true)], author: "A", source: nil, createdAt: created)
        #expect(QuoteDraft(quote: quote) == QuoteDraft(body: "Q", format: quote.format, author: "A", source: ""))
        let share = SharedQuote(id: Fixture.id(1), senderID: Fixture.id(2), recipientID: Fixture.id(3), body: "S", source: "Book", createdAt: created)
        #expect(QuoteDraft(shared: share) == QuoteDraft(body: "S", author: "", source: "Book"))
        let starter = StarterQuote(id: 1, body: "Know thyself.", author: "Socrates")
        #expect(QuoteDraft(starter: starter).author == "Socrates")
    }
}
