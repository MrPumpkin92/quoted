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
            try await client.from(Table.profiles)
                .insert(insert, returning: .representation)
                .select(Columns.profile)
                .single()
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

    /// Whether nobody has `username` yet. Throws ``QuotedError/validation(_:)`` if it is not a valid
    /// username.
    public func isUsernameAvailable(_ username: String) async throws -> Bool {
        _ = try client.requireUserID()
        let name = try Self.validUsername(username)
        return try await mappingErrors {
            let rows: [IDRow] = try await client.from(Table.profiles)
                .select("id")
                .eq("username", value: name)
                .limit(1)
                .execute()
                .value
            return rows.isEmpty
        }
    }

    /// The profile with exactly this username (after normalizing "@Name" to "name"), or nil.
    public func findProfile(username: String) async throws -> Profile? {
        try await findProfile(username: username, retrying: true)
    }

    /// `retrying: false` skips the SDK's GET retries, for a lookup that runs before a write.
    func findProfile(username: String, retrying: Bool) async throws -> Profile? {
        _ = try client.requireUserID()
        guard let name = try? Username.validate(username) else { return nil }
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .select(Columns.profile)
                .eq("username", value: name)
                .maybeSingle()
                .retry(enabled: retrying)
                .execute()
                .value
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
        // No GET retries before the write: offline, fail at once instead of after 7 s of backoff.
        guard let profile = try await findProfile(username: name, retrying: false) else { throw QuotedError.notFound }
        guard profile.id != me else { throw QuotedError.validation("That's your own username.") }
        let row: Friendship = try await mappingErrors(postgrest: Self.friendRequestError) {
            try await client.from(Table.friendships)
                .insert(FriendRequestInsert(addresseeID: profile.id), returning: .representation)
                .select(Columns.friendship)
                .single()
                .execute()
                .value
        }
        return Self.decorate(row, me: me)
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
    @discardableResult
    public func share(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) async throws -> [SharedQuote] {
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
        func rows(quoteID: UUID?) -> [ShareInsert] {
            recipients.map {
                ShareInsert(
                    recipientID: $0, quoteID: quoteID, body: content.body, format: content.format,
                    author: content.author, source: content.source, note: cleanNote
                )
            }
        }
        return try await mappingErrors(postgrest: Self.shareError) {
            do {
                return try await insertShares(rows(quoteID: quote.id))
            } catch let error as PostgrestError
                where error.code == "42501" || (error.code == "23503" && error.mentions("shares_quote_id_fkey")) {
                // The policy also requires quote_id to be one of your quotes. If the original was
                // deleted elsewhere, send the snapshot without the link; a non-friend fails again.
                return try await insertShares(rows(quoteID: nil))
            }
        }
    }

    private func insertShares(_ rows: [ShareInsert]) async throws -> [SharedQuote] {
        try await client.from(Table.shares)
            .insert(rows, returning: .representation)
            .select(Columns.sentShare)
            .execute()
            .value
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

    /// Stamps `seen_at` on received shares that are not seen yet. The first time seen is kept.
    public func markSeen(_ ids: [UUID]) async throws {
        let me = try client.requireUserID()
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        try await mappingErrors {
            try await client.from(Table.shares)
                .update(ShareSeenUpdate(seenAt: Date()), returning: .minimal)
                .in("id", values: ids)
                .eq("recipient_id", value: me)
                .is("seen_at", value: nil)
                .execute()
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
        try await client.from(Table.reports)
            .insert(report, returning: .minimal)
            .execute()
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
        // RLS: there is a block between you (in either direction). Kept vague on purpose.
        case "42501": .validation("You can't send a friend request to this person.")
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
