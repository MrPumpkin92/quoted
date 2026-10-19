import Foundation
import Testing
@testable import QuotedCore

/// A store over a fresh temporary directory and `UserDefaults` suite, removed when done.
final class TemporaryStore {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: AppGroupStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "QuotedCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "QuotedCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AppGroupStore(containerURL: directory, defaults: defaults)
    }

    /// Another store on the same container and suite, like the widget process.
    func sibling() -> AppGroupStore {
        AppGroupStore(containerURL: directory, defaults: UserDefaults(suiteName: suiteName)!)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite("WidgetSnapshot")
struct WidgetSnapshotTests {
    let calendar = Fixture.losAngeles
    let created = Fixture.date(2026, 10, 1)

    var library: [Quote] {
        [
            Quote(id: Fixture.id(1), body: "First", format: [TextRun(start: 0, length: 5, bold: true)], author: "A", rotationPosition: 1, createdAt: created),
            Quote(id: Fixture.id(2), body: "Second", rotationPosition: nil, createdAt: created),
            Quote(id: Fixture.id(3), body: "Third", source: "S", rotationPosition: 0, createdAt: created),
        ]
    }

    var rotation: RotationState {
        RotationState(quoteIDs: RotationState.orderedQuoteIDs(in: library), anchor: Fixture.date(2026, 10, 19), seed: 3)
    }

    @Test func buildsFromTheLibraryInRotationOrder() {
        let snapshot = WidgetSnapshot(library: library, settings: .default, rotation: rotation, updatedAt: created)
        #expect(snapshot.version == WidgetSnapshot.currentVersion)
        #expect(snapshot.quotes.map(\.id) == [Fixture.id(3), Fixture.id(1)])
        #expect(snapshot.quotes[1].format == [TextRun(start: 0, length: 5, bold: true)])
        #expect(snapshot.quotes[0].attribution == "S")
        #expect(!snapshot.isEmpty)
        #expect(snapshot.quote(id: Fixture.id(2)) == nil)
    }

    @Test func currentQuoteAndTimelineFollowThePlanner() {
        let snapshot = WidgetSnapshot(library: library, settings: .default, rotation: rotation, updatedAt: created)
        #expect(snapshot.currentQuote(at: Fixture.date(2026, 10, 19, 7), calendar: calendar)?.id == Fixture.id(3))
        #expect(snapshot.currentQuote(at: Fixture.date(2026, 10, 19, 15), calendar: calendar)?.id == Fixture.id(1))
        let timeline = snapshot.timeline(now: Fixture.date(2026, 10, 19, 15), calendar: calendar)
        #expect(timeline.map(\.quote.id) == [Fixture.id(1), Fixture.id(3), Fixture.id(1), Fixture.id(3)])
        #expect(timeline.first?.date == Fixture.date(2026, 10, 19, 15))
    }

    @Test func emptyRotationShowsThePrompt() {
        let empty = WidgetSnapshot(library: library, settings: .default, rotation: RotationState(quoteIDs: [], anchor: created, seed: 0))
        #expect(empty.isEmpty)
        #expect(empty.currentQuote(at: created, calendar: calendar) == nil)
        #expect(empty.timeline(now: created, calendar: calendar).isEmpty)
    }
}

@Suite("AppGroupStore")
struct AppGroupStoreTests {
    let created = Fixture.date(2026, 10, 1, 9, 30)

    func snapshot() -> WidgetSnapshot {
        let quote = Quote(id: Fixture.id(1), body: "Hello 👋", format: [TextRun(start: 6, length: 2, italic: true)], rotationPosition: 0, createdAt: created)
        return WidgetSnapshot(
            library: [quote],
            settings: ReminderSettings(timesPerDay: 2, order: .shuffle),
            rotation: RotationState(quoteIDs: [quote.id], anchor: created, seed: .max),
            updatedAt: created
        )
    }

    func cache(user: UUID = Fixture.id(42)) -> LibraryCache {
        LibraryCache(
            userID: user,
            savedAt: created,
            quotes: [Quote(id: Fixture.id(1), body: "Cached", author: "Me", origin: .pasted, createdAt: created)],
            shared: [SharedQuote(id: Fixture.id(2), senderID: Fixture.id(3), sender: Profile(id: Fixture.id(3), username: "ada"), recipientID: user, body: "Shared", note: "hi", createdAt: created)]
        )
    }

    @Test func identifierMatchesTheEntitlement() {
        #expect(AppGroup.identifier == "group.com.hwei.quoted")
        let temp = TemporaryStore()
        #expect(temp.store.snapshotURL.lastPathComponent == "widget-snapshot.json")
        #expect(temp.store.libraryCacheURL.lastPathComponent == "library-cache.json")
    }

    @Test func snapshotRoundTripsAndIsVisibleToTheWidget() throws {
        let temp = TemporaryStore()
        #expect(temp.store.readSnapshot() == nil)
        try temp.store.writeSnapshot(snapshot())
        #expect(temp.store.readSnapshot() == snapshot())
        #expect(temp.sibling().readSnapshot() == snapshot())

        var replaced = snapshot()
        replaced.quotes = []
        try temp.store.writeSnapshot(replaced)
        #expect(temp.sibling().readSnapshot() == replaced)
    }

    @Test func ignoresCorruptOrForeignVersionFiles() throws {
        let temp = TemporaryStore()
        try FileManager.default.createDirectory(at: temp.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: temp.store.snapshotURL)
        #expect(temp.store.readSnapshot() == nil)

        var future = snapshot()
        future.version = WidgetSnapshot.currentVersion + 1
        try temp.store.writeSnapshot(future)
        #expect(temp.store.readSnapshot() == nil)

        var oldCache = cache()
        oldCache.version = 0
        try temp.store.writeLibraryCache(oldCache)
        #expect(temp.store.readLibraryCache() == nil)
    }

    @Test func libraryCacheRoundTripsPerUser() throws {
        let temp = TemporaryStore()
        #expect(temp.store.readLibraryCache() == nil)
        try temp.store.writeLibraryCache(cache())
        #expect(temp.store.readLibraryCache() == cache())
        #expect(temp.store.readLibraryCache(for: Fixture.id(42)) == cache())
        #expect(temp.store.readLibraryCache(for: Fixture.id(43)) == nil)
        // The file uses the database column names.
        let text = try String(contentsOf: temp.store.libraryCacheURL, encoding: .utf8)
        #expect(text.contains("\"body_format\"") && text.contains("\"sender_id\"") && text.contains("\"origin\":\"pasted\""))
    }

    @Test func settingsAndRotationLiveInDefaults() {
        let temp = TemporaryStore()
        #expect(temp.store.loadReminderSettings() == .default)
        #expect(temp.store.loadRotationState() == nil)

        let settings = ReminderSettings(enabled: false, timesPerDay: 7, windowStart: 360, windowEnd: 1380, weekdays: [2, 3], order: .shuffle)
        let rotation = RotationState(quoteIDs: Fixture.ids(3), anchor: created, seed: 0xDEAD_BEEF_CAFE_F00D)
        temp.store.saveReminderSettings(settings)
        temp.store.saveRotationState(rotation)
        #expect(temp.sibling().loadReminderSettings() == settings)
        #expect(temp.sibling().loadRotationState() == rotation)
        #expect(temp.defaults.data(forKey: AppGroupStore.reminderSettingsKey) != nil)
    }

    @Test func wipeAllRemovesEverything() throws {
        let temp = TemporaryStore()
        try temp.store.writeSnapshot(snapshot())
        try temp.store.writeLibraryCache(cache())
        temp.store.saveReminderSettings(ReminderSettings(timesPerDay: 9))
        temp.store.saveRotationState(RotationState(quoteIDs: Fixture.ids(1), anchor: created, seed: 1))

        temp.store.wipeAll()
        #expect(temp.store.readSnapshot() == nil)
        #expect(temp.store.readLibraryCache() == nil)
        #expect(temp.store.loadReminderSettings() == .default)
        #expect(temp.store.loadRotationState() == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.store.snapshotURL.path(percentEncoded: false)))
        temp.store.wipeAll() // wiping twice is harmless
    }

    @Test func storeIsSendableAcrossTasks() async throws {
        let temp = TemporaryStore()
        let store = temp.store
        let written = snapshot()
        try await Task.detached { try store.writeSnapshot(written) }.value
        let read = await Task.detached { store.readSnapshot() }.value
        #expect(read == written)
        withExtendedLifetime(temp) {}
    }
}
