import Foundation
import QuotedCore
import Supabase

/// Friends and blocks. Requesting and accepting a friend are social writes: they need the current
/// Terms of Use (``QuotedError/termsRequired``) and no suspension (``QuotedError/suspended``).
public struct SocialRepository: Sendable {
    let client: SupabaseClient
    let profiles: ProfilesRepository

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
        let name = try ProfilesRepository.validUsername(username)
        // No retries before the write: offline, fail at once instead of after seconds of backoff.
        guard let profile = try await profiles.findProfile(username: name, retrying: false) else {
            // The lookup never returns yourself; tell that case apart only when it comes back empty.
            if let mine = try? await profiles.myProfile(), mine.username == name {
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
    /// you, or is already accepted. A new friendship reopens your old conversation, if any.
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

    /// Blocks a user. The server also ends the friendship (or request) and closes your conversation;
    /// nothing is deleted, so you can still read it and report from it. They lose access to your
    /// conversation, posts, playlists, favorites and profile. Blocking someone already blocked succeeds.
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

    /// Unblocks a user. The friendship ended by the block does not come back, and the conversation
    /// stays closed until you are friends again.
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

    /// The users you have blocked, most recent first, with their profiles. Read in pages (see
    /// ``Paging``). Someone who blocked you back is still listed, without a profile (the server no
    /// longer shows it to you), so you can unblock them.
    public func blockedUsers() async throws -> [BlockedUser] {
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
        return rows.map { BlockedUser(id: $0.blockedID, profile: $0.blocked) }
    }

    // MARK: Helpers

    static func decorate(_ friendship: Friendship, me: UUID) -> Friendship {
        var copy = friendship
        copy.otherParty = friendship.otherParty(for: me)
        return copy
    }

    static let friendRequestError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "23505": .validation("You're already friends, or a request is already waiting.")
        case "23514": .validation("You can't add yourself.")
        // RLS: a block between you (either direction). Answered like an unknown username, so a
        // block can't be told apart from a name nobody has (the lookup hides blocked pairs too).
        // Terms and suspension are mapped before this override.
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
}
