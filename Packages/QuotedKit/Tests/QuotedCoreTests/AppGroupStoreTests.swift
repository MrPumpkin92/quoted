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
            quotes: [
                Quote(
                    id: Fixture.id(1), body: "Cached", author: "Me", origin: .pasted, createdAt: created,
                    creatorID: user, creatorUsername: "me", editedFromID: Fixture.id(3), editedFromUsername: "ada"
                ),
            ],
            messages: [
                Message(
                    id: Fixture.id(2), conversationID: Fixture.id(4), senderID: Fixture.id(3), kind: .quote, note: "hi",
                    quote: QuoteSnapshot(body: "Shared", creatorID: Fixture.id(3), creatorUsername: "ada"), createdAt: created
                ),
            ],
            conversations: [
                InboxConversation(
                    id: Fixture.id(4), otherID: Fixture.id(3), other: Profile(id: Fixture.id(3), username: "ada", displayName: "Ada L."),
                    lastMessageAt: created, lastMessageKind: .quote, lastMessagePreview: "Shared",
                    lastMessageSenderID: Fixture.id(3), unreadCount: 1
                ),
            ]
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
        // Provenance is cached, so "Added by" reads offline.
        #expect(text.contains("\"creator_username\":\"me\"") && text.contains("\"edited_from_username\":\"ada\""))
        #expect(temp.store.readLibraryCache()?.quotes.first?.provenance.editedFromUsername == "ada")
        // The senders of cached messages read offline too.
        #expect(text.contains("\"other_username\":\"ada\"") && text.contains("\"unread_count\":1"))
        #expect(temp.store.readLibraryCache()?.conversations.first?.other?.displayName == "Ada L.")
    }

    /// A conversation list that no longer decodes costs only itself: the library and messages stay.
    @Test func undecodableConversationsDropOnlyThemselves() throws {
        let temp = TemporaryStore()
        try temp.store.writeLibraryCache(cache())
        var json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: temp.store.libraryCacheURL)) as? [String: Any]
        )
        json["conversations"] = [["conversation_id": "not a uuid"]]
        try JSONSerialization.data(withJSONObject: json).write(to: temp.store.libraryCacheURL)
        let read = try #require(temp.store.readLibraryCache(for: Fixture.id(42)))
        #expect(read.quotes == cache().quotes)
        #expect(read.messages == cache().messages)
        #expect(read.conversations.isEmpty)
    }

    /// The file the current App Store build writes: shares in `shared`, quotes without provenance.
    @Test func cacheWrittenBeforeTheRedesignStillDecodes() throws {
        let temp = TemporaryStore()
        try FileManager.default.createDirectory(at: temp.directory, withIntermediateDirectories: true)
        let legacy = """
        {"quotes":[{"author":"Me","body":"Cached","body_format":[],"created_at":"2026-10-19T03:26:38.000000Z",
          "favorited_at":null,"id":"00000000-0000-4000-8000-000000000001","is_favorite":true,"origin":"pasted",
          "rotation_position":0,"source":null,"updated_at":"2026-10-19T03:26:38.000000Z","verified_starter_id":null}],
         "savedAt":"2026-10-19T03:26:38.000000Z",
         "shared":[{"author":null,"body":"Shared","body_format":[],"created_at":"2026-10-19T03:26:38.000000Z",
          "id":"00000000-0000-4000-8000-000000000002","note":"hi","quote_id":null,"recipient_id":"00000000-0000-4000-8000-00000000002A",
          "saved_at":null,"seen_at":null,"sender":{"display_name":"ada","id":"00000000-0000-4000-8000-000000000003","shows_favorites":false,"username":"ada"},
          "sender_id":"00000000-0000-4000-8000-000000000003","source":null,"verified_starter_id":null}],
         "userID":"00000000-0000-4000-8000-00000000002A","version":1}
        """
        try Data(legacy.utf8).write(to: temp.store.libraryCacheURL)
        let cache = try #require(temp.store.readLibraryCache(for: Fixture.id(42)))
        #expect(cache.quotes.map(\.body) == ["Cached"])
        #expect(cache.quotes.first?.isFavorite == true)
        #expect(cache.quotes.first?.provenance == Provenance())
        #expect(cache.messages.isEmpty, "shares are not carried over; the next refresh brings the messages")
        #expect(cache.conversations.isEmpty)
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
