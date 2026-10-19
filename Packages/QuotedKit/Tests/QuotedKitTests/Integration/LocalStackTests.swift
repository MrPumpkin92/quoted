import Foundation
import QuotedCore
import Testing
@testable import QuotedKit

/// End-to-end tests against the local Supabase stack (`supabase start`). They run only with
/// `QUOTED_LOCAL_SUPABASE=1 swift test`. Local Auth auto-confirms email, so sign-up signs in.
///
/// Every test signs up throwaway users and deletes them at the end through the `delete-account`
/// Edge Function (FK cascades remove their rows). Auth allows 30 sign-ins and sign-ups per 5 minutes
/// per IP locally, so the suite keeps them to a handful.
@Suite(
    "Local Supabase stack",
    .enabled(if: LocalStack.isEnabled, "Set QUOTED_LOCAL_SUPABASE=1 with `supabase start` running"),
    .serialized
)
struct LocalStackTests {
    @Test func endToEnd() async throws {
        let alice = try await TestUser.signUp("alice")
        let bob: TestUser
        do {
            bob = try await TestUser.signUp("bob")
        } catch {
            await LocalStack.cleanUp([alice])
            throw error
        }
        do {
            try await scenario(alice: alice, bob: bob)
        } catch {
            await LocalStack.cleanUp([alice, bob])
            throw error
        }
        await LocalStack.cleanUp([alice, bob])
    }

