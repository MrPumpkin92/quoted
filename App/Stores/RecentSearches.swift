import Foundation
import Observation

/// The last five search terms, newest first, kept on this device (`UserDefaults.standard`) and
/// cleared on sign-out. Inject with `@Environment(RecentSearches.self)`.
@Observable
@MainActor
final class RecentSearches {
    /// How many terms are kept.
    static let limit = 5

    /// Newest first, at most five, no duplicates (case-insensitive).
    private(set) var terms: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "quoted.recentSearches"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: "quoted.recentSearches") ?? []
    }

    /// Records a submitted search. Blank terms are ignored; a repeat moves to the top.
    func add(_ term: String) {
        let clean = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return }
        var updated = terms.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        updated.insert(clean, at: 0)
        terms = Array(updated.prefix(Self.limit))
        save()
    }

    /// Removes one term.
    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        save()
    }

    /// Removes every term (the Clear button, and sign-out).
    func clear() {
        terms = []
        save()
    }

    private func save() {
        defaults.set(terms, forKey: key)
    }
}
