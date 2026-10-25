import QuotedCore
import SwiftUI

/// A quote in a list: the serif body (4 lines, `.row`) above its `AttributionLine`.
///
/// No per-row share icon (council fix): sharing lives in swipe actions, the context menu and the
/// detail screen. Put it in a `List` with `.groundListRow()`; the row adds no padding of its own.
/// VoiceOver reads it as one element: the quote, then the author and source.
struct QuoteRow: View {
    private let text: String
    private let runs: [TextRun]
    private let author: String?
    private let source: String?
    private let inReminders: Bool
    private let favorite: Bool
    private let verified: Bool
    private let style: QuoteStyle
    private let highlighting: [String]

    /// - Parameters:
    ///   - content: A `Quote`, `SharedQuote`, `StarterQuote` or `SnapshotQuote`.
    ///   - inReminders: Shows the bell glyph. Nil means "ask the quote": a `Quote` in the Rotation
    ///     shows it, anything else does not.
    ///   - favorite: Shows the heart glyph. Nil asks the quote: a `Quote` you hearted shows it,
    ///     anything else (a share, a friend's favorite) does not.
    ///   - verified: Shows the verified seal. Nil asks the quote (`QuoteContent.isVerified`).
    ///   - style: `.row` (4 lines, default) or `.excerpt` (1 line, Reminders list).
    ///   - highlighting: Search terms to tint with `Color.accentSoft`.
    init(
        _ content: some QuoteContent,
        inReminders: Bool? = nil,
        favorite: Bool? = nil,
        verified: Bool? = nil,
        style: QuoteStyle = .row,
        highlighting: [String] = []
    ) {
        text = content.body
        runs = content.format
        author = content.author
        source = content.source
        self.inReminders = inReminders ?? ((content as? Quote)?.isInRotation ?? false)
        self.favorite = favorite ?? ((content as? Quote)?.isFavorite ?? false)
        self.verified = verified ?? content.isVerified
        self.style = style
        self.highlighting = highlighting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            QuoteText(body: text, runs: runs, style: style, highlighting: highlighting)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttributionLine(author: author, source: source, inReminders: inReminders, favorite: favorite, verified: verified)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("QuoteRow in a List") {
    List(Samples.quotes) { quote in
        QuoteRow(quote)
            .groundListRow()
    }
    .listStyle(.plain)
    .groundBackground()
}

#Preview("QuoteRow highlighted") {
    List {
        QuoteRow(Samples.austen, highlighting: ["courage"])
            .groundListRow()
        QuoteRow(Samples.seneca, style: .excerpt)
            .groundListRow()
    }
    .listStyle(.plain)
    .groundBackground()
}
