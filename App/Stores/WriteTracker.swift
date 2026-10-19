import Foundation
import OSLog
import QuotedKit

/// Tells a store whether a refresh result can replace local state wholesale.
///
/// A refresh reads the server at some point while its request is in flight. If a server write was in
/// flight when the refresh started, or started before it returned, the rows may predate that write,
/// and applying them would undo it locally (a created quote vanishes, a deleted one comes back, a
/// "Saved" share flips back to "Save"). Stores call `begin()` before every server write and `end()`
/// when it settles, capture `token` before fetching, and apply the result only when
/// `isQuiet(since:)`. Otherwise they drop it and refresh again once `isIdle`.
struct WriteTracker {
    /// A point in the write history, captured when a refresh starts.
    struct Token: Equatable {
        fileprivate let epoch: Int
        fileprivate let inFlight: Int
    }

    /// Bumped by every `begin()`.
    private var epoch = 0
    /// Writes that began and have not ended.
    private(set) var inFlight = 0

    /// Whether no write is running.
    var isIdle: Bool { inFlight == 0 }

    /// The current point, for a refresh that is about to fetch.
    var token: Token { Token(epoch: epoch, inFlight: inFlight) }

    /// A server write starts.
    mutating func begin() {
        epoch += 1
        inFlight += 1
    }

    /// A server write finished (successfully or not).
    mutating func end() {
        inFlight = max(0, inFlight - 1)
    }

    /// Whether no write was running at `token` and none has started since.
    func isQuiet(since token: Token) -> Bool {
        token.inFlight == 0 && token.epoch == epoch
    }
}

/// How a shared, single-flight refresh ended. Every caller that joined it gets the same outcome.
enum RefreshOutcome: Sendable {
    /// The server answered and the result replaced local state.
    case applied
    /// The server answered, but a write overlapped the fetch, so the result was dropped. A new
    /// refresh runs once the writes settle.
    case superseded
    /// The fetch failed.
    case failed(QuotedError)
    /// Nothing was fetched or applied: signed out, another user, or cancelled.
    case skipped

    /// Whether the server answered (`refresh()`'s return value).
    var serverAnswered: Bool {
        switch self {
        case .applied, .superseded: true
        case .failed, .skipped: false
        }
    }
}

extension ToastCenter {
    /// Shows "<failure>. <friendly reason>" for a failed action ("Couldn't delete. You're offline. Try
    /// again when connected."), with the error haptic. Cancellation shows nothing.
    func show(error: any Error, failure: String) {
        guard let reason = Self.message(for: error) else { return }
        Logger.ui.error("Toast for error (\(failure, privacy: .public)): \(String(describing: error), privacy: .public)")
        Haptics.error()
        show("\(failure). \(reason)", style: .error)
    }
}