    @Test(.enabled("delete-account must be served by the local stack") { await LocalStack.isDeleteAccountServed() })
    func deleteAccountRemovesTheUser() async throws {
        let carol = try await TestUser.signUp("carol")
        let profile = try await carol.social.createProfile(username: carol.username)
        #expect(profile.id == carol.id)
        _ = try await carol.quotes.create(QuoteDraft(body: "Gone soon"))

        try await carol.backend.account.deleteAccount()
        #expect(carol.backend.auth.currentUserID == nil)
        await #expect(throws: QuotedError.notSignedIn) { try await carol.quotes.fetchMine() }
        await #expect(throws: QuotedError.validation("That email and password don't match.")) {
            try await carol.backend.auth.signIn(email: carol.email, password: carol.password)
        }
    }

    /// The PKCE reset link comes back with only a code; `handle(url:)` still reports recovery. Local
    /// Auth sends at most 2 emails an hour, so a rate-limited run returns early instead of failing.
    @Test func passwordResetLinkIsReportedAsRecovery() async throws {
        let dave = try await TestUser.signUp("dave")
        do {
            try await recovery(dave)
        } catch {
            await LocalStack.cleanUp([dave])
            throw error
        }
        await LocalStack.cleanUp([dave])
    }

    private func recovery(_ dave: TestUser) async throws {
        let auth = dave.backend.auth
        try await auth.signOut()
        do {
            try await auth.sendPasswordReset(email: dave.email)
        } catch QuotedError.rateLimited {
            print("[LocalStack] email rate limit reached; skipped the password-reset check")
            _ = try await auth.signIn(email: dave.email, password: dave.password)
            return
        }
        let link = try await LocalStack.resetLink(for: dave.email)
        let callback = try await LocalStack.redirect(from: link)
        #expect(callback.absoluteString.hasPrefix("quoted://auth-callback"))
        #expect(try await auth.handle(url: callback) == .passwordRecovery(dave.id))

        let newPassword = "it-new-\(UUID().uuidString)"
        try await auth.updatePassword(newPassword)
        try await auth.signOut()
        #expect(try await auth.signIn(email: dave.email, password: newPassword) == dave.id)
    }

    // MARK: Scenario

    private func scenario(alice: TestUser, bob: TestUser) async throws {
        try await auth(alice)
        let (aliceProfile, bobProfile) = try await profiles(alice: alice, bob: bob)
        let edited = try await quotes(alice: alice, bob: bob)
        try await starter(alice)
        try await paging(alice)
        try await friends(alice: alice, bob: bob, aliceProfile: aliceProfile, bobProfile: bobProfile, quote: edited)
        let received = try await sharing(alice: alice, bob: bob, quote: edited)
        try await blocking(alice: alice, bob: bob, received: received)
        #expect(await alice.backend.events.logWebSearchTapAndWait())
    }

    private func auth(_ alice: TestUser) async throws {
        let auth = alice.backend.auth
        #expect(auth.currentUserID == alice.id)
        #expect(auth.currentEmail == alice.email)
        var changes = auth.sessionChanges.makeAsyncIterator()
        #expect(await changes.next() == .some(alice.id))

        try await auth.signOut()
        #expect(auth.currentUserID == nil)
        #expect(await changes.next() == .some(nil))

        await #expect(throws: QuotedError.validation("That email and password don't match.")) {
            try await auth.signIn(email: alice.email, password: "not-the-password")
        }
        await #expect(throws: QuotedError.validation("There's already an account with that email. Try signing in.")) {
            _ = try await alice.backend.auth.signUp(email: alice.email, password: alice.password)
        }
        let id = try await auth.signIn(email: " \(alice.email) ", password: alice.password)
        #expect(id == alice.id)
        #expect(await changes.next() == .some(alice.id))
    }

    private func profiles(alice: TestUser, bob: TestUser) async throws -> (Profile, Profile) {
        #expect(try await alice.social.myProfile() == nil)
        #expect(try await alice.social.isUsernameAvailable(alice.username))
        let aliceProfile = try await alice.social.createProfile(username: "@" + alice.username.uppercased(), displayName: " Alice ")
        #expect(aliceProfile == Profile(id: alice.id, username: alice.username, displayName: "Alice"))
        #expect(try await alice.social.myProfile() == aliceProfile)
        #expect(try await alice.social.isUsernameAvailable(alice.username) == false)
        await #expect(throws: QuotedError.validation("You already have a username.")) {
            _ = try await alice.social.createProfile(username: alice.username + "x")
        }

        await #expect(throws: QuotedError.usernameTaken) {
            _ = try await bob.social.createProfile(username: alice.username)
        }
        let bobProfile = try await bob.social.createProfile(username: bob.username)
        #expect(bobProfile.displayName == bob.username)
        #expect(try await bob.social.updateDisplayName("Bobby").displayName == "Bobby")
        let cleared = try await bob.social.updateDisplayName(nil)
        #expect(cleared.displayName == bob.username)

        #expect(try await bob.social.findProfile(username: "@" + alice.username) == aliceProfile)
        #expect(try await bob.social.findProfile(username: "zz_nobody_\(LocalStack.runID)") == nil)
        return (aliceProfile, cleared)
    }

    /// CRUD and Rotation. Returns alice's edited first quote.
    private func quotes(alice: TestUser, bob: TestUser) async throws -> Quote {
        let quotes = alice.quotes
        let bold = [TextRun(start: 0, length: 5, bold: true)]
        let q1 = try await quotes.create(QuoteDraft(body: "First quote", format: bold, author: "Ada", source: "Notes"))
        #expect(q1.origin == .manual)
        #expect(q1.rotationPosition == nil)
        #expect(q1.format == bold)
        #expect(q1.author == "Ada")

        // The emoji is two UTF-16 code units at offset 7.
        let emoji = [TextRun(start: 7, length: 2, italic: true)]
        let q2 = try await quotes.create(QuoteDraft(body: "Second 🙂 quote", format: emoji), origin: .pasted)
        #expect(q2.format == emoji)
        #expect(q2.origin == .pasted)
        let q3 = try await quotes.create(QuoteDraft(body: "Third quote"))
        let doomed = try await quotes.create(QuoteDraft(body: "Delete me"))

        var mine = try await quotes.fetchMine()
        #expect(Set(mine.map(\.id)) == Set([q1, q2, q3, doomed].map(\.id)))
        #expect(mine.first?.id == doomed.id, "newest first")

        var draft = q1
        draft.body = "First quote, edited"
        draft.author = nil
        draft.format = [TextRun(start: 0, length: 5, underline: true)]
        let edited = try await quotes.update(draft)
        #expect(edited.body == "First quote, edited")
        #expect(edited.author == nil)
        #expect(edited.source == "Notes")
        #expect(edited.format == draft.format)
        #expect(edited.updatedAt > q1.updatedAt)

        try await quotes.delete(id: doomed.id)
        try await quotes.delete(id: doomed.id)
        await #expect(throws: QuotedError.notFound) { _ = try await quotes.update(doomed) }

        // RLS: bob sees none of alice's quotes and cannot edit them.
        #expect(try await bob.quotes.fetchMine().isEmpty)
        await #expect(throws: QuotedError.notFound) { _ = try await bob.quotes.update(q2) }

        // Rotation: set_rotation takes IDs only. The deleted quote is skipped (never re-inserted)
        // and leaves no gap; content is never written, so a stale copy can't undo an edit.
        let rotation = try await quotes.setRotation(ordered: [q3, doomed, q1, q2])
        #expect(rotation.map(\.id) == [q3.id, q1.id, q2.id])
        #expect(rotation.map(\.rotationPosition) == [0, 1, 2])
        mine = try await quotes.fetchMine()
        #expect(RotationState.orderedQuoteIDs(in: mine) == [q3.id, q1.id, q2.id])
        #expect(!mine.contains { $0.id == doomed.id }, "a deleted quote is never resurrected")
        #expect(mine.first { $0.id == q1.id }?.body == "First quote, edited", "a stale copy (q1) does not undo the edit")
        #expect(mine.first { $0.id == q1.id }?.createdAt == q1.createdAt, "created_at is kept")
        #expect(mine.first { $0.id == q2.id }?.format == emoji)
        #expect(try await quotes.nextRotationPosition() == 3)

        let current = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
        let reordered = try await quotes.setRotation(
            ordered: [try #require(current[q2.id])],
            removing: [try #require(current[q1.id]), try #require(current[q3.id])]
        )
        #expect(reordered.first?.id == q2.id)
        #expect(reordered.map(\.rotationPosition) == [0, nil, nil])
        #expect(RotationState.orderedQuoteIDs(in: try await quotes.fetchMine()) == [q2.id])
        #expect(try await quotes.nextRotationPosition() == 1)

        // Undo of a delete puts the same row back.
        let inRotation = try #require(reordered.first)
        try await quotes.delete(id: inRotation.id)
        let restored = try await quotes.restore(inRotation)
        #expect(restored.id == inRotation.id)
        #expect(restored.body == inRotation.body)
        #expect(restored.format == inRotation.format)
        #expect(restored.origin == .pasted)
        #expect(restored.rotationPosition == 0)
        #expect(restored.createdAt > inRotation.createdAt, "created_at is server-owned")
        #expect(try await quotes.restore(inRotation).id == inRotation.id, "restoring twice is harmless")
        #expect(try await quotes.fetchMine().filter { $0.id == inRotation.id }.count == 1)
        return edited
    }

    /// More quotes than PostgREST's max_rows (1000): fetchMine pages through all of them.
    private func paging(_ alice: TestUser) async throws {
        let before = try await alice.quotes.fetchMine().count
        let many = (0..<1_050).map { StarterQuote(id: $0, body: "Paged quote \($0)", author: "Pager", sortOrder: $0) }
        _ = try await alice.quotes.importStarter(many, addToRotation: false)
        let mine = try await alice.quotes.fetchMine()
        #expect(mine.count == before + 1_050)
        #expect(Set(mine.map(\.id)).count == mine.count)
        #expect(zip(mine, mine.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt }, "newest first across pages")
    }

    private func starter(_ alice: TestUser) async throws {
        let starters = try await alice.backend.starter.fetchAll()
        #expect(starters.map(\.sortOrder) == starters.map(\.sortOrder).sorted())
        guard starters.count >= 2 else {
            print("[LocalStack] starter_quotes has \(starters.count) rows; skipped importStarter (seed migration not applied?)")
            return
        }
        #expect(starters.allSatisfy { !$0.body.isEmpty && $0.author?.isEmpty == false })
        let picked = Array(starters.prefix(2))
        let imported = try await alice.quotes.importStarter(picked, addToRotation: true)
        #expect(imported.map(\.origin) == [.starter, .starter])
        #expect(imported.map(\.rotationPosition) == [1, 2])
        #expect(imported.map(\.body) == picked.map { QuoteDraft(starter: $0).body.trimmingCharacters(in: .whitespacesAndNewlines) })
        #expect(imported.map(\.author) == picked.map(\.author))
    }

    private func friends(alice: TestUser, bob: TestUser, aliceProfile: Profile, bobProfile: Profile, quote: Quote) async throws {
        let request = try await alice.social.sendFriendRequest(toUsername: bob.username)
        #expect(request.status == .pending)
        #expect(request.isOutgoingRequest(for: alice.id))
        #expect(request.otherParty == bobProfile)
        #expect(request.respondedAt == nil)

        await #expect(throws: QuotedError.validation("You're already friends, or a request is already waiting.")) {
            _ = try await bob.social.sendFriendRequest(toUsername: alice.username)
        }
        await #expect(throws: QuotedError.validation("That's your own username.")) {
            _ = try await alice.social.sendFriendRequest(toUsername: alice.username)
        }
        await #expect(throws: QuotedError.notFound) {
            _ = try await alice.social.sendFriendRequest(toUsername: "zz_nobody_\(LocalStack.runID)")
        }
        // Only the addressee can accept.
        await #expect(throws: QuotedError.notFound) { _ = try await alice.social.accept(friendshipID: request.id) }
        // No sharing before the request is accepted.
        await #expect(throws: QuotedError.validation("You can only share with friends.")) {
            _ = try await alice.social.share(quote, to: [bob.id])
        }

        let incoming = try await bob.social.friendships()
        #expect(incoming.map(\.id) == [request.id])
        #expect(incoming.first?.isIncomingRequest(for: bob.id) == true)
        #expect(incoming.first?.otherParty == aliceProfile)

        let accepted = try await bob.social.accept(friendshipID: request.id)
        #expect(accepted.status == .accepted)
        #expect(accepted.respondedAt != nil)
        #expect(accepted.otherParty?.id == alice.id)
        await #expect(throws: QuotedError.notFound) { _ = try await bob.social.accept(friendshipID: request.id) }

        let friends = try await alice.social.friendships()
        #expect(friends.map(\.status) == [.accepted])
        #expect(friends.first?.otherParty == bobProfile)
    }

    private func sharing(alice: TestUser, bob: TestUser, quote: Quote) async throws -> SharedQuote {
        let sent = try await alice.social.share(quote, to: [bob.id, alice.id, bob.id], note: " Thought of you ")
        #expect(sent.count == 1)
        #expect(sent.first?.recipient?.username == bob.username)
        #expect(sent.first?.quoteID == quote.id)
        #expect(try await alice.social.sent().map(\.id) == sent.map(\.id))
        #expect(try await alice.social.inbox().isEmpty)

        let received = try #require(try await bob.social.inbox().first)
        #expect(received.id == sent.first?.id)
        #expect(received.sender?.username == alice.username)
        #expect(received.sender?.displayName == "Alice")
        #expect(received.body == quote.body)
        #expect(received.format == quote.format)
        #expect(received.author == quote.author)
        #expect(received.source == quote.source)
        #expect(received.note == "Thought of you")
        #expect(!received.isSeen)
        #expect(!received.isSaved)

        try await bob.social.markSeen([received.id])
        let seenAt = try #require(try await bob.social.inbox().first?.seenAt)
        try await bob.social.markSeen([received.id])
        #expect(try await bob.social.inbox().first?.seenAt == seenAt, "the first seen time is kept")

        // Bob's Rotation is empty, so the copy lands at position 0.
        let copy = try await bob.quotes.saveShared(received, addToRotation: true)
        #expect(copy.origin == .shared)
        #expect(copy.body == received.body)
        #expect(copy.format == received.format)
        #expect(copy.author == received.author)
        #expect(copy.rotationPosition == 0)
        #expect(try await bob.social.inbox().first?.isSaved == true)
        #expect(try await bob.quotes.fetchMine().map(\.id) == [copy.id])

        // A quote alice deleted can still be shared as a snapshot.
        let temporary = try await alice.quotes.create(QuoteDraft(body: "Short-lived"))
        try await alice.quotes.delete(id: temporary.id)
        let orphan = try await alice.social.share(temporary, to: [bob.id])
        #expect(orphan.first?.quoteID == nil)
        #expect(try await bob.social.inbox().count == 2)

        // markSaved stamps a share whose quote is already in the library, without a copy; the
        // first time is kept, and nobody but the recipient can stamp it.
        let orphanShareID = try #require(orphan.first?.id)
        try await alice.social.markSaved([orphanShareID])
        #expect(try await bob.social.inbox().first { $0.id == orphanShareID }?.isSaved == false, "only the recipient can mark it saved")
        try await bob.social.markSaved([orphanShareID])
        let savedAt = try #require(try await bob.social.inbox().first { $0.id == orphanShareID }?.savedAt)
        try await bob.social.markSaved([orphanShareID])
        #expect(try await bob.social.inbox().first { $0.id == orphanShareID }?.savedAt == savedAt, "the first saved time is kept")
        #expect(try await bob.quotes.fetchMine().map(\.id) == [copy.id], "no copy is made")

        // Either party can delete a share (Undo of a send, or clearing the inbox); repeats are harmless.
        let orphanID = try #require(orphan.first?.id)
        try await bob.social.deleteShares(ids: [orphanID])
        try await bob.social.deleteShares(ids: [orphanID])
        #expect(try await bob.social.inbox().map(\.id) == [received.id])
        #expect(try await alice.social.sent().map(\.id) == [received.id])
        let unsent = try await alice.social.share(quote, to: [bob.id], note: "Oops")
        try await alice.social.deleteShares(ids: unsent.map(\.id))
        #expect(try await bob.social.inbox().map(\.id) == [received.id])

        try await bob.social.report(share: received, reason: .spam, details: "QuotedKit integration test")
        return received
    }

    private func blocking(alice: TestUser, bob: TestUser, received: SharedQuote) async throws {
        try await bob.social.block(userID: alice.id)
        try await bob.social.block(userID: alice.id)
        #expect(try await bob.social.blockedIDs() == [alice.id])
        #expect(try await bob.social.blockedProfiles().map(\.id) == [alice.id])

        // The block removed the friendship and every share between them, in both directions.
        #expect(try await alice.social.friendships().isEmpty)
        #expect(try await bob.social.friendships().isEmpty)
        #expect(try await bob.social.inbox().isEmpty)
        #expect(try await alice.social.sent().isEmpty)
        // The saved copy is bob's own quote and stays.
        #expect(try await bob.quotes.fetchMine().count == 1)

        // Reporting the deleted share still reports the sender.
        try await bob.social.report(share: received, reason: .harassment)
        try await alice.social.report(userID: bob.id, reason: .other, details: "QuotedKit integration test")

        for (from, to) in [(alice, bob), (bob, alice)] {
            await #expect(throws: QuotedError.validation("You can't send a friend request to this person.")) {
                _ = try await from.social.sendFriendRequest(toUsername: to.username)
            }
        }

        try await bob.social.unblock(userID: alice.id)
        #expect(try await bob.social.blockedIDs().isEmpty)
        let request = try await bob.social.sendFriendRequest(toUsername: alice.username)
        try await alice.social.remove(friendshipID: request.id)
        try await alice.social.remove(friendshipID: request.id)
        #expect(try await bob.social.friendships().isEmpty)
    }
}

