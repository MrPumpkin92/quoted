import QuotedCore
import SwiftUI

/// "Shared with you": every quote friends sent, newest first, as cards with the sender's note, Save
/// (or Saved), and Report / Block / Delete in the "…" menu. Swipe right to save; swipe left to delete
/// (a full swipe deletes), block or report. Opening it marks shares as seen. `Route.sharedInbox` maps
/// to `SharedInboxView()`.
///
/// Delete asks nothing and shows "Deleted" with Undo. Only the sender can create a share, so the
/// server delete waits for the toast to close (`ToastCenter.showDeferred`): Undo just shows the card
/// again. Leaving the screen, a newer toast, going to the background and signing out all commit it.
struct SharedInboxView: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    @State private var isVisible = false
    @State private var confirmation: SocialConfirmation?
    /// Shares deleted on screen whose server delete waits for the Undo toast to close. A reference,
    /// so the toast's closures can still update it after the view has gone.
    @State private var pendingDeletion = PendingInboxDeletions()

    /// The inbox shows whole quotes (the body limit is 1,000 characters).
    private static let fullQuoteLineLimit = 40

    init() {}

    var body: some View {
        // A stable container: lifecycle modifiers on the if/else itself would also fire when the
        // last share is deleted and the list turns into the empty state, committing that delete
        // before its Undo toast closes.
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
            // Commit a delete still waiting on its Undo toast, so Friends never shows the share.
            if !pendingDeletion.ids.isEmpty {
                let toasts = self.toasts
                Task { await toasts.flushPending() }
            }
        }
        .onChange(of: social.unseenCount) {
            // Shares that arrive while the inbox is on screen count as seen too.
            if isVisible { markSharesSeen() }
        }
    }

    /// The inbox minus shares deleted on screen.
    private var visibleInbox: [SharedQuote] {
        let hidden = pendingDeletion.ids
        return hidden.isEmpty ? social.inbox : social.inbox.filter { !hidden.contains($0.id) }
    }

    @ViewBuilder
    private var content: some View {
        if visibleInbox.isEmpty {
            ScrollView {
                emptyContent
                    .frame(maxWidth: .infinity)
            }
            .groundBackground()
        } else {
            List {
                ForEach(visibleInbox) { share in
                    SharedQuoteCard(
                        share: share,
                        lineLimit: Self.fullQuoteLineLimit,
                        confirmation: $confirmation,
                        onDelete: { delete(share) }
                    )
                    .marginCardRow(.single, outerSpacing: 6)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if !share.isSaved {
                            Button {
                                Task { await library.saveShared(share, addToReminders: true) }
                            } label: {
                                Label("Save", systemImage: "bookmark")
                            }
                            .tint(Color.accentColor)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        // No destructive role: with it the app-wide accent tint wins over red.
                        // The row goes away because `visibleInbox` drops it.
                        Button {
                            delete(share)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            confirmation = .blockSender(shareID: share.id)
                        } label: {
                            Label("Block", systemImage: "hand.raised")
                        }
                        .tint(.gray)
                        Button {
                            confirmation = .report(shareID: share.id)
                        } label: {
                            Label("Report", systemImage: "flag")
                        }
                        .tint(.orange)
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
        Text("Saved quotes go to your library and your reminders. Swipe left to delete. Report or block from a quote\u{2019}s \u{2026} menu.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .marginPlainRow(top: Theme.Spacing.s, bottom: Theme.Spacing.l)
    }

    private func markSharesSeen() {
        guard social.unseenCount > 0 else { return }
        Task { await social.markInboxSeen() }
    }

    /// Hides the share now and deletes it on the server once its Undo toast closes.
    private func delete(_ share: SharedQuote) {
        let id = share.id
        let pending = pendingDeletion
        guard !pending.ids.contains(id) else { return }
        pending.ids.insert(id)
        let social = self.social
        let sender = share.sender?.displayName ?? "a friend"
        toasts.showDeferred("Deleted the quote from \(sender)") {
            pending.ids.remove(id)
        } commit: {
            // On failure the store puts the share back and toasts; either way the store is now the
            // source of truth again.
            await social.deleteShares([id])
            pending.ids.remove(id)
        }
    }

    /// Goes to the Friends tab root, where "Add by username" is.
    private func showFriends() {
        router.popToRoot(.friends)
        router.select(.friends)
    }
}

/// The shares `SharedInboxView` hides while their delete waits for the Undo toast.
@Observable
@MainActor
private final class PendingInboxDeletions {
    var ids: Set<UUID> = []
}

// MARK: - Shared quote card

/// A quote a friend sent, as a card: the sender and when, Save, a "…" menu (Report…, Block @x, and
/// Delete when `onDelete` is set), the sender's note, the quote and its attribution.
///
/// Used by Friends ("Shared with you", the latest two) and `SharedInboxView` (all of them). Save adds
/// the quote to the library and to reminders (the same default as Add). The Report and Block
/// confirmations hang off the "…" button, so they point at this card; set `confirmation` to
/// `.report` / `.blockSender` with this share's ID (from a swipe action, say) to show them.
struct SharedQuoteCard: View {
    let share: SharedQuote
    /// Line limit for the quote. Nil keeps the compact style's default (6 lines).
    var lineLimit: Int?
    @Binding var confirmation: SocialConfirmation?
    /// Adds Delete to the "…" menu (the inbox; Friends' preview has none).
    var onDelete: (() -> Void)?

    @Environment(LibraryStore.self) private var library
    @Environment(SocialStore.self) private var social
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                AvatarCircle(name: senderName, id: share.senderID, size: 28)
                fromLine
                Spacer(minLength: Theme.Spacing.xxs)
                if !dynamicTypeSize.isAccessibilitySize {
                    saveControl
                }
                moreMenu
            }
            if let note {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Image(systemName: "text.bubble")
                    Text(note)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Note from \(senderName): \(note)")
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                QuoteText(share, style: .compact, lineLimit: lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AttributionLine(share)
            }
            .accessibilityElement(children: .combine)
            if dynamicTypeSize.isAccessibilitySize {
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

    private var fromLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(senderName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(share.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .lineLimit(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("From \(senderName), \(share.createdAt, format: .relative(presentation: .named, unitsStyle: .wide))"))
    }

    @ViewBuilder
    private var saveControl: some View {
        if share.isSaved {
            Label("Saved", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xs)
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
            if let onDelete {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
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

// MARK: - Confirmations

/// The confirmation a Friends screen is showing, keyed by what it is about. Each confirmation is
/// attached to the row or button it belongs to (so iOS 26 points its popover there) and shows when
/// the screen's `SocialConfirmation?` state equals its key.
enum SocialConfirmation: Hashable, Sendable {
    /// Report a share (reasons).
    case report(shareID: UUID)
    /// Block the sender of a share.
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

/// "Report this quote?" with `ReportReason.allCases`. `SocialStore.report` files it and toasts
/// "Thanks, we'll review it".
private struct ReportShareConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let share: SharedQuote

    @Environment(SocialStore.self) private var social

    func body(content: Content) -> some View {
        content.confirmationDialog("Report this quote?", isPresented: $isPresented, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.title) {
                    Task { await social.report(share, reason: reason) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We review reports every day. The sender isn\u{2019}t told who reported it.")
        }
    }
}

/// Where a person was reported from. Goes into the report's details for the moderator.
enum ReportUserContext: Sendable {
    case incomingRequest
    case outgoingRequest
    case friend
    case blockedUser

    var summary: String {
        switch self {
        case .incomingRequest: "a friend request they sent"
        case .outgoingRequest: "a friend request the reporter sent"
        case .friend: "the reporter\u{2019}s friends list"
        case .blockedUser: "the reporter\u{2019}s blocked users"
        }
    }
}

/// "Report @maya?" with `ReportReason.allCases`, for a person rather than a quote (an offensive
/// name, unwanted requests). `SocialStore.reportUser` files it and toasts "Thanks, we'll review it".
///
/// The server keeps the reported username; the details add where the report came from and the
/// display name the reporter saw, which the person can change or delete later.
private struct ReportUserConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    /// Nil shows nothing (`reportUserConfirmation(item:context:)` before a person is picked).
    let profile: Profile?
    let context: ReportUserContext

    @Environment(SocialStore.self) private var social

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Report \(profile?.handle ?? "this person")?",
            isPresented: $isPresented,
            titleVisibility: .visible,
            presenting: profile
        ) { profile in
            ForEach(ReportReason.allCases) { reason in
                Button(reason.title) {
                    let social = self.social
                    let details = Self.details(for: profile, context: context)
                    Task { await social.reportUser(profile.id, reason: reason, details: details) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("We review reports every day. \(profile.displayName) isn\u{2019}t told who reported them.")
        }
    }

    private static func details(for profile: Profile, context: ReportUserContext) -> String {
        "Reported from \(context.summary). Display name when reported: \u{201C}\(profile.displayName)\u{201D}."
    }
}

extension View {
    /// Asks for a report reason, then reports `share`.
    func reportShareConfirmation(isPresented: Binding<Bool>, share: SharedQuote) -> some View {
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

    /// "Block @maya?" with what blocking does, then runs `block` (which removes the friendship,
    /// requests and shares at once and toasts "Blocked @maya").
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
            Text("\(name) won\u{2019}t be able to send you requests or quotes, and your friendship and shared quotes will be removed. You can unblock them in Account.")
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
    model.social.seedPreview(friendships: Samples.friendships, inbox: [], me: Samples.alex.id)
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
