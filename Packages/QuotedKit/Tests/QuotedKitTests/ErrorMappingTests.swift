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

    @Test func serverWriteLimitsReadAsLimits() {
        #expect(QuotedError(PostgrestError(code: "QR001", message: "slow down"))
            == .validation("You've reached today's limit for this. Try again tomorrow."))
        #expect(QuotedError(PostgrestError(code: "QR002", message: "limit"))
            == .validation("You've reached the limit for your account."))
        #expect(QuotedError.map(PostgrestError(code: "QR002", message: "limit"), postgrest: QuotesRepository.quoteLimitError)
            == .validation("You've reached the limit of \(Limits.quotesPerAccount.formatted()) quotes."))
    }

    /// The server names its limits for people; the ui-spec words a few of them its own way.
    @Test(arguments: [
        ("QR001", "You can post at most 20 quotes a day.", "You can post at most 20 quotes a day."),
        ("QR001", "You can send at most 300 messages a day.", "You can send at most 300 messages a day."),
        ("QR001", "You can send at most 20 friend requests a day.", "You can send at most 20 friend requests a day."),
        ("QR001", "You can make at most 20 playlists a day.", "You can make 20 playlists a day. Try again tomorrow."),
        ("QR002", "Quoted keeps circles to 150 friends.", "Quoted keeps circles to 150 friends."),
        ("QR002", "You can keep at most 100 playlists.", "You can keep up to 100 playlists. Delete one to make another."),
        ("QR002", "A playlist can hold at most 200 quotes.", "A playlist holds up to 200 quotes."),
    ])
    func namedLimits(code: String, message: String, expected: String) {
        #expect(QuotedError(PostgrestError(code: code, message: message)) == .validation(expected))
    }

    @Test func wordFilterAndTextsOff() {
        let qr003 = PostgrestError(code: "QR003", message: "Quoted doesn't allow some words in posts and messages.")
        #expect(QuotedError(qr003) == .blockedWords("Quoted doesn't allow some words in posts and messages."))
        #expect(QuotedError(qr003).userMessage == QuotedError.blockedWordsInPostsAndMessages)
        // The same refusal names its field where the field is known.
        #expect(QuotedError.map(qr003, postgrest: ProfilesRepository.profileError) == .blockedWords("Quoted doesn't allow some words in names."))
        #expect(QuotedError.map(qr003, postgrest: PlaylistsRepository.playlistError)
            == .blockedWords("Quoted doesn't allow some words in playlist titles."))
        #expect(QuotedError(PostgrestError(code: "QR004", message: "This friend receives quotes only.")) == .textsOff)
        // The composer knows the friend: the ui-spec toast names them (Conversation, Texts off).
        #expect(QuotedError.textsOffMessage(handle: "@alice") == "@alice receives quotes only. Attach a quote to send it with a note.")
        #expect(QuotedError.textsOffMessage(handle: "alice") == "@alice receives quotes only. Attach a quote to send it with a note.")
        // Without a handle (an error mapped far from the composer), the generic wording.
        #expect(QuotedError.textsOff.userMessage == "This friend receives quotes only. Attach a quote to send it with a note.")
    }

    @Test func termsAndSuspensionComeFirstForEveryCall() {
        let terms = PostgrestError(code: "42501", message: "Accept the Terms of use first.")
        let suspended = PostgrestError(code: "42501", message: "This account is suspended.")
        #expect(QuotedError(terms) == .termsRequired)
        #expect(QuotedError(suspended) == .suspended)
        // Even where 42501 otherwise reads as "no such user" (a friend request to a blocked pair).
        #expect(QuotedError.map(terms, postgrest: SocialRepository.friendRequestError) == .termsRequired)
        #expect(QuotedError.map(suspended, postgrest: SocialRepository.friendRequestError) == .suspended)
        #expect(QuotedError.map(terms, postgrest: PostsRepository.postError) == .termsRequired)
        #expect(QuotedError.suspended.userMessage == "You can't send messages right now. Contact support in Settings.")
        #expect(QuotedError.termsRequired.userMessage == "Accept the Terms of Use first.")
    }

    /// The server's own 42501 refusals are written for people and reach them as they are.
    @Test(arguments: [
        ("This conversation is closed.", QuotedError.conversationClosed),
        ("This conversation is not available.", .unavailable("This conversation is not available.")),
        ("This quote is not available.", .unavailable("This quote is not available.")),
        ("This person is not available.", .unavailable("This person is not available.")),
        ("This playlist is not available.", .unavailable("This playlist is not available.")),
        ("You can send only your own playlists that friends can see.", .validation("You can send only your own playlists that friends can see.")),
        ("This playlist is hidden while it is reviewed.", .validation("This playlist is hidden while it is reviewed.")),
        ("Sign in to save quotes.", .notSignedIn),
    ])
    func serverRefusals(message: String, expected: QuotedError) {
        #expect(QuotedError(PostgrestError(code: "42501", message: message)) == expected)
    }

    @Test func postgresOwnRefusalsStayDiagnostics() {
        for message in [
            "permission denied for table posts",
            #"origin "starter" is set by the server"#,
            "Permission denied",
        ] {
            guard case .server = QuotedError(PostgrestError(code: "42501", message: message)) else {
                Issue.record("expected .server for \(message)")
                continue
            }
        }
        #expect(QuotedError.isWrittenForPeople("This quote is not available."))
        #expect(!QuotedError.isWrittenForPeople("new row violates row-level security policy for table \"messages\""))
    }

    @Test func aDeletedSourceQuoteReadsAsGoneFromTheLibrary() {
        let post = PostgrestError(code: "42501", message: "You can post only quotes from your Library or the Quoted Catalog.")
        #expect(QuotedError.map(post, postgrest: PostsRepository.postError) == .unavailable("That quote is no longer in your library."))
        let message = PostgrestError(code: "42501", message: "You can send only quotes from your Library or the Quoted Catalog.")
        #expect(QuotedError.map(message, postgrest: MessagesRepository.sendError) == .unavailable("That quote is no longer in your library."))
        let item = PostgrestError(code: "42501", message: #"new row violates row-level security policy for table "playlist_items""#)
        #expect(QuotedError.map(item, postgrest: PlaylistsRepository.itemError) == .unavailable("That quote is no longer in your library."))
    }

    @Test func termsVersionErrors() {
        #expect(QuotedError.map(PostgrestError(code: "22023", message: "Unknown terms version."), postgrest: ProfilesRepository.termsError)
            == .validation("The Terms of Use were just updated. Read them again, then accept."))
        #expect(QuotedError.map(PostgrestError(code: "P0002", message: "Choose a username before accepting the terms."), postgrest: ProfilesRepository.termsError)
            == .validation("Choose a username first."))
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
        #expect(QuotedError.map(taken, postgrest: ProfilesRepository.profileError) == .usernameTaken)

        let existing = PostgrestError(code: "23505", message: #"duplicate key value violates unique constraint "profiles_pkey""#)
        #expect(QuotedError.map(existing, postgrest: ProfilesRepository.profileError) == .validation("You already have a username."))
        // A reserved or retired name reads as taken.
        let reserved = PostgrestError(code: "23505", message: #"username "support" is reserved"#)
        #expect(QuotedError.map(reserved, postgrest: ProfilesRepository.profileError) == .usernameTaken)

        // Other codes fall through to the defaults.
        #expect(QuotedError.map(PostgrestError(code: "PGRST116", message: ""), postgrest: ProfilesRepository.profileError) == .notFound)
    }

    @Test func friendRequestOverride() {
        let override = SocialRepository.friendRequestError
        #expect(QuotedError.map(PostgrestError(code: "23505", message: ""), postgrest: override)
            == .validation("You're already friends, or a request is already waiting."))
        // A block reads like an unknown username, so it can't be detected.
        #expect(QuotedError.map(PostgrestError(code: "42501", message: ""), postgrest: override) == .notFound)
        #expect(QuotedError.map(PostgrestError(code: "23514", message: ""), postgrest: override)
            == .validation("You can't add yourself."))
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
        #expect(QuotedError(SocialTextError.captionTooLong(maximum: 280)) == .validation("Shorten the caption to 280 characters."))
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
        for error in [
            QuotedError.network, .notSignedIn, .usernameTaken, .notFound, .rateLimited, .server("x"), .termsRequired,
            .suspended, .blockedWords("b"), .textsOff, .conversationClosed, .unavailable("u"),
        ] {
            #expect(!error.userMessage.isEmpty)
        }
    }
}
