import QuotedCore
import QuotedKit
import SwiftUI

/// A person's profile: who they are and their favorite quotes.
///
/// - **A friend's profile** (from the Friends list): their favorites, newest first, each with Save
///   (or "In your library" when you already have that quote). Favorites are private unless the
///   friend turned on "Show favorites to friends"; then only accepted friends see them, through
///   `public.friend_favorites`. Otherwise the page says so.
/// - **Your own profile** (Account > Your profile): the switch that shows your favorites to friends,
///   and your favorites, which open the quote's detail.
///
/// A friend's profile has a `…` menu with Report and Block (App Store Guideline 1.2: what a friend
/// shows you can be reported, and its author blocked, from where you see it).
///
/// Cards follow the Friends tab (Margin cards). Pull to refresh.
struct ProfileView: View {
    let profile: Profile
    /// Favorites to show without loading (previews only).
    private let seededFavorites: [FriendFavorite]?

    @Environment(SessionStore.self) private var session
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A friend's favorites as last loaded, or nil before the first load.
    @State private var favorites: [FriendFavorite]?
    /// The friend's profile as last loaded (their name and setting may have changed).
    @State private var current: Profile?
    @State private var loadError: QuotedError?
    @State private var isUpdatingSetting = false
    /// The switch's new value while the server saves it, so it doesn't snap back meanwhile.
    @State private var pendingShows: Bool?
    /// Favorites being saved right now (their Save button is disabled).
    @State private var saving: Set<UUID> = []
    /// The library ID each favorite's copy gets, kept so a retry after a lost answer can't add a
    /// second copy.
    @State private var copyIDs: [UUID: UUID] = [:]
    @State private var isReporting = false
    @State private var isBlocking = false

    init(profile: Profile, favorites: [FriendFavorite]? = nil) {
        self.profile = profile
        seededFavorites = favorites
        _favorites = State(initialValue: favorites)
    }

