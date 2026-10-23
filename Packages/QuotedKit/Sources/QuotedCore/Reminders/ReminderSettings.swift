import Foundation

/// The order the Rotation plays in.
public enum ReminderOrder: String, Codable, Hashable, Sendable, CaseIterable {
    /// Rotation order, top to bottom.
    case inOrder
    /// A fixed permutation derived from ``RotationState/seed``.
    case shuffle
}

/// Device-local reminder settings, stored in the App Group `UserDefaults`.
///
/// Times are minutes since local midnight (0...1439) with `windowStart < windowEnd`. Weekdays use
/// `Calendar` numbering: 1 is Sunday through 7 Saturday. Decoding tolerates missing keys so stored
/// settings survive new fields.
public struct ReminderSettings: Hashable, Sendable {
    /// Allowed reminders per day.
    public static let timesPerDayRange = 1...12
    /// Valid minute-of-day values.
    public static let minuteRange = 0...1439
    /// Valid weekday numbers.
    public static let weekdayRange = 1...7

    /// Whether local notifications are scheduled. The widget keeps rotating either way.
    public var enabled: Bool
    /// Reminders per day, 1...12.
    public var timesPerDay: Int
    /// First reminder of the day, in minutes since midnight.
    public var windowStart: Int
    /// Last reminder of the day, in minutes since midnight. Must be after `windowStart`.
    public var windowEnd: Int
    /// Enabled weekdays, 1 (Sunday) ... 7 (Saturday).
    public var weekdays: Set<Int>
    /// In order or shuffled.
    public var order: ReminderOrder

    /// 3 a day from 8:00 to 21:00, every day, in order.
    public static let `default` = ReminderSettings()

    public init(
        enabled: Bool = true,
        timesPerDay: Int = 3,
        windowStart: Int = 8 * 60,
        windowEnd: Int = 21 * 60,
        weekdays: Set<Int> = Set(1...7),
        order: ReminderOrder = .inOrder
    ) {
        self.enabled = enabled
        self.timesPerDay = timesPerDay
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.weekdays = weekdays
        self.order = order
    }

    /// Minutes since midnight for a wall-clock time.
    public static func minutes(hour: Int, minute: Int) -> Int { hour * 60 + minute }

    /// Whether every value is in range and the window is not empty.
    public var isValid: Bool {
        Self.timesPerDayRange.contains(timesPerDay)
            && Self.minuteRange.contains(windowStart)
            && Self.minuteRange.contains(windowEnd)
            && windowStart < windowEnd
            && weekdays.isSubset(of: Set(Self.weekdayRange))
    }

