import Foundation

/// One planned local notification (or widget timeline entry): when, which quote, and the slot's
/// ordinal counted from the rotation anchor (handy for stable notification identifiers).
public struct PlannedReminder: Codable, Hashable, Sendable {
    public var date: Date
    public var quoteID: UUID
    public var ordinal: Int

    public init(date: Date, quoteID: UUID, ordinal: Int) {
        self.date = date
        self.quoteID = quoteID
        self.ordinal = ordinal
    }
}

/// Pure, deterministic reminder planning shared by the app (notifications) and the widget (timeline).
///
/// - Slots: on each enabled weekday, ``ReminderSettings/dailyMinutes`` wall-clock times built from
///   date components in `calendar`'s time zone, so they stay put across DST changes. A time that does
///   not exist (inside a spring-forward gap) resolves the way `Calendar.date(from:)` does, moving later.
/// - Quote for a slot: the slot's ordinal (the number of slots from `anchor` up to it) plus
///   ``RotationState/startIndex``, modulo the Rotation size, mapped through a ``SplitMix64``
///   permutation of `seed` when shuffling.
/// - Plans never exceed ``maxPendingReminders``.
public enum ReminderPlanner {
    /// iOS keeps at most 64 pending requests per app; 4 are left as headroom.
    public static let maxPendingReminders = 60

    /// The next reminder times strictly after `now`, at most `limit` (capped at 60).
    /// Empty when reminders are disabled or no weekday is enabled.
    public static func slots(
        for settings: ReminderSettings,
        after now: Date,
        calendar: Calendar = .current,
        limit: Int = maxPendingReminders
    ) -> [Date] {
        guard settings.enabled else { return [] }
        return Schedule(settings: settings, calendar: calendar)
            .slots(after: now, limit: min(max(0, limit), maxPendingReminders))
    }

    /// The upcoming reminders with their quotes. Empty when reminders are disabled or the Rotation is empty.
    /// Replanning later with the same anchor and seed continues the same cycle.
    public static func plan(
        rotation: RotationState,
        settings: ReminderSettings,
        now: Date,
        calendar: Calendar = .current,
        limit: Int = maxPendingReminders
    ) -> [PlannedReminder] {
        guard settings.enabled, !rotation.quoteIDs.isEmpty else { return [] }
        let schedule = Schedule(settings: settings, calendar: calendar)
        let dates = schedule.slots(after: now, limit: min(max(0, limit), maxPendingReminders))
        guard let first = dates.first else { return [] }
        let base = schedule.ordinal(of: first, anchor: rotation.anchor)
        let mapper = QuoteMapper(rotation: rotation, order: settings.order)
        return dates.enumerated().map { offset, date in
            let ordinal = base + offset
            return PlannedReminder(date: date, quoteID: mapper.quoteID(forOrdinal: ordinal), ordinal: ordinal)
        }
    }

    /// The quote of the most recent slot at or before `date`, or the first slot's quote when no slot
    /// has happened since the anchor. Uses the schedule even when reminders are disabled, so the
    /// widget keeps rotating. Nil only for an empty Rotation.
    public static func currentQuoteID(
        rotation: RotationState,
        settings: ReminderSettings,
        at date: Date,
        calendar: Calendar = .current
    ) -> UUID? {
        currentEntry(rotation: rotation, settings: settings, at: date, calendar: calendar)?.quoteID
    }

    /// A widget timeline: an entry at `now` showing ``currentQuoteID(rotation:settings:at:calendar:)``,
    /// then one entry per slot in `(now, now + horizon]`. Uses the schedule even when reminders are
    /// disabled. At most 60 slot entries follow the first. Empty only for an empty Rotation.
    public static func timeline(
        rotation: RotationState,
        settings: ReminderSettings,
        now: Date,
        calendar: Calendar = .current,
        horizon: TimeInterval = 24 * 60 * 60
    ) -> [PlannedReminder] {
        guard let current = currentEntry(rotation: rotation, settings: settings, at: now, calendar: calendar) else {
            return []
        }
        let schedule = Schedule(settings: settings, calendar: calendar)
        let end = now.addingTimeInterval(max(0, horizon))
        let upcoming = schedule.slots(after: now, limit: maxPendingReminders).filter { $0 <= end }
        let mapper = QuoteMapper(rotation: rotation, order: settings.order)
        var entries = [current]
        if let first = upcoming.first {
            let base = schedule.ordinal(of: first, anchor: rotation.anchor)
            for (offset, date) in upcoming.enumerated() {
                let ordinal = base + offset
                entries.append(PlannedReminder(date: date, quoteID: mapper.quoteID(forOrdinal: ordinal), ordinal: ordinal))
            }
        }
        return entries
    }

