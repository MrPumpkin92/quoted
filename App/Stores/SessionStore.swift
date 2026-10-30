import Foundation
import Observation
import OSLog
import QuotedCore
import QuotedKit

/// Where the user is in the app's lifecycle. `RootView` switches on it.
enum SessionPhase: Hashable, Sendable {
    /// Restoring the session at launch, or creating the anonymous account (Ground + wordmark;
    /// `launchError` offers a retry).
    case launching
    /// No session: `AuthFlowView` with email accounts, `WelcomeView` (Get started) with anonymous ones.
    case signedOut
    /// Signed in without a profile: `UsernameView`.
    case needsUsername
    /// Profile done, starter pack not yet: `StarterFlowView()`.
    case needsStarter
    /// The main tabs.
    case ready
}

/// How people get an account (docs/decisions/2026-10-20-anonymous-accounts.md).
enum AccountMode: Hashable, Sendable {
    /// No sign-in screens. With no stored session the app creates an anonymous Supabase account for
    /// this iPhone and goes straight to the Username screen. Sign out is not offered (nothing could
    /// sign back in to the account); deleting the account starts a new one.
    case anonymous
    /// Email and password through `AuthFlowView`: sign up, the confirmation link and password reset.
    case emailPassword

    /// The mode this build uses. Set it back to `.emailPassword` to bring the sign-in screens back.
    static let current: AccountMode = .anonymous
}

/// Authentication, the user's profile and onboarding. Owns the session lifecycle: signing in loads
/// the cached library and refreshes it; signing out or deleting the account wipes the App Group
/// (reminder settings survive a sign-out; they are per device), cancels notifications, reloads
/// widgets, empties the HTTP cache and resets every store.
///
/// Methods a form calls (`signIn`, `signUp`, `createProfile`, ...) throw `QuotedError` so the view can
/// show `error.userMessage` inline. Phase changes happen inside the store; never set them from a view.
/// Inject with `@Environment(SessionStore.self)`.
@Observable
@MainActor
final class SessionStore {
    // MARK: State

    /// The current phase.
    private(set) var phase: SessionPhase = .launching {
        // Leaving the launch screen ends a failed launch and its automatic retries.
        didSet { if phase != .launching { clearLaunchFailure() } }
    }
    /// The signed-in user's ID.
    private(set) var userID: UUID?
    /// The signed-in user's email. Nil for an anonymous account.
    private(set) var email: String?
    /// Whether the signed-in account is anonymous: it has no email or password to sign back in with.
    private(set) var isAnonymous = false
    /// Whether to offer Sign out: only with email accounts, where `AuthFlowView` can sign back in.
    /// Signing out of an anonymous account would lose it for good, and with anonymous accounts on
    /// there is no sign-in screen to come back through, even for an email session left on the device.
    var canSignOut: Bool { AccountMode.current == .emailPassword && !isAnonymous }
    /// The signed-in user's profile (username and display name). Nil before a username is chosen.
    private(set) var profile: Profile?
    /// The signed-in user's own account (`my_account()`): favorites visibility and the accepted Terms
    /// of Use version, which `profiles` doesn't let anyone read. Nil until loaded (cached per user).
    private(set) var account: MyAccount?
    /// Set after `signUp` when the server sent a confirmation email: show "Check your inbox".
    private(set) var pendingConfirmationEmail: String?
    /// A launch failure (offline, or the server did not answer). The launch screen shows it with Try
    /// again (`retryLaunch()`), and the app retries by itself: on a timer, and when it comes back to
    /// the foreground.
    private(set) var launchError: String?
    /// The failed launch's diagnostic and the backend URL. The launch screen shows it in DEBUG
    /// builds, where a stopped local stack and a server bug would otherwise look the same.
    private(set) var launchErrorDetail: String?
    /// True while `retryLaunch()` runs: the launch screen keeps `launchError` up and shows progress.
    private(set) var isRetryingLaunch = false
    /// Why Welcome is showing again: the anonymous account on this iPhone can no longer be opened
    /// (the server deleted it, or its session can't be refreshed). Cleared once a new account starts.
    private(set) var signedOutNotice: String?
    /// True after a password-reset link signed the user in: `RootView` shows `NewPasswordView` until
    /// `setNewPassword(_:)` succeeds or `cancelPasswordRecovery()` is called.
    var isRecoveringPassword: Bool { recoveringUserID != nil && recoveringUserID == userID }