// MARK: Support

enum LocalStack {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["QUOTED_LOCAL_SUPABASE"] == "1" }

    static let config = SupabaseConfig(
        url: URL(string: ProcessInfo.processInfo.environment["QUOTED_SUPABASE_URL"] ?? "http://127.0.0.1:54321")!,
        // The local stack's demo publishable key (also in Config/DebugLocal.xcconfig).
        publishableKey: ProcessInfo.processInfo.environment["QUOTED_SUPABASE_PUBLISHABLE_KEY"]
            ?? "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    )

    /// Short random tag that keeps emails and usernames unique per run.
    static let runID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()

    /// Whether the edge runtime serves `delete-account` (it answers 401 to a request without a JWT).
    static func isDeleteAccountServed() async -> Bool {
        guard isEnabled else { return false }
        var request = URLRequest(url: config.url.appending(path: "functions/v1/\(AccountService.deleteAccountFunction)"))
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 401
    }

    /// Deletes each user through `delete-account`. If the function is unavailable, removes what
    /// the client can (quotes, friendships, blocks) and reports the leftover auth user.
    static func cleanUp(_ users: [TestUser]) async {
        for user in users {
            if user.backend.auth.currentUserID == nil {
                _ = try? await user.backend.auth.signIn(email: user.email, password: user.password)
            }
            guard user.backend.auth.currentUserID != nil else {
                print("[LocalStack] could not sign \(user.email) back in for cleanup")
                continue
            }
            do {
                try await user.backend.account.deleteAccount()
            } catch {
                print("[LocalStack] delete-account failed for \(user.email): \(error). Removing rows instead; the auth user remains.")
                for quote in (try? await user.quotes.fetchMine()) ?? [] {
                    try? await user.quotes.delete(id: quote.id)
                }
                for friendship in (try? await user.social.friendships()) ?? [] {
                    try? await user.social.remove(friendshipID: friendship.id)
                }
                for id in (try? await user.social.blockedIDs()) ?? [] {
                    try? await user.social.unblock(userID: id)
                }
            }
        }
    }
}

