import Foundation
import QuotedCore
import Supabase

/// Playlists: titled, ordered lists of quotes from your own library. Yours are owner only; anyone
/// else's you read through `playlist_view` (live and read only), save from, or copy.
///
/// A playlist friends can see is a social write (terms, no suspension), when it is created that way,
/// widened, or added to. Limits: 20 new a day, 100 in all, 200 quotes each.
public struct PlaylistsRepository: Sendable {
    let client: SupabaseClient

    // MARK: Yours

    /// Your playlists with their items in order, most recently changed first. Read in pages (see
    /// ``Paging``). The items are your own quotes' ids: join them with the library for rows.
    public func mine() async throws -> [Playlist] {
        let me = try client.requireUserID()
        return try await mappingErrors {
            let playlists: [Playlist] = try await Paging.fetchAll { from, to in
                try await client.from(Table.playlists)
                    .select(Columns.playlist, count: .exact)
                    .eq("owner_id", value: me)
                    .order("updated_at", ascending: false)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
            let entries = try await self.entries(in: playlists.map(\.id))
            return playlists.map { playlist in
                var copy = playlist
                copy.entries = PlaylistEntry.sorted(entries[playlist.id] ?? [])
                return copy
            }
        }
    }

    /// One of your playlists with its items, or nil when it is gone (or not yours).
    public func playlist(id: UUID) async throws -> Playlist? {
        let me = try client.requireUserID()
        return try await mappingErrors {
            let row: Playlist? = try await client.from(Table.playlists)
                .select(Columns.playlist)
                .eq("id", value: id)
                .eq("owner_id", value: me)
                .maybeSingle()
                .execute()
                .value
            guard var playlist = row else { return nil }
            playlist.entries = PlaylistEntry.sorted(try await entries(in: [id])[id] ?? [])
            return playlist
        }
    }

    /// Creates a playlist. Keep the same `id` when retrying after a lost answer. Throws
    /// ``QuotedError/validation(_:)`` for a blank or long title and the limits,
    /// ``QuotedError/blockedWords(_:)`` (QR003), and ``QuotedError/termsRequired`` for one friends
    /// can see before the terms are accepted.
    public func create(title: String, visibility: Audience = .friends, id: UUID = UUID()) async throws -> Playlist {
        let me = try client.requireUserID()
        let insert = PlaylistInsert(id: id, title: try Self.validTitle(title), visibility: visibility)
        return try await mappingErrors(postgrest: Self.playlistError) {
            do {
                return try await client.from(Table.playlists)
                    .insert(insert, returning: .representation)
                    .select(Columns.playlist)
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError where error.code == "23505" {
                // A retry whose first try landed: that playlist is the result.
                guard let existing = try await playlist(id: id), existing.ownerID == me else { throw error }
                return existing
            }
        }
    }

    /// Renames one of your playlists (1–60 characters). Returns it without items.
    public func rename(_ playlistID: UUID, to title: String) async throws -> Playlist {
        _ = try client.requireUserID()
        let update = PlaylistTitleUpdate(title: try Self.validTitle(title))
        return try await updatePlaylist(playlistID, update)
    }

    /// Changes who can see one of your playlists. Widening to Friends needs the terms; Anyone needs
    /// ``MyAccount/canPublish`` and only quotes you added or catalog quotes. Returns it without items.
    public func setVisibility(_ visibility: Audience, for playlistID: UUID) async throws -> Playlist {
        _ = try client.requireUserID()
        return try await updatePlaylist(playlistID, VisibilityUpdate(visibility: visibility))
    }

    /// Deletes one of your playlists. The quotes stay in your library; friends you sent it to see
    /// "This playlist is no longer available". Deleting one that is already gone succeeds.
    public func delete(id: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.playlists)
                .delete(returning: .minimal)
                .eq("id", value: id)
                .execute()
        }
    }

    // MARK: Items

    /// Appends your quotes to the end of one of your playlists, in order. Quotes already in it are
    /// skipped (so a retry is harmless); returns the items added. Throws
    /// ``QuotedError/validation(_:)`` past 200 quotes ("A playlist holds up to 200 quotes.").
    @discardableResult
    public func add(_ quoteIDs: [UUID], to playlistID: UUID) async throws -> [PlaylistEntry] {
        _ = try client.requireUserID()
        var seen = Set<UUID>()
        let unique = quoteIDs.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        let last = try await lastPosition(in: playlistID)
        let rows = zip(unique, PlaylistOrder.appended(count: unique.count, after: last)).map { quoteID, position in
            PlaylistItemInsert(playlistID: playlistID, quoteID: quoteID, position: position)
        }
        return try await insertItems(rows)
    }

    /// Puts a removed item back where it was (Undo of Remove).
    @discardableResult
    public func restore(_ entry: PlaylistEntry) async throws -> PlaylistEntry {
        _ = try client.requireUserID()
        let row = PlaylistItemInsert(playlistID: entry.playlistID, quoteID: entry.quoteID, position: max(0, entry.position))
        let inserted = try await insertItems([row])
        return inserted.first ?? entry
    }

