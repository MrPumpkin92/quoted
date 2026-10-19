import Foundation
import Observation
import OSLog
import QuotedCore
import QuotedKit

/// Where the user is in the app's lifecycle. `RootView` switches on it.
enum SessionPhase: Hashable, Sendable {
    /// Restoring the session at launch (Ground + wordmark; `launchError` offers a retry).
    case launching
    /// No session: `AuthFlowView`.
    case signedOut
    /// Signed in without a profile: `UsernameView`.
    case needsUsername
    /// Profile done, starter pack not yet: `StarterFlowView(mode: .onboarding)`.
    case needsStarter
    /// The main tabs.
    case ready
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
    private(set) var phase: SessionPhase = .launching
    /// The signed-in user's ID.
    private(set) var userID: UUID?
    /// The signed-in user's email.
    private(set) var email: String?
    /// The signed-in user's profile (username and display name). Nil before a username is chosen.
    private(set) var profile: Profile?
    /// Set after `signUp` when the server sent a confirmation email: show "Check your inbox".
    private(set) var pendingConfirmationEmail: String?
    /// A launch failure (offline on first launch after sign-in). The launch screen offers `retryLaunch()`.
    private(set) var launchError: String?
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
    @ObservationIgnored private let recentSearches: RecentSearches
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let widgets: WidgetBridge
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// The user whose session is starting or started; guards against double starts.
    @ObservationIgnored private var activeUserID: UUID?

