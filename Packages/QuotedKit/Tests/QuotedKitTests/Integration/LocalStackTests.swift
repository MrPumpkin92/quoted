import Foundation
import QuotedCore
import Testing
@testable import QuotedKit

/// End-to-end tests against a local Supabase stack (`supabase start`). They run only with
/// `QUOTED_LOCAL_SUPABASE=1 swift test`; `QUOTED_SUPABASE_URL` and
/// `QUOTED_SUPABASE_PUBLISHABLE_KEY` point them at another local stack. Local Auth auto-confirms
/// email, so sign-up signs in.
///
/// Every test signs up throwaway users and deletes them at the end through the `delete-account`
/// Edge Function (FK cascades remove their rows); a stack that doesn't serve it keeps the auth users.
/// Auth allows 30 sign-ins and sign-ups per 5 minutes per IP locally, so the suite keeps them to a
/// handful.
@Suite(
    "Local Supabase stack",
    .enabled(if: LocalStack.isEnabled, "Set QUOTED_LOCAL_SUPABASE=1 with `supabase start` running"),
    .serialized
)
struct LocalStackTests {
    @Test func endToEnd() async throws {
        let users = try await LocalStack.signUp(["alice", "bob"])
        try await LocalStack.run(users) {
            try await scenario(alice: users[0], bob: users[1])
        }
    }

    /// Two friends with accepted terms talk in a conversation (text, quote, catalog quote, playlist),
    /// post and view each other's profiles; a third person can neither read nor send.
    @Test func messagingPostsAndPlaylists() async throws {
        let users = try await LocalStack.signUp(["maya", "sam", "carol"])
        try await LocalStack.run(users) {
            try await social(maya: users[0], sam: users[1], carol: users[2])
        }
    }

