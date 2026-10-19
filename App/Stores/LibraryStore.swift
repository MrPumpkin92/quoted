import Foundation
import Observation
import OSLog
import QuotedCore
import QuotedKit

/// The signed-in user's quotes, the reminder subset and the offline cache.
///
/// Reads are synchronous properties. Mutations are `async`, update the UI first (optimistic), roll
/// back what they changed with an error toast on failure, write the App Group cache and replan
/// reminders. They never throw; the return value says whether it worked (for example, to keep the
/// Add sheet open). Every server write runs under a `BackgroundTaskAssertion`, so leaving the app right
/// after an action does not cut the request off.
///
/// Refreshes are single-flight, and a refresh that overlapped a write is dropped (its rows may predate
/// the write) and repeated once the writes settle, so a slow fetch never undoes a create, delete or
/// reminder change. A failed write also resyncs once the writes settle.
/// Inject with `@Environment(LibraryStore.self)`.
@Observable
@MainActor
final class LibraryStore {
    // MARK: State

    /// Every quote, newest first. A deleted quote is gone at once (its Undo restores it).
    private(set) var quotes: [Quote] = []
    /// True once the cache or the server has answered for this user (gates "empty" states).
    private(set) var hasLoaded = false
    /// True while a refresh is running.
    private(set) var isRefreshing = false
    /// The last refresh error, cleared by the next successful refresh.
    private(set) var lastError: QuotedError?
    /// When the server last answered.
    private(set) var lastRefreshed: Date?

    // MARK: Dependencies

    @ObservationIgnored weak var social: SocialStore?
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let appGroup: AppGroupStore?
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let reminders: ReminderStore
    @ObservationIgnored private var userID: UUID?
    /// Server writes in flight, so a refresh knows whether its rows can replace local state.
    @ObservationIgnored private var writes = WriteTracker()
    /// Set when a refresh was dropped or a write failed: refresh again once no write is running.
    @ObservationIgnored private var refreshAfterWrites = false
    @ObservationIgnored private var refreshTask: Task<RefreshOutcome, Never>?
    @ObservationIgnored private var refreshSerial = 0
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    @ObservationIgnored private var rotationWrite: Task<Bool, Never>?
    @ObservationIgnored private var rotationSerial = 0
    /// Deletes whose Undo was tapped (a failed delete then needs no error toast).
    @ObservationIgnored private var undoneDeletes: Set<UUID> = []
    /// `saveShared` calls in flight by share ID, so a double tap saves once.
    @ObservationIgnored private var sharesBeingSaved: [UUID: Task<Quote?, Never>] = [:]

    init(backend: Backend, appGroup: AppGroupStore?, toasts: ToastCenter, reminders: ReminderStore) {
        self.backend = backend
        self.appGroup = appGroup
        self.toasts = toasts
        self.reminders = reminders
    }

    // MARK: Reads

