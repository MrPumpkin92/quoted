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

/// Friends, requests, the shared inbox, blocks and reports.
///
/// The signed-in user's own profile lives in `SessionStore.profile`. Mutations are optimistic, roll
/// back only what they changed and toast on failure, and return whether they worked. Server writes
/// run under a `BackgroundTaskAssertion`. Refreshes are single-flight, and one that overlapped a write
/// is dropped and repeated once the writes settle (see `WriteTracker`).
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
    /// Quotes shared with you, newest first (also cached for offline search).
    private(set) var inbox: [SharedQuote] = []
    /// People you blocked (load with `loadBlocked()`).
    private(set) var blockedProfiles: [Profile] = []
    /// True once the server has answered (or the cache was restored for the inbox).
    private(set) var hasLoaded = false
    /// True while `refresh()` runs.
    private(set) var isRefreshing = false
    /// The last refresh error, cleared by the next success.
    private(set) var lastError: QuotedError?

    // MARK: Dependencies

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private var lastRefreshed: Date?
    /// Server writes in flight that change friends, requests, the inbox or blocks.
    @ObservationIgnored private var writes = WriteTracker()
    @ObservationIgnored private var refreshAfterWrites = false
    @ObservationIgnored private var refreshTask: Task<RefreshOutcome, Never>?
    @ObservationIgnored private var refreshSerial = 0
    /// Bumped by `reset()`, so results that arrive after a sign-out are dropped.
    @ObservationIgnored private var generation = 0
    /// Share IDs of a send that failed, by quote, recipients and note, so Send again reuses them:
    /// if the first attempt landed and only its answer was lost, the retry finds those shares
    /// instead of sending a second copy (`SocialRepository.share(_:to:note:ids:)`).
    @ObservationIgnored private var retryShareIDs: [ShareKey: [UUID: UUID]] = [:]

    init(backend: Backend, toasts: ToastCenter) {
        self.backend = backend
        self.toasts = toasts
    }

    // MARK: Derived

    /// Shares you have not opened yet.
    var unseenShares: [SharedQuote] { inbox.filter { !$0.isSeen } }
    /// The number of unseen shares.
    var unseenCount: Int { inbox.reduce(0) { $0 + ($1.isSeen ? 0 : 1) } }
    /// The Friends tab badge: incoming requests plus unseen shares.
    var badgeCount: Int { incomingRequests.count + unseenCount }
    /// Your friends' profiles, by name (the share sheet).
    var friendProfiles: [Profile] { friends.map(\.profile) }

    /// "From Maya", "From Maya and Jordan" or "From Maya, Jordan and 2 others" for unseen shares, or nil.
    var unseenSummary: String? {
        var names: [String] = []
        for share in unseenShares {
            let name = Self.firstName(share.sender?.displayName ?? "a friend")
            if !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0: return nil
        case 1: return "From \(names[0])"
        case 2: return "From \(names[0]) and \(names[1])"
        default:
            let others = names.count - 2
            return "From \(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
    }

    /// The senders of unseen shares, newest first, without repeats (for `AvatarStack`).
    var unseenSenders: [Profile] {
        var seen: Set<UUID> = []
        return unseenShares.compactMap(\.sender).filter { seen.insert($0.id).inserted }
    }

    /// "From Maya", "From Maya and Jordan" or "From Maya, Jordan and 2 others" for every share in the
    /// inbox (seen or not), or nil when it is empty. Friends' "N shared with you" row.
    var inboxSummary: String? {
        Self.fromSummary(inboxSenderNames)
    }

    /// The senders of every share in the inbox, newest first, without repeats (for `AvatarStack`).
    var inboxSenders: [Profile] {
        var seen: Set<UUID> = []
        return inbox.compactMap(\.sender).filter { seen.insert($0.id).inserted }
    }

    private var inboxSenderNames: [String] {
        var names: [String] = []
        for share in inbox {
            let name = Self.firstName(share.sender?.displayName ?? "a friend")
            if !names.contains(name) { names.append(name) }
        }
        return names
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

    /// Your connection (friend or request) with a user, if any.
    func connection(with userID: UUID) -> Connection? {
        (friends + incomingRequests + outgoingRequests).first { $0.profile.id == userID }
    }

    // MARK: Loading

    /// Fetches friendships and the inbox together. Calls made while a refresh runs join it; a result
    /// that overlapped a write is dropped and fetched again once the writes settle. Failures set
    /// `lastError`; with `userInitiated` they also toast. Returns whether the server answered.
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

    /// Loads `blockedProfiles` (Blocked users screen). A block or unblock still in flight keeps its
    /// local result.
    @discardableResult
    func loadBlocked(toastOnFailure: Bool = true) async -> Bool {
        let generation = self.generation
        let token = writes.token
        do {
            let profiles = try await backend.social.blockedProfiles()
            guard self.generation == generation else { return false }
            if writes.isQuiet(since: token) {
                blockedProfiles = profiles
            }
            return true
        } catch {
            if toastOnFailure, self.generation == generation { toasts.show(error: error) }
            return false
        }
    }

    // MARK: Requests

    /// Sends a friend request by exact username ("@maya" or "maya"), shows the result as a toast and
    /// returns it.
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
            let message = mapped == .notFound
                ? "No user named \(handle)"
                : (ToastCenter.message(for: mapped) ?? mapped.userMessage)
            result = FriendRequestResult(isSuccess: false, message: message)
        }
        toasts.show(result.message, style: result.isSuccess ? .success : .error)
        return result
    }

    /// Accepts an incoming request.
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

    /// Unfriends.
    @discardableResult
    func removeFriend(_ friend: Connection) async -> Bool {
        await removeConnection(friend)
    }

    // MARK: Blocks and reports

    /// Blocks a user. Their friendship, requests and shares disappear at once (the server deletes them
    /// too). Shows "Blocked @name".
    @discardableResult
    func block(_ profile: Profile) async -> Bool {
        let generation = self.generation
        let removedConnections = (friends + incomingRequests + outgoingRequests).filter { $0.profile.id == profile.id }
        let removedShares = inbox.filter { $0.senderID == profile.id }
        let wasBlocked = blockedProfiles.contains { $0.id == profile.id }
        friends.removeAll { $0.profile.id == profile.id }
        incomingRequests.removeAll { $0.profile.id == profile.id }
        outgoingRequests.removeAll { $0.profile.id == profile.id }
        inbox.removeAll { $0.senderID == profile.id }
        if !wasBlocked {
            blockedProfiles.insert(profile, at: 0)
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
            library?.writeCache()
            Haptics.warning()
            toasts.show("Blocked \(profile.handle)")
            return true
        } catch {
            guard self.generation == generation else { return false }
            // Put back only what this block removed.
            for connection in removedConnections { reinsert(connection) }
            let present = Set(inbox.map(\.id))
            inbox = Self.newestFirst(inbox + removedShares.filter { !present.contains($0.id) })
            if !wasBlocked { blockedProfiles.removeAll { $0.id == profile.id } }
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Blocks the sender of a share (uses the embedded sender profile when there is one).
    @discardableResult
    func blockSender(of share: SharedQuote) async -> Bool {
        let profile = share.sender ?? connection(with: share.senderID)?.profile
            ?? Profile(id: share.senderID, username: "user")
        return await block(profile)
    }

    /// Unblocks a user. Removed friendships and shares do not come back.
    @discardableResult
    func unblock(_ profile: Profile) async -> Bool {
        let generation = self.generation
        let index = blockedProfiles.firstIndex { $0.id == profile.id }
        blockedProfiles.removeAll { $0.id == profile.id }
        beginWrite()
        let assertion = BackgroundTaskAssertion("Unblock user")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            try await backend.social.unblock(userID: profile.id)
            guard self.generation == generation else { return false }
            toasts.show("Unblocked \(profile.handle)")
            return true
        } catch {
            guard self.generation == generation else { return false }
            if let index, !blockedProfiles.contains(where: { $0.id == profile.id }) {
                blockedProfiles.insert(profile, at: min(index, blockedProfiles.count))
            }
            toasts.show(error: error)
            return false
        }
    }

    /// Reports a share you received. Shows "Thanks, we'll review it".
    @discardableResult
    func report(_ share: SharedQuote, reason: ReportReason, details: String? = nil) async -> Bool {
        let assertion = BackgroundTaskAssertion("Report quote")
        defer { assertion.end() }
        do {
            try await backend.social.report(share: share, reason: reason, details: details)
            toasts.show("Thanks, we\u{2019}ll review it", style: .success)
            return true
        } catch {
            toasts.show(error: error)
            return false
        }
    }

    /// Reports a user without a specific share (a friend or request row, a profile). Shows "Thanks,
    /// we'll review it".
    @discardableResult
    func reportUser(_ userID: UUID, reason: ReportReason, details: String? = nil) async -> Bool {
        let assertion = BackgroundTaskAssertion("Report user")
        defer { assertion.end() }
        do {
            try await backend.social.report(userID: userID, reason: reason, details: details)
            toasts.show("Thanks, we\u{2019}ll review it", style: .success)
            return true
        } catch {
            toasts.show(error: error)
            return false
        }
    }

    /// Reports a share, then blocks its sender, in the order the server needs (a block deletes the
    /// share, so the report must be filed first).
    @discardableResult
    func reportAndBlock(_ share: SharedQuote, reason: ReportReason, details: String? = nil) async -> Bool {
        guard await report(share, reason: reason, details: details) else { return false }
        return await blockSender(of: share)
    }

    // MARK: Sharing

    /// Sends `quote` to friends with an optional note (up to 280 characters) at once and shows "Sent to
    /// Maya" with Undo for 5 seconds; Undo deletes the sent shares. Returns false (with a toast) when
    /// there is no recipient or the note is too long; the sheet can dismiss on true. A send that then
    /// fails shows "Couldn't send. …". Prefer `send(_:to:note:)` when the sheet should stay open on
    /// failure.
    @discardableResult
    func share(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) -> Bool {
        guard let outgoing = prepareShare(quote, to: recipientIDs, note: note) else { return false }
        let attempt = ShareAttempt()
        let sending = startSending(outgoing, attempt: attempt)
        toasts.show(outgoing.message) { [weak self] in
            await self?.unsend(sending, outgoing: outgoing, attempt: attempt)
        }
        Haptics.success()
        return true
    }

    /// Like `share(_:to:note:)`, but waits for the server: on success shows "Sent to Maya" with Undo
    /// and returns true (dismiss the sheet); on failure toasts "Couldn't send. …" and returns false, so
    /// the sheet keeps the selection and the note. Show progress on Send while it runs.
    @discardableResult
    func send(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) async -> Bool {
        guard let outgoing = prepareShare(quote, to: recipientIDs, note: note) else { return false }
        let attempt = ShareAttempt()
        let sending = startSending(outgoing, attempt: attempt)
        guard await sending.value != nil else { return false }
        toasts.show(outgoing.message) { [weak self] in
            await self?.unsend(sending, outgoing: outgoing, attempt: attempt)
        }
        Haptics.success()
        return true
    }

    // MARK: Inbox

    /// Marks every unseen share as seen (opening Friends or the inbox). Optimistic; failures are logged.
    func markInboxSeen() async {
        await markSeen(unseenShares)
    }

    /// Marks specific shares as seen.
    func markSeen(_ shares: [SharedQuote]) async {
        let ids = Set(shares.filter { !$0.isSeen }.map(\.id))
        guard !ids.isEmpty else { return }
        let generation = self.generation
        let now = Date.now
        for index in inbox.indices where ids.contains(inbox[index].id) {
            inbox[index].seenAt = now
        }
        beginWrite()
        defer { endWrite() }
        do {
            try await backend.social.markSeen(Array(ids))
            guard self.generation == generation else { return }
            library?.writeCache()
        } catch {
            Logger.social.error("Marking shares seen failed: \(String(describing: QuotedError(error)), privacy: .public)")
        }
    }

    /// Deletes shares from your inbox (swipe to delete). They disappear at once; on failure they come
    /// back with a toast. Returns whether the server deleted them.
    @discardableResult
    func deleteShares(_ ids: [UUID]) async -> Bool {
        let targets = Set(ids)
        guard !targets.isEmpty else { return true }
        let generation = self.generation
        let removed = inbox.filter { targets.contains($0.id) }
        inbox.removeAll { targets.contains($0.id) }
        library?.writeCache()
        beginWrite()
        let assertion = BackgroundTaskAssertion("Delete shared quotes")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            try await backend.social.deleteShares(ids: ids)
            return true
        } catch {
            guard self.generation == generation else { return false }
            let present = Set(inbox.map(\.id))
            inbox = Self.newestFirst(inbox + removed.filter { !present.contains($0.id) })
            library?.writeCache()
            refreshAfterWrites = true
            toasts.show(error: error, failure: "Couldn\u{2019}t delete")
            return false
        }
    }

    /// Records locally that a share was saved (called by `LibraryStore.saveShared`).
    func markSavedLocally(_ shareID: UUID) {
        guard let index = inbox.firstIndex(where: { $0.id == shareID }) else { return }
        let now = Date.now
        if inbox[index].savedAt == nil { inbox[index].savedAt = now }
        if inbox[index].seenAt == nil { inbox[index].seenAt = now }
    }

    /// `LibraryStore.saveShared` stamps the share's `saved_at` on the server: count it as a write so
    /// a refresh that overlaps it does not flip the share back to unsaved.
    func noteWriteStarted() {
        beginWrite()
    }

    /// The end of a write announced with `noteWriteStarted()`.
    func noteWriteEnded() {
        endWrite()
    }

    /// Shows the cached inbox before the first refresh (called by `LibraryStore.prepare`).
    func restoreCachedInbox(_ shares: [SharedQuote]) {
        guard !hasLoaded else { return }
        inbox = shares
    }

    // MARK: Reset

    /// Forgets everything (sign-out). Results of requests still in flight are dropped.
    func reset() {
        friends = []
        incomingRequests = []
        outgoingRequests = []
        inbox = []
        blockedProfiles = []
        hasLoaded = false
        isRefreshing = false
        lastError = nil
        lastRefreshed = nil
        refreshAfterWrites = false
        refreshTask = nil
        refreshSerial += 1
        generation += 1
        retryShareIDs = [:]
    }

    /// Seeds state for SwiftUI previews.
    func seedPreview(friendships: [Friendship], inbox: [SharedQuote], me: UUID) {
        apply(friendships, me: me)
        self.inbox = inbox
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
            async let shares = backend.social.inbox()
            let (rows, received) = try await (friendships, shares)
            // The user may have signed out (or switched) while the request was in flight.
            guard backend.auth.currentUserID == me, self.generation == generation else { return .skipped }
            guard writes.isQuiet(since: token) else {
                Logger.social.debug("Dropped a social refresh that overlapped a write")
                refreshAfterWrites = true
                refreshIfWritesSettled()
                return .superseded
            }
            apply(rows, me: me)
            inbox = received
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

    // MARK: Private: sharing

    /// A validated send.
    private struct OutgoingShare: Sendable {
        let quote: Quote
        let recipients: [UUID]
        let note: String?
        /// "Sent to Maya".
        let message: String
        /// The new shares' IDs by recipient, chosen before the insert.
        let shareIDs: [UUID: UUID]
        let key: ShareKey
    }

    /// One send's identity for ``retryShareIDs``.
    private struct ShareKey: Hashable, Sendable {
        let quoteID: UUID
        let recipients: Set<UUID>
        let note: String?
    }

    /// Validates recipients and the note, toasting the problem and returning nil when invalid.
    private func prepareShare(_ quote: Quote, to recipientIDs: [UUID], note: String?) -> OutgoingShare? {
        let recipients = recipientIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !recipients.isEmpty else {
            toasts.show("Choose at least one friend.", style: .error)
            return nil
        }
        let cleanNote: String?
        do {
            cleanNote = try QuoteDraft.validatedNote(note ?? "")
        } catch {
            toasts.show(error.errorDescription ?? "The note is too long.", style: .error)
            return nil
        }
        let names = recipients.map { id in
            friends.first { $0.profile.id == id }.map { Self.firstName($0.profile.displayName) } ?? "a friend"
        }
        let key = ShareKey(quoteID: quote.id, recipients: Set(recipients), note: cleanNote)
        let shareIDs = retryShareIDs[key] ?? Dictionary(uniqueKeysWithValues: recipients.map { ($0, UUID()) })
        return OutgoingShare(
            quote: quote, recipients: recipients, note: cleanNote, message: Self.sentMessage(names),
            shareIDs: shareIDs, key: key
        )
    }

    /// Starts the insert now, under background time. The task returns the sent share IDs, or nil after
    /// showing "Couldn't send. …" (unless the user already tapped Undo).
    private func startSending(_ outgoing: OutgoingShare, attempt: ShareAttempt) -> Task<[UUID]?, Never> {
        let assertion = BackgroundTaskAssertion("Send quote")
        let backend = self.backend
        return Task { () -> [UUID]? in
            defer { assertion.end() }
            do {
                let sent = try await backend.social.share(
                    outgoing.quote, to: outgoing.recipients, note: outgoing.note, ids: outgoing.shareIDs
                )
                self.retryShareIDs[outgoing.key] = nil
                return sent.map(\.id)
            } catch {
                Logger.social.error("Share failed: \(String(describing: QuotedError(error)), privacy: .public)")
                // The insert may have landed with its answer lost: Send again reuses these IDs.
                self.retryShareIDs[outgoing.key] = outgoing.shareIDs
                if !attempt.isUndone {
                    self.toasts.show(error: error, failure: "Couldn\u{2019}t send")
                }
                return nil
            }
        }
    }

    /// Undo for a send: waits for the insert, then deletes the shares it created. When the insert's
    /// answer was lost, the shares may still exist; their IDs were chosen up front, so those go.
    private func unsend(_ sending: Task<[UUID]?, Never>, outgoing: OutgoingShare, attempt: ShareAttempt) async {
        attempt.isUndone = true
        let generation = self.generation
        let assertion = BackgroundTaskAssertion("Undo send")
        defer { assertion.end() }
        let ids = await sending.value ?? Array(outgoing.shareIDs.values)
        guard !ids.isEmpty, self.generation == generation else { return }
        retryShareIDs[outgoing.key] = nil
        do {
            try await backend.social.deleteShares(ids: ids)
        } catch {
            guard self.generation == generation else { return }
            toasts.show(error: error, failure: "Couldn\u{2019}t undo")
        }
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

    private static func newestFirst(_ shares: [SharedQuote]) -> [SharedQuote] {
        shares.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
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
}

/// Whether the user tapped Undo on a send, so a failed insert needs no "Couldn't send" toast.
@MainActor
private final class ShareAttempt {
    var isUndone = false
}