    var body: some View {
        List {
            header
            if isMe {
                ownContent
            } else {
                friendContent
            }
        }
        .marginCardList()
        .navigationTitle(isMe ? "Your profile" : person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isMe, isFriend {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Report \(person.handle)\u{2026}", systemImage: "flag") {
                            isReporting = true
                        }
                        Button("Block \(person.handle)", systemImage: "hand.raised", role: .destructive) {
                            isBlocking = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("More")
                    // On the button, so iOS 26 points the confirmation's popover at it.
                    .reportUserConfirmation(isPresented: $isReporting, profile: person, context: .profile)
                    .blockConfirmation(isPresented: $isBlocking, name: person.displayName, handle: person.handle) {
                        await social.block(person)
                    }
                }
            }
        }
        .task(id: profile.id) {
            guard !isMe, seededFavorites == nil else { return }
            // An unfriend or block from another device should show here, not a stale list.
            async let friendships: Void = social.refreshIfStale()
            await load()
            await friendships
        }
        .refreshable {
            if isMe {
                async let me: Void = session.refreshProfile()
                await library.refresh(userInitiated: true)
                await me
            } else {
                async let friendships = social.refresh()
                await load(userInitiated: true)
                _ = await friendships
            }
        }
    }

    // MARK: Data

    private var isMe: Bool { session.profile?.id == profile.id }

    /// The freshest copy of the person: yours from the session, a friend's as last loaded.
    private var person: Profile {
        if isMe { return session.profile ?? profile }
        return current ?? profile
    }

    /// Whether you and this person are friends right now (not a request, not unfriended).
    private var isFriend: Bool {
        social.friends.contains { $0.profile.id == profile.id }
    }

    /// Loads the friend's profile and favorites. A failure with nothing on screen shows the error
    /// card; with favorites already shown it keeps them, and toasts only when the user asked
    /// (pull to refresh, Try Again), so coming back to the page stays quiet.
    private func load(userInitiated: Bool = false) async {
        do {
            let loaded = try await social.profileAndFavorites(of: profile.id)
            if let latest = loaded.profile { current = latest }
            favorites = loaded.favorites
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            if favorites == nil {
                loadError = QuotedError(error)
            } else if userInitiated {
                toasts.show(error: error)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Only an initial; at accessibility sizes it would fill half the screen.
            if !dynamicTypeSize.isAccessibilitySize {
                AvatarCircle(profile: person, size: 72)
                    .padding(.bottom, Theme.Spacing.xxs)
            }
            Text(person.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(verbatim: person.handle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .marginPlainRow(top: Theme.Spacing.m, bottom: Theme.Spacing.xs)
    }

    // MARK: Your profile

    @ViewBuilder
    private var ownContent: some View {
        Toggle(isOn: showsFavoritesBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show favorites to friends")
                Text(showsFavorites
                    ? "Friends can see the quotes you heart."
                    : "Only you can see your favorites.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isUpdatingSetting || session.profile == nil)
        .marginCardRow(.single, outerSpacing: Theme.Spacing.s)

        Text("Your other quotes always stay private.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .marginPlainRow(top: Theme.Spacing.xxs)

        let mine = library.favorites
        MarginSectionHeader(mine.isEmpty ? "Favorites" : "Favorites (\(mine.count))")
        if mine.isEmpty {
            messageCard(
                systemImage: "heart",
                title: "No favorites yet",
                message: "Tap \(Image(systemName: "heart")) on any quote to add it here.",
                // VoiceOver would read the glyph as "love"; the button it means is "Favorite".
                spokenMessage: "Tap Favorite on any quote to add it here."
            )
        } else {
            let ids = mine.map(\.id)
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, quote in
                NavigationLink(value: Route.quote(id: quote.id, contextIDs: ids)) {
                    // Every row here is a favorite, so no heart on each.
                    QuoteRow(quote, favorite: false, style: .row)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .marginCardRow(MarginCardPosition(index: index, count: mine.count), outerSpacing: 0)
            }
        }
    }

    /// The switch's value: the one being saved, else yours as the server last said.
    private var showsFavorites: Bool { pendingShows ?? person.showsFavorites }

    private var showsFavoritesBinding: Binding<Bool> {
        Binding(
            get: { showsFavorites },
            set: { shows in
                pendingShows = shows
                isUpdatingSetting = true
                Task {
                    defer {
                        pendingShows = nil
                        isUpdatingSetting = false
                    }
                    do {
                        try await session.setShowsFavorites(shows)
                    } catch {
                        toasts.show(error: error)
                    }
                }
            }
        )
    }

    // MARK: A friend's profile

    @ViewBuilder
    private var friendContent: some View {
        MarginSectionHeader("Favorites")
        if !isFriend && social.hasLoaded {
            messageCard(
                systemImage: "person.2",
                title: "You\u{2019}re not friends",
                message: "Only friends can see each other\u{2019}s favorites."
            )
        } else if let favorites, !favorites.isEmpty {
            ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
                FavoriteRow(
                    favorite: favorite,
                    isInLibrary: library.containsCopy(of: favorite),
                    isSaving: saving.contains(favorite.id),
                    onSave: { save(favorite) }
                )
                .marginCardRow(MarginCardPosition(index: index, count: favorites.count))
            }
        } else if favorites != nil, !person.showsFavorites {
            messageCard(
                systemImage: "lock",
                title: "\(person.displayName) keeps favorites private",
                message: "They can choose to show them in their profile."
            )
        } else if favorites != nil {
            messageCard(
                systemImage: "heart",
                title: "No favorites yet",
                message: "Quotes \(person.displayName) hearts show up here."
            )
        } else if let error = loadError {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Couldn\u{2019}t load favorites")
                    .font(.headline)
                Text(error.userMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    // Back to the spinner while it retries; the card returns if it fails again.
                    loadError = nil
                    Task { await load(userInitiated: true) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.top, Theme.Spacing.xxs)
            }
            .marginCardRow(.single)
        } else {
            DelayedProgressView(label: "Loading favorites")
                .frame(maxWidth: .infinity)
                .marginPlainRow(top: Theme.Spacing.l)
        }
    }

    private func save(_ favorite: FriendFavorite) {
        guard !saving.contains(favorite.id) else { return }
        saving.insert(favorite.id)
        let id = copyIDs[favorite.id] ?? UUID()
        copyIDs[favorite.id] = id
        Task {
            // The ID only covers a retry after a lost answer; once saved, a later Save (after
            // deleting the copy) is a new quote.
            if await library.saveFavorite(favorite, id: id) != nil {
                copyIDs[favorite.id] = nil
            }
            saving.remove(favorite.id)
        }
    }

    // MARK: Parts

    private func messageCard(
        systemImage: String,
        title: String,
        message: LocalizedStringKey,
        spokenMessage: String? = nil
    ) -> some View {
        let layout = IconTile.layout(for: dynamicTypeSize)
        return layout {
            IconTile(systemName: systemImage, tone: .muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(spokenMessage ?? "")"), isEnabled: spokenMessage != nil)
        .marginCardRow(.single)
    }
}

/// One of a friend's favorites: the quote and its attribution (with the verified seal), then Save,
/// or "In your library" once you have the same text and author.
private struct FavoriteRow: View {
    let favorite: FriendFavorite
    let isInLibrary: Bool
    let isSaving: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            QuoteRow(favorite, inReminders: false)
            if isInLibrary {
                Label("In your library", systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
            } else {
                Button(action: onSave) {
                    Label("Save", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .capsuleButtonLabel()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color.accentColor)
                .disabled(isSaving)
                .accessibilityHint("Adds this quote to your library")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Your profile") {
    NavigationStack {
        ProfileView(profile: Samples.alex)
    }
    .previewEnvironment()
}

#Preview("A friend's profile") {
    NavigationStack {
        ProfileView(profile: Samples.maya, favorites: Samples.mayaFavorites)
    }
    .previewEnvironment()
}

#Preview("A friend's profile, private") {
    NavigationStack {
        ProfileView(profile: Samples.jordan, favorites: [])
    }
    .previewEnvironment()
}
