import QuotedCore
import SwiftUI
import UniformTypeIdentifiers

/// The share sheet (docs/ui-spec.md §11): a preview of the image card, then two ways to share.
///
/// - **Send to a friend:** tap friends to select them, add an optional note (up to 280 characters) and
///   Send. Each friend gets the quote as a message in your conversation with them. The first send
///   shows the Terms sheet over this one until the terms are accepted (`SocialStore.requireTerms`).
///   Send shows progress from the tap on, through the terms check and while `SocialStore.send` waits
///   for the server, and the sheet can't be closed meanwhile. If it closes anyway, a terms check still
///   waiting ends without a word and a send waiting on the Terms sheet is dropped with it
///   (`SocialStore.dropTermsChecks(for:)`), so a send never goes out after its sheet closed. On
///   success the sheet closes
///   and the store shows "Sent to Maya" with Undo (Undo unsends the messages). When every send fails
///   the store toasts and the sheet stays open with the selection and the note. A friend who is no longer
///   a friend after a refresh drops out of the selection. If friends can't load, the section says so
///   with Try again; "Other ways" works either way.
/// - **Other ways:** the system share sheet with the `QuoteCard` image (light, 3x), or the plain text
///   `“body” — Author, Source`. With no friends yet, "Share image" is the one filled action and a quiet
///   link goes to Friends.
///
/// The preview draws the same view the image is rendered from, scaled to fit, so opening the sheet
/// never builds a bitmap. The 3x image is rendered only when a share target asks for it
/// (`QuoteCardImage`).
struct ShareQuoteSheet: View {
    let quote: Quote

    @Environment(SocialStore.self) private var social
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// Selected friends, in tap order (the toast names them in this order).
    @State private var selected: [UUID] = []
    @State private var note = ""
    @State private var isSending = false
    @State private var isRetrying = false
    /// This sheet, as the owner of its terms check (`SocialStore.requireTerms(for:then:)`).
    @State private var termsOwner = UUID()
    @State private var detent: PresentationDetent = .large
    /// A small top crop of the card for the system share sheet's header, rendered after the sheet
    /// has opened.
    @State private var thumbnail: Image?
    @FocusState private var isNoteFocused: Bool

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40

    init(quote: Quote) {
        self.quote = quote
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    ShareCardPreview(quote: quote)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Image card preview")
                        .accessibilityValue(shareLine)
                    if friendsState == .noFriends {
                        noFriendsContent
                    } else {
                        sendSection
                        otherWaysSection(includesImage: true)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .groundBackground()
            .navigationTitle("Share quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // A send (and the terms check before it) finishes before the sheet can close.
        .interactiveDismissDisabled(isSending)
        .onDisappear {
            social.dropTermsChecks(for: termsOwner)
        }
        .task {
            await social.refreshIfStale()
        }
        .task {
            await renderThumbnail()
        }
        .onChange(of: friendIDs) { _, ids in
            // Someone unfriended you (or was blocked) while the sheet was open: an invisible
            // selection would make Send fail with "You can only share with friends".
            selected.removeAll { !ids.contains($0) }
        }
        .onChange(of: isNoteFocused) { _, focused in
            if focused { detent = .large }
        }
        // A note may be typed: a reminder tap waits until Share closes.
        .holdsDeepLinks()
    }

    // MARK: Friends state

    private enum FriendsState: Equatable {
        case list
        case noFriends
        case loading
        case failed
    }

    private var friendsState: FriendsState {
        if !social.friends.isEmpty { return .list }
        if social.hasLoaded { return .noFriends }
        return social.lastError == nil ? .loading : .failed
    }

    private var friendIDs: [UUID] {
        social.friendProfiles.map(\.id)
    }

    // MARK: Send to a friend

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionHeader("Send to a friend")
            switch friendsState {
            case .list:
                friendList
                    .disabled(isSending)
                noteField
                    .disabled(isSending)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    PrimaryButton(sendTitle, systemImage: "paperplane.fill", isLoading: isSending) {
                        send()
                    }
                    .disabled(selected.isEmpty || isNoteTooLong)
                    Text("They\u{2019}ll see it next time they open Quoted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Spacing.xxs)
                }
            case .loading, .noFriends:
                DelayedProgressView(label: "Loading friends")
                    .frame(maxWidth: .infinity, minHeight: 88)
            case .failed:
                loadFailed
            }
        }
    }

