import QuotedCore
import SwiftUI

/// The big page card: `Surface` with a hairline, 32-pt padding, the hero serif quote with hanging
/// quote marks, and the attribution. Never truncates.
///
/// Used by `QuoteDetailView` (one card per page of the pager) and as the share image: render it with
/// `ImageRenderer` at scale 3 in light appearance with `showsWordmark: true`
/// (see `QuoteCard.shareImage(for:)`).
struct QuoteCard: View {
    private let text: String
    private let runs: [TextRun]
    private let author: String?
    private let source: String?
    private let inReminders: Bool
    private let showsWordmark: Bool

    /// - Parameters:
    ///   - content: A `Quote`, `SharedQuote`, `StarterQuote` or `SnapshotQuote`.
    ///   - inReminders: Shows the bell glyph. Nil asks the quote (a `Quote` in the Rotation shows it).
    ///   - showsWordmark: Adds a small "Quoted." footer, for the share image.
    init(_ content: some QuoteContent, inReminders: Bool? = nil, showsWordmark: Bool = false) {
        text = content.body
        runs = content.format
        author = content.author
        source = content.source
        self.inReminders = inReminders ?? ((content as? Quote)?.isInRotation ?? false)
        self.showsWordmark = showsWordmark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            QuoteText(body: text, runs: runs, style: .hero, quoteMarks: .hanging)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttributionLine(author: author, source: source, inReminders: inReminders)
            if showsWordmark {
                Wordmark(textStyle: .footnote)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Theme.Spacing.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: Theme.cardShape)
        .overlay(Theme.cardShape.strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline))
        .accessibilityElement(children: .combine)
    }
}

extension QuoteCard {
    /// The share image: the card with the wordmark, light appearance, rendered at 3x on `Ground`.
    /// Returns nil if rendering fails.
    @MainActor
    static func shareImage(for content: some QuoteContent, width: CGFloat = 390) -> UIImage? {
        let card = QuoteCard(content, inReminders: false, showsWordmark: true)
            .frame(width: width - 2 * Theme.Spacing.gutter)
            .padding(Theme.Spacing.gutter)
            .background(Color.ground)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage
    }
}

#Preview("QuoteCard") {
    ScrollView {
        VStack(spacing: Theme.Spacing.group) {
            QuoteCard(Samples.shelley)
            QuoteCard(Samples.emerson, showsWordmark: true)
        }
        .padding(Theme.Spacing.gutter)
    }
    .groundBackground()
}

#Preview("QuoteCard dark") {
    QuoteCard(Samples.seneca)
        .padding(Theme.Spacing.gutter)
        .frame(maxHeight: .infinity)
        .groundBackground()
        .preferredColorScheme(.dark)
}
