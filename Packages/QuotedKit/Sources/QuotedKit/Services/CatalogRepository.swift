import Foundation
import QuotedCore
import Supabase

/// The verified catalog (`catalog_quotes`, read-only): the onboarding starters and the catalog
/// batches. Onboarding still reads only the starters, through ``StarterRepository``.
public struct CatalogRepository: Sendable {
    let client: SupabaseClient

    /// Every live catalog quote, by `id`. Read in pages of ``Paging/pageSize``, so a catalog larger
    /// than PostgREST's `max_rows` comes back whole.
    public func fetchLive() async throws -> [CatalogQuote] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await Paging.fetchAll { from, to in
                try await client.from(Table.catalogQuotes)
                    .select(Columns.catalogQuote, count: .exact)
                    .eq("status", value: CatalogStatus.live.rawValue)
                    .order("id")
                    .range(from: from, to: to)
                    .execute()
            }
        }
    }

    /// One catalog quote, whatever its status (the Verified sheet of a sealed quote), or nil when
    /// there is no such row.
    public func quote(id: Int) async throws -> CatalogQuote? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.catalogQuotes)
                .select(Columns.catalogQuote)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }
}
