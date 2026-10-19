import Foundation
import QuotedCore
import Supabase
import Testing
@testable import QuotedKit

@Suite("Error mapping")
struct ErrorMappingTests {
    func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:54321/auth/v1/token")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func authAPI(_ code: String, status: Int = 400, message: String = "msg") -> AuthError {
        .api(message: message, errorCode: ErrorCode(code), underlyingData: Data(), underlyingResponse: response(status))
    }

    @Test(arguments: [
        ("23505", QuotedError.validation("That already exists.")),
        ("23514", .validation("Some of the details aren't valid. Check them and try again.")),
        ("23502", .validation("Some of the details aren't valid. Check them and try again.")),
        ("23503", .notFound),
        ("PGRST116", .notFound),
        ("PGRST301", .notSignedIn),
        ("PGRST303", .notSignedIn),
    ])
    func postgrestCodes(code: String, expected: QuotedError) {
        #expect(QuotedError(PostgrestError(code: code, message: "m")) == expected)
    }

    @Test func rlsViolationIsAServerErrorByDefault() {
        let error = PostgrestError(code: "42501", message: #"new row violates row-level security policy for table "shares""#)
        guard case .server(let detail) = QuotedError(error) else {
            Issue.record("expected .server")
            return
        }
        #expect(detail.contains("row-level security"))
        #expect(QuotedError(error).userMessage == "Something went wrong. Please try again.")
    }

    @Test func profileOverrideSeparatesUsernameFromPrimaryKey() {
        let taken = PostgrestError(
            details: "Key (username)=(ada) already exists.", code: "23505",
            message: #"duplicate key value violates unique constraint "profiles_username_key""#
        )
        #expect(taken.constraintName == "profiles_username_key")
        #expect(QuotedError.map(taken, postgrest: SocialRepository.profileError) == .usernameTaken)

        let existing = PostgrestError(code: "23505", message: #"duplicate key value violates unique constraint "profiles_pkey""#)
        #expect(QuotedError.map(existing, postgrest: SocialRepository.profileError) == .validation("You already have a username."))

        // Other codes fall through to the defaults.
        #expect(QuotedError.map(PostgrestError(code: "PGRST116", message: ""), postgrest: SocialRepository.profileError) == .notFound)
    }

    @Test func friendRequestOverride() {
        let override = SocialRepository.friendRequestError
        #expect(QuotedError.map(PostgrestError(code: "23505", message: ""), postgrest: override)
            == .validation("You're already friends, or a request is already waiting."))
        #expect(QuotedError.map(PostgrestError(code: "42501", message: ""), postgrest: override)
            == .validation("You can't send a friend request to this person."))
        #expect(QuotedError.map(PostgrestError(code: "23514", message: ""), postgrest: override)
            == .validation("You can't add yourself."))
    }

    @Test func shareOverride() {
        #expect(QuotedError.map(PostgrestError(code: "42501", message: ""), postgrest: SocialRepository.shareError)
            == .validation("You can only share with friends."))
    }

    @Test func authErrors() {
        #expect(QuotedError(AuthError.sessionMissing) == .notSignedIn)
        #expect(QuotedError(AuthError.weakPassword(message: "Password should be at least 6 characters.", reasons: ["length"]))
            == .validation("Password should be at least 6 characters."))
        #expect(QuotedError(authAPI("invalid_credentials")) == .validation("That email and password don't match."))
        #expect(QuotedError(authAPI("user_already_exists", status: 422)) == .validation("There's already an account with that email. Try signing in."))
        #expect(QuotedError(authAPI("email_not_confirmed")) == .validation("Confirm your email first. Check your inbox for the link."))
        #expect(QuotedError(authAPI("over_request_rate_limit", status: 429)) == .rateLimited)
        #expect(QuotedError(authAPI("over_email_send_rate_limit", status: 429)) == .rateLimited)
        #expect(QuotedError(authAPI("something_new", status: 429)) == .rateLimited)
        #expect(QuotedError(authAPI("session_not_found", status: 403)) == .notSignedIn)
        #expect(QuotedError(authAPI("validation_failed", status: 400, message: "Unable to validate email address: invalid format"))
            == .validation("Unable to validate email address: invalid format"))
        #expect(QuotedError(authAPI("unexpected_failure", status: 500, message: "boom")) == .server("Auth 500 unexpected_failure: boom"))
        #expect(QuotedError(AuthError.pkceGrantCodeExchange(message: "No code detected."))
            == .validation("This link has expired or was already used. Try signing in."))
    }

    @Test func functionsAndHTTPErrors() {
        #expect(QuotedError(FunctionsError.httpError(code: 401, data: Data())) == .notSignedIn)
        #expect(QuotedError(FunctionsError.httpError(code: 429, data: Data())) == .rateLimited)
        #expect(QuotedError(FunctionsError.httpError(code: 500, data: Data(#"{"error":"delete_failed"}"#.utf8)))
            == .server(#"HTTP 500: {"error":"delete_failed"}"#))
        #expect(QuotedError(FunctionsError.relayError) == .server("Edge Function relay error"))
        #expect(QuotedError(HTTPError(data: Data(), response: response(404))) == .notFound)
        #expect(QuotedError(HTTPError(data: Data(), response: response(401))) == .notSignedIn)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost])
    func urlErrorsAreNetwork(code: URLError.Code) {
        #expect(QuotedError(URLError(code)) == .network)
        #expect(QuotedError(URLError(code)).userMessage.contains("offline"))
    }

    @Test func validationAndDecodingErrors() {
        #expect(QuotedError(QuoteDraftError.emptyBody) == .validation("Write the quote first."))
        #expect(QuotedError(UsernameError.tooShort(minimum: 3)) == .validation("Usernames need at least 3 characters."))
        #expect(QuotedError(QuotedError.usernameTaken) == .usernameTaken)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        guard case .server = QuotedError(decoding) else {
            Issue.record("expected .server for a decoding error")
            return
        }
    }

    @Test func cancellationPassesThrough() async {
        await #expect(throws: CancellationError.self) {
            try await mappingErrors { throw URLError(.cancelled) }
        }
        await #expect(throws: CancellationError.self) {
            try await mappingErrors { throw CancellationError() }
        }
        await #expect(throws: QuotedError.network) {
            try await mappingErrors { throw URLError(.notConnectedToInternet) }
        }
    }

    @Test func userMessages() {
        #expect(QuotedError.validation("Custom").userMessage == "Custom")
        #expect(QuotedError.usernameTaken.errorDescription == QuotedError.usernameTaken.userMessage)
        for error in [QuotedError.network, .notSignedIn, .usernameTaken, .notFound, .rateLimited, .server("x")] {
            #expect(!error.userMessage.isEmpty)
        }
    }
}
