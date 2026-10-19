import Foundation
import QuotedCore
import Supabase

/// The signed-in user's library (`quotes`, owner only under RLS).
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

    /// Validates and saves a new quote. Pass `rotationPosition` to add it to the Rotation at that
    /// position (see ``nextRotationPosition()``).
    public func create(
        _ draft: QuoteDraft,
        origin: QuoteOrigin = .manual,
        rotationPosition: Int? = nil
    ) async throws -> Quote {
        _ = try client.requireUserID()
        let validated = try validate(draft)
        let insert = QuoteInsert(validated, origin: origin, rotationPosition: rotationPosition.map { max(0, $0) })
        return try await mappingErrors {
            try await client.from(Table.quotes)
                .insert(insert, returning: .representation)
                .select(Columns.quote)
                .single()
                .execute()
                .value
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

    /// Puts a deleted quote back with the same ID, content, origin and `rotationPosition` (Undo for
    /// delete). Restoring a quote that still exists rewrites it with these values, so a retry is
    /// harmless.
    ///
    /// Timestamps are server-owned (migration `20261019060000_hardening`), so a quote that was really
    /// deleted comes back with new `createdAt` and `updatedAt` and sorts as the newest. The position
    /// is written as given; if the Rotation was renumbered meanwhile, follow with
    /// ``setRotation(ordered:removing:)``.
    public func restore(_ quote: Quote) async throws -> Quote {
        _ = try client.requireUserID()
        let validated = try validate(QuoteDraft(quote: quote))
        let row = QuoteRestoreRow(quote, content: validated)
        return try await mappingErrors {
            try await client.from(Table.quotes)
                .upsert(row, onConflict: "id", returning: .representation)
                .select(Columns.quote)
                .single()
                .execute()
                .value
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

    /// Copies starter quotes into the library (origin `starter`) in one insert, in the given order.
    /// With `addToRotation`, they join the end of the Rotation in that order.
    public func importStarter(_ starters: [StarterQuote], addToRotation: Bool) async throws -> [Quote] {
        _ = try client.requireUserID()
        guard !starters.isEmpty else { return [] }
        let validated = try starters.map { try validate(QuoteDraft(starter: $0)) }
        let start = addToRotation ? try await nextRotationPosition() : 0
        let inserts = validated.enumerated().map { offset, value in
            QuoteInsert(value, origin: .starter, rotationPosition: addToRotation ? start + offset : nil)
        }
        return try await mappingErrors {
            let inserted: [Quote] = try await client.from(Table.quotes)
                .insert(inserts, returning: .representation)
                .select(Columns.quote)
                .execute()
                .value
            return addToRotation ? inserted.sorted(by: Self.rotationOrder) : inserted
        }
    }

    /// Copies a received share into the library (origin `shared`), then marks the share saved.
    ///
    /// Marking is best effort: once the copy exists, a failure to stamp `saved_at` is not reported,
    /// so a retry cannot create a duplicate.
    public func saveShared(_ share: SharedQuote, addToRotation: Bool) async throws -> Quote {
        let me = try client.requireUserID()
        guard share.recipientID == me else { throw QuotedError.notFound }
        let validated = try validate(QuoteDraft(shared: share))
        let position = addToRotation ? try await nextRotationPosition() : nil
        let quote: Quote = try await mappingErrors {
            try await client.from(Table.quotes)
                .insert(QuoteInsert(validated, origin: .shared, rotationPosition: position), returning: .representation)
                .select(Columns.quote)
                .single()
                .execute()
                .value
        }
        do {
            try await client.from(Table.shares)
                .update(ShareSavedUpdate(savedAt: Date()), returning: .minimal)
                .eq("id", value: share.id)
                .eq("recipient_id", value: me)
                .execute()
        } catch {
            // Best effort; see the doc comment.
        }
        return quote
    }

    // MARK: Helpers

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
