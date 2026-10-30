import Foundation
import QuotedCore
import Supabase

/// The onboarding starter pack (`starter_quotes`, read-only): the live starters of the Quoted Catalog
/// (``CatalogRepository``).
public struct StarterRepository: Sendable {
    let client: SupabaseClient

    /// Every starter quote, by `sort_order`.
    public func fetchAll() async throws -> [StarterQuote] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.starterQuotes)
                .select(Columns.starterQuote)
                .order("sort_order")
                .execute()
                .value
        }
    }
}

/// Product analytics. Events are anonymous: only the event name is sent (no user ID, no search
/// term), and the row is never read back.
public struct EventsRepository: Sendable {
    let client: SupabaseClient

    /// Records a tap on "Search the web" in the background. Never throws and never blocks the UI.
    public func logWebSearchTap() {
        let repository = self
        Task(priority: .utility) {
            await repository.logWebSearchTapAndWait()
        }
    }

    /// Records a tap on "Search the web" and reports whether it was stored. Never throws.
    ///
    /// Only signed-in users may insert (the grant is to `authenticated`), but the payload is just
    /// `{"name": "web_search_tap"}`.
    @discardableResult
    public func logWebSearchTapAndWait() async -> Bool {
        guard client.signedInUserID != nil else { return false }
        do {
            // `events` has no select grant, so the insert must not ask for the row back.
            try await client.from(Table.events)
                .insert(EventInsert.webSearchTap, returning: .minimal)
                .execute()
            return true
        } catch {
            return false
        }
    }
}

/// Account-level actions.
public struct AccountService: Sendable {
    let client: SupabaseClient
    let auth: AuthService

    /// The Edge Function that deletes the calling user.
    static let deleteAccountFunction = "delete-account"

    /// Permanently deletes the account (App Store 5.1.1(v)) through the `delete-account` Edge
    /// Function, then signs out locally. Foreign-key cascades remove every row the user owns.
    ///
    /// Safe to retry. If an earlier call deleted the user but its response was lost, the function now
    /// answers 401 (or the SDK can no longer refresh the session). The account then counts as deleted
    /// only when Auth confirms it: `GET /auth/v1/user` with the user's access token answers
    /// `user_not_found`. In that case the local session is removed and this returns normally. Any other
    /// answer keeps the error: ``QuotedError/notSignedIn`` for a session that ended while the user
    /// still exists (or cannot be checked, for example with an expired token), ``QuotedError/network``
    /// offline.
    ///
    /// The caller still wipes the App Group cache and snapshot, removes pending notifications and
    /// calls ``Backend/purgeHTTPCaches()``.
    public func deleteAccount() async throws {
        _ = try client.requireUserID()
        // Kept for the "already deleted" check: a failed refresh below may clear the stored session.
        let storedToken = client.auth.currentSession?.accessToken
        do {
            try await mappingErrors {
                // The SDK sends the user's (refreshed) access token as the bearer.
                try await client.functions.invoke(
                    Self.deleteAccountFunction,
                    options: FunctionInvokeOptions(method: .post)
                )
            }
        } catch QuotedError.notSignedIn {
            // The token the function saw (refreshed if it had expired), or the stored one if the
            // refresh failed and the SDK dropped the session.
            guard let token = client.auth.currentSession?.accessToken ?? storedToken,
                  await isUserGone(accessToken: token)
            else { throw QuotedError.notSignedIn }
        }
        await signOutLocally()
    }

    /// Whether Auth says the user behind `accessToken` no longer exists. Only a definite
    /// `user_not_found` counts; network errors, expired tokens and anything else return false.
    private func isUserGone(accessToken: String) async -> Bool {
        do {
            _ = try await client.auth.user(jwt: accessToken)
            return false
        } catch let AuthError.api(_, code, _, _) {
            return code == .userNotFound
        } catch {
            return false
        }
    }

    /// The user no longer exists: drop the local session. `signOut(scope: .local)` removes it and
    /// emits the sign-out before it calls the server, whose answer (the session is gone) does not
    /// matter; `clearLocalSession()` covers a session the SDK had already dropped.
    private func signOutLocally() async {
        try? await client.auth.signOut(scope: .local)
        auth.clearLocalSession()
    }
}
