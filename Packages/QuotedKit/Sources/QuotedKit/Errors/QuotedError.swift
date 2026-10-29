import Foundation
import QuotedCore
import Supabase

/// Every error a QuotedKit repository throws, apart from `CancellationError`, which passes through
/// untouched so a cancelled task never shows a toast.
///
/// Show ``userMessage`` to the user. The `String` payloads of ``validation(_:)``,
/// ``blockedWords(_:)`` and ``unavailable(_:)`` are already user-facing; the payload of
/// ``server(_:)`` is a diagnostic for logs, not for display.
///
/// The server writes its own refusals for people (a capital letter, a full stop: "This quote is not
/// available."), so those reach the user as they are; Postgres's own messages ("permission denied
/// for table …") never do.
public enum QuotedError: Error, Hashable, Sendable {
    /// The request never reached the server (offline, timed out, DNS, TLS).
    case network
    /// There is no session, or the server rejected it. The app ends the session (email accounts sign
    /// in again; an anonymous account is replaced once the SDK has dropped it).
    case notSignedIn
    /// `profiles.username` is already in use.
    case usernameTaken
    /// The row (or username) does not exist, or is not visible to this user.
    case notFound
    /// The input or the action was rejected. The message is user-facing.
    case validation(String)
    /// Too many requests. Ask the user to wait a moment.
    case rateLimited
    /// Anything else. The message is a diagnostic, not user-facing.
    case server(String)
    /// The current Terms of Use aren't accepted yet (42501 "Accept the Terms of use first."). Every
    /// social write answers this first: show the Terms sheet, call `accept_terms`, then retry.
    case termsRequired
    /// The account is suspended (42501 "This account is suspended."): it can read, not post or send.
    case suspended
    /// QR003: the text holds a word Quoted doesn't allow. The payload is user-facing and names the
    /// field ("…in posts and messages.", "…in names.", "…in playlist titles."). Keep the typed text
    /// and focus its field.
    case blockedWords(String)
    /// QR004: the friend turned off "Friends can text me". Quotes and playlists still go through.
    case textsOff
    /// 42501 "This conversation is closed.": unfriended or blocked. It stays readable, not writable.
    case conversationClosed
    /// The item is gone or hidden from you (deleted, unsent, reported, blocked, unfriended), in the
    /// server's words, for example "This quote is not available.". Show the screen's gone state.
    case unavailable(String)

    /// A short, friendly message for an alert or toast.
    public var userMessage: String {
        switch self {
        case .network:
            "You seem to be offline. Check your connection and try again."
        case .notSignedIn:
            // Not "sign in again": an anonymous account has no sign-in. The app ends or replaces the
            // session itself (SessionStore).
            "Your session has ended. Try again in a moment."
        case .usernameTaken:
            "That username is taken. Try another one."
        case .notFound:
            "We couldn't find that. It may have been removed."
        case .validation(let message):
            message
        case .rateLimited:
            "Too many tries. Wait a moment and try again."
        case .server:
            "Something went wrong. Please try again."
        case .termsRequired:
            "Accept the Terms of Use first."
        case .suspended:
            "You can't send messages right now. Contact support in Settings."
        case .blockedWords(let message):
            message
        case .textsOff:
            // Without the friend's handle; the composer, which knows it, uses textsOffMessage(handle:).
            "This friend receives quotes only. Attach a quote to send it with a note."
        case .conversationClosed:
            "This conversation is closed."
        case .unavailable(let message):
            message
        }
    }

    /// The QR004 toast with the friend's handle (docs/ui-spec.md, Conversation: "@alice receives
    /// quotes only. Attach a quote to send it with a note."). `handle` is "@alice" or "alice".
    /// ``userMessage`` of ``textsOff`` is the fallback when no handle is at hand.
    public static func textsOffMessage(handle: String) -> String {
        let name = handle.hasPrefix("@") ? handle : "@\(handle)"
        return "\(name) receives quotes only. Attach a quote to send it with a note."
    }

    /// The QR003 message for posts and messages (the server's own text).
    public static let blockedWordsInPostsAndMessages = "Quoted doesn't allow some words in posts and messages."
    /// The QR003 message for display names and usernames.
    public static let blockedWordsInNames = "Quoted doesn't allow some words in names."
    /// The QR003 message for playlist titles.
    public static let blockedWordsInPlaylistTitles = "Quoted doesn't allow some words in playlist titles."
}

extension QuotedError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

// MARK: Mapping

