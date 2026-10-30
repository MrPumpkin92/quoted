import Foundation

/// `reports.reason`.
public enum ReportReason: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case spam
    case harassment
    case inappropriate
    case copyright
    /// Quoted Catalog quotes only: the wording doesn't match the source.
    case wrongWording = "wrong_wording"
    case other

    public var id: String { rawValue }

    /// The reasons offered for a person's content or profile, in menu order.
    public static let personReasons: [ReportReason] = [.spam, .harassment, .inappropriate, .copyright, .other]

    /// The confirmation dialog's button.
    public var title: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment"
        case .inappropriate: "Inappropriate"
        case .copyright: "Copyright"
        case .wrongWording: "Wrong Wording"
        case .other: "Other"
        }
    }
}

/// What a report is about. Each names the person it is about (author, sender or owner); a catalog
/// quote names nobody. The server copies the content itself, so nothing else travels.
public enum ReportTarget: Hashable, Sendable {
    /// A person, with no specific item ("Report @bob…").
    case profile(userID: UUID)
    /// A post and its poster.
    case post(id: UUID, posterID: UUID)
    /// A message and its sender.
    case message(id: UUID, senderID: UUID)
    /// A playlist and its owner.
    case playlist(id: UUID, ownerID: UUID)
    /// A Quoted Catalog quote ("Report Wrong Wording…").
    case catalogQuote(Int)

    /// The person the report is about; nil for a catalog quote.
    public var reportedUserID: UUID? {
        switch self {
        case .profile(let id): id
        case .post(_, let id): id
        case .message(_, let id): id
        case .playlist(_, let id): id
        case .catalogQuote: nil
        }
    }

    /// The `reports.target_kind` the server will record.
    public var kind: String {
        switch self {
        case .profile: "profile"
        case .post: "post"
        case .message: "message"
        case .playlist: "playlist"
        case .catalogQuote: "catalog_quote"
        }
    }
}

/// What the app showed, sent with a profile report when the reported item is already gone (unsent
/// or deleted), so the report still says what the reporter saw. The server keeps it as unverified;
/// for an item that still exists it takes its own copy instead.
public struct ReportContent: Hashable, Sendable {
    public var body: String?
    public var author: String?
    public var source: String?
    /// The caption, the message's text or note, or the playlist's title.
    public var note: String?

    public init(body: String? = nil, author: String? = nil, source: String? = nil, note: String? = nil) {
        self.body = body
        self.author = author
        self.source = source
        self.note = note
    }

    /// A post as the reporter saw it.
    public init(post: Post) {
        self.init(body: post.quote.body, author: post.quote.author, source: post.quote.source, note: post.caption)
    }

    /// A message as the reporter saw it.
    public init(message: Message) {
        self.init(
            body: message.quote?.body, author: message.quote?.author, source: message.quote?.source,
            note: message.text ?? message.note ?? message.playlistTitle
        )
    }
}
