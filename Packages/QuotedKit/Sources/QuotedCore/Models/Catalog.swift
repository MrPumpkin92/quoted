import Foundation

/// One of the seven themes a catalog quote carries (`catalog_quotes.themes`, 1 to 3 per quote). The
/// cases are in the fixed order the Verified Quotes list shows its sections in.
public enum CatalogTheme: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case courage
    case calm
    case time
    case love
    case nature
    case purpose
    /// Raw value `self` (the case can't be called that in Swift).
    case selfhood = "self"

    public var id: String { rawValue }

    /// The section title.
    public var title: String {
        switch self {
        case .courage: "Courage"
        case .calm: "Calm"
        case .time: "Time"
        case .love: "Love"
        case .nature: "Nature"
        case .purpose: "Purpose"
        case .selfhood: "Self"
        }
    }
}

/// `catalog_quotes.status`. Rows are never deleted; they change status instead.
public enum CatalogStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Offered in the Verified Quotes list. Matching quotes are sealed.
    case live
    /// No longer offered. Quotes that match keep their seal.
    case retired
    /// The wording or credit turned out wrong: the seal comes off.
    case withdrawn

    /// Unknown values (from a newer server) decode as `.retired`: not offered, but not called wrong.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CatalogStatus(rawValue: raw) ?? .retired
    }
}

/// One verified quote from `catalog_quotes`: the onboarding starters (`isStarter`) and the catalog
/// batches. Every one was checked word for word against a pinned public-domain edition
/// (docs/catalog-sources.md). Read-only for clients.
///
/// A library quote whose body, author and source match one exactly carries its `id` as
/// `Quote.verifiedStarterID` (the server's seal; the wire name predates the catalog).
public struct CatalogQuote: Identifiable, Hashable, Sendable, RichTextContent {
    public var id: Int
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?
    /// Where the quote is in the work, for people ("1831 edition, Chapter 20").
    public var sourceLocation: String?
    /// The full text it was checked against (Project Gutenberg or Wikisource).
    public var sourceURL: URL?
    /// The character who speaks the line, when it is not the author's own voice.
    public var speaker: String?
    /// One to three themes, the best fit first. Values this build doesn't know are dropped.
    public var themes: [CatalogTheme]
    /// One of the onboarding starter quotes (`starter_quotes`).
    public var isStarter: Bool
    /// The onboarding position (starters only).
    public var sortOrder: Int?
    public var status: CatalogStatus

    public init(
        id: Int,
        body: String,
        format: [TextRun] = [],
        author: String? = nil,
        source: String? = nil,
        sourceLocation: String? = nil,
        sourceURL: URL? = nil,
        speaker: String? = nil,
        themes: [CatalogTheme] = [],
        isStarter: Bool = false,
        sortOrder: Int? = nil,
        status: CatalogStatus = .live
    ) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
        self.sourceLocation = sourceLocation
        self.sourceURL = sourceURL
        self.speaker = speaker
        self.themes = themes
        self.isStarter = isStarter
        self.sortOrder = isStarter ? sortOrder : nil
        self.status = status
    }

    /// A live starter, from `starter_quotes` (which has no themes or speaker).
    public init(starter: StarterQuote) {
        self.init(
            id: starter.id,
            body: starter.body,
            format: starter.format,
            author: starter.author,
            source: starter.source,
            sourceLocation: starter.sourceLocation,
            sourceURL: starter.sourceURL,
            isStarter: true,
            sortOrder: starter.sortOrder
        )
    }

    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }

    /// The theme the Verified Quotes list files it under: its first.
    public var primaryTheme: CatalogTheme? { themes.first }

    /// The `origin` a library copy records: `starter` for a starter, `catalog` for the rest.
    public var libraryOrigin: QuoteOrigin { isStarter ? .starter : .catalog }
}

extension CatalogQuote: Codable {
    enum CodingKeys: String, CodingKey {
        case id, body
        case format = "body_format"
        case author, source
        case sourceLocation = "source_location"
        case sourceURL = "source_url"
        case speaker, themes
        case isStarter = "is_starter"
        case sortOrder = "sort_order"
        case status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sourceLocation = try container.decodeIfPresent(String.self, forKey: .sourceLocation)
        // A malformed link drops only the link, not the row.
        let link: String? = (try? container.decodeIfPresent(String.self, forKey: .sourceURL)) ?? nil
        sourceURL = link.flatMap { URL(string: $0) }
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        // Unknown themes (from a newer server) are dropped; a malformed list reads as none.
        let rawThemes: [String]? = (try? container.decodeIfPresent([String].self, forKey: .themes)) ?? nil
        themes = (rawThemes ?? []).compactMap { CatalogTheme(rawValue: $0) }
        isStarter = try container.decodeIfPresent(Bool.self, forKey: .isStarter) ?? false
        let order = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        sortOrder = isStarter ? order : nil
        status = try container.decodeIfPresent(CatalogStatus.self, forKey: .status) ?? .live
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(format, forKey: .format)
        try container.encode(author, forKey: .author)
        try container.encode(source, forKey: .source)
        try container.encode(sourceLocation, forKey: .sourceLocation)
        try container.encode(sourceURL?.absoluteString, forKey: .sourceURL)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(themes, forKey: .themes)
        try container.encode(isStarter, forKey: .isStarter)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(status, forKey: .status)
    }
}

/// One section of the Verified Quotes list: the quotes filed under one theme.
public struct CatalogSection: Identifiable, Hashable, Sendable {
    /// Nil for quotes with no theme this build knows (listed last).
    public var theme: CatalogTheme?
    public var quotes: [CatalogQuote]

    public init(theme: CatalogTheme?, quotes: [CatalogQuote]) {
        self.theme = theme
        self.quotes = quotes
    }

    public var id: String { theme?.rawValue ?? "other" }

    /// The theme's title, or "More" for quotes without a known theme.
    public var title: String { theme?.title ?? "More" }
}

extension CatalogQuote {
    /// `quotes` in sections by their first theme, in ``CatalogTheme`` order, so each quote shows once.
    /// Quotes keep their given order within a section. Quotes with no known theme come last; empty
    /// sections are left out.
    public static func sections(_ quotes: [CatalogQuote]) -> [CatalogSection] {
        var byTheme: [CatalogTheme: [CatalogQuote]] = [:]
        var unthemed: [CatalogQuote] = []
        for quote in quotes {
            if let theme = quote.primaryTheme {
                byTheme[theme, default: []].append(quote)
            } else {
                unthemed.append(quote)
            }
        }
        var sections = CatalogTheme.allCases.compactMap { theme in
            byTheme[theme].map { CatalogSection(theme: theme, quotes: $0) }
        }
        if !unthemed.isEmpty {
            sections.append(CatalogSection(theme: nil, quotes: unthemed))
        }
        return sections
    }
}
