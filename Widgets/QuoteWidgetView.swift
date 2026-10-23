import QuotedCore
import SwiftUI
import WidgetKit

/// The Quote widget for every family: a Margin "page" on Surface with a serif quote and its
/// attribution, or the "Add quotes to your reminders" prompt.
///
/// The quote text is `widgetAccentable()`, so the tinted and clear Home Screen modes color the quote
/// and leave the attribution in the secondary tone. The Surface background is removed by the system
/// where it does not apply (StandBy, tinted and clear modes); the Lock Screen family has none.
struct QuoteWidgetView: View {
    let entry: QuoteEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        QuoteWidgetContent(entry: entry, family: family)
            .widgetURL(entry.url)
            .containerBackground(for: .widget) {
                if family == .accessoryRectangular {
                    Color.clear
                } else {
                    Color.surface
                }
            }
    }
}

/// The layout for one family, without the widget container (so it can also be rendered directly).
struct QuoteWidgetContent: View {
    let entry: QuoteEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if let quote = entry.quote {
                switch family {
                case .accessoryRectangular:
                    RectangularQuoteView(quote: quote)
                case .systemMedium:
                    MediumQuoteView(quote: quote)
                default:
                    SmallQuoteView(quote: quote)
                }
            } else {
                switch family {
                case .accessoryRectangular:
                    RectangularEmptyView()
                case .systemMedium:
                    MediumEmptyView()
                default:
                    SmallEmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .redacted(reason: entry.isRedacted ? .placeholder : [])
        // Widgets have a fixed size: past xxxLarge the attribution would crowd out the quote.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

// MARK: - Quote

/// Small: the quote (up to 5 lines, scaling down) with the author in small caps at the foot.
private struct SmallQuoteView: View {
    let quote: SnapshotQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The quote takes whatever the attribution leaves, top-aligned, so the author sits at the foot.
            WidgetQuoteText(quote: quote, textStyle: .body, lineLimit: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let author = quote.trimmedAuthor {
                WidgetAttribution.author(author)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            } else if let source = quote.trimmedSource {
                WidgetAttribution.source(source)
                    .lineLimit(2)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quote.accessibilityText)
    }
}

/// Medium: the quote (up to 4 lines) with the author in small caps and the source in serif italic.
private struct MediumQuoteView: View {
    let quote: SnapshotQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetQuoteText(quote: quote, textStyle: .title3, lineLimit: 4)
            if let attribution = WidgetAttribution.line(author: quote.trimmedAuthor, source: quote.trimmedSource) {
                attribution
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quote.accessibilityText)
    }
}

/// Lock Screen rectangular: the quote (3 lines) followed by "— Author".
private struct RectangularQuoteView: View {
    let quote: SnapshotQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            WidgetQuoteText(quote: quote, textStyle: .subheadline, lineLimit: 3, lineSpacing: 0)
            if let byline = quote.trimmedAuthor ?? quote.trimmedSource {
                Text(verbatim: "\u{2014} \(byline)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quote.accessibilityText)
    }
}

/// A quote body with its bold, italic and underline runs, in the system serif.
private struct WidgetQuoteText: View {
    let quote: SnapshotQuote
    let textStyle: Font.TextStyle
    let lineLimit: Int
    var lineSpacing: CGFloat = 2

    var body: some View {
        Text(RichText.attributedString(quote.body, runs: quote.format))
            .font(.system(textStyle, design: .serif))
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
            .widgetAccentable()
    }
}

/// Attribution typography, matching the app's `AttributionStyle`.
private enum WidgetAttribution {
    /// The author: `.caption` semibold, uppercase, tracking 1.2, secondary.
    static func author(_ name: String) -> Text {
        Text(name.localizedUppercase)
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    /// The source: `.caption` serif italic, secondary.
    static func source(_ title: String) -> Text {
        Text(title)
            .font(.system(.caption, design: .serif).italic())
            .foregroundStyle(.secondary)
    }

    /// "AUTHOR  Source", either part optional; nil when both are missing.
    static func line(author: String?, source: String?) -> Text? {
        switch (author, source) {
        case let (author?, source?):
            Text("\(Self.author(author))  \(Self.source(source))")
        case let (author?, nil):
            Self.author(author)
        case let (nil, source?):
            Self.source(source)
        case (nil, nil):
            nil
        }
    }
}

// MARK: - Empty

/// Small empty state: the bell tile, then the prompt at the foot.
private struct SmallEmptyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BellTile()
            Spacer(minLength: 0)
            EmptyPrompt.title
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Medium empty state: the bell tile, the prompt and a line about what shows up here.
private struct MediumEmptyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BellTile()
            VStack(alignment: .leading, spacing: 2) {
                EmptyPrompt.title
                    .lineLimit(2)
                EmptyPrompt.detail
                    .lineLimit(2)
            }
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Lock Screen empty state: a bell and the prompt.
private struct RectangularEmptyView: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bell.fill")
                .font(.subheadline)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text("Add quotes to your reminders")
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum EmptyPrompt {
    static var title: some View {
        Text("Add quotes to your reminders")
            .font(.headline)
            .foregroundStyle(.primary)
    }

    static var detail: some View {
        Text("Your latest reminder shows up here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// The accent `bell.fill` on a soft accent tile, as on the app's status card.
private struct BellTile: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 36

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accent)
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Helpers

private extension SnapshotQuote {
    var trimmedAuthor: String? { author.nonBlank }
    var trimmedSource: String? { source.nonBlank }

    /// "body, Author, Source" for VoiceOver, in natural case.
    var accessibilityText: String {
        ([body] + [trimmedAuthor, trimmedSource].compactMap { $0 }).joined(separator: ", ")
    }
}

private extension Optional where Wrapped == String {
    /// The trimmed string, or nil when it is nil or blank.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    QuoteWidget()
} timeline: {
    QuoteEntry(date: .now, content: .quote(WidgetSamples.shakespeare))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.emerson))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.austen))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.anonymous))
    QuoteEntry.empty(at: .now)
}

#Preview("Medium", as: .systemMedium) {
    QuoteWidget()
} timeline: {
    QuoteEntry(date: .now, content: .quote(WidgetSamples.emerson))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.shelley))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.austen))
    QuoteEntry.empty(at: .now)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    QuoteWidget()
} timeline: {
    QuoteEntry(date: .now, content: .quote(WidgetSamples.shakespeare))
    QuoteEntry(date: .now, content: .quote(WidgetSamples.austen))
    QuoteEntry.empty(at: .now)
}
