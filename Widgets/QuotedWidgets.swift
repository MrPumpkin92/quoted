import QuotedCore
import SwiftUI
import WidgetKit

/// The Quote widget: the quote of the latest reminder, on the Home Screen (small, medium) and the
/// Lock Screen (rectangular).
///
/// The app writes `widget-snapshot.json` to the App Group on every replan and reloads all timelines.
/// ``QuoteTimelineProvider`` runs the same `ReminderPlanner` over that snapshot, so the widget always
/// matches the last reminder. The extension links QuotedCore only (no Supabase).
struct QuoteWidget: Widget {
    static let kind = "QuoteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuoteTimelineProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Quote")
        .description("A quote from your reminders, matching your latest reminder.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct QuotedWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuoteWidget()
    }
}
