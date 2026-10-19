import Foundation
import Testing
@testable import QuotedCore

@Suite("ReminderSettings and RotationState")
struct ReminderSettingsTests {
    @Test func defaults() {
        let settings = ReminderSettings.default
        #expect(settings.enabled)
        #expect(settings.timesPerDay == 3)
        #expect(settings.windowStart == 8 * 60)
        #expect(settings.windowEnd == 21 * 60)
        #expect(settings.weekdays == Set(1...7))
        #expect(settings.order == .inOrder)
        #expect(settings.isValid)
        #expect(ReminderSettings.minutes(hour: 14, minute: 30) == 870)
    }

    @Test func dailyMinutesSpreadEvenlyAndInclusive() {
        #expect(ReminderSettings().dailyMinutes == [480, 870, 1260])
        #expect(ReminderSettings(timesPerDay: 1).dailyMinutes == [480])
        #expect(ReminderSettings(timesPerDay: 2).dailyMinutes == [480, 1260])
        let twelve = ReminderSettings(timesPerDay: 12).dailyMinutes
        #expect(twelve.count == 12)
        #expect(twelve.first == 480 && twelve.last == 1260)
        let gaps = zip(twelve.dropFirst(), twelve).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 == 70 || $0 == 71 })
        // A window narrower than the count collapses duplicate minutes.
        #expect(ReminderSettings(timesPerDay: 12, windowStart: 600, windowEnd: 602).dailyMinutes == [600, 601, 602])
    }

    @Test func sanitizedForcesValuesIntoRange() {
        #expect(ReminderSettings(timesPerDay: 0).sanitized.timesPerDay == 1)
        #expect(ReminderSettings(timesPerDay: 99).sanitized.timesPerDay == 12)
        let reversed = ReminderSettings(windowStart: 1260, windowEnd: 480).sanitized
        #expect(reversed.windowStart == 480 && reversed.windowEnd == 1260)
        let empty = ReminderSettings(windowStart: 600, windowEnd: 600).sanitized
        #expect(empty.windowStart == 600 && empty.windowEnd == 601)
        let late = ReminderSettings(windowStart: 5000, windowEnd: 9000).sanitized
        #expect(late.windowStart == 1438 && late.windowEnd == 1439)
        let early = ReminderSettings(windowStart: -50, windowEnd: 30).sanitized
        #expect(early.windowStart == 0 && early.windowEnd == 30)
        #expect(ReminderSettings(weekdays: [0, 3, 8]).sanitized.weekdays == [3])
        for settings in [reversed, empty, late, early] { #expect(settings.isValid) }
        #expect(!ReminderSettings(timesPerDay: 13).isValid)
        #expect(!ReminderSettings(windowStart: 600, windowEnd: 600).isValid)
        #expect(!ReminderSettings(weekdays: [0]).isValid)
    }

    @Test func codableToleratesMissingKeysAndSortsWeekdays() throws {
        #expect(try Fixture.decode(ReminderSettings.self, "{}") == .default)
        let partial = try Fixture.decode(ReminderSettings.self, #"{"timesPerDay":5,"order":"sideways"}"#)
        #expect(partial.timesPerDay == 5 && partial.order == .inOrder && partial.windowEnd == 1260)
        let settings = ReminderSettings(enabled: false, timesPerDay: 4, windowStart: 420, windowEnd: 1320, weekdays: [7, 1, 3], order: .shuffle)
        #expect(try Fixture.jsonString(settings)
            == #"{"enabled":false,"order":"shuffle","timesPerDay":4,"weekdays":[1,3,7],"windowEnd":1320,"windowStart":420}"#)
        let data = try QuotedJSON.makeEncoder().encode(settings)
        #expect(try QuotedJSON.makeDecoder().decode(ReminderSettings.self, from: data) == settings)
    }

    @Test func rotationOrderFollowsPositions() {
        let base = Date(timeIntervalSince1970: 1_000)
        let quotes = [
            Quote(id: Fixture.id(1), body: "a", rotationPosition: 2, createdAt: base),
            Quote(id: Fixture.id(2), body: "b", rotationPosition: nil, createdAt: base),
            Quote(id: Fixture.id(3), body: "c", rotationPosition: 0, createdAt: base),
            Quote(id: Fixture.id(4), body: "d", rotationPosition: 1, createdAt: base.addingTimeInterval(5)),
            Quote(id: Fixture.id(5), body: "e", rotationPosition: 1, createdAt: base),
        ]
        #expect(RotationState.orderedQuoteIDs(in: quotes) == [Fixture.id(3), Fixture.id(5), Fixture.id(4), Fixture.id(1)])
    }

    @Test func rotationStateCodableKeepsStartIndexAndToleratesOldJSON() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(RotationState.starting(with: [], at: start).isEmpty)
        #expect(RotationState.starting(with: Fixture.ids(2), at: start, seed: 1).startIndex == 0)

        let big = RotationState(quoteIDs: Fixture.ids(2), anchor: start, seed: .max, startIndex: 7)
        let data = try QuotedJSON.makeEncoder().encode(big)
        #expect(try QuotedJSON.makeDecoder().decode(RotationState.self, from: data) == big)

        // App Group and widget-snapshot JSON written before `startIndex` existed.
        var object = try Fixture.jsonObject(big)
        #expect(object["startIndex"] as? Int == 7)
        object.removeValue(forKey: "startIndex")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try QuotedJSON.makeDecoder().decode(RotationState.self, from: old)
        #expect(decoded == RotationState(quoteIDs: Fixture.ids(2), anchor: start, seed: .max))
    }
}

