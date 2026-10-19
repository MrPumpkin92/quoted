import Foundation
import Observation
import OSLog
import QuotedCore
import UIKit

/// What the Library status card says about reminders.
struct ReminderStatusSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Reminders are on and allowed: "6 quotes in your reminders" / "3× daily · Next at 8:00 PM".
        case active
        /// The Reminders toggle is off.
        case remindersOff
        /// Notifications were never allowed (the user tapped "Not now" in onboarding).
        case needsPermission
        /// Notifications are off for Quoted in iOS Settings.
        case notificationsDenied
    }

    let kind: Kind
    let title: String
    let detail: String

    /// Whether the card shows its off state (`bell.slash`, "Turn on").
    var isOff: Bool { kind != .active }
    /// "Turn on" in the off states, else nil.
    var actionTitle: String? { isOff ? "Turn on" : nil }
}

/// One weekday chip in the Reminders settings.
struct WeekdayOption: Identifiable, Hashable, Sendable {
    /// `Calendar` weekday number: 1 is Sunday through 7 Saturday (as `ReminderSettings.weekdays`).
    let weekday: Int
    /// The chip letter ("M").
    let letter: String
    /// The full name for VoiceOver ("Monday").
    let name: String

    var id: Int { weekday }
}

/// Reminder settings, notification permission and the reminder coordinator.
///
/// `replan()` is the single path that keeps notifications and the widget in step with the library:
/// it refreshes the rotation state (when the reminder set or order changes, the cycle carries on after
/// the quote shown last instead of restarting at the top), runs `ReminderPlanner.plan`, replaces the
/// pending `reminder-` notifications, writes the widget snapshot and reloads the widget timelines. `LibraryStore` calls it after every mutation, setting
/// `settings` calls it, and `AppModel` calls it on launch, foreground and background refresh.
/// Inject with `@Environment(ReminderStore.self)`.
@Observable
@MainActor
final class ReminderStore {
    // MARK: State

    /// The reminder settings (App Group defaults). Setting them saves, sanitizes (times per day
    /// clamped to 1...12, a reversed window swapped) and replans. Bind controls straight to it:
    /// `$reminders.settings.timesPerDay`, `$reminders.settings.windowStartTime`.
    var settings: ReminderSettings {
        get { storedSettings }
        set {
            let sanitized = newValue.sanitized
            guard sanitized != storedSettings else { return }
            storedSettings = sanitized
            appGroup?.saveReminderSettings(sanitized)
            replan()
        }
    }

    /// Whether Quoted may notify. Refreshed by `refreshPermission()` and every replan.
    private(set) var permission: NotificationPermission = .notDetermined
    /// The next scheduled reminder, or nil when none is scheduled (off, not allowed, or no quotes).
    private(set) var nextReminderDate: Date?
    /// How many reminders are pending with iOS (at most 60).
    private(set) var scheduledCount = 0
    /// The rotation state the last plan used.
    private(set) var rotation: RotationState?

    private var storedSettings: ReminderSettings

    // MARK: Dependencies

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private let appGroup: AppGroupStore?
    @ObservationIgnored private let scheduler: NotificationScheduler
    @ObservationIgnored private let widgets: WidgetBridge
    @ObservationIgnored private let sideEffects: Bool
    @ObservationIgnored private var replanTask: Task<Void, Never>?
    @ObservationIgnored private var replanRequested = false

    init(appGroup: AppGroupStore?, scheduler: NotificationScheduler, widgets: WidgetBridge, sideEffects: Bool = true) {
        self.appGroup = appGroup
        self.scheduler = scheduler
        self.widgets = widgets
        self.sideEffects = sideEffects
        storedSettings = appGroup?.loadReminderSettings() ?? .default
        rotation = appGroup?.loadRotationState()
    }

    // MARK: Derived text

    /// The number of quotes in reminders.
    var quoteCount: Int { library?.reminderQuotes.count ?? 0 }

