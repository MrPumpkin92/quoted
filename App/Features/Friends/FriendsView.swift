import QuotedCore
import SwiftUI
import UIKit

/// The Friends tab root (docs/ui-spec.md §10).
///
/// Top to bottom: your profile row (→ Account; press and hold to copy or share your username), "Add a
/// friend" (the username field, then "Your username: @alex" with Copy and Share), Requests (incoming:
/// Decline / Accept; outgoing: Requested / Cancel; each with a "…" menu: Report, Block, and Decline
/// for incoming), "N shared with you" (one row that opens the inbox) and Friends (a "…" menu and
/// trailing swipes: Remove, Block, Report). The "…" holds everything about a person, here and on shared
/// quotes. Report and Block are also VoiceOver actions on each person. Opening the tab marks shares as
/// seen. MainTabView puts `FriendsView()` at the root of the Friends tab's NavigationStack.
struct FriendsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var username = ""
    @State private var usernameError: String?
    @State private var isSendingRequest = false
    @FocusState private var isUsernameFocused: Bool
    @State private var isVisible = false
    @State private var confirmation: SocialConfirmation?
    private var separatorInset = SocialSeparatorInset()

    init() {}

    var body: some View {
        List {
            profileRow
            addFriendSection
            requestsSection
            sharedSection
            friendsSection
        }
        .marginCardList()
        .navigationTitle("Friends")
        .refreshable {
            await social.refresh(userInitiated: true)
        }
        .task {
            await social.refreshIfStale()
        }
        .onAppear {
            isVisible = true
            markSharesSeen()
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: social.unseenCount) {
            // New shares that arrive while the tab is on screen count as seen too.
            if isVisible { markSharesSeen() }
        }
    }

    // MARK: Profile

    private var profileRow: some View {
        NavigationLink(value: Route.account) {
            ProfileSummaryRow(profile: session.profile, email: session.email)
        }
        .contextMenu {
            if let handle = session.profile?.handle {
                Button("Copy Username", systemImage: "doc.on.doc") { copy(handle) }
                ShareLink(item: UsernameInvite.text(handle)) {
                    Label("Share Username", systemImage: "square.and.arrow.up")
                }
            }
        }
        .marginCardRow(.single, outerSpacing: Theme.Spacing.xs)
    }

    // MARK: Add a friend

    @ViewBuilder
    private var addFriendSection: some View {
        MarginSectionHeader("Add a friend")
        addFriendRow
    }

    private var addFriendRow: some View {
        // At accessibility sizes the field gets its own line and Add goes under it. `AnyLayout`, not
        // `ViewThatFits`: the field keeps its identity (and focus) when the layout changes, and a
        // long typed username never flips the layout mid-word.
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.xs))
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            layout {
                HStack(spacing: Theme.Spacing.xs) {
                    if !isStacked {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 1) {
                        Text("@")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .submitLabel(.send)
                            .focused($isUsernameFocused)
                            .onSubmit(sendRequest)
                            .accessibilityLabel("Add by username")
                    }
                }
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                Button(action: sendRequest) {
                    ZStack {
                        Text("Add").opacity(isSendingRequest ? 0 : 1)
                        if isSendingRequest {
                            ProgressView()
                        }
                    }
                    .fontWeight(.semibold)
                    .capsuleButtonLabel()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .fixedSize()
                .disabled(!Username.isValid(username) || isSendingRequest)
                // The label keeps the visible word, so Voice Control's "Tap Add" works.
                .accessibilityLabel(isSendingRequest ? "Sending request" : "Add friend")
                .accessibilityHint("Sends a friend request to this username.")
                .accessibilityInputLabels(["Add", "Add friend", "Send friend request"])
            }
            if let usernameError {
                Text(usernameError)
                    .font(.footnote)
                    .foregroundStyle(.inlineError)
            }
            if let handle = session.profile?.handle {
                HairlineDivider()
                    .padding(.top, Theme.Spacing.xxs)
                YourUsernameLine(handle: handle, onCopy: { copy(handle) })
            }
        }
        .onChange(of: username) {
            usernameError = Self.liveUsernameError(username)
        }
        .marginCardRow(.single)
    }

    /// Errors worth showing while typing (bad characters, too long). "Too short" waits for submit.
    private static func liveUsernameError(_ input: String) -> String? {
        guard !Username.normalize(input).isEmpty else { return nil }
        switch Result(catching: { () throws(UsernameError) -> String in try Username.validate(input) }) {
        case .success, .failure(.tooShort):
            return nil
        case .failure(let error):
            return error.errorDescription
        }
    }

    private func sendRequest() {
        let input = username
        guard !isSendingRequest else { return }
        if case .failure(let error) = Result(catching: { () throws(UsernameError) -> String in try Username.validate(input) }) {
            usernameError = error.errorDescription
            return
        }
        usernameError = nil
        isSendingRequest = true
        Task {
            let result = await social.sendRequest(toUsername: input)
            isSendingRequest = false
            if result.isSuccess {
                username = ""
                isUsernameFocused = false
            }
        }
    }

    // MARK: Requests

    @ViewBuilder
    private var requestsSection: some View {
        let requests = social.incomingRequests + social.outgoingRequests
        if !requests.isEmpty {
            MarginSectionHeader("Requests")
            ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                FriendRequestRow(
                    request: request,
                    onAccept: { accept(request) },
                    onDecline: { Task { await social.decline(request) } },
                    onCancel: { Task { await social.cancel(request) } },
                    onReport: { confirmation = .reportUser(userID: request.profile.id) },
                    onBlock: { confirmation = .block(userID: request.profile.id) }
                )
                .marginCardRow(MarginCardPosition(index: index, count: requests.count), separatorInset: separatorInset.value)
                .contextMenu {
                    Button("Report \(request.profile.handle)\u{2026}", systemImage: "flag") {
                        confirmation = .reportUser(userID: request.profile.id)
                    }
                    Button("Block \(request.profile.handle)", systemImage: "hand.raised", role: .destructive) {
                        confirmation = .block(userID: request.profile.id)
                    }
                }
                .reportUserConfirmation(
                    isPresented: $confirmation.presenting(.reportUser(userID: request.profile.id)),
                    profile: request.profile,
                    context: request.kind == .incoming ? .incomingRequest : .outgoingRequest
                )
                .blockConfirmation(
                    isPresented: $confirmation.presenting(.block(userID: request.profile.id)),
                    name: request.profile.displayName,
                    handle: request.profile.handle
                ) {
                    await social.block(request.profile)
                }
            }
        }
    }

    // MARK: Shared with you

    /// One row, like Library's: who sent quotes and how many, opening the inbox. The cards with Save,
    /// Delete, Report and Block live only in the inbox, so they behave the same everywhere.
    @ViewBuilder
    private var sharedSection: some View {
        if social.inbox.isEmpty {
            if social.hasLoaded {
                MarginSectionHeader("Shared with you")
                MarginCardMessage(
                    systemImage: "tray",
                    title: "Nothing shared yet",
                    message: Text("Quotes your friends send you show up here.")
                )
                .marginCardRow(.single)
            }
        } else {
            MarginSectionHeader("Shared with you")
            Button {
                router.push(.sharedInbox)
            } label: {
                SharedSummaryRow(
                    count: social.inbox.count,
                    senders: social.inboxSenders,
                    summary: social.inboxSummary
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens quotes your friends sent")
            .marginCardRow(.single)
        }
    }

    // MARK: Friends

    @ViewBuilder
    private var friendsSection: some View {
        MarginSectionHeader("Friends")
        if !social.friends.isEmpty {
            ForEach(Array(social.friends.enumerated()), id: \.element.id) { index, friend in
                FriendRow(
                    friend: friend,
                    onRemove: { confirmation = .remove(friendshipID: friend.id) },
                    onReport: { confirmation = .reportUser(userID: friend.profile.id) },
                    onBlock: { confirmation = .block(userID: friend.profile.id) }
                )
                .marginCardRow(MarginCardPosition(index: index, count: social.friends.count), separatorInset: separatorInset.value)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Red, but no destructive role: Remove asks first, and a destructive swipe
                    // button makes the list animate the row away, which tears down the
                    // confirmation before it shows (checked on iOS 26). The inbox's Delete, which
                    // removes the row at once, keeps the role.
                    Button {
                        confirmation = .remove(friendshipID: friend.id)
                    } label: {
                        Label("Remove", systemImage: "person.badge.minus")
                    }
                    .tint(SwipeTint.destructive)
                    Button {
                        confirmation = .block(userID: friend.profile.id)
                    } label: {
                        Label("Block", systemImage: "hand.raised")
                    }
                    .tint(SwipeTint.block)
                    Button {
                        confirmation = .reportUser(userID: friend.profile.id)
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    .tint(SwipeTint.report)
                }
                .contextMenu {
                    Button("Remove Friend", systemImage: "person.badge.minus") {
                        confirmation = .remove(friendshipID: friend.id)
                    }
                    Button("Report \(friend.profile.handle)\u{2026}", systemImage: "flag") {
                        confirmation = .reportUser(userID: friend.profile.id)
                    }
                    Button("Block \(friend.profile.handle)", systemImage: "hand.raised", role: .destructive) {
                        confirmation = .block(userID: friend.profile.id)
                    }
                }
                .reportUserConfirmation(
                    isPresented: $confirmation.presenting(.reportUser(userID: friend.profile.id)),
                    profile: friend.profile,
                    context: .friend
                )
                .confirmationDialog(
                    "Remove \(friend.profile.displayName)?",
                    isPresented: $confirmation.presenting(.remove(friendshipID: friend.id)),
                    titleVisibility: .visible
                ) {
                    Button("Remove Friend", role: .destructive) {
                        remove(friend)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You and \(friend.profile.displayName) won\u{2019}t be able to send each other quotes. Quotes you\u{2019}ve already shared stay. You can add them again later.")
                }
                .blockConfirmation(
                    isPresented: $confirmation.presenting(.block(userID: friend.profile.id)),
                    name: friend.profile.displayName,
                    handle: friend.profile.handle
                ) {
                    await social.block(friend.profile)
                }
            }
        } else if social.hasLoaded {
            MarginCardMessage(
                systemImage: "person.2",
                title: "No friends yet",
                message: Text("Friends add each other by username. Add someone, or send them yours.")
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.l) { emptyStateActions }
                    VStack(alignment: .leading, spacing: 0) { emptyStateActions }
                }
            }
            .marginCardRow(.single)
        } else if let error = social.lastError {
            MarginCardMessage(
                systemImage: "wifi.exclamationmark",
                title: "Couldn\u{2019}t load your friends",
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
            .marginCardRow(.single)
        } else {
            DelayedProgressView(label: "Loading friends")
                .frame(maxWidth: .infinity, minHeight: 88)
                .marginPlainRow()
        }
    }

    /// "Add a friend" (focuses the field) and "Share your username", side by side or stacked.
    @ViewBuilder
    private var emptyStateActions: some View {
        Button {
            isUsernameFocused = true
        } label: {
            // The 44-pt target is in the label: a frame outside a Button adds no hit area.
            Text("Add a friend")
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        if let handle = session.profile?.handle {
            ShareLink(item: UsernameInvite.text(handle)) {
                Text("Share your username")
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Sends \(handle) so a friend can add you")
        }
    }

    // MARK: Actions

    private func markSharesSeen() {
        guard social.unseenCount > 0 else { return }
        Task { await social.markInboxSeen() }
    }

    /// Accepts, and once the server agrees says so: the new friend lands in the list further down.
    private func accept(_ request: Connection) {
        Task {
            if await social.accept(request) {
                toasts.show("You and \(request.profile.handle) are now friends", style: .success)
            }
        }
    }

    private func remove(_ friend: Connection) {
        Task {
            if await social.removeFriend(friend) {
                toasts.show("Removed \(friend.profile.displayName)")
            }
        }
    }

    private func copy(_ handle: String) {
        UIPasteboard.general.string = handle
        toasts.show("Copied \(handle)", style: .success)
    }
}

// MARK: Username sharing

/// What "Share" sends: a line a friend can act on (they add you by exact username).
enum UsernameInvite {
    static func text(_ handle: String) -> String {
        "Add me on Quoted: \(handle)"
    }
}

/// "Your username: @alex", with Copy and Share. Side by side, or the buttons under the text when they
/// don't fit (large text, long usernames). The username never wraps mid-handle.
struct YourUsernameLine: View {
    let handle: String
    let onCopy: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                label
                Spacer(minLength: Theme.Spacing.xs)
                buttons
            }
            VStack(alignment: .leading, spacing: 0) {
                label
                HStack(spacing: Theme.Spacing.l) { buttons }
            }
        }
    }

    private var label: some View {
        Text("Your username: \(Text(verbatim: handle).foregroundStyle(.primary))")
            .foregroundStyle(.secondary)
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .textSelection(.enabled)
            .accessibilityLabel("Your username: \(handle)")
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onCopy) {
            Text("Copy")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy your username")
        ShareLink(item: UsernameInvite.text(handle)) {
            Text("Share")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Share your username")
        .accessibilityHint("Sends \(handle) so a friend can add you")
    }
}

// MARK: Rows

/// Your own profile at the top of Friends: avatar, name, @handle and "Account". At accessibility sizes
/// the avatar (decorative, and only an initial) is left out and the rest stacks, so the first screen
/// isn't all your own identity.
private struct ProfileSummaryRow: View {
    let profile: Profile?
    let email: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    names
                    settingsLabel
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) {
                        avatar
                        names
                        Spacer(minLength: Theme.Spacing.xs)
                        settingsLabel
                    }
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        avatar
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            names
                            settingsLabel
                        }
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens your account. Press and hold to copy or share your username.")
    }

    @ViewBuilder
    private var avatar: some View {
        if let profile {
            AvatarCircle(profile: profile, size: 48)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile?.displayName ?? "Your account")
                .font(.headline)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var settingsLabel: some View {
        Text("Account")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var subtitle: String? {
        profile?.handle ?? email
    }

    private var accessibilityText: String {
        [profile?.displayName ?? "Your account", subtitle, "Account"]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}

/// "3 shared with you · From Rosa and Maya", with the senders' avatars and a chevron (the same row
/// Library shows for unseen shares).
private struct SharedSummaryRow: View {
    let count: Int
    let senders: [Profile]
    let summary: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Avatars above the text at accessibility sizes, like the status card's tile.
        let layout = IconTile.layout(for: dynamicTypeSize)
        HStack(spacing: Theme.Spacing.s) {
            layout {
                AvatarStack(profiles: senders, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 shared with you" : "\(count) shared with you")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let summary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A friend: the person and a "…" menu (Remove Friend, Report, Block). The row's swipe actions and
/// context menu, and the person's VoiceOver actions, offer the same.
private struct FriendRow: View {
    let friend: Connection
    let onRemove: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            SocialPersonLabel(profile: friend.profile)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityActions {
                    Button("Remove friend", action: onRemove)
                    Button("Report\u{2026}", action: onReport)
                    Button("Block", action: onBlock)
                }
            PersonMoreMenu(profile: friend.profile, onReport: onReport, onBlock: onBlock) {
                Button("Remove Friend", systemImage: "person.badge.minus", action: onRemove)
            }
        }
        .frame(minHeight: Theme.Metrics.minTouchTarget)
        .accessibilityElement(children: .contain)
    }
}

/// The "…" on a person (requests and friends): `extra` first (Decline, Remove Friend), then Report
/// and Block, the same as the "…" on a shared quote.
private struct PersonMoreMenu<Extra: View>: View {
    let profile: Profile
    let onReport: () -> Void
    let onBlock: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        Menu {
            extra()
            Divider()
            Button("Report \(profile.handle)\u{2026}", systemImage: "flag", action: onReport)
            Button("Block \(profile.handle)", systemImage: "hand.raised", role: .destructive, action: onBlock)
        } label: {
            MoreMenuLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("More options for \(profile.displayName)")
    }
}

/// A friend request: the person with a "…" menu, then Decline / Accept (incoming) or Requested /
/// Cancel (outgoing).
///
/// When the buttons fit beside even a short name they sit there (a long name wraps to two lines, then
/// truncates); otherwise (large text, narrow screens) they move under the name, then stack at the
/// largest sizes. The "…" stays at the top right in every layout. Report and Block are in the "…"
/// (with Decline for incoming), the row's context menu and the person's VoiceOver actions.
private struct FriendRequestRow: View {
    let request: Connection
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onCancel: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void

    /// Lines the stacked buttons up with the name, after the avatar.
    private var textIndent = SocialSeparatorInset()
    /// The narrowest name column that still counts as room beside the buttons: about nine characters
    /// a line, two lines. Longer names wrap within it.
    @ScaledMetric(relativeTo: .body) private var minimumNameWidth: CGFloat = 64

    init(
        request: Connection,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onReport: @escaping () -> Void,
        onBlock: @escaping () -> Void
    ) {
        self.request = request
        self.onAccept = onAccept
        self.onDecline = onDecline
        self.onCancel = onCancel
        self.onReport = onReport
        self.onBlock = onBlock
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // ViewThatFits measures ideal widths. The person reports a short ideal width (avatar plus
            // `minimumNameWidth`), so this layout is chosen whenever the buttons fit beside that; it
            // then takes all the room the buttons leave.
            HStack(spacing: Theme.Spacing.s) {
                person
                    .frame(
                        minWidth: 0,
                        idealWidth: textIndent.value - Theme.Spacing.cardPadding + minimumNameWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                HStack(spacing: Theme.Spacing.xs) { actions }
                    .fixedSize()
                moreMenu
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                personWithMenu
                HStack(spacing: Theme.Spacing.xs) { actions }
                    .fixedSize()
                    .padding(.leading, textIndent.value - Theme.Spacing.cardPadding)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                personWithMenu
                HStack(spacing: Theme.Spacing.xs) { actions }
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                personWithMenu
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) { actions }
            }
        }
        .buttonBorderShape(.capsule)
        .accessibilityElement(children: .contain)
    }

    private var person: some View {
        SocialPersonLabel(profile: request.profile)
            .accessibilityActions {
                Button("Report\u{2026}", action: onReport)
                Button("Block", action: onBlock)
            }
    }

    private var personWithMenu: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            person
                .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu
        }
    }

    private var moreMenu: some View {
        PersonMoreMenu(profile: request.profile, onReport: onReport, onBlock: onBlock) {
            if request.kind == .incoming {
                Button("Decline", systemImage: "xmark", action: onDecline)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch request.kind {
        case .incoming:
            // Plain: Accept is the one filled button on the row.
            Button(action: onDecline) {
                // `Color.primary`: in a borderless button `.primary` would resolve to the tint.
                Text("Decline")
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Decline request from \(request.profile.displayName)")
            Button(action: onAccept) {
                Text("Accept")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.onAccent)
                    .capsuleButtonLabel()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Accept request from \(request.profile.displayName)")
        case .outgoing:
            Text("Requested")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onCancel) {
                Text("Cancel")
                    .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .tint(Color.primary)
            .accessibilityLabel("Cancel request to \(request.profile.displayName)")
        case .friend:
            EmptyView()
        }
    }
}

// MARK: Previews

#Preview("Friends") {
    NavigationStack { FriendsView() }
        .previewEnvironment()
}

#Preview("Friends empty") {
    let model = AppModel.preview()
    model.social.seedPreview(friendships: [], inbox: [], me: Samples.alex.id)
    return NavigationStack { FriendsView() }
        .previewEnvironment(model)
}

#Preview("Friends dark, large type") {
    NavigationStack { FriendsView() }
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

// MARK: - Margin card list

// Grouped Margin cards inside a plain `List`.
//
// Friends, the shared inbox, Account and Blocked users need per-row swipe actions and context menus,
// which only `List` rows get, but the Margin look is a Surface card with a hairline outline on Ground.
// Each row draws its own slice of the card (`MarginCardRowBackground`): rows in a run join into one
// card, and a single row is a whole card.

/// Where a row sits in its card.
enum MarginCardPosition: Hashable, Sendable {
    /// A card with one row.
    case single
    /// The top row of a card with several rows.
    case first
    /// A row between the first and the last.
    case middle
    /// The bottom row.
    case last

    /// The position of row `index` in a card of `count` rows.
    init(index: Int, count: Int) {
        if count <= 1 {
            self = .single
        } else if index == 0 {
            self = .first
        } else if index == count - 1 {
            self = .last
        } else {
            self = .middle
        }
    }

    /// Whether the card's top edge (and its rounded corners) belongs to this row.
    var closesTop: Bool { self == .single || self == .first }
    /// Whether the card's bottom edge (and its rounded corners) belongs to this row.
    var closesBottom: Bool { self == .single || self == .last }
}

/// One row's slice of a Margin card: the `Surface` fill, the hairline outline (closed only at the
/// card's top and bottom) and a hairline separator under every row but the last.
struct MarginCardRowBackground: View {
    let position: MarginCardPosition
    /// Where the separator under this row starts, from the card's leading edge.
    var separatorInset: CGFloat = Theme.Spacing.cardPadding
    /// Clear space above and below the card, for cards stacked in one list.
    var outerSpacing: CGFloat = 0
    /// Clear space below the card when it differs from `outerSpacing` (nil: the same).
    var bottomSpacing: CGFloat?

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position.closesTop ? Theme.Radius.card : 0,
            bottomLeadingRadius: position.closesBottom ? Theme.Radius.card : 0,
            bottomTrailingRadius: position.closesBottom ? Theme.Radius.card : 0,
            topTrailingRadius: position.closesTop ? Theme.Radius.card : 0,
            style: .continuous
        )
        shape
            .fill(Color.surface)
            .overlay {
                // The outline runs past the open edges, so clipping leaves only the sides there.
                shape
                    .strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline)
                    .padding(.top, position.closesTop ? 0 : -2)
                    .padding(.bottom, position.closesBottom ? 0 : -2)
            }
            .clipped()
            .overlay(alignment: .bottom) {
                if !position.closesBottom {
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: Theme.Metrics.hairline)
                        .padding(.leading, separatorInset)
                        .padding(.trailing, Theme.Metrics.hairline)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.top, position.closesTop ? outerSpacing : 0)
            .padding(.bottom, position.closesBottom ? (bottomSpacing ?? outerSpacing) : 0)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Makes this `List` row one row of a Margin card: card-padded content, the card slice behind it,
    /// no system separator. Use in a `.plain` list styled with `.marginCardList()`.
    ///
    /// `outerSpacing` is the clear space above and below the card; `bottomSpacing` overrides the
    /// space below it (a card that ends a group but leads into its footer).
    func marginCardRow(
        _ position: MarginCardPosition,
        separatorInset: CGFloat = Theme.Spacing.cardPadding,
        outerSpacing: CGFloat = 0,
        bottomSpacing: CGFloat? = nil
    ) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            // A press-and-hold preview of just this row as a small card, instead of the list cell
            // with its slice of the card background inside the system platter.
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).inset(by: -Theme.Spacing.s)
            )
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.s + (position.closesTop ? outerSpacing : 0),
                leading: Theme.Spacing.gutter + Theme.Spacing.cardPadding,
                bottom: Theme.Spacing.s + (position.closesBottom ? (bottomSpacing ?? outerSpacing) : 0),
                trailing: Theme.Spacing.gutter + Theme.Spacing.cardPadding
            ))
            .listRowBackground(MarginCardRowBackground(
                position: position,
                separatorInset: separatorInset,
                outerSpacing: outerSpacing,
                bottomSpacing: bottomSpacing
            ))
            .listRowSeparator(.hidden)
    }

    /// A `List` row that sits on Ground outside any card (section labels, headers, footers).
    func marginPlainRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: top, leading: Theme.Spacing.gutter, bottom: bottom, trailing: Theme.Spacing.gutter))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Styles a `List` for Margin cards: plain style, rows packed edge to edge, Ground behind, and the
    /// keyboard dismissed by scrolling.
    func marginCardList() -> some View {
        self
            .listStyle(.plain)
            .listRowSpacing(0)
            .listSectionSeparator(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .groundBackground()
            .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    /// Pads a small capsule button's label so the stock `.bordered` / `.borderedProminent` capsule
    /// reaches the 44-pt touch target without the bulk of `.controlSize(.large)`.
    func capsuleButtonLabel() -> some View {
        padding(.vertical, 5)
            .padding(.horizontal, 2)
    }
}

/// A section label above a card ("Requests", "Friends"), with an optional trailing control.
struct MarginSectionHeader<Trailing: View>: View {
    private let title: LocalizedStringKey
    private let trailing: Trailing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.xs)
            trailing
        }
        .marginPlainRow(top: Theme.Spacing.l, bottom: Theme.Spacing.xs)
    }
}