    @Test(.enabled("delete-account must be served by the local stack") { await LocalStack.isDeleteAccountServed() })
    func deleteAccountRemovesTheUser() async throws {
        let carol = try await TestUser.signUp("carol")
        let profile = try await carol.profiles.createProfile(username: carol.username)
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
    @Test(.enabled("the stack's mail catcher must be reachable") { await LocalStack.isMailServed() })
    func passwordResetLinkIsReportedAsRecovery() async throws {
        let dave = try await TestUser.signUp("dave")
        try await LocalStack.run([dave]) { try await recovery(dave) }
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

    // MARK: End to end

    private func scenario(alice: TestUser, bob: TestUser) async throws {
        try await auth(alice)
        let (aliceProfile, bobProfile) = try await profiles(alice: alice, bob: bob)
        let edited = try await quotes(alice: alice, bob: bob)
        try await catalog(alice)
        try await paging(alice)
        try await friends(alice: alice, bob: bob, aliceProfile: aliceProfile, bobProfile: bobProfile)
        let conversation = try await conversation(alice: alice, bob: bob, quote: edited)
        try await blocking(alice: alice, bob: bob, conversation: conversation)
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
        #expect(try await alice.profiles.myProfile() == nil)
        #expect(try await alice.profiles.myAccount() == nil)
        #expect(try await alice.profiles.isUsernameAvailable(alice.username))
        let aliceProfile = try await alice.profiles.createProfile(username: "@" + alice.username.uppercased(), displayName: " Alice ")
        #expect(aliceProfile == Profile(id: alice.id, username: alice.username, displayName: "Alice", acceptsTextMessages: true))
        #expect(try await alice.profiles.myProfile() == aliceProfile)
        #expect(try await alice.profiles.isUsernameAvailable(alice.username) == false)
        // A second Continue (an earlier answer was lost) gets the profile that exists, unchanged.
        #expect(try await alice.profiles.createProfile(username: alice.username + "x") == aliceProfile)

        // The private fields come from my_account() only.
        let account = try #require(try await alice.profiles.myAccount())
        #expect(account.profile == aliceProfile)
        #expect(account.favoritesVisibility == .onlyMe)
        #expect(account.termsVersion == nil && !account.hasAcceptedCurrentTerms)
        #expect(account.currentTermsVersion >= 1)
        #expect(!account.isSuspended && !account.canPublish)

        await #expect(throws: QuotedError.usernameTaken) {
            _ = try await bob.profiles.createProfile(username: alice.username)
        }
        let bobProfile = try await bob.profiles.createProfile(username: bob.username)
        #expect(bobProfile.displayName == bob.username)
        #expect(try await bob.profiles.updateDisplayName("Bobby").displayName == "Bobby")
        let cleared = try await bob.profiles.updateDisplayName(nil)
        #expect(cleared.displayName == bob.username)
        #expect(try await bob.profiles.setAcceptsTextMessages(false).acceptsTextMessages == false)
        #expect(try await bob.profiles.setAcceptsTextMessages(true).acceptsTextMessages == true)

        #expect(try await bob.profiles.findProfile(username: "@" + alice.username) == Profile(id: alice.id, username: alice.username, displayName: "Alice"))
        #expect(try await bob.profiles.findProfile(username: "zz_nobody_\(LocalStack.runID)") == nil)
        return (aliceProfile, cleared)
    }

    /// CRUD, provenance, Undo and Rotation. Returns alice's edited first quote.
    private func quotes(alice: TestUser, bob: TestUser) async throws -> Quote {
        let quotes = alice.quotes
        let bold = [TextRun(start: 0, length: 5, bold: true)]
        let q1 = try await quotes.create(QuoteDraft(body: "First quote", format: bold, author: "Ada", source: "Notes"))
        #expect(q1.origin == .manual)
        #expect(q1.rotationPosition == nil)
        #expect(q1.format == bold)
        #expect(q1.author == "Ada")
        // The server makes you the creator of your own words.
        #expect(q1.creatorID == alice.id)
        #expect(q1.provenance.who(viewer: alice.username) == .you)

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
        #expect(edited.provenance == q1.provenance, "editing your own words changes nothing")

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

        // Undo of a delete is a plain insert of the same row; the server gives back its provenance.
        let inRotation = try #require(reordered.first)
        try await quotes.delete(id: inRotation.id)
        let restored = try await quotes.restore(inRotation)
        #expect(restored.id == inRotation.id)
        #expect(restored.body == inRotation.body)
        #expect(restored.format == inRotation.format)
        #expect(restored.origin == .pasted)
        #expect(restored.rotationPosition == 0)
        #expect(restored.creatorID == alice.id)
        #expect(restored.createdAt > inRotation.createdAt, "created_at is server-owned")
        #expect(try await quotes.restore(inRotation).id == inRotation.id, "restoring twice is harmless")
        #expect(try await quotes.fetchMine().filter { $0.id == inRotation.id }.count == 1)
        return edited
    }

    private func catalog(_ alice: TestUser) async throws {
        let catalog = try await alice.backend.starter.fetchAll()
        #expect(catalog.map(\.sortOrder) == catalog.map(\.sortOrder).sorted())
        // The live catalog holds every live starter; one row also reads by id.
        let live = try await alice.backend.catalog.fetchLive()
        #expect(Set(catalog.map(\.id)).isSubset(of: Set(live.filter(\.isStarter).map(\.id))))
        #expect(live.allSatisfy { $0.status == .live && !$0.themes.isEmpty })
        if let first = catalog.first {
            let row = try await alice.backend.catalog.quote(id: first.id)
            #expect(row?.body == first.body)
        }
        guard catalog.count >= 2 else {
            print("[LocalStack] starter_quotes has \(catalog.count) rows; skipped addCatalogQuotes (seed migration not applied?)")
            return
        }
        #expect(catalog.allSatisfy { !$0.body.isEmpty && $0.author?.isEmpty == false })
        let picked = Array(catalog.prefix(2))
        let ids = [UUID(), UUID()]
        let added = try await alice.quotes.addCatalogQuotes(picked.map(\.id), ids: ids, inReminders: true)
        #expect(added.map(\.id) == ids)
        #expect(added.map(\.origin) == [.starter, .starter])
        #expect(added.map(\.rotationPosition) == [1, 2])
        #expect(added.map(\.body) == picked.map(\.body))
        #expect(added.map(\.provenance) == picked.map(\.provenance), "Quoted Catalog, no creator")
        // A retry with the same ids returns the same quotes.
        #expect(try await alice.quotes.addCatalogQuotes(picked.map(\.id), ids: ids, inReminders: true).map(\.id) == ids)
        await #expect(throws: QuotedError.notFound) { try await alice.quotes.addCatalogQuotes([32_000]) }

        // A Verified Quotes pick that is not a starter keeps origin catalog, sealed with its own id.
        if let batch = live.first(where: { !$0.isStarter }) {
            let saved = try await alice.quotes.addCatalogQuotes([batch.id])
            #expect(saved.map(\.origin) == [.catalog])
            #expect(saved.map(\.verifiedStarterID) == [batch.id])
            #expect(saved.map(\.provenance) == [batch.provenance])
            #expect(saved.map(\.rotationPosition) == [nil])
        }
    }

    /// More quotes than PostgREST's max_rows (1000): fetchMine pages through all of them.
    private func paging(_ alice: TestUser) async throws {
        let catalog = try await alice.backend.starter.fetchAll()
        guard !catalog.isEmpty else { return }
        let before = try await alice.quotes.fetchMine().count
        _ = try await alice.quotes.addCatalogQuotes((0..<1_050).map { catalog[$0 % catalog.count].id })
        let mine = try await alice.quotes.fetchMine()
        #expect(mine.count == before + 1_050)
        #expect(Set(mine.map(\.id)).count == mine.count)
        #expect(zip(mine, mine.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt }, "newest first across pages")
    }

    private func friends(alice: TestUser, bob: TestUser, aliceProfile: Profile, bobProfile: Profile) async throws {
        // Friend requests are social writes: the terms come first, whatever the target.
        await #expect(throws: QuotedError.termsRequired) {
            _ = try await alice.social.sendFriendRequest(toUsername: bob.username)
        }
        try await LocalStack.acceptTerms(alice)
        try await LocalStack.acceptTerms(bob)
        #expect(try await alice.profiles.myAccount()?.hasAcceptedCurrentTerms == true)
        await #expect(throws: QuotedError.validation("The Terms of Use were just updated. Read them again, then accept.")) {
            try await alice.profiles.acceptTerms(version: 999)
        }

