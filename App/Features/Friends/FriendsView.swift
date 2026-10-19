import QuotedCore
import SwiftUI

/// The Friends tab root (docs/ui-spec.md §10).
///
/// Top to bottom: your profile row (→ Account), "Add by username", Requests (incoming: Decline /
/// Accept; outgoing: Requested / Cancel; context menu Report / Block), "Shared with you" (the latest
/// two as cards, "See all" → the inbox) and Friends (swipe to Remove; context menu Remove / Report /
/// Block). Report and Block are also VoiceOver actions on each person. Opening the tab marks shares
/// as seen. MainTabView puts `FriendsView()` at the root of the Friends tab's NavigationStack.
struct FriendsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    @State private var username = ""
    @State private var usernameError: String?
    @State private var isSendingRequest = false
    @FocusState private var isUsernameFocused: Bool
    @State private var isVisible = false
    @State private var confirmation: SocialConfirmation?
    private var separatorInset = SocialSeparatorInset()

    /// How many shares the tab shows before "See all".
    private static let sharedPreviewCount = 2

    init() {}

    var body: some View {
        List {
            profileRow
            addFriendRow
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
        .marginCardRow(.single, outerSpacing: Theme.Spacing.xs)
    }

    // MARK: Add by username

    private var addFriendRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
                .disabled(!Username.isValid(username) || isSendingRequest)
                // The label keeps the visible word, so Voice Control's "Tap Add" works.
                .accessibilityLabel(isSendingRequest ? "Sending request" : "Add friend")
                .accessibilityHint("Sends a friend request to this username.")
                .accessibilityInputLabels(["Add", "Add friend", "Send friend request"])
            }
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            if let usernameError {
                Text(usernameError)
                    .font(.footnote)
                    .foregroundStyle(.inlineError)
            }
        }
        .onChange(of: username) {
            usernameError = Self.liveUsernameError(username)
        }
        .marginCardRow(.single, outerSpacing: Theme.Spacing.s)
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
                    onAccept: { Task { await social.accept(request) } },
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

    @ViewBuilder
    private var sharedSection: some View {
        if social.hasLoaded || !social.inbox.isEmpty {
            MarginSectionHeader("Shared with you") {
                if !social.inbox.isEmpty {
                    Button {
                        router.push(.sharedInbox)
                    } label: {
                        Text(social.inbox.count > Self.sharedPreviewCount ? "See all (\(social.inbox.count))" : "See all")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: Theme.Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("See all \(social.inbox.count) shared quotes")
                }
            }
            if social.inbox.isEmpty {
                MarginCardMessage(
                    systemImage: "tray",
                    title: "Nothing shared yet",
                    message: Text("Quotes your friends send you show up here.")
                )
                .marginCardRow(.single)
            } else {
                ForEach(social.inbox.prefix(Self.sharedPreviewCount)) { share in
                    SharedQuoteCard(share: share, confirmation: $confirmation)
                        .marginCardRow(.single, outerSpacing: 6)
                }
            }
        }
    }

    // MARK: Friends

    @ViewBuilder
    private var friendsSection: some View {
        MarginSectionHeader("Friends")
        if !social.friends.isEmpty {
            ForEach(Array(social.friends.enumerated()), id: \.element.id) { index, friend in
                SocialPersonLabel(profile: friend.profile)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .accessibilityActions {
                        Button("Report\u{2026}") { confirmation = .reportUser(userID: friend.profile.id) }
                        Button("Block") { confirmation = .block(userID: friend.profile.id) }
                    }
                    .marginCardRow(MarginCardPosition(index: index, count: social.friends.count), separatorInset: separatorInset.value)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            confirmation = .remove(friendshipID: friend.id)
                        } label: {
                            Label("Remove", systemImage: "person.badge.minus")
                        }
                        .tint(.red)
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
                message: Text("Add friends by username to share quotes.")
            ) {
                Button {
                    isUsernameFocused = true
                } label: {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text("Add a friend")
                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .marginCardRow(.single)
        } else if let error = social.lastError {
            MarginCardMessage(
                systemImage: "wifi.exclamationmark",
                title: "Couldn\u{2019}t load your friends",
                message: Text(error.friendlyMessage)
            ) {
                Button("Try again") {
                    Task { await social.refresh(userInitiated: true) }
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

    // MARK: Actions

    private func markSharesSeen() {
        guard social.unseenCount > 0 else { return }
        Task { await social.markInboxSeen() }
    }

    private func remove(_ friend: Connection) {
        Task {
            if await social.removeFriend(friend) {
                toasts.show("Removed \(friend.profile.displayName)")
            }
        }
    }
}

// MARK: Rows

/// Your own profile at the top of Friends: avatar, name, @handle and "Account and settings".
private struct ProfileSummaryRow: View {
    let profile: Profile?
    let email: String?

    var body: some View {
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
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens your account and settings")
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
            }
        }
    }

    private var settingsLabel: some View {
        Text("Account and settings")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var subtitle: String? {
        profile?.handle ?? email
    }

    private var accessibilityText: String {
        [profile?.displayName ?? "Your account", subtitle, "Account and settings"]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}

/// A friend request: the person, then Decline / Accept (incoming) or Requested / Cancel (outgoing).
///
/// At the default text size the buttons always sit beside the person: a long name wraps to two lines
/// (then truncates) instead of pushing them down. When they can't fit next to even a short name
/// (large text, narrow screens), they move under the name, then stack at the largest sizes. Report
/// and Block are VoiceOver actions on the person (the row's context menu has them for everyone else).
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
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                person
                HStack(spacing: Theme.Spacing.xs) { actions }
                    .fixedSize()
                    .padding(.leading, textIndent.value - Theme.Spacing.cardPadding)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                person
                HStack(spacing: Theme.Spacing.xs) { actions }
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                person
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

    @ViewBuilder
    private var actions: some View {
        switch request.kind {
        case .incoming:
            Button(action: onDecline) {
                Text("Decline")
                    .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .tint(Color.primary)
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
            .padding(.bottom, position.closesBottom ? outerSpacing : 0)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Makes this `List` row one row of a Margin card: card-padded content, the card slice behind it,
    /// no system separator. Use in a `.plain` list styled with `.marginCardList()`.
    func marginCardRow(
        _ position: MarginCardPosition,
        separatorInset: CGFloat = Theme.Spacing.cardPadding,
        outerSpacing: CGFloat = 0
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
                bottom: Theme.Spacing.s + (position.closesBottom ? outerSpacing : 0),
                trailing: Theme.Spacing.gutter + Theme.Spacing.cardPadding
            ))
            .listRowBackground(MarginCardRowBackground(
                position: position,
                separatorInset: separatorInset,
                outerSpacing: outerSpacing
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
                Text(profile.handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
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