@Suite("RotationState continuity")
struct RotationContinuityTests {
    let calendar = Fixture.losAngeles
    /// Monday 2026-10-19 00:00. Default slots are 8:00, 14:30 and 21:00 every day.
    let anchor = Fixture.date(2026, 10, 19)

    func state(_ ids: [UUID], seed: UInt64 = 7) -> RotationState {
        RotationState(quoteIDs: ids, anchor: anchor, seed: seed)
    }

    func next(_ rotation: RotationState, at now: Date, settings: ReminderSettings = .default, count: Int = 1) -> [UUID] {
        ReminderPlanner.plan(rotation: rotation, settings: settings, now: now, calendar: calendar, limit: count).map(\.quoteID)
    }

    func current(_ rotation: RotationState, at now: Date, settings: ReminderSettings = .default) -> UUID? {
        ReminderPlanner.currentQuoteID(rotation: rotation, settings: settings, at: now, calendar: calendar)
    }

    func update(_ rotation: RotationState, to ids: [UUID], at now: Date, settings: ReminderSettings = .default, seed: UInt64 = 7) -> RotationState {
        rotation.updated(with: ids, at: now, seed: seed, settings: settings, calendar: calendar)
    }

    @Test func unchangedIDsKeepTheState() {
        let rotation = state(Fixture.ids(3))
        #expect(update(rotation, to: Fixture.ids(3), at: Fixture.date(2026, 10, 25), seed: 99) == rotation)
    }

    @Test func appendingMidCycleContinuesWithTheNextQuote() {
        let ids = Fixture.ids(5)
        let rotation = state(ids)
        // 8:00 played ids[0] and 14:30 played ids[1].
        let now = Fixture.date(2026, 10, 19, 15)
        #expect(current(rotation, at: now) == ids[1])

        let appended = update(rotation, to: ids + [Fixture.id(6)], at: now)
        #expect(appended.anchor == rotation.anchor, "the anchor is kept")
        #expect(appended.quoteIDs == ids + [Fixture.id(6)])
        #expect(current(appended, at: now) == ids[1], "the widget keeps the last quote")
        #expect(next(appended, at: now, count: 6) == [ids[2], ids[3], ids[4], Fixture.id(6), ids[0], ids[1]])
    }

    @Test func insertingAfterTheCurrentQuotePlaysItNext() {
        let ids = Fixture.ids(5)
        let now = Fixture.date(2026, 10, 19, 15)
        let inserted = [ids[0], ids[1], Fixture.id(9), ids[2], ids[3], ids[4]]
        let rotation = update(state(ids), to: inserted, at: now)
        #expect(next(rotation, at: now, count: 3) == [Fixture.id(9), ids[2], ids[3]])
    }

