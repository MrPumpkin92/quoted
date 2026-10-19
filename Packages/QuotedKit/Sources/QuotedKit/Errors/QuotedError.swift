import Foundation
import QuotedCore
import Supabase

/// Every error a QuotedKit repository throws, apart from `CancellationError`, which passes through
/// untouched so a cancelled task never shows a toast.
///
/// Show ``userMessage`` to the user. The `String` payloads of ``validation(_:)`` are already
/// user-facing; the payload of ``server(_:)`` is a diagnostic for logs, not for display.
public enum QuotedError: Error, Hashable, Sendable {
    /// The request never reached the server (offline, timed out, DNS, TLS).
    case network
    /// There is no session, or the server rejected it. Send the user back to sign in.
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

    /// A short, friendly message for an alert or toast.
    public var userMessage: String {
        switch self {
        case .network:
            "You seem to be offline. Check your connection and try again."
        case .notSignedIn:
            "Your session has ended. Please sign in again."
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
        }
    }
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
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return .network }
            return .server(error.localizedDescription)
        }
    }

    typealias PostgrestOverride = @Sendable (PostgrestError) -> QuotedError?

    /// Postgres SQLSTATE and PostgREST `PGRST…` codes.
    static func map(postgrest error: PostgrestError) -> QuotedError {
        switch error.code {
        case "23505":
            return .validation("That already exists.")
        case "23514", "23502", "22001", "22P02":
            return .validation("Some of the details aren't valid. Check them and try again.")
        case "23503":
            return .notFound
        case "42501":
            return .server("Permission denied: \(error.message)")
        case "PGRST116":
            return .notFound
        case "PGRST301", "PGRST302", "PGRST303":
            return .notSignedIn
        default:
            return .server(error.code.map { "\($0): \(error.message)" } ?? error.message)
        }
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
            if (400..<500).contains(status), !message.isEmpty, message != "Unexpected error" {
                return .validation(message)
            }
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
}
