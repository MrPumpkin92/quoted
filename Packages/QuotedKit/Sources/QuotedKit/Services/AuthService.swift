import Foundation
import QuotedCore
import Supabase

/// The outcome of ``AuthService/signUp(email:password:)``.
public enum SignUpResult: Hashable, Sendable {
    /// Email confirmation is off (or already done): the user is signed in.
    case signedIn(userID: UUID)
    /// A confirmation email was sent. The link opens `quoted://auth-callback`; pass it to
    /// ``AuthService/handle(url:)``.
    case confirmationRequired(email: String)
}

/// The outcome of ``AuthService/handle(url:)``.
public enum AuthCallbackResult: Hashable, Sendable {
    /// An email-confirmation link: the user is signed in.
    case signedIn(UUID)
    /// A password-reset link: the user is signed in with a recovery session and should choose a new
    /// password now (``AuthService/updatePassword(_:)``).
    case passwordRecovery(UUID)

    /// The signed-in user's ID.
    public var userID: UUID {
        switch self {
        case .signedIn(let id), .passwordRecovery(let id): id
        }
    }
}

/// Email and password accounts through Supabase Auth.
public struct AuthService: Sendable {
    let client: SupabaseClient
    /// Where the SDK keeps the session, and the key it uses.
    let storage: any AuthLocalStorage
    let storageKey: String

    /// The signed-in user's ID from the stored session (no network). The session may be expired;
    /// the SDK refreshes it before the next request.
    public var currentUserID: UUID? { client.signedInUserID }

    /// The signed-in user's email, if any. Nil for an anonymous account (GoTrue sends `""` for it).
    public var currentEmail: String? {
        guard let email = client.auth.currentUser?.email, !email.isEmpty else { return nil }
        return email
    }

    /// Whether the stored session belongs to an anonymous account (no email or password).
    public var isAnonymous: Bool { client.auth.currentUser?.isAnonymous ?? false }

    /// Creates an anonymous account and signs it in (`POST /auth/v1/signup` with no email). The
    /// session is stored like any other and ``sessionChanges`` reports the new user. Needs "Allow
    /// anonymous sign-ins" on the project, otherwise throws a ``QuotedError/validation(_:)`` saying so.
    @discardableResult
    public func signInAnonymously() async throws -> UUID {
        try await mappingErrors {
            try await client.auth.signInAnonymously().user.id
        }
    }