    @Test func removingTheCurrentQuoteContinuesWithItsSuccessor() {
        let ids = Fixture.ids(5)
        let now = Fixture.date(2026, 10, 19, 15) // ids[1] is on screen
        let removed = update(state(ids), to: [ids[0], ids[2], ids[3], ids[4]], at: now)
        #expect(next(removed, at: now, count: 4) == [ids[2], ids[3], ids[4], ids[0]])
        #expect(current(removed, at: now) == ids[0], "the widget falls back to the quote before")

        let removedRun = update(state(ids), to: [ids[0], ids[3], ids[4]], at: now)
        #expect(next(removedRun, at: now, count: 2) == [ids[3], ids[4]])

        let onlyEarlier = update(state(ids), to: [ids[0]], at: now)
        #expect(next(onlyEarlier, at: now, count: 2) == [ids[0], ids[0]])
    }

    @Test func reorderingContinuesAfterTheCurrentQuote() {
        let ids = Fixture.ids(5)
        let now = Fixture.date(2026, 10, 19, 15) // ids[1] is on screen
        let reversed = update(state(ids), to: ids.reversed(), at: now)
        #expect(next(reversed, at: now, count: 5) == [ids[0], ids[4], ids[3], ids[2], ids[1]])
        #expect(current(reversed, at: now) == ids[1])
    }

    @Test func beforeAnySlotTheUpcomingQuoteStaysNext() {
        let ids = Fixture.ids(4)
        // Anchored after the 8:00 slot; nothing has played by 10:00, and 14:30 will play ids[0].
        let rotation = RotationState(quoteIDs: ids, anchor: Fixture.date(2026, 10, 19, 9), seed: 1)
        let now = Fixture.date(2026, 10, 19, 10)
        #expect(next(rotation, at: now) == [ids[0]])

        let appended = update(rotation, to: ids + [Fixture.id(5)], at: now)
        #expect(next(appended, at: now, count: 2) == [ids[0], ids[1]])
        #expect(current(appended, at: now) == ids[0])

        let withoutFirst = update(rotation, to: Array(ids.dropFirst()), at: now)
        #expect(next(withoutFirst, at: now) == [ids[1]])
    }

    @Test func emptyTransitionsStartAtTheTop() {
        let now = Fixture.date(2026, 10, 21, 15)
        let empty = state([])
        let filled = update(empty, to: Fixture.ids(3), at: now)
        #expect(next(filled, at: now, count: 3) == Fixture.ids(3))
        #expect(update(filled, to: [], at: now).isEmpty)
        #expect(next(update(filled, to: [], at: now), at: now).isEmpty)

        let disjoint = update(state(Fixture.ids(3)), to: [Fixture.id(7), Fixture.id(8)], at: now)
        #expect(next(disjoint, at: now, count: 2) == [Fixture.id(7), Fixture.id(8)])
    }

    @Test func aFutureAnchorMovesToNow() {
        let ids = Fixture.ids(3)
        let future = RotationState(quoteIDs: ids, anchor: Fixture.date(2026, 11, 1), seed: 1)
        let now = Fixture.date(2026, 10, 19, 10)
        let updated = update(future, to: ids + [Fixture.id(4)], at: now)
        #expect(updated.anchor == now)
        #expect(next(updated, at: now) == [ids[0]])
    }

    @Test func noEnabledWeekdayKeepsTheCurrentQuote() {
        let settings = ReminderSettings(weekdays: [])
        let ids = Fixture.ids(3)
        let rotation = RotationState(quoteIDs: ids, anchor: anchor, seed: 1, startIndex: 1)
        let now = Fixture.date(2026, 10, 22)
        #expect(current(rotation, at: now, settings: settings) == ids[1])
        let updated = update(rotation, to: [Fixture.id(9)] + ids, at: now, settings: settings)
        #expect(current(updated, at: now, settings: settings) == ids[1])
    }

    @Test func startIndexShiftsBeforeTheShufflePermutation() {
        let ids = Fixture.ids(6)
        let permutation = SplitMix64.permutation(count: 6, seed: 42)
        let rotation = RotationState(quoteIDs: ids, anchor: anchor, seed: 42, startIndex: 4)
        for ordinal in -7...14 {
            let position = ((ordinal + 4) % 6 + 6) % 6
            #expect(ReminderPlanner.quoteID(forOrdinal: ordinal, rotation: rotation, order: .shuffle) == ids[permutation[position]])
            #expect(ReminderPlanner.quoteID(forOrdinal: ordinal, rotation: rotation, order: .inOrder) == ids[position])
        }
        // Extreme values (a corrupt store) never overflow.
        let extreme = RotationState(quoteIDs: ids, anchor: anchor, seed: 42, startIndex: .max)
        #expect(ReminderPlanner.plan(rotation: extreme, settings: .default, now: anchor, calendar: calendar).count == 60)
        let negative = RotationState(quoteIDs: ids, anchor: anchor, seed: 42, startIndex: .min)
        #expect(ReminderPlanner.quoteID(forOrdinal: .max, rotation: negative, order: .shuffle) != nil)
    }