    /// The shortest password the app accepts (the Create account form uses the same rule).
    static let minimumPasswordLength = 8

    /// The user a password-reset link signed in, until they choose a new password.
    private var recoveringUserID: UUID?

    // MARK: Dependencies

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let appGroup: AppGroupStore?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let social: SocialStore
    @ObservationIgnored private let reminders: ReminderStore
    @ObservationIgnored private let starter: StarterStore
    @ObservationIgnored private let catalog: CatalogStore
    @ObservationIgnored private let recentSearches: RecentSearches
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let widgets: WidgetBridge
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// The user whose session is starting or started; guards against double starts.
    @ObservationIgnored private var activeUserID: UUID?
    /// Profile writes (name, favorites visibility), so a profile read that overlapped one is dropped.
    @ObservationIgnored private var profileWrites = WriteTracker()
    /// Set when a profile read was dropped or a profile write failed: read again once no write runs.
    @ObservationIgnored private var rereadProfileAfterWrites = false
    /// True while `startAccount()` waits for the server, so one tap creates one account.
    @ObservationIgnored private var isCreatingAccount = false
    /// The pending automatic launch retry (`scheduleLaunchRetry()`).
    @ObservationIgnored private var launchRetryTimer: Task<Void, Never>?
    /// Failed launch attempts in a row; picks the next retry's delay.
    @ObservationIgnored private var launchFailures = 0
    /// True while `signOut()` or `deleteAccount()` runs. The sign-out they cause reaches
    /// `handleSessionChange` too, and must not read as a lost account.
    @ObservationIgnored private var isLeavingAccount = false
    #if DEBUG
    /// Set once `DebugSignIn` has signed in, so a deletion or sign-out in a UI test moves on to Welcome
    /// instead of signing back in to the same account.
    @ObservationIgnored private var didUseDebugSignIn = false
    #endif

    /// Welcome's line after an anonymous account was lost (`signedOutNotice`).
    static let lostAccountNotice = "Your previous account can no longer be opened on this iPhone. Get started to begin again."

    init(
        backend: Backend,
        appGroup: AppGroupStore?,
        library: LibraryStore,
        social: SocialStore,
        reminders: ReminderStore,
        starter: StarterStore,
        catalog: CatalogStore,
        recentSearches: RecentSearches,
        router: Router,
        toasts: ToastCenter,
        preferences: AppPreferences,
        widgets: WidgetBridge
    ) {
        self.backend = backend
        self.appGroup = appGroup
        self.library = library
        self.social = social
        self.reminders = reminders
        self.starter = starter
        self.catalog = catalog
        self.recentSearches = recentSearches
        self.router = router
        self.toasts = toasts
        self.preferences = preferences
        self.widgets = widgets
    }

    // MARK: Lifecycle

    /// Starts following the auth session (idempotent). Called by `AppModel.start()`.
    func start() {
        guard listener == nil else { return }
        let changes = backend.auth.sessionChanges
        listener = Task { [weak self] in
            for await userID in changes {
                guard let self else { return }
                await self.handleSessionChange(userID)
            }
        }
    }

    /// Retries a launch that failed (`launchError`). The message stays up while it runs.
    func retryLaunch() async {
        guard !isRetryingLaunch else { return }
        launchRetryTimer?.cancel()
        guard let id = activeUserID ?? backend.auth.currentUserID else {
            phase = .signedOut
            return
        }
        isRetryingLaunch = true
        defer { isRetryingLaunch = false }
        activeUserID = nil
        await beginSession(userID: id)
    }

    /// Retries the launch if the launch screen shows a failure: when the app comes back to the
    /// foreground, and when the retry timer fires.
    func retryLaunchIfFailed() async {
        guard phase == .launching, launchError != nil else { return }
        await retryLaunch()
    }

    // MARK: Auth

