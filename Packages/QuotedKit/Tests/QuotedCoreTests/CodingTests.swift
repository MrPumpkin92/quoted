import Foundation
import Testing
@testable import QuotedCore

@Suite("Timestamp")
struct TimestampTests {
    /// 2026-10-19T03:26:38Z
    let base: TimeInterval = 1_792_380_398

    @Test("Parses Postgres timestamptz text", arguments: [
        ("2026-10-19T03:26:38.123456+00:00", 0.123456),
        ("2026-10-19T03:26:38+00:00", 0),
        ("2026-10-19T03:26:38Z", 0),
        ("2026-10-19T03:26:38.5Z", 0.5),
        ("2026-10-19 03:26:38.123+00", 0.123),
        ("2026-10-19T05:26:38+02:00", 0),
        ("2026-10-18T20:26:38-07:00", 0),
        ("2026-10-19T08:56:38+0530", 0),
        ("2026-10-19T03:26:38", 0),
        ("2026-10-19T03:26:38.123456789123Z", 0.123456789),
    ])
    func parses(text: String, fraction: Double) throws {
        let date = try #require(Timestamp.date(from: text))
        #expect(abs(date.timeIntervalSince1970 - (base + fraction)) < 1e-6)
    }

    @Test("Rejects malformed text", arguments: [
        "", "garbage", "2026-10-19", "2026-13-01T00:00:00Z", "2026-02-29T00:00:00Z",
        "2026-04-31T00:00:00Z", "2026-10-19T24:00:00Z", "2026-10-19T03:60:00Z",
        "2026-10-19T03:26:38+00:00x", "2026-10-19T03:26:38.Z", "2026/10/19T03:26:38Z",
    ])
    func rejects(text: String) {
        #expect(Timestamp.date(from: text) == nil)
    }

    @Test func acceptsLeapDay() throws {
        let date = try #require(Timestamp.date(from: "2028-02-29T12:00:00Z"))
        #expect(Timestamp.string(from: date) == "2028-02-29T12:00:00.000000Z")
    }

    @Test func formatsUTCWithMicroseconds() throws {
        let date = try #require(Timestamp.date(from: "2026-10-19T03:26:38.123456+00:00"))
        #expect(Timestamp.string(from: date) == "2026-10-19T03:26:38.123456Z")
        #expect(Timestamp.string(from: Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500000Z")
        #expect(Timestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000000Z")
    }

    @Test func roundTripsAcrossCenturies() throws {
        var generator = SplitMix64(seed: 42)
        for _ in 0..<500 {
            // 1900...2100, with microseconds.
            let micros = Int64(bitPattern: generator.next() % 6_311_433_600_000_000) - 2_208_988_800_000_000
            let date = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
            let text = Timestamp.string(from: date)
            let parsed = try #require(Timestamp.date(from: text))
            #expect(abs(parsed.timeIntervalSince1970 - date.timeIntervalSince1970) < 1e-6, "\(text)")
        }
    }

    @Test func civilDayArithmeticMatchesFoundation() {
        let calendar = Fixture.calendar("UTC")
        for days in stride(from: -30_000, through: 60_000, by: 97) {
            let (year, month, day) = Timestamp.civilFromDays(days)
            #expect(Timestamp.daysFromCivil(year: year, month: month, day: day) == days)
            let date = Date(timeIntervalSince1970: Double(days) * 86_400)
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            #expect(components.year == year && components.month == month && components.day == day)
        }
    }

    @Test func coderStrategiesUseTimestamp() throws {
        struct Box: Codable, Equatable { let at: Date }
        let box = try Fixture.decode(Box.self, #"{"at":"2026-10-19T03:26:38.250000+00:00"}"#)
        #expect(box.at.timeIntervalSince1970 == base + 0.25)
        #expect(try Fixture.jsonString(box) == #"{"at":"2026-10-19T03:26:38.250000Z"}"#)
        #expect(throws: DecodingError.self) { try Fixture.decode(Box.self, #"{"at":"yesterday"}"#) }
    }
}

@Suite("Models decode PostgREST rows")
struct ModelCodingTests {
    static let quoteRow = """
    {
      "id": "8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11",
      "owner_id": "11111111-2222-4333-8444-555555555555",
      "body": "Be yourself; everyone else is already taken.",
      "body_format": [{"start": 0, "length": 11, "bold": true}, {"start": 13, "length": 8, "italic": true, "underline": true}],
      "author": "Oscar Wilde",
      "source": null,
      "origin": "starter",
      "rotation_position": 2,
      "created_at": "2026-10-19T03:26:38.123456+00:00",
      "updated_at": "2026-10-19T03:26:40+00:00"
    }
    """

