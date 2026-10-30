import Accessibility
import OSLog
import QuotedKit
import SwiftUI
import UIKit

/// One short message at the bottom of the screen, with an optional action (usually Undo).
struct Toast: Identifiable, Equatable {
    enum Style: Equatable, Sendable {
        /// Neutral confirmation ("Sent to Maya").
        case info
        /// Something worked ("Saved to your library").
        case success
        /// Something failed ("You're offline. Try again when connected.").
        case error
    }

    let id: UUID
    let message: String
    let style: Style
    /// The trailing button title ("Undo"), or nil.
    let actionTitle: String?
    /// How long the toast stays before it closes on its own (already lengthened for assistive
    /// technology, see `ToastCenter.assistiveDurationFactor`).
    let duration: Duration
}

/// Shows one toast at a time, app-wide. Owned by `AppModel`; inject with `@Environment(ToastCenter.self)`.
///
/// - `show(_:style:)`: a plain message.
/// - `show(_:actionTitle:action:)`: the change already happened; the action reverses it ("Removed from
///   reminders" · Undo → add it back).
/// - `showDeferred(_:undo:commit:)`: the change is pending. Exactly one of `undo` (the user tapped Undo)
///   or `commit` (the toast timed out, was replaced or swiped away, or `flushPending()` ran) is called.
///   The stores no longer use it: delete and send commit at once and their Undo is the inverse.
/// - `show(error:)`: maps any error to friendly copy (QuotedError, offline) and ignores cancellation.
///
/// A new toast replaces the current one (committing a pending deferred change first). Each sheet adds
/// `.toastHost()` so toasts appear above it; only the most recently attached host draws the toast.
///
/// Accessibility (WCAG 2.2.1, timing adjustable): while VoiceOver or Switch Control is running, a toast
/// with an action stays ten times as long, VoiceOver focus moves to it, and it never closes while
/// VoiceOver is on it. The toast is one element ("Quote deleted. Undo, button"): double-tap, the
/// action in the Actions rotor or a Magic Tap runs Undo; the Dismiss action or the escape gesture
/// closes it. Every toast is announced, an actionable one as "Quote deleted. Undo available."
@Observable
@MainActor
final class ToastCenter {
    /// The toast on screen, if any.
    private(set) var current: Toast?
    /// The host that draws toasts: the last one registered (the topmost sheet, else the root).
    private(set) var activeHostID: UUID?
    /// The height of a bar the screen on top pins above the tab bar (the empty Feed's guidance and
    /// Add a friend), which the tab-bar host's toasts stay clear of. The screen sets it while it is on
    /// screen (`View.reportsPinnedBarHeight()`); 0 otherwise.
    var pinnedBarHeight: CGFloat = 0

    private var action: (@MainActor () async -> Void)?
    private var pendingCommit: (@MainActor () async -> Void)?
    private var timer: Task<Void, Never>?
    private var hosts: [UUID] = []
    private let announces: Bool

    /// Default durations: 4 s for messages, 5 s when there is an Undo.
    static let messageDuration: Duration = .seconds(4)
    static let undoDuration: Duration = .seconds(5)
    /// How many times longer a toast with an action stays while VoiceOver or Switch Control is
    /// running (WCAG 2.2.1 asks for at least ten times the default), so Undo can be reached in time.
    static let assistiveDurationFactor = 10

    /// Whether VoiceOver or Switch Control is running right now.
    static var isAssistiveTechnologyRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    init(announces: Bool = true) {
        self.announces = announces
    }

    // MARK: Showing

    /// Shows a plain message.
    func show(_ message: String, style: Toast.Style = .info, duration: Duration = ToastCenter.messageDuration) {
        present(message, style: style, actionTitle: nil, duration: duration, action: nil, commit: nil)
    }

    /// Shows a message with a button (default "Undo") that runs `action`. The change has already
    /// happened; `action` reverses it.
    func show(
        _ message: String,
        actionTitle: String = "Undo",
        duration: Duration = ToastCenter.undoDuration,
        action: @escaping @MainActor () async -> Void
    ) {
        present(message, style: .info, actionTitle: actionTitle, duration: duration, action: action, commit: nil)
    }

    /// Shows a message for a change that is not committed yet. Exactly one of `undo` or `commit` runs:
    /// `undo` if the user taps Undo, otherwise `commit` once the toast closes for any reason.
    func showDeferred(
        _ message: String,
        actionTitle: String = "Undo",
        duration: Duration = ToastCenter.undoDuration,
        undo: @escaping @MainActor () async -> Void,
        commit: @escaping @MainActor () async -> Void
    ) {
        present(message, style: .info, actionTitle: actionTitle, duration: duration, action: undo, commit: commit)
    }

