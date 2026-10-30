import QuotedCore
import SwiftUI
import UIKit

/// The Profile tab root (docs/ui-spec.md §10a): your `ProfileHeader` and the gear that pushes Settings,
/// the only way in. Posts, playlists, favorites and View As come with Stage 6; until then one quiet
/// line under the header says what the username is for. Press and hold the header to copy or share
/// your username. Pull to refresh re-reads your profile.
struct MyProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    init() {}

    var body: some View {
        List {
            header
            Text("Friends add you by your exact username.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .marginPlainRow(top: Theme.Spacing.xxs, bottom: Theme.Spacing.l)
        }
        .marginCardList()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("profile.settings")
            }
        }
        .refreshable {
            await session.refreshProfile()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let profile = session.profile {
            ProfileHeader(profile: profile)
                // Even space around the header, on Ground, so the press-and-hold preview is the header
                // as a card instead of the list cell with its uneven row insets.
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.ground)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contextMenu {
                    Button("Copy Username", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = profile.handle
                        toasts.show("Copied \(profile.handle)", style: .success)
                    }
                    ShareLink(item: UsernameInvite.text(profile.handle)) {
                        Label("Share Username\u{2026}", systemImage: "square.and.arrow.up")
                    }
                }
                // With the padding: 24 pt above the avatar, 16 pt down to the line below.
                .marginPlainRow(top: Theme.Spacing.l - Theme.Spacing.s)
        } else {
            DelayedProgressView(label: "Loading your profile")
                .frame(maxWidth: .infinity, minHeight: 120)
                .marginPlainRow()
        }
    }
}

/// A person at the top of a profile (docs/ui-spec.md §10a): a 72-pt avatar (left out at accessibility
/// sizes, where an initial would fill the screen), the display name in `.title2` semibold (it wraps)
/// and the @username in `.body` `.secondary` on one line, shrinking to 0.8 before it truncates, all
/// centred. No counts, bio or photo. VoiceOver: "Alex Rivera, @alex".
struct ProfileHeader: View {
    let profile: Profile

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if !dynamicTypeSize.isAccessibilitySize {
                AvatarCircle(profile: profile, size: 72)
                    .padding(.bottom, Theme.Spacing.xxs)
            }
            Text(profile.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(verbatim: profile.handle)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.displayName), \(profile.handle)")
    }
}

#Preview("Profile") {
    NavigationStack { MyProfileView() }
        .previewEnvironment()
}

#Preview("Profile, AX3") {
    NavigationStack { MyProfileView() }
        .previewEnvironment()
        .dynamicTypeSize(.accessibility3)
}
