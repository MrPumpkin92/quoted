import Foundation
import Observation
import QuotedCore

/// App navigation state: the selected tab, one typed path per tab, the presented sheet and the
/// search text. Inject with `@Environment(Router.self)`.
///
/// Push with `router.push(.reminders)`, present with `router.present(.addQuote)`, dismiss your own
/// sheet with `@Environment(\.dismiss)` (or `router.dismissSheet()`). Deep links go through
/// `AppModel.open(_:)`, which calls `open(_:reminderQuoteIDs:)` once the user is signed in. A link
/// never closes a sheet that may hold unsaved input: it waits in `pendingLink` and opens when the
/// sheet is dismissed.
@Observable
@MainActor
final class Router {
    /// The selected tab. Setting it through `select(_:)` pops to root when the tab is re-tapped.
    var selectedTab: AppTab = .library
    /// The Library tab's stack.
    var libraryPath: [Route] = []
    /// The Friends tab's stack.
    var friendsPath: [Route] = []
    /// The Search tab's stack.
    var searchPath: [Route] = []
    /// The presented sheet, if any. Setting a different value swaps the sheet.
    var sheet: SheetRoute?
    /// The search field's text. `MainTabView` binds it to `.searchable` on the TabView; `SearchView`
    /// reads it (and must not add its own `.searchable`).
    var searchText: String = ""
    /// Whether the search field is active (focused). Bound to `.searchable(isPresented:)`.
    var isSearchPresented: Bool = false

    /// A deep link waiting to open: it arrived before the user reached the main tabs (applied when they
    /// do), or while a sheet that may hold unsaved input was up (applied when it is dismissed).
    private(set) var pendingLink: DeepLink?

    // MARK: Tabs

    /// Selects a tab. Re-selecting the current tab pops it to its root, like every iOS tab bar.
    func select(_ tab: AppTab) {
        if tab == selectedTab {
            popToRoot(tab)
        } else {
            selectedTab = tab
        }
    }

    // MARK: Stacks

    /// The path of a tab.
    func path(for tab: AppTab) -> [Route] {
        switch tab {
        case .library: libraryPath
        case .friends: friendsPath
        case .search: searchPath
        }
    }

    /// Replaces the path of a tab.
    func setPath(_ routes: [Route], for tab: AppTab) {
        switch tab {
        case .library: libraryPath = routes
        case .friends: friendsPath = routes
        case .search: searchPath = routes
        }
    }

    /// Pushes onto the selected tab's stack.
    func push(_ route: Route) {
        setPath(path(for: selectedTab) + [route], for: selectedTab)
    }

    /// Selects `tab` and pushes onto its stack.
    func push(_ route: Route, in tab: AppTab) {
        selectedTab = tab
        setPath(path(for: tab) + [route], for: tab)
    }

    /// Pushes `QuoteDetailView` for `id`, paging across `contextIDs` (pass the list it was opened from).
    func showQuote(_ id: UUID, in contextIDs: [UUID]) {
        let context = contextIDs.contains(id) ? contextIDs : [id]
        push(.quote(id: id, contextIDs: context))
    }

    /// Pops the top screen of the selected tab.
    func pop() {
        var routes = path(for: selectedTab)
        guard !routes.isEmpty else { return }
        routes.removeLast()
        setPath(routes, for: selectedTab)
    }

    /// Pops a tab (default: the selected one) to its root.
    func popToRoot(_ tab: AppTab? = nil) {
        setPath([], for: tab ?? selectedTab)
    }

    // MARK: Sheets

    /// Presents a sheet, replacing any sheet on screen.
    func present(_ sheet: SheetRoute) {
        self.sheet = sheet
    }

    /// Dismisses the shell-presented sheet.
    func dismissSheet() {
        sheet = nil
    }

    // MARK: Search

    /// Switches to Search and searches for `term` (suggestion chips, recent searches).
    func search(for term: String) {
        selectedTab = .search
        searchText = term
        isSearchPresented = true
    }

    // MARK: Deep links

    /// Routes a deep link: `quote/<id>` selects Library and shows the quote paging across the
    /// reminder quotes; `rotation` selects Library and shows Reminders. `auth-callback` is handled by
    /// `SessionStore`, not here.
    ///
    /// A sheet that may hold unsaved input (Add, Edit, Share, the reminder picker, the starter pack;
    /// see `SheetRoute.mayHoldUnsavedInput`) is never closed by a link: the link waits in
    /// `pendingLink`, and `MainTabView` applies it with `openPendingLink(reminderQuoteIDs:)` once the
    /// sheet is dismissed (saved or cancelled). The widget guide closes at once.
    /// Returns whether the link was applied now.
    @discardableResult
    func open(_ link: DeepLink, reminderQuoteIDs: [UUID]) -> Bool {
        switch link {
        case .quote, .rotation:
            if let sheet, sheet.mayHoldUnsavedInput {
                pendingLink = link
                return false
            }
        case .authCallback:
            return false
        }
        sheet = nil
        pendingLink = nil
        selectedTab = .library
        switch link {
        case .quote(let id):
            let context = reminderQuoteIDs.contains(id) ? reminderQuoteIDs : [id]
            libraryPath = [.quote(id: id, contextIDs: context)]
        case .rotation:
            libraryPath = [.reminders]
        case .authCallback:
            break
        }
        return true
    }

    /// Opens the waiting link, if any, unless a sheet that may hold input is still up (the shell
    /// calls it when a sheet is dismissed).
    func openPendingLink(reminderQuoteIDs: [UUID]) {
        guard let link = pendingLink else { return }
        open(link, reminderQuoteIDs: reminderQuoteIDs)
    }

    /// Keeps a link until the main tabs appear (cold launch from a notification while signing in).
    /// A newer link replaces an older one.
    func deferLink(_ link: DeepLink) {
        pendingLink = link
    }

    /// Returns and clears the deferred link.
    func takePendingLink() -> DeepLink? {
        defer { pendingLink = nil }
        return pendingLink
    }

    // MARK: Reset

    /// Back to a fresh Library tab with nothing presented (sign-out).
    func reset() {
        selectedTab = .library
        libraryPath = []
        friendsPath = []
        searchPath = []
        sheet = nil
        searchText = ""
        isSearchPresented = false
        pendingLink = nil
    }
}