    /// Shows the friendly message for an error. `CancellationError` shows nothing.
    func show(error: any Error) {
        guard let message = Self.message(for: error) else { return }
        Logger.ui.error("Toast for error: \(String(describing: error), privacy: .public)")
        Haptics.error()
        show(message, style: .error)
    }

    /// The copy `show(error:)` uses, or nil for cancellation.
    nonisolated static func message(for error: any Error) -> String? {
        if error is CancellationError { return nil }
        let mapped = QuotedError(error)
        if mapped == .network { return "You're offline. Try again when connected." }
        return mapped.userMessage
    }

    // MARK: Closing

    /// Runs the toast's action (Undo) and closes it. A deferred change is not committed.
    func performAction() {
        guard current != nil else { return }
        let action = self.action
        pendingCommit = nil
        close()
        if let action {
            Task { await action() }
        }
    }

    /// Closes the toast. A pending deferred change is committed.
    func dismiss() {
        let commit = pendingCommit
        pendingCommit = nil
        close()
        if let commit {
            Task { await commit() }
        }
    }

    /// Commits a pending deferred change now and closes its toast. Call before the app goes to the
    /// background and before signing out.
    func flushPending() async {
        guard let commit = pendingCommit else { return }
        pendingCommit = nil
        close()
        await commit()
    }

    /// Clears everything without committing (after sign-out).
    func reset() {
        pendingCommit = nil
        close()
    }

    // MARK: Accessibility

    /// VoiceOver focus moved onto or off the toast `id`. While focused it never closes on its own;
    /// when focus leaves, it gets its full time again. Called by `.toastHost()`.
    func accessibilityFocusChanged(_ isFocused: Bool, toastID id: UUID) {
        guard let current, current.id == id else { return }
        timer?.cancel()
        timer = nil
        if !isFocused {
            startTimer(for: current)
        }
    }

    /// What VoiceOver announces for a toast: "Quote deleted. Undo available." when it has an action.
    nonisolated static func announcement(message: String, actionTitle: String?) -> String {
        guard let actionTitle else { return message }
        return "\(sentence(message)) \(actionTitle) available."
    }

    /// `message` ending in a full stop, so VoiceOver pauses before what follows it.
    nonisolated static func sentence(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?\u{2026}".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// The time a toast stays: lengthened for a toast with an action while assistive technology runs.
    static func lifetime(for duration: Duration, hasAction: Bool, assistive: Bool) -> Duration {
        hasAction && assistive ? duration * assistiveDurationFactor : duration
    }

    // MARK: Hosts

    /// Registers a toast host and makes it the active one. Called by `.toastHost()`.
    func registerHost() -> UUID {
        let id = UUID()
        hosts.append(id)
        activeHostID = id
        return id
    }

    /// Removes a toast host. Called by `.toastHost()`.
    func unregisterHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        activeHostID = hosts.last
    }

    // MARK: Private

    private func present(
        _ message: String,
        style: Toast.Style,
        actionTitle: String?,
        duration: Duration,
        action: (@MainActor () async -> Void)?,
        commit: (@MainActor () async -> Void)?
    ) {
        // A newer toast replaces the current one; commit what the old one was holding.
        if let previous = pendingCommit {
            pendingCommit = nil
            Task { await previous() }
        }
        timer?.cancel()
        let lifetime = Self.lifetime(
            for: duration,
            hasAction: actionTitle != nil,
            assistive: announces && Self.isAssistiveTechnologyRunning
        )
        let toast = Toast(id: UUID(), message: message, style: style, actionTitle: actionTitle, duration: lifetime)
        current = toast
        self.action = action
        pendingCommit = commit
        if announces {
            // The host also moves VoiceOver focus to an actionable toast, which reads it again; the
            // announcement covers the case where focus cannot move (and Switch Control speech).
            AccessibilityNotification.Announcement(Self.announcement(message: message, actionTitle: actionTitle)).post()
        }
        startTimer(for: toast)
    }

    private func startTimer(for toast: Toast) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled else { return }
            self?.expire(toast.id)
        }
    }

    private func expire(_ id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }

    private func close() {
        timer?.cancel()
        timer = nil
        action = nil
        current = nil
    }
}

// MARK: Host

/// What a toast host keeps its toast clear of at the bottom of the screen.
enum ToastClearance: Equatable, Sendable {
    /// A fixed space above the bottom safe area (sheets: `Theme.Spacing.m`).
    case fixed(CGFloat)
    /// iOS 26's floating tab bar (the signed-in shell, whose host sits outside the `TabView`).
    case tabBar
    /// A `PrimaryButton` pinned to the bottom of the screen (onboarding's Continue).
    case bottomButton

