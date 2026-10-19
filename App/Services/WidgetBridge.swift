import Foundation
import OSLog
import QuotedCore
import WidgetKit

/// Writes the widget snapshot to the App Group and reloads the widget timelines.
///
/// The widget extension reads `widget-snapshot.json` (QuotedCore `WidgetSnapshot`) and runs the same
/// `ReminderPlanner`, so the widget always matches the latest reminder.
@MainActor
struct WidgetBridge {
    /// The App Group store, or nil when the entitlement is missing (then writes are skipped).
    let store: AppGroupStore?

    /// Atomically writes `snapshot` off the main thread, then reloads every Quoted widget.
    func write(_ snapshot: WidgetSnapshot) async {
        if let store {
            let result = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try store.writeSnapshot(snapshot)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let result {
                Logger.reminders.error("Writing the widget snapshot failed: \(result, privacy: .public)")
            }
        }
        reloadTimelines()
    }

    /// Asks WidgetKit to reload every Quoted widget timeline.
    func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Whether the user has added a Quoted widget anywhere (Home Screen, Lock Screen, StandBy).
    /// False when WidgetKit cannot answer.
    func hasInstalledWidget() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let widgets):
                    continuation.resume(returning: !widgets.isEmpty)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