    /// The Library status card, or nil when no quote is in reminders (the card is hidden).
    var statusSummary: ReminderStatusSummary? {
        let count = quoteCount
        guard count > 0 else { return nil }
        let countLine = Self.quoteCountText(count)
        if !settings.enabled {
            return ReminderStatusSummary(kind: .remindersOff, title: "Reminders off", detail: countLine)
        }
        switch permission {
        case .denied:
            return ReminderStatusSummary(kind: .notificationsDenied, title: "Notifications off in Settings", detail: countLine)
        case .notDetermined:
            return ReminderStatusSummary(kind: .needsPermission, title: "Reminders off", detail: "Allow notifications to see \(count == 1 ? "it" : "them") through the day")
        case .authorized:
            var detail = "\(settings.timesPerDay)\u{00D7} daily"
            if let next = nextReminderDate {
                detail += " \u{00B7} \(Self.nextText(next))"
            }
            return ReminderStatusSummary(kind: .active, title: countLine, detail: detail)
        }
    }

    /// The subtitle under the Reminders toggle: "Every day · Next at 8:00 PM", or "Off".
    var scheduleSummary: String {
        guard settings.enabled else { return "Off" }
        if permission == .denied { return "Notifications are off for Quoted" }
        var text = daysDescription
        if let next = nextReminderDate {
            text += " \u{00B7} \(Self.nextText(next))"
        }
        return text
    }

    /// "3× a day" (the How often row).
    var frequencyText: String { "\(settings.timesPerDay)\u{00D7} a day" }

    /// "Every day", "Weekdays", "Weekends", "Mon, Wed, Fri" or "No days".
    var daysDescription: String { Self.daysDescription(settings.weekdays) }