        let request = try await alice.social.sendFriendRequest(toUsername: bob.username)
        #expect(request.status == .pending)
        #expect(request.isOutgoingRequest(for: alice.id))
        // From find_profile, which doesn't say whether they take texts (unknown, not on).
        #expect(request.otherParty == Profile(id: bob.id, username: bob.username, displayName: bobProfile.displayName))
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
        // No conversation before the request is accepted.
        await #expect(throws: QuotedError.unavailable("This person is not available.")) {
            _ = try await alice.backend.messages.openConversation(with: bob.id)
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

    /// Today's Send to a friend: one quote message in their conversation.
    private func conversation(alice: TestUser, bob: TestUser, quote: Quote) async throws -> Conversation {
        let conversation = try await alice.backend.messages.openConversation(with: bob.id)
        #expect(Set([conversation.userA, conversation.userB]) == [alice.id, bob.id])
        #expect(try await bob.backend.messages.openConversation(with: alice.id).id == conversation.id, "one per pair")

        let sent = try await alice.backend.messages.send(.quote(.quote(quote.id), note: " Thought of you "), in: conversation.id)
        #expect(sent.note == "Thought of you")
        #expect(sent.quote?.body == quote.body)
        #expect(sent.quote?.format == quote.format)

        let inbox = try await bob.backend.messages.inbox()
        let row = try #require(inbox.first { $0.id == conversation.id })
        #expect(row.other?.username == alice.username)
        #expect(row.other?.displayName == "Alice")
        #expect(row.unreadCount == 1)
        #expect(row.lastMessageKind == .quote)
        #expect(row.lastMessagePreview == quote.body)
        #expect(InboxBadge(conversations: inbox, friendRequests: 0).count == 1)

        let received = try #require(try await bob.backend.messages.messages(in: conversation.id).first)
        #expect(received.id == sent.id)
        #expect(received.senderID == alice.id)
        #expect(received.quote?.author == quote.author)
        #expect(received.quote?.source == quote.source)
        #expect(received.provenance?.who(viewer: bob.username) == .person(alice.username))

        let member = try #require(try await bob.backend.messages.markRead(conversationID: conversation.id, upTo: received.createdAt))
        #expect(member.lastReadAt == received.createdAt)
        #expect(try await bob.backend.messages.inbox().first { $0.id == conversation.id }?.unreadCount == 0)

        // Bob's Rotation is empty, so the copy lands at position 0, with alice as its creator.
        let copy = try await bob.quotes.save(.message(received.id), inReminders: true)
        #expect(copy.origin == .shared)
        #expect(copy.body == quote.body)
        #expect(copy.rotationPosition == 0)
        #expect(copy.creatorUsername == alice.username)
        // Undo of a delete puts it back with its origin and creator, and is safe to retry: the
        // first try used up the tombstone, and the retry reads the quote back instead of failing.
        try await bob.quotes.delete(id: copy.id)
        let restored = try await bob.quotes.restore(copy)
        #expect(restored.origin == .shared && restored.creatorUsername == alice.username)
        #expect(try await bob.quotes.restore(copy) == restored)
        #expect(try await bob.quotes.fetchMine().map(\.id) == [copy.id])
        return conversation
    }

