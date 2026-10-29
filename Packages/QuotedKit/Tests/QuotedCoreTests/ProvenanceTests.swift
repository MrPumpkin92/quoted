import Foundation
import Testing
@testable import QuotedCore

/// The provenance model and every string in docs/ui-spec.md, Shared components → Provenance.
@Suite("Provenance")
struct ProvenanceTests {
    static let checked = Provenance.catalog(12)
    static let mine = Provenance(creatorUsername: "hwei")
    static let mineEdited = Provenance(creatorUsername: "hwei", editedFromUsername: "bob")
    static let alices = Provenance(creatorUsername: "alice")
    static let alicesFromMe = Provenance(creatorUsername: "alice", editedFromUsername: "hwei")
    static let unknown = Provenance()

    // MARK: who(viewer:perspective:)

    @Test func whoFromTheViewer() {
        #expect(Self.checked.who(viewer: "hwei") == .catalog)
        #expect(Self.mine.who(viewer: "hwei") == .you)
        #expect(Self.mine.who(viewer: "@HWei") == .you, "the viewer is normalized like a username")
        #expect(Self.alices.who(viewer: "hwei") == .person("alice"))
        #expect(Self.unknown.who(viewer: "hwei") == .unknown)
        // Before a username exists nothing reads as yours.
        #expect(Self.mine.who(viewer: nil) == .person("hwei"))
        // A checked quote never names a person, whatever the row says.
        #expect(Provenance(catalogID: 3, creatorUsername: "alice").who(viewer: "alice") == .catalog)
    }

    @Test func whoAsFriendsSeeIt() {
        #expect(Self.mine.who(viewer: "hwei", perspective: .friends) == .person("hwei"))
        #expect(Self.alices.who(viewer: "hwei", perspective: .friends) == .person("alice"))
        #expect(Self.checked.who(viewer: "hwei", perspective: .friends) == .catalog)
        #expect(Self.mineEdited.editedFrom(viewer: "hwei", perspective: .friends) == .person("bob"))
    }

    @Test func whoOutsideQuoted() {
        // The share image: your own "@yourname", everyone else "a person", no "edited from".
        #expect(Self.mine.who(viewer: "hwei", perspective: .outsideQuoted) == .person("hwei"))
        #expect(Self.mineEdited.who(viewer: "hwei", perspective: .outsideQuoted) == .person("hwei"))
        #expect(Self.alices.who(viewer: "hwei", perspective: .outsideQuoted) == .unknown)
        #expect(Self.checked.who(viewer: "hwei", perspective: .outsideQuoted) == .catalog)
        #expect(Self.mineEdited.editedFrom(viewer: "hwei", perspective: .outsideQuoted) == nil)
    }

    @Test func editedFrom() {
        #expect(Self.mineEdited.editedFrom(viewer: "hwei") == .person("bob"))
        #expect(Self.alicesFromMe.editedFrom(viewer: "hwei") == .you)
        #expect(Self.mine.editedFrom(viewer: "hwei") == nil)
        #expect(Provenance(catalogID: 1, editedFromUsername: "bob").editedFrom(viewer: "hwei") == nil, "never on a checked quote")
    }

    @Test func publicEligibility() {
        #expect(Self.checked.isPublicEligible(viewer: "hwei"))
        #expect(Self.mine.isPublicEligible(viewer: "hwei"))
        #expect(!Self.mineEdited.isPublicEligible(viewer: "hwei"), "edited from someone else")
        #expect(!Self.alices.isPublicEligible(viewer: "hwei"))
        #expect(!Self.unknown.isPublicEligible(viewer: "hwei"))
        #expect(!Self.mine.isPublicEligible(viewer: nil))
    }

