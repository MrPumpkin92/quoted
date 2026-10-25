import Foundation
import QuotedCore
import Supabase

/// Profiles, friends, blocks, shares and reports.
public struct SocialRepository: Sendable {
    let client: SupabaseClient

    // MARK: Profiles

    /// The signed-in user's profile, or nil before a username is chosen.
    public func myProfile() async throws -> Profile? {
        let me = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .select(Columns.profile)
                .eq("id", value: me)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// Creates the signed-in user's profile. Throws ``QuotedError/usernameTaken`` when the username is
    /// in use, and ``QuotedError/validation(_:)`` for an invalid username or name.
    public func createProfile(username: String, displayName: String? = nil) async throws -> Profile {
        let me = try client.requireUserID()
        let insert = ProfileInsert(
            id: me,
            username: try Self.validUsername(username),
            displayName: try Self.validDisplayName(displayName)
        )
        return try await mappingErrors(postgrest: Self.profileError) {
            do {
                return try await client.from(Table.profiles)
                    .insert(insert, returning: .representation)
                    .select(Columns.profile)
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError
                where error.code == "23505" && (error.constraintName == "profiles_pkey" || error.mentions("profiles_pkey")) {
                // You already have a profile: most likely an earlier Continue whose answer was lost.
                // That profile is the result, so onboarding goes on instead of sticking here.
                guard let existing = try await myProfile() else { throw error }
                return existing
            }
        }
    }

    /// Shows or hides your favorites from your friends. Off by default.
    public func setShowsFavorites(_ shows: Bool) async throws -> Profile {
        let me = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .update(ShowsFavoritesUpdate(showsFavorites: shows), returning: .representation)
                .eq("id", value: me)
                .select(Columns.profile)
                .single()
                .execute()
                .value
        }
    }

    /// A linked person's profile as it is now (a friend's name and whether they show favorites), or
    /// nil when you can no longer see it (unfriended and unlinked, or blocked).
    public func profile(id: UUID) async throws -> Profile? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .select(Columns.profile)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// A friend's favorite quotes, newest first (at most 100). Empty unless you are accepted friends,
    /// neither has blocked the other, and they show favorites.
    public func favorites(of userID: UUID) async throws -> [FriendFavorite] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.rpc(RPC.friendFavorites, params: FriendFavoritesParam(user: userID))
                .execute()
                .value
        }
    }

    /// Changes the signed-in user's display name. Nil or blank clears it (the username is shown).
    public func updateDisplayName(_ displayName: String?) async throws -> Profile {
        let me = try client.requireUserID()
        let update = DisplayNameUpdate(displayName: try Self.validDisplayName(displayName))
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .update(update, returning: .representation)
                .eq("id", value: me)
                .select(Columns.profile)
                .single()
                .execute()
                .value
        }
    }

    /// Whether nobody has `username` yet (reserved names count as taken). Throws
    /// ``QuotedError/validation(_:)`` if it is not a valid username.
    ///
    /// Asks `public.is_username_available`: profiles are readable only between people connected by
    /// a friendship, share or block, so a plain select could not see a stranger's username.
    public func isUsernameAvailable(_ username: String) async throws -> Bool {
        _ = try client.requireUserID()
        let name = try Self.validUsername(username)
        return try await mappingErrors {
            try await client.rpc(RPC.isUsernameAvailable, params: UsernameParam(username: name))
                .execute()
                .value
        }
    }

    /// The profile with exactly this username (after normalizing "@Name" to "name"), or nil. Nil
    /// too for your own username and for anyone you have blocked or who has blocked you
    /// (`public.find_profile`), so a block can't be detected from a lookup.
    public func findProfile(username: String) async throws -> Profile? {
        try await findProfile(username: username, retrying: true)
    }

    /// `retrying: false` skips the SDK's retries, for a lookup that runs before a write.
    func findProfile(username: String, retrying: Bool) async throws -> Profile? {
        _ = try client.requireUserID()
        guard let name = try? Username.validate(username) else { return nil }
        return try await mappingErrors {
            let rows: [Profile] = try await client.rpc(RPC.findProfile, params: UsernameParam(username: name))
                .select(Columns.foundProfile)
                .retry(enabled: retrying)
                .execute()
                .value
            return rows.first
        }
    }

    /// Records that this account is in use (`public.touch_activity`, which the server throttles to
    /// one write per 12 hours). Anonymous accounts unused for a year are deleted, so the app calls
    /// this when it comes to the foreground and from background refresh. Never throws.
    public func touchActivity() async {
        guard client.signedInUserID != nil else { return }
        do {
            try await client.rpc(RPC.touchActivity).execute()
        } catch {
            // Best effort: the next foreground or background refresh tries again.
        }
    }

    // MARK: Friends

    /// Friendships and pending requests in both directions, newest first, with the other party's
    /// profile in `otherParty` (and `requester`/`addressee`). Read in pages (see ``Paging``).
    public func friendships() async throws -> [Friendship] {
        let me = try client.requireUserID()
        let rows: [Friendship] = try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.friendships)
                    .select(Columns.friendship, count: .exact)
                    .or("requester_id.eq.\(me.uuidString),addressee_id.eq.\(me.uuidString)")
                    // Only the statuses this build decodes: a status added later on the server
                    // must not break the whole Friends and inbox refresh on installed builds.
                    .in("status", values: FriendshipStatus.allCases.map(\.rawValue))
                    .order("created_at", ascending: false)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
        return rows.map { Self.decorate($0, me: me) }
    }

    /// Sends a friend request to the user with this exact username.
    ///
    /// Throws ``QuotedError/notFound`` when nobody has it, and ``QuotedError/validation(_:)`` for
    /// your own username, an existing friendship or request (either direction), or a block.
    @discardableResult
    public func sendFriendRequest(toUsername username: String) async throws -> Friendship {
        let me = try client.requireUserID()
        let name = try Self.validUsername(username)
        // No retries before the write: offline, fail at once instead of after seconds of backoff.
        guard let profile = try await findProfile(username: name, retrying: false) else {
            // The lookup never returns yourself; tell that case apart only when it comes back empty.
            if let mine = try? await myProfile(), mine.username == name {
                throw QuotedError.validation("That's your own username.")
            }
            throw QuotedError.notFound
        }
        guard profile.id != me else { throw QuotedError.validation("That's your own username.") }
        let row: Friendship = try await mappingErrors(postgrest: Self.friendRequestError) {
            try await client.from(Table.friendships)
                .insert(FriendRequestInsert(addresseeID: profile.id), returning: .representation)
                .select(Columns.friendship)
                .single()
                .execute()
                .value
        }
        var request = Self.decorate(row, me: me)
        // The insert's embed runs before the new friendship exists for the profiles policy, so the
        // addressee's profile comes back null; use the one the lookup just returned.
        if request.otherParty == nil {
            request.otherParty = profile
        }
        return request
    }

    /// Accepts an incoming request. Throws ``QuotedError/notFound`` if it is gone, was not sent to
    /// you, or is already accepted.
    @discardableResult
    public func accept(friendshipID: UUID) async throws -> Friendship {
        let me = try client.requireUserID()
        let row: Friendship = try await mappingErrors {
            try await client.from(Table.friendships)
                .update(FriendshipStatusUpdate(status: .accepted), returning: .representation)
                .eq("id", value: friendshipID)
                .eq("addressee_id", value: me)
                .eq("status", value: FriendshipStatus.pending.rawValue)
                .select(Columns.friendship)
                .single()
                .execute()
                .value
        }
        return Self.decorate(row, me: me)
    }

    /// Declines or cancels a request, or unfriends. Removing one that is already gone succeeds.
    public func remove(friendshipID: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.friendships)
                .delete(returning: .minimal)
                .eq("id", value: friendshipID)
                .execute()
        }
    }

    // MARK: Blocks

    /// Blocks a user. The server also removes the friendship (or request) and every share between
    /// you. Blocking someone already blocked succeeds.
    public func block(userID: UUID) async throws {
        let me = try client.requireUserID()
        guard userID != me else { throw QuotedError.validation("You can't block yourself.") }
        try await mappingErrors(postgrest: Self.blockError) {
            do {
                try await client.from(Table.blocks)
                    .insert(BlockInsert(blockedID: userID), returning: .minimal)
                    .execute()
            } catch let error as PostgrestError where error.code == "23505" {
                // Already blocked.
            }
        }
    }

    /// Unblocks a user. Friendships and shares removed by the block do not come back.
    public func unblock(userID: UUID) async throws {
        let me = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.blocks)
                .delete(returning: .minimal)
                .eq("blocker_id", value: me)
                .eq("blocked_id", value: userID)
                .execute()
        }
    }

    /// IDs of the users you have blocked. Read in pages (see ``Paging``).
    public func blockedIDs() async throws -> Set<UUID> {
        let me = try client.requireUserID()
        let rows: [BlockedRow] = try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.blocks)
                    .select("blocked_id", count: .exact)
                    .eq("blocker_id", value: me)
                    .order("blocked_id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
        return Set(rows.map(\.blockedID))
    }

    /// Profiles of the users you have blocked, most recent first. Read in pages (see ``Paging``).
    public func blockedProfiles() async throws -> [Profile] {
        let me = try client.requireUserID()
        let rows: [BlockedRow] = try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.blocks)
                    .select(Columns.blockedProfile, count: .exact)
                    .eq("blocker_id", value: me)
                    .order("created_at", ascending: false)
                    .order("blocked_id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
        return rows.compactMap(\.blocked)
    }

    // MARK: Shares

    /// Sends a snapshot of `quote` (body, format, author, source) to each friend in `recipientIDs`,
    /// in one insert. Your own ID and duplicates are ignored. Returns the sent shares with the
    /// recipients' profiles.
    ///
    /// Throws ``QuotedError/validation(_:)`` when no recipient is left, the note is too long, or a
    /// recipient is not an accepted friend.
    ///
    /// `ids` maps recipients to the new shares' IDs (missing ones are generated). Pass the same map to
    /// retry a send whose answer was lost: the shares that reached the server are returned instead
    /// of sent twice, and ``deleteShares(ids:)`` can undo them even though the first answer never came.
    @discardableResult
    public func share(
        _ quote: Quote,
        to recipientIDs: [UUID],
        note: String? = nil,
        ids: [UUID: UUID] = [:]
    ) async throws -> [SharedQuote] {
        let me = try client.requireUserID()
        let recipients = Self.recipients(recipientIDs, excluding: me)
        guard !recipients.isEmpty else { throw QuotedError.validation("Choose at least one friend.") }
        let cleanNote = try Self.validNote(note)
        let content: QuoteDraft.Validated
        do {
            content = try QuoteDraft(quote: quote).validated()
        } catch {
            throw QuotedError.validation(error.errorDescription ?? "This quote can't be shared.")
        }
        let shareIDs = recipients.map { ids[$0] ?? UUID() }
        func rows(quoteID: UUID?) -> [ShareInsert] {
            zip(recipients, shareIDs).map { recipient, id in
                ShareInsert(
                    id: id, recipientID: recipient, quoteID: quoteID, body: content.body, format: content.format,
                    author: content.author, source: content.source, note: cleanNote
                )
            }
        }
        return try await mappingErrors(postgrest: Self.shareError) {
            do {
                return try await insertShares(rows(quoteID: quote.id), ids: shareIDs)
            } catch let error as PostgrestError
                where error.code == "42501" || (error.code == "23503" && error.mentions("shares_quote_id_fkey")) {
                // The policy also requires quote_id to be one of your quotes. If the original was
                // deleted elsewhere, send the snapshot without the link; a non-friend fails again.
                return try await insertShares(rows(quoteID: nil), ids: shareIDs)
            }
        }
    }

    /// Inserts shares with client-chosen `ids`. On a unique violation, an earlier attempt with the
    /// same IDs may have landed with its answer lost: if every one is a share you sent, they are the
    /// result; otherwise the error is thrown as it came.
    private func insertShares(_ rows: [ShareInsert], ids: [UUID]) async throws -> [SharedQuote] {
        do {
            return try await client.from(Table.shares)
                .insert(rows, returning: .representation)
                .select(Columns.sentShare)
                .execute()
                .value
        } catch let error as PostgrestError where error.code == "23505" {
            let me = try client.requireUserID()
            let existing: [SharedQuote] = try await client.from(Table.shares)
                .select(Columns.sentShare)
                .in("id", values: ids)
                .eq("sender_id", value: me)
                .execute()
                .value
            guard existing.count == Set(ids).count else { throw error }
            return existing
        }
    }

    /// Quotes shared with you, newest first, with the sender's profile. Read in pages (see ``Paging``).
    public func inbox() async throws -> [SharedQuote] {
        let me = try client.requireUserID()
        return try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.shares)
                    .select(Columns.inboxShare, count: .exact)
                    .eq("recipient_id", value: me)
                    .order("created_at", ascending: false)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
    }

    /// Quotes you shared, newest first, with the recipient's profile. Read in pages (see ``Paging``).
    public func sent() async throws -> [SharedQuote] {
        let me = try client.requireUserID()
        return try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.shares)
                    .select(Columns.sentShare, count: .exact)
                    .eq("sender_id", value: me)
                    .order("created_at", ascending: false)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
    }

    /// Deletes shares you sent or received (RLS lets either party delete). IDs that are gone, or not
    /// yours, are skipped, so a retry is harmless. Large lists go out in batches of
    /// ``deleteBatchSize`` IDs to keep the URL short; if one batch fails, the earlier ones stay
    /// deleted and the error is thrown.
    public func deleteShares(ids: [UUID]) async throws {
        _ = try client.requireUserID()
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        try await mappingErrors {
            for start in stride(from: 0, to: unique.count, by: Self.deleteBatchSize) {
                let batch = Array(unique[start..<min(start + Self.deleteBatchSize, unique.count)])
                try await client.from(Table.shares)
                    .delete(returning: .minimal)
                    .in("id", values: batch)
                    .execute()
            }
        }
    }

    /// IDs per `deleteShares` request: about 4 KB of `id=in.(…)`, well under URL limits (~8 KB).
    static let deleteBatchSize = 100

    /// Stamps `seen_at` on received shares that are not seen yet. The first time seen is kept. Large
    /// lists go out in batches of ``deleteBatchSize`` IDs, like ``deleteShares(ids:)``.
    public func markSeen(_ ids: [UUID]) async throws {
        let me = try client.requireUserID()
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        let seenAt = Date()
        try await mappingErrors {
            for start in stride(from: 0, to: ids.count, by: Self.deleteBatchSize) {
                let batch = Array(ids[start..<min(start + Self.deleteBatchSize, ids.count)])
                try await client.from(Table.shares)
                    .update(ShareSeenUpdate(seenAt: seenAt), returning: .minimal)
                    .in("id", values: batch)
                    .eq("recipient_id", value: me)
                    .is("seen_at", value: nil)
                    .execute()
            }
        }
    }

    /// Stamps `saved_at` on received shares that are not marked saved yet, without copying them (the
    /// library already holds the same quote). The server keeps the first time.
    public func markSaved(_ ids: [UUID]) async throws {
        let me = try client.requireUserID()
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        try await mappingErrors {
            try await client.from(Table.shares)
                .update(ShareSavedUpdate(savedAt: Date()), returning: .minimal)
                .in("id", values: ids)
                .eq("recipient_id", value: me)
                .is("saved_at", value: nil)
                .execute()
        }
    }

    // MARK: Reports

    /// Reports a share you received (App Store guideline 1.2). The report carries a copy of the
    /// share's body, author and source, which the server takes from the share itself and keeps after
    /// a block deletes the share. If the share is already gone, the sender is still reported with
    /// the content the app holds.
    public func report(share: SharedQuote, reason: ReportReason, details: String? = nil) async throws {
        let me = try client.requireUserID()
        guard share.recipientID == me, share.senderID != me else {
            throw QuotedError.validation("You can only report quotes shared with you.")
        }
        let cleanDetails = try Self.validDetails(details)
        let report = ReportInsert(share: share, reason: reason, details: cleanDetails)
        try await mappingErrors {
            do {
                try await insertReport(report)
            } catch let error as PostgrestError where ["42501", "23503"].contains(error.code) {
                // The share no longer exists (for example, after a block). Report the user, keeping
                // the snapshot.
                var fallback = report
                fallback.shareID = nil
                try await insertReport(fallback)
            }
        }
    }

    /// Reports a user without a specific share.
    public func report(userID: UUID, reason: ReportReason, details: String? = nil) async throws {
        let me = try client.requireUserID()
        guard userID != me else { throw QuotedError.validation("You can't report yourself.") }
        let cleanDetails = try Self.validDetails(details)
        try await mappingErrors {
            try await insertReport(ReportInsert(shareID: nil, reportedUserID: userID, reason: reason, details: cleanDetails))
        }
    }

    private func insertReport(_ report: ReportInsert) async throws {
        // Reporters can read their own reports, but nothing needs the row back.
        do {
            try await client.from(Table.reports)
                .insert(report, returning: .minimal)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // The same report (reporter, user, share) is already filed: a retry, or a second tap.
        }
    }

    // MARK: Helpers

    static func decorate(_ friendship: Friendship, me: UUID) -> Friendship {
        var copy = friendship
        copy.otherParty = friendship.otherParty(for: me)
        return copy
    }

    static func recipients(_ ids: [UUID], excluding me: UUID) -> [UUID] {
        var seen: Set<UUID> = [me]
        return ids.filter { seen.insert($0).inserted }
    }

    static func validUsername(_ username: String) throws(QuotedError) -> String {
        do {
            return try Username.validate(username)
        } catch {
            throw .validation(error.errorDescription ?? "Choose a different username.")
        }
    }

    static func validDisplayName(_ name: String?) throws(QuotedError) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try DisplayName.validate(name)
        } catch {
            throw .validation(error.errorDescription ?? "Choose a different name.")
        }
    }

    static func validNote(_ note: String?) throws(QuotedError) -> String? {
        guard let note else { return nil }
        do {
            return try QuoteDraft.validatedNote(note)
        } catch {
            throw .validation(error.errorDescription ?? "The note is too long.")
        }
    }

    static func validDetails(_ details: String?) throws(QuotedError) -> String? {
        guard let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard Limits.length(of: trimmed) <= Limits.reportDetailsMaxLength else {
            throw .validation("Details can be at most \(Limits.reportDetailsMaxLength) characters.")
        }
        return trimmed
    }

    static let profileError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "23505":
            error.constraintName == "profiles_pkey" || error.mentions("profiles_pkey")
                ? .validation("You already have a username.")
                : .usernameTaken
        case "23514":
            error.mentions("display_name")
                ? .validation("Names can be 1–50 characters.")
                : .validation("Usernames are 3–20 characters: letters a–z, numbers, underscores and periods.")
        default:
            nil
        }
    }

    static let friendRequestError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "23505": .validation("You're already friends, or a request is already waiting.")
        case "23514": .validation("You can't add yourself.")
        // RLS: a block between you (either direction). Answered like an unknown username, so a
        // block can't be told apart from a name nobody has (the lookup hides blocked pairs too).
        case "42501": .notFound
        case "23503": .notFound
        default: nil
        }
    }

    static let blockError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "23514": .validation("You can't block yourself.")
        case "23503": .notFound
        default: nil
        }
    }

    static let shareError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "42501": .validation("You can only share with friends.")
        case "23514": .validation("This quote can't be shared.")
        case "23503": .notFound
        default: nil
        }
    }
}
