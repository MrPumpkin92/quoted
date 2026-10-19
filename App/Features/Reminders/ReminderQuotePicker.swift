import QuotedCore
import SwiftUI

/// "Add quotes" (docs/ui-spec.md §8): a multi-select of the library quotes that are not in reminders,
/// presented by the shell for `SheetRoute.reminderPicker`.
///
/// Tapping a row toggles it (an accent check circle shows the selection). **Add** appends the picked
/// quotes to the end of the reminders in library order (`LibraryStore.addToReminders`, optimistic)
/// and closes the sheet.
struct ReminderQuotePicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var query = ""

    init() {}

    var body: some View {
        let candidates = library.quotesNotInReminders
        let visible = filtered(candidates)
        NavigationStack {
            content(candidates: candidates, visible: visible)
                .groundBackground()
                .navigationTitle("Add quotes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(addTitle) { add(from: candidates) }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .disabled(selection.isEmpty)
                    }
                }
        }
    }

    @ViewBuilder
    private func content(candidates: [Quote], visible: [Quote]) -> some View {
        if !library.hasLoaded {
            DelayedProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: library.isEmpty ? "text.quote" : "bell.badge",
                    title: library.isEmpty ? "Your library is empty" : "Every quote is in your reminders",
                    message: library.isEmpty
                        ? "Save a quote first, then pick the ones you want to see again."
                        : "New quotes can join your reminders when you save them.",
                    actionTitle: "Add a quote",
                    action: { router.present(.addQuote) }
                )
            }
        } else {
            List {
                if visible.isEmpty {
                    Text("No quotes match \u{201C}\(query)\u{201D}")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .groundListRow()
                } else {
                    Section {
                        ForEach(visible) { quote in
                            PickerRow(
                                quote: quote,
                                isSelected: selection.contains(quote.id),
                                highlighting: terms,
                                onToggle: { toggle(quote.id) }
                            )
                            .groundListRow()
                        }
                    } header: {
                        Text(header(count: candidates.count))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search your quotes"))
            .sensoryFeedback(.selection, trigger: selection)
        }
    }

    // MARK: Derived

    private var terms: [String] {
        SearchIndex.fold(query).isEmpty ? [] : query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func filtered(_ candidates: [Quote]) -> [Quote] {
        guard !terms.isEmpty else { return candidates }
        return SearchIndex.search(query, quotes: candidates, shared: []).library
    }

    private var addTitle: String {
        selection.isEmpty ? "Add" : "Add \(selection.count)"
    }

    private func header(count: Int) -> String {
        count == 1 ? "1 quote not in your reminders" : "\(count) quotes not in your reminders"
    }

    // MARK: Actions

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// Appends the picked quotes (library order) and closes. The store is optimistic and toasts on failure.
    private func add(from candidates: [Quote]) {
        let ids = candidates.map(\.id).filter(selection.contains)
        guard !ids.isEmpty else { return }
        let library = self.library
        Task { await library.addToReminders(ids) }
        toasts.show(ids.count == 1 ? "Added 1 quote to your reminders" : "Added \(ids.count) quotes to your reminders", style: .success)
        dismiss()
    }
}

/// A library quote with a trailing check circle. The whole row toggles it.
private struct PickerRow: View {
    let quote: Quote
    let isSelected: Bool
    let highlighting: [String]
    let onToggle: () -> Void

    @ScaledMetric(relativeTo: .title3) private var checkSize: CGFloat = 24

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                QuoteRow(quote, inReminders: false, highlighting: highlighting)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: checkSize))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget, alignment: .topTrailing)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Removes it from the selection" : "Selects it to add to your reminders")
    }
}

#Preview("Add quotes") {
    let model = AppModel.preview()
    return Color.clear
        .sheet(isPresented: .constant(true)) {
            ReminderQuotePicker()
                .previewEnvironment(model)
        }
}

#Preview("Add quotes · all in") {
    ReminderQuotePicker()
        .previewEnvironment(.preview(emptyLibrary: true))
}
