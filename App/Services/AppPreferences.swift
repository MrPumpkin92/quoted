import Foundation
import Observation
import QuotedCore

/// Small device-local flags, kept in the App Group `UserDefaults` suite (falling back to `.standard`).
///
/// - Per user: whether onboarding (the starter pack) is done, and the cached profile that lets a
///   signed-in launch go straight to the library while offline.
/// - Per device: whether the Library widget tip was dismissed.
///
/// Inject with `@Environment(AppPreferences.self)`.
@Observable
@MainActor
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the one-time "Put a quote on your Home Screen" tip was dismissed. Setting it persists.
    var widgetTipDismissed: Bool {
        didSet { defaults.set(widgetTipDismissed, forKey: Keys.widgetTipDismissed) }
    }

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        let store = defaults ?? .standard
        self.defaults = store
        widgetTipDismissed = store.bool(forKey: Keys.widgetTipDismissed)
    }

    // MARK: Onboarding

    /// Whether `userID` finished (or skipped) the starter pack on this device.
    func hasCompletedOnboarding(userID: UUID) -> Bool {
        defaults.bool(forKey: Keys.onboarding(userID))
    }

    /// Records that `userID` finished onboarding, so the starter pack shows only once.
    func setCompletedOnboarding(userID: UUID) {
        defaults.set(true, forKey: Keys.onboarding(userID))
    }

    // MARK: Cached profile

    /// The last profile loaded for `userID`, if any.
    func cachedProfile(userID: UUID) -> Profile? {
        guard let data = defaults.data(forKey: Keys.profile(userID)) else { return nil }
        guard let profile = try? QuotedJSON.makeDecoder().decode(Profile.self, from: data), profile.id == userID else {
            return nil
        }
        return profile
    }

    /// Caches `profile` for its user.
    func cacheProfile(_ profile: Profile) {
        guard let data = try? QuotedJSON.makeEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Keys.profile(profile.id))
    }

    // MARK: Wipe

    /// Removes everything stored for `userID` (sign-out keeps the onboarding flag; account deletion
    /// removes it too).
    func removeUserData(userID: UUID, includingOnboarding: Bool) {
        defaults.removeObject(forKey: Keys.profile(userID))
        if includingOnboarding {
            defaults.removeObject(forKey: Keys.onboarding(userID))
        }
    }

    private enum Keys {
        static let widgetTipDismissed = "quoted.widgetTipDismissed"
        static func onboarding(_ id: UUID) -> String { "quoted.onboardingComplete.\(id.uuidString.lowercased())" }
        static func profile(_ id: UUID) -> String { "quoted.profile.\(id.uuidString.lowercased())" }
    }
}
