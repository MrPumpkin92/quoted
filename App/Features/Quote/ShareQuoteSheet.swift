import QuotedCore
import SwiftUI

/// The share sheet (docs/ui-spec.md §11), in two parts:
///
/// - **Send to a friend:** tap friends to select them, add an optional note (up to 280 characters) and
///   Send. Send shows progress while `SocialStore.send` waits for the server; on success the sheet
///   closes and the store shows "Sent to Maya" with Undo (Undo deletes the sent shares). On failure the
///   store toasts and the sheet stays open with the selection and the note. With no friends yet, a link
///   to the Friends tab.
/// - **Other ways:** the system share sheet with the `QuoteCard` image (rendered at 3x, light), or the
///   plain text `“body” — Author, Source`.
struct ShareQuoteSheet: View {
    let quote: Quote

    @Environment(SocialStore.self) private var social
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// Selected friends, in tap order (the toast names them in this order).
    @State private var selected: [UUID] = []
    @State private var note = ""
    @State private var cardImage: Image?
    @State private var isSending = false
    @FocusState private var isNoteFocused: Bool

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(quote: Quote) {
        self.quote = quote
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    preview
                    sendSection
                    otherWaysSection
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
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task {
            renderCardImage()
            await social.refreshIfStale()
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            QuoteText(quote, style: .compact, lineLimit: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttributionLine(quote)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sharing: \(shareLine)")
    }

    // MARK: Send to a friend

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionHeader("Send to a friend")
            if social.friends.isEmpty {
                if social.hasLoaded {
                    noFriends
                } else {
                    DelayedProgressView(label: "Loading friends")
                        .frame(maxWidth: .infinity, minHeight: 88)
                }
            } else {
                friendList
                    .disabled(isSending)
                noteField
                    .disabled(isSending)
                PrimaryButton(sendTitle, systemImage: "paperplane.fill", isLoading: isSending) {
                    send()
                }
                .disabled(selected.isEmpty || isNoteTooLong)
            }
        }
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
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

    private var noFriends: some View {
        let tileLayout = IconTile.layout(for: dynamicTypeSize, alignment: .top)
        return CardContainer {
            tileLayout {
                IconTile(systemName: "person.2.fill")
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("Add friends to send quotes in Quoted")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        router.dismissSheet()
                        router.select(.friends)
                    } label: {
                        // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                        Text("Go to Friends")
                            .fontWeight(.semibold)
                            .capsuleButtonLabel()
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    // MARK: Other ways

    private var otherWaysSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionHeader("Other ways")
            CardContainer(padding: 0) {
                if let cardImage {
                    ShareLink(item: cardImage, preview: SharePreview("Quote card", image: cardImage)) {
                        otherWayRow("Share as image", systemImage: "photo")
                    }
                    .buttonStyle(.plain)
                } else {
                    otherWayRow("Share as image", systemImage: "photo")
                        .opacity(0.4)
                        .accessibilityLabel("Share as image, preparing")
                }
                HairlineDivider(leadingInset: Theme.Spacing.cardPadding + 28 + Theme.Spacing.s)
                ShareLink(item: shareLine) {
                    otherWayRow("Share as text", systemImage: "text.quote")
                }
                .buttonStyle(.plain)
            }
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
        switch selected.count {
        case 0:
            return "Send"
        case 1:
            let name = social.friendProfiles.first { $0.id == selected[0] }?.displayName ?? "1 friend"
            let first = name.split(separator: " ").first.map(String.init) ?? name
            return "Send to \(first)"
        default:
            return "Send to \(selected.count) friends"
        }
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else {
            selected.append(id)
        }
    }

    /// Waits for the server: closes on success; on failure (already toasted) keeps the selection and
    /// the note so the user can try again.
    private func send() {
        guard !isSending else { return }
        isNoteFocused = false
        isSending = true
        Task {
            let sent = await social.send(quote, to: selected, note: note)
            isSending = false
            if sent { dismiss() }
        }
    }

    private func renderCardImage() {
        guard cardImage == nil, let image = QuoteCard.shareImage(for: quote) else { return }
        cardImage = Image(uiImage: image)
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
    model.social.seedPreview(friendships: [], inbox: [], me: Samples.alex.id)
    return Color.ground
        .sheet(isPresented: .constant(true)) {
            ShareQuoteSheet(quote: Samples.shelley)
                .toastHost()
        }
        .previewEnvironment(model)
        .preferredColorScheme(.dark)
}
