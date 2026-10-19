import QuotedCore
import SwiftUI
import UIKit

/// Anything the design components can show as a quote: a styled body plus an optional author and
/// source. `Quote`, `SharedQuote`, `StarterQuote` and `SnapshotQuote` all conform.
protocol QuoteContent: RichTextContent {
    var author: String? { get }
    var source: String? { get }
}

extension Quote: QuoteContent {}
extension SharedQuote: QuoteContent {}
extension StarterQuote: QuoteContent {}
extension SnapshotQuote: QuoteContent {}

/// How a quote body is set. Quotes always use the system serif (New York) and scale with Dynamic Type.
///
/// UI text uses the default SF; only quote bodies and sources are serif.
enum QuoteStyle: Hashable, Sendable {
    /// Library, search and starter rows: `.title3`, line limit 4.
    case row
    /// One-line excerpt in the Reminders list and pickers: `.title3`, line limit 1.
    case excerpt
    /// The detail page, Welcome and the share card: `.largeTitle`. Never truncates.
    case hero
    /// The editor: about 26 pt, scaled relative to `.title2`. Never truncates.
    case editor
    /// Compact cards (shared-with-you cards in Friends): `.body`, line limit 6.
    case compact

    /// The text style the size scales with.
    var textStyle: Font.TextStyle {
        switch self {
        case .row, .excerpt: .title3
        case .hero: .largeTitle
        case .editor: .title2
        case .compact: .body
        }
    }

    /// The default line limit, or nil for "never truncate".
    var defaultLineLimit: Int? {
        switch self {
        case .row: 4
        case .excerpt: 1
        case .compact: 6
        case .hero, .editor: nil
        }
    }

    /// Extra leading between lines, for the serif's long ascenders.
    var lineSpacing: CGFloat {
        switch self {
        case .row, .compact: 2
        case .excerpt: 0
        case .hero, .editor: 4
        }
    }

    /// The point size of `.editor` before Dynamic Type scaling.
    static let editorBaseSize: CGFloat = 26

    /// The SwiftUI font. `.editor` needs a scaled size; pass it from `@ScaledMetric(relativeTo: .title2)`.
    func font(editorSize: CGFloat = QuoteStyle.editorBaseSize) -> Font {
        switch self {
        case .editor:
            .system(size: editorSize, design: .serif)
        default:
            .system(textStyle, design: .serif)
        }
    }

    /// The UIKit font for the rich-text editor (a `UITextView`), with optional bold and italic traits,
    /// scaled for the current Dynamic Type size relative to `.title2`.
    static func editorUIFont(
        bold: Bool = false,
        italic: Bool = false,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: editorBaseSize)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        var symbolic = descriptor.symbolicTraits
        if bold { symbolic.insert(.traitBold) }
        if italic { symbolic.insert(.traitItalic) }
        if let styled = descriptor.withSymbolicTraits(symbolic) {
            descriptor = styled
        }
        let font = UIFont(descriptor: descriptor, size: editorBaseSize)
        return UIFontMetrics(forTextStyle: .title2).scaledFont(for: font, compatibleWith: traits)
    }
}

/// Attribution typography: the author in small caps (uppercase, tracked) and the source in serif italic.
enum AttributionStyle {
    /// Author: `.caption` semibold, uppercase, tracking 1.2, `.secondary`.
    static func author(_ name: String) -> Text {
        Text(name.localizedUppercase)
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    /// Source: `.caption` serif italic, `.secondary`.
    static func source(_ title: String) -> Text {
        Text(title)
            .font(.system(.caption, design: .serif).italic())
            .foregroundStyle(.secondary)
    }
}

/// The "Quoted." wordmark: serif semibold with an accent-colored period.
struct Wordmark: View {
    var textStyle: Font.TextStyle = .title

    var body: some View {
        let name = Text("Quoted").foregroundStyle(.primary)
        let period = Text(".").foregroundStyle(Color.accentColor)
        Text("\(name)\(period)")
            .font(.system(textStyle, design: .serif).weight(.semibold))
            .accessibilityLabel("Quoted")
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Type scale") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Wordmark()
            QuoteText(Samples.shelley, style: .hero, quoteMarks: .hanging)
            QuoteText(Samples.emerson, style: .row)
            QuoteText(Samples.seneca, style: .excerpt)
            QuoteText(Samples.austen, style: .compact)
            AttributionLine(author: "Mary Shelley", source: "Frankenstein")
        }
        .padding(Theme.Spacing.gutter)
    }
    .groundBackground()
}
