import Foundation
import OSLog
import QuotedCore
import WidgetKit

/// One moment of the Quote widget: a quote to show from `date`, or the empty prompt.
struct QuoteEntry: TimelineEntry, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        /// A quote from the user's reminders. Tapping opens its detail screen.
        case quote(SnapshotQuote)
        /// A built-in quote for the widget gallery and the placeholder. Tapping just opens the app.
        case sample(SnapshotQuote)
        /// No quotes in reminders, or signed out. Tapping opens Reminders.
        case empty
    }

    let date: Date
    let content: Content

    /// The quote to show, if any.
    var quote: SnapshotQuote? {
        switch content {
        case .quote(let quote), .sample(let quote): quote
        case .empty: nil
        }
    }

    /// The deep link for a tap: `quoted://quote/<id>`, `quoted://rotation`, or nil (opens the app).
    var url: URL? {
        switch content {
        case .quote(let quote): DeepLink.quote(quote.id).url
        case .sample: nil
        case .empty: DeepLink.rotation.url
        }
    }

    static func empty(at date: Date) -> QuoteEntry {
        QuoteEntry(date: date, content: .empty)
    }

    /// The gallery and placeholder entry (Shakespeare).
    static func sample(at date: Date) -> QuoteEntry {
        QuoteEntry(date: date, content: .sample(WidgetSamples.shakespeare))
    }
}

/// What the widget found in the App Group.
enum SnapshotLoad: Sendable {
    /// A readable snapshot (it may still hold no quotes).
    case loaded(WidgetSnapshot)
    /// No snapshot: signed out, or the app has not planned yet.
    case missing
    /// A snapshot file exists but cannot be read yet, for example before the first unlock after a
    /// restart (data protection). Try again soon.
    case unreadable

    /// Reads `widget-snapshot.json` from the shared App Group container.
    static func current() -> SnapshotLoad {
        guard let store = AppGroupStore(appGroupID: AppGroup.identifier) else {
            WidgetLog.timeline.error("The App Group container is unavailable; showing the empty state")
            return .missing
        }
        if let snapshot = store.readSnapshot() {
            return .loaded(snapshot)
        }
        let exists = FileManager.default.fileExists(atPath: store.snapshotURL.path(percentEncoded: false))
        return exists ? .unreadable : .missing
    }
}

/// Builds the Quote widget's timeline from the App Group snapshot with `ReminderPlanner`.
///
/// - Timeline: an entry for "now" (the quote of the latest reminder slot), then one entry per slot in
///   the next 24 hours, from `WidgetSnapshot.timeline(now:calendar:horizon:)`. Reloads at the end.
/// - Empty or signed out: the prompt entry. The app reloads every timeline whenever it writes a new
///   snapshot, so this needs no polling.
/// - Gallery and placeholder: the Shakespeare sample.
struct QuoteTimelineProvider: TimelineProvider {
    /// How far ahead each timeline plans.
    static let horizon: TimeInterval = 24 * 60 * 60
    /// When to try again after an unreadable snapshot.
    static let retryInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> QuoteEntry {
        .sample(at: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QuoteEntry) -> Void) {
        let now = Date()
        if context.isPreview {
            completion(.sample(at: now))
            return
        }
        completion(Self.timeline(for: .current(), now: now).entries.first ?? .empty(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QuoteEntry>) -> Void) {
        completion(Self.timeline(for: .current(), now: .now))
    }

    /// The timeline for a loaded (or missing) snapshot at `now`. Pure, so previews and tests can use it.
    static func timeline(for load: SnapshotLoad, now: Date, calendar: Calendar = .current) -> Timeline<QuoteEntry> {
        switch load {
        case .missing:
            return Timeline(entries: [.empty(at: now)], policy: .never)
        case .unreadable:
            return Timeline(entries: [.empty(at: now)], policy: .after(now.addingTimeInterval(retryInterval)))
        case .loaded(let snapshot):
            let entries = entries(for: snapshot, now: now, calendar: calendar)
            guard !entries.isEmpty else {
                return Timeline(entries: [.empty(at: now)], policy: .never)
            }
            // With no reminder slot in the next 24 h (for example a weekend with weekdays only), the
            // "now" entry stands alone; reload after the horizon instead of right away.
            let policy: TimelineReloadPolicy = entries.count > 1 ? .atEnd : .after(now.addingTimeInterval(horizon))
            return Timeline(entries: entries, policy: policy)
        }
    }

    /// "Now" plus one entry per reminder slot in the next 24 hours. Empty for an empty snapshot.
    static func entries(for snapshot: WidgetSnapshot, now: Date, calendar: Calendar = .current) -> [QuoteEntry] {
        guard !snapshot.isEmpty else { return [] }
        return snapshot.timeline(now: now, calendar: calendar, horizon: horizon)
            .map { QuoteEntry(date: $0.date, content: .quote($0.quote)) }
    }
}

/// Logging for the widget extension, in the app's subsystem.
enum WidgetLog {
    static let timeline = Logger(subsystem: "com.hwei.quoted", category: "widgets")
}
