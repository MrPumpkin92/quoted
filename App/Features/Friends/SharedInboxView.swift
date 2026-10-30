import QuotedCore
import SwiftUI

/// "Shared with you": every quote friends sent (the quote messages you received in your
/// conversations), newest first, as cards with the sender's note, Save (or Saved), and Report / Block
/// in the "…" menu. Swipe right to save; swipe left to block or report. Opening it marks the
/// conversations read. `Route.sharedInbox` maps to `SharedInboxView()`.
///
/// A received message can't be deleted on its own (only its sender can unsend it), so there is no
/// Delete; the conversation screens (Stage 5) bring "Delete Conversation".
struct SharedInboxView: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    @State private var isVisible = false
    @State private var confirmation: SocialConfirmation?

    /// The inbox shows whole quotes, at every text size: a fixed cap (it was 40 lines) cut long
    /// quotes off at accessibility sizes, where a card has no detail view to read the rest in.
    private static let fullQuoteLineLimit = Int.max

    init() {}

    var body: some View {
        ZStack {
            content
        }
        .navigationTitle("Shared with you")
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
            // Quotes that arrive while the inbox is on screen count as seen too.
            if isVisible { markSharesSeen() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if social.inbox.isEmpty {
            ScrollView {
                emptyContent
                    .frame(maxWidth: .infinity)
            }
            .groundBackground()
        } else {
            List {
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
                footer
            }
            .marginCardList()
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if !social.hasLoaded, let error = social.lastError {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn\u{2019}t load shared quotes",
                message: "\(error.friendlyMessage)",
                actionTitle: "Try again",
                action: { Task { await social.refresh(userInitiated: true) } }
            )
        } else if !social.hasLoaded {
            DelayedProgressView(label: "Loading shared quotes")
                .padding(.top, Theme.Spacing.xxl)
        } else {
            EmptyStateView(
                systemImage: "tray",
                title: "Nothing shared yet",
                message: "When friends send you a quote, it shows up here. Save the ones you want to keep.",
                actionTitle: "Find friends",
                action: showFriends
            )
        }
    }

    private var footer: some View {
        Text("Saved quotes go to your library and your reminders.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .marginPlainRow(top: Theme.Spacing.s, bottom: Theme.Spacing.l)
    }

    private func markSharesSeen() {
        guard social.unseenCount > 0 else { return }
        Task { await social.markInboxSeen() }
    }

    /// Goes to the Friends tab root, where "Add by username" is.
    private func showFriends() {
        router.popToRoot(.friends)
        router.select(.friends)
    }
}

// MARK: - Shared quote card

/// A quote a friend sent, as a card: the sender and when, a "…" menu (Report…, Block @x), the
/// sender's note, the quote and its attribution, then Save (or Saved, when the library already holds
/// the same text and author).
///
/// Used by `SharedInboxView`. Save sits under the quote at every text size, so the card reads who →
/// what they said → the quote → act. Save adds the quote to the library and to reminders (the same
/// default as Add). The Report and Block confirmations hang off the "…" button, so they point at this
/// card; set `confirmation` to `.report` / `.blockSender` with this message's ID (from a swipe
/// action, say) to show them.
struct SharedQuoteCard: View {
    let share: InboxQuote
    /// Line limit for the quote. Nil keeps the compact style's default (6 lines).
    var lineLimit: Int?
    @Binding var confirmation: SocialConfirmation?

    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                AvatarCircle(name: senderName, id: share.senderID, size: 28)
                fromLine
                Spacer(minLength: Theme.Spacing.xxs)
                moreMenu
            }
            if let note {
                // The note is the one personal line on the card: primary ink, the glyph quiet.
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .foregroundStyle(.primary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Note from \(senderName): \(note)")
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                QuoteText(share, style: .compact, lineLimit: lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AttributionLine(share)
            }
            .accessibilityElement(children: .combine)
            // A reported quote is gone for you on the server (Save would fail); its card stays
            // only for the "Also block?" offer.
            if !social.reportedMessageIDs.contains(share.id) {
                saveControl
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    // MARK: Parts

    private var senderName: String {
        share.sender?.displayName ?? "A friend"
    }

    private var note: String? {
        guard let trimmed = share.note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Under a minute reads "Just now" rather than "47 sec. ago".
    private var isJustNow: Bool {
        Date.now.timeIntervalSince(share.createdAt) < 60
    }

    private var fromLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(senderName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Group {
                if isJustNow {
                    Text("Just now")
                } else {
                    Text(share.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .lineLimit(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isJustNow
            ? Text("From \(senderName), just now")
            : Text("From \(senderName), \(share.createdAt, format: .relative(presentation: .named, unitsStyle: .wide))"))
    }

    @ViewBuilder
    private var saveControl: some View {
        if library.containsCopy(of: share) {
            Label("Saved", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .accessibilityLabel("Saved to your library")
        } else {
            Button(action: save) {
                ZStack {
                    Text("Save").opacity(isSaving ? 0 : 1)
                    if isSaving {
                        ProgressView()
                    }
                }
                .fontWeight(.semibold)
                .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(isSaving)
            .accessibilityLabel(isSaving ? "Saving" : "Save to your library")
            .accessibilityHint("Adds the quote to your library and your reminders.")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Report\u{2026}", systemImage: "flag") {
                confirmation = .report(shareID: share.id)
            }
            Button("Block \(handle)", systemImage: "hand.raised", role: .destructive) {
                confirmation = .blockSender(shareID: share.id)
            }
        } label: {
            MoreMenuLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("More options for the quote from \(senderName)")
        .reportShareConfirmation(isPresented: $confirmation.presenting(.report(shareID: share.id)), share: share)
        .blockConfirmation(
            isPresented: $confirmation.presenting(.blockSender(shareID: share.id)),
            name: share.sender?.displayName ?? "This person",
            handle: share.sender?.handle
        ) {
            await social.blockSender(of: share)
        }
    }

    private var handle: String {
        share.sender?.handle ?? "sender"
    }

    // MARK: Actions

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await library.saveShared(share, addToReminders: true)
            isSaving = false
        }
    }
}

/// The "…" that holds everything about a person or a quote (Report, Block, Remove, Delete): a
/// semibold ellipsis in the concrete secondary gray (about 3.5:1 on Surface in light mode, more in
/// dark), in a 44-pt target. `Color.secondary`, not `.secondary`: inside a borderless button the
/// hierarchical style resolves against the accent tint and drops to about 2.5:1.
struct MoreMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.bold))
            .foregroundStyle(Color.secondary)
            .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
            .contentShape(Rectangle())
    }
}

/// Swipe-action fills. Destructive swipes keep `role: .destructive` and say red explicitly, because
/// the app-wide accent tint would otherwise win. Report, Block and Favorite use the Increased
/// Contrast light variants of system orange, gray and pink, so their white glyph and title reach
/// 4.5:1 in either mode (plain `.orange` is about 2.2:1).
@MainActor
enum SwipeTint {
    static let destructive = Color.red
    static let report = highContrast(.systemOrange)
    static let block = highContrast(.systemGray)
    static let favorite = highContrast(.systemPink)

    private static func highContrast(_ color: UIColor) -> Color {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.accessibilityContrast = .high
        }
        return Color(uiColor: color.resolvedColor(with: traits))
    }
}

// MARK: - Confirmations

/// The confirmation a Friends screen is showing, keyed by what it is about. Each confirmation is
/// attached to the row or button it belongs to (so iOS 26 points its popover there) and shows when
/// the screen's `SocialConfirmation?` state equals its key.
enum SocialConfirmation: Hashable, Sendable {
    /// Report a quote a friend sent (reasons), by message ID.
    case report(shareID: UUID)
    /// Block the sender of a quote, by message ID.
    case blockSender(shareID: UUID)
    /// Block a friend or someone with a pending request.
    case block(userID: UUID)
    /// Report a person (a friend, a request, a blocked user), not a quote.
    case reportUser(userID: UUID)
    /// Remove a friend.
    case remove(friendshipID: UUID)
}

extension Binding where Value == SocialConfirmation? {
    /// True while the state is `key`; setting false clears it (only if it is still `key`).
    func presenting(_ key: SocialConfirmation) -> Binding<Bool> {
        let state = self
        return Binding<Bool>(
            get: { state.wrappedValue == key },
            set: { isPresented in
                if !isPresented, state.wrappedValue == key {
                    state.wrappedValue = nil
                }
            }
        )
    }
}

/// "Report this quote?" with `ReportReason.personReasons`. `SocialStore.report` files it against the
/// message and its sender and toasts "Thanks, we'll review it", then "Also block @x?" offers to block
/// the sender. The server hides a reported message from its reporter at once: the card loses Save,
/// and goes once the offer is answered (`SocialStore.hideReported(_:)`).
private struct ReportShareConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let share: InboxQuote

    @Environment(SocialStore.self) private var social
    @State private var isOfferingBlock = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Report this quote?", isPresented: $isPresented, titleVisibility: .visible) {
                ForEach(ReportReason.personReasons) { reason in
                    Button(reason.title) { file(reason) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("We review reports every day. The sender isn\u{2019}t told who reported it.")
            }
            .confirmationDialog("Also block \(handle)?", isPresented: $isOfferingBlock, titleVisibility: .visible) {
                Button("Block \(handle)", role: .destructive) {
                    let social = self.social
                    let share = self.share
                    Task { await social.blockSender(of: share) }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(BlockCopy.consequences(name: share.sender?.displayName ?? "They"))
            }
            .onChange(of: isOfferingBlock) { _, isOffering in
                if !isOffering { social.hideReported(share.id) }
            }
    }

    private var handle: String {
        share.sender?.handle ?? "the sender"
    }

    private func file(_ reason: ReportReason) {
        let social = self.social
        let share = self.share
        Task {
            guard await social.report(share, reason: reason) else { return }
            // Still on screen (a refresh drops a reported quote, and the dialog with its card):
            // offer to block. Otherwise there is no card left to keep.
            guard social.inbox.contains(where: { $0.id == share.id }) else {
                social.hideReported(share.id)
                return
            }
            isOfferingBlock = true
        }
    }
}

/// Where a person was reported from. Goes into the report's details for the moderator.
enum ReportUserContext: Sendable {
    case incomingRequest
    case outgoingRequest
    case friend
    case profile
    case blockedUser

    var summary: String {
        switch self {
        case .incomingRequest: "a friend request they sent"
        case .outgoingRequest: "a friend request the reporter sent"
        case .friend: "the reporter\u{2019}s friends list"
        case .profile: "their profile, which shows their favorite quotes"
        case .blockedUser: "the reporter\u{2019}s blocked users"
        }
    }
}

/// "Report @maya?" with `ReportReason.personReasons`, for a person rather than a quote (an offensive
/// name, unwanted requests). `SocialStore.reportUser` files it and toasts "Thanks, we'll review it",
/// then (unless they are already blocked) "Also block @maya?" offers to block them.
///
/// The server keeps the reported username; the details add where the report came from and the
/// display name the reporter saw, which the person can change or delete later.
private struct ReportUserConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    /// Nil shows nothing (`reportUserConfirmation(item:context:)` before a person is picked).
    let profile: Profile?
    let context: ReportUserContext

    @Environment(SocialStore.self) private var social
    /// The person just reported, while "Also block?" asks.
    @State private var blockCandidate: Profile?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Report \(profile?.handle ?? "this person")?",
                isPresented: $isPresented,
                titleVisibility: .visible,
                presenting: profile
            ) { profile in
                ForEach(ReportReason.personReasons) { reason in
                    Button(reason.title) { file(reason, about: profile) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                Text("We review reports every day. \(profile.displayName) isn\u{2019}t told who reported them.")
            }
            .confirmationDialog(
                "Also block \(blockCandidate?.handle ?? "them")?",
                isPresented: isOfferingBlock,
                titleVisibility: .visible,
                presenting: blockCandidate
            ) { profile in
                Button("Block \(profile.handle)", role: .destructive) {
                    let social = self.social
                    Task { await social.block(profile) }
                }
                Button("Not Now", role: .cancel) {}
            } message: { profile in
                Text(BlockCopy.consequences(name: profile.displayName))
            }
    }

    private var isOfferingBlock: Binding<Bool> {
        Binding(
            get: { blockCandidate != nil },
            set: { if !$0 { blockCandidate = nil } }
        )
    }

    private func file(_ reason: ReportReason, about profile: Profile) {
        let social = self.social
        let details = Self.details(for: profile, context: context)
        let offersBlock = context != .blockedUser
        Task {
            guard await social.reportUser(profile.id, reason: reason, details: details), offersBlock else { return }
            guard !social.blockedUsers.contains(where: { $0.id == profile.id }) else { return }
            blockCandidate = profile
        }
    }

    private static func details(for profile: Profile, context: ReportUserContext) -> String {
        "Reported from \(context.summary). Display name when reported: \u{201C}\(profile.displayName)\u{201D}."
    }
}

/// What blocking does, said the same way everywhere (docs/ui-spec.md, Report and block). Every claim
/// holds on the server: the username lookup, friend requests and messages ignore a blocked pair,
/// posts, playlists and the profile page are hidden from them, and the block ends the friendship and
/// closes the conversation without deleting a message. "Account" until Settings replaces it.
enum BlockCopy {
    static func consequences(name: String) -> String {
        "\(name) won\u{2019}t be able to find you or message you, and won\u{2019}t see your posts, playlists or profile. Your friendship ends. You keep your conversation, read only, so you can report from it. They aren\u{2019}t told. You can unblock them in Account."
    }
}

extension View {
    /// Asks for a report reason, then reports `share` (the message and its sender).
    func reportShareConfirmation(isPresented: Binding<Bool>, share: InboxQuote) -> some View {
        modifier(ReportShareConfirmation(isPresented: isPresented, share: share))
    }

    /// Asks for a report reason, then reports `profile` (not a quote). `context` says where the
    /// report came from, for the moderator.
    func reportUserConfirmation(isPresented: Binding<Bool>, profile: Profile, context: ReportUserContext) -> some View {
        modifier(ReportUserConfirmation(isPresented: isPresented, profile: profile, context: context))
    }

    /// The same, for whichever person `item` holds; shows while it is non-nil and clears it on close.
    func reportUserConfirmation(item: Binding<Profile?>, context: ReportUserContext) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        return modifier(ReportUserConfirmation(isPresented: isPresented, profile: item.wrappedValue, context: context))
    }

    /// "Block @maya?" with what blocking does, then runs `block` (which removes the friendship and
    /// requests at once and toasts "Blocked @maya").
    func blockConfirmation(
        isPresented: Binding<Bool>,
        name: String,
        handle: String?,
        block: @escaping @MainActor () async -> Void
    ) -> some View {
        confirmationDialog("Block \(handle ?? name)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task { await block() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BlockCopy.consequences(name: name))
        }
    }
}

// MARK: - Previews

#Preview("Shared inbox") {
    NavigationStack { SharedInboxView() }
        .previewEnvironment()
}

#Preview("Shared inbox empty") {
    let model = AppModel.preview()
    model.social.seedPreview(friendships: Samples.friendships, conversations: [], messages: [], me: Samples.alex.id)
    return NavigationStack { SharedInboxView() }
        .previewEnvironment(model)
}

#Preview("SharedQuoteCard dark") {
    @Previewable @State var confirmation: SocialConfirmation?
    List {
        ForEach(Samples.inbox) { share in
            SharedQuoteCard(share: share, confirmation: $confirmation)
                .marginCardRow(.single, outerSpacing: 6)
        }
    }
    .marginCardList()
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