    @Test func shuffleContinuesAfterTheCurrentQuoteDeterministically() {
        let settings = ReminderSettings(order: .shuffle)
        let ids = Fixture.ids(8)
        let rotation = state(ids, seed: 1234)
        let now = Fixture.date(2026, 10, 20, 15) // five slots have played
        let shown = current(rotation, at: now, settings: settings)
        let grown = ids + [Fixture.id(9)]
        let updated = update(rotation, to: grown, at: now, settings: settings, seed: 555)
        #expect(updated == update(rotation, to: grown, at: now, settings: settings, seed: 555))
        #expect(updated.seed == 555)
        #expect(current(updated, at: now, settings: settings) == shown)

        // The next nine slots walk the new permutation once, starting after the shown quote.
        let order = SplitMix64.permutation(count: 9, seed: 555).map { grown[$0] }
        guard let shown, let shownIndex = order.firstIndex(of: shown) else {
            Issue.record("the shown quote is still in the Rotation")
            return
        }
        let expected = (1...9).map { order[(shownIndex + $0) % 9] }
        #expect(next(updated, at: now, settings: settings, count: 9) == expected)
    }

    /// The review scenario: 10 quotes in order, 3 a day, a new quote appended every 2 days for 30
    /// days. Restarting at the top on each change starved the end of the list; continuing reaches
    /// every quote within one pass of the list.
    @Test func periodicAppendsStillReachEveryQuote() {
        var ids = Fixture.ids(10)
        var rotation = RotationState.starting(with: ids, at: anchor, seed: 3)
        var delivered: [UUID: Date] = [:]
        var addedAt: [UUID: Date] = [:]
        let end = Fixture.date(2026, 11, 18)
        var now = anchor
        var day = 0
        while now < end {
            let nextChange = Fixture.date(2026, 10, 19 + day + 2, 12)
            for reminder in ReminderPlanner.plan(rotation: rotation, settings: .default, now: now, calendar: calendar)
            where reminder.date < min(nextChange, end) {
                delivered[reminder.quoteID] = delivered[reminder.quoteID] ?? reminder.date
            }
            now = nextChange
            day += 2
            let new = Fixture.id(100 + day)
            ids.append(new)
            addedAt[new] = now
            rotation = rotation.updated(with: ids, at: now, seed: 3, settings: .default, calendar: calendar)
        }

        for id in Fixture.ids(10) {
            #expect((delivered[id] ?? .distantFuture) < Fixture.date(2026, 10, 23), "every original quote within the first pass")
        }
        // A quote appended with n quotes in the Rotation plays within n slots (n / 3 days, rounded up).
        for (id, added) in addedAt where added < Fixture.date(2026, 11, 10) {
            let bound = added.addingTimeInterval(Double(ids.count / 3 + 1) * 86_400)
            #expect((delivered[id] ?? .distantFuture) <= bound, "quote added \(added) played late or never")
        }
    }
}

@Suite("ReminderPlanner slots")
struct ReminderSlotTests {
    let calendar = Fixture.losAngeles
    /// Monday 2026-10-19 07:00 in Los Angeles.
    let mondayMorning = Fixture.date(2026, 10, 19, 7)