extension LocalStack {
    /// The local stack's mail catcher (Mailpit, `[inbucket]` in config.toml).
    static let mailURL = URL(string: ProcessInfo.processInfo.environment["QUOTED_LOCAL_MAIL_URL"] ?? "http://127.0.0.1:54324")!

    private struct MailSearch: Decodable {
        struct Message: Decodable { var ID: String }
        var messages: [Message]
    }

    private struct MailMessage: Decodable { var Text: String }

    /// The `/auth/v1/verify` link in the newest email to `email`, waiting up to 10 s for it.
    static func resetLink(for email: String) async throws -> URL {
        for _ in 0..<20 {
            var search = URLComponents(url: mailURL.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)
            search?.queryItems = [URLQueryItem(name: "query", value: "to:\(email)")]
            if let url = search?.url,
               let (data, _) = try? await URLSession.shared.data(from: url),
               let id = (try? JSONDecoder().decode(MailSearch.self, from: data))?.messages.first?.ID {
                let (body, _) = try await URLSession.shared.data(from: mailURL.appending(path: "api/v1/message/\(id)"))
                let text = try JSONDecoder().decode(MailMessage.self, from: body).Text
                if let range = text.range(of: #"http\S*/auth/v1/verify\S*"#, options: .regularExpression),
                   let link = URL(string: String(text[range]).replacingOccurrences(of: "&amp;", with: "&")) {
                    return link
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw QuotedError.notFound
    }

    /// Opens `url` without following the redirect and returns its `Location`.
    static func redirect(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await session.data(from: url)
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location)
        else { throw QuotedError.server("no redirect from \(url)") }
        return target
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

struct TestUser: Sendable {
    let backend: Backend
    let id: UUID
    let email: String
    let password: String
    /// A valid username (≤ 20 characters) for this user.
    let username: String

    var quotes: QuotesRepository { backend.quotes }
    var social: SocialRepository { backend.social }

    static func signUp(_ label: String) async throws -> TestUser {
        let backend = Backend(config: LocalStack.config, sessionPersistence: .inMemory)
        let tag = "\(label.prefix(5))_\(LocalStack.runID)"
        let email = "quotedkit-it-\(tag.replacingOccurrences(of: "_", with: "-"))@example.com"
        let password = "it-\(UUID().uuidString)"
        let result = try await backend.auth.signUp(email: email, password: password)
        guard case .signedIn(let id) = result else {
            Issue.record("Local Auth should auto-confirm sign-ups, got \(result)")
            throw QuotedError.notSignedIn
        }
        return TestUser(backend: backend, id: id, email: email, password: password, username: "it_\(tag)")
    }
}