    private func blocking(alice: TestUser, bob: TestUser, conversation: Conversation) async throws {
        try await bob.backend.reports.report(.profile(userID: alice.id), reason: .spam, details: "QuotedKit integration test")
        try await bob.social.block(userID: alice.id)
        try await bob.social.block(userID: alice.id)
        #expect(try await bob.social.blockedIDs() == [alice.id])
        #expect(try await bob.social.blockedUsers().map(\.id) == [alice.id])

        // The block ended the friendship and closed the conversation. Nothing is deleted: bob keeps
        // it, read only, to report from; alice can no longer read it.
        #expect(try await alice.social.friendships().isEmpty)
        #expect(try await bob.social.friendships().isEmpty)
        #expect(try await bob.backend.messages.messages(in: conversation.id).count == 1)
        #expect(try await bob.backend.messages.conversation(id: conversation.id)?.isClosed == true)
        #expect(try await alice.backend.messages.messages(in: conversation.id).isEmpty)
        #expect(try await alice.backend.messages.conversation(id: conversation.id) == nil)
        await #expect(throws: QuotedError.conversationClosed) {
            try await bob.backend.messages.send(.text("hello?"), in: conversation.id)
        }
        // The saved copy is bob's own quote and stays.
        #expect(try await bob.quotes.fetchMine().count == 1)

        try await alice.backend.reports.report(.profile(userID: bob.id), reason: .other, details: "QuotedKit integration test")

