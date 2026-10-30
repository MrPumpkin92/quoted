import SwiftUI

/// The signed-in app: an iOS 26 `TabView` with Feed, Library, Inbox (the only badge), Profile and the
/// search-role tab (docs/ui-spec.md, App structure).
///
/// Each tab owns a `NavigationStack` bound to its own router path, with every `Route` mapped by
/// `.routeDestinations()`. The search field's `.searchable` (bound to `router.searchText`) sits on the
/// search tab's stack and `.tabViewSearchActivation(.searchTabSelection)` on the `TabView`, on iOS 26
/// and 27 alike: a `.searchable` on the `TabView` would put the field in every tab root's navigation
/// bar, where it searches nothing. The tab bar keeps the automatic minimize behavior: a bar minimized
/// on scroll would hide the Inbox badge. The app icon is never badged. Shell sheets are presented from
/// here; when one is dismissed, a deep link that waited for it (`Router.pendingLink`) opens.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @Environment(RecentSearches.self) private var recentSearches

    var body: some View {
        @Bindable var router = router
        let badge = social.inboxBadge
        TabView(selection: tabSelection) {
            Tab("Feed", systemImage: "text.quote", value: AppTab.feed) {
                NavigationStack(path: $router.feedPath) {
                    FeedView()
                        .routeDestinations()
                }
            }
            .accessibilityIdentifier("tab.feed")
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .routeDestinations()
                }
            }
            .accessibilityIdentifier("tab.library")
            Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                NavigationStack(path: $router.inboxPath) {
                    InboxView()
                        .routeDestinations()
                }
            }
            .badge(badge.label.map { Text(verbatim: $0) })
            .accessibilityValue(Text(badge.accessibilityValue ?? ""), isEnabled: badge.accessibilityValue != nil)
            .accessibilityIdentifier("tab.inbox")
            Tab("Profile", systemImage: "person.crop.circle", value: AppTab.profile) {
                NavigationStack(path: $router.profilePath) {
                    MyProfileView()
                        .routeDestinations()
                }
            }
            .accessibilityIdentifier("tab.profile")
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .routeDestinations()
                }
                .searchField(router: router, recentSearches: recentSearches)
            }
            .accessibilityIdentifier("tab.search")
        }
        .tabBarMinimizeBehavior(.automatic)
        // On the TabView, not the stack: iOS 27 draws the search tab as an ordinary tab, with no field,
        // when the activation sits inside it.
        .tabViewSearchActivation(.searchTabSelection)
        .sheet(item: $router.sheet, onDismiss: openPendingLink) { sheet in
            SheetHost(sheet: sheet)
        }
        // A reminder or widget tap shows the quote full screen.
        .fullScreenCover(item: $router.spotlight, onDismiss: openPendingLink) { spotlight in
            QuoteSpotlightView(quoteID: spotlight.quoteID)
        }
    }

    /// A reminder or widget tapped while a sheet with unsaved input was up opens now.
    private func openPendingLink() {
        router.openPendingLink(reminderQuoteIDs: library.reminderQuotes.map(\.id))
    }

    /// Re-tapping the selected tab pops it to its root.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { router.select($0) }
        )
    }
}

// MARK: Search field

private extension View {
    /// The search tab's field on its stack, bound to the router. The Search key remembers the term
    /// (Recent on the empty search screen).
    func searchField(router: Router, recentSearches: RecentSearches) -> some View {
        @Bindable var router = router
        return self
            .searchable(text: $router.searchText, isPresented: $router.isSearchPresented, prompt: Text("Quotes, authors, sources"))
            .onSubmit(of: .search) {
                recentSearches.add(router.searchText)
            }
    }
}

// MARK: Holding links

extension View {
    /// Marks a sheet the shell doesn't present as possibly holding unsaved input, or as one a link
    /// can't open over (the full-screen quote can't be presented while a view's own sheet is up): while
    /// it is on screen, a reminder or widget tap waits (`Router.linkHolds`) and opens once it is gone.
    /// Apply it to the sheet's content. Shell sheets use `SheetRoute.mayHoldUnsavedInput` instead (both
    /// are fine).
    func holdsDeepLinks() -> some View {
        modifier(HoldsDeepLinks())
    }
}

private struct HoldsDeepLinks: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isHolding else { return }
                isHolding = true
                router.holdLinks()
            }
            .onDisappear {
                guard isHolding else { return }
                isHolding = false
                router.releaseLinkHold(reminderQuoteIDs: library.reminderQuotes.map(\.id))
            }
    }
}

// MARK: Destinations

extension View {
    /// Maps every `Route` to its screen. The shell applies it to each tab's stack root; feature views
    /// never add their own `navigationDestination(for: Route.self)`.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(route: route)
        }
    }
}

/// The screen for a pushed `Route`.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .quote(let id, let contextIDs):
            // A new identity per quote: when a link replaces the stack with another quote at the same
            // depth, SwiftUI would otherwise keep the old pager selection (its @State starts in init).
            QuoteDetailView(quoteID: id, contextIDs: contextIDs)
                .id(id)
        case .reminders:
            RemindersView()
        case .profile(let profile):
            ProfileView(profile: profile)
        case .friends(let entry):
            FriendsView(entry: entry)
        case .settings:
            AccountView()
        case .blockedUsers:
            BlockedUsersView()
        case .textPage(let page):
            TextPageView(page: page)
        }
    }
}

/// The view for a presented `SheetRoute`, with its own toast host and Terms sheet (a send from the
/// share sheet stacks the Terms sheet over it).
struct SheetHost: View {
    let sheet: SheetRoute

    var body: some View {
        content
            .termsSheet()
            .environment(\.isInShellSheet, true)
            .toastHost()
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .addQuote:
            AddEditQuoteView(editing: nil)
        case .pastedQuote(let text):
            AddEditQuoteView(editing: nil, pasted: text)
        case .editQuote(let quote):
            AddEditQuoteView(editing: quote)
        case .share(let quote):
            ShareQuoteSheet(quote: quote)
        case .widgetGuide:
            WidgetGuideView()
        case .reminderPicker:
            ReminderQuotePicker()
        case .verifiedQuotes:
            VerifiedQuotesView()
        case .safari(let url):
            SafariView(url: url)
        }
    }
}

#Preview("Main tabs") {
    MainTabView()
        .previewEnvironment()
}
