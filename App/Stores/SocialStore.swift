import Foundation
import Observation
import OSLog
import QuotedCore
import QuotedKit

/// A friend or a pending request, with the other person's profile.
struct Connection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An accepted friendship.
        case friend
        /// A request someone sent you (Accept / Decline).
        case incoming
        /// A request you sent ("Requested" / Cancel).
        case outgoing
    }

    /// The friendship row ID (what accept, decline, cancel and remove act on).
    let id: UUID
    let kind: Kind
    /// The other person.
    let profile: Profile
    let createdAt: Date
}

/// The outcome of `SocialStore.sendRequest(toUsername:)`. The store already showed `message` as a toast.
struct FriendRequestResult: Hashable, Sendable {
    /// Whether a request was sent (clear the field).
    let isSuccess: Bool
    /// "Request sent to @maya", "No user named @x", or the error copy.
    let message: String
}

/// A quote a friend sent you: one quote message you received, with the friend who sent it (from the
/// Inbox row of its conversation). "Shared with you", Search and the inbox alerts show these.
struct InboxQuote: Identifiable, Hashable, Sendable {
    let message: ConversationMessage
    /// The server-built snapshot the message carries.
    let quote: QuoteSnapshot
    /// The sender's profile, when the Inbox row has it.
    let sender: Profile?

    /// Nil for a text or playlist message.
    init?(message: ConversationMessage, sender: Profile?) {
        guard case .quote(let quote, _) = message.content else { return nil }
        self.message = message
        self.quote = quote
        self.sender = sender
    }

    var id: UUID { message.id }
    var senderID: UUID { message.senderID }
    var conversationID: UUID { message.conversationID }
    /// The sender's note, if any.
    var note: String? { message.note }
    var createdAt: Date { message.createdAt }
}

/// A social write that waits for the Terms of Use (`SocialStore.requireTerms(for:then:)`). The Terms
/// sheet (`.termsSheet()`) shows while one is pending.
struct TermsRequest: Identifiable {
    let id = UUID()
    /// The screen or sheet that asked (see `SocialStore.dropTermsChecks(for:)`), if it can go away.
    let owner: UUID?
    /// "Updated Terms": this account accepted an earlier version.
    let isUpdate: Bool
    /// The version Accept agrees to (`my_account().current_terms_version`).
    var version: Int
    /// The write to run once the terms are accepted.
    let action: @MainActor () async -> Void
}

/// Friends, requests, the quotes friends sent you, blocks, reports and the Terms of Use gate.
///
/// The quotes friends sent are quote messages: each refresh reads your conversations
/// (`inbox_conversations()`, with your read mark in each) and every quote message sent to you
/// (`MessagesRepository.receivedQuotes()`, one query across conversations, read to the end), so an
/// older quote is never cut off and one its sender unsent leaves at the next refresh. A quote is
/// unseen while it is newer than your read mark in its conversation. Sending a quote opens your
/// conversation with each friend and sends it there.
///
/// The signed-in user's own profile and account live in `SessionStore`. Mutations are optimistic,
/// roll back only what they changed and toast on failure, and return whether they worked. Server
/// writes run under a `BackgroundTaskAssertion`. Refreshes are single-flight, and one that overlapped
/// a write is dropped and repeated once the writes settle (see `WriteTracker`). Friend requests,
/// accepting one and sending need the current Terms of Use: run them through `requireTerms(for:then:)`.
/// Inject with `@Environment(SocialStore.self)`.
@Observable
@MainActor
final class SocialStore {
    // MARK: State

    /// Accepted friends, by name.
    private(set) var friends: [Connection] = []
    /// Requests waiting for you, newest first.
    private(set) var incomingRequests: [Connection] = []
    /// Requests you sent, newest first.
    private(set) var outgoingRequests: [Connection] = []
    /// Your conversations (`inbox_conversations()`), newest first, with your unread counts.
    private(set) var conversations: [InboxConversation] = []
    /// Quotes friends sent you, newest first (also cached for offline search).
    private(set) var inbox: [InboxQuote] = []
    /// The quotes in `inbox` that arrived after your read mark in their conversation.
    private(set) var unreadInboxIDs: Set<UUID> = []
    /// Quote messages you reported. The server hides them from you at once: Save is off for them,
    /// and their card leaves once the "Also block?" offer is answered (`hideReported(_:)`).
    private(set) var reportedMessageIDs: Set<UUID> = []
    /// People you blocked (load with `loadBlocked()`). One who blocked you back has no profile.
    private(set) var blockedUsers: [BlockedUser] = []
    /// True once the server has answered (or the cache was restored for the inbox).
    private(set) var hasLoaded = false
    /// True while `refresh()` runs.
    private(set) var isRefreshing = false
    /// The last refresh error, cleared by the next success.
    private(set) var lastError: QuotedError?
    /// A social write waiting for the Terms of Use. `.termsSheet()` shows the Terms sheet while set.
    private(set) var termsRequest: TermsRequest?

