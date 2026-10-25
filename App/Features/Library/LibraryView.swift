import QuotedCore
import QuotedKit
import SwiftUI

/// The Library tab root (docs/ui-spec.md §5): the reminders status card, a one-time widget tip, the
/// "shared with you" row, a count header and the quote list. A filled "+" opens Add.
///
/// Rows open the detail pager across the Library order. Leading swipe shares or hearts; trailing swipe
/// deletes (with Undo) or adds to / removes from reminders (Undo puts it back in its old place); the
/// context menu has all five. Once any quote is a favorite, "All / Favorites" above the count narrows
/// the list to favorites. Pull to refresh. Empty: "Your library is empty" with Add and the starter pack;
/// the toolbar "+" is then quiet glass, so the screen has one filled action.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @Environment(ReminderStore.self) private var reminders
    @Environment(SocialStore.self) private var social
    @Environment(Router.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether a Quoted widget is installed (nil until WidgetKit answers; the tip waits for it).
    @State private var widgetInstalled: Bool?
    /// The list shows only favorites ("All / Favorites"). Goes back to All when the last favorite goes.
    @State private var showsFavoritesOnly = false

    init() {}

    var body: some View {
        content
            .groundBackground()
            // On `content`, not the list: deleting the last quote replaces the list with the empty
            // state, and the filter must not come back on with no favorites to show.
            .onChange(of: hasFavorites) { _, has in
                if !has { showsFavoritesOnly = false }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addButton
                }
            }
            .task(id: scenePhase) {
                // Re-check when the app comes back (the user may have just added the widget).
                guard scenePhase == .active else { return }
                widgetInstalled = await app.widgets.hasInstalledWidget()
            }
    }

    // MARK: Toolbar

    /// The toolbar "+". Filled accent over the list; quiet glass with an accent glyph when the screen
    /// already shows its own filled action ("Add your first quote", "Try again"), so there is only one.
    @ViewBuilder
    private var addButton: some View {
        if showsOwnPrimaryAction {
            Button {
                router.present(.addQuote)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Add quote")
        } else {
            Button {
                router.present(.addQuote)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.onAccent)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Add quote")
        }
    }

    /// Whether the content is the empty or the load-failed state, each with its own filled button.
    private var showsOwnPrimaryAction: Bool {
        library.quotes.isEmpty && (library.hasLoaded || library.lastError != nil)
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if !library.quotes.isEmpty {
            quoteList
        } else if library.hasLoaded {
            emptyLibrary
        } else if let error = library.lastError {
            loadFailed(error)
        } else {
            DelayedProgressView(label: "Loading your library")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The quotes the list shows: all of them, or only favorites (newest heart first).
    private var listedQuotes: [Quote] {
        filtersFavorites ? library.favorites : library.quotes
    }

    /// The Favorites filter applies only while there are favorites (its picker is hidden otherwise).
    private var filtersFavorites: Bool { showsFavoritesOnly && hasFavorites }

    private var quoteList: some View {
        let listed = listedQuotes
        let ids = listed.map(\.id)
        return List {
            if let summary = reminders.statusSummary {
                StatusCard(
                    summary: summary,
                    onOpen: { router.push(.reminders) },
                    onTurnOn: { Task { await reminders.turnOn() } }
                )
                .headerCardRow()
            }
            if showsWidgetTip {
                widgetTip
                    .headerCardRow()
                    .transition(.opacity)
            }
            if showsSharedRow {
                sharedRow
                    .headerCardRow()
            }
            if hasFavorites {
                favoritesFilter
            }
            countHeader
            ForEach(listed) { quote in
                NavigationLink(value: Route.quote(id: quote.id, contextIDs: ids)) {
                    QuoteRow(quote)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .groundListRow()
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        router.present(.share(quote))
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(Color.accentColor)
                    Button {
                        toggleFavorite(quote)
                    } label: {
                        FavoriteActionLabel(isFavorite: quote.isFavorite)
                    }
                    .tint(SwipeTint.favorite)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.delete(quote)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        toggleReminders(quote)
                    } label: {
                        reminderLabel(for: quote)
                    }
                    .tint(Color.accentColor)
                }
                .contextMenu {
                    Button {
                        router.present(.share(quote))
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        toggleReminders(quote)
                    } label: {
                        reminderLabel(for: quote)
                    }
                    Button {
                        toggleFavorite(quote)
                    } label: {
                        FavoriteActionLabel(isFavorite: quote.isFavorite)
                    }
                    Button {
                        router.present(.editQuote(quote))
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        library.delete(quote)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .animation(.default, value: showsWidgetTip)
        .animation(.default, value: showsFavoritesOnly)
        .refreshable { await refreshAll() }
    }

    private var hasFavorites: Bool { library.quotes.contains(where: \.isFavorite) }

    /// "All / Favorites", above the count once any quote is a favorite.
    private var favoritesFilter: some View {
        Picker("Show", selection: $showsFavoritesOnly) {
            Text("All").tag(false)
            Text("Favorites").tag(true)
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(
            top: Theme.Spacing.s,
            leading: Theme.Spacing.gutter,
            bottom: 0,
            trailing: Theme.Spacing.gutter
        ))
        .listRowBackground(Color.ground)
        .listRowSeparator(.hidden)
    }

    private var emptyLibrary: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.group) {
                    if showsSharedRow {
                        sharedRow
                    }
                    EmptyStateView(
                        systemImage: "text.quote",
                        title: "Your library is empty",
                        message: "Save the lines that move you. They come back in your widget and reminders.",
                        actionTitle: "Add your first quote",
                        action: { router.present(.addQuote) },
                        secondaryTitle: "Pick from the starter pack",
                        secondaryAction: { router.present(.starterPack) }
                    )
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .refreshable { await refreshAll() }
        }
    }

    private func loadFailed(_ error: QuotedError) -> some View {
        EmptyStateView(
            systemImage: "exclamationmark.icloud",
            title: "Couldn\u{2019}t load your library",
            message: LocalizedStringKey(ToastCenter.message(for: error) ?? error.userMessage),
            actionTitle: "Try again",
            action: { Task { await library.refresh(userInitiated: true) } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header cards

    private var showsWidgetTip: Bool {
        widgetInstalled == false && !preferences.widgetTipDismissed && !library.isEmpty
    }

    private var showsSharedRow: Bool { social.unseenCount > 0 }

    private var widgetTip: some View {
        let tileLayout = IconTile.layout(for: dynamicTypeSize)
        return HStack(alignment: .center, spacing: Theme.Spacing.xs) {
            Button {
                router.present(.widgetGuide)
            } label: {
                tileLayout {
                    IconTile(systemName: "widget.small.badge.plus")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Put a quote on your Home Screen")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Add the widget in three steps")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows how to add the widget")

            Button {
                withAnimation { preferences.widgetTipDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.vertical, -Theme.Spacing.xxs)
        .card()
    }

    private var sharedRow: some View {
        // Avatars above the text at accessibility sizes, like the status card's tile.
        let layout = IconTile.layout(for: dynamicTypeSize)
        return Button {
            router.push(.sharedInbox)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                layout {
                    AvatarStack(profiles: social.unseenSenders, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(social.unseenCount == 1 ? "1 shared with you" : "\(social.unseenCount) shared with you")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let summary = social.unseenSummary {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens quotes your friends sent")
    }

    private var countHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(countTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if listedQuotes.contains(where: \.isInRotation) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text("In reminders")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
        .listRowInsets(EdgeInsets(
            top: Theme.Spacing.m,
            leading: Theme.Spacing.gutter,
            bottom: Theme.Spacing.xs,
            trailing: Theme.Spacing.gutter
        ))
        .listRowBackground(Color.ground)
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparatorTint(Color.hairline)
    }

    private var countTitle: String {
        let count = listedQuotes.count
        if filtersFavorites {
            return count == 1 ? "1 favorite" : "\(count) favorites"
        }
        return count == 1 ? "1 quote" : "\(count) quotes"
    }

    // MARK: Actions

    private func toggleFavorite(_ quote: Quote) {
        Task { await library.setFavorite(quote, !quote.isFavorite) }
    }

    @ViewBuilder
    private func reminderLabel(for quote: Quote) -> some View {
        if quote.isInRotation {
            Label("Remove from reminders", systemImage: "bell.slash")
        } else {
            Label("Add to reminders", systemImage: "bell")
        }
    }

    private func toggleReminders(_ quote: Quote) {
        ReminderMembership.toggle(quote, library: library, toasts: toasts)
    }

    private func refreshAll() async {
        let library = self.library
        let social = self.social
        async let quotes = library.refresh(userInitiated: true)
        async let friends = social.refresh()
        _ = await (quotes, friends)
    }
}

/// Adding a quote to reminders or taking it out, with the same toasts in Library, Search and Reminders:
/// "Added to reminders", or "Removed from reminders · Undo". Undo puts the quote back at its old place
/// in the reminder order (`LibraryStore.restoreReminder(id:position:)`), not at the end.
@MainActor
enum ReminderMembership {
    /// Adds `quote` to reminders, or removes it (with Undo) when it is already in.
    static func toggle(_ quote: Quote, library: LibraryStore, toasts: ToastCenter) {
        let current = library.quote(id: quote.id) ?? quote
        if current.isInRotation {
            remove(current, library: library, toasts: toasts)
        } else {
            Task { await library.addToReminders([current.id]) }
            toasts.show("Added to reminders", style: .success)
        }
    }

    /// Takes `quote` out of reminders and shows "Removed from reminders · Undo". The store is
    /// optimistic; a failed write replaces this toast with its own error toast.
    static func remove(_ quote: Quote, library: LibraryStore, toasts: ToastCenter) {
        guard let position = library.reminderPosition(of: quote.id) else { return }
        Task { await library.removeFromReminders([quote.id]) }
        toasts.show("Removed from reminders") {
            await library.restoreReminder(id: quote.id, position: position)
        }
    }
}

private extension View {
    /// A card (status, tip, shared) as a borderless row on Ground.
    func headerCardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.xxs + 2,
                leading: Theme.Spacing.gutter,
                bottom: Theme.Spacing.xxs + 2,
                trailing: Theme.Spacing.gutter
            ))
            .listRowBackground(Color.ground)
            .listRowSeparator(.hidden)
    }
}

#Preview("Library") {
    NavigationStack { LibraryView() }
        .previewEnvironment()
}

#Preview("Library, dark") {
    NavigationStack { LibraryView() }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}

#Preview("Library, notifications off") {
    let model = AppModel.preview()
    model.reminders.seedPreview(permission: .denied)
    return NavigationStack { LibraryView() }
        .previewEnvironment(model)
}

#Preview("Empty library") {
    NavigationStack { LibraryView() }
        .previewEnvironment(.preview(emptyLibrary: true))
}

#Preview("Library, large text") {
    NavigationStack { LibraryView() }
        .previewEnvironment()
        .dynamicTypeSize(.accessibility1)
}
