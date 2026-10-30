import QuotedCore
import SwiftUI

/// The Feed tab root (docs/ui-spec.md §15). Until posts arrive (Stage 4) the Feed has none, so it
/// always shows the empty Feed, "Checked against the source": the Quoted Catalog quote of the day in a
/// `QuoteCard` whose checked provenance block opens `VerifiedQuoteSheet`, and a bottom bar with one
/// guidance line by friend count. With no friends a filled Add a friend pushes Friends onto the Feed
/// stack with the username field focused; with friends the guidance stands alone (Post a quote comes
/// with the composer, Stage 4).
///
/// The quote comes from the live Quoted Catalog (`CatalogStore`, every live `catalog_quotes` row) in id
/// order, for the day the Feed appeared (`CatalogQuote.ofTheDay`), so it changes the next time the Feed
/// appears, or the app returns to it from the background, after local midnight, never while it is on
/// screen (Control Center or a system alert over the Feed is not a return). The day's pick is kept on
/// the device (`AppPreferences.feedDayPick`), so a catalog that changes during the day doesn't move it.
/// The catalog loads once per session, and again after a failed Save or Send and when the Feed shows
/// on a day after the catalog loaded. The new day's quote waits for that reload (the earlier day's
/// stays meanwhile), so a quote retired or withdrawn overnight never shows; one retired during the day
/// leaves when a Save or Send of it fails. The heading, card and bar fit one screen at the default text size: the quote steps down from `.hero`
/// through `.title`, `.title2` and `.title3`, then the page scrolls. At accessibility sizes it stays
/// `.hero` and the guidance and button follow the card at the end of the scroll view. When the catalog
/// can't load (or has no live quote), an `EmptyStateView` carries the same guidance and button; a
/// failed decoration never shows an error, and the next appearance or return to the foreground tries
/// again, keeping the empty state up meanwhile. Press and hold the card for Save to Library (or "In
/// Your Library", matched as Verified Quotes dims what you hold) and Send…, both disabled until the
/// library has loaded so they never add a copy the library already holds.
struct FeedView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    /// The day (`CatalogQuote.dayNumber(of:)`) the quote is picked for, set when the Feed appears or the
    /// app comes back to it from the background, once the catalog is from that day (or couldn't
    /// reload). Fixed between those moments, so neither a re-render after midnight nor a time zone
    /// change moves the quote on screen. Nil until the Feed first appears (see `pickDay`).
    @State private var shownDay: Int?
    /// The app is in, or went through, the background, so its next `.active` is a return to the
    /// foreground rather than the end of an interruption (Control Center, an alert) over the Feed.
    @State private var wasInBackground = false
    /// The catalog quote whose provenance sheet is showing.
    @State private var verifying: CatalogQuote?
    /// Save or Send is copying the quote into the library.
    @State private var isSaving = false

    init() {}

    var body: some View {
        content
            .groundBackground()
            .navigationTitle("Feed")
            .onAppear { showToday() }
            // A Feed left on screen overnight is a new appearance when the app comes back. One under a
            // pushed screen or in another tab catches up when it next appears.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasInBackground = true
                case .active where wasInBackground:
                    wasInBackground = false
                    guard isFeedShowing else { break }
                    showToday()
                    // After a failed load, try again (a no-op once loaded).
                    Task { await catalog.load() }
                default:
                    break
                }
            }
            // Keeps the day's pick, so a reload or relaunch later today shows the same quote.
            .onChange(of: dayPick, initial: true) { _, pick in
                guard let pick else { return }
                preferences.feedDayPick = pick
            }
            .task { await catalog.load() }
            .task { await social.refreshIfStale() }
            .sheet(item: $verifying) { quote in
                VerifiedQuoteSheet(catalogID: quote.id, author: quote.author, work: quote.source)
            }
    }

    // MARK: States

    /// The day the quote is picked for: `shownDay`, or before the Feed first appears, the day the
    /// catalog loaded, so a Feed first shown on a later day never picks today's quote from an earlier
    /// day's catalog. Nil while nothing has loaded.
    private var pickDay: Int? { shownDay ?? catalog.loadedDay }

    /// The quote for `pickDay`: the day's kept pick while it is live, otherwise its index.
    private var quoteOfTheDay: CatalogQuote? {
        pickDay.flatMap { CatalogQuote.ofTheDay(from: catalog.quotes, day: $0, keeping: preferences.feedDayPick) }
    }

    /// The pick on screen, to keep for the rest of the day.
    private var dayPick: CatalogDayPick? {
        guard let day = pickDay, let quote = quoteOfTheDay else { return nil }
        return CatalogDayPick(day: day, catalogID: quote.id)
    }

    @ViewBuilder
    private var content: some View {
        if let quote = quoteOfTheDay {
            page(quote)
        } else if catalog.lastError != nil || catalog.hasLoaded {
            // The load failed (a retry keeps this up rather than a spinner), or the live catalog has no
            // quote.
            EmptyStateView(
                systemImage: "text.quote",
                title: "No posts yet",
                // Interpolated, so a username like "_sam_" isn't read as Markdown.
                message: guidance.map { "\($0.text)" },
                actionTitle: guidance?.showsAddFriend == true ? "Add a friend" : nil,
                action: addFriend
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DelayedProgressView(label: "Loading your Feed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func page(_ quote: CatalogQuote) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageTop(quote, style: .hero)
                    bottomContent
                        .padding(.horizontal, Theme.Spacing.gutter)
                        .padding(.bottom, Theme.Spacing.l)
                }
            }
        } else {
            // The first that fits above the bar wins; the last scrolls.
            ViewThatFits(in: .vertical) {
                pageTop(quote, style: .hero)
                pageTop(quote, style: .fitted(.title))
                pageTop(quote, style: .fitted(.title2))
                pageTop(quote, style: .fitted(.title3))
                ScrollView {
                    pageTop(quote, style: .fitted(.title3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaBar(edge: .bottom) {
                bottomContent
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.m)
                    // Toasts sit above the bar, not over Add a friend.
                    .reportsPinnedBarHeight()
            }
        }
    }

    /// The heading and the card.
    private func pageTop(_ quote: CatalogQuote, style: QuoteStyle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Checked against the source")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            QuoteCard(quote, style: style) {
                provenanceBlock(quote)
            }
            .contextMenu {
                cardMenu(quote)
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.m)
    }

    /// A hairline, then "Quoted Catalog" over "Checked word for word against …", which opens the
    /// sheet that says where it was checked.
    private func provenanceBlock(_ quote: CatalogQuote) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HairlineDivider()
            Button {
                verifying = quote
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    // Hidden, so VoiceOver doesn't add the checkmark's "Selected" to the block.
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quoted Catalog")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(quote.statusLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quoted Catalog, \(quote.statusLine)")
            .accessibilityHint("Shows how it was checked")
        }
    }

    /// Save and Send wait for the library: before it has loaded, an empty library would offer Save
    /// for a quote it already holds, and `add_catalog_quotes` doesn't skip text you have.
    @ViewBuilder
    private func cardMenu(_ quote: CatalogQuote) -> some View {
        if library.quote(matching: quote) != nil {
            Button("In Your Library", systemImage: "checkmark") {}
                .disabled(true)
        } else {
            Button("Save to Library", systemImage: "bookmark") {
                save(quote)
            }
            .disabled(isSaving || !library.hasLoaded)
        }
        Button("Send\u{2026}", systemImage: "paperplane") {
            send(quote)
        }
        .disabled(isSaving || !library.hasLoaded)
    }

    // MARK: Bottom bar

    /// The guidance line by friend count, and with no friends the filled Add a friend. Nothing until
    /// the friends list has loaded, so the line never flips from "no friends" to "one". Friendships
    /// aren't cached, so after a failed load the bar stays empty until a refresh answers.
    private var bottomContent: some View {
        ZStack {
            if let guidance {
                VStack(spacing: Theme.Spacing.s) {
                    Text(guidance.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                    if guidance.showsAddFriend {
                        PrimaryButton("Add a friend", action: addFriend)
                    }
                }
                // A new friend count cross-fades the line and the button.
                .id(guidance)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: guidance)
    }

    private var guidance: Guidance? {
        guard social.hasLoaded else { return nil }
        switch social.friends.count {
        case 0: return .noFriends
        case 1: return .oneFriend(handle: social.friends[0].profile.handle)
        default: return .friends
        }
    }

    // MARK: Actions

    /// The Feed appeared, or the app came back to it from the background: picks for today. A catalog
    /// loaded on an earlier day reloads first, and the quote moves to today only once that answers
    /// (the earlier day's stays meanwhile), so a quote retired or withdrawn since never shows; after a
    /// failed reload it moves anyway, with the catalog in hand. The day's kept pick stays unless it is
    /// gone.
    private func showToday() {
        let today = CatalogQuote.dayNumber(of: .now)
        guard catalog.hasLoaded, catalog.loadedDay != today else {
            shownDay = today
            return
        }
        Task {
            await catalog.load(force: true)
            shownDay = today
        }
    }

    /// Friends, on the Feed stack, with the username field focused.
    private func addFriend() {
        router.push(.friends(.add))
    }

    /// Saves the catalog quote to the library only, with "Add to Reminders" on the toast.
    private func save(_ quote: CatalogQuote) {
        Task {
            // A copy that arrived since the menu opened (a refresh) is the one saved.
            let saved: Quote?
            if let existing = library.quote(matching: quote) {
                saved = existing
            } else {
                saved = await saveCopy(of: quote)
            }
            guard let saved else { return }
            toasts.show("Saved to your library", actionTitle: "Add to Reminders") { [library, toasts] in
                guard await library.addToReminders([saved.id]) else { return }
                toasts.show("Added to your reminders", style: .success)
            }
        }
    }

    /// Today's send flow (the share sheet) works on a library quote, so it sends the library's checked
    /// copy (sealed with this quote's id), never a look-alike you typed or changed, which would reach
    /// your friend as unchecked and added by you. With no checked copy one is saved first (library
    /// only), and the toast says so, naming it a checked copy when the menu said In Your Library for a
    /// look-alike; the sheet then opens only if the Feed is still on screen.
    private func send(_ quote: CatalogQuote) {
        if let checked = checkedCopy(of: quote) {
            router.present(.share(checked))
            return
        }
        let hasLookAlike = library.quote(matching: quote) != nil
        Task {
            guard let saved = await saveCopy(of: quote) else { return }
            toasts.show(hasLookAlike ? "Saved a checked copy to your library" : "Saved to your library", style: .success)
            guard isFeedOnScreen else { return }
            router.present(.share(saved))
        }
    }

    /// The library's copy of `quote` that carries its seal, if any.
    private func checkedCopy(of quote: CatalogQuote) -> Quote? {
        library.quotes.first { $0.verifiedStarterID == quote.id }
    }

    /// Whether the Feed's tab is selected with nothing pushed over the Feed (a sheet may cover it).
    private var isFeedShowing: Bool {
        router.selectedTab == .feed && router.feedPath.isEmpty
    }

    /// Whether the Feed's card is still what's on screen after Send's save: presenting replaces any
    /// shell sheet (an Add draft would close without asking), and nothing can be presented over the
    /// provenance sheet, the full-screen quote or another tab.
    private var isFeedOnScreen: Bool {
        isFeedShowing && router.sheet == nil && router.spotlight == nil && verifying == nil
    }

    /// Saves a new copy of `quote` (`add_catalog_quotes`, outside reminders) and returns it. Nil when
    /// the save failed (the store toasted) or one is already running. A failure reloads the catalog:
    /// the server adds only live quotes (23503), so one retired or withdrawn since the catalog loaded
    /// leaves the Feed instead of failing every tap.
    private func saveCopy(of quote: CatalogQuote) async -> Quote? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        guard let saved = await library.importCatalog([quote], inReminders: false)?.first else {
            await catalog.load(force: true)
            return nil
        }
        return library.quote(id: saved.id) ?? saved
    }
}