    /// The floating tab bar's top edge, measured from the bottom edge of the screen. It is the same on
    /// every iPhone, about 83 pt: on Face ID phones the bar sits inside the 34-pt home-indicator inset,
    /// on Home-button phones (iPhone SE, no inset) it sits higher above the screen edge. So the
    /// space the toast needs above the host's safe area depends on that inset.
    static let tabBarTopFromScreenBottom: CGFloat = 83

    /// The space between the toast and what it clears.
    static let gap: CGFloat = Theme.Spacing.m

    /// The bottom padding for a host whose bottom safe-area inset is `safeAreaBottom`, with a pinned
    /// primary button `buttonHeight` tall (it grows with Dynamic Type).
    func bottomPadding(safeAreaBottom: CGFloat, buttonHeight: CGFloat, pinnedBarHeight: CGFloat = 0) -> CGFloat {
        switch self {
        case .fixed(let padding):
            padding
        case .tabBar:
            // With the keyboard up the inset is the keyboard, which hides the bar: just a small gap.
            // A screen's bar pinned above the tab bar (`ToastCenter.pinnedBarHeight`) adds its height.
            max(Theme.Spacing.xs, Self.tabBarTopFromScreenBottom + Self.gap - safeAreaBottom) + pinnedBarHeight
        case .bottomButton:
            // The onboarding bars pin the button `Theme.Spacing.m` above the safe area.
            buttonHeight + Theme.Spacing.m + Theme.Spacing.xs
        }
    }
}

extension View {
    /// Draws `ToastCenter` toasts over this view. The shell applies it to the root and to every sheet
    /// it presents; add it to the root of any sheet or full-screen cover you present yourself.
    ///
    /// - Parameter bottomPadding: Space below the toast, above the bottom safe area.
    func toastHost(bottomPadding: CGFloat = Theme.Spacing.m) -> some View {
        modifier(ToastHostModifier(clearance: .fixed(bottomPadding)))
    }

    /// Draws `ToastCenter` toasts over this view, clear of `clearance` (the root: the tab bar once
    /// signed in, the pinned Continue button during onboarding).
    func toastHost(clearance: ToastClearance) -> some View {
        modifier(ToastHostModifier(clearance: clearance))
    }

    /// Reports this bar's height (`ToastCenter.pinnedBarHeight`) while it is on screen, so the shell's
    /// toasts sit above it instead of over its button. Apply it to the content of a tab root's bottom
    /// `.safeAreaBar`.
    func reportsPinnedBarHeight() -> some View {
        modifier(PinnedBarHeightReporter())
    }
}

private struct PinnedBarHeightReporter: ViewModifier {
    @Environment(ToastCenter.self) private var center
    @State private var height: CGFloat = 0
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                height = newHeight
                if isVisible { center.pinnedBarHeight = newHeight }
            }
            .onAppear {
                isVisible = true
                center.pinnedBarHeight = height
            }
            .onDisappear {
                isVisible = false
                center.pinnedBarHeight = 0
            }
    }
}

private struct ToastHostModifier: ViewModifier {
    let clearance: ToastClearance
    @Environment(ToastCenter.self) private var center
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var hostID: UUID?
    /// The host's bottom safe-area inset: the home indicator (0 on Home-button phones), or the
    /// keyboard while it is up.
    @State private var safeAreaBottom: CGFloat = 0
    /// A `PrimaryButton`'s height at the current text size (52 pt by default; it wraps and grows at
    /// accessibility sizes).
    @ScaledMetric(relativeTo: .headline) private var buttonHeight: CGFloat = Theme.Metrics.primaryButtonHeight

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.bottom
            } action: { inset in
                safeAreaBottom = inset
            }
            .overlay(alignment: .bottom) {
                if let toast = center.current, hostID != nil, hostID == center.activeHostID {
                    ToastView(
                        toast: toast,
                        onAction: { center.performAction() },
                        onDismiss: { center.dismiss() },
                        takesAccessibilityFocus: voiceOverEnabled && toast.actionTitle != nil,
                        onAccessibilityFocusChange: { center.accessibilityFocusChanged($0, toastID: toast.id) }
                    )
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.bottom, clearance.bottomPadding(
                        safeAreaBottom: safeAreaBottom,
                        buttonHeight: max(buttonHeight, Theme.Metrics.primaryButtonHeight),
                        pinnedBarHeight: center.pinnedBarHeight
                    ))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                }
            }
            .animation(.snappy, value: center.current?.id)
            .onAppear {
                if hostID == nil { hostID = center.registerHost() }
            }
            .onDisappear {
                if let hostID { center.unregisterHost(hostID) }
                hostID = nil
            }
    }
}

