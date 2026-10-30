import QuotedCore
import SwiftUI

/// A quote body with its bold, italic and underline runs, set in the system serif.
///
/// Runs go through `RichText.attributedString`, so bad offsets can never crash rendering. Pass
/// `highlighting` terms (Search) to tint every case- and diacritic-insensitive match with
/// `Color.accentSoft`. `.hanging` quote marks put the opening “ in the left margin (Welcome, detail).
struct QuoteText: View {
    /// Whether to wrap the body in curly quotes.
    enum QuoteMarks: Hashable, Sendable {
        /// Just the body (rows, cards, the editor preview).
        case none
        /// “ hangs in the margin before the first line and ” follows the last word.
        case hanging
    }

    private let text: String
    private let runs: [TextRun]
    private let style: QuoteStyle
    private let quoteMarks: QuoteMarks
    private let lineLimit: Int?
    private let highlighting: [String]

    @ScaledMetric(relativeTo: .title2) private var editorSize: CGFloat = QuoteStyle.editorBaseSize
    @ScaledMetric(relativeTo: .largeTitle) private var spotlightSize: CGFloat = QuoteStyle.spotlightBaseSize

    /// - Parameters:
    ///   - body: The plain quote text.
    ///   - runs: `body_format` runs over `body` (UTF-16 offsets).
    ///   - style: The type size and line limit. Defaults to `.row`.
    ///   - quoteMarks: `.hanging` for hero quotes.
    ///   - lineLimit: Overrides the style's line limit (nil keeps the style's default).
    ///   - highlighting: Terms to highlight with `Color.accentSoft` (Search).
    init(
        body: String,
        runs: [TextRun],
        style: QuoteStyle = .row,
        quoteMarks: QuoteMarks = .none,
        lineLimit: Int? = nil,
        highlighting: [String] = []
    ) {
        self.text = body
        self.runs = runs
        self.style = style
        self.quoteMarks = quoteMarks
        self.lineLimit = lineLimit ?? style.defaultLineLimit
        self.highlighting = highlighting
    }

    /// Renders any quote-like value (`Quote`, `InboxQuote`, `StarterQuote`, `SnapshotQuote`).
    init(
        _ content: some RichTextContent,
        style: QuoteStyle = .row,
        quoteMarks: QuoteMarks = .none,
        lineLimit: Int? = nil,
        highlighting: [String] = []
    ) {
        self.init(
            body: content.body,
            runs: content.format,
            style: style,
            quoteMarks: quoteMarks,
            lineLimit: lineLimit,
            highlighting: highlighting
        )
    }

    var body: some View {
        Text(attributed)
            .font(style.font(editorSize: editorSize, spotlightSize: spotlightSize))
            .lineSpacing(style.lineSpacing)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
            .overlay(alignment: .topLeading) {
                if quoteMarks == .hanging {
                    // A zero-width frame aligned trailing pushes the mark left of the text's edge.
                    Text("\u{201C}")
                        .font(style.font(editorSize: editorSize, spotlightSize: spotlightSize))
                        .fixedSize()
                        .frame(width: 0, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text(text))
    }

    private var attributed: AttributedString {
        var result = RichText.attributedString(text, runs: runs)
        for term in highlighting {
            Self.highlight(term, in: &result)
        }
        if quoteMarks == .hanging {
            result.append(AttributedString("\u{201D}"))
        }
        return result
    }

    /// Tints every case- and diacritic-insensitive occurrence of `term`.
    private static func highlight(_ term: String, in attributed: inout AttributedString) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let found = attributed[searchStart...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[found].backgroundColor = Color.accentSoft
            guard found.upperBound > searchStart else { break }
            searchStart = found.upperBound
        }
    }
}

#Preview("QuoteText") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            QuoteText(Samples.shelley, style: .hero, quoteMarks: .hanging)
            QuoteText(Samples.emerson)
            QuoteText(Samples.seneca, style: .excerpt)
            QuoteText(Samples.austen, highlighting: ["courage"])
            QuoteText(Samples.emerson, style: .editor)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.gutter)
    }
    .groundBackground()
}