    /// Signs up. Sends `quoted://auth-callback` as the confirmation redirect.
    public func signUp(email: String, password: String) async throws -> SignUpResult {
        let email = try Self.cleanEmail(email)
        try Self.checkPassword(password)
        return try await mappingErrors {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                redirectTo: DeepLink.authCallbackURL
            )
            if let session = response.session {
                return .signedIn(userID: session.user.id)
            }
            return .confirmationRequired(email: email)
        }
    }

    /// Signs in and returns the user's ID.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> UUID {
        let email = try Self.cleanEmail(email)
        try Self.checkPassword(password)
        return try await mappingErrors {
            try await client.auth.signIn(email: email, password: password).user.id
        }
    }

    /// Signs out this device. The local session is removed first, so a network failure while
    /// telling the server is not reported as an error.
    public func signOut() async throws {
        do {
            try await client.auth.signOut(scope: .local)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if client.auth.currentSession == nil { return }
            throw QuotedError(error)
        }
    }

    /// Signed-in user changes: the stored user (or nil) first, then a value on each sign-in,
    /// sign-out or account switch. Consecutive duplicates (token refreshes) are dropped.
    public var sessionChanges: AsyncStream<UUID?> {
        let changes = client.auth.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                var last: UUID??
                for await change in changes {
                    let id = Self.userID(after: change.event, session: change.session)
                    if last != .some(id) {
                        last = .some(id)
                        continuation.yield(id)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Completes an email-confirmation or password-reset deep link (`quoted://auth-callback…`) and
    /// says which it was. Other URLs throw ``QuotedError/validation(_:)``.
    ///
    /// With PKCE, GoTrue redirects both kinds of link with only a `code`, and supabase-swift reports
    /// `passwordRecovery` only for implicit-flow links. A reset is recognised by the new session's
    /// `amr` claim (`[{"method":"recovery",…}]`, set by GoTrue for a session issued from a recovery
    /// link) or a `type=recovery` parameter in the URL.
    @discardableResult
    public func handle(url: URL) async throws -> AuthCallbackResult {
        guard case .authCallback = DeepLink.parse(url) else {
            throw QuotedError.validation("This isn't a sign-in link.")
        }
        let session = try await mappingErrors {
            try await client.auth.session(from: url)
        }
        return Self.isPasswordRecovery(url: url, accessToken: session.accessToken)
            ? .passwordRecovery(session.user.id)
            : .signedIn(session.user.id)
    }

    /// Removes the stored session (and any pending PKCE verifier) from this device without a network
    /// call, and returns whether no session is left.
    ///
    /// For the first launch after an install: Keychain items outlive the app, so a reinstall would
    /// otherwise sign the previous user back in. Call it before reading ``currentUserID`` or
    /// subscribing to ``sessionChanges``; it does not emit a sign-out on ``sessionChanges`` (use
    /// ``signOut()`` to end a live session). The server-side session is not revoked, but its refresh
    /// token existed only in the deleted copy, so nothing can use it.
    @discardableResult
    public func clearLocalSession() -> Bool {
        if let keychain = storage as? DeviceKeychainStorage {
            try? keychain.removeAll()
        }
        // The session, the PKCE verifier, and the key older SDK versions used.
        for key in [storageKey, "\(storageKey)-code-verifier", "supabase.session"] {
            try? storage.remove(key: key)
        }
        return client.auth.currentSession == nil
    }

    /// Sends a password-reset email whose link opens `quoted://auth-callback`.
    public func sendPasswordReset(email: String) async throws {
        let email = try Self.cleanEmail(email)
        try await mappingErrors {
            try await client.auth.resetPasswordForEmail(email, redirectTo: DeepLink.authCallbackURL)
        }
    }

    /// Sets a new password for the signed-in user (after a password-reset link).
    public func updatePassword(_ password: String) async throws {
        try Self.checkPassword(password)
        try await mappingErrors {
            _ = try await client.auth.update(user: UserAttributes(password: password))
        }
    }

    // MARK: Helpers

    static func userID(after event: AuthChangeEvent, session: Session?) -> UUID? {
        switch event {
        case .signedOut, .userDeleted: nil
        default: session?.user.id
        }
    }

    /// Whether a callback produced a password-recovery session: `type=recovery` in the URL's query or
    /// fragment, or a `recovery` entry in the access token's `amr` claim.
    static func isPasswordRecovery(url: URL, accessToken: String) -> Bool {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if let fragment = components.fragment {
                var fragmentComponents = URLComponents()
                fragmentComponents.query = fragment
                items += fragmentComponents.queryItems ?? []
            }
            if items.contains(where: { $0.name == "type" && $0.value == "recovery" }) { return true }
        }
        return authenticationMethods(in: accessToken).contains("recovery")
    }

    /// The `amr[].method` values of a JWT, read without verifying it (the token came straight from
    /// Auth over TLS, and the result only picks which screen to show).
    static func authenticationMethods(in jwt: String) -> [String] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [] }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONDecoder().decode(AMRClaims.self, from: data)
        else { return [] }
        return claims.amr?.map(\.method) ?? []
    }

    private struct AMRClaims: Decodable {
        /// GoTrue writes `{"method": "...", "timestamp": ...}`; RFC 8176 allows a bare string.
        struct Entry: Decodable {
            var method: String

            enum CodingKeys: String, CodingKey {
                case method
            }

            init(from decoder: any Decoder) throws {
                if let single = try? decoder.singleValueContainer().decode(String.self) {
                    method = single
                } else {
                    method = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .method)
                }
            }
        }

        var amr: [Entry]?
    }

    static func cleanEmail(_ email: String) throws(QuotedError) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .validation("Enter your email address.") }
        guard trimmed.contains("@"), !trimmed.contains(" ") else {
            throw .validation("Check your email address.")
        }
        return trimmed
    }

    static func checkPassword(_ password: String) throws(QuotedError) {
        guard !password.isEmpty else { throw .validation("Enter your password.") }
    }
}
