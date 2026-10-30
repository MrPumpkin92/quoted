import Foundation
import QuotedCore
import Supabase

/// Reports (App Store guideline 1.2). A report names its target (a post, a message, a playlist or a
/// Quoted Catalog quote) and the person it is about; the server copies the reported content from
/// its own row, and the reporter never reads that copy back. A reported post, message or playlist
/// disappears for its reporter at once.
public struct ReportsRepository: Sendable {
    let client: SupabaseClient

    /// Files a report. `details` is optional (at most 500 characters).
    ///
    /// When the item is already gone (unsent, deleted, or no longer visible), the person is reported
    /// instead with `seen`, what the app showed, so the report still says what the reporter saw; a
    /// second gone item from the same person is a second report (the server tells them apart by
    /// that content). Reporting the same thing twice, or retrying after a lost answer, succeeds
    /// without a second report: the server refuses a duplicate (23505), and a post or playlist you
    /// already reported is no longer yours to see, so a report you already filed about it ends the
    /// call instead of falling back to the person.
    public func report(
        _ target: ReportTarget,
        reason: ReportReason,
        details: String? = nil,
        seen content: ReportContent? = nil
    ) async throws {
        let me = try client.requireUserID()
        if target.reportedUserID == me { throw QuotedError.validation("You can't report yourself.") }
        if reason == .wrongWording {
            guard case .catalogQuote = target else {
                throw QuotedError.validation("Wrong wording is only for Quoted Catalog quotes.")
            }
        }
        let cleanDetails = try Self.validDetails(details)
        let report: ReportInsert = switch target {
        case .profile(let userID): ReportInsert(userID: userID, reason: reason, details: cleanDetails, content: content)
        default: ReportInsert(target: target, reason: reason, details: cleanDetails)
        }
        try await mappingErrors {
            do {
                try await insert(report)
            } catch let error as PostgrestError where ["42501", "23503"].contains(error.code) {
                // The item is gone or hidden (for example unsent): report the person with what the
                // app showed. A catalog quote or a profile report has nothing to fall back to.
                guard let userID = target.reportedUserID, report.reportedUserID != nil,
                      report.postID != nil || report.messageID != nil || report.playlistID != nil
                else { throw error }
                // A post or playlist you reported disappears for you, so a second report of it (or
                // the retry of one whose answer was lost) is refused the same way: that report
                // stands, and the person is not reported again.
                if try await hasFiled(report, as: me) { return }
                try await insert(ReportInsert(userID: userID, reason: reason, details: cleanDetails, content: content))
            }
        }
    }

    /// Whether you already filed a report about `report`'s post, message or playlist (reporters
    /// read back the target ids of their own reports).
    private func hasFiled(_ report: ReportInsert, as me: UUID) async throws -> Bool {
        var query = client.from(Table.reports)
            .select("id")
            .eq("reporter_id", value: me)
        if let id = report.postID {
            query = query.eq("post_id", value: id)
        } else if let id = report.messageID {
            query = query.eq("message_id", value: id)
        } else if let id = report.playlistID {
            query = query.eq("playlist_id", value: id)
        } else {
            return false
        }
        let rows: [IDRow] = try await query.limit(1).execute().value
        return !rows.isEmpty
    }

    private struct IDRow: Decodable {
        let id: UUID
    }

    private func insert(_ report: ReportInsert) async throws {
        // Reporters read back only what they filed, and nothing needs the row back.
        do {
            try await client.from(Table.reports)
                .insert(report, returning: .minimal)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // The same report (reporter, person, target, and for a report about a person what it
            // carries) is already filed: a retry, or a second tap.
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
}
