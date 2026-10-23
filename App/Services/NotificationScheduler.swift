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
/// replaces exactly those. The subtitle is the author and the body is `“body”` in plain text with its
/// line breaks (notifications cannot render runs), with no title, so iOS shows "Quoted".
/// `threadIdentifier` is `reminders` and `userInfo` carries `quoteID` (a UUID string) for the tap.
struct NotificationScheduler: Sendable {
    static let identifierPrefix = "reminder-"
    static let threadIdentifier = "reminders"
    static let quoteIDKey = "quoteID"
    /// `userInfo` key of the nudge, whose value is `rotation` (opens Reminders).
    static let linkKey = "link"
    /// The nudge after the last planned reminder (it shares the prefix, so it is replaced and
    /// cancelled with the reminders).
    static let nudgeIdentifier = "\(identifierPrefix)nudge"
    static let nudgeText = "Open Quoted to keep your reminders coming."
    /// How long after the last planned reminder the nudge comes.
    static let nudgeDelay: TimeInterval = 24 * 60 * 60

    /// The current permission.
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationPermission(settings.authorizationStatus)
    }

    /// Shows the system prompt (only the first time) and returns the resulting permission.
    func requestAuthorization() async -> NotificationPermission {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Logger.reminders.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await permission()
    }

    /// Replaces every pending reminder with `plans`. Plans whose quote is missing are skipped.
    /// Returns the number of quote reminders scheduled.
    ///
    /// New requests are added first (an identifier is per slot, so a request for the same slot
    /// replaces the pending one), then only the pending reminders not in the new set are removed:
    /// if iOS suspends the app part-way, the old schedule is still there rather than none.
    ///
    /// The queue holds a limited number of reminders and refills only when the app runs, so one
    /// more notification (``nudgeText``) comes ``nudgeDelay`` after the last planned reminder and
    /// opens Reminders.
    @discardableResult
    func reschedule(_ plans: [PlannedReminder], quotes: [UUID: NotificationQuote], calendar: Calendar = .current) async -> Int {
        let center = UNUserNotificationCenter.current()
        var kept = Set<String>()
        var scheduled = 0
        for plan in plans {
            guard let quote = quotes[plan.quoteID] else { continue }
            let request = UNNotificationRequest(
                identifier: Self.identifier(for: plan),
                content: Self.content(for: quote),
                trigger: Self.trigger(at: plan.date, calendar: calendar)
            )
            do {
                try await center.add(request)
                kept.insert(request.identifier)
                scheduled += 1
            } catch {
                Logger.reminders.error("Scheduling a reminder failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if scheduled > 0, let last = plans.last {
            let nudge = UNNotificationRequest(
                identifier: Self.nudgeIdentifier,
                content: Self.nudgeContent(),
                trigger: Self.trigger(at: last.date.addingTimeInterval(Self.nudgeDelay), calendar: calendar)
            )
            do {
                try await center.add(nudge)
                kept.insert(nudge.identifier)
            } catch {
                Logger.reminders.error("Scheduling the reminders nudge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await removePendingReminders(in: center, keeping: kept)
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

    /// `“body”` with the quote's line breaks kept (each line tidied), so a poem keeps its shape.
    static func bodyText(for quote: NotificationQuote) -> String {
        "\u{201C}\(RichText.collapseWhitespaceKeepingLines(quote.body))\u{201D}"
    }

    /// The author, or nil without one. It is the subtitle, so a long quote can't push it out of view.
    static func subtitleText(for quote: NotificationQuote) -> String? {
        let author = RichText.collapseWhitespace(quote.author ?? "")
        return author.isEmpty ? nil : author
    }

    static func trigger(at date: Date, calendar: Calendar) -> UNCalendarNotificationTrigger {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    /// "Open Quoted to keep your reminders coming." with no quote text; a tap opens Reminders.
    static func nudgeContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = nudgeText
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = [linkKey: "rotation"]
        return content
    }

    static func content(for quote: NotificationQuote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.subtitle = subtitleText(for: quote) ?? ""
        content.body = bodyText(for: quote)
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = [quoteIDKey: quote.id.uuidString]
        return content
    }

    /// The deep link a tapped reminder opens (`quoted://quote/<id>`, or Reminders for the nudge), or
    /// nil.
    static func deepLink(fromUserInfo userInfo: [AnyHashable: Any]) -> DeepLink? {
        if userInfo[linkKey] as? String == "rotation" { return .rotation }
        guard let raw = userInfo[quoteIDKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        return .quote(id)
    }

    // MARK: Private

    private func removePendingReminders(in center: UNUserNotificationCenter, keeping kept: Set<String> = []) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !kept.contains($0) }
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