        // A blocked pair reads like an unknown username, both ways.
        for (from, to) in [(alice, bob), (bob, alice)] {
            await #expect(throws: QuotedError.notFound) {
                _ = try await from.social.sendFriendRequest(toUsername: to.username)
            }
        }

        // Alice blocks back: bob can no longer read her profile, but she stays on his list, so he
        // can still unblock her.
        #expect(try await bob.social.blockedUsers().first?.profile?.username == alice.username)
        try await alice.social.block(userID: bob.id)
        let mutual = try await bob.social.blockedUsers()
        #expect(mutual.map(\.id) == [alice.id])
        #expect(mutual.first?.profile == nil)
        try await alice.social.unblock(userID: bob.id)

        try await bob.social.unblock(userID: alice.id)
        #expect(try await bob.social.blockedIDs().isEmpty)
        #expect(try await bob.backend.messages.conversation(id: conversation.id)?.isClosed == true, "unblocking does not reopen it")
        let request = try await bob.social.sendFriendRequest(toUsername: alice.username)
        try await alice.social.remove(friendshipID: request.id)
        try await alice.social.remove(friendshipID: request.id)
        #expect(try await bob.social.friendships().isEmpty)
    }

    // MARK: Messaging, posts and playlists

    private func social(maya: TestUser, sam: TestUser, carol: TestUser) async throws {
        try await LocalStack.makeFriends(maya, sam)
        _ = try await carol.profiles.createProfile(username: carol.username)

        // Carol: terms first, then she is still nobody's friend.
        await #expect(throws: QuotedError.termsRequired) {
            _ = try await carol.backend.messages.openConversation(with: maya.id)
        }
        await #expect(throws: QuotedError.termsRequired) {
            _ = try await carol.backend.posts.create(PostDraft(source: .catalog(1)))
        }
        try await LocalStack.acceptTerms(carol)
        await #expect(throws: QuotedError.unavailable("This person is not available.")) {
            _ = try await carol.backend.messages.openConversation(with: maya.id)
        }

        let conversation = try await maya.backend.messages.openConversation(with: sam.id)
        // A new conversation shows in the Inbox with no message yet.
        let fresh = try #require(try await sam.backend.messages.inbox().first { $0.id == conversation.id })
        #expect(fresh.lastMessageAt == nil && fresh.unreadCount == 0)

        // Text, with an idempotent retry.
        let textID = UUID()
        let text = try await maya.backend.messages.send(.text("  Hello, Sam  "), in: conversation.id, id: textID)
        #expect(text.content == .text("Hello, Sam"))
        #expect(try await maya.backend.messages.send(.text("Hello, Sam"), in: conversation.id, id: textID) == text)
        await #expect(throws: QuotedError.validation("Write a message first.")) {
            try await maya.backend.messages.send(.text("   "), in: conversation.id)
        }

        // A quote of maya's own, and a catalog quote.
        let words = try await maya.quotes.create(QuoteDraft(body: "Courage is grace under pressure.", author: "Hemingway"))
        _ = try await maya.quotes.setFavorite(id: words.id, true)
        let quoteMessage = try await maya.backend.messages.send(.quote(.quote(words.id), note: "for Monday"), in: conversation.id)
        #expect(quoteMessage.quote?.creatorUsername == maya.username)
        let catalog = try await maya.backend.starter.fetchAll()
        if let checked = catalog.first {
            let message = try await maya.backend.messages.send(.quote(.catalog(checked.id)), in: conversation.id)
            #expect(message.provenance == .catalog(checked.id))
            #expect(message.starterQuoteID == checked.id)
        }

        // A playlist friends can see.
        let playlist = try await maya.backend.playlists.create(title: " Courage ")
        #expect(playlist.title == "Courage" && playlist.visibility == .friends)
        let added = try await maya.backend.playlists.add([words.id, words.id], to: playlist.id)
        #expect(added.map(\.quoteID) == [words.id])
        #expect(try await maya.backend.playlists.add([words.id], to: playlist.id).isEmpty, "already in it: skipped")
        let playlistMessage = try await maya.backend.messages.send(.playlist(playlist.id), in: conversation.id)
        #expect(playlistMessage.content == .playlist(id: playlist.id, title: "Courage"))

        // Sam's side: the Inbox, the page, the read mark.
        var row = try #require(try await sam.backend.messages.inbox().first { $0.id == conversation.id })
        #expect(row.unreadCount == (catalog.isEmpty ? 3 : 4))
        #expect(row.lastMessageKind == .playlist)
        #expect(row.lastMessagePreview == "Courage")
        #expect(!row.lastMessageIsMine(sam.id))
        let page = try await sam.backend.messages.messages(in: conversation.id)
        #expect(page.first?.id == playlistMessage.id, "newest first")
        #expect(page.last?.id == text.id)
        // Keyset pages: two at a time reach every message once, in order.
        var older: [Message] = []
        var cursor: PageCursor?
        repeat {
            let next = try await sam.backend.messages.messages(in: conversation.id, after: cursor, limit: 2)
            older += next
            cursor = next.count == 2 ? next.last?.cursor : nil
        } while cursor != nil
        #expect(older.map(\.id) == page.map(\.id))
        // "Shared with you": every quote message Sam received, newest first, read to the end in
        // pages (here one at a time); no text or playlist message.
        let received = try await sam.backend.messages.receivedQuotes(pageSize: 1)
        #expect(received.map(\.id) == page.filter { $0.kind == .quote }.map(\.id))
        #expect(try await maya.backend.messages.receivedQuotes().isEmpty, "Maya's own messages are not hers to receive")
        // The read mark stops at what Sam has shown: up to the quote message, the later ones stay
        // unread; up to the newest, none is.
        try await sam.backend.messages.markRead(conversationID: conversation.id, upTo: quoteMessage.createdAt)
        row = try #require(try await sam.backend.messages.inbox().first { $0.id == conversation.id })
        #expect(row.unreadCount == (catalog.isEmpty ? 1 : 2))
        let newest = try #require(row.lastMessageAt)
        try await sam.backend.messages.markRead(conversationID: conversation.id, upTo: newest)
        row = try #require(try await sam.backend.messages.inbox().first { $0.id == conversation.id })
        #expect(!row.isUnread)
        #expect(row.lastReadAt == newest)

        // The playlist, as Sam sees it: save one item, then a copy of the whole list.
        let view = try #require(try await sam.backend.playlists.view(id: playlist.id))
        #expect(view.owner.id == maya.id)
        #expect(view.items.map(\.body) == [words.body])
        let item = try #require(view.items.first)
        #expect(item.provenance.who(viewer: sam.username) == .person(maya.username))
        let savedItem = try await sam.quotes.save(view.snapshotRef(for: item))
        #expect(savedItem.creatorUsername == maya.username)
        let copy = try await sam.backend.playlists.saveCopy(of: playlist.id)
        #expect(copy.ownerID == sam.id && copy.title == "Courage" && copy.visibility == .onlyMe)
        #expect(copy.quoteIDs == [savedItem.id], "a quote Sam already holds is reused")
        #expect(try await sam.backend.playlists.mine().map(\.id) == [copy.id])

        // Saving the quote message, then editing it: Sam becomes the creator, Maya "edited from".
        let saved = try await sam.quotes.save(.message(quoteMessage.id))
        var edit = saved
        edit.body = "Courage is grace under pressure, always."
        let version = try await sam.quotes.update(edit)
        #expect(version.creatorUsername == sam.username)
        #expect(version.editedFromUsername == maya.username)
        #expect(ProvenanceCopy.editNote(saved.provenance, viewer: sam.username)
            == "Changing the words makes this your version. @\(maya.username) stays as edited from.")

        // Texts off: text is refused, quotes still go through.
        _ = try await sam.profiles.setAcceptsTextMessages(false)
        #expect(try await maya.backend.messages.conversation(id: conversation.id)?.otherProfile(for: maya.id)?.acceptsTextMessages == false)
        await #expect(throws: QuotedError.textsOff) {
            try await maya.backend.messages.send(.text("Are you there?"), in: conversation.id)
        }
        _ = try await maya.backend.messages.send(.quote(.quote(words.id)), in: conversation.id)
        _ = try await sam.profiles.setAcceptsTextMessages(true)

        // Carol is in none of it.
        #expect(try await carol.backend.messages.messages(in: conversation.id).isEmpty)
        #expect(try await carol.backend.messages.conversation(id: conversation.id) == nil)
        #expect(try await carol.backend.messages.message(id: quoteMessage.id) == nil)
        #expect(try await carol.backend.messages.inbox().isEmpty)
        await #expect(throws: QuotedError.unavailable("This conversation is not available.")) {
            try await carol.backend.messages.send(.text("Let me in"), in: conversation.id)
        }
        await #expect(throws: QuotedError.unavailable("This message is not available.")) {
            try await carol.quotes.save(.message(quoteMessage.id))
        }
        #expect(try await carol.backend.playlists.view(id: playlist.id) == nil)
        #expect(try await carol.backend.messages.markRead(conversationID: conversation.id, upTo: .now) == nil)

        // Unsend: gone for both. Delete Conversation: gone for Sam only.
        try await maya.backend.messages.unsend(messageID: text.id)
        #expect(try await sam.backend.messages.message(id: text.id) == nil)
        // An older quote unsent: the conversation's latest message stays the same, yet the quote
        // leaves Sam's "Shared with you" at the next read.
        let latestBefore = try await sam.backend.messages.inbox().first { $0.id == conversation.id }?.lastMessageAt
        try await maya.backend.messages.unsend(messageID: quoteMessage.id)
        #expect(try await sam.backend.messages.inbox().first { $0.id == conversation.id }?.lastMessageAt == latestBefore)
        #expect(try await sam.backend.messages.receivedQuotes().contains { $0.id == quoteMessage.id } == false)
        try await sam.backend.messages.clear(conversationID: conversation.id)
        #expect(try await sam.backend.messages.messages(in: conversation.id).isEmpty)
        #expect(try await maya.backend.messages.messages(in: conversation.id).isEmpty == false)

        try await posts(maya: maya, sam: sam, carol: carol, words: words)
        try await playlistOrder(maya, playlist: playlist, first: words)

        // Unfriending closes the conversation for both.
        let friendship = try #require(try await maya.social.friendships().first)
        try await maya.social.remove(friendshipID: friendship.id)
        await #expect(throws: QuotedError.conversationClosed) {
            try await maya.backend.messages.send(.quote(.quote(words.id)), in: conversation.id)
        }
        #expect(try await maya.backend.messages.inbox().first { $0.id == conversation.id }?.isClosed == true)
    }

    private func posts(maya: TestUser, sam: TestUser, carol: TestUser, words: Quote) async throws {
        let post = try await maya.backend.posts.create(PostDraft(source: .quote(words.id), caption: "  Monday  "))
        #expect(post.posterID == maya.id)
        #expect(post.caption == "Monday")
        #expect(post.quote.body == words.body)
        #expect(post.provenance.who(viewer: maya.username) == .you)
        await #expect(throws: QuotedError.validation("Shorten the caption to 280 characters.")) {
            try await maya.backend.posts.create(PostDraft(source: .quote(words.id), caption: String(repeating: "c", count: 281)))
        }

        // The Feed: Maya's own and Sam's (a friend) see it, with the poster; Carol (a stranger) doesn't.
        #expect(try await maya.backend.posts.feed().map(\.id) == [post.id])
        let feed = try await sam.backend.posts.feed()
        #expect(feed.map(\.id) == [post.id])
        #expect(feed.first?.poster?.username == maya.username)
        #expect(try await carol.backend.posts.feed().isEmpty)
        #expect(try await carol.backend.posts.post(id: post.id) == nil)
        #expect(try await sam.backend.posts.posts(by: maya.id).map(\.id) == [post.id])

        // Profile pages: a friend sees the posts and playlists; favorites once Maya shares them.
        var page = try #require(try await sam.profiles.profileView(username: maya.username))
        #expect(page.relationship == .friend)
        #expect(page.posts.map(\.id) == [post.id])
        #expect(page.playlists.map(\.title) == ["Courage"])
        #expect(page.favorites == nil)
        try await maya.profiles.setFavoritesVisibility(.friends)
        #expect(try await maya.profiles.myAccount()?.favoritesVisibility == .friends)
        page = try #require(try await sam.profiles.profileView(username: "@" + maya.username))
        let favorite = try #require(page.favorites?.first)
        #expect(favorite.body == words.body)
        let fromFavorite = try await sam.quotes.save(page.snapshotRef(for: favorite))
        #expect(fromFavorite.creatorUsername == maya.username)
        let strangers = try #require(try await carol.profiles.profileView(username: maya.username))
        #expect(strangers.relationship == Relationship.none)
        #expect(strangers.isEmpty, "only friends see what Maya shares")
        #expect(try await carol.profiles.profileView(username: "zz_nobody_\(LocalStack.runID)") == nil)
        #expect(try await maya.profiles.profileView(username: maya.username)?.relationship == .me)

        // Saving a post keeps its creator. (Forwarding a post or message is not exercised here.)
        let fromPost = try await sam.quotes.save(.post(post.id))
        #expect(fromPost.origin == .shared && fromPost.creatorUsername == maya.username)
        await #expect(throws: QuotedError.unavailable("This post is not available.")) {
            try await carol.quotes.save(.post(post.id))
        }

        // A catalog post, keyset paging, and delete.
        let catalog = try await maya.backend.starter.fetchAll()
        if let checked = catalog.first {
            let second = try await maya.backend.posts.create(PostDraft(source: .catalog(checked.id)))
            #expect(second.provenance == .catalog(checked.id))
            let first = try await sam.backend.posts.feed(limit: 1)
            #expect(first.map(\.id) == [second.id])
            let next = try await sam.backend.posts.feed(after: try #require(first.last).cursor, limit: 1)
            #expect(next.map(\.id) == [post.id])
            try await maya.backend.posts.delete(id: second.id)
        }
        try await maya.backend.posts.delete(id: post.id)
        #expect(try await sam.backend.posts.feed().isEmpty)
    }

    private func playlistOrder(_ maya: TestUser, playlist: Playlist, first: Quote) async throws {
        let second = try await maya.quotes.create(QuoteDraft(body: "Second in the list"))
        let third = try await maya.quotes.create(QuoteDraft(body: "Third in the list"))
        _ = try await maya.backend.playlists.add([second.id, third.id], to: playlist.id)
        var mine = try #require(try await maya.backend.playlists.playlist(id: playlist.id))
        #expect(mine.quoteIDs == [first.id, second.id, third.id])

        // Move the last to the front. The dense start (0, 1024, 2048) has no room before 0, so this
        // one renumbers; later moves fit into the gaps.
        let entries = mine.entries
        _ = try await maya.backend.playlists.reorder(playlist.id, entries: [entries[2], entries[0], entries[1]])
        mine = try #require(try await maya.backend.playlists.playlist(id: playlist.id))
        #expect(mine.quoteIDs == [third.id, first.id, second.id])

        // Remove and put back (Undo).
        let removed = try #require(mine.entries.first)
        try await maya.backend.playlists.remove(quoteID: removed.quoteID, from: playlist.id)
        #expect(try await maya.backend.playlists.playlist(id: playlist.id)?.quoteIDs == [first.id, second.id])
        _ = try await maya.backend.playlists.restore(removed)
        #expect(try await maya.backend.playlists.playlist(id: playlist.id)?.quoteIDs == [third.id, first.id, second.id])

        // Rename, narrow and delete.
        #expect(try await maya.backend.playlists.rename(playlist.id, to: "Grace").title == "Grace")
        #expect(try await maya.backend.playlists.setVisibility(.onlyMe, for: playlist.id).visibility == .onlyMe)
        await #expect(throws: QuotedError.validation("Give the playlist a title.")) {
            try await maya.backend.playlists.rename(playlist.id, to: "  ")
        }
        try await maya.backend.playlists.delete(id: playlist.id)
        #expect(try await maya.backend.playlists.playlist(id: playlist.id) == nil)
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

    /// Signs up one user per label, cleaning up the ones already made if a sign-up fails.
    static func signUp(_ labels: [String]) async throws -> [TestUser] {
        var users: [TestUser] = []
        for label in labels {
            do {
                users.append(try await TestUser.signUp(label))
            } catch {
                await cleanUp(users)
                throw error
            }
        }
        return users
    }

    /// Runs `body`, then cleans up `users` whether it threw or not.
    static func run(_ users: [TestUser], _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await cleanUp(users)
            throw error
        }
        await cleanUp(users)
    }

    /// Accepts the current Terms of Use.
    static func acceptTerms(_ user: TestUser) async throws {
        let account = try #require(try await user.profiles.myAccount())
        try await user.profiles.acceptTerms(version: account.currentTermsVersion)
    }

    /// Gives both users a profile, accepts the terms for both and makes them accepted friends.
    static func makeFriends(_ a: TestUser, _ b: TestUser) async throws {
        for user in [a, b] {
            if try await user.profiles.myProfile() == nil {
                _ = try await user.profiles.createProfile(username: user.username)
            }
        }
        try await acceptTerms(a)
        try await acceptTerms(b)
        let request = try await a.social.sendFriendRequest(toUsername: b.username)
        _ = try await b.social.accept(friendshipID: request.id)
    }

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

    /// Whether this stack's mail catcher answers. Another stack (a custom `QUOTED_SUPABASE_URL`) must
    /// name its own with `QUOTED_LOCAL_MAIL_URL`, or the reset email would be looked for elsewhere.
    static func isMailServed() async -> Bool {
        guard isEnabled else { return false }
        let environment = ProcessInfo.processInfo.environment
        if environment["QUOTED_SUPABASE_URL"] != nil, environment["QUOTED_LOCAL_MAIL_URL"] == nil { return false }
        var request = URLRequest(url: mailURL.appending(path: "api/v1/messages"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// Deletes each user through `delete-account`. If the function is unavailable, removes what
    /// the client can (posts, playlists, quotes, friendships, blocks) and reports the leftover auth user.
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
                for post in (try? await user.backend.posts.posts(by: user.id, limit: 100)) ?? [] {
                    try? await user.backend.posts.delete(id: post.id)
                }
                for playlist in (try? await user.backend.playlists.mine()) ?? [] {
                    try? await user.backend.playlists.delete(id: playlist.id)
                }
                // One request, however many quotes a test made.
                _ = try? await user.backend.client.from(Table.quotes)
                    .delete(returning: .minimal)
                    .eq("owner_id", value: user.id)
                    .execute()
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
    var profiles: ProfilesRepository { backend.profiles }

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