    private var loadFailed: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                Text("Couldn\u{2019}t load your friends")
                    .font(.headline)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if let error = social.lastError {
                Text(error.friendlyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("You can still share it another way below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                retry()
            } label: {
                // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                ZStack {
                    Text("Try again").opacity(isRetrying ? 0 : 1)
                    if isRetrying {
                        ProgressView()
                    }
                }
                .capsuleButtonLabel()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? "Loading friends" : "Try again")
            .padding(.top, Theme.Spacing.xxs)
        }
        .card()
    }

    private var friendList: some View {
        let friends = social.friendProfiles
        return CardContainer(padding: 0) {
            ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                if index > 0 {
                    HairlineDivider(leadingInset: Theme.Spacing.cardPadding + avatarSize + Theme.Spacing.s)
                }
                friendRow(friend)
            }
        }
    }

    private func friendRow(_ friend: Profile) -> some View {
        let isSelected = selected.contains(friend.id)
        return Button {
            toggle(friend.id)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                AvatarCircle(profile: friend)
                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(friend.handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // `.secondary`, not `.tertiary`, for the empty circle: it is the control's only mark.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.cardPadding)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Double-tap to remove" : "Double-tap to send to \(friend.displayName)")
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private var noteField: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .focused($isNoteFocused)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget - 2 * Theme.Spacing.s, alignment: .leading)
            if noteLength > Limits.noteMaxLength - 40 {
                Text("\(noteLength)/\(Limits.noteMaxLength)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isNoteTooLong ? Color.inlineError : Color.secondary)
                    .accessibilityLabel("\(noteLength) of \(Limits.noteMaxLength) characters")
            }
        }
        .card(padding: Theme.Spacing.s + Theme.Spacing.xxs)
    }

    // MARK: No friends yet

    /// With no friends, sharing the image is the action: one filled "Share image", the text as a row
    /// under it, and a quiet way to Friends (which closes the sheet).
    private var noFriendsContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            imageShareLink {
                Label("Share image", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primary)
            otherWaysSection(includesImage: false)
            VStack(alignment: .leading, spacing: 0) {
                Text("To send quotes inside Quoted, add friends by username.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    // Presented by the shell or by the full-screen quote, which closes too.
                    dismiss()
                    router.spotlight = nil
                    router.select(.friends)
                } label: {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text("Go to Friends")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Closes this sheet and opens Friends")
            }
            .padding(.horizontal, Theme.Spacing.xxs)
        }
    }

    // MARK: Other ways

    private func otherWaysSection(includesImage: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionHeader(includesImage ? "Other ways" : "Or share the text")
            CardContainer(padding: 0) {
                if includesImage {
                    imageShareLink {
                        otherWayRow("Share as image", systemImage: "photo")
                    }
                    .buttonStyle(.plain)
                    HairlineDivider(leadingInset: Theme.Spacing.cardPadding + 28 + Theme.Spacing.s)
                }
                ShareLink(item: shareLine) {
                    otherWayRow("Share as text", systemImage: "text.quote")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A ShareLink for the 3x card image, which renders only when a share target asks for it.
    @ViewBuilder
    private func imageShareLink<RowLabel: View>(@ViewBuilder label: () -> RowLabel) -> some View {
        let item = QuoteCardImage(quote: quote)
        if let thumbnail {
            ShareLink(item: item, preview: SharePreview("Quote card", image: thumbnail), label: label)
        } else {
            ShareLink(item: item, preview: SharePreview("Quote card"), label: label)
        }
    }

    /// The text form (docs/ui-spec.md §11): `“body” — Author, Source` on one line. Paste in Add
    /// splits it back into body, author and source.
    private var shareLine: String {
        let body = "\u{201C}\(quote.body.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
        guard let attribution = RichText.attribution(author: quote.author, source: quote.source) else { return body }
        return "\(body) \u{2014} \(attribution)"
    }

    private func otherWayRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.body)
                // The 28-pt column holds the glyph up to AX1; past that the glyph would spill into
                // the title, so it stops growing (the title still scales).
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "square.and.arrow.up")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.cardPadding)
        .frame(minHeight: Theme.Metrics.primaryButtonHeight)
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.xxs)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Actions

    private var noteLength: Int { Limits.length(of: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var isNoteTooLong: Bool { noteLength > Limits.noteMaxLength }

    private var sendTitle: LocalizedStringKey {
        // Only friends still in the list count (the selection is pruned when the list changes).
        let names = selected.compactMap { id in social.friendProfiles.first { $0.id == id }?.displayName }
        switch names.count {
        case 0:
            return "Send"
        case 1:
            let first = names[0].split(separator: " ").first.map(String.init) ?? names[0]
            return "Send to \(first)"
        default:
            return "Send to \(names.count) friends"
        }
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else {
            selected.append(id)
        }
    }

    /// After the Terms sheet if needed, waits for the server: closes on success; on failure (already
    /// toasted) keeps the selection and the note so the user can try again. Send shows progress from
    /// the tap on, through the terms check (a server round trip when the account's answer isn't
    /// cached as accepted).
    private func send() {
        guard !isSending else { return }
        isNoteFocused = false
        isSending = true
        Task {
            await social.requireTerms(for: termsOwner) { await deliver() }
            isSending = false
        }
    }

    /// The send itself: right away, or after Accept on the Terms sheet.
    private func deliver() async {
        isSending = true
        // The friends selected now: someone may have dropped out while the Terms sheet was up.
        let friends = Set(friendIDs)
        let recipients = selected.filter { friends.contains($0) }
        let sent = await social.send(quote, to: recipients, note: note)
        isSending = false
        if sent { dismiss() }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            await social.refresh(userInitiated: true)
            isRetrying = false
        }
    }

    /// Renders the share-sheet thumbnail once the sheet is up (a square top crop at 2x, so a long
    /// quote costs no more than a short one).
    private func renderThumbnail() async {
        guard thumbnail == nil else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let side = QuoteCardImage.width
        let renderer = ImageRenderer(content: QuoteCardImage.Content(quote: quote)
            .frame(width: side, height: side, alignment: .top)
            .clipped())
        renderer.scale = 2
        if let image = renderer.uiImage {
            thumbnail = Image(uiImage: image)
        }
    }
}

