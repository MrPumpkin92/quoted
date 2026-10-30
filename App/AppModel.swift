import Foundation
import Observation
import OSLog
import QuotedCore
import QuotedKit
import SwiftUI
import UserNotifications

/// The app's composition root. Owns the backend, every store and the services, wires them together,
/// and handles app-level events (deep links, scene phase, background refresh).
///
/// `RootView` gets it with `.appEnvironment(model)`, which also injects each store on its own, so a
/// feature view usually reads just what it needs:
///
///     @Environment(LibraryStore.self) private var library
///     @Environment(Router.self) private var router
///
/// `@Environment(AppModel.self)` works too when a view needs several stores.
@Observable
@MainActor
final class AppModel {
    let backend: Backend
    let session: SessionStore
    let library: LibraryStore
    let social: SocialStore
    let reminders: ReminderStore
    let starter: StarterStore
    let catalog: CatalogStore
    let recentSearches: RecentSearches
    let router: Router
    let toasts: ToastCenter
    let preferences: AppPreferences
    let widgets: WidgetBridge

    /// The notification delegate (the center holds it weakly, so the model keeps it alive).
    @ObservationIgnored private(set) var notificationDelegate: NotificationDelegate?
    @ObservationIgnored private let sideEffects: Bool
    @ObservationIgnored private var started = false
    /// When this launch last told the server the account is in use (`touchActivityIfDue()`).
    @ObservationIgnored private var lastActivityTouch: Date?

    /// - Parameters:
    ///   - backend: The Supabase backend (`Backend.fromBundle()`).
    ///   - appGroup: The shared container; nil skips the cache, snapshot and saved settings.
    ///   - sideEffects: False for previews: no notifications, widgets or announcements.
    init(backend: Backend, appGroup: AppGroupStore? = AppGroupStore(), sideEffects: Bool = true) {
        self.backend = backend
        self.sideEffects = sideEffects
        let toasts = ToastCenter(announces: sideEffects)
        let router = Router()
        let widgets = WidgetBridge(store: appGroup)
        let preferences = AppPreferences(
            defaults: sideEffects ? UserDefaults(suiteName: AppGroup.identifier) : UserDefaults(suiteName: "quoted.preview"),
            installDefaults: sideEffects ? .standard : (UserDefaults(suiteName: "quoted.preview") ?? .standard)
        )
        let reminders = ReminderStore(appGroup: appGroup, scheduler: NotificationScheduler(), widgets: widgets, sideEffects: sideEffects)
        let library = LibraryStore(backend: backend, appGroup: appGroup, toasts: toasts, reminders: reminders)
        let social = SocialStore(backend: backend, toasts: toasts)
        let starter = StarterStore(backend: backend)
        let catalog = CatalogStore(backend: backend, starter: starter)
        let recentSearches = RecentSearches(defaults: sideEffects ? .standard : (UserDefaults(suiteName: "quoted.preview") ?? .standard))
        reminders.library = library
        library.social = social
        social.library = library

        self.toasts = toasts
        self.router = router
        self.widgets = widgets
        self.preferences = preferences
        self.reminders = reminders
        self.library = library
        self.social = social
        self.starter = starter
        self.catalog = catalog
        self.recentSearches = recentSearches
        self.session = SessionStore(
            backend: backend,
            appGroup: appGroup,
            library: library,
            social: social,
            reminders: reminders,
            starter: starter,
            catalog: catalog,
            recentSearches: recentSearches,
            router: router,
            toasts: toasts,
            preferences: preferences,
            widgets: widgets
        )
        if sideEffects {
            notificationDelegate = NotificationDelegate { [weak self] link in
                self?.open(link)
            }
        }
    }

    // MARK: Launch

    /// Sets the notification delegate. Call during launch (QuotedApp.init) so a tap that launched the
    /// app is delivered.
    func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    /// Starts following the auth session. Idempotent; RootView calls it on appear.
    func start() {
        guard sideEffects, !started else { return }
        started = true
        session.start()
    }

    // MARK: Deep links

    /// `.onOpenURL`: `auth-callback` completes sign-in; `quote/<id>` and `rotation` route (or wait
    /// until the user is signed in and onboarded).
    func handle(url: URL) async {
        guard let link = DeepLink.parse(url) else {
            Logger.app.info("Ignored URL \(url.absoluteString, privacy: .private)")
            return
        }
        if case .authCallback(let callback) = link {
            await session.handleAuthCallback(callback)
        } else {
            open(link)
        }
    }

    /// Routes a deep link now if the main tabs are showing, otherwise when they appear. A sheet that
    /// may hold unsaved input stays up; the link opens once it is dismissed (`Router.open`).
    func open(_ link: DeepLink) {
        if session.phase == .ready {
            router.open(link, reminderQuoteIDs: library.reminderQuotes.map(\.id))
        } else {
            router.deferLink(link)
        }
    }

    // MARK: Scene phase

