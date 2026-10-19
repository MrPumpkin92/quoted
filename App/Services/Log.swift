import OSLog

/// App loggers. Use these instead of `print`. Messages are private by default; mark values
/// `privacy: .public` only when they hold no user content.
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hwei.quoted"

    /// Launch, scene phase and deep links.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Sign-in, sign-out and onboarding phases.
    static let session = Logger(subsystem: subsystem, category: "session")
    /// Library loads, cache and quote mutations.
    static let library = Logger(subsystem: subsystem, category: "library")
    /// Friends, shares, reports and blocks.
    static let social = Logger(subsystem: subsystem, category: "social")
    /// Reminder planning, notifications and widget snapshots.
    static let reminders = Logger(subsystem: subsystem, category: "reminders")
    /// Toasts and other UI events.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