    /// Anonymous accounts: Welcome's Get started. Creates an account for this iPhone and begins its
    /// session; the phase moves on to Choose a username by itself. Throws `QuotedError` for Welcome
    /// to show (offline, busy, or anonymous sign-ins turned off on the server); nothing changes then.
    ///
    /// A session the SDK still holds but this store gave up on (one the server rejected) is signed
    /// out first: Get started is the user asking for a fresh start. DEBUG builds against the local
    /// stack sign in with `DebugSignIn` credentials instead, when the launch environment has them.
    func startAccount() async throws(QuotedError) {
        guard AccountMode.current == .anonymous, !isCreatingAccount, activeUserID == nil else { return }
        isCreatingAccount = true
        defer { isCreatingAccount = false }
        if backend.auth.currentUserID != nil {
            isLeavingAccount = true
            try? await backend.auth.signOut()
            isLeavingAccount = false
        }
        let id: UUID
        do {
            id = try await signInWithoutAccount()
        } catch {
            let mapped = QuotedError(error)
            Logger.session.error("Starting an account failed: \(String(describing: mapped), privacy: .public)")
            if mapped == .rateLimited {
                throw .validation("Quoted is busy right now. Try again in a few minutes.")
            }
            throw mapped
        }
        signedOutNotice = nil
        await beginSession(userID: id)
    }

    /// Signs in with email and password. On success the phase moves on by itself.
    func signIn(email: String, password: String) async throws(QuotedError) {
        let id: UUID
        do {
            id = try await backend.auth.signIn(email: email, password: password)
        } catch {
            throw QuotedError(error)
        }
        await beginSession(userID: id)
    }

    /// Creates an account. When the server wants email confirmation, sets `pendingConfirmationEmail`
    /// (show "Check your inbox") and returns `.confirmationRequired`; otherwise the user is signed in.
    /// "Resend" calls this again with the same email and password.
    @discardableResult
    func signUp(email: String, password: String) async throws(QuotedError) -> SignUpResult {
        let result: SignUpResult
        do {
            result = try await backend.auth.signUp(email: email, password: password)
        } catch {
            throw QuotedError(error)
        }
        switch result {
        case .signedIn(let id):
            pendingConfirmationEmail = nil
            await beginSession(userID: id)
        case .confirmationRequired(let address):
            pendingConfirmationEmail = address
        }
        return result
    }

    /// Leaves the "Check your inbox" state (back to the sign-in form).
    func clearPendingConfirmation() {
        pendingConfirmationEmail = nil
    }

    /// Sends a password-reset email. The view shows a toast on success.
    func sendPasswordReset(email: String) async throws(QuotedError) {
        do {
            try await backend.auth.sendPasswordReset(email: email)
        } catch {
            throw QuotedError(error)
        }
    }

    /// Completes `quoted://auth-callback`. An email-confirmation link signs the user in; a
    /// password-reset link signs them in and sets `isRecoveringPassword`, so `RootView` asks for a new
    /// password. Failures toast.
    func handleAuthCallback(_ url: URL) async {
        do {
            let result = try await backend.auth.handle(url: url)
            pendingConfirmationEmail = nil
            if case .passwordRecovery(let id) = result {
                recoveringUserID = id
            }
            await beginSession(userID: result.userID)
        } catch {
            toasts.show(error: error)
        }
    }

    /// Sets a new password for the signed-in user.
    func updatePassword(_ password: String) async throws(QuotedError) {
        do {
            try await backend.auth.updatePassword(password)
        } catch {
            throw QuotedError(error)
        }
    }

    /// Saves the new password after a password-reset link (`NewPasswordView`). Throws
    /// `.validation` for a password shorter than `minimumPasswordLength` and the server's errors
    /// otherwise (show `error.friendlyMessage` inline). On success clears `isRecoveringPassword` and
    /// toasts "Password updated".
    func setNewPassword(_ password: String) async throws(QuotedError) {
        guard password.count >= Self.minimumPasswordLength else {
            throw .validation("Use at least \(Self.minimumPasswordLength) characters for your password.")
        }
        let assertion = BackgroundTaskAssertion("Set new password")
        defer { assertion.end() }
        do {
            try await backend.auth.updatePassword(password)
        } catch {
            throw QuotedError(error)
        }
        recoveringUserID = nil
        toasts.show("Password updated", style: .success)
    }

