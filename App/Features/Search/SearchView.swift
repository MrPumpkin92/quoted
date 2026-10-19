import QuotedCore
import SwiftUI

/// The search tab root (docs/ui-spec.md §9).
///
/// The field is the shell's `.searchable` on the search tab's stack, bound to `router.searchText`, so
/// this view only reads it (the shell's `.onSubmit(of: .search)` records the term in Recent). With an empty query it shows recent searches and suggestion chips. While
/// typing it searches the library and the shared inbox on the device (`QuotedCore.SearchIndex`) and
/// lists "In your library", then "Shared with you", then always the "Search the web" row last.
///
/// The web row opens Google in an in-app browser (`SafariView`, presented as the shell's `.safari` sheet),
/// as the founder chose (docs/decisions/2026-10-19-web-search-browser.md).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @Environment(RecentSearches.self) private var recents
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    @State private var indexCache = SearchIndexCache()

    init() {}

    var body: some View {
        let results = indexCache.index(quotes: library.quotes, shared: social.inbox).search(router.searchText)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.group) {
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
    /// copies a quote there, closes it and taps Paste in Add.
    private func searchWeb(_ results: SearchResults) {
        recents.add(results.webQuery)
        model.logWebSearchTap()
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
    let results: SearchResults
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

/// A shared match: "Jordan Lee · yesterday", a Save (bookmark) button, then the quote.
/// Tapping the quote opens the shared inbox, where it can be reported or the sender blocked.
/// Save works as it does in the inbox: the quote goes to the library and the reminders.
private struct SharedResultRow: View {
    let share: SharedQuote
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
        if share.isSaved {
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
                    Text("Opens Google. Copy a quote, then tap Paste in Add.")
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
/// quote happens once per data change, not per keystroke).
@MainActor
private final class SearchIndexCache {
    private var quotes: [Quote] = []
    private var shared: [SharedQuote] = []
    private var index: SearchIndex?

    func index(quotes: [Quote], shared: [SharedQuote]) -> SearchIndex {
        if let index, quotes == self.quotes, shared == self.shared {
            return index
        }
        let built = SearchIndex(quotes: quotes, shared: shared)
        self.quotes = quotes
        self.shared = shared
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
