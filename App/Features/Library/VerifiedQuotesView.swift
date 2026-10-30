import QuotedCore
import SwiftUI

/// "Verified Quotes" (docs/ui-spec.md §5): every live quote in the verified catalog (the starters and
/// the later batches), in sections by theme, presented by the shell for `SheetRoute.verifiedQuotes`
/// from Library's "+" menu, its empty state and the reminder picker.
///
/// Each quote shows once, under its first theme, and the themes keep a fixed order
/// (`CatalogTheme`). Tapping a row toggles it (check circle); quotes already in the library are
/// dimmed and can't be picked. **Add N quotes** copies the picks into the library and the end of the
/// reminders, in list order (`LibraryStore.importCatalog`), then closes. A failed add keeps the sheet
/// open (the store showed a toast).
struct VerifiedQuotesView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    /// Picked catalog IDs, in the order they were tapped.
    @State private var picked: [Int] = []
    /// Set once the first load attempt finished, to tell "still loading" from "nothing came back".
    @State private var didLoad = false
    @State private var isImporting = false

    init() {}

    var body: some View {
        let sections = catalog.sections
        let owned = library.ownedCatalogIDs(in: catalog.quotes)
        NavigationStack {
            List {
                intro
                content(sections: sections, owned: owned)
            }
            .listStyle(.plain)
            .groundBackground()
            .navigationTitle("Verified Quotes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(isImporting)
                }
            }
            .safeAreaBar(edge: .bottom) {
                if !catalog.quotes.isEmpty {
                    let toAdd = pickedQuotes(in: sections, owned: owned)
                    PrimaryButton(addTitle(count: toAdd.count), isLoading: isImporting) {
                        importQuotes(toAdd)
                    }
                    .disabled(toAdd.isEmpty)
                    // The disabled button is translucent; keep the rows from showing through it.
                    .background(Color.ground, in: Capsule())
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.m)
                }
            }
            .sensoryFeedback(.selection, trigger: picked)
            .task {
                await catalog.load()
                didLoad = true
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    // MARK: Content

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("They'll show up in your widget and reminders.")
                .font(.body)
                .foregroundStyle(.secondary)
            // The seal on library rows means the same; here every row has it, so it's said once.
            Label {
                Text("Every quote is checked word for word against its source.")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .listRowSeparator(.hidden, edges: .top)
        .groundListRow()
    }

    @ViewBuilder
    private func content(sections: [CatalogSection], owned: Set<Int>) -> some View {
        if sections.isEmpty {
            Group {
                if let error = catalog.lastError, !catalog.isLoading {
                    loadError(ToastCenter.message(for: error) ?? error.userMessage)
                } else if didLoad || catalog.hasLoaded, !catalog.isLoading {
                    loadError("Verified quotes aren\u{2019}t available right now.")
                } else {
                    DelayedProgressView(label: "Loading verified quotes")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .listRowBackground(Color.ground)
            .listRowSeparator(.hidden)
        } else {
            ForEach(sections) { section in
                Section {
                    ForEach(section.quotes) { quote in
                        SelectableQuoteRow(
                            quote: quote,
                            isSelected: picked.contains(quote.id),
                            isOwned: owned.contains(quote.id)
                        ) {
                            toggle(quote.id)
                        }
                        .disabled(isImporting)
                        .groundListRow()
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        // A Color, not the hierarchical style, which would dim the header twice.
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                        // The plain list pins each theme's header; on the hidden scroll background
                        // it needs Ground behind it, or the rows scroll through the title.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Color.ground)
                }
            }
        }
    }

    private func loadError(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                Task { await catalog.load(force: true) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, Theme.Spacing.l)
    }

    // MARK: Picking

    /// The picked quotes not already in the library, in list order (section by section). After a
    /// failed add whose insert did land, a refresh brings those quotes in; they show as owned and
    /// must not count or be added again.
    private func pickedQuotes(in sections: [CatalogSection], owned: Set<Int>) -> [CatalogQuote] {
        let chosen = Set(picked)
        return sections.flatMap(\.quotes).filter { chosen.contains($0.id) && !owned.contains($0.id) }
    }

    private func addTitle(count: Int) -> LocalizedStringKey {
        switch count {
        case 0: "Add quotes"
        case 1: "Add 1 quote"
        default: "Add \(count) quotes"
        }
    }

    private func toggle(_ id: Int) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }

    /// Adds the picks to the library and the end of the reminders, then closes with "Added N
    /// quotes". A failure already showed a toast, so the sheet stays open.
    private func importQuotes(_ quotes: [CatalogQuote]) {
        guard !isImporting, !quotes.isEmpty else { return }
        isImporting = true
        Task {
            let imported = await library.importCatalog(quotes)
            isImporting = false
            guard imported else { return }
            toasts.show(quotes.count == 1 ? "Added 1 quote" : "Added \(quotes.count) quotes", style: .success)
            dismiss()
        }
    }
}

// MARK: - Previews

#Preview("Verified Quotes") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            VerifiedQuotesView()
                .previewEnvironment()
        }
}

#Preview("Verified Quotes, empty library") {
    VerifiedQuotesView()
        .previewEnvironment(.preview(emptyLibrary: true))
}

#Preview("Verified Quotes, dark, large type") {
    VerifiedQuotesView()
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Verified Quotes, loading") {
    let model = AppModel.preview()
    model.catalog.reset()
    return VerifiedQuotesView()
        .previewEnvironment(model)
}
