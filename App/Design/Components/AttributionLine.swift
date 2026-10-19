import SwiftUI

/// "MARY SHELLEY  *Frankenstein*": the author in tracked small caps, then the source in serif italic.
///
/// With `inReminders`, a small accent `bell.fill` comes first (VoiceOver: "In reminders"). Wraps onto
/// more lines at large Dynamic Type sizes. Shows nothing when both author and source are blank.
struct AttributionLine: View {
    private let author: String?
    private let source: String?
    private let inReminders: Bool

    init(author: String?, source: String?, inReminders: Bool = false) {
        self.author = Self.clean(author)
        self.source = Self.clean(source)
        self.inReminders = inReminders
    }

    /// The attribution of any quote-like value.
    init(_ content: some QuoteContent, inReminders: Bool = false) {
        self.init(author: content.author, source: content.source, inReminders: inReminders)
    }

    var body: some View {
        if author != nil || source != nil || inReminders {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                if inReminders {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In reminders")
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
            Text("\(authorText)\u{2002}\(sourceText)")
                .accessibilityLabel("\(author), \(source)")
        case let (author?, nil):
            AttributionStyle.author(author)
                .accessibilityLabel(author)
        case let (nil, source?):
            AttributionStyle.source(source)
        case (nil, nil):
            EmptyView()
        }
    }

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
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .groundBackground()
}