    /// The quote for a slot ordinal (negative ordinals count back from the anchor).
    public static func quoteID(forOrdinal ordinal: Int, rotation: RotationState, order: ReminderOrder) -> UUID? {
        guard !rotation.quoteIDs.isEmpty else { return nil }
        return QuoteMapper(rotation: rotation, order: order).quoteID(forOrdinal: ordinal)
    }

    private static func currentEntry(
        rotation: RotationState,
        settings: ReminderSettings,
        at date: Date,
        calendar: Calendar
    ) -> PlannedReminder? {
        guard !rotation.quoteIDs.isEmpty else { return nil }
        let schedule = Schedule(settings: settings, calendar: calendar)
        let passed = date < rotation.anchor ? 0 : schedule.count(from: rotation.anchor, to: date, includingEnd: true)
        let ordinal = max(0, passed - 1)
        let mapper = QuoteMapper(rotation: rotation, order: settings.order)
        return PlannedReminder(date: date, quoteID: mapper.quoteID(forOrdinal: ordinal), ordinal: ordinal)
    }
}

extension ReminderPlanner {
    /// The state behind ``RotationState/updated(with:at:seed:settings:previousSettings:calendar:)``:
    /// the Rotation `quoteIDs` under `settings`, continuing `old`'s cycle, which ran under `oldSettings`.
    static func continuation(
        of old: RotationState,
        under oldSettings: ReminderSettings,
        with quoteIDs: [UUID],
        at now: Date,
        seed: UInt64,
        settings: ReminderSettings,
        calendar: Calendar
    ) -> RotationState {
        // A future anchor (the clock went back) would give negative ordinals; count from now instead.
        let anchor = old.anchor <= now ? old.anchor : now
        var state = RotationState(quoteIDs: quoteIDs, anchor: anchor, seed: seed)
        guard !quoteIDs.isEmpty else { return state }

        let newMapper = QuoteMapper(rotation: state, order: settings.order)
        let nextPosition = old.quoteIDs.isEmpty
            ? 0
            : nextCyclePosition(after: old, under: oldSettings, in: newMapper, at: now, calendar: calendar)
        // Every slot of the new schedule from the anchor up to `now` is behind us, so the next slot's
        // ordinal is their count.
        let passed = Schedule(settings: settings, calendar: calendar).count(from: anchor, to: now, includingEnd: true)
        state.startIndex = QuoteMapper.modulo(nextPosition - passed, quoteIDs.count)
        return state
    }

    /// The position in `newMapper`'s cycle that the next slot should play when `old`, which ran under
    /// `oldSettings`, is replaced.
    private static func nextCyclePosition(
        after old: RotationState,
        under oldSettings: ReminderSettings,
        in newMapper: QuoteMapper,
        at now: Date,
        calendar: Calendar
    ) -> Int {
        let oldMapper = QuoteMapper(rotation: old, order: oldSettings.order)
        let schedule = Schedule(settings: oldSettings, calendar: calendar)
        let passed = now < old.anchor ? 0 : schedule.count(from: old.anchor, to: now, includingEnd: true)
        // The quote on screen: the most recent slot's, or the upcoming one before any slot has passed.
        let currentPosition = oldMapper.position(forOrdinal: max(0, passed - 1))
        let delivered = passed > 0

        var newIndices: [UUID: Int] = [:]
        for (index, id) in newMapper.ids.enumerated() where newIndices[id] == nil {
            newIndices[id] = index
        }
        if delivered, let index = newIndices[oldMapper.quoteID(atPosition: currentPosition)] {
            return newMapper.position(ofIndex: index) + 1
        }
        // The current quote left the Rotation (or has not played yet): continue with the first quote
        // still in the Rotation, walking the old cycle from there.
        let start = delivered ? currentPosition + 1 : currentPosition
        for step in 0..<oldMapper.ids.count {
            if let index = newIndices[oldMapper.quoteID(atPosition: start + step)] {
                return newMapper.position(ofIndex: index)
            }
        }
        return 0
    }
}

/// Maps slot ordinals to cycle positions, and cycle positions to quote IDs.
private struct QuoteMapper {
    let ids: [UUID]
    let permutation: [Int]?
    let startIndex: Int

    init(rotation: RotationState, order: ReminderOrder) {
        ids = rotation.quoteIDs
        permutation = order == .shuffle ? SplitMix64.permutation(count: ids.count, seed: rotation.seed) : nil
        startIndex = rotation.startIndex
    }

