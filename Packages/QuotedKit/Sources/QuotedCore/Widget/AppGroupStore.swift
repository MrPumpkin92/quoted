import Foundation

/// The App Group shared by the app and the widget extension.
public enum AppGroup {
    /// Must match the App Groups entitlement of both targets.
    public static let identifier = "group.com.hwei.quoted"
}

/// The offline library cache, written to `library-cache.json` so launch renders without a network.
public struct LibraryCache: Codable, Hashable, Sendable {
    /// Bump when the format changes incompatibly; older caches are then ignored.
    public static let currentVersion = 1

    public var version: Int
    /// The user the cache belongs to, so a different sign-in never shows someone else's library.
    public var userID: UUID?
    public var savedAt: Date
    public var quotes: [Quote]
    public var shared: [SharedQuote]

    public init(
        version: Int = LibraryCache.currentVersion,
        userID: UUID? = nil,
        savedAt: Date = Date(),
        quotes: [Quote],
        shared: [SharedQuote]
    ) {
        self.version = version
        self.userID = userID
        self.savedAt = savedAt
        self.quotes = quotes
        self.shared = shared
    }
}

/// Reads and writes the files and settings the app and the widget share.
///
/// Files (`widget-snapshot.json`, `library-cache.json`) are written atomically to the App Group
/// container; ``ReminderSettings`` and ``RotationState`` live in the suite `UserDefaults` as JSON.
/// The class is `@unchecked Sendable` because its only mutable dependency, `UserDefaults`, is
/// documented as thread-safe; every stored property is immutable.
public final class AppGroupStore: @unchecked Sendable {
    public static let snapshotFileName = "widget-snapshot.json"
    public static let libraryCacheFileName = "library-cache.json"
    static let reminderSettingsKey = "quoted.reminderSettings"
    static let rotationStateKey = "quoted.rotationState"

    /// The directory that holds the shared files.
    public let containerURL: URL
    private let defaults: UserDefaults

    /// Opens the App Group container and suite. Nil when the entitlement is missing.
    public convenience init?(appGroupID: String = AppGroup.identifier) {
        guard
            let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
            let defaults = UserDefaults(suiteName: appGroupID)
        else { return nil }
        self.init(containerURL: url, defaults: defaults)
    }

    /// Uses an explicit directory and defaults, for tests.
    public init(containerURL: URL, defaults: UserDefaults) {
        self.containerURL = containerURL
        self.defaults = defaults
    }

    public var snapshotURL: URL { containerURL.appending(path: Self.snapshotFileName, directoryHint: .notDirectory) }
    public var libraryCacheURL: URL { containerURL.appending(path: Self.libraryCacheFileName, directoryHint: .notDirectory) }

    // MARK: Widget snapshot

    /// The saved snapshot, or nil if there is none, it is unreadable, or it has another version.
    public func readSnapshot() -> WidgetSnapshot? {
        guard let snapshot = read(WidgetSnapshot.self, from: snapshotURL),
              snapshot.version == WidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Atomically replaces the snapshot. Reload widget timelines afterwards.
    public func writeSnapshot(_ snapshot: WidgetSnapshot) throws {
        try write(snapshot, to: snapshotURL)
    }

    // MARK: Library cache

    /// The saved cache, or nil if there is none, it is unreadable, or it has another version.
    public func readLibraryCache() -> LibraryCache? {
        guard let cache = read(LibraryCache.self, from: libraryCacheURL),
              cache.version == LibraryCache.currentVersion
        else { return nil }
        return cache
    }

    /// The saved cache only if it belongs to `userID`.
    public func readLibraryCache(for userID: UUID) -> LibraryCache? {
        guard let cache = readLibraryCache(), cache.userID == userID else { return nil }
        return cache
    }

    /// Atomically replaces the cache.
    public func writeLibraryCache(_ cache: LibraryCache) throws {
        try write(cache, to: libraryCacheURL)
    }

    // MARK: Settings

    /// The saved reminder settings, or ``ReminderSettings/default``.
    public func loadReminderSettings() -> ReminderSettings {
        loadDefault(ReminderSettings.self, forKey: Self.reminderSettingsKey) ?? .default
    }

    public func saveReminderSettings(_ settings: ReminderSettings) {
        saveDefault(settings, forKey: Self.reminderSettingsKey)
    }

    /// The saved rotation state, or nil before the first save.
    public func loadRotationState() -> RotationState? {
        loadDefault(RotationState.self, forKey: Self.rotationStateKey)
    }

    public func saveRotationState(_ state: RotationState) {
        saveDefault(state, forKey: Self.rotationStateKey)
    }

    // MARK: Wipe

    /// Removes the snapshot, the library cache, the reminder settings and the rotation state.
    /// Call on sign-out and after account deletion.
    public func wipeAll() {
        let fileManager = FileManager.default
        for url in [snapshotURL, libraryCacheURL] where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: url)
        }
        defaults.removeObject(forKey: Self.reminderSettingsKey)
        defaults.removeObject(forKey: Self.rotationStateKey)
    }

    // MARK: Private

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? QuotedJSON.makeDecoder().decode(type, from: data)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let data = try QuotedJSON.makeEncoder().encode(value)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func loadDefault<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? QuotedJSON.makeDecoder().decode(type, from: data)
    }

    private func saveDefault(_ value: some Encodable, forKey key: String) {
        guard let data = try? QuotedJSON.makeEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