    // MARK: Dependencies

    @ObservationIgnored weak var library: LibraryStore?
    /// Holds your account (the accepted Terms of Use version).
    @ObservationIgnored weak var session: SessionStore?
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private var lastRefreshed: Date?
    /// Server writes in flight that change friends, requests, read marks or blocks.
    @ObservationIgnored private var writes = WriteTracker()
    @ObservationIgnored private var refreshAfterWrites = false
    @ObservationIgnored private var refreshTask: Task<RefreshOutcome, Never>?
    @ObservationIgnored private var refreshSerial = 0
    /// Bumped by `reset()`, so results that arrive after a sign-out are dropped.
    @ObservationIgnored private var generation = 0
    /// Every quote message sent to you, newest first, as the last refresh (or the cache) had them.
    @ObservationIgnored private var receivedMessages: [ConversationMessage] = []
    /// Reported quotes whose card stays until the "Also block?" offer is answered.
    @ObservationIgnored private var reportsOnScreen: Set<UUID> = []
    /// Message IDs of a send that failed, by quote, recipients and note, so Send again reuses them:
    /// if the first attempt landed and only its answer was lost, the retry finds those messages
    /// instead of sending a second copy (`MessagesRepository.send(_:in:id:)`).
    @ObservationIgnored private var retrySendIDs: [SendKey: [UUID: UUID]] = [:]
    /// Set when a write was refused for the terms although the account said they were accepted (a
    /// newer version came out): the next `requireTerms(for:then:)` asks the server.
    @ObservationIgnored private var termsMayBeOutdated = false
    /// Terms checks waiting for the server, by check, with the screen or sheet that asked. A check
    /// whose owner went away meanwhile (`dropTermsChecks(for:)`) is no longer here when it answers.
    @ObservationIgnored private var termsChecks: [UUID: UUID] = [:]

    init(backend: Backend, toasts: ToastCenter) {
        self.backend = backend
        self.toasts = toasts
    }

    // MARK: Derived

    /// Quotes you have not opened yet.
    var unseenQuotes: [InboxQuote] { inbox.filter { unreadInboxIDs.contains($0.id) } }
    /// The number of unseen quotes.
    var unseenCount: Int { unreadInboxIDs.count }
    /// The Friends tab badge: incoming requests plus unseen quotes.
    var badgeCount: Int { incomingRequests.count + unseenCount }
    /// Your friends' profiles, by name (the share sheet).
    var friendProfiles: [Profile] { friends.map(\.profile) }

    /// "From Maya", "From Maya and Jordan" or "From Maya, Jordan and 2 others" for unseen quotes, or nil.
    var unseenSummary: String? {
        Self.fromSummary(Self.senderNames(unseenQuotes))
    }

    /// The senders of unseen quotes, newest first, without repeats (for `AvatarStack`).
    var unseenSenders: [Profile] {
        Self.senders(unseenQuotes)
    }

    /// "From Maya", "From Maya and Jordan" or "From Maya, Jordan and 2 others" for every quote in the
    /// inbox (seen or not), or nil when it is empty. Friends' "N shared with you" row.
    var inboxSummary: String? {
        Self.fromSummary(Self.senderNames(inbox))
    }

    /// The senders of every quote in the inbox, newest first, without repeats (for `AvatarStack`).
    var inboxSenders: [Profile] {
        Self.senders(inbox)
    }

    /// Your connection (friend or request) with a user, if any.
    func connection(with userID: UUID) -> Connection? {
        (friends + incomingRequests + outgoingRequests).first { $0.profile.id == userID }
    }

    // MARK: Loading

    /// Fetches friendships, conversations and the quote messages sent to you: three reads, whatever
    /// the number of conversations. Calls made while a refresh runs join it; a result that overlapped
    /// a write is dropped and fetched again once the writes settle. Failures set `lastError`; with
    /// `userInitiated` they also toast. Returns whether the server answered.
    @discardableResult
    func refresh(userInitiated: Bool = false) async -> Bool {
        let outcome = await sharedRefresh()
        if userInitiated, case .failed(let error) = outcome {
            toasts.show(error: error)
        }
        return outcome.serverAnswered
    }

