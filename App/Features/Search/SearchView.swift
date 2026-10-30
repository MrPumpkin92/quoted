import Accessibility
import QuotedCore
import SwiftUI
import UIKit

/// The search tab root (docs/ui-spec.md §9).
///
/// The field is the shell's `.searchable` on the search tab's stack, bound to `router.searchText`, so
/// this view only reads it (the shell's `.onSubmit(of: .search)` records the term in Recent). With an empty query it shows recent searches and suggestion chips. While
/// typing it searches the library and the shared inbox on the device (`QuotedCore.SearchIndex`) and
/// lists "In your library", then "Shared with you", then always the "Search the web" row last.
///
/// The web row opens Google in an in-app browser (`SafariView`, presented as the shell's `.safari` sheet),
/// as the founder chose (docs/decisions/2026-10-19-web-search-browser.md). When the browser closes and
/// something new was copied while it was open, a card offers the system Paste button, which opens a new
/// quote filled from the copied text (`SheetRoute.pastedQuote`). The app never reads the pasteboard
/// itself (only `changeCount` and `hasStrings`, which show no paste prompt).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @Environment(RecentSearches.self) private var recents
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase

    @State private var indexCache = SearchIndexCache()
    /// `UIPasteboard.changeCount` when the web row opened the browser.
    @State private var pasteboardCountAtWebSearch: Int?
    /// Whether to offer "Add the quote you copied" (the browser closed after something was copied).
    @State private var offersCopiedQuote = false
    /// `UIPasteboard.changeCount` when the card was offered. Copying anything else since makes the
    /// card stale, so it goes.
    @State private var pasteboardCountAtOffer: Int?

    init() {}

    var body: some View {
        let results = indexCache.index(quotes: library.quotes, inbox: social.inbox).search(router.searchText)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    if offersCopiedQuote {
                        CopiedQuoteCard(onDismiss: hideCopiedQuote)
                            .id(CopiedQuoteCard.scrollID)
                            .transition(.opacity)
                    }
                    if results.webQuery.isEmpty {
                        SearchStartContent(onPick: pick)
                    } else {
                        SearchResultsContent(
                            results: results,
                            isLoading: !library.hasLoaded,
                            onOpen: open,
                            onWebSearch: { searchWeb(results) }
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
            .groundBackground()
            .navigationTitle("Search")
            .animation(.default, value: offersCopiedQuote)
            .onChange(of: router.sheet) { old, new in
                if case .pastedQuote = new { hideCopiedQuote() }
                guard case .safari = old, new == nil, let count = pasteboardCountAtWebSearch else { return }
                pasteboardCountAtWebSearch = nil
                let pasteboard = UIPasteboard.general
                offersCopiedQuote = pasteboard.changeCount != count && pasteboard.hasStrings
                pasteboardCountAtOffer = offersCopiedQuote ? pasteboard.changeCount : nil
            }
            // The web row is often below the fold, so the card would appear out of sight above it.
            .onChange(of: offersCopiedQuote) { _, shows in
                guard shows else { return }
                withAnimation { proxy.scrollTo(CopiedQuoteCard.scrollID, anchor: .top) }
                Task { @MainActor in
                    // After the sheet's own screen-change notification, which would cut it off.
                    try? await Task.sleep(for: .milliseconds(500))
                    AccessibilityNotification.Announcement("Add the quote you copied, at the top of Search").post()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { hideCopiedQuoteIfStale() }
            }
            .onAppear(perform: hideCopiedQuoteIfStale)
        }
    }

    // MARK: Copied quote

    private func hideCopiedQuote() {
        offersCopiedQuote = false
        pasteboardCountAtOffer = nil
    }

    /// Hides the card once something else was copied (in another app, or on another tab), so it
    /// never offers a pasteboard that has moved on. Reads only `changeCount` and `hasStrings`.
    private func hideCopiedQuoteIfStale() {
        guard offersCopiedQuote else { return }
        let pasteboard = UIPasteboard.general
        if pasteboard.changeCount != pasteboardCountAtOffer || !pasteboard.hasStrings {
            hideCopiedQuote()
        }
    }

    // MARK: Actions

    /// A recent search or a suggestion chip: fill the field and remember the term.
    private func pick(_ term: String) {
        recents.add(term)
        router.search(for: term)
    }

    /// Opens a library result in the detail pager, paging across the library results.
    private func open(_ quote: Quote, among results: [Quote]) {
        recents.add(router.searchText)
        router.showQuote(quote.id, in: results.map(\.id))
    }

    /// The web row: log the tap (no term is stored) and open Google in the in-app browser. The user
    /// copies a quote there and closes it; the copied-quote card then offers Paste.
    private func searchWeb(_ results: SearchIndexCache.Results) {
        recents.add(results.webQuery)
        model.logWebSearchTap()
        hideCopiedQuote()
        pasteboardCountAtWebSearch = UIPasteboard.general.changeCount
        router.present(.safari(results.webURL))
    }

}

// MARK: - Empty query

/// "Recent" (the last five searches, with Clear) and the suggestion chips.
private struct SearchStartContent: View {
    let onPick: (String) -> Void

    @Environment(RecentSearches.self) private var recents

    /// Suggestion chips from the spec.
    static let suggestions = ["courage", "time", "kindness", "love", "hope"]

    var body: some View {
        if !recents.terms.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    SearchSectionTitle("Recent")
                    Spacer()
                    Button {
                        withAnimation { recents.clear() }
                    } label: {
                        // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                        Text("Clear")
                            .font(.subheadline)
                            .padding(.horizontal, Theme.Spacing.xxs)
                            .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear recent searches")
                }
                HairlineDivider()
                ForEach(recents.terms, id: \.self) { term in
                    RecentSearchRow(term: term, onPick: onPick)
                    if term != recents.terms.last {
                        HairlineDivider(leadingInset: Theme.Spacing.xl)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SearchSectionTitle("Try searching for")
            FlowLayout(spacing: Theme.Spacing.xs) {
                ForEach(Self.suggestions, id: \.self) { term in
                    Button(term) { onPick(term) }
                        .buttonStyle(SuggestionChipStyle())
                        .accessibilityHint("Searches your quotes")
                }
            }
        }
    }
}

/// One recent search: tap to search again, × to forget it.
private struct RecentSearchRow: View {
    let term: String
    let onPick: (String) -> Void

    @Environment(RecentSearches.self) private var recents

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                onPick(term)
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Theme.Spacing.l)
                        .accessibilityHidden(true)
                    Text(term)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(term)
            .accessibilityHint("Searches again")

            Button {
                withAnimation { recents.remove(term) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(term)")
        }
    }
}

/// A suggestion chip: a soft-accent capsule with accent text, at least 44 pt tall.
private struct SuggestionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .background(Color.accentSoft, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Results

/// The results for a non-empty query: library matches, shared matches, then the web row.
private struct SearchResultsContent: View {
    let results: SearchIndexCache.Results
    let isLoading: Bool
    let onOpen: (Quote, [Quote]) -> Void
    let onWebSearch: () -> Void

    @Environment(LibraryStore.self) private var library

    /// The words to tint in each result.
    private var terms: [String] {
        results.webQuery.split(separator: " ").map(String.init)
    }

    var body: some View {
        if results.isEmpty {
            if isLoading {
                DelayedProgressView(label: "Searching")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.l)
            } else {
                NoMatchesLine(term: results.webQuery, libraryIsEmpty: library.isEmpty)
            }
        }

        if !results.library.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SearchSectionTitle("In your library")
                HairlineDivider()
                ForEach(results.library) { quote in
                    LibraryResultRow(quote: quote, terms: terms) {
                        onOpen(quote, results.library)
                    }
                    if quote.id != results.library.last?.id {
                        HairlineDivider()
                    }
                }
            }
        }

        if !results.shared.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SearchSectionTitle("Shared with you")
                HairlineDivider()
                ForEach(results.shared) { share in
                    SharedResultRow(share: share, terms: terms)
                    if share.id != results.shared.last?.id {
                        HairlineDivider()
                    }
                }
            }
        }

        WebSearchRow(term: results.webQuery, action: onWebSearch)
    }
}