    /// Removes a quote from one of your playlists. The quote stays in your library.
    public func remove(quoteID: UUID, from playlistID: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.playlistItems)
                .delete(returning: .minimal)
                .eq("playlist_id", value: playlistID)
                .eq("quote_id", value: quoteID)
                .execute()
        }
    }

    /// Saves a new order for one of your playlists: `entries` are its items in the new order, with
    /// their current positions. Only the items that must move are written (``PlaylistOrder/plan(_:)``),
    /// all in one call (`public.set_playlist_positions`), so the order lands whole or not at all.
    /// Returns the entries in the new order with their new positions. Retrying after a lost answer
    /// writes the same positions again.
    @discardableResult
    public func reorder(_ playlistID: UUID, entries: [PlaylistEntry]) async throws -> [PlaylistEntry] {
        _ = try client.requireUserID()
        let plan = PlaylistOrder.plan(entries.map(\.position))
        var result = entries
        var moves = SetPlaylistPositionsParams(playlist: playlistID, quoteIDs: [], positions: [])
        for (index, position) in plan.enumerated() {
            guard let position else { continue }
            moves.quoteIDs.append(entries[index].quoteID)
            moves.positions.append(position)
            result[index].position = position
        }
        guard !moves.quoteIDs.isEmpty else { return result }
        try await mappingErrors {
            try await client.rpc(RPC.setPlaylistPositions, params: moves)
                .select("playlist_id")
                .execute()
        }
        return result
    }

    // MARK: Anyone's

    /// A playlist as you may see it (`public.playlist_view`): yours, or a friend's that friends can
    /// see. Nil when it is no longer available (deleted, narrowed to Only me, unfriended, blocked,
    /// held). Items carry per-viewer handles for ``QuotesRepository/save(_:id:inReminders:)``.
    public func view(id: UUID) async throws -> PlaylistView? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.rpc(RPC.playlistView, params: PlaylistParam(playlist: id))
                .execute()
                .value
        }
    }

    /// "Save a copy": a new private playlist of yours with the items you can see, each keeping its
    /// creator; quotes you already hold (same text and author) are reused. `title` defaults to the
    /// original's. Returns the copy with its items. Throws ``QuotedError/unavailable(_:)`` when you
    /// can no longer see the playlist.
    public func saveCopy(of playlistID: UUID, title: String? = nil) async throws -> Playlist {
        _ = try client.requireUserID()
        let params = SavePlaylistCopyParams(playlist: playlistID, title: try title.map(Self.validTitle))
        return try await mappingErrors(postgrest: Self.playlistError) {
            var copy: Playlist = try await client.rpc(RPC.savePlaylistCopy, params: params)
                .select(Columns.playlist)
                .single()
                .execute()
                .value
            copy.entries = PlaylistEntry.sorted(try await entries(in: [copy.id])[copy.id] ?? [])
            return copy
        }
    }

    // MARK: Helpers

    /// A `playlist_items` row with an id across playlists, for ``Paging``.
    private struct EntryRow: Decodable, Identifiable {
        let entry: PlaylistEntry
        var id: String { "\(entry.playlistID)/\(entry.quoteID)" }

        init(from decoder: any Decoder) throws {
            entry = try PlaylistEntry(from: decoder)
        }
    }

    /// The items of these playlists, by playlist.
    private func entries(in playlistIDs: [UUID]) async throws -> [UUID: [PlaylistEntry]] {
        guard !playlistIDs.isEmpty else { return [:] }
        let rows: [EntryRow] = try await Paging.fetchAll { from, to in
            try await client.from(Table.playlistItems)
                .select(Columns.playlistEntry, count: .exact)
                .in("playlist_id", values: playlistIDs)
                .order("playlist_id")
                .order("position")
                .order("quote_id")
                .range(from: from, to: to)
                .execute()
        }
        return Dictionary(grouping: rows.map(\.entry), by: \.playlistID)
    }

    /// The highest position in a playlist, or nil when it is empty. Not retried: it runs before a write.
    private func lastPosition(in playlistID: UUID) async throws -> Int? {
        try await mappingErrors {
            let rows: [PositionRow] = try await client.from(Table.playlistItems)
                .select("position")
                .eq("playlist_id", value: playlistID)
                .order("position", ascending: false)
                .limit(1)
                .retry(enabled: false)
                .execute()
                .value
            return rows.first?.position
        }
    }

    /// Inserts items, skipping any already in their playlist (`on conflict do nothing`, which needs
    /// only the insert grant). Returns the rows inserted.
    private func insertItems(_ rows: [PlaylistItemInsert]) async throws -> [PlaylistEntry] {
        try await mappingErrors(postgrest: Self.itemError) {
            try await client.from(Table.playlistItems)
                .upsert(rows, onConflict: "playlist_id,quote_id", returning: .representation, ignoreDuplicates: true)
                .select(Columns.playlistEntry)
                .execute()
                .value
        }
    }

    private func updatePlaylist(_ playlistID: UUID, _ update: some Encodable & Sendable) async throws -> Playlist {
        try await mappingErrors(postgrest: Self.playlistError) {
            try await client.from(Table.playlists)
                .update(update, returning: .representation)
                .eq("id", value: playlistID)
                .select(Columns.playlist)
                .single()
                .execute()
                .value
        }
    }

    static func validTitle(_ title: String) throws(QuotedError) -> String {
        do {
            return try SocialText.playlistTitle(title)
        } catch {
            throw .validation(error.errorDescription ?? "Check the title.")
        }
    }

    static let playlistError: QuotedError.PostgrestOverride = { error in
        error.code == "QR003" ? .blockedWords(QuotedError.blockedWordsInPlaylistTitles) : nil
    }

    /// Someone else's quote id and an unknown one fail alike: the quote is no longer yours.
    static let itemError: QuotedError.PostgrestOverride = { error in
        guard error.code == "42501", !QuotedError.isWrittenForPeople(error.message) else { return nil }
        return .unavailable("That quote is no longer in your library.")
    }
}