    @Test func decodesTheServerColumnsAndRoundTrips() throws {
        let decoded = try Fixture.decode(Provenance.self, #"{"verified_starter_id":null,"creator_username":"alice","edited_from_username":null}"#)
        #expect(decoded == Self.alices)
        #expect(try Fixture.decode(Provenance.self, "{}") == Self.unknown)
        let object = try Fixture.jsonObject(Self.mineEdited)
        #expect(Set(object.keys) == ["verified_starter_id", "creator_username", "edited_from_username"])
        #expect(try Fixture.decode(Provenance.self, Fixture.jsonString(Self.mineEdited)) == Self.mineEdited)
    }

    // MARK: Copy

    @Test func rowCardAndVoiceOverLines() {
        let cases: [(Provenance.Who, row: String, card: String, voiceOver: String)] = [
            (.catalog, "Quoted Catalog", "Quoted Catalog · Checked", "Quoted Catalog, checked word for word"),
            (.you, "Added by you", "Added by you · Not checked", "Added by you, not checked"),
            (.person("alice"), "Added by @alice", "Added by @alice · Not checked", "Added by alice, not checked"),
            (.unknown, "Added by a person", "Added by a person · Not checked", "Added by a person, not checked"),
        ]
        for (who, row, card, voiceOver) in cases {
            #expect(ProvenanceCopy.rowLine(who) == row)
            #expect(ProvenanceCopy.cardLine(who) == card)
            #expect(ProvenanceCopy.accessibilityLine(who) == voiceOver)
            #expect(!ProvenanceCopy.rowLine(who).contains("Not checked"), "row lines never say Not checked")
            #expect(!ProvenanceCopy.accessibilityLine(who).contains("@"), "VoiceOver never speaks the @")
        }
    }

    @Test func blockLines() {
        #expect(ProvenanceCopy.editedFrom(.person("bob")) == "Edited from @bob")
        #expect(ProvenanceCopy.editedFrom(.you) == "Edited from you")
        #expect(ProvenanceCopy.blockTitle(.person("alice"), editedFrom: .person("bob")) == "Added by @alice · Edited from @bob")
        #expect(ProvenanceCopy.blockTitle(.you, editedFrom: nil) == "Added by you")
        #expect(ProvenanceCopy.blockTitle(.catalog, editedFrom: nil) == "Quoted Catalog")
    }

    @Test func statusLines() {
        #expect(ProvenanceCopy.statusLine(checked: false) == "Not checked against a source")
        #expect(ProvenanceCopy.statusLine(checked: true, work: "Meditations", location: "Book 4")
            == "Checked word for word against Meditations, Book 4")
        #expect(ProvenanceCopy.statusLine(checked: true, work: "Frankenstein", location: "1831 edition, Chapter 20")
            == "Checked word for word against Frankenstein, 1831 edition, Chapter 20")
        // The location already names the work: it stands alone.
        #expect(ProvenanceCopy.statusLine(checked: true, work: "Self-Reliance", location: "Self-Reliance, paragraph 3")
            == "Checked word for word against Self-Reliance, paragraph 3")
        #expect(ProvenanceCopy.statusLine(checked: true, work: "Walden", location: "  ")
            == "Checked word for word against Walden")
        #expect(ProvenanceCopy.statusLine(checked: true, work: nil, location: "Stanza 1") == "Checked word for word against Stanza 1")
        #expect(ProvenanceCopy.statusLine(checked: true) == "Checked word for word")
        let starter = StarterQuote(id: 4, body: "Waste no more time", author: "Marcus Aurelius", source: "Meditations", sourceLocation: "Book 10")
        #expect(starter.statusLine == "Checked word for word against Meditations, Book 10")
    }

    @Test func blockVoiceOver() {
        #expect(ProvenanceCopy.blockAccessibilityLabel(.person("alice"), editedFrom: .person("bob"))
            == "Added by alice, edited from bob, not checked against a source")
        #expect(ProvenanceCopy.blockAccessibilityLabel(.you, editedFrom: nil) == "Added by you, not checked against a source")
        #expect(ProvenanceCopy.blockAccessibilityLabel(.unknown, editedFrom: .you)
            == "Added by a person, edited from you, not checked against a source")
        #expect(ProvenanceCopy.blockAccessibilityLabel(.catalog, editedFrom: nil, work: "Frankenstein", location: "1831 edition, Chapter 20")
            == "Quoted Catalog, checked word for word against Frankenstein, 1831 edition, Chapter 20")
    }

    @Test func sheetCopy() {
        #expect(ProvenanceCopy.sheetTitle == "About This Quote")
        #expect(ProvenanceCopy.actionHint == "Shows who added it and how it was checked.")
        #expect(ProvenanceCopy.checkedExplanation
            == "Quoted checked this quote word for word against a public-domain edition of the work, and its author against the same edition.")
        #expect(ProvenanceCopy.uncheckedExplanation == "Quoted hasn't checked this wording against a source.")
        #expect(ProvenanceCopy.personValue(.person("alice"), viewer: "hwei") == "@alice")
        #expect(ProvenanceCopy.personValue(.you, viewer: "hwei") == "You (@hwei)")
        #expect(ProvenanceCopy.personValue(.unknown, viewer: "hwei") == "A person")
        #expect(ProvenanceCopy.peopleFootnote(.you) == "Your username stays with this quote when you send or post it.")
        #expect(ProvenanceCopy.peopleFootnote(.unknown) == "Quoted doesn't know which account added it.")
        #expect(ProvenanceCopy.peopleFootnote(.person("alice")) == nil)
        #expect(ProvenanceCopy.checkedInLibraryNote == "Change the wording, author or source and the seal comes off.")
        #expect(ProvenanceCopy.viewProfile("Alice") == "View @alice's Profile")
    }

    @Test func readItLinks() throws {
        let gutenberg = try #require(URL(string: "https://www.gutenberg.org/ebooks/2944"))
        let wikisource = try #require(URL(string: "https://en.wikisource.org/wiki/Hope"))
        #expect(ProvenanceCopy.readIt(gutenberg) == "Read it on Project Gutenberg")
        #expect(ProvenanceCopy.readItMenuItem(gutenberg) == "Read It on Project Gutenberg")
        #expect(ProvenanceCopy.readIt(wikisource) == "Read it on Wikisource")
        #expect(ProvenanceCopy.readIt(try #require(URL(string: "https://example.com/x"))) == nil)
    }

    @Test func copyThatTravels() {
        #expect(ProvenanceCopy.savedToast(.person("alice")) == "Saved to your library · Added by @alice")
        #expect(ProvenanceCopy.savedToast(.catalog) == "Saved to your library")
        #expect(ProvenanceCopy.savedToast(.unknown) == "Saved to your library")
        #expect(ProvenanceCopy.savedToast(.you) == "Saved to your library")
        #expect(ProvenanceCopy.addToReminders == "Add to Reminders")
        #expect(ProvenanceCopy.addedToReminders == "Added to your reminders")

        #expect(ProvenanceCopy.sendFootnote(.you) == "Your username stays with this quote.")
        #expect(ProvenanceCopy.sendFootnote(.person("alice")) == "Added by @alice stays with this quote.")
        #expect(ProvenanceCopy.sendFootnote(.person("alice"), savesCopy: true)
            == "Added by @alice stays with this quote. Sending also saves it to your library.")
        #expect(ProvenanceCopy.sendFootnote(.catalog) == nil)
        #expect(ProvenanceCopy.sendFootnote(.unknown) == nil)
        #expect(ProvenanceCopy.playlistSendFootnote == "Each quote keeps who added it.")

        #expect(ProvenanceCopy.composerFootnote(.person("alice"))
            == "Your username shows on the post. Added by @alice stays with this quote.")
        #expect(ProvenanceCopy.composerFootnote(.you) == "Your username shows on the post. Your username stays with this quote.")
        #expect(ProvenanceCopy.composerFootnote(.catalog) == "Your username shows on the post.")
    }

    @Test func editNotes() {
        #expect(ProvenanceCopy.editNote(Self.alices, viewer: "hwei")
            == "Changing the words makes this your version. @alice stays as edited from.")
        #expect(ProvenanceCopy.editNote(Self.unknown, viewer: "hwei") == "Changing the words makes this your version.")
        #expect(ProvenanceCopy.editNote(Self.checked, viewer: "hwei")
            == "Changing the words makes this your version, and the seal comes off.")
        #expect(ProvenanceCopy.editNote(Self.mine, viewer: "hwei") == nil)
        #expect(ProvenanceCopy.editNote(Self.mineEdited, viewer: "hwei") == nil)
    }

    @Test func everyQuoteKindCarriesItsProvenance() {
        let created = Date(timeIntervalSince1970: 0)
        let quote = Quote(body: "Q", verifiedStarterID: nil, creatorUsername: "alice", editedFromUsername: "bob")
        #expect(quote.provenance == Provenance(creatorUsername: "alice", editedFromUsername: "bob"))
        let favorite = FriendFavorite(id: Fixture.id(1), body: "F", verifiedStarterID: 9)
        #expect(favorite.provenance == .catalog(9))
        let item = PlaylistItem(id: Fixture.id(2), body: "I", creatorUsername: "maya")
        #expect(item.provenance.who(viewer: "maya") == .you)
        let post = Post(id: Fixture.id(3), posterID: Fixture.id(4), quote: QuoteSnapshot(body: "P", creatorUsername: "bob"), createdAt: created)
        #expect(post.provenance.who(viewer: "hwei") == .person("bob"))
        let text = Message(id: Fixture.id(5), conversationID: Fixture.id(6), senderID: Fixture.id(4), kind: .text, text: "hi", createdAt: created)
        #expect(text.provenance == nil)
    }
}