    /// The app came to the foreground: refresh (if stale), re-read permission and replan. Before the
    /// main tabs, retries a failed launch.
    func sceneDidBecomeActive() async {
        guard sideEffects else { return }
        guard session.phase == .ready else {
            // Back in the foreground with a failed launch on screen: try again now.
            await session.retryLaunchIfFailed()
            return
        }
        Task { await touchActivityIfDue() }
        await reminders.refreshPermission()
        reminders.replan()
        let library = self.library
        let social = self.social
        Task { await library.refreshIfStale() }
        Task {
            await social.refreshIfStale()
            // Seen here: a later background alert must not announce them again.
            InboxAlerts().markSeenInApp(shares: social.unseenShares, requests: social.incomingRequests)
            await InboxAlerts.setBadge(social.badgeCount)
        }
    }

    /// The app went to the background: commit pending deferred toasts and schedule the next refresh.
    /// The commit runs under background time so iOS does not suspend it mid-request. (Store writes
    /// commit immediately and hold their own background time; this covers any `showDeferred` toast.)
    func sceneDidEnterBackground() async {
        guard sideEffects else { return }
        let assertion = BackgroundTaskAssertion("Commit pending changes")
        defer { assertion.end() }
        await toasts.flushPending()
        if session.userID != nil {
            BackgroundRefresh.schedule()
        }
    }

    /// The `BGAppRefreshTask` handler: refresh the library if signed in, then replan reminders and the
    /// widget, and schedule the next run.
    func performBackgroundRefresh() async {
        guard sideEffects else { return }
        BackgroundRefresh.schedule()
        guard let userID = backend.auth.currentUserID else { return }
        library.prepare(for: userID)
        // Top up reminders from the cache first: iOS can end the task (cancelling the network
        // requests below) at any moment, and the queue must not run dry because a fetch was slow.
        await reminders.refreshPermission()
        await reminders.replan().value
        await touchActivityIfDue()
        if await library.refresh() {
            await reminders.replan().value
        }
        // New shares and friend requests: one best-effort alert, and the icon badge (no push).
        if await social.refresh() {
            await InboxAlerts().alertNew(
                shares: social.unseenShares, requests: social.incomingRequests, permission: reminders.permission
            )
            await InboxAlerts.setBadge(social.badgeCount)
        }
        Logger.app.info("Background refresh finished")
    }

    /// Tells the server the account is in use, at most every 6 hours per launch (the server keeps one
    /// write per 12 hours). Anonymous accounts unused for a year are deleted
    /// (`private.purge_inactive_anonymous`).
    func touchActivityIfDue() async {
        guard sideEffects else { return }
        if let lastActivityTouch, Date.now.timeIntervalSince(lastActivityTouch) < 6 * 60 * 60 { return }
        lastActivityTouch = .now
        await backend.social.touchActivity()
    }
}

// MARK: Analytics

extension AppModel {
    /// Records a "Search the web" tap (`events.web_search_tap`; the term is never sent). Runs in the
    /// background and never fails visibly. Previews and signed-out sessions record nothing.
    func logWebSearchTap() {
        guard sideEffects else { return }
        backend.events.logWebSearchTap()
    }
}

// MARK: Environment

extension View {
    /// Injects the model and each store, so views can use `@Environment(LibraryStore.self)` etc., and
    /// sets the accent tint (stock toggles, pickers and links use it instead of green or system blue).
    func appEnvironment(_ model: AppModel) -> some View {
        self
            .tint(Color.accentColor)
            .environment(model)
            .environment(model.session)
            .environment(model.library)
            .environment(model.social)
            .environment(model.reminders)
            .environment(model.starter)
            .environment(model.catalog)
            .environment(model.recentSearches)
            .environment(model.router)
            .environment(model.toasts)
            .environment(model.preferences)
    }
}

// MARK: Previews

extension AppModel {
    /// A model seeded with the mockup data (signed in as Alex, eight quotes, six in reminders, two
    /// friends, a request each way, two unseen shares) and no side effects. Network calls fail quietly.
    static func preview(phase: SessionPhase = .ready, emptyLibrary: Bool = false) -> AppModel {
        let url = URL(string: "http://127.0.0.1:54321") ?? URL(filePath: "/")
        let backend = Backend(config: SupabaseConfig(url: url, publishableKey: "sb_publishable_preview"), sessionPersistence: .inMemory)
        let model = AppModel(backend: backend, appGroup: nil, sideEffects: false)
        model.session.seedPreview(phase: phase, profile: Samples.alex, email: "alex@example.com")
        model.library.seedPreview(quotes: emptyLibrary ? [] : Samples.quotes)
        model.social.seedPreview(friendships: Samples.friendships, inbox: Samples.inbox, me: Samples.alex.id)
        model.starter.seedPreview(quotes: Samples.starters)
        model.catalog.seedPreview(quotes: Samples.catalog)
        model.reminders.seedPreview(permission: .authorized)
        return model
    }
}

extension View {
    /// Wraps a preview in `AppModel.preview()` with a toast host: `#Preview { NavigationStack { LibraryView() }.previewEnvironment() }`.
    func previewEnvironment(_ model: AppModel = .preview()) -> some View {
        self
            .toastHost()
            .appEnvironment(model)
    }
}
