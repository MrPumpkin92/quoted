import Foundation
import Observation
import QuotedCore
import QuotedKit

/// The public-domain starter pack (`starter_quotes`), loaded once per session.
/// Inject with `@Environment(StarterStore.self)`.
@Observable
@MainActor
final class StarterStore {
    /// Every starter quote, by sort order. Empty until `load()` succeeds.
    private(set) var quotes: [StarterQuote] = []
    /// True while loading.
    private(set) var isLoading = false
    /// The last load error (show it inline with a retry), cleared by the next success.
    private(set) var lastError: QuotedError?

    @ObservationIgnored private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    /// Loads the starter pack unless it is already loaded (pass `force` to reload).
    func load(force: Bool = false) async {
        guard force || quotes.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            quotes = try await backend.starter.fetchAll()
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = QuotedError(error)
        }
    }

    /// Forgets the loaded pack (sign-out).
    func reset() {
        quotes = []
        isLoading = false
        lastError = nil
    }

    /// Seeds quotes for SwiftUI previews.
    func seedPreview(quotes: [StarterQuote]) {
        self.quotes = quotes
    }
}
