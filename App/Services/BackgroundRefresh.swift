import BackgroundTasks
import Foundation
import OSLog

/// The `BGAppRefreshTask` that tops up reminders and the widget snapshot about every 12 hours.
///
/// SwiftUI registers the handler at launch through the scene's
/// `.backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier))` modifier (QuotedApp), which calls
/// `AppModel.performBackgroundRefresh()`. The identifier is listed under
/// `BGTaskSchedulerPermittedIdentifiers` in Info.plist, with `UIBackgroundModes` = `fetch`.
enum BackgroundRefresh {
    static let taskIdentifier = "com.hwei.quoted.refresh"
    /// How long iOS should wait before running the next refresh.
    static let interval: TimeInterval = 12 * 60 * 60

    /// Submits (or replaces) the next refresh request. Call when the app goes to the background and at
    /// the end of each refresh. Failures (for example in the Simulator) are logged, not thrown.
    @MainActor
    static func schedule(after interval: TimeInterval = BackgroundRefresh.interval) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger.app.debug("Background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}
