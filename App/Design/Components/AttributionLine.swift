import SwiftUI

/// "MARY SHELLEY  *Frankenstein*": the author in tracked small caps, then the source in serif italic.
///
/// With `inReminders`, a small accent `bell.fill` comes first (VoiceOver: "In reminders"), and with
/// `favorite` a small accent `heart.fill` after it (VoiceOver: "Favorite"). With `verified`, the
/// accent verified seal ends the line, after the source (VoiceOver: "verified").
/// Wraps onto more lines at large Dynamic Type sizes. Shows nothing when both author and source are blank.
struct AttributionLine: View {
    private let author: String?
    private let source: String?
    private let inReminders: Bool
    private let favorite: Bool
    private let verified: Bool

    init(author: String?, source: String?, inReminders: Bool = false, favorite: Bool = false, verified: Bool = false) {
        self.author = Self.clean(author)
        self.source = Self.clean(source)
        self.inReminders = inReminders
        self.favorite = favorite
        self.verified = verified
    }

    /// The attribution of any quote-like value, with its verified seal unless `verified` says otherwise.
    init(_ content: some QuoteContent, inReminders: Bool = false, favorite: Bool = false, verified: Bool? = nil) {
        self.init(
            author: content.author,
            source: content.source,
            inReminders: inReminders,
            favorite: favorite,
            verified: verified ?? content.isVerified
        )
    }

    var body: some View {
        if author != nil || source != nil || inReminders || favorite || verified {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                if inReminders {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In reminders")
                }
                if favorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Favorite")
                }
                line
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var line: some View {
        switch (author, source) {
        case let (author?, source?):
            let authorText = AttributionStyle.author(author)
            let sourceText = AttributionStyle.source(source)
            Text("\(authorText)\u{2002}\(sourceText)\(seal)")
                .accessibilityLabel("\(author), \(source)\(sealLabel)")
        case let (author?, nil):
            Text("\(AttributionStyle.author(author))\(seal)")
                .accessibilityLabel("\(author)\(sealLabel)")
        case let (nil, source?):
            Text("\(AttributionStyle.source(source))\(seal)")
                .accessibilityLabel("\(source)\(sealLabel)")
        case (nil, nil):
            if verified {
                AttributionStyle.verifiedSeal
                    .accessibilityLabel("Verified")
            }
        }
    }

    /// The seal after the attribution, or nothing.
    private var seal: Text {
        verified ? Text("\u{2002}\(AttributionStyle.verifiedSeal)") : Text(verbatim: "")
    }

    private var sealLabel: String { verified ? ", verified" : "" }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

#Preview("AttributionLine") {
    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
        AttributionLine(author: "Mary Shelley", source: "Frankenstein")
        AttributionLine(author: "Ralph Waldo Emerson", source: "Self-Reliance", inReminders: true)
        AttributionLine(author: "Emily Dickinson", source: nil, inReminders: true)
        AttributionLine(author: nil, source: "Letters to Lucilius")
        AttributionLine(author: "Mary Shelley", source: "Frankenstein", verified: true)
        AttributionLine(author: "Ralph Waldo Emerson", source: "Self-Reliance", inReminders: true, verified: true)
        AttributionLine(author: "Jane Austen", source: "Pride and Prejudice", inReminders: true, favorite: true)
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .groundBackground()
}
