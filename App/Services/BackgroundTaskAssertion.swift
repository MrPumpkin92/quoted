import OSLog
import UIKit

/// Keeps the app running for a short while after it leaves the foreground, so a server write the
/// user already started (a delete, a send, a sign-out) finishes instead of being suspended mid-request.
///
/// Begin one right before the network call and end it when the call returns:
///
///     let assertion = BackgroundTaskAssertion("Delete quote")
///     defer { assertion.end() }
///     try await backend.quotes.delete(id: id)
///
/// `end()` is idempotent, and iOS's expiration handler ends it too, so the task is ended exactly once.
/// In the foreground the assertion costs nothing.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let name: String

    /// Asks iOS for background time named `name` (shown in Instruments and the console).
    init(_ name: String) {
        self.name = name
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            Logger.app.info("Background time ran out for \(self.name, privacy: .public)")
            self.end()
        }
    }

    /// Releases the background time. Safe to call more than once.
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
