import Foundation

/// A Rotation quote as the widget needs it.
public struct SnapshotQuote: Codable, Hashable, Sendable, Identifiable, RichTextContent {
    public var id: UUID
    public var body: String
    public var format: [TextRun]
    public var author: String?
    public var source: String?

    public init(id: UUID, body: String, format: [TextRun] = [], author: String? = nil, source: String? = nil) {
        self.id = id
        self.body = body
        self.format = RichText.normalize(format, in: body)
        self.author = author
        self.source = source
    }

    public init(_ quote: Quote) {
        self.init(id: quote.id, body: quote.body, format: quote.format, author: quote.author, source: quote.source)
    }

    /// "author, source", or nil when neither is set.
    public var attribution: String? { RichText.attribution(author: author, source: source) }

    enum CodingKeys: String, CodingKey {
        case id, body, format, author, source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        format = LossyRuns.decode(from: container, forKey: .format, body: body)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

/// Everything the widget extension needs, written by the app to `widget-snapshot.json` in the App
/// Group container. The widget runs ``ReminderPlanner`` on it, so it always matches the last reminder.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    /// Bump when the format changes incompatibly; older snapshots are then ignored.
    public static let currentVersion = 1

    public var version: Int
    public var updatedAt: Date
    /// Rotation quotes, in Rotation order.
    public var quotes: [SnapshotQuote]
    public var settings: ReminderSettings
    public var rotation: RotationState

    public init(
        version: Int = WidgetSnapshot.currentVersion,
        updatedAt: Date = Date(),
        quotes: [SnapshotQuote],
        settings: ReminderSettings,
        rotation: RotationState
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.quotes = quotes
        self.settings = settings
        self.rotation = rotation
    }

    /// Builds a snapshot from the library, keeping the quotes whose IDs are in `rotation`, in its order.
    public init(library: [Quote], settings: ReminderSettings, rotation: RotationState, updatedAt: Date = Date()) {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.init(
            updatedAt: updatedAt,
            quotes: rotation.quoteIDs.compactMap { byID[$0].map(SnapshotQuote.init) },
            settings: settings,
            rotation: rotation
        )
    }

    /// Whether the Rotation is empty, so the widget shows its prompt instead.
    public var isEmpty: Bool { quotes.isEmpty || rotation.quoteIDs.isEmpty }

    /// The quote with this ID, if it is in the snapshot.
    public func quote(id: UUID) -> SnapshotQuote? {
        quotes.first { $0.id == id }
    }

    /// The quote the latest reminder at or before `date` showed.
    public func currentQuote(at date: Date, calendar: Calendar = .current) -> SnapshotQuote? {
        guard let id = ReminderPlanner.currentQuoteID(rotation: rotation, settings: settings, at: date, calendar: calendar) else {
            return nil
        }
        return quote(id: id) ?? quotes.first
    }

    /// Timeline entries for the widget: now, then each slot in the next `horizon` seconds.
    /// Empty when the Rotation is empty.
    public func timeline(now: Date, calendar: Calendar = .current, horizon: TimeInterval = 24 * 60 * 60) -> [SnapshotEntry] {
        let fallback = quotes.first
        return ReminderPlanner.timeline(rotation: rotation, settings: settings, now: now, calendar: calendar, horizon: horizon)
            .compactMap { entry in
                guard let quote = quote(id: entry.quoteID) ?? fallback else { return nil }
                return SnapshotEntry(date: entry.date, quote: quote)
            }
    }
}

/// One widget timeline entry: show `quote` from `date`.
public struct SnapshotEntry: Hashable, Sendable {
    public var date: Date
    public var quote: SnapshotQuote

    public init(date: Date, quote: SnapshotQuote) {
        self.date = date
        self.quote = quote
    }
}
