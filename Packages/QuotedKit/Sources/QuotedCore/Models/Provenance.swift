import Foundation

/// Who brought a quote's wording into Quoted, and whether Quoted checked it ("Added by" and the seal).
///
/// The server owns every part of it: `verified_starter_id` and the `creator_username` and
/// `edited_from_username` columns on quotes, posts and messages, and the same fields in
/// `friend_favorites`, `playlist_view` and `profile_view` (where the usernames are null for checked
/// quotes). The client only shows it; ``ProvenanceCopy`` holds every string.
public struct Provenance: Hashable, Sendable, Codable {
    /// The Quoted Catalog quote (`starter_quotes.id`) this wording matches exactly. Non-nil means
    /// checked word for word.
    public var catalogID: Int?
    /// The username of the account that brought this wording into Quoted, or nil when unknown or
    /// deleted ("Added by a person"). Always ignored for a checked quote.
    public var creatorUsername: String?
    /// The previous creator, when the creator changed someone else's wording ("Edited from @bob").
    public var editedFromUsername: String?

    public init(catalogID: Int? = nil, creatorUsername: String? = nil, editedFromUsername: String? = nil) {
        self.catalogID = catalogID
        self.creatorUsername = Self.clean(creatorUsername)
        self.editedFromUsername = Self.clean(editedFromUsername)
    }

    /// A Quoted Catalog quote: checked, with no creator.
    public static func catalog(_ id: Int) -> Provenance { Provenance(catalogID: id) }

    /// Whether Quoted checked the wording against a public-domain edition (the filled seal).
    public var isChecked: Bool { catalogID != nil }

    /// Who a provenance line names.
    public enum Who: Hashable, Sendable {
        /// A Quoted Catalog quote: "Quoted Catalog".
        case catalog
        /// The viewer: "Added by you".
        case you
        /// Someone, by username without the "@": "Added by @alice".
        case person(String)
        /// Unknown or deleted: "Added by a person".
        case unknown
    }

    /// Whose eyes a line is written for.
    public enum Perspective: Hashable, Sendable {
        /// The signed-in person: their own quotes read "Added by you".
        case viewer
        /// Friends (Profile's "How your quotes appear"): your own quotes read "@yourname".
        case friends
        /// Outside Quoted (the share image): your own read "@yourname", everyone else "a person", and
        /// there is no "edited from".
        case outsideQuoted
    }

    /// Who the line names for `viewer` (the signed-in username, or nil) from `perspective`.
    public func who(viewer: String?, perspective: Perspective = .viewer) -> Who {
        if isChecked { return .catalog }
        guard let creator = creatorUsername else { return .unknown }
        let isViewer = Self.same(creator, viewer)
        switch perspective {
        case .viewer: return isViewer ? .you : .person(creator)
        case .friends: return .person(creator)
        case .outsideQuoted: return isViewer ? .person(creator) : .unknown
        }
    }

    /// Who the wording was edited from, or nil when it wasn't, when it's checked, or outside Quoted.
    public func editedFrom(viewer: String?, perspective: Perspective = .viewer) -> Who? {
        guard !isChecked, let editor = editedFromUsername else { return nil }
        switch perspective {
        case .viewer: return Self.same(editor, viewer) ? .you : .person(editor)
        case .friends: return .person(editor)
        case .outsideQuoted: return nil
        }
    }

    /// Whether `viewer` may show this quote publicly ("Anyone with your username"): a checked quote,
    /// or one the viewer added with no "edited from". The server applies the same rule by account id.
    public func isPublicEligible(viewer: String?) -> Bool {
        if isChecked { return true }
        guard let creatorUsername else { return false }
        return Self.same(creatorUsername, viewer) && editedFromUsername == nil
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case catalogID = "verified_starter_id"
        case creatorUsername = "creator_username"
        case editedFromUsername = "edited_from_username"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            catalogID: try container.decodeIfPresent(Int.self, forKey: .catalogID),
            creatorUsername: try container.decodeIfPresent(String.self, forKey: .creatorUsername),
            editedFromUsername: try container.decodeIfPresent(String.self, forKey: .editedFromUsername)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(catalogID, forKey: .catalogID)
        try container.encode(creatorUsername, forKey: .creatorUsername)
        try container.encode(editedFromUsername, forKey: .editedFromUsername)
    }

    // MARK: Private

    private static func clean(_ username: String?) -> String? {
        guard let username else { return nil }
        let normalized = Username.normalize(username)
        return normalized.isEmpty ? nil : normalized
    }

