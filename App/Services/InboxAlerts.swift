import Foundation
import OSLog
import QuotedCore
import UserNotifications

/// Best-effort alerts for new shares and friend requests, and the app icon badge. There is no push:
/// background refresh (`AppModel.performBackgroundRefresh`) posts at most one alert when it finds
/// items no earlier alert covered, so they can arrive late or not at all.
///
/// Alerts never show quote text. A friend request never names its sender, so a stranger's name
/// doesn't reach the Lock Screen; a share names the friend who sent it. Delivered at once, they
/// use none of the pending-request slots the reminders need.
struct InboxAlerts: Sendable {
    /// Requests and shares an alert already covered, so each item alerts once.
    static let alertedKey = "quoted.inboxAlertedIDs"
    /// IDs kept in ``alertedKey`` (the newest ones).
    static let alertedLimit = 500
    static let identifierPrefix = "inbox-"
    static let threadIdentifier = "inbox"

    /// Posts one alert for the shares and requests no earlier alert covered, when notifications are
    /// allowed. Returns whether it posted.
    @discardableResult
    func alertNew(
        shares: [SharedQuote],
        requests: [Connection],
        permission: NotificationPermission,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        let (newShares, newRequests) = Self.uncovered(shares: shares, requests: requests, defaults: defaults)
        guard !newShares.isEmpty || !newRequests.isEmpty else { return false }
        // Covered even without permission: allowing notifications later must not replay old items.
        Self.cover(shares: newShares, requests: newRequests, defaults: defaults)
        guard permission == .authorized else { return false }

        let content = UNMutableNotificationContent()
        content.body = Self.text(shares: newShares, requests: newRequests.count)
        content.sound = .default
        content.threadIdentifier = Self.threadIdentifier
        let request = UNNotificationRequest(
            identifier: "\(Self.identifierPrefix)\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            Logger.social.error("Posting the inbox alert failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Marks items as covered without alerting: the user saw them in the app (foreground refresh).
    func markSeenInApp(shares: [SharedQuote], requests: [Connection], defaults: UserDefaults = .standard) {
        let (newShares, newRequests) = Self.uncovered(shares: shares, requests: requests, defaults: defaults)
        Self.cover(shares: newShares, requests: newRequests, defaults: defaults)
    }

    private static func uncovered(
        shares: [SharedQuote],
        requests: [Connection],
        defaults: UserDefaults
    ) -> ([SharedQuote], [Connection]) {
        let alerted = Set(defaults.stringArray(forKey: alertedKey) ?? [])
        return (
            shares.filter { !alerted.contains($0.id.uuidString) },
            requests.filter { !alerted.contains($0.id.uuidString) }
        )
    }

    private static func cover(shares: [SharedQuote], requests: [Connection], defaults: UserDefaults) {
        let ids = (shares.map(\.id) + requests.map(\.id)).map(\.uuidString)
        guard !ids.isEmpty else { return }
        let previous = defaults.stringArray(forKey: alertedKey) ?? []
        defaults.set(Array((previous + ids).suffix(alertedLimit)), forKey: alertedKey)
    }

    /// Sets the app icon badge (shown only if the user allowed badges).
    static func setBadge(_ count: Int) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
        } catch {
            Logger.social.debug("Setting the badge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears the badge and what earlier alerts covered (sign-out, account deletion).
    static func reset(defaults: UserDefaults = .standard) async {
        defaults.removeObject(forKey: alertedKey)
        await setBadge(0)
    }

    /// "Maya sent you a quote." / "You have 3 new quotes from friends." plus "You have a new friend
    /// request." / "You have 2 new friend requests."
    static func text(shares: [SharedQuote], requests: Int) -> String {
        var parts: [String] = []
        let senders = Set(shares.map(\.senderID))
        if shares.count == 1 || senders.count == 1, let first = shares.first {
            let name = first.sender.map { Self.firstName($0.displayName) } ?? "A friend"
            parts.append(shares.count == 1 ? "\(name) sent you a quote." : "\(name) sent you \(shares.count) quotes.")
        } else if !shares.isEmpty {
            parts.append("You have \(shares.count) new quotes from friends.")
        }
        if requests == 1 {
            parts.append("You have a new friend request.")
        } else if requests > 1 {
            parts.append("You have \(requests) new friend requests.")
        }
        return parts.joined(separator: " ")
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
