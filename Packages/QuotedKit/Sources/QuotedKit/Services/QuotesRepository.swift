import Foundation
import QuotedCore
import Supabase

/// The signed-in user's library (`quotes`, owner only under RLS), and saving other people's quotes
/// into it through the server's save functions.
///
/// The server owns `origin` and provenance: a direct insert is your own words (manual or pasted, and
/// you become the creator); catalog quotes come only from ``addCatalogQuotes(_:ids:inReminders:)`` and
/// other people's words only from ``save(_:id:inReminders:)``, which keep their creator.
public struct QuotesRepository: Sendable {
    let client: SupabaseClient

    /// Every quote the user owns, newest first. Read in pages of ``Paging/pageSize``, so a library
    /// larger than PostgREST's `max_rows` comes back whole.
    public func fetchMine() async throws -> [Quote] {
        let me = try client.requireUserID()
        return try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.quotes)
                    .select(Columns.quote, count: .exact)
                    .eq("owner_id", value: me)
                    .order("created_at", ascending: false)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
    }

    /// Validates and saves a new quote of your own with the given `id` (you become its creator).
    /// `origin` is `.manual` (typed) or `.pasted`; the server sets every other origin. Pass
    /// `rotationPosition` to add it to the Rotation at that position (see ``nextRotationPosition()``).
    /// A position another of your quotes already holds moves to the end of the Rotation on the server
    /// (migration `20261021100000_rotation_position_on_insert`); the returned quote has the final one.
    ///
    /// Keep the same `id` when retrying a save whose answer was lost: if the first insert reached
    /// the server, the retry returns that quote instead of creating a second one.
    public func create(
        _ draft: QuoteDraft,
        id: UUID = UUID(),
        origin: QuoteOrigin = .manual,
        rotationPosition: Int? = nil
    ) async throws -> Quote {
        _ = try client.requireUserID()
        guard origin == .manual || origin == .pasted else {
            throw QuotedError.server("origin \(origin.rawValue) is set by the server; use addCatalogQuotes or save")
        }
        let validated = try validate(draft)
        let insert = QuoteInsert(validated, id: id, origin: origin, rotationPosition: rotationPosition.map { max(0, $0) })
        return try await mappingErrors(postgrest: Self.quoteLimitError) {
            let inserted = try await insertRecovering(ids: [id]) {
                try await client.from(Table.quotes)
                    .insert(insert, returning: .representation)
                    .select(Columns.quote)
                    .execute()
                    .value
            }
            guard let quote = inserted.first else { throw QuotedError.server("The saved quote was not returned") }
            return quote
        }
    }

    /// Saves edits to a quote's body, format, author and source. Rotation membership changes only
    /// through ``setRotation(ordered:removing:)``. Throws ``QuotedError/notFound`` if the quote is
    /// gone.
    public func update(_ quote: Quote) async throws -> Quote {
        _ = try client.requireUserID()
        let validated = try validate(QuoteDraft(quote: quote))
        return try await mappingErrors {
            try await client.from(Table.quotes)
                .update(QuoteContentUpdate(validated), returning: .representation)
                .eq("id", value: quote.id)
                .select(Columns.quote)
                .single()
                .execute()
                .value
        }
    }

    /// Hearts or un-hearts one of your quotes. The server stamps `favoritedAt`. Throws
    /// ``QuotedError/notFound`` if the quote is gone.
    public func setFavorite(id: UUID, _ isFavorite: Bool) async throws -> Quote {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.quotes)
                .update(FavoriteUpdate(isFavorite: isFavorite), returning: .representation)
                .eq("id", value: id)
                .select(Columns.quote)
                .single()
                .execute()
                .value
        }
    }

    /// Deletes a quote. Deleting one that is already gone succeeds.
    public func delete(id: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.quotes)
                .delete(returning: .minimal)
                .eq("id", value: id)
                .execute()
        }
    }

    /// Puts a deleted quote back with the same ID, content, heart and `rotationPosition` (Undo for
    /// delete). A plain insert, never an upsert: the server gives the row back its origin and
    /// provenance from the one-day tombstone it kept, so "Added by" survives Undo. Restoring a quote
    /// that still exists returns it as it is, so a retry is harmless: the retry of a manual quote
    /// gets 23505, and the retry of a catalog or shared one 42501 (the first try used up its
    /// tombstone, and without one the server refuses an origin it sets), and both read the quote back.
    /// A catalog or shared quote whose tombstone is gone (over a day) fails with
    /// ``QuotedError/server(_:)``.
    ///
    /// Timestamps are server-owned (migration `20261019060000_hardening`), so a quote that was really
    /// deleted comes back with new `createdAt` and `updatedAt` and sorts as the newest. The position
    /// is written as given; if the Rotation was renumbered meanwhile, follow with
    /// ``setRotation(ordered:removing:)``.
    public func restore(_ quote: Quote) async throws -> Quote {
        _ = try client.requireUserID()
        let validated = try validate(QuoteDraft(quote: quote))
        let row = QuoteRestoreRow(quote, content: validated)
        return try await mappingErrors(postgrest: Self.quoteLimitError) {
            let restored = try await insertRecovering(ids: [quote.id], alsoAfterRefusal: true) {
                try await client.from(Table.quotes)
                    .insert(row, returning: .representation)
                    .select(Columns.quote)
                    .execute()
                    .value
            }
            guard let first = restored.first else { throw QuotedError.server("The restored quote was not returned") }
            return first
        }
    }

    /// Writes the Rotation with one call to `public.set_rotation` (migration
    /// `20261019070000_set_rotation`): `ordered` gets positions 0…n-1, `removing` gets null. An ID in
    /// both lists stays in the Rotation, and duplicates keep their first position. Returns the
    /// updated quotes, Rotation first.
    ///
    /// Only IDs travel, in the POST body, so the request stays small for any Rotation size and never
    /// writes content: an edit made on another device is never overwritten by this device's copy.
    /// The function updates only the caller's existing quotes (RLS applies), so a quote deleted
    /// elsewhere is skipped, never re-inserted, and the positions have no gap where it was.
    @discardableResult
    public func setRotation(ordered: [Quote], removing: [Quote] = []) async throws -> [Quote] {
        _ = try client.requireUserID()
        let params = SetRotationParams(ordered: ordered.map(\.id), removing: removing.map(\.id))
        guard !params.isEmpty else { return [] }
        let written: [Quote] = try await mappingErrors {
            try await client.rpc(RPC.setRotation, params: params)
                .select(Columns.quote)
                .execute()
                .value
        }
        return written.sorted(by: Self.rotationOrder)
    }

    /// The position after the last quote in the Rotation (0 when it is empty).
    ///
    /// Not retried: it runs before a write, and the SDK's GET retries (1 + 2 + 4 s) would hold the
    /// write's spinner for seconds offline before the error.
    public func nextRotationPosition() async throws -> Int {
        let me = try client.requireUserID()
        return try await mappingErrors {
            let rows: [RotationPositionRow] = try await client.from(Table.quotes)
                .select("rotation_position")
                .eq("owner_id", value: me)
                .not("rotation_position", operator: .is, value: "null")
                .order("rotation_position", ascending: false)
                .limit(1)
                .retry(enabled: false)
                .execute()
                .value
            return (rows.first?.rotationPosition).map { $0 + 1 } ?? 0
        }
    }

    /// Saves Quoted Catalog quotes (`catalog_quotes` ids: the onboarding starters and the Verified
    /// Quotes list) to the library, in the given order, through `public.add_catalog_quotes`. The
    /// server records origin `starter` for a starter and `catalog` for the rest
    /// (``CatalogQuote/libraryOrigin``), with no creator ("Quoted Catalog"). With `inReminders`, the
    /// server appends them to the end of the Rotation in that order.
    ///
    /// `ids` (one per catalog id, in order) are the new quotes' IDs; pass the same ones to retry after
    /// a lost answer and get the same quotes back. Missing IDs are generated. An unknown catalog id
    /// fails with ``QuotedError/notFound``.
    public func addCatalogQuotes(_ catalogIDs: [Int], ids: [UUID] = [], inReminders: Bool = false) async throws -> [Quote] {
        _ = try client.requireUserID()
        guard !catalogIDs.isEmpty else { return [] }
        let params = AddCatalogQuotesParams(
            starterIDs: catalogIDs,
            ids: catalogIDs.indices.map { $0 < ids.count ? ids[$0] : UUID() },
            inReminders: inReminders
        )
        return try await mappingErrors(postgrest: Self.quoteLimitError) {
            try await client.rpc(RPC.addCatalogQuotes, params: params)
                .select(Columns.quote)
                .execute()
                .value
        }
    }

    /// Saves someone else's quote to your library (origin `shared`, keeping its creator and "edited
    /// from", never the sender's name unless they added it), through the server function for its
    /// source: `save_from_post`, `save_from_message`, `save_from_favorite`, `save_from_playlist`, or
    /// `add_catalog_quotes` for a catalog quote. Saving is private: it needs no terms. With
    /// `inReminders` it joins the end of the Rotation.
    ///
    /// Pass the same `id` to retry after a lost answer. A playlist item whose text and author you
    /// already hold returns that quote instead (its id may differ). Throws
    /// ``QuotedError/unavailable(_:)`` when you can't see the source any more (deleted, unsent,
    /// reported, blocked, unfriended).
    @discardableResult
    public func save(_ source: SnapshotRef, id: UUID = UUID(), inReminders: Bool = false) async throws -> Quote {
        _ = try client.requireUserID()
        let params = SaveParams(source: source, id: id, inReminders: inReminders)
        guard let function = params.function else {
            guard case .catalog(let catalogID) = source,
                  let quote = try await addCatalogQuotes([catalogID], ids: [id], inReminders: inReminders).first
            else { throw QuotedError.server("The saved quote was not returned") }
            return quote
        }
        return try await mappingErrors(postgrest: Self.quoteLimitError) {
            try await client.rpc(function, params: params)
                .select(Columns.quote)
                .single()
                .execute()
                .value
        }
    }

    // MARK: Helpers

    /// Runs an insert of quotes with client-chosen `ids`. A unique violation can mean an earlier
    /// attempt with the same IDs reached the server and only its answer was lost: then every one of
    /// `ids` is already a visible quote, and those rows are the result (in `ids` order). With
    /// `alsoAfterRefusal`, a 42501 is read back the same way (a BEFORE INSERT check that refuses the
    /// retry before the primary key can; see ``PostgrestError/mayHideEarlierInsert``). Any other
    /// conflict (for example a Rotation position) is thrown as it came.
    private func insertRecovering(
        ids: [UUID],
        alsoAfterRefusal: Bool = false,
        _ insert: () async throws -> [Quote]
    ) async throws -> [Quote] {
        do {
            return try await insert()
        } catch let error as PostgrestError
            where error.code == "23505" || (alsoAfterRefusal && error.mayHideEarlierInsert) {
            let existing: [Quote] = try await client.from(Table.quotes)
                .select(Columns.quote)
                .in("id", values: ids)
                .execute()
                .value
            guard existing.count == Set(ids).count else { throw error }
            let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }
        }
    }

    /// `QR002` from a quote insert is the per-account cap (migration
    /// `20261021090000_abuse_limits_privacy_cleanup`).
    static let quoteLimitError: QuotedError.PostgrestOverride = { error in
        error.code == "QR002"
            ? .validation("You've reached the limit of \(Limits.quotesPerAccount.formatted()) quotes.")
            : nil
    }

    private func validate(_ draft: QuoteDraft) throws(QuotedError) -> QuoteDraft.Validated {
        do {
            return try draft.validated()
        } catch {
            throw .validation(error.errorDescription ?? "Check the quote and try again.")
        }
    }

    /// Rotation members by position, then the rest.
    static func rotationOrder(_ lhs: Quote, _ rhs: Quote) -> Bool {
        switch (lhs.rotationPosition, rhs.rotationPosition) {
        case let (l?, r?): l < r
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.createdAt > rhs.createdAt
        }
    }
}