    private static func same(_ username: String, _ viewer: String?) -> Bool {
        guard let viewer else { return false }
        return Username.normalize(viewer) == username
    }
}

/// Every provenance string the app shows, so `swift test` pins the exact copy (docs/ui-spec.md,
/// Shared components → Provenance). VoiceOver strings never speak the "@".
public enum ProvenanceCopy {
    // MARK: Lines

    /// The row line (your Library, Search's Your Library, the pickers). It never says "Not checked":
    /// the hollow glyph and the VoiceOver words carry it.
    public static func rowLine(_ who: Provenance.Who) -> String {
        switch who {
        case .catalog: "Quoted Catalog"
        case .you: "Added by you"
        case .person(let username): "Added by @\(username)"
        case .unknown: "Added by a person"
        }
    }

    /// The card line (other people's content): the row line plus "· Checked" or "· Not checked".
    public static func cardLine(_ who: Provenance.Who) -> String {
        switch who {
        case .catalog: "Quoted Catalog · Checked"
        default: "\(rowLine(who)) · Not checked"
        }
    }

    /// What VoiceOver reads for a row or card line.
    public static func accessibilityLine(_ who: Provenance.Who) -> String {
        switch who {
        case .catalog: "Quoted Catalog, checked word for word"
        case .you: "Added by you, not checked"
        case .person(let username): "Added by \(username), not checked"
        case .unknown: "Added by a person, not checked"
        }
    }

    /// "Edited from @bob", or "Edited from you" when the earlier version was yours.
    public static func editedFrom(_ who: Provenance.Who) -> String {
        switch who {
        case .you: "Edited from you"
        case .person(let username): "Edited from @\(username)"
        case .catalog, .unknown: "Edited from a person"
        }
    }

    // MARK: Provenance block (single-quote screens)

    /// Line 1 of the block: the row line, plus " · Edited from @bob" when set.
    public static func blockTitle(_ who: Provenance.Who, editedFrom: Provenance.Who?) -> String {
        guard let editedFrom else { return rowLine(who) }
        return "\(rowLine(who)) · \(Self.editedFrom(editedFrom))"
    }

    /// Line 2 of the block. Checked: "Checked word for word against <work>, <location>" from the
    /// catalog's `source` and `source_location` (the location alone when it already names the work).
    /// Unchecked: "Not checked against a source".
    public static func statusLine(checked: Bool, work: String? = nil, location: String? = nil) -> String {
        guard checked else { return uncheckedStatus }
        let work = nonBlank(work)
        let location = nonBlank(location)
        switch (work, location) {
        case let (work?, location?):
            if location.range(of: work, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return "Checked word for word against \(location)"
            }
            return "Checked word for word against \(work), \(location)"
        case let (work?, nil): return "Checked word for word against \(work)"
        case let (nil, location?): return "Checked word for word against \(location)"
        case (nil, nil): return "Checked word for word"
        }
    }

    /// The unchecked status line.
    public static let uncheckedStatus = "Not checked against a source"

    /// The block as one VoiceOver button: "Added by alice, edited from bob, not checked against a
    /// source", or "Quoted Catalog, checked word for word against Frankenstein, 1831 edition, Chapter 20".
    public static func blockAccessibilityLabel(
        _ who: Provenance.Who,
        editedFrom: Provenance.Who?,
        work: String? = nil,
        location: String? = nil
    ) -> String {
        if who == .catalog {
            return "Quoted Catalog, \(lowercasingFirst(statusLine(checked: true, work: work, location: location)))"
        }
        var parts = [accessibilityName(who)]
        if let editedFrom {
            parts.append("edited from \(spokenName(editedFrom))")
        }
        parts.append(lowercasingFirst(uncheckedStatus))
        return parts.joined(separator: ", ")
    }

    /// The hint on a provenance line or block that opens the Provenance sheet.
    public static let actionHint = "Shows who added it and how it was checked."

    // MARK: Provenance sheet

    /// The sheet's inline title, and the menu item that opens it.
    public static let sheetTitle = "About This Quote"
    /// The status under the header, checked.
    public static let checkedExplanation = "Quoted checked this quote word for word against a public-domain edition of the work, and its author against the same edition."
    /// The status under the header, unchecked.
    public static let uncheckedExplanation = "Quoted hasn't checked this wording against a source."
    /// The people card's row labels.
    public static let addedByLabel = "Added by"
    public static let editedFromLabel = "Edited from"