/// "Nothing in your library yet": shown above the web row when nothing matches.
private struct NoMatchesLine: View {
    let term: String
    let libraryIsEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(libraryIsEmpty ? "Nothing in your library yet" : "Nothing in your library matches \u{201C}\(term)\u{201D} yet")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A library match: the quote with the matched words tinted. Tap opens the detail pager.
private struct LibraryResultRow: View {
    let quote: Quote
    let terms: [String]
    let onOpen: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        Button(action: onOpen) {
            QuoteRow(quote, highlighting: terms)
                .padding(.vertical, Theme.Spacing.m)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the quote")
        .contextMenu {
            Button("Share", systemImage: "square.and.arrow.up") {
                router.present(.share(quote))
            }
            // Same labels and toasts (with Undo) as Library.
            Button {
                ReminderMembership.toggle(quote, library: library, toasts: toasts)
            } label: {
                if quote.isInRotation {
                    Label("Remove from reminders", systemImage: "bell.slash")
                } else {
                    Label("Add to reminders", systemImage: "bell")
                }
            }
            Button("Edit", systemImage: "pencil") {
                router.present(.editQuote(quote))
            }
        }
    }
}

/// A shared match (a quote a friend sent): "Jordan Lee · yesterday", a Save (bookmark) button, then
/// the quote. Tapping the quote opens the shared inbox, where it can be reported or the sender
/// blocked. Save works as it does in the inbox: the quote goes to the library and the reminders.
private struct SharedResultRow: View {
    let share: InboxQuote
    let terms: [String]

    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSaving = false

