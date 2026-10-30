import QuotedCore
import SwiftUI

/// The Inbox tab root (docs/ui-spec.md §20), the one badged tab.
///
/// Top to bottom: the requests row while incoming requests wait (it pushes Friends scrolled to
/// Requests), then the quotes friends sent you, newest first, as cards with the sender's note, Save
/// (or Saved), and Report / Block in the "…" menu; swipe right to save, left to block or report.
/// Conversation rows replace the cards in Stage 5. The toolbar's Friends button (`person.2`) pushes
/// Friends. Empty: "No messages yet", with a filled Add a friend and a quiet Share my username when
/// you have no friends (with friends, Send a quote waits for the Stage 5 picker).
///
/// Opening the Inbox marks the quotes it shows as seen (`SocialStore.markInboxSeen()`), which clears
/// their conversations from the badge; quotes that arrive while it is on screen count as seen too. It
/// refreshes on appear and on pull to refresh.
struct InboxView: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router

    @State private var isVisible = false
    @State private var confirmation: SocialConfirmation?

    /// The cards show whole quotes, at every text size: there is no detail screen to read the rest in.
    private static let fullQuoteLineLimit = Int.max

    init() {}

    var body: some View {
        List {
            requestsRow
            quotes
        }
        .marginCardList()
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.push(.friends(.list))
                } label: {
                    Label("Friends", systemImage: "person.2")
                }
                .accessibilityIdentifier("inbox.friends")
            }
        }
        .refreshable {
            await social.refresh(userInitiated: true)
        }
        .task {
            await social.refresh()
        }
        .onAppear {
            isVisible = true
            markQuotesSeen()
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: social.unseenCount) {
            // Quotes that arrive while the Inbox is on screen count as seen too.
            if isVisible { markQuotesSeen() }
        }
    }

    // MARK: Requests

    @ViewBuilder
    private var requestsRow: some View {
        let requests = social.incomingRequests
        if !requests.isEmpty {
            NavigationLink(value: Route.friends(.requests)) {
                FriendRequestsSummary(requests: requests)
            }
            .accessibilityHint("Opens Friends")
            .marginCardRow(.single, outerSpacing: Theme.Spacing.xs)
        }
    }

    // MARK: Quotes

    @ViewBuilder
    private var quotes: some View {
        if !social.inbox.isEmpty {
            ForEach(social.inbox) { share in
                SharedQuoteCard(
                    share: share,
                    lineLimit: Self.fullQuoteLineLimit,
                    confirmation: $confirmation
                )
                .marginCardRow(.single, outerSpacing: 6)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !library.containsCopy(of: share), !social.reportedMessageIDs.contains(share.id) {
                        Button {
                            Task { await library.saveShared(share, addToReminders: true) }
                        } label: {
                            Label("Save", systemImage: "bookmark")
                        }
                        .tint(Color.accentColor)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        confirmation = .blockSender(shareID: share.id)
                    } label: {
                        Label("Block", systemImage: "hand.raised")
                    }
                    .tint(SwipeTint.block)
                    Button {
                        confirmation = .report(shareID: share.id)
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    .tint(SwipeTint.report)
                }
            }
            Text("Saved quotes go to your library and your reminders.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .marginPlainRow(top: Theme.Spacing.s, bottom: Theme.Spacing.l)
        } else if social.hasLoaded {
            emptyState
                .marginPlainRow()
        } else if let error = social.lastError {
            MarginCardMessage(
                systemImage: "wifi.exclamationmark",
                title: "Couldn\u{2019}t load your messages",
                message: Text(error.friendlyMessage)
            ) {
                Button {
                    Task { await social.refresh(userInitiated: true) }
                } label: {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text("Try again")
                        .capsuleButtonLabel()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.top, Theme.Spacing.xxs)
            }
            .marginCardRow(.single, outerSpacing: Theme.Spacing.xs)
        } else {
            DelayedProgressView(label: "Loading your messages")
                .frame(maxWidth: .infinity, minHeight: 88)
                .marginPlainRow()
        }
    }

    /// "No messages yet". With no friends, Add a friend (filled) and Share my username (quiet).
    private var emptyState: some View {
        let hasNoFriends = social.friends.isEmpty
        return EmptyStateView(
            systemImage: "tray",
            title: "No messages yet",
            message: "Quotes your friends send land here.",
            actionTitle: hasNoFriends ? "Add a friend" : nil,
            action: { router.push(.friends(.add)) }
        ) {
            if hasNoFriends, let handle = session.profile?.handle {
                ShareLink(item: UsernameInvite.text(handle)) {
                    Text("Share my username")
                        .emptyStateLink()
                }
                // In a List row a default-style control would take the row's ink, not the accent.
                .buttonStyle(.borderless)
                .accessibilityHint("Sends \(handle) so a friend can add you")
            }
        }
    }

    // MARK: Actions

    private func markQuotesSeen() {
        guard social.unseenCount > 0 else { return }
        Task { await social.markInboxSeen() }
    }
}

// MARK: - Requests summary

/// The Inbox's requests row: one request reads "Sam Kim wants to be friends" over "@samk" beside their
/// avatar; several read "3 friend requests" over "From Sam, Lee and Ana" beside up to three avatars.
/// At accessibility sizes the avatars go, the title has no line limit (it is the row's whole message)
/// and the second line gets 3 lines. VoiceOver: "3 friend requests, from Sam Kim, Lee Park and Ana
/// Ruiz".
private struct FriendRequestsSummary: View {
    let requests: [Connection]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let profiles = requests.map(\.profile)
        HStack(spacing: Theme.Spacing.s) {
            if !dynamicTypeSize.isAccessibilitySize {
                if let only = profiles.first, profiles.count == 1 {
                    AvatarCircle(profile: only, size: 40)
                } else {
                    AvatarStack(profiles: profiles, size: 32)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(profiles))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(subtitle(profiles))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(profiles))
    }

    private func title(_ profiles: [Profile]) -> String {
        if let only = profiles.first, profiles.count == 1 {
            return "\(only.displayName) wants to be friends"
        }
        return "\(profiles.count) friend requests"
    }

    private func subtitle(_ profiles: [Profile]) -> String {
        if let only = profiles.first, profiles.count == 1 {
            return only.handle
        }
        return "From \(Self.list(profiles.map { Self.firstName($0.displayName) }))"
    }

    private func accessibilityText(_ profiles: [Profile]) -> String {
        if let only = profiles.first, profiles.count == 1 {
            return "\(only.displayName) wants to be friends, \(only.handle)"
        }
        return "\(profiles.count) friend requests, from \(Self.list(profiles.map(\.displayName)))"
    }

    /// "Sam", "Sam and Lee", "Sam, Lee and Ana", "Sam, Lee and 3 others".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

// MARK: - Previews

#Preview("Inbox") {
    NavigationStack { InboxView() }
        .previewEnvironment()
}

#Preview("Inbox empty, no friends") {
    let model = AppModel.preview()
    model.social.seedPreview(friendships: [], conversations: [], messages: [], me: Samples.alex.id)
    return NavigationStack { InboxView() }
        .previewEnvironment(model)
}

#Preview("Inbox dark, large type") {
    NavigationStack { InboxView() }
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