// MARK: - Card image

/// The quote card as a PNG for the system share sheet. The image is the `QuoteCard` with the wordmark,
/// light, at 3x (`QuoteCard.shareImage(for:)`); it is rendered only when the share target asks for
/// the data, so opening the share sheet (or a quote that is never shared as an image) costs nothing.
struct QuoteCardImage: Transferable {
    let quote: Quote

    /// The width `QuoteCard.shareImage(for:)` renders at.
    static let width: CGFloat = 390

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            try await card.pngData()
        }
        .suggestedFileName("Quote.png")
    }

    @MainActor
    private func pngData() throws -> Data {
        guard let data = QuoteCard.shareImage(for: quote, width: Self.width)?.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// The view the image is made of, for on-screen previews: the same composition as
    /// `QuoteCard.shareImage(for:)` (keep the two in step).
    struct Content: View {
        let quote: Quote

        var body: some View {
            QuoteCard(quote, inReminders: false, showsWordmark: true)
                .frame(width: QuoteCardImage.width - 2 * Theme.Spacing.gutter)
                .padding(Theme.Spacing.gutter)
                .background(Color.ground)
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, .large)
        }
    }
}

/// The image card as it will be sent, drawn live and scaled down to fit the sheet (at most
/// `maxHeight` tall), with a hairline and rounded corners so its light background reads as an
/// image in dark mode too.
private struct ShareCardPreview: View {
    let quote: Quote

    @State private var cardHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 240

    var body: some View {
        let width = QuoteCardImage.width
        let fitWidth = availableWidth > 0 ? availableWidth / width : 1
        let fitHeight = cardHeight > 0 ? min(maxHeight, 420) / cardHeight : 1
        let scale = min(1, fitWidth, fitHeight)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
        QuoteCardImage.Content(quote: quote)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width * scale, height: cardHeight * scale, alignment: .topLeading)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline))
            .opacity(cardHeight > 0 ? 1 : 0)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}

#Preview("Share") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            ShareQuoteSheet(quote: Samples.emerson)
                .toastHost()
        }
        .previewEnvironment()
}

#Preview("Share, no friends") {
    let model = AppModel.preview()
    model.social.seedPreview(friendships: [], conversations: [], messages: [], me: Samples.alex.id)
    return Color.ground
        .sheet(isPresented: .constant(true)) {
            ShareQuoteSheet(quote: Samples.shelley)
                .toastHost()
        }
        .previewEnvironment(model)
        .preferredColorScheme(.dark)
}