    @Test func decodesQuoteRow() throws {
        let quote = try Fixture.decode(Quote.self, Self.quoteRow)
        #expect(quote.id == UUID(uuidString: "8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11"))
        #expect(quote.body == "Be yourself; everyone else is already taken.")
        #expect(quote.format == [
            TextRun(start: 0, length: 11, bold: true),
            TextRun(start: 13, length: 8, italic: true, underline: true),
        ])
        #expect(quote.author == "Oscar Wilde")
        #expect(quote.source == nil)
        #expect(quote.origin == .starter)
        #expect(quote.rotationPosition == 2)
        #expect(quote.isInRotation)
        #expect(abs(quote.createdAt.timeIntervalSince1970 - 1_792_380_398.123456) < 1e-6)
        #expect(quote.updatedAt.timeIntervalSince1970 == 1_792_380_400)
    }

    @Test func encodesQuoteWithColumnNamesAndExplicitNulls() throws {
        let quote = try Fixture.decode(Quote.self, Self.quoteRow)
        let object = try Fixture.jsonObject(quote)
        #expect(Set(object.keys) == [
            "id", "body", "body_format", "author", "source", "origin", "rotation_position", "created_at", "updated_at",
            "verified_starter_id", "is_favorite", "favorited_at",
        ])
        #expect(object["is_favorite"] as? Bool == false)
        #expect(object["favorited_at"] is NSNull)
        #expect(object["verified_starter_id"] is NSNull)
        #expect(object["source"] is NSNull)
        #expect(object["origin"] as? String == "starter")
        #expect(object["created_at"] as? String == "2026-10-19T03:26:38.123456Z")
        let runs = try #require(object["body_format"] as? [[String: Any]])
        #expect(runs.count == 2)
        #expect(Set(runs[0].keys) == ["start", "length", "bold"])
        #expect(Set(runs[1].keys) == ["start", "length", "italic", "underline"])

        let notInRotation = Quote(id: Fixture.id(1), body: "x", createdAt: Date(timeIntervalSince1970: 0))
        #expect(try Fixture.jsonObject(notInRotation)["rotation_position"] is NSNull)
    }

    @Test func quoteRoundTrips() throws {
        let quote = try Fixture.decode(Quote.self, Self.quoteRow)
        let data = try QuotedJSON.makeEncoder().encode(quote)
        #expect(try QuotedJSON.makeDecoder().decode(Quote.self, from: data) == quote)
    }

    @Test func decodingClampsAndSkipsBadRuns() throws {
        let json = """
        {"id":"8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11","body":"hello","body_format":[
          {"start":3,"length":100,"bold":true},
          {"start":"zero","length":1,"italic":true},
          {"length":2,"underline":true},
          {"start":-4,"length":5,"italic":true},
          {"start":1,"length":1}
        ],"origin":"manual","created_at":"2026-10-19T03:26:38Z"}
        """
        let quote = try Fixture.decode(Quote.self, json)
        #expect(quote.format == [TextRun(start: 0, length: 1, italic: true), TextRun(start: 3, length: 2, bold: true)])
        // No updated_at falls back to created_at, no rotation_position means not in the Rotation.
        #expect(quote.updatedAt == quote.createdAt)
        #expect(!quote.isInRotation)
    }

    @Test("Null, missing or non-array body_format decodes as no runs", arguments: [
        #""body_format":null,"#, "", #""body_format":{"start":0},"#, #""body_format":"[]","#,
    ])
    func toleratesOddFormat(fragment: String) throws {
        let json = #"{"id":"8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11","body":"hi",\#(fragment)"created_at":"2026-10-19T03:26:38Z"}"#
        let quote = try Fixture.decode(Quote.self, json)
        #expect(quote.format.isEmpty)
        #expect(quote.origin == .manual)
    }

    @Test func unknownOriginFallsBackToManual() throws {
        let json = #"{"id":"8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11","body":"hi","origin":"imported","created_at":"2026-10-19T03:26:38Z"}"#
        #expect(try Fixture.decode(Quote.self, json).origin == .manual)
    }

    @Test func rawValuesMatchDatabase() {
        #expect(QuoteOrigin.allCases.map(\.rawValue) == ["manual", "starter", "shared", "pasted", "catalog"])
        #expect(CatalogTheme.allCases.map(\.rawValue) == ["courage", "calm", "time", "love", "nature", "purpose", "self"])
        #expect(CatalogTheme.allCases.map(\.title) == ["Courage", "Calm", "Time", "Love", "Nature", "Purpose", "Self"])
        #expect(CatalogStatus.allCases.map(\.rawValue) == ["live", "retired", "withdrawn"])
        #expect(ReportReason.allCases.map(\.rawValue) == ["spam", "harassment", "inappropriate", "other"])
        #expect(FriendshipStatus.allCases.map(\.rawValue) == ["pending", "accepted"])
        #expect(ReportReason.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func decodesShareWithEmbeddedSender() throws {
        let json = """
        {"id":"0a6f1b9c-0000-4000-8000-000000000001","sender_id":"0a6f1b9c-0000-4000-8000-0000000000aa",
         "recipient_id":"0a6f1b9c-0000-4000-8000-0000000000bb","quote_id":null,
         "body":"Stay hungry 🍎","body_format":[{"start":12,"length":2,"bold":true}],"author":"Steve Jobs",
         "source":"Stanford, 2005","note":"thought of you","created_at":"2026-10-19T03:26:38.5+00:00",
         "seen_at":"2026-10-19T04:00:00+00:00","saved_at":null,
         "sender":{"id":"0a6f1b9c-0000-4000-8000-0000000000aa","username":"ada","display_name":null}}
        """
        let share = try Fixture.decode(SharedQuote.self, json)
        #expect(share.sender?.username == "ada")
        #expect(share.sender?.displayName == "ada")
        #expect(share.recipient == nil)
        #expect(share.quoteID == nil)
        #expect(share.format == [TextRun(start: 12, length: 2, bold: true)])
        #expect(share.note == "thought of you")
        #expect(share.isSeen && !share.isSaved)
        let object = try Fixture.jsonObject(share)
        #expect(object["saved_at"] is NSNull)
        #expect(object["quote_id"] is NSNull)
        #expect(object["recipient"] == nil)
        let data = try QuotedJSON.makeEncoder().encode(share)
        #expect(try QuotedJSON.makeDecoder().decode(SharedQuote.self, from: data) == share)
    }

    @Test func decodesFriendshipAndFindsOtherParty() throws {
        let me = UUID(uuidString: "0a6f1b9c-0000-4000-8000-0000000000bb")!
        let json = """
        {"id":"0a6f1b9c-0000-4000-8000-000000000009","requester_id":"0a6f1b9c-0000-4000-8000-0000000000aa",
         "addressee_id":"0a6f1b9c-0000-4000-8000-0000000000bb","status":"pending",
         "created_at":"2026-10-19T03:26:38+00:00","responded_at":null,
         "requester":{"id":"0a6f1b9c-0000-4000-8000-0000000000aa","username":"ada","display_name":"Ada L."},
         "addressee":{"id":"0a6f1b9c-0000-4000-8000-0000000000bb","username":"me","display_name":"Me"}}
        """
        let friendship = try Fixture.decode(Friendship.self, json)
        #expect(friendship.status == .pending)
        #expect(friendship.respondedAt == nil)
        #expect(friendship.otherPartyID(for: me) == friendship.requesterID)
        #expect(friendship.otherParty(for: me)?.displayName == "Ada L.")
        #expect(friendship.otherParty(for: friendship.requesterID)?.username == "me")
        #expect(friendship.isIncomingRequest(for: me))
        #expect(!friendship.isOutgoingRequest(for: me))
        #expect(friendship.isOutgoingRequest(for: friendship.requesterID))

        var withOther = friendship
        withOther.requester = nil
        withOther.addressee = nil
        withOther.otherParty = Profile(id: friendship.requesterID, username: "ada")
        #expect(withOther.otherParty(for: me)?.username == "ada")
        let data = try QuotedJSON.makeEncoder().encode(withOther)
        #expect(try QuotedJSON.makeDecoder().decode(Friendship.self, from: data) == withOther)
    }

    @Test func embeddedProfilesWithoutIDUseTheForeignKey() throws {
        let share = try Fixture.decode(SharedQuote.self, """
        {"id":"0a6f1b9c-0000-4000-8000-000000000001","sender_id":"0a6f1b9c-0000-4000-8000-0000000000aa",
         "recipient_id":"0a6f1b9c-0000-4000-8000-0000000000bb","body":"x","created_at":"2026-10-19T03:26:38Z",
         "sender":{"username":"ada","display_name":"Ada"},"recipient":{"display_name":"no username"}}
        """)
        #expect(share.sender == Profile(id: share.senderID, username: "ada", displayName: "Ada"))
        #expect(share.recipient == nil) // malformed embed is dropped, the row still decodes
        #expect(share.format.isEmpty && share.note == nil && share.seenAt == nil)

        let friendship = try Fixture.decode(Friendship.self, """
        {"id":"0a6f1b9c-0000-4000-8000-000000000009","requester_id":"0a6f1b9c-0000-4000-8000-0000000000aa",
         "addressee_id":"0a6f1b9c-0000-4000-8000-0000000000bb","status":"accepted","created_at":"2026-10-19T03:26:38Z",
         "requester":{"username":"ada","display_name":""},"addressee":null,"other_party":{"username":"nobody"}}
        """)
        #expect(friendship.requester == Profile(id: friendship.requesterID, username: "ada"))
        #expect(friendship.addressee == nil)
        #expect(friendship.otherParty == nil) // other_party must carry its own id
        #expect(friendship.otherParty(for: friendship.addresseeID)?.username == "ada")
    }

    @Test func catalogOriginRoundTrips() throws {
        let json = #"{"id":"8f0c5b8e-3f5e-4c1a-9a51-0d8c1c7e2b11","body":"hi","origin":"catalog","created_at":"2026-10-19T03:26:38Z"}"#
        let quote = try Fixture.decode(Quote.self, json)
        #expect(quote.origin == .catalog)
        #expect(try Fixture.jsonObject(quote)["origin"] as? String == "catalog")
        #expect(try Fixture.decode(Quote.self, String(decoding: QuotedJSON.makeEncoder().encode(quote), as: UTF8.self)).origin == .catalog)
    }

    @Test func decodesCatalogQuote() throws {
        let quote = try Fixture.decode(CatalogQuote.self, #"""
        {"id":61,"body":"There is nothing either good or bad, but thinking makes it so.","body_format":[{"start":0,"length":99,"italic":true}],
         "author":"William Shakespeare","source":"Hamlet","source_location":"Act 2, Scene 2",
         "source_url":"https://www.gutenberg.org/ebooks/1524","speaker":"Hamlet","themes":["calm","wonder","self"],
         "is_starter":false,"sort_order":null,"status":"live"}
        """#)
        #expect(quote.id == 61)
        #expect(quote.speaker == "Hamlet")
        // Unknown themes are dropped; the first known one files it.
        #expect(quote.themes == [.calm, .selfhood])
        #expect(quote.primaryTheme == .calm)
        #expect(quote.isStarter == false)
        #expect(quote.sortOrder == nil)
        #expect(quote.status == .live)
        #expect(quote.libraryOrigin == .catalog)
        #expect(quote.format == [TextRun(start: 0, length: quote.body.utf16.count, italic: true)])
        #expect(quote.sourceURL?.host() == "www.gutenberg.org")
        #expect(quote.attribution == "William Shakespeare, Hamlet")
        let data = try QuotedJSON.makeEncoder().encode(quote)
        #expect(try QuotedJSON.makeDecoder().decode(CatalogQuote.self, from: data) == quote)
        #expect(QuoteDraft(catalog: quote) == QuoteDraft(body: quote.body, format: quote.format, author: "William Shakespeare", source: "Hamlet"))

        // Missing optional columns, an unknown status and a malformed theme list still decode.
        let sparse = try Fixture.decode(CatalogQuote.self, #"{"id":3,"body":"Know thyself.","themes":"courage","status":"archived","is_starter":true,"sort_order":3}"#)
        #expect(sparse.themes.isEmpty)
        #expect(sparse.status == .retired)
        #expect(sparse.isStarter)
        #expect(sparse.sortOrder == 3)
        #expect(sparse.libraryOrigin == .starter)
        #expect(sparse.speaker == nil)
    }

    @Test func catalogQuoteFromStarter() {
        let starter = StarterQuote(id: 7, body: "Know thyself.", author: "Socrates", sortOrder: 3, sourceLocation: "Apology", sourceURL: URL(string: "https://example.org"))
        let quote = CatalogQuote(starter: starter)
        #expect(quote.id == 7)
        #expect(quote.isStarter)
        #expect(quote.sortOrder == 3)
        #expect(quote.status == .live)
        #expect(quote.sourceLocation == "Apology")
        #expect(quote.sourceURL == starter.sourceURL)
        #expect(quote.libraryOrigin == .starter)
        // A non-starter never keeps an onboarding position.
        #expect(CatalogQuote(id: 70, body: "x", sortOrder: 5).sortOrder == nil)
    }

    @Test func catalogSectionsFileEachQuoteUnderItsFirstTheme() {
        let quotes = [
            CatalogQuote(id: 1, body: "a", themes: [.selfhood, .courage]),
            CatalogQuote(id: 2, body: "b", themes: [.courage]),
            CatalogQuote(id: 3, body: "c", themes: []),
            CatalogQuote(id: 4, body: "d", themes: [.time, .purpose]),
            CatalogQuote(id: 5, body: "e", themes: [.courage, .calm]),
        ]
        let sections = CatalogQuote.sections(quotes)
        #expect(sections.map(\.theme) == [.courage, .time, .selfhood, nil])
        #expect(sections.map { $0.quotes.map(\.id) } == [[2, 5], [4], [1], [3]])
        #expect(sections.map(\.title) == ["Courage", "Time", "Self", "More"])
        #expect(Set(sections.map(\.id)).count == sections.count)
        #expect(CatalogQuote.sections([]).isEmpty)
    }

    @Test func decodesProfileAndStarter() throws {
        let profile = try Fixture.decode(Profile.self, #"{"id":"0a6f1b9c-0000-4000-8000-0000000000aa","username":"ada","display_name":"Ada Lovelace","created_at":"2026-10-19T03:26:38Z"}"#)
        #expect(profile.displayName == "Ada Lovelace")
        #expect(profile.handle == "@ada")
        #expect(try Fixture.jsonObject(profile)["display_name"] as? String == "Ada Lovelace")

        let starter = try Fixture.decode(StarterQuote.self, #"{"id":7,"body":"Know thyself.","body_format":[],"author":"Socrates","source":null,"sort_order":3}"#)
        #expect(starter.id == 7)
        #expect(starter.sortOrder == 3)
        #expect(starter.attribution == "Socrates")
        let data = try QuotedJSON.makeEncoder().encode(starter)
        #expect(try QuotedJSON.makeDecoder().decode(StarterQuote.self, from: data) == starter)
    }

    @Test func textRunOmitsFalseFlags() throws {
        #expect(try Fixture.jsonString(TextRun(start: 0, length: 3, bold: true)) == #"{"bold":true,"length":3,"start":0}"#)
        #expect(try Fixture.jsonString(TextRun(start: 2, length: 1, bold: true, italic: true, underline: true))
            == #"{"bold":true,"italic":true,"length":1,"start":2,"underline":true}"#)
        let decoded = try Fixture.decode(TextRun.self, #"{"start":1,"length":2}"#)
        #expect(decoded == TextRun(start: 1, length: 2))
        #expect(decoded.flags.isEmpty)
        #expect(try Fixture.decode(TextRun.self, #"{"start":1,"length":2,"italic":true,"bold":false}"#).flags == .italic)
    }
}