    init(
        backend: Backend,
        appGroup: AppGroupStore?,
        library: LibraryStore,
        social: SocialStore,
        reminders: ReminderStore,
        starter: StarterStore,
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

    /// Retries a launch that failed (`launchError`).
    func retryLaunch() async {
        guard let id = activeUserID ?? backend.auth.currentUserID else {
            launchError = nil
            phase = .signedOut
            return
        }
        activeUserID = nil
        launchError = nil
        await beginSession(userID: id)
    }

    // MARK: Auth

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
            return try await backend.social.isUsernameAvailable(username)
        } catch {
            throw QuotedError(error)
        }
    }

    /// Creates the profile (Username screen). Throws `.usernameTaken` or `.validation`. On success the
    /// phase moves to the starter pack (or straight to the library if the user already has quotes).
    func createProfile(username: String, displayName: String?) async throws(QuotedError) {
        let created: Profile
        do {
            created = try await backend.social.createProfile(username: username, displayName: displayName)
        } catch {
            throw QuotedError(error)
        }
        profile = created
        preferences.cacheProfile(created)
        guard let id = userID else { return }
        await resolvePhaseAfterProfile(userID: id)
    }

    /// Changes the display name (blank clears it, showing the username).
    func updateDisplayName(_ displayName: String?) async throws(QuotedError) {
        let updated: Profile
        do {
            updated = try await backend.social.updateDisplayName(displayName)
        } catch {
            throw QuotedError(error)
        }
        profile = updated
        preferences.cacheProfile(updated)
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
    func signOut() async {
        let assertion = BackgroundTaskAssertion("Sign out")
        defer { assertion.end() }
        await toasts.flushPending()
        do {
            try await backend.auth.signOut()
        } catch {
            toasts.show(error: error)
            return
        }
        await endSession(accountDeleted: false)
    }

    /// Permanently deletes the account on the server, then cleans up like `signOut()` and also resets
    /// the reminder settings and this user's onboarding flag. Throws `QuotedError` (the account stays)
    /// so the Account screen can show it.
    ///
    /// Safe to retry: when an earlier attempt deleted the account but its answer was lost, QuotedKit
    /// confirms the user is gone and this returns normally. `.notSignedIn` means the session can no
    /// longer be used while the account may still exist: the app then signs out on this device (with a
    /// toast asking to sign in again) and rethrows. Runs under background time.
    func deleteAccount() async throws(QuotedError) {
        let assertion = BackgroundTaskAssertion("Delete account")
        defer { assertion.end() }
        await toasts.flushPending()
        let deletedUserID = userID
        do {
            try await backend.account.deleteAccount()
        } catch {
            let mapped = QuotedError(error)
            if mapped == .notSignedIn {
                // An unusable session: every request would fail. Sign out so the user can sign in
                // again and delete from there.
                try? await backend.auth.signOut()
                await endSession(accountDeleted: false)
                toasts.show("Your session has ended. Sign in again to delete your account.", style: .error)
            }
            throw mapped
        }
        // The local sign-out inside deleteAccount() may already have ended the session through the
        // session stream, so remove this user's flags explicitly.
        if let deletedUserID {
            preferences.removeUserData(userID: deletedUserID, includingOnboarding: true)
        }
        await endSession(accountDeleted: true)
    }

    // MARK: Private

    private func handleSessionChange(_ userID: UUID?) async {
        if let userID {
            await beginSession(userID: userID)
        } else if activeUserID != nil || phase != .signedOut {
            Logger.session.info("Session ended")
            await endSession(accountDeleted: false)
        }
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
        launchError = nil
        pendingConfirmationEmail = nil
        library.prepare(for: id)

        if let cached = preferences.cachedProfile(userID: id) {
            profile = cached
            await resolvePhaseAfterProfile(userID: id)
            await refreshProfile(userID: id)
            return
        }

        do {
            let fetched = try await backend.social.myProfile()
            guard activeUserID == id else { return }
            if let fetched {
                profile = fetched
                preferences.cacheProfile(fetched)
                await resolvePhaseAfterProfile(userID: id)
            } else {
                phase = .needsUsername
            }
        } catch {
            guard activeUserID == id else { return }
            let mapped = QuotedError(error)
            if mapped == .notSignedIn {
                await endSession(accountDeleted: false)
                return
            }
            Logger.session.error("Profile load failed: \(String(describing: mapped), privacy: .public)")
            launchError = ToastCenter.message(for: mapped) ?? mapped.userMessage
            phase = .launching
        }
    }

    /// Ready if onboarding is done or the user already has quotes; otherwise the starter pack.
    ///
    /// Without the onboarding flag (a new device, or a reinstall that kept the Keychain session) an
    /// empty library is checked with the server. If that check fails, the user may well have quotes,
    /// so the launch screen shows the error with "Try again" instead of the starter pack.
    private func resolvePhaseAfterProfile(userID id: UUID) async {
        if preferences.hasCompletedOnboarding(userID: id) {
            enterReady()
            return
        }
        if library.isEmpty {
            let answered = await library.refresh()
            guard activeUserID == id else { return }
            if !answered, library.isEmpty {
                let error = library.lastError ?? .network
                if error == .notSignedIn {
                    await endSession(accountDeleted: false)
                    return
                }
                Logger.session.error("Library check failed: \(String(describing: error), privacy: .public)")
                launchError = ToastCenter.message(for: error) ?? error.userMessage
                phase = .launching
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
        do {
            guard let fetched = try await backend.social.myProfile(), activeUserID == id else { return }
            profile = fetched
            preferences.cacheProfile(fetched)
        } catch {
            if QuotedError(error) == .notSignedIn, activeUserID == id {
                await endSession(accountDeleted: false)
            }
        }
    }

    /// Local cleanup after sign-out, session expiry or account deletion. Reminder settings are per
    /// device and survive everything but account deletion.
    private func endSession(accountDeleted: Bool) async {
        let endedUserID = activeUserID ?? userID
        activeUserID = nil
        toasts.reset()
        library.reset()
        social.reset()
        starter.reset()
        recentSearches.clear()
        router.reset()
        if let endedUserID {
            preferences.removeUserData(userID: endedUserID, includingOnboarding: accountDeleted)
            if recoveringUserID == endedUserID { recoveringUserID = nil }
        }
        userID = nil
        email = nil
        profile = nil
        launchError = nil
        phase = .signedOut

        await reminders.cancelAll()
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
        self.userID = profile?.id
        self.email = email
    }
}
