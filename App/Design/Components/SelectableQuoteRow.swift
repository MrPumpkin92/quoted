import QuotedCore
import SwiftUI

/// A verified quote to pick (onboarding's starter pack, Verified Quotes): the serif excerpt and
/// attribution, with a check circle on the right. The whole row toggles. A quote already in the
/// library shows a dimmed check and can't be picked. The rows don't show the seal: the list says
/// once, above them, that every quote was checked.
struct SelectableQuoteRow<Content: QuoteContent>: View {
    let quote: Content
    let isSelected: Bool
    let isOwned: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                QuoteRow(quote, inReminders: false, verified: false)
                checkmark
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOwned)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isOwned ? Text("Already in your library") : Text(""))
    }

    private var checkmark: some View {
        Image(systemName: isSelected || isOwned ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(checkStyle)
            .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private var checkStyle: AnyShapeStyle {
        if isOwned { return AnyShapeStyle(.tertiary) }
        return isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }
}

#Preview("SelectableQuoteRow") {
    List {
        SelectableQuoteRow(quote: Samples.catalog[0], isSelected: true, isOwned: false) {}
            .groundListRow()
        SelectableQuoteRow(quote: Samples.catalog[1], isSelected: false, isOwned: false) {}
            .groundListRow()
        SelectableQuoteRow(quote: Samples.catalog[2], isSelected: false, isOwned: true) {}
            .groundListRow()
    }
    .listStyle(.plain)
    .groundBackground()
}