extension QuotedError {
    /// Maps any error from the Supabase SDK, URLSession, decoding or QuotedCore validation to a
    /// ``QuotedError``. A `QuotedError` maps to itself.
    public init(_ error: any Error) {
        self = Self.map(error, postgrest: nil)
    }

    /// The mapping, with an optional per-call override for PostgREST errors (return nil to fall
    /// back to the defaults).
    static func map(_ error: any Error, postgrest override: PostgrestOverride?) -> QuotedError {
        switch error {
        case let error as QuotedError:
            return error
        case let error as PostgrestError:
            // Terms and suspension come before every other check on the server, for every call.
            if let account = map(accountRefusal: error) { return account }
            if let override, let mapped = override(error) { return mapped }
            return map(postgrest: error)
        case let error as AuthError:
            return map(auth: error)
        case let error as FunctionsError:
            return map(functions: error)
        case let error as HTTPError:
            return map(status: error.response.statusCode, detail: String(decoding: error.data, as: UTF8.self))
        case is URLError:
            return .network
        case is DecodingError:
            return .server("Unexpected response from the server: \(error)")
        case is EncodingError:
            return .server("Could not encode the request: \(error)")
        case let error as QuoteDraftError:
            return .validation(error.errorDescription ?? "Check the quote and try again.")
        case let error as UsernameError:
            return .validation(error.errorDescription ?? "Choose a different username.")
        case let error as DisplayNameError:
            return .validation(error.errorDescription ?? "Choose a different name.")
        case let error as SocialTextError:
            return .validation(error.errorDescription ?? "Check the text and try again.")
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return .network }
            return .server(error.localizedDescription)
        }
    }

    typealias PostgrestOverride = @Sendable (PostgrestError) -> QuotedError?

    /// The account-level refusals every social write gives before anything else (terms, suspension).
    static func map(accountRefusal error: PostgrestError) -> QuotedError? {
        guard error.code == "42501" else { return nil }
        switch error.message {
        case "Accept the Terms of use first.": return .termsRequired
        case "This account is suspended.": return .suspended
        default: return nil
        }
    }

    /// Postgres SQLSTATE and PostgREST `PGRST…` codes.
    static func map(postgrest error: PostgrestError) -> QuotedError {
        switch error.code {
        // The server's write limits (migration 20261021090000_abuse_limits_privacy_cleanup): QR001 is
        // a rolling 24-hour limit (friend requests, posts, messages, playlists, reports), QR002 an
        // account total. The server names the limit in words for people ("You can post at most 20
        // quotes a day."); a few read better in the app's own words (``limitCopy``).
        case "QR001":
            return .validation(limitCopy[error.message]
                ?? (isWrittenForPeople(error.message) ? error.message : "You've reached today's limit for this. Try again tomorrow."))
        case "QR002":
            return .validation(limitCopy[error.message]
                ?? (isWrittenForPeople(error.message) ? error.message : "You've reached the limit for your account."))
        // The word filter and "Friends can text me" (migrations 20261029090000 and 20261029090300).
        case "QR003":
            return .blockedWords(blockedWordsInPostsAndMessages)
        case "QR004":
            return .textsOff
        case "23505":
            return .validation("That already exists.")
        case "23514", "23502", "22001", "22P02":
            return .validation("Some of the details aren't valid. Check them and try again.")
        case "23503":
            return .notFound
        case "42501":
            return map(refusal: error.message)
        case "PGRST116":
            return .notFound
        case "PGRST301", "PGRST302", "PGRST303":
            return .notSignedIn
        default:
            return .server(error.code.map { "\($0): \(error.message)" } ?? error.message)
        }
    }

    /// Server limit messages the app words its own way (docs/ui-spec.md, States checklist).
    static let limitCopy: [String: String] = [
        "You can make at most 20 playlists a day.": "You can make 20 playlists a day. Try again tomorrow.",
        "You can keep at most 100 playlists.": "You can keep up to 100 playlists. Delete one to make another.",
        "A playlist can hold at most 200 quotes.": "A playlist holds up to 200 quotes.",
    ]

    /// 42501. The server's own refusals are sentences for people; Postgres's (RLS, grants) are not.
    static func map(refusal message: String) -> QuotedError {
        if message == "Accept the Terms of use first." { return .termsRequired }
        if message == "This account is suspended." { return .suspended }
        if message == "This conversation is closed." { return .conversationClosed }
        if message.hasPrefix("Sign in to ") { return .notSignedIn }
        guard isWrittenForPeople(message) else { return .server("Permission denied: \(message)") }
        return message.hasSuffix(" is not available.") ? .unavailable(message) : .validation(message)
    }

    /// Whether a server message was written for people: it starts with a capital letter and ends
    /// with a full stop. Postgres's own messages start lowercase and have no full stop.
    static func isWrittenForPeople(_ message: String) -> Bool {
        guard let first = message.unicodeScalars.first, message.hasSuffix(".") else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    static func map(auth error: AuthError) -> QuotedError {
        switch error {
        case .sessionMissing, .refreshDiscarded, .jwtVerificationFailed:
            return .notSignedIn
        case .weakPassword(let message, _):
            return .validation(message.isEmpty ? "Choose a stronger password." : message)
        case .pkceGrantCodeExchange, .implicitGrantRedirect:
            return .validation("This link has expired or was already used. Try signing in.")
        case .api(let message, let code, _, let response):
            return map(authAPI: code, message: message, status: response.statusCode)
        default:
            return .server(error.message)
        }
    }

    static func map(authAPI code: ErrorCode, message: String, status: Int) -> QuotedError {
        switch code {
        case .overRequestRateLimit, .overEmailSendRateLimit, .overSMSSendRateLimit:
            return .rateLimited
        case .invalidCredentials:
            return .validation("That email and password don't match.")
        case .emailExists, .userAlreadyExists:
            return .validation("There's already an account with that email. Try signing in.")
        case .emailNotConfirmed:
            return .validation("Confirm your email first. Check your inbox for the link.")
        case .weakPassword:
            return .validation(message.isEmpty ? "Choose a stronger password." : message)
        case .samePassword:
            return .validation("Choose a password you haven't used here before.")
        case .signupDisabled, .emailProviderDisabled:
            return .validation("New sign-ups are turned off right now.")
        case .anonymousProviderDisabled:
            return .validation("Quoted can't create your account right now: anonymous sign-ins are turned off on the server.")
        case .flowStateNotFound, .flowStateExpired, .otpExpired, .badCodeVerifier:
            return .validation("This link has expired or was already used. Try signing in.")
        case .sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed,
             .badJWT, .invalidJWT, .noAuthorization, .userNotFound:
            return .notSignedIn
        case .validationFailed, .emailAddressInvalid:
            return .validation(message.isEmpty ? "Check your email address." : message)
        default:
            if status == 429 { return .rateLimited }
            if status == 401 { return .notSignedIn }
            // Anything else keeps GoTrue's English text for the logs only: it is written for
            // developers (captcha_failed, user_banned, …) and is not localized.
            return .server("Auth \(status) \(code.rawValue): \(message)")
        }
    }

    static func map(functions error: FunctionsError) -> QuotedError {
        switch error {
        case .relayError:
            return .server("Edge Function relay error")
        case .httpError(let code, let data):
            return map(status: code, detail: String(decoding: data, as: UTF8.self))
        }
    }

    /// Maps a bare HTTP status (no structured error body).
    static func map(status: Int, detail: String) -> QuotedError {
        switch status {
        case 401: .notSignedIn
        case 404: .notFound
        case 429: .rateLimited
        default: .server("HTTP \(status): \(detail.prefix(200))")
        }
    }
}

