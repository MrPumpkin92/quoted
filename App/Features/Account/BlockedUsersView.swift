import QuotedCore
import SwiftUI

/// The people you blocked, each with Unblock (after a confirmation that says what does and doesn't
/// come back) and, from the context menu or VoiceOver actions, Report. Loads with
/// `SocialStore.loadBlocked()`; pull to reload. `Route.blockedUsers` maps to `BlockedUsersView()`.
struct BlockedUsersView: View {
    @Environment(SocialStore.self) private var social

    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var unblockTarget: Profile?
    @State private var reportTarget: Profile?

    init() {}

    var body: some View {
        BlockedUsersContent(
            profiles: social.blockedProfiles,
            isLoading: !hasLoaded,
            loadFailed: loadFailed,
            onRetry: { Task { await load() } },
            onUnblock: { unblockTarget = $0 },
            onReport: { reportTarget = $0 }
        )
        .navigationTitle("Blocked users")
        .refreshable {
            loadFailed = !(await social.loadBlocked())
        }
        .task {
            await load()
        }
        .confirmationDialog(
            "Unblock \(unblockTarget?.handle ?? "this person")?",
            isPresented: isConfirmingUnblock,
            titleVisibility: .visible,
            presenting: unblockTarget
        ) { profile in
            Button("Unblock") {
                Task { await social.unblock(profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("\(profile.displayName) will be able to find you and send you friend requests again. Your old friendship and shared quotes don\u{2019}t come back.")
        }
        .reportUserConfirmation(item: $reportTarget, context: .blockedUser)
    }

    /// Loads the list; a failure shows inline with Try again (instead of "No blocked users").
    private func load() async {
        loadFailed = !(await social.loadBlocked(toastOnFailure: false))
        hasLoaded = true
    }

    private var isConfirmingUnblock: Binding<Bool> {
        Binding(
            get: { unblockTarget != nil },
            set: { if !$0 { unblockTarget = nil } }
        )
    }
}

/// The list itself, separate from loading so previews can show sample people.
private struct BlockedUsersContent: View {
    let profiles: [Profile]
    let isLoading: Bool
    var loadFailed = false
    var onRetry: () -> Void = {}
    let onUnblock: (Profile) -> Void
    var onReport: (Profile) -> Void = { _ in }

    private var separatorInset = SocialSeparatorInset()

    var body: some View {
        if profiles.isEmpty {
            ScrollView {
                if isLoading {
                    DelayedProgressView(label: "Loading blocked users")
                        .padding(.top, Theme.Spacing.xxl)
                        .frame(maxWidth: .infinity)
                } else if loadFailed {
                    EmptyStateView(
                        systemImage: "exclamationmark.icloud",
                        title: "Couldn\u{2019}t load blocked users",
                        message: "Check your connection and try again.",
                        actionTitle: "Try again",
                        action: onRetry
                    )
                } else {
                    EmptyStateView(
                        systemImage: "hand.raised",
                        title: "No blocked users",
                        message: "People you block can\u{2019}t send you friend requests or quotes. Block someone from a shared quote\u{2019}s \u{2026} menu or by pressing and holding a friend."
                    )
                }
            }
            .groundBackground()
        } else {
            List {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    BlockedUserRow(profile: profile, onReport: { onReport(profile) }) { onUnblock(profile) }
                        .contextMenu {
                            Button("Report \(profile.handle)\u{2026}", systemImage: "flag") { onReport(profile) }
                        }
                        .marginCardRow(
                            MarginCardPosition(index: index, count: profiles.count),
                            separatorInset: separatorInset.value,
                            outerSpacing: Theme.Spacing.xs
                        )
                }
                Text("Blocked people can\u{2019}t find you, send you friend requests or send you quotes. They aren\u{2019}t told that you blocked them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .marginPlainRow(top: Theme.Spacing.xs, bottom: Theme.Spacing.l)
            }
            .marginCardList()
        }
    }
}

/// One blocked person with an Unblock button (which moves under the name at large text sizes).
/// Report is a VoiceOver action on the person (the row's context menu has it for everyone else).
private struct BlockedUserRow: View {
    let profile: Profile
    let onReport: () -> Void
    let onUnblock: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                person
                Spacer(minLength: Theme.Spacing.xs)
                unblockButton
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                person
                unblockButton
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var person: some View {
        SocialPersonLabel(profile: profile)
            .accessibilityActions {
                Button("Report\u{2026}", action: onReport)
            }
    }

    private var unblockButton: some View {
        Button(action: onUnblock) {
            Text("Unblock")
                .capsuleButtonLabel()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color.primary)
        .fixedSize()
        .accessibilityLabel("Unblock \(profile.displayName)")
    }
}

#Preview("Blocked users") {
    NavigationStack {
        BlockedUsersContent(profiles: [Samples.sam, Samples.riley], isLoading: false, onUnblock: { _ in })
            .navigationTitle("Blocked users")
    }
    .previewEnvironment()
}

#Preview("Blocked users empty") {
    NavigationStack {
        BlockedUsersContent(profiles: [], isLoading: false, onUnblock: { _ in })
            .navigationTitle("Blocked users")
    }
    .previewEnvironment()
}
