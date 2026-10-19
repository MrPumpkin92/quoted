import SwiftUI

/// A Margin card: `Surface` fill, 1-px `Hairline` stroke, 20-pt continuous corners, 16-pt padding.
///
/// Use for grouped controls (the Add sheet's cards, Reminders settings, Friends request rows) and any
/// content block that sits on `Ground`. Separate rows inside a card with `HairlineDivider`.
struct CardContainer<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - padding: Inside padding. 16 pt by default; 0 for edge-to-edge rows with their own insets.
    ///   - content: The card's content, laid out top-leading.
    init(padding: CGFloat = Theme.Spacing.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .card(padding: padding)
    }
}

/// A full-width hairline for separating rows inside a `CardContainer`.
struct HairlineDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: Theme.Metrics.hairline)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

#Preview("CardContainer") {
    VStack(spacing: Theme.Spacing.group) {
        CardContainer {
            Text("Author").font(.footnote).foregroundStyle(.secondary)
            Text("Ralph Waldo Emerson")
        }
        CardContainer(padding: 0) {
            Toggle("Include in reminders", isOn: .constant(true))
                .padding(Theme.Spacing.cardPadding)
            HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
            Text("Shows up in widgets and reminders")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(Theme.Spacing.cardPadding)
        }
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxHeight: .infinity, alignment: .top)
    .groundBackground()
}
