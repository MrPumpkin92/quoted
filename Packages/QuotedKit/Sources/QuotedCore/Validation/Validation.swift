import Foundation

/// Database limits mirrored on the client. Lengths count Unicode scalars, like Postgres `char_length`.
public enum Limits {
    public static let usernameLength = 3...20
    public static let displayNameLength = 1...50
    public static let bodyLength = 1...2000
    public static let authorMaxLength = 200
    public static let sourceMaxLength = 200
    public static let noteMaxLength = 280
    public static let reportDetailsMaxLength = 500
    public static let formatRunsMax = RichText.maxRuns
    /// Quotes one account can keep; the server enforces it (`QR002`).
    public static let quotesPerAccount = 5000

    /// The length Postgres `char_length` reports for `text`.
    public static func length(of text: String) -> Int { text.unicodeScalars.count }
}

// MARK: Username

/// Why a username was rejected.
public enum UsernameError: Error, Hashable, Sendable, LocalizedError {
    case empty
    case tooShort(minimum: Int)
    case tooLong(maximum: Int)
    case invalidCharacters

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Choose a username."
        case .tooShort(let minimum):
            "Usernames need at least \(minimum) characters."
        case .tooLong(let maximum):
            "Usernames can be at most \(maximum) characters."
        case .invalidCharacters:
            "Use only letters a–z, numbers, underscores and periods."
        }
    }
}

/// Username rules, matching the `profiles.username` check `^[a-z0-9_.]{3,20}$`.
public enum Username {
    /// Trims whitespace, drops one leading "@" and lowercases.
    public static func normalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@") { text.removeFirst() }
        return text.lowercased()
    }

    /// Returns the normalized username, or throws a friendly error.
    public static func validate(_ input: String) throws(UsernameError) -> String {
        let name = normalize(input)
        guard !name.isEmpty else { throw .empty }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "."
        }
        guard allowed else { throw .invalidCharacters }
        let length = name.unicodeScalars.count
        guard length >= Limits.usernameLength.lowerBound else { throw .tooShort(minimum: Limits.usernameLength.lowerBound) }
        guard length <= Limits.usernameLength.upperBound else { throw .tooLong(maximum: Limits.usernameLength.upperBound) }
        return name
    }

    /// Whether `input` normalizes to a valid username.
    public static func isValid(_ input: String) -> Bool {
        (try? validate(input)) != nil
    }
}

// MARK: Display name

/// Why a display name was rejected.
public enum DisplayNameError: Error, Hashable, Sendable, LocalizedError {
    case empty
    case tooLong(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a name."
        case .tooLong(let maximum): "Names can be at most \(maximum) characters."
        }
    }
}

/// Display name rules, matching `profiles.display_name` (1–50 characters).
public enum DisplayName {
    /// Returns the trimmed name, or throws a friendly error.
    public static func validate(_ input: String) throws(DisplayNameError) -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .empty }
        guard Limits.length(of: name) <= Limits.displayNameLength.upperBound else {
            throw .tooLong(maximum: Limits.displayNameLength.upperBound)
        }
        return name
    }
}

// MARK: Quote draft

/// Why a quote draft or share note was rejected.
public enum QuoteDraftError: Error, Hashable, Sendable, LocalizedError {
    case emptyBody
    case bodyTooLong(maximum: Int)
    case authorTooLong(maximum: Int)
    case sourceTooLong(maximum: Int)
    case noteTooLong(maximum: Int)
    case tooMuchFormatting(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyBody: "Write the quote first."
        case .bodyTooLong(let maximum): "Quotes can be at most \(maximum) characters."
        case .authorTooLong(let maximum): "The author can be at most \(maximum) characters."
        case .sourceTooLong(let maximum): "The source can be at most \(maximum) characters."
        case .noteTooLong(let maximum): "Notes can be at most \(maximum) characters."
        case .tooMuchFormatting(let maximum): "This quote has too many styled pieces (at most \(maximum))."
        }
    }
}

/// The editable fields of a quote, validated on the client before insert or update.
public struct QuoteDraft: Hashable, Sendable, RichTextContent {
    public var body: String
    public var format: [TextRun]
    public var author: String
    public var source: String

    public init(body: String = "", format: [TextRun] = [], author: String = "", source: String = "") {
        self.body = body
        self.format = format
        self.author = author
        self.source = source
    }

    /// A draft for editing an existing quote.
    public init(quote: Quote) {
        self.init(body: quote.body, format: quote.format, author: quote.author ?? "", source: quote.source ?? "")
    }

    /// A draft for saving a received share into the library.
    public init(shared: SharedQuote) {
        self.init(body: shared.body, format: shared.format, author: shared.author ?? "", source: shared.source ?? "")
    }

    /// A draft for copying a starter quote into the library.
    public init(starter: StarterQuote) {
        self.init(body: starter.body, format: starter.format, author: starter.author ?? "", source: starter.source ?? "")
    }

    /// The cleaned values to store: body trimmed (runs shifted to match and normalized), author and
    /// source trimmed with blanks as nil.
    public struct Validated: Hashable, Sendable, RichTextContent {
        public let body: String
        public let format: [TextRun]
        public let author: String?
        public let source: String?
    }

    /// Trims and checks every field: body 1–2000 characters and not only whitespace, author and source
    /// up to 200, at most 200 style runs.
    public func validated() throws(QuoteDraftError) -> Validated {
        let (trimmedBody, shiftedRuns) = Self.trim(body, runs: format)
        guard !trimmedBody.isEmpty else { throw .emptyBody }
        guard Limits.length(of: trimmedBody) <= Limits.bodyLength.upperBound else {
            throw .bodyTooLong(maximum: Limits.bodyLength.upperBound)
        }
        let cleanAuthor = Self.optional(author)
        if let cleanAuthor, Limits.length(of: cleanAuthor) > Limits.authorMaxLength {
            throw .authorTooLong(maximum: Limits.authorMaxLength)
        }
        let cleanSource = Self.optional(source)
        if let cleanSource, Limits.length(of: cleanSource) > Limits.sourceMaxLength {
            throw .sourceTooLong(maximum: Limits.sourceMaxLength)
        }
        guard shiftedRuns.count <= Limits.formatRunsMax else {
            throw .tooMuchFormatting(maximum: Limits.formatRunsMax)
        }
        return Validated(body: trimmedBody, format: shiftedRuns, author: cleanAuthor, source: cleanSource)
    }

    /// Whether ``validated()`` would succeed.
    public var isValid: Bool { (try? validated()) != nil }

    /// Validates an optional share note: trimmed, up to 280 characters, blank becomes nil.
    public static func validatedNote(_ note: String) throws(QuoteDraftError) -> String? {
        guard let clean = optional(note) else { return nil }
        guard Limits.length(of: clean) <= Limits.noteMaxLength else { throw .noteTooLong(maximum: Limits.noteMaxLength) }
        return clean
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trims leading and trailing whitespace and shifts the runs by the removed prefix.
    private static func trim(_ body: String, runs: [TextRun]) -> (String, [TextRun]) {
        let isSpace: (Character) -> Bool = { $0.isWhitespace || $0.isNewline }
        guard let first = body.firstIndex(where: { !isSpace($0) }),
              let last = body.lastIndex(where: { !isSpace($0) })
        else { return ("", []) }
        let trimmed = String(body[first...last])
        let shift = body.utf16.distance(from: body.startIndex, to: first)
        let moved = runs.map { run in
            var copy = run
            copy.start = max(run.start, Int.min + shift) - shift
            return copy
        }
        return (trimmed, RichText.normalize(moved, in: trimmed))
    }
}