    /// A people-card value: "@alice", "You (@hwei)" (or "You" with no username yet) or "A person".
    public static func personValue(_ who: Provenance.Who, viewer: String?) -> String {
        switch who {
        case .you:
            guard let viewer, !viewer.isEmpty else { return "You" }
            return "You (@\(Username.normalize(viewer)))"
        case .person(let username): return "@\(username)"
        case .catalog, .unknown: return "A person"
        }
    }

    /// The people card's footnote: yours, or an unknown creator; nil otherwise.
    public static func peopleFootnote(_ who: Provenance.Who) -> String? {
        switch who {
        case .you: "Your username stays with this quote when you send or post it."
        case .unknown: "Quoted doesn't know which account added it."
        case .catalog, .person: nil
        }
    }

    /// Under the source card of a checked quote that is in your Library.
    public static let checkedInLibraryNote = "Change the wording, author or source and the seal comes off."

    /// "View @alice's Profile".
    public static func viewProfile(_ username: String) -> String { "View @\(Username.normalize(username))'s Profile" }

    /// The public-domain site a checked quote links to ("Project Gutenberg", "Wikisource"), or nil.
    public static func siteName(for url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        if host == "gutenberg.org" || host.hasSuffix(".gutenberg.org") { return "Project Gutenberg" }
        if host == "wikisource.org" || host.hasSuffix(".wikisource.org") { return "Wikisource" }
        return nil
    }

    /// The source card's button, sentence case: "Read it on Project Gutenberg". Nil for other sites.
    public static func readIt(_ url: URL) -> String? { siteName(for: url).map { "Read it on \($0)" } }

    /// The menu item, Title Case: "Read It on Project Gutenberg". Nil for other sites.
    public static func readItMenuItem(_ url: URL) -> String? { siteName(for: url).map { "Read It on \($0)" } }

    // MARK: Copy that travels with a quote

    /// The toast after saving someone else's quote: "Saved to your library · Added by @alice" for
    /// another person's unchecked quote, else "Saved to your library". Pair it with ``addToReminders``.
    public static func savedToast(_ who: Provenance.Who) -> String {
        if case .person(let username) = who {
            return "Saved to your library · Added by @\(username)"
        }
        return "Saved to your library"
    }

    /// The save toast's action.
    public static let addToReminders = "Add to Reminders"
    /// The toast after ``addToReminders``.
    public static let addedToReminders = "Added to your reminders"

    /// The Send sheet's footnote: your own quote "Your username stays with this quote."; someone
    /// else's "Added by @alice stays with this quote.", plus " Sending also saves it to your library."
    /// when Send makes a copy first; a catalog or unknown quote, none.
    public static func sendFootnote(_ who: Provenance.Who, savesCopy: Bool = false) -> String? {
        switch who {
        case .you:
            return "Your username stays with this quote."
        case .person(let username):
            let line = "Added by @\(username) stays with this quote."
            return savesCopy ? "\(line) Sending also saves it to your library." : line
        case .catalog, .unknown:
            return nil
        }
    }

    /// The Send sheet's footnote for a playlist.
    public static let playlistSendFootnote = "Each quote keeps who added it."

    /// The post composer's footnote: "Your username shows on the post." then the send footnote.
    public static func composerFootnote(_ who: Provenance.Who) -> String {
        let first = "Your username shows on the post."
        guard let send = sendFootnote(who) else { return first }
        return "\(first) \(send)"
    }

    /// The note under the editor when editing: another person's quote, an unknown creator or a checked
    /// quote get one; your own quote (with or without "edited from") gets none.
    public static func editNote(_ provenance: Provenance, viewer: String?) -> String? {
        switch provenance.who(viewer: viewer) {
        case .catalog: "Changing the words makes this your version, and the seal comes off."
        case .you: nil
        case .person(let username): "Changing the words makes this your version. @\(username) stays as edited from."
        case .unknown: "Changing the words makes this your version."
        }
    }

    // MARK: Private

    private static func accessibilityName(_ who: Provenance.Who) -> String {
        switch who {
        case .catalog: "Quoted Catalog"
        case .you: "Added by you"
        case .person(let username): "Added by \(username)"
        case .unknown: "Added by a person"
        }
    }

    private static func spokenName(_ who: Provenance.Who) -> String {
        switch who {
        case .you: "you"
        case .person(let username): username
        case .catalog, .unknown: "a person"
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
