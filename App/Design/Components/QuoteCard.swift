import QuotedCore
import SwiftUI

/// The big page card: `Surface` with a hairline, 32-pt padding, the hero serif quote with hanging
/// quote marks, and the attribution. Never truncates.
///
/// Used by `QuoteDetailView` (one card per page of the pager), the empty Feed (a smaller `style` when
/// the hero doesn't fit, and the provenance block as its `footer`) and as the share image: render it
/// with `ImageRenderer` at scale 3 in light appearance with `showsWordmark: true`
/// (see `QuoteCard.shareImage(for:)`). VoiceOver reads the quote and attribution as one element; the
/// footer keeps its own elements. Without a footer the card itself is that element, so accessibility
/// actions a caller adds (the pager's Next quote and Previous quote) land on it.
struct QuoteCard<Footer: View>: View {
    private let text: String
    private let runs: [TextRun]
    private let author: String?
    private let source: String?
    private let style: QuoteStyle
    private let inReminders: Bool
    private let verified: Bool
    private let showsWordmark: Bool
    private let footer: Footer

    /// - Parameters:
    ///   - content: A `Quote`, `InboxQuote`, `StarterQuote`, `CatalogQuote` or `SnapshotQuote`.
    ///   - style: The quote's type: `.hero`, or `.fitted` a step down when a screen must fit.
    ///   - inReminders: Shows the bell glyph. Nil asks the quote (a `Quote` in the Rotation shows it).
    ///   - footer: Drawn under the attribution, inside the card (the empty Feed's provenance block).
    init(
        _ content: some QuoteContent,
        style: QuoteStyle = .hero,
        inReminders: Bool? = nil,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(content, style: style, inReminders: inReminders, showsWordmark: false, footer: footer())
    }

    private init(_ content: some QuoteContent, style: QuoteStyle, inReminders: Bool?, showsWordmark: Bool, footer: Footer) {
        text = content.body
        runs = content.format
        author = content.author
        source = content.source
        self.style = style
        self.inReminders = inReminders ?? ((content as? Quote)?.isInRotation ?? false)
        verified = content.isVerified
        self.showsWordmark = showsWordmark
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                // A style with a default line limit (none of the page styles has one) still never truncates.
                QuoteText(body: text, runs: runs, style: style, quoteMarks: .hanging, lineLimit: style.defaultLineLimit.map { _ in .max })
                    .frame(maxWidth: .infinity, alignment: .leading)
                AttributionLine(author: author, source: source, inReminders: inReminders, verified: verified)
                if showsWordmark {
                    Wordmark(textStyle: .footnote)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .accessibilityElement(children: .combine)
            footer
        }
        .padding(Theme.Spacing.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: Theme.cardShape)
        .overlay(Theme.cardShape.strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline))
        .accessibilityElement(children: Footer.self == EmptyView.self ? .combine : .contain)
    }
}

extension QuoteCard where Footer == EmptyView {
    /// - Parameters:
    ///   - content: A `Quote`, `InboxQuote`, `StarterQuote`, `CatalogQuote` or `SnapshotQuote`.
    ///   - inReminders: Shows the bell glyph. Nil asks the quote (a `Quote` in the Rotation shows it).
    ///   - showsWordmark: Adds a small "Quoted." footer, for the share image.
    init(_ content: some QuoteContent, inReminders: Bool? = nil, showsWordmark: Bool = false) {
        self.init(content, style: .hero, inReminders: inReminders, showsWordmark: showsWordmark, footer: EmptyView())
    }

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
            QuoteCard(Samples.seneca, style: .fitted(.title2)) {
                HairlineDivider()
                Text("Footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
