import QuotedCore
import SwiftUI

/// The people you blocked, each with Unblock (after a confirmation that says what does and doesn't
/// come back, docs/ui-spec.md §12) and, from the context menu or VoiceOver actions, Report. Someone
/// who blocked you back is listed too, as "Blocked account" (the server no longer shows you their
/// profile), with Unblock only; their confirmation claims nothing about what they can do, since
/// their own block still keeps you apart. Loads with `SocialStore.loadBlocked()`; pull to reload.
/// `Route.blockedUsers` maps to `BlockedUsersView()`.
struct BlockedUsersView: View {
    @Environment(SocialStore.self) private var social

    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var unblockTarget: BlockedUser?
    @State private var reportTarget: Profile?

    init() {}

    var body: some View {
        BlockedUsersContent(
            users: social.blockedUsers,
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
            unblockTarget?.profile.map { "Unblock \($0.handle)?" } ?? "Unblock this account?",
            isPresented: isConfirmingUnblock,
            titleVisibility: .visible,
            presenting: unblockTarget
        ) { user in
            Button("Unblock") {
                Task { await social.unblock(user) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text(Self.unblockMessage(for: user))
        }
        .reportUserConfirmation(item: $reportTarget, context: .blockedUser)
    }

    /// What Unblock changes (docs/ui-spec.md §12). Blocking deleted the friendship and closed the
    /// conversation but kept its messages, so nothing shared "comes back": it never left. Someone
    /// whose profile you can't see blocked you too, and their block still stops the username lookup
    /// and friend requests both ways (`private.is_blocked_pair`), so their copy promises nothing.
    static func unblockMessage(for user: BlockedUser) -> String {
        if let profile = user.profile {
            "\(profile.handle) can find you by username and send a friend request again. Your old conversation reopens only if you become friends again."
        } else {
            "You can find each other again only if neither of you blocks the other. Your old conversation reopens only if you become friends again."
        }
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
    let users: [BlockedUser]
    let isLoading: Bool
    var loadFailed = false
    var onRetry: () -> Void = {}
    let onUnblock: (BlockedUser) -> Void
    var onReport: (Profile) -> Void = { _ in }

    private var separatorInset = SocialSeparatorInset()

    var body: some View {
        if users.isEmpty {
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
                        message: "People you block can\u{2019}t find you by username or send you friend requests or quotes. Block someone from the \u{2026} menu next to their name or on a quote they shared."
                    )
                }
            }
            .groundBackground()
        } else {
            List {
                ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                    BlockedUserRow(user: user, onReport: onReport) { onUnblock(user) }
                        .contextMenu {
                            if let profile = user.profile {
                                Button("Report \(profile.handle)\u{2026}", systemImage: "flag") { onReport(profile) }
                            }
                        }
                        .marginCardRow(
                            MarginCardPosition(index: index, count: users.count),
                            separatorInset: separatorInset.value,
                            outerSpacing: Theme.Spacing.xs
                        )
                }
                // Each claim holds on the server (docs/ui-spec.md §12): the username lookup returns
                // nothing for a blocked pair (the same as for a name nobody has), and friend requests
                // to or from one fail like one to an unknown user; profile_view, posts, playlists and
                // favorites are hidden across a block; the block deleted the friendship and closed
                // the conversation (its messages stay), and only a new friendship reopens it.
                // Nothing notifies the blocked person.
                Text("People you block can\u{2019}t find you by username, see your profile, posts, playlists or favorites, or message you. They aren\u{2019}t told. Unblocking doesn\u{2019}t make you friends again or reopen your conversation.")
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
/// Someone who blocked you back shows as "Blocked account", without Report.
private struct BlockedUserRow: View {
    let user: BlockedUser
    let onReport: (Profile) -> Void
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

    @ViewBuilder
    private var person: some View {
        if let profile = user.profile {
            SocialPersonLabel(profile: profile)
                .accessibilityActions {
                    Button("Report\u{2026}") { onReport(profile) }
                }
        } else {
            UnavailablePersonLabel()
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
        .accessibilityLabel("Unblock \(user.profile?.displayName ?? "blocked account")")
    }
}

/// A blocked person whose profile you can no longer see (they blocked you too), in the place of
/// `SocialPersonLabel`.
private struct UnavailablePersonLabel: View {
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = SocialPersonLabel.avatarSize

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "person.slash")
                .foregroundStyle(.secondary)
                .frame(width: avatarSize, height: avatarSize)
                .background(Circle().fill(Color(.tertiarySystemFill)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Blocked account")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("Their profile isn\u{2019}t available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blocked account. Their profile isn\u{2019}t available.")
    }
}

#Preview("Blocked users") {
    NavigationStack {
        BlockedUsersContent(
            users: [BlockedUser(Samples.sam), BlockedUser(Samples.riley), BlockedUser(id: UUID())],
            isLoading: false,
            onUnblock: { _ in }
        )
            .navigationTitle("Blocked users")
    }
    .previewEnvironment()
}

#Preview("Blocked users empty") {
    NavigationStack {
        BlockedUsersContent(users: [], isLoading: false, onUnblock: { _ in })
            .navigationTitle("Blocked users")
    }
    .previewEnvironment()
}