    /// The quotes in reminders, in reminder order (`rotationPosition`).
    var reminderQuotes: [Quote] {
        let order = RotationState.orderedQuoteIDs(in: quotes)
        let byID = Dictionary(quotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// Library quotes that are not in reminders, newest first (the reminder picker).
    var quotesNotInReminders: [Quote] { quotes.filter { !$0.isInRotation } }

    /// Whether the library has no quotes (after loading).
    var isEmpty: Bool { quotes.isEmpty }

    /// The quote with `id`, if it is in the library.
    func quote(id: UUID) -> Quote? { quotes.first { $0.id == id } }

    /// Whether a starter quote is already in the library (same body and author).
    func contains(starter: StarterQuote) -> Bool {
        quotes.contains { $0.body == starter.body && $0.author == starter.author }
    }

    /// The quote's index in the reminder order, or nil when it is not in reminders. Capture it before
    /// removing a quote, for `restoreReminder(id:position:)`.
    func reminderPosition(of id: UUID) -> Int? {
        reminderQuotes.firstIndex { $0.id == id }
    }

    // MARK: Loading

    /// Shows this user's cached library at once (no network). Called by `SessionStore` on sign-in
    /// and launch; follow with `refresh()`.
    func prepare(for userID: UUID) {
        if self.userID != userID {
            reset()
            self.userID = userID
        }
        guard !hasLoaded, let cache = appGroup?.readLibraryCache(for: userID) else { return }
        quotes = Self.sorted(cache.quotes)
        social?.restoreCachedInbox(cache.shared)
        hasLoaded = true
        Logger.library.debug("Restored \(cache.quotes.count, privacy: .public) cached quotes")
    }

    /// Shows the cache for `userID`, then refreshes from the server.
    func load(userID: UUID) async {
        prepare(for: userID)
        reminders.replan()
        await refresh()
    }

    /// Fetches the library from the server and replaces the local copy. Calls made while a refresh
    /// runs join it. If a write overlapped the fetch, the result is dropped and a new refresh runs
    /// once the writes settle. Failures set `lastError`; with `userInitiated` (pull to refresh) they
    /// also toast. Returns whether the server answered.
    @discardableResult
    func refresh(userInitiated: Bool = false) async -> Bool {
        let outcome = await sharedRefresh()
        if userInitiated, case .failed(let error) = outcome {
            toasts.show(error: error)
        }
        return outcome.serverAnswered
    }

    /// Refreshes only if the last refresh is older than `maxAge` seconds (foreground, tab appear).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastRefreshed, Date.now.timeIntervalSince(lastRefreshed) < maxAge { return }
        await refresh()
    }

    // MARK: Create, edit, delete

    /// Saves a new quote. With `includeInReminders` it joins the end of the reminders. Waits for the
    /// server (the Add sheet shows progress); on failure shows a toast and returns nil, so the sheet
    /// stays open.
    @discardableResult
    func create(draft: QuoteDraft, includeInReminders: Bool, origin: QuoteOrigin = .manual) async -> Quote? {
        let owner = userID
        let position = includeInReminders ? nextReminderPosition : nil
        beginWrite()
        let assertion = BackgroundTaskAssertion("Save quote")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            let quote = try await backend.quotes.create(draft, origin: origin, rotationPosition: position)
            guard userID == owner else { return nil }
            upsertLocal(quote)
            writeCache()
            if quote.isInRotation { reminders.replan() }
            Haptics.success()
            return quote
        } catch {
            guard userID == owner else { return nil }
            // The insert may have reached the server even though the answer was lost.
            refreshAfterWrites = true
            toasts.show(error: error)
            return nil
        }
    }

