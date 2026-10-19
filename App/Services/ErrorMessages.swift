import Foundation

extension Error {
    /// Friendly copy for any error, for inline form errors: QuotedError's `userMessage`, with the
    /// offline case as "You're offline. Try again when connected." Empty for cancellation.
    ///
    /// A plain `catch` binds `any Error` even around `throws(QuotedError)` calls, so use this:
    /// `catch { errorText = error.friendlyMessage }`.
    var friendlyMessage: String {
        ToastCenter.message(for: self) ?? ""
    }
}
