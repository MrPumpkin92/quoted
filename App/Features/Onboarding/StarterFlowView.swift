// The starter pack (docs/ui-spec.md §3) and notification priming (§4), in onboarding.
//
// RootView shows `StarterFlowView()` while `SessionStore.phase == .needsStarter`: pick quotes →
// import them → priming → `SessionStore.completeOnboarding()`. Skip completes onboarding with an
// empty library. It offers only the starters (`StarterStore`, `starter_quotes`); after onboarding,
// Verified Quotes (`VerifiedQuotesView`) offers the whole catalog.

import QuotedCore
import SwiftUI

struct StarterFlowView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(ReminderStore.self) private var reminders
    @Environment(StarterStore.self) private var starter

    @State private var step: Step = .pick
    @State private var isImporting = false
    @State private var isRequestingPermission = false

    private enum Step: Equatable {
        case pick
        /// Priming, with a sample notification built from one of the picked quotes.
        case priming(sample: NotificationQuote)
    }

    init() {}

    var body: some View {
        ZStack {
            switch step {
            case .pick:
                NavigationStack {
                    StarterPickerView(isImporting: isImporting) { picked in
                        importQuotes(picked)
                    } onSkip: {
                        session.completeOnboarding()
                    }
                }
                .transition(.opacity)
            case .priming(let sample):
                NotificationPrimingView(
                    sample: sample,
                    settings: reminders.settings,
                    isRequesting: isRequestingPermission
                ) {
                    allowNotifications()
                } onNotNow: {
                    session.completeOnboarding()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    // MARK: Actions

    /// Imports the picked quotes (in list order) into the library and the end of the reminders.
    /// A failure already showed a toast, so the picker stays open, and reloads the starters: the server
    /// adds only live ones and fails the whole add for any other (23503), so one retired since the
    /// pack loaded drops out of the list and the count instead of failing every Continue.
    private func importQuotes(_ picked: [StarterQuote]) {
        guard !isImporting, !picked.isEmpty else { return }
        isImporting = true
        Task {
            let imported = await library.importStarter(picked)
            guard imported else {
                await starter.load(force: true)
                isImporting = false
                return
            }
            await reminders.refreshPermission()
            isImporting = false
            if reminders.permission == .notDetermined, let first = picked.first {
                step = .priming(sample: NotificationQuote(id: UUID(), body: first.body, author: first.author))
            } else {
                // Already allowed or denied in Settings: the system prompt can't show again, and
                // the Library status card covers the denied state.
                session.completeOnboarding()
            }
        }
    }

    private func allowNotifications() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task {
            await reminders.requestAuthorization()
            isRequestingPermission = false
            session.completeOnboarding()
        }
    }
}

// MARK: - Picker

/// "Pick a few to start": every starter quote as a tappable row with a check circle, and a
/// "Continue with N quotes" button pinned to the bottom.
private struct StarterPickerView: View {
    let isImporting: Bool
    let onContinue: ([StarterQuote]) -> Void
    let onSkip: () -> Void

    @Environment(StarterStore.self) private var starter
    @Environment(LibraryStore.self) private var library

    /// Picked starter IDs, in the order they were tapped.
    @State private var picked: [Int] = []
    /// Set once the first load attempt finished, to tell "still loading" from "nothing came back".
    @State private var didLoad = false

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("They'll show up in your widget and reminders.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                // The seal on library rows means the same; here every row has it, so it's said once.
                Label {
                    Text("Every quote is checked word for word against its source.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .listRowSeparator(.hidden, edges: .top)
            .groundListRow()
            content
        }
        .listStyle(.plain)
        .groundBackground()
        .navigationTitle("Pick a few to start")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Skip", action: onSkip)
                    .disabled(isImporting)
            }
        }
        .safeAreaBar(edge: .bottom) {
            if !starter.quotes.isEmpty {
                PrimaryButton(continueTitle, isLoading: isImporting) {
                    onContinue(pickedQuotes)
                }
                .disabled(pickedQuotes.isEmpty)
                // The disabled button is translucent; keep the rows from showing through it.
                .background(Color.ground, in: Capsule())
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.m)
            }
        }
        .sensoryFeedback(.selection, trigger: picked)
        .task {
            await starter.load()
            didLoad = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if starter.quotes.isEmpty {
            Group {
                if let error = starter.lastError, !starter.isLoading {
                    loadError(ToastCenter.message(for: error) ?? error.userMessage)
                } else if didLoad, !starter.isLoading {
                    loadError("The starter pack isn't available right now.")
                } else {
                    DelayedProgressView(label: "Loading the starter pack")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .listRowBackground(Color.ground)
            .listRowSeparator(.hidden)
        } else {
            ForEach(starter.quotes) { quote in
                SelectableQuoteRow(
                    quote: quote,
                    isSelected: picked.contains(quote.id),
                    isOwned: library.contains(starter: quote)
                ) {
                    toggle(quote.id)
                }
                .disabled(isImporting)
                .groundListRow()
            }
        }
    }

    private func loadError(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                Task { await starter.load(force: true) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, Theme.Spacing.l)
    }

    /// The picked quotes not already in the library. After a failed import whose insert did land, a
    /// refresh brings those quotes in; they show as owned and must not count or import again.
    private var pickedQuotes: [StarterQuote] {
        starter.quotes.filter { picked.contains($0.id) && !library.contains(starter: $0) }
    }

    private var continueTitle: LocalizedStringKey {
        let count = pickedQuotes.count
        switch count {
        case 0: return "Continue"
        case 1: return "Continue with 1 quote"
        default: return "Continue with \(count) quotes"
        }
    }

    private func toggle(_ id: Int) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }
}

// MARK: - Notification priming

/// "Your quotes, a few times a day": a sample notification with one of the picked quotes, the schedule
/// in plain words, Allow notifications (the system prompt) and Not now.
private struct NotificationPrimingView: View {
    /// The quote the sample notification shows, laid out as iOS will show it.
    let sample: NotificationQuote
    let settings: ReminderSettings
    let isRequesting: Bool
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Your quotes, a few times a day")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    SampleNotification(quote: sample)
                        .padding(.vertical, Theme.Spacing.s)
                    Text(scheduleText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipped()

            VStack(spacing: Theme.Spacing.xs) {
                PrimaryButton("Allow notifications", isLoading: isRequesting, action: onAllow)
                Button(action: onNotNow) {
                    Text("Not now")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.m)
        }
        .groundBackground()
    }

    /// "Quoted will show you 3 of your quotes a day, between 8 AM and 9 PM. You can change this anytime."
    private var scheduleText: String {
        let sanitized = settings.sanitized
        let count = sanitized.timesPerDay
        let start = Self.timeText(minutes: sanitized.windowStart)
        let end = Self.timeText(minutes: sanitized.windowEnd)
        let amount = count == 1 ? "1 of your quotes a day, at \(start)" : "\(count) of your quotes a day, between \(start) and \(end)"
        return "Quoted will show you \(amount). You can change this anytime."
    }

    /// "8 AM", or "8:30 AM" when the minutes aren't zero (locale-aware).
    private static func timeText(minutes: Int) -> String {
        let date = ReminderSettings.date(minutes: minutes)
        return minutes % 60 == 0
            ? date.formatted(.dateTime.hour())
            : date.formatted(.dateTime.hour().minute())
    }
}

/// A plain-text look-alike of an iOS notification banner (notifications can't render runs or serif):
/// "Quoted", the author as the subtitle, then the quote.
private struct SampleNotification: View {
    let quote: NotificationQuote

    private var subtitle: String? { NotificationScheduler.subtitleText(for: quote) }
    private var text: String { NotificationScheduler.bodyText(for: quote) }

    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 38

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Text(verbatim: "Q")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Color.onAccent)
                .frame(width: iconSize, height: iconSize)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Quoted")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: Theme.Spacing.xs)
                    Text("now")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(verbatim: text)
                    .font(.subheadline)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.s + Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sample notification from Quoted: \([text, subtitle].compactMap(\.self).joined(separator: ", "))"))
    }
}

// MARK: - Previews

#Preview("Starter pack, onboarding") {
    StarterFlowView()
        .previewEnvironment(.preview(phase: .needsStarter, emptyLibrary: true))
}

#Preview("Starter pack, dark, large type") {
    StarterFlowView()
        .previewEnvironment(.preview(phase: .needsStarter, emptyLibrary: true))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Notification priming") {
    NotificationPrimingView(
        sample: NotificationQuote(id: UUID(), body: "Beware; for I am fearless, and therefore powerful.", author: "Mary Shelley"),
        settings: .default,
        isRequesting: false,
        onAllow: {},
        onNotNow: {}
    )
    .previewEnvironment(.preview(phase: .needsStarter))
}

#Preview("Notification priming, dark") {
    NotificationPrimingView(
        sample: NotificationQuote(
            id: UUID(),
            body: "Hope is the thing with feathers\nThat perches in the soul,\nAnd sings the tune without the words,\nAnd never stops at all.",
            author: "Emily Dickinson"
        ),
        settings: .default,
        isRequesting: true,
        onAllow: {},
        onNotNow: {}
    )
    .previewEnvironment(.preview(phase: .needsStarter))
    .preferredColorScheme(.dark)
}