    /// Saves edits to body, format, author and source (reminder membership is separate). Optimistic;
    /// on failure the old text comes back (unless a later edit replaced it) and a toast shows.
    @discardableResult
    func update(_ quote: Quote) async -> Bool {
        guard let old = self.quote(id: quote.id) else { return false }
        let owner = userID
        var edited = quote
        edited.rotationPosition = old.rotationPosition
        upsertLocal(edited)
        beginWrite()
        let assertion = BackgroundTaskAssertion("Save quote")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            let saved = try await backend.quotes.update(edited)
            guard userID == owner else { return false }
            // Keep a later edit, and the local reminder position (a reminder write may be queued).
            if let current = self.quote(id: saved.id), Self.hasSameContent(current, edited) {
                var merged = saved
                merged.rotationPosition = current.rotationPosition
                upsertLocal(merged)
            }
            writeCache()
            if self.quote(id: saved.id)?.isInRotation == true { reminders.replan() }
            return true
        } catch {
            guard userID == owner else { return false }
            if let current = self.quote(id: edited.id), Self.hasSameContent(current, edited) {
                var reverted = old
                reverted.rotationPosition = current.rotationPosition
                upsertLocal(reverted)
            }
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Deletes a quote and shows "Quote deleted · Undo". The quote disappears and the server delete
    /// starts at once; Undo puts the same quote back (same ID, content and reminder position) with
    /// `QuotesRepository.restore`. A failed delete puts the quote back and toasts.
    func delete(_ quote: Quote) {
        guard let removed = self.quote(id: quote.id) else { return }
        let owner = userID
        let reminderOrder = reminderQuotes.map(\.id)
        quotes.removeAll { $0.id == removed.id }
        if removed.isInRotation { reminders.replan() }
        writeCache()
        Haptics.warning()
        undoneDeletes.remove(removed.id)

        beginWrite()
        let assertion = BackgroundTaskAssertion("Delete quote")
        let commit = Task { () -> Bool in
            defer {
                assertion.end()
                self.endWrite()
            }
            do {
                try await self.backend.quotes.delete(id: removed.id)
                return true
            } catch {
                guard self.userID == owner else { return false }
                if self.quote(id: removed.id) == nil {
                    self.upsertLocal(removed)
                    self.writeCache()
                    if removed.isInRotation { self.reminders.replan() }
                }
                self.refreshAfterWrites = true
                if self.undoneDeletes.remove(removed.id) == nil {
                    self.toasts.show(error: error, failure: "Couldn\u{2019}t delete")
                }
                return false
            }
        }
        toasts.show("Quote deleted") { [weak self] in
            await self?.undoDelete(removed, reminderOrder: reminderOrder, owner: owner, after: commit)
        }
    }

    // MARK: Reminders

    /// Adds a quote to the end of the reminders, or removes it.
    @discardableResult
    func setInReminders(_ quote: Quote, _ included: Bool) async -> Bool {
        if included {
            return await addToReminders([quote.id])
        } else {
            return await removeFromReminders([quote.id])
        }
    }

    /// Adds quotes to the end of the reminders, in the given order. Quotes already in are skipped.
    @discardableResult
    func addToReminders(_ ids: [UUID]) async -> Bool {
        let current = reminderQuotes.map(\.id)
        let known = Set(quotes.map(\.id))
        let added = ids.filter { known.contains($0) && !current.contains($0) }
        guard !added.isEmpty else { return true }
        return await writeRotation(ordered: current + added, removing: [])
    }

    /// Takes quotes out of the reminders (they stay in the library). For Undo, capture
    /// `reminderPosition(of:)` first and call `restoreReminder(id:position:)`.
    @discardableResult
    func removeFromReminders(_ ids: [UUID]) async -> Bool {
        let removing = Set(ids)
        let current = reminderQuotes.map(\.id)
        guard current.contains(where: removing.contains) else { return true }
        return await writeRotation(ordered: current.filter { !removing.contains($0) }, removing: Array(removing))
    }

    /// Undo for "Removed from reminders": puts the quote back at `position` (its index in the
    /// reminder order before it was removed, from `reminderPosition(of:)`), clamped to the current
    /// list. A quote already in reminders moves there.
    @discardableResult
    func restoreReminder(id: UUID, position: Int) async -> Bool {
        guard quote(id: id) != nil else { return false }
        let current = reminderQuotes.map(\.id)
        var ordered = current.filter { $0 != id }
        ordered.insert(id, at: min(max(0, position), ordered.count))
        guard ordered != current else { return true }
        return await writeRotation(ordered: ordered, removing: [])
    }

    /// Sets the reminder order. `ids` should hold every reminder quote; missing ones keep their
    /// relative order after the given ones.
    @discardableResult
    func reorderReminders(_ ids: [UUID]) async -> Bool {
        let current = reminderQuotes.map(\.id)
        let given = ids.filter(current.contains)
        let ordered = given + current.filter { !given.contains($0) }
        guard ordered != current else { return true }
        return await writeRotation(ordered: ordered, removing: [])
    }

    /// `List.onMove` for the Reminders list.
    func moveReminders(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = reminderQuotes.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        Task { await reorderReminders(ids) }
    }

    // MARK: Starter pack and shares

    /// Copies starter quotes into the library and the end of the reminders. Waits for the server;
    /// on failure shows a toast and returns false.
    @discardableResult
    func importStarter(_ starters: [StarterQuote]) async -> Bool {
        guard !starters.isEmpty else { return true }
        let owner = userID
        beginWrite()
        let assertion = BackgroundTaskAssertion("Add starter quotes")
        defer {
            assertion.end()
            endWrite()
        }
        do {
            let inserted = try await backend.quotes.importStarter(starters, addToRotation: true)
            guard userID == owner else { return false }
            for quote in inserted { upsertLocal(quote) }
            hasLoaded = true
            writeCache()
            reminders.replan()
            Haptics.success()
            return true
        } catch {
            guard userID == owner else { return false }
            refreshAfterWrites = true
            toasts.show(error: error)
            return false
        }
    }

    /// Saves a quote a friend shared into the library (optionally into reminders) and marks the
    /// share saved. Shows "Saved to your library". Returns the quote, or nil on failure.
    ///
    /// Never creates a duplicate: when the library already holds the same text and author, that quote
    /// is returned (added to reminders if asked) with "Already in your library" and the share is
    /// marked saved on the server (`SocialRepository.markSaved`); a second call while a save is
    /// running waits for it instead of inserting again.
    @discardableResult
    func saveShared(_ share: SharedQuote, addToReminders: Bool) async -> Quote? {
        if let running = sharesBeingSaved[share.id] {
            return await running.value
        }
        if let existing = existingCopy(of: share) {
            social?.markSavedLocally(share.id)
            writeCache()
            if !share.isSaved { stampSaved(share.id) }
            if addToReminders, !existing.isInRotation {
                await self.addToReminders([existing.id])
            }
            toasts.show("Already in your library")
            return quote(id: existing.id) ?? existing
        }
        let task = Task { await self.insertShared(share, addToReminders: addToReminders) }
        sharesBeingSaved[share.id] = task
        let saved = await task.value
        sharesBeingSaved[share.id] = nil
        return saved
    }

    // MARK: Cache

    /// Writes the library and the shared inbox to the App Group cache, off the main thread, in order.
    func writeCache() {
        guard let appGroup, let userID, hasLoaded else { return }
        let cache = LibraryCache(userID: userID, quotes: quotes, shared: social?.inbox ?? [])
        let previous = cacheWrite
        cacheWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try appGroup.writeLibraryCache(cache)
            } catch {
                Logger.library.error("Writing the library cache failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits until every queued cache write has landed. `SessionStore` calls it after `reset()` and
    /// before wiping the App Group, so a late write cannot put a signed-out user's library back.
    func waitForCacheWrites() async {
        await cacheWrite?.value
    }

    // MARK: Reset

    /// Forgets everything (sign-out). Does not touch the server or the App Group. Writes still in
    /// flight for the previous user finish, but their results are dropped. After a reset no new cache
    /// write is queued until the next `prepare(for:)`.
    func reset() {
        quotes = []
        hasLoaded = false
        isRefreshing = false
        lastError = nil
        lastRefreshed = nil
        userID = nil
        refreshAfterWrites = false
        refreshTask = nil
        refreshSerial += 1
        undoneDeletes = []
        sharesBeingSaved = [:]
    }

    /// Seeds quotes for SwiftUI previews.
    func seedPreview(quotes: [Quote]) {
        self.quotes = Self.sorted(quotes)
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
            // Runs on the main actor right after the fetch, before any caller resumes, so a refresh
            // requested from here on starts a new fetch.
            if self.refreshSerial == serial { self.refreshTask = nil }
            return outcome
        }
        refreshTask = task
        return await task.value
    }

    private func performRefresh() async -> RefreshOutcome {
        guard let requestedFor = backend.auth.currentUserID, userID == nil || userID == requestedFor else { return .skipped }
        let token = writes.token
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await backend.quotes.fetchMine()
            // The user may have signed out (or switched) while the request was in flight.
            guard backend.auth.currentUserID == requestedFor, userID == nil || userID == requestedFor else { return .skipped }
            guard writes.isQuiet(since: token) else {
                Logger.library.debug("Dropped a library refresh that overlapped a write")
                refreshAfterWrites = true
                refreshIfWritesSettled()
                return .superseded
            }
            quotes = Self.sorted(fetched)
            hasLoaded = true
            lastError = nil
            lastRefreshed = .now
            writeCache()
            reminders.replan()
            return .applied
        } catch is CancellationError {
            return .skipped
        } catch {
            guard userID == nil || userID == requestedFor else { return .skipped }
            let mapped = QuotedError(error)
            lastError = mapped
            Logger.library.error("Library refresh failed: \(String(describing: mapped), privacy: .public)")
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

    /// Starts the resync a dropped refresh or a failed write asked for, once no write is running.
    private func refreshIfWritesSettled() {
        guard refreshAfterWrites, writes.isIdle, userID != nil else { return }
        refreshAfterWrites = false
        Task { await self.refresh() }
    }

    // MARK: Private: writes

    private var nextReminderPosition: Int {
        (quotes.compactMap(\.rotationPosition).max() ?? -1) + 1
    }

    /// Inserts or replaces a quote, keeping newest-first order.
    private func upsertLocal(_ quote: Quote) {
        if let index = quotes.firstIndex(where: { $0.id == quote.id }) {
            let moved = quotes[index].createdAt != quote.createdAt
            quotes[index] = quote
            if moved { quotes = Self.sorted(quotes) }
        } else {
            quotes.append(quote)
            quotes = Self.sorted(quotes)
        }
    }

    /// Undo for `delete`: shows the quote again at once, waits for the delete to settle, then puts the
    /// server copy back with `restore` and, if the reminders changed meanwhile, returns it to its old
    /// place among its neighbours.
    private func undoDelete(_ quote: Quote, reminderOrder: [UUID], owner: UUID?, after commit: Task<Bool, Never>) async {
        guard userID == owner else { return }
        undoneDeletes.insert(quote.id)
        if self.quote(id: quote.id) == nil {
            upsertLocal(quote)
            writeCache()
            if quote.isInRotation { reminders.replan() }
        }
        beginWrite()
        let assertion = BackgroundTaskAssertion("Restore quote")
        defer {
            assertion.end()
            endWrite()
        }
        let deleted = await commit.value
        undoneDeletes.remove(quote.id)
        // A failed delete already left the quote in place.
        guard deleted, userID == owner else { return }
        do {
            let restored = try await backend.quotes.restore(quote)
            guard userID == owner else { return }
            upsertLocal(restored)
            writeCache()
            reminders.replan()
            if restored.isInRotation {
                let current = reminderQuotes.map(\.id)
                let ordered = Self.order(inserting: restored.id, into: current, following: reminderOrder)
                if ordered != current {
                    await writeRotation(ordered: ordered, removing: [])
                }
            }
        } catch {
            guard userID == owner else { return }
            quotes.removeAll { $0.id == quote.id }
            writeCache()
            if quote.isInRotation { reminders.replan() }
            refreshAfterWrites = true
            toasts.show(error: error, failure: "Couldn\u{2019}t undo")
        }
    }

    /// The library copy of a share, if the library already holds the same text and author.
    private func existingCopy(of share: SharedQuote) -> Quote? {
        guard let content = try? QuoteDraft(shared: share).validated() else { return nil }
        return quotes.first { quote in
            quote.body == content.body && Self.cleaned(quote.author) == content.author
        }
    }

    /// Stamps `saved_at` on the server for a share whose quote the library already holds (no copy is
    /// made). Counted as a social write, so an overlapping refresh can't flip it back to "Save".
    /// Best effort: on failure the share shows "Saved" here until the next refresh.
    private func stampSaved(_ shareID: UUID) {
        let social = self.social
        social?.noteWriteStarted()
        let assertion = BackgroundTaskAssertion("Mark shared quote saved")
        let backend = self.backend
        Task {
            defer {
                assertion.end()
                social?.noteWriteEnded()
            }
            do {
                try await backend.social.markSaved([shareID])
            } catch {
                Logger.library.error("Marking a share saved failed: \(String(describing: QuotedError(error)), privacy: .public)")
            }
        }
    }

    private func insertShared(_ share: SharedQuote, addToReminders: Bool) async -> Quote? {
        let owner = userID
        beginWrite()
        social?.noteWriteStarted()
        let assertion = BackgroundTaskAssertion("Save shared quote")
        defer {
            assertion.end()
            social?.noteWriteEnded()
            endWrite()
        }
        do {
            let quote = try await backend.quotes.saveShared(share, addToRotation: addToReminders)
            guard userID == owner else { return nil }
            upsertLocal(quote)
            social?.markSavedLocally(share.id)
            writeCache()
            if quote.isInRotation { reminders.replan() }
            Haptics.success()
            toasts.show("Saved to your library", style: .success)
            return quote
        } catch {
            guard userID == owner else { return nil }
            refreshAfterWrites = true
            toasts.show(error: error)
            return nil
        }
    }

    /// Writes the reminder order: `ordered` gets positions 0..., `removing` leaves. The change shows
    /// at once; the server writes run one at a time.
    ///
    /// Each queued write sends the reminder order as it is when its turn comes, which already holds
    /// this change and any later ones, minus earlier writes that failed. On failure it rolls back only
    /// the positions it set that nothing has changed since, toasts, and resyncs once the writes settle.
    @discardableResult
    private func writeRotation(ordered: [UUID], removing: [UUID]) async -> Bool {
        let owner = userID
        let affected = Set(ordered).union(removing)
        let before = positions(of: affected)
        applyPositions(ordered: ordered, removing: removing)
        let applied = positions(of: affected)
        reminders.replan()

        beginWrite()
        rotationSerial += 1
        let serial = rotationSerial
        let previous = rotationWrite
        let removingIDs = Set(removing)
        let task = Task { () -> Bool in
            _ = await previous?.value
            let assertion = BackgroundTaskAssertion("Save reminders")
            defer {
                assertion.end()
                self.endWrite()
            }
            guard self.userID == owner else { return false }
            let order = self.reminderQuotes
            let leaving = self.quotes.filter { removingIDs.contains($0.id) && !$0.isInRotation }
            do {
                let updated = try await self.backend.quotes.setRotation(ordered: order, removing: leaving)
                guard self.userID == owner else { return false }
                // A later queued write applies its own result; taking this one would flicker.
                if self.rotationSerial == serial {
                    self.mergePositions(from: updated)
                }
                self.writeCache()
                self.reminders.replan()
                return true
            } catch {
                guard self.userID == owner else { return false }
                for (id, position) in applied where self.quote(id: id).map({ $0.rotationPosition == position }) == true {
                    self.setPosition(before[id] ?? nil, for: id)
                }
                self.reminders.replan()
                self.refreshAfterWrites = true
                self.toasts.show(error: error)
                return false
            }
        }
        rotationWrite = task
        return await task.value
    }

    private func positions(of ids: Set<UUID>) -> [UUID: Int?] {
        var result: [UUID: Int?] = [:]
        for quote in quotes where ids.contains(quote.id) {
            result[quote.id] = .some(quote.rotationPosition)
        }
        return result
    }

    private func setPosition(_ position: Int?, for id: UUID) {
        guard let index = quotes.firstIndex(where: { $0.id == id }) else { return }
        quotes[index].rotationPosition = position
    }

    /// Takes the server's reminder positions (and `updatedAt`) for the returned quotes; content stays
    /// local, so an edit saved meanwhile is kept.
    private func mergePositions(from updated: [Quote]) {
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in quotes.indices {
            guard let server = byID[quotes[index].id] else { continue }
            quotes[index].rotationPosition = server.rotationPosition
            quotes[index].updatedAt = max(quotes[index].updatedAt, server.updatedAt)
        }
    }

    private func applyPositions(ordered: [UUID], removing: [UUID]) {
        let positions = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = Set(removing).subtracting(ordered)
        for index in quotes.indices {
            let id = quotes[index].id
            if let position = positions[id] {
                quotes[index].rotationPosition = position
            } else if removed.contains(id) {
                quotes[index].rotationPosition = nil
            }
        }
    }

    // MARK: Helpers

    /// `current` without `id`, with `id` inserted right after the nearest quote that preceded it in
    /// `previous` and is still in `current` (first when none is).
    static func order(inserting id: UUID, into current: [UUID], following previous: [UUID]) -> [UUID] {
        var result = current.filter { $0 != id }
        guard let oldIndex = previous.firstIndex(of: id) else { return result + [id] }
        let present = Set(result)
        if let predecessor = previous[..<oldIndex].last(where: present.contains),
           let index = result.firstIndex(of: predecessor) {
            result.insert(id, at: index + 1)
        } else {
            result.insert(id, at: 0)
        }
        return result
    }

    private static func hasSameContent(_ lhs: Quote, _ rhs: Quote) -> Bool {
        lhs.body == rhs.body && lhs.format == rhs.format && lhs.author == rhs.author && lhs.source == rhs.source
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func sorted(_ quotes: [Quote]) -> [Quote] {
        quotes.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