    /// The seven day chips in the order of the user's calendar (Sunday or Monday first).
    static func weekdayOptions(calendar: Calendar = .current) -> [WeekdayOption] {
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let names = calendar.standaloneWeekdaySymbols
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return WeekdayOption(weekday: weekday, letter: letters[weekday - 1], name: names[weekday - 1])
        }
    }

    // MARK: Permission

    /// Reads the current notification permission (cheap; call on appear and foreground).
    func refreshPermission() async {
        guard sideEffects else { return }
        permission = await scheduler.permission()
    }

    /// Shows the system prompt if the user was never asked, then replans. Returns the permission.
    @discardableResult
    func requestAuthorization() async -> NotificationPermission {
        guard sideEffects else { return permission }
        permission = await scheduler.requestAuthorization()
        await replan().value
        return permission
    }

    /// The status card's "Turn on": turns the toggle on, asks for permission, or opens the app's
    /// notification settings in iOS Settings, whichever the current state needs.
    func turnOn() async {
        guard let summary = statusSummary else { return }
        switch summary.kind {
        case .active:
            return
        case .remindersOff:
            settings.enabled = true
            if permission == .notDetermined {
                await requestAuthorization()
            }
        case .needsPermission:
            await requestAuthorization()
        case .notificationsDenied:
            await Self.openNotificationSettings()
        }
    }

    /// Opens Quoted's notification settings in iOS Settings.
    static func openNotificationSettings() async {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }

    // MARK: Planning

    /// Replans reminders and the widget. Calls coalesce: a replan requested while one runs runs once
    /// more afterwards. Fire and forget, or `await reminders.replan().value` to wait.
    @discardableResult
    func replan() -> Task<Void, Never> {
        replanRequested = true
        if let running = replanTask { return running }
        let task = Task { [weak self] in
            while let self, self.replanRequested {
                self.replanRequested = false
                await self.performReplan()
            }
            self?.replanTask = nil
        }
        replanTask = task
        return task
    }

    /// Removes every pending and delivered reminder (sign-out, account deletion).
    func cancelAll() async {
        replanRequested = false
        await replanTask?.value
        nextReminderDate = nil
        scheduledCount = 0
        guard sideEffects else { return }
        await scheduler.cancelAll()
    }

    /// Forgets the rotation and the schedule after the session ends. Call it after the App Group is
    /// wiped. Reminder settings are per device: with `keepingSettings` (sign-out, session expiry) they
    /// are saved back to the App Group, so reminders resume as configured at the next sign-in; without
    /// it (account deletion) they return to the defaults.
    func reset(keepingSettings: Bool) {
        if keepingSettings {
            appGroup?.saveReminderSettings(storedSettings)
        } else {
            storedSettings = .default
        }
        rotation = nil
        nextReminderDate = nil
        scheduledCount = 0
    }

    private func performReplan() async {
        guard let library, library.hasLoaded else { return }
        let quotes = library.reminderQuotes
        let ids = quotes.map(\.id)
        let settings = self.settings
        let now = Date.now
        let previous = rotation ?? appGroup?.loadRotationState()
        // A changed set or order continues the cycle after the quote shown last (see RotationState).
        let next = previous.map { $0.updated(with: ids, at: now, settings: settings) } ?? RotationState.starting(with: ids, at: now)
        if next != previous {
            appGroup?.saveRotationState(next)
        }
        rotation = next

        guard sideEffects else {
            nextReminderDate = ReminderPlanner.plan(rotation: next, settings: settings, now: now, limit: 1).first?.date
            return
        }

        await widgets.write(WidgetSnapshot(library: quotes, settings: settings, rotation: next))
        permission = await scheduler.permission()
        let plans = permission == .authorized
            ? ReminderPlanner.plan(rotation: next, settings: settings, now: now)
            : []
        let lookup = Dictionary(quotes.map { ($0.id, NotificationQuote($0)) }, uniquingKeysWith: { first, _ in first })
        scheduledCount = await scheduler.reschedule(plans, quotes: lookup)
        nextReminderDate = plans.first?.date
        let pending = await scheduler.pendingCount()
        Logger.reminders.debug(
            "Replanned \(plans.count, privacy: .public) reminders for \(ids.count, privacy: .public) quotes; \(pending, privacy: .public) pending with iOS, next \(self.nextReminderDate?.formatted(.iso8601) ?? "none", privacy: .public)"
        )
    }

    // MARK: Formatting

    /// "1 quote in your reminders" / "6 quotes in your reminders".
    static func quoteCountText(_ count: Int) -> String {
        count == 1 ? "1 quote in your reminders" : "\(count) quotes in your reminders"
    }

    /// "Next at 8:00 PM" today, "Next tomorrow at 8:00 AM", or "Next Mon at 8:00 AM".
    static func nextText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Next at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Next tomorrow at \(time)"
        }
        return "Next \(date.formatted(.dateTime.weekday(.abbreviated))) at \(time)"
    }

    /// Describes a weekday set (1 = Sunday ... 7 = Saturday).
    static func daysDescription(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        let valid = weekdays.filter { (1...7).contains($0) }
        switch valid {
        case Set(1...7): return "Every day"
        case Set(2...6): return "Weekdays"
        case [1, 7]: return "Weekends"
        case []: return "No days"
        default:
            let symbols = calendar.shortStandaloneWeekdaySymbols
            return weekdayOptions(calendar: calendar)
                .filter { valid.contains($0.weekday) }
                .map { symbols[$0.weekday - 1] }
                .joined(separator: ", ")
        }
    }

    // MARK: Previews

    /// Seeds state for SwiftUI previews (no side effects).
    func seedPreview(permission: NotificationPermission) {
        self.permission = permission
        replan()
    }
}

extension ReminderSettings {
    /// `windowStart` as today's date at that time, for a `DatePicker(displayedComponents: .hourAndMinute)`.
    var windowStartTime: Date {
        get { Self.date(minutes: windowStart) }
        set { windowStart = Self.minutes(of: newValue) }
    }

    /// `windowEnd` as today's date at that time, for a `DatePicker(displayedComponents: .hourAndMinute)`.
    var windowEndTime: Date {
        get { Self.date(minutes: windowEnd) }
        set { windowEnd = Self.minutes(of: newValue) }
    }

    /// Whether `weekday` (1 = Sunday ... 7 = Saturday) is on.
    func isEnabled(weekday: Int) -> Bool { weekdays.contains(weekday) }

    /// Turns `weekday` (1 = Sunday ... 7 = Saturday) on or off.
    mutating func toggle(weekday: Int) {
        if weekdays.contains(weekday) {
            weekdays.remove(weekday)
        } else {
            weekdays.insert(weekday)
        }
    }

    /// Today at `minutes` past midnight in `calendar`.
    static func date(minutes: Int, calendar: Calendar = .current, now: Date = .now) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) ?? start
    }

    /// Minutes past midnight of `date` in `calendar`.
    static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
