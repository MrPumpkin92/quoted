import SwiftUI

/// The signed-in app: an iOS 26 `TabView` with Library, Friends (badged) and the search-role tab.
///
/// Each tab owns a `NavigationStack` bound to the router's typed path, with every `Route` mapped by
/// `.routeDestinations()`. The search tab's stack is `.searchable` (bound to `router.searchText`), so the
/// field lives only in the search tab. Shell sheets are presented from here; when one is dismissed, a
/// deep link that waited for it (`Router.pendingLink`) opens.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @Environment(RecentSearches.self) private var recentSearches

    var body: some View {
        @Bindable var router = router
        TabView(selection: tabSelection) {
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .routeDestinations()
                }
            }
            Tab("Friends", systemImage: "person.2", value: AppTab.friends) {
                NavigationStack(path: $router.friendsPath) {
                    FriendsView()
                        .routeDestinations()
                }
            }
            .badge(social.badgeCount)
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .routeDestinations()
                }
                .searchField(router: router, recentSearches: recentSearches, isOn: !Self.searchFieldOnTabView)
            }
        }
        .searchField(router: router, recentSearches: recentSearches, isOn: Self.searchFieldOnTabView)
        .sheet(item: $router.sheet, onDismiss: openPendingLink) { sheet in
            SheetHost(sheet: sheet)
        }
        // A reminder or widget tap shows the quote full screen.
        .fullScreenCover(item: $router.spotlight, onDismiss: openPendingLink) { spotlight in
            QuoteSpotlightView(quoteID: spotlight.quoteID)
        }
        // The app icon badge follows the Friends tab badge (shown only if badges are allowed).
        .onChange(of: social.badgeCount, initial: true) { _, count in
            Task { await InboxAlerts.setBadge(count) }
        }
    }

    /// Where the search field's `.searchable` goes. iOS 27 shows a search-role tab's field only when it
    /// is on the `TabView` (inside the tab there is no field at all). iOS 26 puts a `TabView`-level
    /// field in every tab's navigation bar, so there it stays on the search tab's stack.
    private static var searchFieldOnTabView: Bool {
        if #available(iOS 27, *) { true } else { false }
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
    /// The search tab's field, bound to the router, when `isOn`: the same `.searchable` either on the
    /// `TabView` or on the search tab's stack (`MainTabView.searchFieldOnTabView`). The Search key
    /// remembers the term (Recent on the empty search screen).
    @ViewBuilder
    func searchField(router: Router, recentSearches: RecentSearches, isOn: Bool) -> some View {
        if isOn {
            @Bindable var router = router
            self
                .searchable(text: $router.searchText, isPresented: $router.isSearchPresented, prompt: Text("Quotes, authors, sources"))
                .tabViewSearchActivation(.searchTabSelection)
                .onSubmit(of: .search) {
                    recentSearches.add(router.searchText)
                }
        } else {
            self
        }
    }
}

// MARK: Holding links

extension View {
    /// Marks a sheet the shell doesn't present as possibly holding unsaved input: while it is on
    /// screen, a reminder or widget tap waits (`Router.linkHolds`) and opens once it is gone. Apply it
    /// to the sheet's content. Shell sheets use `SheetRoute.mayHoldUnsavedInput` instead (both are fine).
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
        case .sharedInbox:
            SharedInboxView()
        case .account:
            AccountView()
        case .blockedUsers:
            BlockedUsersView()
        case .textPage(let page):
            TextPageView(page: page)
        }
    }
}

/// The view for a presented `SheetRoute`, with its own toast host.
struct SheetHost: View {
    let sheet: SheetRoute

    var body: some View {
        content
            .toastHost()
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .addQuote:
            AddEditQuoteView(editing: nil)
        case .editQuote(let quote):
            AddEditQuoteView(editing: quote)
        case .share(let quote):
            ShareQuoteSheet(quote: quote)
        case .widgetGuide:
            WidgetGuideView()
        case .reminderPicker:
            ReminderQuotePicker()
        case .starterPack:
            StarterFlowView(mode: .addMore)
        case .safari(let url):
            SafariView(url: url)
        }
    }
}

#Preview("Main tabs") {
    MainTabView()
        .previewEnvironment()
}