    /// Leaves the new-password screen without changing the password. The user stays signed in.
    func cancelPasswordRecovery() {
        recoveringUserID = nil
    }

    // MARK: Profile

    /// Whether `username` is free. Throws `.validation` for an invalid username.
    func isUsernameAvailable(_ username: String) async throws(QuotedError) -> Bool {
        do {
            return try await backend.profiles.isUsernameAvailable(username)
        } catch {
            throw QuotedError(error)
        }
    }

    /// Creates the profile (Username screen). Throws `.usernameTaken` or `.validation`. On success the
    /// phase moves to the starter pack (or straight to the library if the user already has quotes).
    func createProfile(username: String, displayName: String?) async throws(QuotedError) {
        let assertion = BackgroundTaskAssertion("Create profile")
        profileWrites.begin()
        defer {
            profileWrites.end()
            assertion.end()
            rereadProfileIfWritesSettled()
        }
        let created: Profile
        do {
            created = try await backend.profiles.createProfile(username: username, displayName: displayName)
        } catch {
            throw QuotedError(error)
        }
        profile = created
        preferences.cacheProfile(created)
        guard let id = userID else { return }
        // The account's private fields (terms, favorites visibility) come from `my_account()`, read
        // once this write settles.
        rereadProfileAfterWrites = true
        await resolvePhaseAfterProfile(userID: id)
    }

    /// Changes the display name (blank clears it, showing the username).
    func updateDisplayName(_ displayName: String?) async throws(QuotedError) {
        let assertion = BackgroundTaskAssertion("Update display name")
        profileWrites.begin()
        defer {
            profileWrites.end()
            assertion.end()
            rereadProfileIfWritesSettled()
        }
        let updated: Profile
        do {
            updated = try await backend.profiles.updateDisplayName(displayName)
        } catch {
            // The change may have landed even though the answer was lost.
            rereadProfileAfterWrites = true
            throw QuotedError(error)
        }
        profile = updated
        preferences.cacheProfile(updated)
        if var account, account.id == updated.id {
            account.displayName = updated.displayName == updated.username ? nil : updated.displayName
            self.account = account
            preferences.cacheAccount(account)
        }
    }

    /// Whether friends can see the quotes you heart (`favorites_visibility` is `friends`). Nil until
    /// the account is loaded (the first launch after an update, before `my_account()` answers, or
    /// offline then): show a neutral state, never "private".
    var showsFavorites: Bool? { account.map { $0.favoritesVisibility == .friends } }

    /// Shows or hides your favorites from your friends (off by default): sets `favorites_visibility`
    /// to `friends` or `private`.
    func setShowsFavorites(_ shows: Bool) async throws(QuotedError) {
        let assertion = BackgroundTaskAssertion("Show favorites to friends")
        profileWrites.begin()
        defer {
            profileWrites.end()
            assertion.end()
            rereadProfileIfWritesSettled()
        }
        let visibility: FavoritesVisibility = shows ? .friends : .onlyMe
        do {
            try await backend.profiles.setFavoritesVisibility(visibility)
        } catch {
            // The change may have landed even though the answer was lost.
            rereadProfileAfterWrites = true
            throw QuotedError(error)
        }
        if var account {
            account.favoritesVisibility = visibility
            self.account = account
            preferences.cacheAccount(account)
        } else {
            // Not loaded yet: read the whole account once the write settles.
            rereadProfileAfterWrites = true
        }
    }

    /// Reads your account again (`my_account()`) and returns it: the Terms check (`SocialStore`)
    /// needs the server's answer, not the cache. Applies it unless a profile write overlapped the
    /// read. Nil before a username is chosen. Not retried: a write waits on it, and offline should
    /// fail at once rather than after the SDK's retries.
    func reloadAccount() async throws -> MyAccount? {
        let token = profileWrites.token
        let fetched = try await backend.profiles.myAccount(retry: false)
        if let fetched, fetched.id == activeUserID, profileWrites.isQuiet(since: token) {
            apply(fetched)
        }
        return fetched
    }

