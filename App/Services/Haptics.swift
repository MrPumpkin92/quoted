import UIKit

/// Light haptic feedback for imperative code paths (stores, toasts). In views, prefer SwiftUI's
/// `.sensoryFeedback(_:trigger:)`.
@MainActor
enum Haptics {
    /// A completed action (saved, sent, accepted).
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A destructive action went through (deleted, blocked).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Something failed.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// A selection changed (chips, checkmarks, toggles in a custom control).
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A light tap (drag-to-reorder pickup).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