    /// Refreshes only if the last refresh is older than `maxAge` seconds.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastRefreshed, Date.now.timeIntervalSince(lastRefreshed) < maxAge { return }
        await refresh()
    }

    /// Loads `blockedUsers` (Blocked users screen). A block or unblock still in flight keeps its
    /// local result. Someone who blocked you back comes without a profile; the one this session
    /// already knew stays.
    @discardableResult
    func loadBlocked(toastOnFailure: Bool = true) async -> Bool {
        let generation = self.generation
        let token = writes.token
        do {
            let users = try await backend.social.blockedUsers()
            guard self.generation == generation else { return false }
            if writes.isQuiet(since: token) {
                let known = Dictionary(blockedUsers.compactMap { user in user.profile.map { (user.id, $0) } }) { first, _ in first }
                blockedUsers = users.map { BlockedUser(id: $0.id, profile: $0.profile ?? known[$0.id]) }
            }
            return true
        } catch {
            if toastOnFailure, self.generation == generation { toasts.show(error: error) }
            return false
        }
    }

    // MARK: Profiles

    /// Someone's profile page (`profile_view`): their profile as it is now, how you stand with them,
    /// and their favorites when they share them with you (nil when they don't). Nil when the profile
    /// is gone or they blocked you. Throws, so `ProfileView` can show its own error.
    func profilePage(of profile: Profile) async throws -> ProfilePage? {
        try await backend.profiles.profileView(username: profile.username)
    }

    // MARK: Terms of Use

    /// Runs `action` (a friend request, accepting one, a send) once the current Terms of Use are
    /// accepted (docs/ui-spec.md §22), and returns when it has run, the Terms sheet is up, or the
    /// check failed (toasted). Accepted already: it runs now. Otherwise the Terms sheet stacks over
    /// whatever asked; Accept runs it, Not Now drops it. The account's cached answer is trusted only
    /// when it says yes; anything else asks the server first, so keep the control's progress on
    /// while this awaits. A request still waiting is replaced by the newer one: a tap is never
    /// dropped without a word.
    ///
    /// `owner` names the screen or sheet that asked: when it goes away (it calls
    /// `dropTermsChecks(for:)` from `onDisappear`) before the server answers, the answer shows
    /// nothing and runs nothing, so a send the user cancelled never comes back as a Terms sheet over
    /// another screen. A cancelled task drops its check the same way.
    func requireTerms(for owner: UUID? = nil, then action: @escaping @MainActor () async -> Void) async {
        guard let session, termsMayBeOutdated || session.account?.hasAcceptedCurrentTerms != true else {
            await action()
            return
        }
        let generation = self.generation
        let check = UUID()
        if let owner { termsChecks[check] = owner }
        let account: MyAccount?
        do {
            account = try await session.reloadAccount()
        } catch {
            guard takeTermsCheck(check, owner: owner), self.generation == generation else { return }
            toasts.show(error: error)
            return
        }
        guard takeTermsCheck(check, owner: owner), self.generation == generation, let account else { return }
        termsMayBeOutdated = false
        if account.hasAcceptedCurrentTerms {
            await action()
        } else {
            termsRequest = TermsRequest(
                owner: owner, isUpdate: account.needsUpdatedTerms, version: account.currentTermsVersion, action: action
            )
        }
    }

    /// The screen or sheet `owner` went away: its terms checks still waiting for the server end
    /// without a word, and its write waiting on the Terms sheet is dropped (the sheet closes).
    func dropTermsChecks(for owner: UUID) {
        termsChecks = termsChecks.filter { $0.value != owner }
        if termsRequest?.owner == owner { termsRequest = nil }
    }

    /// Ends a terms check: whether its answer still counts (its task was not cancelled, and its
    /// owner, if any, is still there).
    private func takeTermsCheck(_ check: UUID, owner: UUID?) -> Bool {
        let ownerStayed = owner == nil || termsChecks.removeValue(forKey: check) != nil
        return ownerStayed && !Task.isCancelled
    }

    /// Accept on the Terms sheet: `accept_terms(version)`, then closes the sheet and runs the waiting
    /// write. A failure toasts and keeps the sheet (when the terms changed meanwhile, the next Accept
    /// agrees to the new version). Returns whether it worked.
    @discardableResult
    func acceptTerms() async -> Bool {
        guard let request = termsRequest else { return false }
        let generation = self.generation
        let assertion = BackgroundTaskAssertion("Accept terms")
        defer { assertion.end() }
        do {
            try await backend.profiles.acceptTerms(version: request.version)
            guard self.generation == generation, termsRequest?.id == request.id else { return false }
            session?.noteTermsAccepted(version: request.version)
            termsMayBeOutdated = false
            termsRequest = nil
            await request.action()
            return true
        } catch {
            guard self.generation == generation else { return false }
            toasts.show(error: error)
            if let account = try? await session?.reloadAccount(), termsRequest?.id == request.id {
                termsRequest?.version = account.currentTermsVersion
            }
            return false
        }
    }

    /// Not Now on the Terms sheet (or a swipe down): drops the waiting write.
    func cancelTerms() {
        termsRequest = nil
    }

    // MARK: Requests

    /// Sends a friend request by exact username ("@maya" or "maya"), shows the result as a toast and
    /// returns it. Run it through `requireTerms(for:then:)`.
    @discardableResult
    func sendRequest(toUsername input: String) async -> FriendRequestResult {
        let handle = "@\(Username.normalize(input))"
        let generation = self.generation
        beginWrite()
        let assertion = BackgroundTaskAssertion("Send friend request")
        defer {
            assertion.end()
            endWrite()
        }
        let result: FriendRequestResult
        do {
            let row = try await backend.social.sendFriendRequest(toUsername: input)
            guard self.generation == generation else { return FriendRequestResult(isSuccess: false, message: "") }
            if let me = backend.auth.currentUserID, let connection = Self.connection(from: row, me: me) {
                outgoingRequests.removeAll { $0.id == connection.id }
                outgoingRequests.insert(connection, at: 0)
            }
            result = FriendRequestResult(isSuccess: true, message: "Request sent to \(handle)")
            Haptics.success()
        } catch {
            let mapped = QuotedError(error)
            noteRefusal(mapped)
            let message = mapped == .notFound
                ? "No user named \(handle)"
                : (ToastCenter.message(for: mapped) ?? mapped.userMessage)
            result = FriendRequestResult(isSuccess: false, message: message)
        }
        toasts.show(result.message, style: result.isSuccess ? .success : .error)
        return result
    }

    /// Accepts an incoming request. Run it through `requireTerms(for:then:)`.
    @discardableResult
    func accept(_ request: Connection) async -> Bool {
        guard incomingRequests.contains(where: { $0.id == request.id }) else { return false }
        let generation = self.generation
        incomingRequests.removeAll { $0.id == request.id }
        let friend = Connection(id: request.id, kind: .friend, profile: request.profile, createdAt: request.createdAt)
        friends = Self.sortedByName(friends.filter { $0.id != request.id } + [friend])
        beginWrite()
        let assertion = BackgroundTaskAssertion("Accept friend request")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            _ = try await backend.social.accept(friendshipID: request.id)
            Haptics.success()
            return true
        } catch {
            guard self.generation == generation else { return false }
            noteRefusal(QuotedError(error))
            // Undo only this accept: other requests may have changed meanwhile.
            friends.removeAll { $0.id == request.id }
            reinsert(request)
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Declines an incoming request.
    @discardableResult
    func decline(_ request: Connection) async -> Bool {
        await removeConnection(request)
    }

    /// Cancels a request you sent.
    @discardableResult
    func cancel(_ request: Connection) async -> Bool {
        await removeConnection(request)
    }

    /// Unfriends. Your conversation stays, read only, until you are friends again.
    @discardableResult
    func removeFriend(_ friend: Connection) async -> Bool {
        await removeConnection(friend)
    }

    // MARK: Blocks and reports

    /// Blocks a user. Their friendship and requests disappear at once (the server ends them too and
    /// closes your conversation; its messages stay, read only, so they can still be reported). Shows
    /// "Blocked @name".
    @discardableResult
    func block(_ profile: Profile) async -> Bool {
        let generation = self.generation
        let removedConnections = (friends + incomingRequests + outgoingRequests).filter { $0.profile.id == profile.id }
        let wasBlocked = blockedUsers.contains { $0.id == profile.id }
        friends.removeAll { $0.profile.id == profile.id }
        incomingRequests.removeAll { $0.profile.id == profile.id }
        outgoingRequests.removeAll { $0.profile.id == profile.id }
        if !wasBlocked {
            blockedUsers.insert(BlockedUser(profile), at: 0)
        }
        beginWrite()
        let assertion = BackgroundTaskAssertion("Block user")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            try await backend.social.block(userID: profile.id)
            guard self.generation == generation else { return false }
            Haptics.warning()
            toasts.show("Blocked \(profile.handle)")
            return true
        } catch {
            guard self.generation == generation else { return false }
            // Put back only what this block removed.
            for connection in removedConnections { reinsert(connection) }
            if !wasBlocked { blockedUsers.removeAll { $0.id == profile.id } }
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Blocks the sender of a quote (uses the Inbox row's profile when there is one).
    @discardableResult
    func blockSender(of item: InboxQuote) async -> Bool {
        let profile = item.sender ?? connection(with: item.senderID)?.profile
            ?? Profile(id: item.senderID, username: "user")
        return await block(profile)
    }

    /// Unblocks a user (also one who blocked you back, whose profile you can't see). The friendship
    /// the block ended does not come back.
    @discardableResult
    func unblock(_ user: BlockedUser) async -> Bool {
        let generation = self.generation
        let index = blockedUsers.firstIndex { $0.id == user.id }
        blockedUsers.removeAll { $0.id == user.id }
        beginWrite()
        let assertion = BackgroundTaskAssertion("Unblock user")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            try await backend.social.unblock(userID: user.id)
            guard self.generation == generation else { return false }
            toasts.show(user.profile.map { "Unblocked \($0.handle)" } ?? "Unblocked")
            return true
        } catch {
            guard self.generation == generation else { return false }
            if let index, !blockedUsers.contains(where: { $0.id == user.id }) {
                blockedUsers.insert(user, at: min(index, blockedUsers.count))
            }
            toasts.show(error: error)
            return false
        }
    }

    /// Reports a quote a friend sent you (the message and its sender; the server copies the content).
    /// Shows "Thanks, we'll review it". The server hides the message from you at once: Save turns off
    /// for it, and its card stays only until `hideReported(_:)` (after the "Also block?" offer).
    @discardableResult
    func report(_ item: InboxQuote, reason: ReportReason, details: String? = nil) async -> Bool {
        let assertion = BackgroundTaskAssertion("Report quote")
        defer { assertion.end() }
        do {
            try await backend.reports.report(
                .message(id: item.id, senderID: item.senderID),
                reason: reason,
                details: details,
                seen: ReportContent(message: item.message)
            )
            reportedMessageIDs.insert(item.id)
            reportsOnScreen.insert(item.id)
            toasts.show("Thanks, we\u{2019}ll review it", style: .success)
            return true
        } catch {
            toasts.show(error: error)
            return false
        }
    }

    /// Reports a user without a specific quote (a friend or request row, a profile). Shows "Thanks,
    /// we'll review it".
    @discardableResult
    func reportUser(_ userID: UUID, reason: ReportReason, details: String? = nil) async -> Bool {
        let assertion = BackgroundTaskAssertion("Report user")
        defer { assertion.end() }
        do {
            try await backend.reports.report(.profile(userID: userID), reason: reason, details: details)
            toasts.show("Thanks, we\u{2019}ll review it", style: .success)
            return true
        } catch {
            toasts.show(error: error)
            return false
        }
    }

    // MARK: Sending

    /// Sends one of your quotes to friends with an optional note (up to 280 characters): one quote
    /// message in your conversation with each friend (`open_conversation`, then the message), each
    /// with its own ID. Waits for the server; show progress on Send while it runs. Run it through
    /// `requireTerms(for:then:)`.
    ///
    /// - All sent: "Sent to Maya" with Undo for 5 seconds (Undo unsends them); returns true.
    /// - Some failed: "Sent to Maya. Couldn't send to @sam." with Undo for the ones delivered; true.
    /// - All failed: toasts the error and returns false, so the sheet keeps the selection and note.
    ///   Send again reuses the message IDs, so a first try whose answer was lost isn't sent twice.
    @discardableResult
    func send(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) async -> Bool {
        guard let outgoing = prepareSend(quote, to: recipientIDs, note: note) else { return false }
        let generation = self.generation
        let assertion = BackgroundTaskAssertion("Send quote")
        defer { assertion.end() }
        let results = await Self.deliver(outgoing, backend: backend)
        guard self.generation == generation else { return false }
        let delivered = outgoing.recipients.compactMap { id in results.sent[id].map { (recipient: id, messageID: $0) } }
        let failed = outgoing.recipients.filter { results.failed[$0] != nil }
        for error in results.failed.values { noteRefusal(error) }
        guard !delivered.isEmpty else {
            retrySendIDs[outgoing.key] = outgoing.messageIDs
            let error = outgoing.recipients.lazy.compactMap { results.failed[$0] }.first ?? .server("Nothing was sent")
            Logger.social.error("Send failed: \(String(describing: error), privacy: .public)")
            toasts.show(error: error, failure: "Couldn\u{2019}t send")
            return false
        }
        retrySendIDs[outgoing.key] = nil
        var message = Self.sentMessage(delivered.map { name(of: $0.recipient) })
        if !failed.isEmpty {
            message += ". " + Self.notSentMessage(failed.map { handle(of: $0) })
        }
        let sentIDs = delivered.map(\.messageID)
        toasts.show(message) { [weak self] in
            await self?.unsend(sentIDs, generation: generation)
        }
        Haptics.success()
        return true
    }

    // MARK: Inbox

    /// Marks the conversations with an unseen quote read (opening Friends or the inbox), each up to
    /// the newest quote the app shows from it (`InboxConversation.seenMarks`), so those quotes count
    /// as seen. Nothing later: a message the app has not fetched or shown (a text, or a quote that
    /// arrived after the last refresh) stays unread and comes up as new. Optimistic; failures are
    /// logged.
    func markInboxSeen() async {
        let shown = inbox.map(\.message)
        let times = InboxConversation.seenMarks(conversations, shown: shown)
        var marks: [(id: UUID, time: Date)] = []
        for index in conversations.indices {
            guard let time = times[conversations[index].id] else { continue }
            marks.append((conversations[index].id, time))
            conversations[index] = conversations[index].markedRead(upTo: time, shown: shown)
        }
        guard !marks.isEmpty else { return }
        let generation = self.generation
        rebuildInbox()
        beginWrite()
        defer { endWrite() }
        let backend = self.backend
        let failures = await withTaskGroup(of: Bool.self) { group in
            for mark in marks {
                group.addTask {
                    do {
                        try await backend.messages.markRead(conversationID: mark.id, upTo: mark.time)
                        return false
                    } catch {
                        return !(error is CancellationError)
                    }
                }
            }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }
        guard self.generation == generation else { return }
        if failures > 0 {
            Logger.social.error("Marking \(failures, privacy: .public) conversations read failed")
            refreshAfterWrites = true
        }
        library?.writeCache()
    }

    /// The card of a reported quote can go now (the "Also block?" offer was answered).
    func hideReported(_ messageID: UUID) {
        guard reportsOnScreen.remove(messageID) != nil else { return }
        rebuildInbox()
        library?.writeCache()
    }

    /// Shows the cached inbox (with each conversation's read mark) before the first refresh (called
    /// by `LibraryStore.prepare`). The first refresh replaces it.
    func restoreCachedInbox(messages: [ConversationMessage], conversations: [InboxConversation]) {
        guard !hasLoaded else { return }
        self.conversations = conversations
        receivedMessages = Self.newestFirst(messages)
        rebuildInbox()
    }

    // MARK: Reset

    /// Forgets everything (sign-out). Results of requests still in flight are dropped.
    func reset() {
        friends = []
        incomingRequests = []
        outgoingRequests = []
        conversations = []
        inbox = []
        unreadInboxIDs = []
        reportedMessageIDs = []
        blockedUsers = []
        hasLoaded = false
        isRefreshing = false
        lastError = nil
        termsRequest = nil
        termsChecks = [:]
        lastRefreshed = nil
        refreshAfterWrites = false
        refreshTask = nil
        refreshSerial += 1
        generation += 1
        receivedMessages = []
        reportsOnScreen = []
        retrySendIDs = [:]
        termsMayBeOutdated = false
    }

    /// Seeds state for SwiftUI previews.
    func seedPreview(friendships: [Friendship], conversations: [InboxConversation], messages: [ConversationMessage], me: UUID) {
        apply(friendships, me: me)
        self.conversations = conversations
        receivedMessages = Self.newestFirst(messages.filter { $0.senderID != me })
        rebuildInbox()
        hasLoaded = true
    }

    // MARK: Private: refresh

    private func sharedRefresh() async -> RefreshOutcome {
        if let running = refreshTask {
            return await running.value
        }
        refreshSerial += 1
        let serial = refreshSerial
        let task = Task { () -> RefreshOutcome in
            let outcome = await self.performRefresh()
            // Runs on the main actor right after the fetch, before any caller resumes.
            if self.refreshSerial == serial { self.refreshTask = nil }
            return outcome
        }
        refreshTask = task
        return await task.value
    }

    private func performRefresh() async -> RefreshOutcome {
        guard let me = backend.auth.currentUserID else { return .skipped }
        let generation = self.generation
        let token = writes.token
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let friendships = backend.social.friendships()
            async let inboxRows = backend.messages.inbox()
            async let received = backend.messages.receivedQuotes()
            let (rows, fetchedConversations, messages) = try await (friendships, inboxRows, received)
            // The user may have signed out (or switched) while the request was in flight.
            guard backend.auth.currentUserID == me, self.generation == generation else { return .skipped }
            guard writes.isQuiet(since: token) else {
                Logger.social.debug("Dropped a social refresh that overlapped a write")
                refreshAfterWrites = true
                refreshIfWritesSettled()
                return .superseded
            }
            apply(rows, me: me)
            conversations = fetchedConversations
            receivedMessages = messages
            rebuildInbox()
            hasLoaded = true
            lastError = nil
            lastRefreshed = .now
            library?.writeCache()
            return .applied
        } catch is CancellationError {
            return .skipped
        } catch {
            guard self.generation == generation else { return .skipped }
            let mapped = QuotedError(error)
            lastError = mapped
            Logger.social.error("Social refresh failed: \(String(describing: mapped), privacy: .public)")
            return .failed(mapped)
        }
    }

    /// Rebuilds `inbox` and `unreadInboxIDs` from the received quote messages and the conversations
    /// (the sender's profile, your read mark). A quote is unseen while it is newer than your read
    /// mark in its conversation. A reported quote is left out once its card may go.
    private func rebuildInbox() {
        let byID = Dictionary(conversations.map { ($0.id, $0) }) { first, _ in first }
        var items: [InboxQuote] = []
        var unread: Set<UUID> = []
        for message in receivedMessages {
            if reportedMessageIDs.contains(message.id), !reportsOnScreen.contains(message.id) { continue }
            let conversation = byID[message.conversationID]
            guard let item = InboxQuote(message: message, sender: conversation?.other) else { continue }
            items.append(item)
            if conversation?.isUnread(message) ?? false { unread.insert(item.id) }
        }
        inbox = Self.newestFirst(items)
        unreadInboxIDs = unread
    }

    private func beginWrite() {
        writes.begin()
    }

    private func endWrite() {
        writes.end()
        refreshIfWritesSettled()
    }

    private func refreshIfWritesSettled() {
        guard refreshAfterWrites, writes.isIdle, backend.auth.currentUserID != nil else { return }
        refreshAfterWrites = false
        Task { await self.refresh() }
    }

    /// A refusal for the terms means the cached account was out of date: ask the server next time.
    private func noteRefusal(_ error: QuotedError) {
        if error == .termsRequired { termsMayBeOutdated = true }
    }

    // MARK: Private: sending

    /// A validated send.
    private struct OutgoingSend: Sendable {
        let quoteID: UUID
        let recipients: [UUID]
        let note: String?
        /// The new messages' IDs by recipient, chosen before sending.
        let messageIDs: [UUID: UUID]
        let key: SendKey
    }

    /// One send's identity for ``retrySendIDs``.
    private struct SendKey: Hashable, Sendable {
        let quoteID: UUID
        let recipients: Set<UUID>
        let note: String?
    }

    /// What each recipient's send came to.
    private struct DeliveryResults: Sendable {
        var sent: [UUID: UUID] = [:]
        var failed: [UUID: QuotedError] = [:]
    }

    /// Validates recipients and the note, toasting the problem and returning nil when invalid.
    private func prepareSend(_ quote: Quote, to recipientIDs: [UUID], note: String?) -> OutgoingSend? {
        let recipients = recipientIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !recipients.isEmpty else {
            toasts.show("Choose at least one friend.", style: .error)
            return nil
        }
        let cleanNote: String?
        do {
            cleanNote = try SocialText.note(note)
        } catch {
            toasts.show(error.errorDescription ?? "The note is too long.", style: .error)
            return nil
        }
        let key = SendKey(quoteID: quote.id, recipients: Set(recipients), note: cleanNote)
        let messageIDs = retrySendIDs[key] ?? Dictionary(uniqueKeysWithValues: recipients.map { ($0, UUID()) })
        return OutgoingSend(quoteID: quote.id, recipients: recipients, note: cleanNote, messageIDs: messageIDs, key: key)
    }

    /// Opens each recipient's conversation and sends the quote there, all at once.
    nonisolated private static func deliver(_ outgoing: OutgoingSend, backend: Backend) async -> DeliveryResults {
        await withTaskGroup(of: (UUID, Result<UUID, QuotedError>).self) { group in
            for recipient in outgoing.recipients {
                let messageID = outgoing.messageIDs[recipient] ?? UUID()
                group.addTask {
                    do {
                        let conversation = try await backend.messages.openConversation(with: recipient)
                        let sent = try await backend.messages.send(
                            .quote(.quote(outgoing.quoteID), note: outgoing.note),
                            in: conversation.id,
                            id: messageID
                        )
                        return (recipient, .success(sent.id))
                    } catch {
                        return (recipient, .failure(QuotedError(error)))
                    }
                }
            }
            var results = DeliveryResults()
            for await (recipient, result) in group {
                switch result {
                case .success(let id): results.sent[recipient] = id
                case .failure(let error): results.failed[recipient] = error
                }
            }
            return results
        }
    }

    /// Undo for a send: unsends the messages it delivered.
    private func unsend(_ messageIDs: [UUID], generation: Int) async {
        let assertion = BackgroundTaskAssertion("Undo send")
        defer { assertion.end() }
        let backend = self.backend
        let failure = await withTaskGroup(of: QuotedError?.self) { group in
            for id in messageIDs {
                group.addTask {
                    do {
                        try await backend.messages.unsend(messageID: id)
                        return nil
                    } catch {
                        return QuotedError(error)
                    }
                }
            }
            var first: QuotedError?
            for await error in group where first == nil { first = error }
            return first
        }
        guard self.generation == generation, let failure else { return }
        toasts.show(error: failure, failure: "Couldn\u{2019}t undo")
    }

    /// A friend's first name for "Sent to Maya".
    private func name(of id: UUID) -> String {
        friends.first { $0.profile.id == id }.map { Self.firstName($0.profile.displayName) } ?? "a friend"
    }

    /// A friend's handle for "Couldn't send to @sam".
    private func handle(of id: UUID) -> String {
        connection(with: id)?.profile.handle ?? "a friend"
    }

    // MARK: Private

    private func removeConnection(_ connection: Connection) async -> Bool {
        let generation = self.generation
        let removed = (friends + incomingRequests + outgoingRequests).filter { $0.id == connection.id }
        friends.removeAll { $0.id == connection.id }
        incomingRequests.removeAll { $0.id == connection.id }
        outgoingRequests.removeAll { $0.id == connection.id }
        beginWrite()
        let assertion = BackgroundTaskAssertion("Update friends")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            try await backend.social.remove(friendshipID: connection.id)
            return true
        } catch {
            guard self.generation == generation else { return false }
            for row in removed { reinsert(row) }
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Puts one connection back into the list for its kind (if it is not there already).
    private func reinsert(_ connection: Connection) {
        guard !(friends + incomingRequests + outgoingRequests).contains(where: { $0.id == connection.id }) else { return }
        switch connection.kind {
        case .friend:
            friends = Self.sortedByName(friends + [connection])
        case .incoming:
            incomingRequests = Self.newestFirst(incomingRequests + [connection])
        case .outgoing:
            outgoingRequests = Self.newestFirst(outgoingRequests + [connection])
        }
    }

    private func apply(_ rows: [Friendship], me: UUID) {
        let connections = rows.compactMap { Self.connection(from: $0, me: me) }
        friends = Self.sortedByName(connections.filter { $0.kind == .friend })
        incomingRequests = connections.filter { $0.kind == .incoming }
        outgoingRequests = connections.filter { $0.kind == .outgoing }
    }

    private static func connection(from row: Friendship, me: UUID) -> Connection? {
        let otherID = row.otherPartyID(for: me)
        let profile = row.otherParty(for: me) ?? Profile(id: otherID, username: "user")
        let kind: Connection.Kind
        switch row.status {
        case .accepted: kind = .friend
        case .pending: kind = row.isIncomingRequest(for: me) ? .incoming : .outgoing
        }
        return Connection(id: row.id, kind: kind, profile: profile, createdAt: row.createdAt)
    }

    private static func sortedByName(_ connections: [Connection]) -> [Connection] {
        connections.sorted { $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending }
    }

    private static func newestFirst(_ connections: [Connection]) -> [Connection] {
        connections.sorted { $0.createdAt > $1.createdAt }
    }

    private static func newestFirst(_ items: [InboxQuote]) -> [InboxQuote] {
        items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func newestFirst(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func senderNames(_ items: [InboxQuote]) -> [String] {
        var names: [String] = []
        for item in items {
            let name = firstName(item.sender?.displayName ?? "a friend")
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func senders(_ items: [InboxQuote]) -> [Profile] {
        var seen: Set<UUID> = []
        return items.compactMap(\.sender).filter { seen.insert($0.id).inserted }
    }

    private static func fromSummary(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "From \(names[0])"
        case 2: return "From \(names[0]) and \(names[1])"
        default:
            let others = names.count - 2
            return "From \(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    private static func sentMessage(_ names: [String]) -> String {
        switch names.count {
        case 1: "Sent to \(names[0])"
        case 2: "Sent to \(names[0]) and \(names[1])"
        default: "Sent to \(names.count) friends"
        }
    }

    /// "Couldn't send to @sam." / "Couldn't send to @sam and @lee." / "Couldn't send to 3 friends."
    private static func notSentMessage(_ handles: [String]) -> String {
        switch handles.count {
        case 1: "Couldn\u{2019}t send to \(handles[0])."
        case 2: "Couldn\u{2019}t send to \(handles[0]) and \(handles[1])."
        default: "Couldn\u{2019}t send to \(handles.count) friends."
        }
    }
}
