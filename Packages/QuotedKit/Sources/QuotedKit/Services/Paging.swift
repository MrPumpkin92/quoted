import Foundation
import QuotedCore
import Supabase

/// Reads whole result sets in pages, so nothing is silently cut at PostgREST's `max_rows` (1000 in
/// `supabase/config.toml` and the hosted default).
enum Paging {
    /// Rows per request: well under `max_rows`.
    static let pageSize = 500

    /// Calls `page(from, to)` (an inclusive row range for `range(from:to:)`) until every row is read.
    ///
    /// Each page should select with `count: .exact` and order by a total order that ends in a unique
    /// column. Reading stops at an empty page or once the exact count is reached (without a count,
    /// at a short page), so a server whose `max_rows` is below ``pageSize`` is still read to the end.
    /// Rows are de-duplicated by `id`, in case an insert shifts a row onto the next page meanwhile.
    static func fetchAll<Row: Identifiable>(
        pageSize: Int = Paging.pageSize,
        _ page: (_ from: Int, _ to: Int) async throws -> PostgrestResponse<[Row]>
    ) async throws -> [Row] {
        var rows: [Row] = []
        var seen = Set<Row.ID>()
        var offset = 0
        while true {
            let response = try await page(offset, offset + pageSize - 1)
            let batch = response.value
            for row in batch where seen.insert(row.id).inserted {
                rows.append(row)
            }
            offset += batch.count
            if batch.isEmpty { return rows }
            if let total = response.count {
                if offset >= total { return rows }
            } else if batch.count < pageSize {
                return rows
            }
        }
    }
}

/// Keyset pages of newest-first lists ordered by `created_at desc, id` (the Feed, a conversation).
enum Keyset {
    /// The PostgREST `or` filter for the rows after `cursor` in that order: older, or as old with a
    /// later id. Timestamps are quoted, since they hold reserved characters (`.` and `:`).
    static func after(_ cursor: PageCursor) -> String {
        let time = Timestamp.string(from: cursor.createdAt)
        let id = cursor.id.uuidString.lowercased()
        return #"created_at.lt."\#(time)",and(created_at.eq."\#(time)",id.gt.\#(id))"#
    }
}
