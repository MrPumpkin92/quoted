import Foundation
import OSLog
import QuotedCore
import UserNotifications

/// Whether Quoted may show notifications.
enum NotificationPermission: Equatable, Sendable {
    /// The user has not been asked yet.
    case notDetermined
    /// Denied in the prompt or turned off in Settings.
    case denied
    /// Allowed (including provisional and ephemeral).
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .denied
        }
    }
}

/// The plain-text parts of a quote a notification needs.
struct NotificationQuote: Hashable, Sendable {
    let id: UUID
    let body: String
    let author: String?

    init(id: UUID, body: String, author: String?) {
        self.id = id
        self.body = body
        self.author = author
    }

    init(_ quote: Quote) {
        self.init(id: quote.id, body: quote.body, author: quote.author)
    }
}

/// Local reminder notifications through `UNUserNotificationCenter`.
///
/// Only requests whose identifier starts with `reminder-` belong to Quoted's reminders; `reschedule`
/// replaces exactly those. The body is `“body” — Author` in plain text (notifications cannot render
/// runs), with no title, so iOS shows "Quoted". `threadIdentifier` is `reminders` and `userInfo`
/// carries `quoteID` (a UUID string) for the tap.
struct NotificationScheduler: Sendable {
    static let identifierPrefix = "reminder-"
    static let threadIdentifier = "reminders"
    static let quoteIDKey = "quoteID"

    /// The current permission.
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationPermission(settings.authorizationStatus)
    }

    /// Shows the system prompt (only the first time) and returns the resulting permission.
    func requestAuthorization() async -> NotificationPermission {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Logger.reminders.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await permission()
    }

    /// Replaces every pending reminder with `plans`. Plans whose quote is missing are skipped.
    /// Returns the number of requests scheduled.
    @discardableResult
    func reschedule(_ plans: [PlannedReminder], quotes: [UUID: NotificationQuote], calendar: Calendar = .current) async -> Int {
        let center = UNUserNotificationCenter.current()
        await removePendingReminders(in: center)
        var scheduled = 0
        for plan in plans {
            guard let quote = quotes[plan.quoteID] else { continue }
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.identifier(for: plan),
                content: Self.content(for: quote),
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                Logger.reminders.error("Scheduling a reminder failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return scheduled
    }

    /// Removes every pending reminder and every delivered reminder (sign-out, account deletion).
    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        await removePendingReminders(in: center)
        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    /// The number of reminders iOS still holds.
    func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .count
    }

    // MARK: Content

    /// `reminder-<unix seconds>`: unique per slot.
    static func identifier(for plan: PlannedReminder) -> String {
        "\(identifierPrefix)\(Int(plan.date.timeIntervalSince1970))"
    }

    /// `“body” — Author`, or `“body”` without an author.
    static func bodyText(for quote: NotificationQuote) -> String {
        let body = "\u{201C}\(RichText.collapseWhitespace(quote.body))\u{201D}"
        guard let author = quote.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else {
            return body
        }
        return "\(body) \u{2014} \(author)"
    }

    static func content(for quote: NotificationQuote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = bodyText(for: quote)
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = [quoteIDKey: quote.id.uuidString]
        return content
    }

    /// The deep link a tapped reminder opens (`quoted://quote/<id>`), or nil.
    static func deepLink(fromUserInfo userInfo: [AnyHashable: Any]) -> DeepLink? {
        guard let raw = userInfo[quoteIDKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        return .quote(id)
    }

    // MARK: Private

    private func removePendingReminders(in center: UNUserNotificationCenter) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Shows reminders as banners while the app is open and routes taps to the quote.
///
/// Set as `UNUserNotificationCenter.current().delegate` at launch (QuotedApp). The center holds its
/// delegate weakly, so `AppModel` keeps this object alive.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (DeepLink) -> Void

    /// - Parameter open: Called on the main actor with `quoted://quote/<id>` when a reminder is tapped.
    init(open: @escaping @MainActor @Sendable (DeepLink) -> Void) {
        self.open = open
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = NotificationScheduler.deepLink(fromUserInfo: response.notification.request.content.userInfo)
        else { return }
        await open(link)
    }
}
