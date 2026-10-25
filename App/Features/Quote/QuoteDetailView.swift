import QuotedCore
import SwiftUI

/// The single-quote screen (docs/ui-spec.md §6): a horizontal pager of `QuoteCard` pages across the
/// list it was opened from (Library order, reminder order or search results), with Share, the
/// "In reminders" toggle, and the favorite heart, Edit and Delete in the toolbar. A verified quote also gets a "Verified
/// quote" button that opens `VerifiedQuoteSheet`. At accessibility text sizes the counter,
/// Share and the toggle scroll with each page, below its card.
///
/// If the quote disappears (deleted here, on another device, or a stale deep link), the pager moves to
/// a neighbour; with nothing left it pops back, with a toast unless the user deleted it here (the
/// store's "Quote deleted · Undo" toast is already showing).
///
/// VoiceOver: a one-finger swipe moves focus, not pages, so the "Quote 2 of 8" counter is adjustable
/// (swipe up or down to change quotes) and each card has "Next quote" / "Previous quote" actions.
struct QuoteDetailView: View {
    let quoteID: UUID
    let contextIDs: [UUID]

    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selection: UUID?
    @State private var lastIndex = 0
    @State private var pendingDelete: Quote?
    @State private var deletedHere: Set<UUID> = []
    @State private var isLeaving = false
    /// The quote whose verification sheet is showing.
    @State private var verifying: Quote?

    init(quoteID: UUID, contextIDs: [UUID]) {
        self.quoteID = quoteID
        self.contextIDs = contextIDs
        _selection = State(initialValue: quoteID)
    }

    var body: some View {
        content
            .groundBackground()
            .navigationTitle("Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: pageIDs, initial: true) { _, ids in
                reconcile(ids)
            }
            .onChange(of: selection) { _, id in
                if let id, let index = pageIDs.firstIndex(of: id) {
                    lastIndex = index
                }
            }
            .confirmationDialog(
                "Delete this quote?",
                isPresented: isConfirmingDelete,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { quote in
                Button("Delete Quote", role: .destructive) {
                    deletedHere.insert(quote.id)
                    library.delete(quote)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It leaves your library, your reminders and the widget.")
            }
            .sheet(item: $verifying) { quote in
                if let starterID = quote.verifiedStarterID {
                    VerifiedQuoteSheet(starterID: starterID, author: quote.author, work: quote.source)
                }
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let current {
            VStack(spacing: 0) {
                pager
                if !controlsScrollWithPage {
                    controls(for: current)
                }
            }
        } else if !library.hasLoaded {
            DelayedProgressView(label: "Loading quote")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(pages) { quote in
                page(for: quote)
                    .tag(Optional(quote.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func page(for quote: Quote) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    QuoteCard(quote)
                        .accessibilityActions {
                            if pageIDs.count > 1 {
                                Button("Next quote") { turnPage(by: 1) }
                                Button("Previous quote") { turnPage(by: -1) }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.gutter)
                        .padding(.vertical, Theme.Spacing.m)
                        .frame(maxWidth: .infinity, minHeight: controlsScrollWithPage ? nil : proxy.size.height)
                    if controlsScrollWithPage {
                        controls(for: quote)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// At accessibility text sizes the counter, Share and the reminders toggle would take most of the
    /// screen and squeeze the quote into a small scrolling window, so they scroll with each page,
    /// below its card.
    private var controlsScrollWithPage: Bool { dynamicTypeSize.isAccessibilitySize }

    private func controls(for quote: Quote) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            if pages.count > 1, let index = pageIDs.firstIndex(of: quote.id) {
                Text("\(index + 1) of \(pages.count)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Quote")
                    .accessibilityValue("\(index + 1) of \(pages.count)")
                    .accessibilityHint("Swipe up or down to change quotes.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: turnPage(by: 1)
                        case .decrement: turnPage(by: -1)
                        @unknown default: break
                        }
                    }
            }
            if quote.isVerified {
                Button {
                    verifying = quote
                } label: {
                    Label("Verified quote", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color.accentColor)
                .accessibilityHint("Shows where this quote was checked")
            }
            PrimaryButton("Share", systemImage: "square.and.arrow.up") {
                router.present(.share(quote))
            }
            CardContainer {
                Toggle(isOn: reminderBinding(for: quote)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In reminders")
                        Text("Shows up in widgets and reminders")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Wrap instead of truncating at accessibility text sizes.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.m)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let current {
            ToolbarItem(placement: .topBarTrailing) {
                FavoriteButton(quote: current)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    router.present(.editQuote(current))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        pendingDelete = current
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: Data

    /// The pages that still exist, in context order (always including the opened quote).
    private var pageIDs: [UUID] {
        let ids = contextIDs.contains(quoteID) ? contextIDs : [quoteID] + contextIDs
        return ids.filter { library.quote(id: $0) != nil }
    }

    private var pages: [Quote] {
        pageIDs.compactMap { library.quote(id: $0) }
    }

    private var current: Quote? {
        selection.flatMap { library.quote(id: $0) }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func reminderBinding(for quote: Quote) -> Binding<Bool> {
        Binding(
            get: { library.quote(id: quote.id)?.isInRotation ?? false },
            set: { included in
                Task { await library.setInReminders(quote, included) }
            }
        )
    }

    /// Moves the pager one page forward (+1) or back (-1), for the VoiceOver adjustable counter and the
    /// card's Next / Previous quote actions. Stops at the ends.
    private func turnPage(by delta: Int) {
        let ids = pageIDs
        guard let selection, let index = ids.firstIndex(of: selection) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        withAnimation { self.selection = ids[target] }
    }

    /// Keeps the selection on an existing page; pops when none is left.
    private func reconcile(_ ids: [UUID]) {
        guard library.hasLoaded, !isLeaving else { return }
        if let selection, ids.contains(selection) { return }
        if ids.isEmpty {
            isLeaving = true
            // Deleted here, the store's "Quote deleted · Undo" toast is showing; replacing an Undo toast
            // would take its Undo away, so only explain when nothing actionable is on screen.
            let deletedByUser = selection.map(deletedHere.contains) ?? false
            if !deletedByUser, toasts.current?.actionTitle == nil {
                toasts.show("This quote is no longer in your library.")
            }
            Task { @MainActor in dismiss() }
        } else {
            selection = ids[min(lastIndex, ids.count - 1)]
        }
    }
}

#Preview("Quote detail") {
    NavigationStack {
        QuoteDetailView(quoteID: Samples.shelley.id, contextIDs: Samples.quotes.map(\.id))
    }
    .previewEnvironment()
}

#Preview("Quote detail, dark") {
    NavigationStack {
        QuoteDetailView(quoteID: Samples.emerson.id, contextIDs: Samples.quotes.map(\.id))
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("Single quote, large text") {
    NavigationStack {
        QuoteDetailView(quoteID: Samples.austen.id, contextIDs: [Samples.austen.id])
    }
    .previewEnvironment()
    .dynamicTypeSize(.accessibility2)
}
