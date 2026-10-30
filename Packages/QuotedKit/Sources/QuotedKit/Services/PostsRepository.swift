import Foundation
import QuotedCore
import Supabase

/// Posts and the Feed. A post is a server-built snapshot of one of your quotes or a Quoted Catalog
/// quote, with an optional caption, for you and your accepted friends. Posting is a social write
/// (terms, no suspension). Strangers never read posts here; public posts reach them only through
/// ``ProfilesRepository/profileView(username:before:)``.
public struct PostsRepository: Sendable {
    let client: SupabaseClient

    /// Posts per Feed page.
    public static let pageSize = 30

    /// The Feed: your posts and your accepted friends' (not held, not reported by you), newest
    /// first, with each poster's profile. Pass the last post's ``Post/cursor`` for the next page; a
    /// page shorter than `limit` is the last.
    public func feed(after cursor: PageCursor? = nil, limit: Int = PostsRepository.pageSize) async throws -> [Post] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            var query = client.from(Table.posts).select(Columns.feedPost)
            if let cursor { query = query.or(Keyset.after(cursor)) }
            return try await query
                .order("created_at", ascending: false)
                .order("id")
                .limit(limit)
                .execute()
                .value
        }
    }

    /// One person's posts that you can see (yours, or an accepted friend's), newest first, with the
    /// poster's profile. For a stranger's public posts use ``ProfilesRepository/profileView(username:before:)``.
    public func posts(by userID: UUID, after cursor: PageCursor? = nil, limit: Int = PostsRepository.pageSize) async throws -> [Post] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            var query = client.from(Table.posts).select(Columns.feedPost).eq("author_id", value: userID)
            if let cursor { query = query.or(Keyset.after(cursor)) }
            return try await query
                .order("created_at", ascending: false)
                .order("id")
                .limit(limit)
                .execute()
                .value
        }
    }

    /// One post you can see, or nil (deleted, held, reported, blocked or unfriended).
    public func post(id: UUID) async throws -> Post? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.posts)
                .select(Columns.feedPost)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// Posts a quote. Only the quote reference, the caption and the audience travel; the server
    /// builds the snapshot. Keep the same `id` when retrying after a lost answer: the retry returns
    /// the post the first try made.
    ///
    /// Throws ``QuotedError/termsRequired`` before the terms are accepted,
    /// ``QuotedError/blockedWords(_:)`` (QR003), ``QuotedError/validation(_:)`` for a caption over
    /// 280 characters or the daily limit ("You can post at most 20 quotes a day."), and
    /// ``QuotedError/unavailable(_:)`` when the quote is no longer in your library.
    @discardableResult
    public func create(_ draft: PostDraft, id: UUID = UUID()) async throws -> Post {
        let me = try client.requireUserID()
        let insert = PostInsert(id: id, source: draft.source, caption: try validCaption(draft), audience: draft.audience)
        return try await mappingErrors(postgrest: Self.postError) {
            do {
                return try await client.from(Table.posts)
                    .insert(insert, returning: .representation)
                    .select(Columns.post)
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError where error.mayHideEarlierInsert {
                // A retry whose first try landed: that post is the result (23505, or 42501 when the
                // quote it was made from has been deleted since).
                let existing: Post? = try await client.from(Table.posts)
                    .select(Columns.post)
                    .eq("id", value: id)
                    .eq("author_id", value: me)
                    .maybeSingle()
                    .execute()
                    .value
                guard let existing else { throw error }
                return existing
            }
        }
    }

    /// Changes who can see one of your posts. Public needs ``MyAccount/canPublish`` and a quote you
    /// added (or a catalog quote).
    @discardableResult
    public func setAudience(_ audience: Audience, for postID: UUID) async throws -> Post {
        _ = try client.requireUserID()
        return try await mappingErrors(postgrest: Self.postError) {
            try await client.from(Table.posts)
                .update(AudienceUpdate(audience: audience), returning: .representation)
                .eq("id", value: postID)
                .select(Columns.post)
                .single()
                .execute()
                .value
        }
    }

    /// Deletes one of your posts. Copies friends saved stay in their libraries; the post still counts
    /// toward today's limit. Deleting one that is already gone succeeds.
    public func delete(id: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.posts)
                .delete(returning: .minimal)
                .eq("id", value: id)
                .execute()
        }
    }

    // MARK: Helpers

    private func validCaption(_ draft: PostDraft) throws(QuotedError) -> String? {
        do {
            return try draft.validatedCaption()
        } catch {
            throw .validation(error.errorDescription ?? "Shorten the caption.")
        }
    }

    /// The source quote was deleted meanwhile (the server refuses a quote that isn't yours).
    static let postError: QuotedError.PostgrestOverride = { error in
        if error.code == "42501", error.message == "You can post only quotes from your Library or the Quoted Catalog." {
            return .unavailable("That quote is no longer in your library.")
        }
        return nil
    }
}
