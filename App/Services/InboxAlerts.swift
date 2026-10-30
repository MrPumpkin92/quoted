import Foundation
import OSLog
import UserNotifications

/// What is left of the inbox alerts and the app icon badge (docs/ui-spec.md, Badges).
///
/// Builds before the social redesign posted one best-effort alert from background refresh for new
/// quotes from friends and friend requests (thread ``threadIdentifier``, identifiers starting
/// ``identifierPrefix``) and badged the app icon. This build posts none: the Inbox tab's badge is the
/// only signal, and the app icon is never badged. It clears the icon badge when the main tabs appear,
/// on every return to the foreground and at sign-out; removes the old alerts still in Notification
/// Center on the first launch of this build; and a tap on an old alert opens `quoted://inbox`
/// (`NotificationDelegate`).
enum InboxAlerts {
    static let identifierPrefix = "inbox-"
    static let threadIdentifier = "inbox"
    /// Where earlier builds kept the requests and quotes an alert already covered.
    static let legacyAlertedKey = "quoted.inboxAlertedIDs"
    /// Set once this build has removed the old alerts.
    static let retiredKey = "quoted.inboxAlertsRetired"

    /// Whether a delivered notification is an inbox alert from an earlier build.
    static func isInboxAlert(identifier: String, threadIdentifier: String) -> Bool {
        threadIdentifier == Self.threadIdentifier || identifier.hasPrefix(identifierPrefix)
    }

    /// Clears the app icon badge, which earlier builds set and this one never does.
    static func clearAppIconBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        } catch {
            Logger.social.debug("Clearing the badge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// On the first launch of this build: removes the inbox alerts earlier builds left in
    /// Notification Center and forgets what they covered. Later launches do nothing.
    static func retireDeliveredAlerts(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: retiredKey) else { return }
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .filter { isInboxAlert(identifier: $0.request.identifier, threadIdentifier: $0.request.content.threadIdentifier) }
            .map(\.request.identifier)
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
            Logger.social.info("Removed \(ids.count, privacy: .public) inbox alerts from an earlier build")
        }
        defaults.removeObject(forKey: legacyAlertedKey)
        defaults.set(true, forKey: retiredKey)
    }

    /// Clears the app icon badge and what earlier alerts covered (sign-out, account deletion).
    static func reset(defaults: UserDefaults = .standard) async {
        defaults.removeObject(forKey: legacyAlertedKey)
        await clearAppIconBadge()
    }
}