    /// Records that the server accepted Terms of Use `version` (`SocialStore.acceptTerms()`).
    func noteTermsAccepted(version: Int) {
        guard var account else { return }
        account.termsVersion = max(account.termsVersion ?? 0, version)
        account.termsAcceptedAt = .now
        self.account = account
        preferences.cacheAccount(account)
    }

    /// Re-reads your profile (name, favorites setting), for pull to refresh on Your profile. Quiet
    /// on failure: the profile shown stays.
    func refreshProfile() async {
        guard let id = activeUserID else { return }
        await refreshProfile(userID: id)
    }

    /// Finishes onboarding (after the starter pack and notification priming, or Skip): records the
    /// per-user flag so the starter pack shows only once, and shows the main tabs.
    func completeOnboarding() {
        guard let id = userID else { return }
        preferences.setCompletedOnboarding(userID: id)
        enterReady()
    }

    // MARK: Sign out and delete

    /// Signs out: commits pending undo toasts, signs out of Supabase, then wipes the App Group (the
    /// per-device reminder settings stay), cancels notifications, reloads widgets, empties the HTTP
    /// cache and resets every store. Runs under background time, so leaving the app mid-way finishes it.
    /// With anonymous accounts a new one starts afterwards (the views offer Sign out only for an email
    /// account, `canSignOut`).
    func signOut() async {
        let assertion = BackgroundTaskAssertion("Sign out")
        defer { assertion.end() }
        await toasts.flushPending()
        isLeavingAccount = true
        do {
            try await backend.auth.signOut()
        } catch {
            isLeavingAccount = false
            toasts.show(error: error)
            return
        }
        preferences.hadAnonymousSession = false
        await endSession(accountDeleted: false)
        isLeavingAccount = false
    }

    /// Permanently deletes the account on the server, then cleans up like `signOut()` and also resets
    /// the reminder settings and this user's onboarding flag. Throws `QuotedError` (the account stays)
    /// so the Account screen can show it.
    ///
    /// Safe to retry: when an earlier attempt deleted the account but its answer was lost, QuotedKit
    /// confirms the user is gone and this returns normally. `.notSignedIn` means the session can no
    /// longer be used while the account may still exist: the app then signs out on this device (with a
    /// toast asking to sign in again) and rethrows. An anonymous account has no way back in, so it keeps
    /// its session instead and the error asks to try again; if the SDK has dropped that session
    /// meanwhile, the account can't be reached any more and Welcome shows `signedOutNotice`. Runs under
    /// background time.
    ///
    /// With anonymous accounts the app returns to Welcome after a deletion.
    func deleteAccount() async throws(QuotedError) {
        let assertion = BackgroundTaskAssertion("Delete account")
        defer { assertion.end() }
        await toasts.flushPending()
        let deletedUserID = userID
        isLeavingAccount = true
        do {
            try await backend.account.deleteAccount()
        } catch {
            let mapped = QuotedError(error)
            guard mapped == .notSignedIn else {
                isLeavingAccount = false
                if activeUserID == nil, backend.auth.currentUserID == nil {
                    // The SDK dropped the session during the call and its sign-out already ended it
                    // here (while leaving): show Welcome with the lost-account notice.
                    await replaceLostSession()
                }
                throw mapped
            }
            if backend.auth.isAnonymous {
                // Signing out would lose the account without deleting it. The SDK refreshes or drops
                // a dead session by itself; Try again then deletes it or finds it gone.
                isLeavingAccount = false
                throw .validation("Quoted couldn\u{2019}t confirm your account with the server. Try again in a moment.")
            }
            // An unusable session: every request would fail. Sign out so the user can sign in
            // again and delete from there (an anonymous account the SDK dropped is simply gone).
            try? await backend.auth.signOut()
            await endSession(accountDeleted: false)
            isLeavingAccount = false
            if AccountMode.current == .anonymous {
                // No sign-in screen to come back through: Welcome says why.
                signedOutNotice = Self.lostAccountNotice
                preferences.hadAnonymousSession = false
            } else {
                toasts.show("Your session has ended. Sign in again to delete your account.", style: .error)
            }
            throw mapped
        }
        // The local sign-out inside deleteAccount() may already have ended the session through the
        // session stream, so remove this user's flags explicitly.
        if let deletedUserID {
            preferences.removeUserData(userID: deletedUserID, includingOnboarding: true)
        }
        preferences.hadAnonymousSession = false
        await endSession(accountDeleted: true)
        isLeavingAccount = false
    }