    @Test func spreadsEvenlyOverTheWindow() {
        let slots = ReminderPlanner.slots(for: .default, after: mondayMorning, calendar: calendar, limit: 6)
        #expect(slots.map { Fixture.clock($0, in: calendar).hour * 60 + Fixture.clock($0, in: calendar).minute }
            == [480, 870, 1260, 480, 870, 1260])
        #expect(slots.map { calendar.component(.day, from: $0) } == [19, 19, 19, 20, 20, 20])
    }

    @Test func oneADayFiresAtWindowStart() {
        let slots = ReminderPlanner.slots(for: ReminderSettings(timesPerDay: 1), after: mondayMorning, calendar: calendar, limit: 3)
        #expect(slots == [Fixture.date(2026, 10, 19, 8), Fixture.date(2026, 10, 20, 8), Fixture.date(2026, 10, 21, 8)])
    }

    @Test func skipsSlotsAtOrBeforeNow() {
        func first(after date: Date) -> Date? {
            ReminderPlanner.slots(for: .default, after: date, calendar: calendar, limit: 1).first
        }
        #expect(first(after: Fixture.date(2026, 10, 19, 14, 29, 59)) == Fixture.date(2026, 10, 19, 14, 30))
        #expect(first(after: Fixture.date(2026, 10, 19, 14, 30)) == Fixture.date(2026, 10, 19, 21))
        #expect(first(after: Fixture.date(2026, 10, 19, 21, 0, 1)) == Fixture.date(2026, 10, 20, 8))
    }

    @Test func onlyOnEnabledWeekdays() {
        let settings = ReminderSettings(weekdays: [2, 4]) // Monday, Wednesday
        let slots = ReminderPlanner.slots(for: settings, after: mondayMorning, calendar: calendar, limit: 30)
        #expect(slots.count == 30)
        #expect(slots.allSatisfy { [2, 4].contains(calendar.component(.weekday, from: $0)) })
        #expect(slots.first == Fixture.date(2026, 10, 19, 8))
        #expect(slots[3] == Fixture.date(2026, 10, 21, 8))
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func neverMoreThanSixty() {
        #expect(ReminderPlanner.slots(for: ReminderSettings(timesPerDay: 12), after: mondayMorning, calendar: calendar, limit: 500).count == 60)
        #expect(ReminderPlanner.slots(for: .default, after: mondayMorning, calendar: calendar, limit: 5).count == 5)
        #expect(ReminderPlanner.slots(for: .default, after: mondayMorning, calendar: calendar, limit: 0).isEmpty)
        #expect(ReminderPlanner.slots(for: .default, after: mondayMorning, calendar: calendar, limit: -3).isEmpty)
        // One Sunday reminder a week still fills the plan, over 60 weeks.
        let sparse = ReminderPlanner.slots(for: ReminderSettings(timesPerDay: 1, weekdays: [1]), after: mondayMorning, calendar: calendar)
        #expect(sparse.count == 60)
        #expect(sparse.allSatisfy { calendar.component(.weekday, from: $0) == 1 })
    }

    @Test func emptyWhenDisabledOrNoWeekdays() {
        #expect(ReminderPlanner.slots(for: ReminderSettings(enabled: false), after: mondayMorning, calendar: calendar).isEmpty)
        #expect(ReminderPlanner.slots(for: ReminderSettings(weekdays: []), after: mondayMorning, calendar: calendar).isEmpty)
    }

    @Test func keepsWallClockAcrossFallBack() {
        // DST ends 2026-11-01 02:00 in Los Angeles.
        let slots = ReminderPlanner.slots(for: .default, after: Fixture.date(2026, 10, 31), calendar: calendar, limit: 9)
        for slot in slots {
            let clock = Fixture.clock(slot, in: calendar)
            #expect([480, 870, 1260].contains(clock.hour * 60 + clock.minute))
        }
        #expect(slots[3].timeIntervalSince(slots[0]) == 25 * 3600)
        #expect(slots[6].timeIntervalSince(slots[3]) == 24 * 3600)
    }

    @Test func keepsWallClockAcrossSpringForward() {
        // DST starts 2027-03-14 02:00 in Los Angeles.
        let slots = ReminderPlanner.slots(for: .default, after: Fixture.date(2027, 3, 13), calendar: calendar, limit: 6)
        #expect(slots[3].timeIntervalSince(slots[0]) == 23 * 3600)
        #expect(slots.map { Fixture.clock($0, in: calendar).hour } == [8, 14, 21, 8, 14, 21])
    }

    @Test func nonexistentTimesMoveLaterAndStayOrdered() {
        let settings = ReminderSettings(windowStart: 120, windowEnd: 180) // 02:00, 02:30, 03:00
        let slots = ReminderPlanner.slots(for: settings, after: Fixture.date(2027, 3, 14), calendar: calendar, limit: 6)
        #expect(slots.count == 6)
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(slots.prefix(3).allSatisfy { calendar.component(.day, from: $0) == 14 && Fixture.clock($0, in: calendar).hour == 3 })
        #expect(slots.suffix(3).map { Fixture.clock($0, in: calendar).hour * 60 + Fixture.clock($0, in: calendar).minute } == [120, 150, 180])
    }

    @Test func repeatedHourUsesFirstOccurrence() {
        let settings = ReminderSettings(windowStart: 60, windowEnd: 120) // 01:00, 01:30, 02:00
        let slots = ReminderPlanner.slots(for: settings, after: Fixture.date(2026, 11, 1), calendar: calendar, limit: 3)
        #expect(slots.map { $0.timeIntervalSince(slots[0]) } == [0, 1800, 7200])
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Suite("ReminderPlanner plans")
struct ReminderPlanTests {
    let calendar = Fixture.losAngeles
    let ids = Fixture.ids(4)
    let anchor = Fixture.date(2026, 10, 19)
    let mondayMorning = Fixture.date(2026, 10, 19, 7)

    var rotation: RotationState { RotationState(quoteIDs: ids, anchor: anchor, seed: 12_345) }

    @Test func cyclesInOrderFromTheAnchor() {
        let plan = ReminderPlanner.plan(rotation: rotation, settings: .default, now: mondayMorning, calendar: calendar)
        #expect(plan.count == 60)
        #expect(plan.prefix(8).map(\.quoteID) == ids + ids)
        #expect(plan.map(\.ordinal) == Array(0..<60))
        #expect(plan.first?.date == Fixture.date(2026, 10, 19, 8))
        #expect(ReminderPlanner.plan(rotation: rotation, settings: .default, now: mondayMorning, calendar: calendar, limit: 500).count == 60)
        #expect(ReminderPlanner.plan(rotation: rotation, settings: .default, now: mondayMorning, calendar: calendar, limit: 7).count == 7)
    }

    @Test func countsFromAMidDayAnchor() {
        let midDay = RotationState(quoteIDs: ids, anchor: Fixture.date(2026, 10, 19, 12), seed: 0)
        let plan = ReminderPlanner.plan(rotation: midDay, settings: .default, now: Fixture.date(2026, 10, 19, 12), calendar: calendar, limit: 3)
        #expect(plan.map(\.date) == [Fixture.date(2026, 10, 19, 14, 30), Fixture.date(2026, 10, 19, 21), Fixture.date(2026, 10, 20, 8)])
        #expect(plan.map(\.quoteID) == Array(ids.prefix(3)))
    }

    @Test func emptyWhenDisabledOrRotationEmpty() {
        #expect(ReminderPlanner.plan(rotation: rotation, settings: ReminderSettings(enabled: false), now: mondayMorning, calendar: calendar).isEmpty)
        let empty = RotationState(quoteIDs: [], anchor: anchor, seed: 1)
        #expect(ReminderPlanner.plan(rotation: empty, settings: .default, now: mondayMorning, calendar: calendar).isEmpty)
        #expect(ReminderPlanner.plan(rotation: rotation, settings: ReminderSettings(weekdays: []), now: mondayMorning, calendar: calendar).isEmpty)
    }

    @Test("Replanning later continues the same cycle", arguments: [ReminderOrder.inOrder, .shuffle])
    func replanContinuesCycle(order: ReminderOrder) {
        let settings = ReminderSettings(timesPerDay: 5, weekdays: [1, 2, 4, 6], order: order)
        let rotation = RotationState(quoteIDs: Fixture.ids(7), anchor: anchor, seed: 99)
        let first = ReminderPlanner.plan(rotation: rotation, settings: settings, now: mondayMorning, calendar: calendar)
        let later = ReminderPlanner.plan(
            rotation: rotation, settings: settings, now: Fixture.date(2026, 10, 27, 15, 10), calendar: calendar
        )
        let byDate = Dictionary(uniqueKeysWithValues: first.map { ($0.date, $0) })
        let overlap = later.filter { byDate[$0.date] != nil }
        #expect(overlap.count > 20)
        for reminder in overlap {
            #expect(byDate[reminder.date] == reminder)
        }
        #expect(zip(later, later.dropFirst()).allSatisfy { $1.ordinal == $0.ordinal + 1 })
    }

    @Test func anchorInTheFutureCountsBackwards() {
        let future = RotationState(quoteIDs: ids, anchor: Fixture.date(2026, 10, 20, 14, 30), seed: 0)
        let plan = ReminderPlanner.plan(rotation: future, settings: .default, now: mondayMorning, calendar: calendar, limit: 6)
        #expect(plan.map(\.ordinal) == [-4, -3, -2, -1, 0, 1])
        #expect(plan[4].quoteID == ids[0])
        #expect(plan[0].quoteID == ids[0])
        #expect(plan[3].quoteID == ids[3])
    }

    @Test func shuffleIsDeterministicAndCoversEveryQuote() {
        let ten = Fixture.ids(10)
        let settings = ReminderSettings(timesPerDay: 4, order: .shuffle)
        let rotation = RotationState(quoteIDs: ten, anchor: anchor, seed: 12_345)
        let plan = ReminderPlanner.plan(rotation: rotation, settings: settings, now: mondayMorning, calendar: calendar)
        #expect(plan == ReminderPlanner.plan(rotation: rotation, settings: settings, now: mondayMorning, calendar: calendar))
        let cycle = plan.prefix(10).map(\.quoteID)
        #expect(Set(cycle) == Set(ten))
        #expect(cycle != ten)
        #expect(cycle == SplitMix64.permutation(count: 10, seed: 12_345).map { ten[$0] })
        for index in 10..<plan.count { #expect(plan[index].quoteID == plan[index - 10].quoteID) }

        var reseeded = rotation
        reseeded.seed = 999
        let other = ReminderPlanner.plan(rotation: reseeded, settings: settings, now: mondayMorning, calendar: calendar)
        #expect(other.prefix(10).map(\.quoteID) != cycle)
        #expect(other.map(\.date) == plan.map(\.date))
    }

    @Test func splitMixMatchesReferenceOutputs() {
        var generator = SplitMix64(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
        #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(generator.next() == 0x06C4_5D18_8009_454F)
        for seed: UInt64 in [0, 1, 42, .max] {
            for count in 0...20 {
                #expect(SplitMix64.permutation(count: count, seed: seed).sorted() == Array(0..<count))
            }
        }
    }
}

@Suite("ReminderPlanner current quote and timeline")
struct ReminderCurrentTests {
    let calendar = Fixture.losAngeles
    let ids = Fixture.ids(4)
    var rotation: RotationState { RotationState(quoteIDs: ids, anchor: Fixture.date(2026, 10, 19), seed: 5) }

    func current(_ date: Date, settings: ReminderSettings = .default, rotation: RotationState? = nil) -> UUID? {
        ReminderPlanner.currentQuoteID(rotation: rotation ?? self.rotation, settings: settings, at: date, calendar: calendar)
    }

    @Test func followsTheMostRecentSlot() {
        #expect(current(Fixture.date(2026, 10, 19, 7)) == ids[0]) // before any slot
        #expect(current(Fixture.date(2026, 10, 19, 8)) == ids[0])
        #expect(current(Fixture.date(2026, 10, 19, 14, 29)) == ids[0])
        #expect(current(Fixture.date(2026, 10, 19, 14, 30)) == ids[1])
        #expect(current(Fixture.date(2026, 10, 19, 21)) == ids[2])
        #expect(current(Fixture.date(2026, 10, 20, 7, 59)) == ids[2])
        #expect(current(Fixture.date(2026, 10, 20, 8)) == ids[3])
        #expect(current(Fixture.date(2026, 10, 20, 14, 30)) == ids[0])
        #expect(current(Fixture.date(2026, 10, 18)) == ids[0]) // before the anchor
    }

    @Test("Matches every planned reminder", arguments: [ReminderOrder.inOrder, .shuffle])
    func matchesPlan(order: ReminderOrder) {
        let settings = ReminderSettings(timesPerDay: 6, windowStart: 450, windowEnd: 1335, weekdays: [2, 3, 5, 7], order: order)
        let plan = ReminderPlanner.plan(rotation: rotation, settings: settings, now: Fixture.date(2026, 10, 25, 9), calendar: calendar)
        for (reminder, next) in zip(plan, plan.dropFirst()) {
            #expect(current(reminder.date, settings: settings) == reminder.quoteID)
            #expect(current(next.date.addingTimeInterval(-1), settings: settings) == reminder.quoteID)
        }
    }

    @Test func shuffleStartsWithTheFirstSlotsQuote() {
        let settings = ReminderSettings(order: .shuffle)
        let first = ids[SplitMix64.permutation(count: 4, seed: 5)[0]]
        #expect(current(Fixture.date(2026, 10, 19, 7), settings: settings) == first)
    }

    @Test func emptyRotationHasNoQuoteButDisabledStillRotates() {
        #expect(current(Fixture.date(2026, 10, 20, 9), rotation: RotationState(quoteIDs: [], anchor: .distantPast, seed: 0)) == nil)
        #expect(current(Fixture.date(2026, 10, 20, 9), settings: ReminderSettings(enabled: false)) == ids[3])
        #expect(current(Fixture.date(2026, 10, 20, 9), settings: ReminderSettings(weekdays: [])) == ids[0])
    }

    /// Compares the closed-form slot counting against walking every slot, in zones with odd DST rules.
    @Test("Long-running anchors count slots exactly", arguments: [
        "America/Los_Angeles", "Asia/Kolkata", "Australia/Lord_Howe", "America/Santiago", "Europe/London",
    ])
    func longAnchorsMatchBruteForce(zone: String) {
        let calendar = Fixture.calendar(zone)
        let settings = ReminderSettings(timesPerDay: 5, windowStart: 540, windowEnd: 1050, weekdays: [2, 3, 6])
        let ids = Fixture.ids(7)
        let anchor = Fixture.date(2025, 9, 3, 10, 17, in: calendar)
        let rotation = RotationState(quoteIDs: ids, anchor: anchor, seed: 1)
        let end = anchor.addingTimeInterval(450 * 86_400)

        var all: [Date] = []
        var cursor = anchor.addingTimeInterval(-0.001)
        while cursor < end {
            let chunk = ReminderPlanner.slots(for: settings, after: cursor, calendar: calendar)
            guard let last = chunk.last else { break }
            all += chunk
            cursor = last
        }
        #expect(all.count > 900)

        var sample = anchor.addingTimeInterval(3600)
        while sample < end {
            let passed = all.lazy.filter { $0 <= sample }.count
            let expected = ids[max(0, passed - 1) % ids.count]
            #expect(ReminderPlanner.currentQuoteID(rotation: rotation, settings: settings, at: sample, calendar: calendar) == expected)
            let next = ReminderPlanner.plan(rotation: rotation, settings: settings, now: sample, calendar: calendar, limit: 1)
            #expect(next.first?.ordinal == passed)
            sample = sample.addingTimeInterval(37 * 3600 + 13 * 60)
        }
    }

    @Test func timelineStartsNowAndCoversTheNextDay() {
        let morning = ReminderPlanner.timeline(rotation: rotation, settings: .default, now: Fixture.date(2026, 10, 19, 7), calendar: calendar)
        #expect(morning.map(\.date) == [
            Fixture.date(2026, 10, 19, 7), Fixture.date(2026, 10, 19, 8),
            Fixture.date(2026, 10, 19, 14, 30), Fixture.date(2026, 10, 19, 21),
        ])
        #expect(morning.map(\.quoteID) == [ids[0], ids[0], ids[1], ids[2]])

        let afternoon = ReminderPlanner.timeline(rotation: rotation, settings: .default, now: Fixture.date(2026, 10, 19, 15), calendar: calendar)
        #expect(afternoon.map(\.ordinal) == [1, 2, 3, 4])
        #expect(afternoon.last?.date == Fixture.date(2026, 10, 20, 14, 30))

        let disabled = ReminderPlanner.timeline(
            rotation: rotation, settings: ReminderSettings(enabled: false), now: Fixture.date(2026, 10, 19, 15), calendar: calendar
        )
        #expect(disabled == afternoon)
        let nowOnly = ReminderPlanner.timeline(rotation: rotation, settings: .default, now: Fixture.date(2026, 10, 19, 15), calendar: calendar, horizon: 0)
        #expect(nowOnly.count == 1)
        #expect(ReminderPlanner.timeline(rotation: RotationState(quoteIDs: [], anchor: .now, seed: 0), settings: .default, now: .now).isEmpty)
        #expect(ReminderPlanner.quoteID(forOrdinal: -1, rotation: rotation, order: .inOrder) == ids[3])
    }
}