    /// `value` modulo `count`, in `0..<count`.
    static func modulo(_ value: Int, _ count: Int) -> Int {
        ((value % count) + count) % count
    }

    /// The cycle position of a slot ordinal. Reduces both terms first, so no value can overflow.
    func position(forOrdinal ordinal: Int) -> Int {
        let count = ids.count
        return Self.modulo(ordinal % count + startIndex % count, count)
    }

    /// The quote at a cycle position (any integer, taken modulo the count).
    func quoteID(atPosition position: Int) -> UUID {
        let wrapped = Self.modulo(position, ids.count)
        return ids[permutation?[wrapped] ?? wrapped]
    }

    /// The cycle position that plays `ids[index]`.
    func position(ofIndex index: Int) -> Int {
        guard let permutation else { return index }
        return permutation.firstIndex(of: index) ?? index
    }

    func quoteID(forOrdinal ordinal: Int) -> UUID {
        quoteID(atPosition: position(forOrdinal: ordinal))
    }
}

/// The wall-clock slot grid, ignoring `enabled`.
private struct Schedule {
    let minutes: [Int]
    let weekdays: Set<Int>
    let calendar: Calendar

    init(settings: ReminderSettings, calendar: Calendar) {
        let sanitized = settings.sanitized
        minutes = sanitized.dailyMinutes
        weekdays = sanitized.weekdays
        self.calendar = calendar
    }

    var isEmpty: Bool { minutes.isEmpty || weekdays.isEmpty }

    /// Slot dates on the day that starts at `dayStart`, in slot order (never decreasing).
    func dates(onDayStarting dayStart: Date) -> [Date] {
        let day = calendar.dateComponents([.era, .year, .month, .day, .weekday], from: dayStart)
        guard let weekday = day.weekday, weekdays.contains(weekday) else { return [] }
        var result: [Date] = []
        result.reserveCapacity(minutes.count)
        for minute in minutes {
            var components = DateComponents()
            components.era = day.era
            components.year = day.year
            components.month = day.month
            components.day = day.day
            components.hour = minute / 60
            components.minute = minute % 60
            components.second = 0
            var date = calendar.date(from: components) ?? dayStart.addingTimeInterval(TimeInterval(minute * 60))
            if let last = result.last, date < last { date = last }
            result.append(date)
        }
        return result
    }

    func startOfNextDay(after dayStart: Date) -> Date? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return calendar.startOfDay(for: next)
    }

    /// Up to `limit` slots strictly after `now`.
    func slots(after now: Date, limit: Int) -> [Date] {
        guard limit > 0, !isEmpty else { return [] }
        var result: [Date] = []
        var day = calendar.startOfDay(for: now)
        // At least one weekday is enabled, so `limit` slots fit in `limit` weeks (plus today).
        for _ in 0..<(limit * 7 + 8) {
            for date in dates(onDayStarting: day) where date > now {
                result.append(date)
                if result.count == limit { return result }
            }
            guard let next = startOfNextDay(after: day) else { break }
            day = next
        }
        return result
    }

    /// The signed ordinal of `slot` relative to `anchor`.
    func ordinal(of slot: Date, anchor: Date) -> Int {
        slot >= anchor ? count(from: anchor, to: slot, includingEnd: false) : -count(from: slot, to: anchor, includingEnd: false)
    }

    /// The number of slots `s` with `start <= s < end` (or `<= end` when `includingEnd`).
    func count(from start: Date, to end: Date, includingEnd: Bool) -> Int {
        guard !isEmpty, end >= start else { return 0 }
        func inRange(_ date: Date) -> Bool { date >= start && (includingEnd ? date <= end : date < end) }

        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        if firstDay == lastDay {
            return dates(onDayStarting: firstDay).filter(inRange).count
        }
        var total = dates(onDayStarting: firstDay).filter(inRange).count
            + dates(onDayStarting: lastDay).filter(inRange).count

        // Whole days strictly between. Compare at noon, which exists on every day in every zone.
        guard
            let firstNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: firstDay),
            let lastNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: lastDay),
            let dayDistance = calendar.dateComponents([.day], from: firstNoon, to: lastNoon).day
        else { return total }
        let between = dayDistance - 1
        guard between > 0 else { return total }

        let firstWeekday = calendar.component(.weekday, from: firstDay)
        var enabledDays = (between / 7) * weekdays.count
        let remainder = between % 7
        if remainder > 0 {
            for offset in 1...remainder where weekdays.contains((firstWeekday - 1 + offset) % 7 + 1) {
                enabledDays += 1
            }
        }
        total += enabledDays * minutes.count
        return total
    }
}