    // MARK: Private

    private func handleSessionChange(_ userID: UUID?) async {
        if let userID {
            await beginSession(userID: userID)
            return
        }
        // A sign-out a newer sign-in has already replaced: `startAccount()` begins the new session
        // directly, so the stream's earlier sign-out can arrive after it.
        guard backend.auth.currentUserID == nil else { return }
        Logger.session.info("Session ended")
        await replaceLostSession()
    }

    /// Ends a session the SDK dropped or the server rejected and shows the signed-out screen. If this
    /// install's last session was an anonymous account the user did not leave, there is no way back
    /// into it: Welcome says so (`signedOutNotice`).
    ///
    /// DEBUG: with `DebugSignIn` credentials in the launch environment, the first launch signs in to
    /// that local account at once instead of waiting on Welcome (UI tests and the demo script).
    private func replaceLostSession() async {
        let lostAccount = AccountMode.current == .anonymous && preferences.hadAnonymousSession && !isLeavingAccount
        if activeUserID != nil || phase != .signedOut {
            await endSession(accountDeleted: false)
        }
        if lostAccount {
            signedOutNotice = Self.lostAccountNotice
            preferences.hadAnonymousSession = false
        }
        #if DEBUG
        if phase == .signedOut, !isLeavingAccount, !didUseDebugSignIn, DebugSignIn.credentials(for: backend.config) != nil {
            try? await startAccount()
        }
        #endif
    }

    /// The sign-in behind `startAccount()`: a new anonymous account, or in DEBUG the local test account
    /// named in the launch environment. That account is used until it signs in once; after that (it was
    /// deleted or signed out) Get started creates anonymous accounts.
    private func signInWithoutAccount() async throws -> UUID {
        #if DEBUG
        if !didUseDebugSignIn, let credentials = DebugSignIn.credentials(for: backend.config) {
            Logger.session.info("DEBUG: signing in with the launch environment's local account")
            let id = try await backend.auth.signIn(email: credentials.email, password: credentials.password)
            didUseDebugSignIn = true
            return id
        }
        #endif
        let id = try await backend.auth.signInAnonymously()
        Logger.session.info("Created an anonymous account")
        return id
    }

    /// Whether a `.notSignedIn` answer should end the session here. Always for an email account (the
    /// user signs in again). An anonymous account has no way back in, so it ends only once the SDK
    /// has dropped the session itself (it does for a refresh token the server no longer knows); until
    /// then a launch refreshes it (`shouldRetryLaunchStep`), and a ready app stays where it is.
    private var shouldEndRejectedSession: Bool { !backend.auth.isAnonymous }

    /// Ends a session the server rejected and shows the signed-out screen.
    private func endRejectedSession() async {
        await replaceLostSession()
    }

    /// Handles a launch step that failed with `error`, and says whether to run the step again.
    ///
    /// `.notSignedIn` ends an email account's session. An anonymous account's session is refreshed
    /// instead (when `mayRefresh`, once per step), since the stored token can be rejected while the
    /// SDK still thinks it valid: a device clock running behind, or a signing key the server rotated.
    /// After a new token the step runs again (true). If the server no longer knows the session, the
    /// SDK removes it and the account is lost: Welcome says so. Any other failure shows on the launch
    /// screen with Try again.
    private func shouldRetryLaunchStep(after error: QuotedError, step: String, userID id: UUID, mayRefresh: Bool) async -> Bool {
        guard error == .notSignedIn else {
            failLaunch(error, step: step)
            return false
        }
        if shouldEndRejectedSession {
            await endRejectedSession()
            return false
        }
        guard mayRefresh else {
            failLaunch(error, step: step)
            return false
        }
        do {
            try await backend.auth.refreshSession()
        } catch {
            guard activeUserID == id else { return false }
            if backend.auth.currentUserID == nil {
                Logger.session.error("\(step, privacy: .public): the server no longer knows this session")
                await replaceLostSession()
            } else {
                failLaunch(QuotedError(error), step: "\(step) session refresh")
            }
            return false
        }
        guard activeUserID == id, backend.auth.currentUserID == id else { return false }
        Logger.session.info("\(step, privacy: .public): refreshed a session the server rejected")
        return true
    }