    private var senderName: String { share.sender?.displayName ?? "A friend" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: Theme.Spacing.xs) {
                    AvatarCircle(name: senderName, id: share.senderID, size: 24)
                    fromLine
                }
                saveButton
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    AvatarCircle(name: senderName, id: share.senderID, size: 24)
                    fromLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                    saveButton
                }
            }
            Button {
                router.push(.sharedInbox)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    QuoteText(share, highlighting: terms)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AttributionLine(share)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens Shared with you")
        }
        .padding(.vertical, Theme.Spacing.m)
    }

    private var fromLine: some View {
        let name = Text(senderName).fontWeight(.semibold).foregroundStyle(.primary)
        let when = share.createdAt.formatted(.relative(presentation: .named))
        return Text("\(name) \u{00B7} \(when)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityLabel("From \(senderName), \(when)")
    }

    @ViewBuilder
    private var saveButton: some View {
        if library.containsCopy(of: share) {
            Label("Saved", systemImage: "bookmark.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .accessibilityLabel("Saved to your library")
        } else {
            Button {
                save()
            } label: {
                // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                ZStack {
                    Label("Save", systemImage: "bookmark")
                        .opacity(isSaving ? 0 : 1)
                    if isSaving {
                        ProgressView()
                    }
                }
                .fontWeight(.semibold)
                .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .fixedSize()
            .disabled(isSaving)
            .accessibilityLabel(isSaving ? "Saving" : "Save")
            .accessibilityHint("Adds the quote to your library and your reminders.")
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await library.saveShared(share, addToReminders: true)
            isSaving = false
        }
    }
}

/// "Add the quote you copied", shown after the in-app browser closes with something new copied. The
/// system PasteButton reads the text without a paste prompt and opens a new quote filled from it
/// (`SheetRoute.pastedQuote`); Not now hides the card.
private struct CopiedQuoteCard: View {
    /// The card's scroll target, so it comes into view when it appears.
    static let scrollID = "copiedQuoteCard"

    let onDismiss: () -> Void

    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            let layout = IconTile.layout(for: dynamicTypeSize, alignment: .top)
            layout {
                IconTile(systemName: "doc.on.clipboard")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add the quote you copied")
                        .font(.headline)
                    Text("Paste it into a new quote. You can check the words and the author before you save.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Theme.Spacing.s) {
                PasteButton(payloadType: String.self) { @Sendable [router] strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in router.present(.pastedQuote(text)) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Color.accentColor)
                Button(action: onDismiss) {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text("Not now")
                        .padding(.horizontal, Theme.Spacing.xxs)
                        .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .card(padding: Theme.Spacing.l)
    }
}

/// The web link-out, always last: globe · “Search the web for “courage” quotes” · ↗.
private struct WebSearchRow: View {
    let term: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 24

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: "globe")
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(Self.title(for: term))
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.leading)
                    Text("Opens Google. Copy a quote, then come back here to add it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .card(padding: Theme.Spacing.l)
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Opens Google in a browser inside Quoted")
    }

    /// “Search the web for “courage” quotes”, without doubling “quotes” when the term already ends in it.
    static func title(for term: String) -> String {
        let last = SearchIndex.fold(term).split(separator: " ").last
        if last == "quote" || last == "quotes" {
            return "Search the web for \u{201C}\(term)\u{201D}"
        }
        return "Search the web for \u{201C}\(term)\u{201D} quotes"
    }
}

// MARK: - Shared pieces

/// A section title in the Margin style: subheadline semibold, secondary.
private struct SearchSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Lays out children left to right, wrapping onto new lines (the suggestion chips).
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(fitted))
                x += fitted.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Keeps one `SearchIndex` per library and inbox, so each keystroke only searches (folding every
/// quote happens once per data change, not per keystroke). The index searches the received quote
/// messages; their matches come back as the inbox's `InboxQuote`s, with their senders.
@MainActor
private final class SearchIndexCache {
    /// One search: `SearchResults` with the shared matches as `InboxQuote`s.
    struct Results {
        var library: [Quote]
        var shared: [InboxQuote]
        var webQuery: String
        var webURL: URL

        var isEmpty: Bool { library.isEmpty && shared.isEmpty }
    }

    /// The index with the inbox it was built from.
    struct Index {
        let index: SearchIndex
        let inbox: [UUID: InboxQuote]

        func search(_ query: String) -> Results {
            let results = index.search(query)
            return Results(
                library: results.library,
                shared: results.inbox.compactMap { inbox[$0.id] },
                webQuery: results.webQuery,
                webURL: results.webURL
            )
        }
    }

    private var quotes: [Quote] = []
    private var inbox: [InboxQuote] = []
    private var index: Index?

    func index(quotes: [Quote], inbox: [InboxQuote]) -> Index {
        if let index, quotes == self.quotes, inbox == self.inbox {
            return index
        }
        let built = Index(
            index: SearchIndex(quotes: quotes, inbox: inbox.map(\.message)),
            inbox: Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        self.quotes = quotes
        self.inbox = inbox
        index = built
        return built
    }
}

// MARK: - Previews

#Preview("Search · empty") {
    let model = AppModel.preview()
    model.recentSearches.add("seneca")
    model.recentSearches.add("fearless")
    return NavigationStack { SearchView() }
        .previewEnvironment(model)
}

#Preview("Search · courage") {
    let model = AppModel.preview()
    model.router.searchText = "courage"
    return NavigationStack { SearchView() }
        .previewEnvironment(model)
}

#Preview("Search · no matches") {
    let model = AppModel.preview()
    model.router.searchText = "serendipity"
    return NavigationStack { SearchView() }
        .previewEnvironment(model)
}