extension MarginSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title) { EmptyView() }
    }
}

/// Avatar, display name and @handle: the person part of friend, request and blocked rows.
struct SocialPersonLabel: View {
    let profile: Profile
    var avatarSize: CGFloat = SocialPersonLabel.avatarSize

    /// The avatar diameter at the default text size.
    nonisolated static let avatarSize: CGFloat = 40

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            AvatarCircle(profile: profile, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                // One line: a handle broken mid-word ("@qar924" / "058") reads as two names. A long
                // one shrinks a little, then truncates; VoiceOver still reads all of it.
                Text(profile.handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.displayName), \(profile.handle)")
    }
}

/// The separator inset that lines row separators up with the text after a `SocialPersonLabel` avatar.
/// Scales with Dynamic Type like `AvatarCircle` does (capped at 1.6x).
struct SocialSeparatorInset: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var value: CGFloat {
        Theme.Spacing.cardPadding + SocialPersonLabel.avatarSize * min(scale, 1.6) + Theme.Spacing.s
    }
}

/// A quiet message inside a card (empty and error states within a list).
struct MarginCardMessage<Actions: View>: View {
    private let systemImage: String
    private let title: LocalizedStringKey
    private let message: Text?
    private let actions: Actions

    init(
        systemImage: String,
        title: LocalizedStringKey,
        message: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            if let message {
                message
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            actions
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

extension MarginCardMessage where Actions == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: Text? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

#Preview("Margin card list") {
    List {
        MarginSectionHeader("Friends") {
            Button("See all") {}
        }
        ForEach(Array([Samples.maya, Samples.jordan, Samples.riley].enumerated()), id: \.element.id) { index, profile in
            SocialPersonLabel(profile: profile)
                .marginCardRow(MarginCardPosition(index: index, count: 3), separatorInset: 68)
        }
        MarginSectionHeader("Shared with you")
        MarginCardMessage(systemImage: "tray", title: "Nothing shared yet", message: Text("Quotes your friends send show up here."))
            .marginCardRow(.single)
    }
    .marginCardList()
    .previewEnvironment()
}
