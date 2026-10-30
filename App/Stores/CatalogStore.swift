import Foundation
import Observation
import QuotedCore
import QuotedKit

/// The verified catalog (`catalog_quotes`): every live quote for Verified Quotes, loaded once per
/// session, and any catalog quote by id for the Verified sheet, kept per session.
/// Inject with `@Environment(CatalogStore.self)`.
///
/// Onboarding doesn't use it: it offers only the starters, through `StarterStore`.
@Observable
@MainActor
final class CatalogStore {
    /// Every live catalog quote, by id. Empty until `load()` succeeds.
    private(set) var quotes: [CatalogQuote] = []
    /// True once a load succeeded this session (an empty catalog then means none, not loading).
    private(set) var hasLoaded = false
    /// True while loading.
    private(set) var isLoading = false
    /// The last load error (show it inline with a retry), cleared by the next success.
    private(set) var lastError: QuotedError?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let starter: StarterStore
    /// Catalog quotes looked up by id this session, whatever their status (`verifiedSource(id:)`).
    @ObservationIgnored private var lookedUp: [Int: CatalogQuote] = [:]

    init(backend: Backend, starter: StarterStore) {
        self.backend = backend
        self.starter = starter
    }

    /// `quotes` in sections by first theme, in the fixed theme order.
    var sections: [CatalogSection] { CatalogQuote.sections(quotes) }

    /// Loads the live catalog unless it is already loaded (pass `force` to reload).
    func load(force: Bool = false) async {
        guard force || !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            quotes = try await backend.catalog.fetchLive()
            hasLoaded = true
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = QuotedError(error)
        }
    }

    /// The catalog quote a verified quote matches (its location, link and speaker), for the Verified
    /// sheet. Any catalog id resolves, live or not: from the loaded list, from this session's
    /// lookups, or with one request (`catalog_quotes?id=eq.N`). When that request fails (offline),
    /// a starter still resolves from the starter pack if it was loaded. Nil when none of those has it.
    func verifiedSource(id: Int) async -> CatalogQuote? {
        if let known = lookedUp[id] ?? quotes.first(where: { $0.id == id }) {
            return known
        }
        do {
            if let quote = try await backend.catalog.quote(id: id) {
                lookedUp[id] = quote
                return quote
            }
        } catch is CancellationError {
            return nil
        } catch {
            // Offline or failing: try the starter pack below.
        }
        return starter.quotes.first { $0.id == id }.map(CatalogQuote.init(starter:))
    }

    /// Forgets the catalog and the lookups (sign-out).
    func reset() {
        quotes = []
        hasLoaded = false
        isLoading = false
        lastError = nil
        lookedUp = [:]
    }

    /// Seeds quotes for SwiftUI previews.
    func seedPreview(quotes: [CatalogQuote]) {
        self.quotes = quotes
        hasLoaded = true
    }
}