    /// A copy with every value forced into range: times per day clamped, window clamped (swapped if
    /// reversed, widened by a minute if empty), and unknown weekdays dropped.
    public var sanitized: ReminderSettings {
        var copy = self
        copy.timesPerDay = min(max(timesPerDay, Self.timesPerDayRange.lowerBound), Self.timesPerDayRange.upperBound)
        var start = min(max(windowStart, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        var end = min(max(windowEnd, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        if start > end { swap(&start, &end) }
        if start == end {
            if end < Self.minuteRange.upperBound { end += 1 } else { start -= 1 }
        }
        copy.windowStart = start
        copy.windowEnd = end
        copy.weekdays = weekdays.filter { Self.weekdayRange.contains($0) }
        return copy
    }

    /// The minute-of-day of each daily reminder, ascending and unique: `timesPerDay` values spread
    /// evenly from `windowStart` to `windowEnd` inclusive, rounded to the minute. One a day is at
    /// `windowStart`. Computed from ``sanitized``.
    public var dailyMinutes: [Int] {
        let settings = sanitized
        let count = settings.timesPerDay
        let start = settings.windowStart
        guard count > 1 else { return [start] }
        let span = settings.windowEnd - start
        let steps = count - 1
        var result: [Int] = []
        for index in 0..<count {
            // Round half up in integer arithmetic so every platform agrees.
            let minute = start + (2 * span * index + steps) / (2 * steps)
            if result.last != minute { result.append(minute) }
        }
        return result
    }

    /// Whether `other` plays the same cycle: the same daily times, weekdays and order. `enabled` does
    /// not count, because the widget keeps rotating while reminders are off.
    func playsSameCycle(as other: ReminderSettings) -> Bool {
        dailyMinutes == other.dailyMinutes
            && sanitized.weekdays == other.sanitized.weekdays
            && order == other.order
    }
}

extension ReminderSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, timesPerDay, windowStart, windowEnd, weekdays, order
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        timesPerDay = try container.decodeIfPresent(Int.self, forKey: .timesPerDay) ?? defaults.timesPerDay
        windowStart = try container.decodeIfPresent(Int.self, forKey: .windowStart) ?? defaults.windowStart
        windowEnd = try container.decodeIfPresent(Int.self, forKey: .windowEnd) ?? defaults.windowEnd
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? defaults.weekdays
        order = (try? container.decodeIfPresent(ReminderOrder.self, forKey: .order)) ?? defaults.order
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(timesPerDay, forKey: .timesPerDay)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encode(windowEnd, forKey: .windowEnd)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
        try container.encode(order, forKey: .order)
    }
}

/// The Rotation as the planner sees it: ordered quote IDs plus the anchor, seed and start index that
/// keep the cycle stable across replans.
///
/// The quote for a slot sits at cycle position `(ordinal + startIndex) mod count`, where `ordinal`
/// counts slots from `anchor`. In order, the position indexes `quoteIDs` directly; shuffled, it
/// indexes a ``SplitMix64`` permutation of `seed` first.
///
/// When the Rotation's members or order change, or the reminder schedule does,
/// ``updated(with:at:seed:settings:previousSettings:calendar:)`` keeps the anchor and moves
/// `startIndex`, so the cycle carries on after the quote it showed last instead of starting again at
/// the top or jumping. Save the result whenever the Rotation or the settings change.
public struct RotationState: Hashable, Sendable {
    /// Rotation quote IDs, in Rotation order.
    public var quoteIDs: [UUID]
    /// Slot ordinals are counted from here.
    public var anchor: Date
    /// Seeds the shuffle permutation.
    public var seed: UInt64
    /// The cycle position of ordinal 0 (any integer; it is reduced modulo the count). States saved
    /// before this field existed decode as 0.
    public var startIndex: Int

    public init(quoteIDs: [UUID], anchor: Date, seed: UInt64, startIndex: Int = 0) {
        self.quoteIDs = quoteIDs
        self.anchor = anchor
        self.seed = seed
        self.startIndex = startIndex
    }

    /// Whether the Rotation has no quotes.
    public var isEmpty: Bool { quoteIDs.isEmpty }

    /// A new state starting the cycle at `now` with a fresh random seed. Use it only when there is no
    /// saved state; otherwise use ``updated(with:at:seed:settings:previousSettings:calendar:)``.
    public static func starting(with quoteIDs: [UUID], at now: Date = Date(), seed: UInt64 = .random(in: .min ... .max)) -> RotationState {
        RotationState(quoteIDs: quoteIDs, anchor: now, seed: seed)
    }

    /// The state for the Rotation `quoteIDs` under `settings`, continuing this state's cycle, which ran
    /// under `previousSettings` (nil means `settings`). Returns `self` when `quoteIDs` is unchanged and
    /// so is the cycle the settings play (daily times, weekdays and order; `enabled` doesn't count).
    ///
    /// Otherwise the anchor is kept (moved to `now` only if it lies in the future), the shuffle seed
    /// becomes `seed` (or stays, when `quoteIDs` is unchanged), and `startIndex` is chosen so that the
    /// next slot after `now` plays:
    /// - the quote after the one shown last (the most recent slot's quote, under `previousSettings`)
    ///   in the new cycle, when a slot has passed since the anchor and that quote is still in the Rotation;
    /// - otherwise the first quote, in this state's cycle order, from the one shown last (exclusive)
    ///   or from the upcoming one (inclusive, when no slot has passed yet) that is still in the Rotation;
    /// - otherwise the first quote of the new cycle.
    ///
    /// The widget's "now" entry keeps showing the last quote where it is still in the Rotation, once
    /// a slot of the new schedule has passed since the anchor; before that it shows the upcoming one.
    public func updated(
        with quoteIDs: [UUID],
        at now: Date = Date(),
        seed: UInt64 = .random(in: .min ... .max),
        settings: ReminderSettings,
        previousSettings: ReminderSettings? = nil,
        calendar: Calendar = .current
    ) -> RotationState {
        let oldSettings = previousSettings ?? settings
        let unchanged = quoteIDs == self.quoteIDs
        if unchanged, oldSettings.playsSameCycle(as: settings) { return self }
        return ReminderPlanner.continuation(
            of: self, under: oldSettings, with: quoteIDs, at: now,
            seed: unchanged ? self.seed : seed, settings: settings, calendar: calendar
        )
    }

    /// The IDs of the quotes in the Rotation, ordered by `rotationPosition` (ties by creation date, then ID).
    public static func orderedQuoteIDs(in quotes: [Quote]) -> [UUID] {
        quotes
            .filter(\.isInRotation)
            .sorted { lhs, rhs in
                let left = lhs.rotationPosition ?? 0
                let right = rhs.rotationPosition ?? 0
                if left != right { return left < right }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(\.id)
    }
}

extension RotationState: Codable {
    enum CodingKeys: String, CodingKey {
        case quoteIDs, anchor, seed, startIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quoteIDs = try container.decode([UUID].self, forKey: .quoteIDs)
        anchor = try container.decode(Date.self, forKey: .anchor)
        seed = try container.decode(UInt64.self, forKey: .seed)
        startIndex = try container.decodeIfPresent(Int.self, forKey: .startIndex) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quoteIDs, forKey: .quoteIDs)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(seed, forKey: .seed)
        try container.encode(startIndex, forKey: .startIndex)
    }
}