/// The empty Feed's guidance by friend count (docs/ui-spec.md §15).
private enum Guidance: Hashable {
    case noFriends
    case oneFriend(handle: String)
    case friends

    var text: String {
        switch self {
        case .noFriends: "When friends post quotes, they show up here."
        case .oneFriend(let handle): "You and \(handle) are friends. Post a quote for them to see."
        case .friends: "Quotes you and your friends post show up here."
        }
    }

    /// Only with no friends: with friends the button is Post a quote, which needs the composer.
    var showsAddFriend: Bool { self == .noFriends }
}

#Preview("Feed, no friends") {
    let model = AppModel.preview()
    model.social.seedPreview(friendships: [], conversations: [], messages: [], me: Samples.alex.id)
    return NavigationStack { FeedView() }
        .previewEnvironment(model)
}

#Preview("Feed, friends") {
    NavigationStack { FeedView() }
        .previewEnvironment()
}

#Preview("Feed, AX3") {
    NavigationStack { FeedView() }
        .previewEnvironment()
        .dynamicTypeSize(.accessibility3)
}

#Preview("Feed, catalog not loaded") {
    // Loading, then (the preview server isn't there) the catalog-unavailable empty state.
    let model = AppModel.preview()
    model.catalog.reset()
    return NavigationStack { FeedView() }
        .previewEnvironment(model)
}