extension ErrorCode {
    /// GoTrue's code for a malformed email address (not in the SDK's list of known codes).
    fileprivate static let emailAddressInvalid = ErrorCode("email_address_invalid")
}

// MARK: Running requests

/// Runs `body`, rethrowing `CancellationError` (and cancelled URL loads as `CancellationError`) and
/// mapping every other error to ``QuotedError``.
@discardableResult
func mappingErrors<T>(
    postgrest override: QuotedError.PostgrestOverride? = nil,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
    } catch {
        throw QuotedError.map(error, postgrest: override)
    }
}

extension PostgrestError {
    /// The constraint named in a Postgres error message, e.g. `profiles_username_key`.
    var constraintName: String? {
        let text = [message, details ?? ""].joined(separator: " ")
        guard let open = text.range(of: "constraint \"") else { return nil }
        let rest = text[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    /// Whether the message or details mention `name` (a constraint or column).
    func mentions(_ name: String) -> Bool {
        message.contains(name) || (details?.contains(name) ?? false) || (hint?.contains(name) ?? false)
    }

    /// Whether a retried insert with a client-chosen id may have landed the first time and only lost
    /// its answer: the primary key refuses it (23505), or a BEFORE INSERT check that runs before the
    /// primary key no longer passes (42501), for example a source quote deleted since, or the
    /// tombstone an Undo used up. Read the row back by id before treating it as a failure.
    var mayHideEarlierInsert: Bool {
        code == "23505" || code == "42501"
    }
}