/// The toast capsule: Liquid Glass, an optional status glyph, the message and the action.
///
/// For assistive technology the capsule is one element: "Quote deleted. Undo, button". Double-tap,
/// the named action or a Magic Tap runs the action; "Dismiss" and the escape gesture close it.
struct ToastView: View {
    let toast: Toast
    var onAction: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// Moves VoiceOver focus to the toast when it appears (actionable toasts, VoiceOver on).
    var takesAccessibilityFocus = false
    /// Called when VoiceOver focus enters or leaves the toast (it stays open while focused).
    var onAccessibilityFocusChange: (Bool) -> Void = { _ in }

    @AccessibilityFocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// How long the toast waits after appearing before taking VoiceOver focus, so the element exists
    /// in the accessibility tree and the screen change from the action has settled.
    private static let focusDelay: Duration = .milliseconds(350)

    /// The glass tint: mostly Surface, so the capsule stays glass but whatever scrolls under it
    /// can't be read through it.
    static let glassTint = Color.surface.opacity(0.9)

    var body: some View {
        capsule
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .modifier(ToastAccessibilityActions(actionTitle: toast.actionTitle, onAction: onAction, onDismiss: onDismiss))
            .accessibilityFocused($isFocused)
            .onChange(of: isFocused) { _, focused in
                onAccessibilityFocusChange(focused)
            }
            .task {
                guard takesAccessibilityFocus else { return }
                try? await Task.sleep(for: Self.focusDelay)
                guard !Task.isCancelled else { return }
                isFocused = true
            }
    }

    private var capsule: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let glyph {
                Image(systemName: glyph)
                    .foregroundStyle(toast.style == .error ? AnyShapeStyle(.red) : AnyShapeStyle(Color.accentColor))
            }
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = toast.actionTitle {
                Button(action: onAction) {
                    // The 44-pt target lives inside the label: a frame outside a Button adds layout
                    // space, not hit area.
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, Theme.Spacing.m)
        .padding(.trailing, toast.actionTitle == nil ? Theme.Spacing.m : Theme.Spacing.xxs)
        .padding(.vertical, toast.actionTitle == nil ? Theme.Spacing.s : 0)
        .frame(minHeight: Theme.Metrics.minTouchTarget + 4)
        // Tinted with Surface so the rows behind wash out instead of reading through the message
        // and the Undo (plain `.regular` glass is clear enough to read a quote through it).
        .glassEffect(.regular.tint(Self.glassTint), in: shape)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height > 20 { onDismiss() }
            }
        )
    }

    /// A capsule; at accessibility text sizes the message wraps onto several lines, so the ends stay
    /// 24-pt rounded corners instead of turning the toast into an oval that clips the text.
    private var shape: AnyShape {
        dynamicTypeSize.isAccessibilitySize
            ? AnyShape(RoundedRectangle(cornerRadius: Theme.Spacing.l, style: .continuous))
            : AnyShape(Capsule())
    }

    /// "Quote deleted. Undo" (VoiceOver adds "button"), or just the message.
    private var accessibilityLabel: Text {
        guard let actionTitle = toast.actionTitle else { return Text(toast.message) }
        return Text("\(ToastCenter.sentence(toast.message)) \(actionTitle)")
    }

    private var glyph: String? {
        switch toast.style {
        case .info: nil
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

/// The toast's accessibility actions. With an action: it is the button's activation, a named action
/// and the Magic Tap. Always: "Dismiss" and the escape gesture.
private struct ToastAccessibilityActions: ViewModifier {
    let actionTitle: String?
    let onAction: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        if let actionTitle {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onAction)
                .accessibilityAction(.magicTap, onAction)
                .accessibilityAction(named: Text(actionTitle), onAction)
                .accessibilityAction(named: "Dismiss", onDismiss)
                .accessibilityAction(.escape, onDismiss)
        } else {
            content
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss", onDismiss)
                .accessibilityAction(.escape, onDismiss)
        }
    }
}

#Preview("Toasts") {
    VStack(spacing: Theme.Spacing.m) {
        Spacer()
        ToastView(toast: Toast(id: UUID(), message: "Sent to Maya", style: .info, actionTitle: "Undo", duration: .seconds(5)))
        ToastView(toast: Toast(id: UUID(), message: "Saved to your library", style: .success, actionTitle: nil, duration: .seconds(4)))
        ToastView(toast: Toast(id: UUID(), message: "You're offline. Try again when connected.", style: .error, actionTitle: nil, duration: .seconds(4)))
    }
    .padding(Theme.Spacing.gutter)
    .groundBackground()
}

#Preview("Toast host") {
    @Previewable @State var center = ToastCenter(announces: false)
    VStack(spacing: Theme.Spacing.m) {
        Button("Show message") { center.show("Request sent to @maya") }
        Button("Show undo") { center.show("Removed from reminders") {} }
        Button("Show error") { center.show(error: QuotedError.network) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .groundBackground()
    .toastHost()
    .environment(center)
}