    /// Shows a failed launch step on the launch screen and schedules the next automatic attempt.
    private func failLaunch(_ error: QuotedError, step: String) {
        Logger.session.error("\(step, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        launchError = ToastCenter.message(for: error) ?? error.userMessage
        launchErrorDetail = "\(String(describing: error)) \u{2014} \(backend.config.url.absoluteString)"
        phase = .launching
        scheduleLaunchRetry()
    }

    /// Seconds before each automatic launch retry; the last one repeats while the launch keeps failing.
    private static let launchRetryDelays: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]

    /// Retries a failed launch after a pause, so a dropped connection or a short outage clears by
    /// itself while the launch screen shows the error.
    private func scheduleLaunchRetry() {
        launchRetryTimer?.cancel()
        let delay = Self.launchRetryDelays[min(launchFailures, Self.launchRetryDelays.count - 1)]
        launchFailures += 1
        launchRetryTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Its own task: cancelling the timer later must not cancel the retry's requests.
            Task { await self.retryLaunchIfFailed() }
        }
    }

    /// Forgets a failed launch: its message, its retry timer and the failure count.
    private func clearLaunchFailure() {
        launchError = nil
        launchErrorDetail = nil
        launchFailures = 0
        launchRetryTimer?.cancel()
        launchRetryTimer = nil
    }

    /// Shows the cached library and decides the phase. Idempotent per user.
    private func beginSession(userID id: UUID) async {
        guard activeUserID != id else { return }
        if activeUserID != nil {
            await endSession(accountDeleted: false)
        }
        activeUserID = id
        userID = id
        email = backend.auth.currentEmail
        isAnonymous = backend.auth.isAnonymous
        // Only while the SDK still holds this session: one it already dropped must not clear the flag.
        if backend.auth.currentUserID == id {
            preferences.hadAnonymousSession = isAnonymous
        }
        // `launchError` stays: a retry keeps the message up until it succeeds (the phase changes) or
        // fails again (`failLaunch`).
        pendingConfirmationEmail = nil
        library.prepare(for: id)

        account = preferences.cachedAccount(userID: id)
        if let cached = preferences.cachedProfile(userID: id) {
            profile = cached
            await resolvePhaseAfterProfile(userID: id)
            await refreshProfile(userID: id)
            return
        }
        await loadProfile(userID: id)
    }

    /// Fetches the profile (with the account's private fields) at launch and decides the phase:
    /// Choose a username without one.
    private func loadProfile(userID id: UUID, mayRefreshSession: Bool = true) async {
        do {
            let fetched = try await backend.profiles.myAccount()
            guard activeUserID == id else { return }
            if let fetched {
                apply(fetched)
                await resolvePhaseAfterProfile(userID: id)
            } else {
                phase = .needsUsername
            }
        } catch {
            guard activeUserID == id else { return }
            if await shouldRetryLaunchStep(after: QuotedError(error), step: "Profile load", userID: id, mayRefresh: mayRefreshSession) {
                await loadProfile(userID: id, mayRefreshSession: false)
            }
        }
    }

    /// Ready if onboarding is done or the user already has quotes; otherwise the starter pack.
    ///
    /// Without the onboarding flag (a new device, or a reinstall that kept the Keychain session) an
    /// empty library is checked with the server. If that check fails, the user may well have quotes,
    /// so the launch screen shows the error with "Try again" instead of the starter pack.
    private func resolvePhaseAfterProfile(userID id: UUID, mayRefreshSession: Bool = true) async {
        if preferences.hasCompletedOnboarding(userID: id) {
            enterReady()
            return
        }
        if library.isEmpty {
            let answered = await library.refresh()
            guard activeUserID == id else { return }
            if !answered, library.isEmpty {
                let error = library.lastError ?? .network
                if await shouldRetryLaunchStep(after: error, step: "Library check", userID: id, mayRefresh: mayRefreshSession) {
                    await resolvePhaseAfterProfile(userID: id, mayRefreshSession: false)
                }
                return
            }
        }
        if library.isEmpty {
            phase = .needsStarter
        } else {
            preferences.setCompletedOnboarding(userID: id)
            enterReady()
        }
    }

    /// Shows the main tabs and starts the ready-state work: refreshes, permission, replan, the
    /// deferred deep link and the background refresh schedule.
    private func enterReady() {
        guard phase != .ready else { return }
        phase = .ready
        launchError = nil
        Logger.session.info("Session ready")
        if let link = router.takePendingLink() {
            router.open(link, reminderQuoteIDs: library.reminderQuotes.map(\.id))
        }
        BackgroundRefresh.schedule()
        let library = self.library
        let social = self.social
        let reminders = self.reminders
        Task {
            await reminders.refreshPermission()
            reminders.replan()
        }
        Task { await library.refreshIfStale(maxAge: 30) }
        Task { await social.refresh() }
    }

    private func refreshProfile(userID id: UUID) async {
        let token = profileWrites.token
        do {
            guard let fetched = try await backend.profiles.myAccount(), activeUserID == id else { return }
            // A name or setting saved while this read was out wins; read again once writes settle.
            guard profileWrites.isQuiet(since: token) else {
                rereadProfileAfterWrites = true
                rereadProfileIfWritesSettled()
                return
            }
            apply(fetched)
        } catch {
            if QuotedError(error) == .notSignedIn, activeUserID == id, shouldEndRejectedSession {
                await endRejectedSession()
            }
        }
    }

    /// Shows and caches a freshly read account and the profile it holds.
    private func apply(_ fetched: MyAccount) {
        account = fetched
        profile = fetched.profile
        preferences.cacheProfile(fetched.profile)
        preferences.cacheAccount(fetched)
    }

    /// Re-reads the profile when a read was dropped or a write failed, once no profile write runs.
    private func rereadProfileIfWritesSettled() {
        guard rereadProfileAfterWrites, profileWrites.isIdle, let id = activeUserID else { return }
        rereadProfileAfterWrites = false
        Task { await refreshProfile(userID: id) }
    }

    /// Local cleanup after sign-out, session expiry or account deletion. Reminder settings are per
    /// device and survive everything but account deletion.
    private func endSession(accountDeleted: Bool) async {
        let endedUserID = activeUserID ?? userID
        activeUserID = nil
        rereadProfileAfterWrites = false
        toasts.reset()
        library.reset()
        social.reset()
        starter.reset()
        catalog.reset()
        recentSearches.clear()
        router.reset()
        if let endedUserID {
            preferences.removeUserData(userID: endedUserID, includingOnboarding: accountDeleted)
            if recoveringUserID == endedUserID { recoveringUserID = nil }
        }
        userID = nil
        email = nil
        isAnonymous = false
        profile = nil
        account = nil
        launchError = nil
        phase = .signedOut

        await reminders.cancelAll()
        await InboxAlerts.reset()
        // A cache write queued before the reset must land before the wipe, or it would leave this
        // user's library and inbox in the App Group. No new one is queued after `library.reset()`.
        await library.waitForCacheWrites()
        appGroup?.wipeAll()
        reminders.reset(keepingSettings: !accountDeleted)
        widgets.reloadTimelines()
        // Builds before the backend's no-cache URL session wrote responses (tokens, library, inbox) to
        // `URLCache.shared`.
        Backend.purgeHTTPCaches()
    }

    // MARK: Previews

    /// Seeds state for SwiftUI previews.
    func seedPreview(phase: SessionPhase, profile: Profile?, email: String?) {
        self.phase = phase
        self.profile = profile
        account = profile.map {
            MyAccount(id: $0.id, username: $0.username, displayName: $0.displayName, termsVersion: 1, currentTermsVersion: 1)
        }
        self.userID = profile?.id
        self.email = email
    }
}
