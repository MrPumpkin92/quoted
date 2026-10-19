import OSLog
import QuotedCore
import SwiftUI

/// Account (docs/ui-spec.md §12): your profile, notification status, blocked users, the legal pages,
/// support, sign out and account deletion, with the version in the footer.
///
/// Delete account asks first (it is permanent), shows progress while the server deletes everything,
/// and on failure explains why and offers Try again. On success `SessionStore` cleans up the device
/// and the app returns to Welcome. `Route.account` maps to `AccountView()`.
struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ReminderStore.self) private var reminders
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isSigningOut = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    init() {}

    var body: some View {
        List {
            header
            notificationsSection
            safetySection
            aboutSection
            signOutRow
            deleteRow
            footer
        }
        .marginCardList()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDeleting || isSigningOut)
        .navigationBarBackButtonHidden(isDeleting)
        .overlay {
            if isDeleting {
                deletingOverlay
            }
        }
        .task {
            await reminders.refreshPermission()
        }
        .confirmationDialog("Sign out of Quoted?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your quotes stay in your account. Reminders and the widget on this iPhone stop until you sign in again.")
        }
        .alert("Delete your account?", isPresented: $isConfirmingDelete) {
            Button("Delete Account", role: .destructive, action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, your quotes, your friends and every quote shared with you or by you. It can\u{2019}t be undone.")
        }
        .alert("Couldn\u{2019}t delete your account", isPresented: isShowingDeleteError, presenting: deleteError) { _ in
            Button("Try Again", action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let profile = session.profile {
                AvatarCircle(profile: profile, size: 72)
                    .padding(.bottom, Theme.Spacing.xxs)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(session.profile?.displayName ?? "Your account")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let handle = session.profile?.handle {
                Text(handle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if let email = session.email {
                // Secondary, not tertiary: which account is signed in matters before Delete account.
                Text(verbatim: email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .marginPlainRow(top: Theme.Spacing.m, bottom: Theme.Spacing.xs)
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        let status = notificationStatus
        Button {
            if status.opensSettings {
                Task { await ReminderStore.openNotificationSettings() }
            } else {
                router.push(.reminders)
            }
        } label: {
            AccountRowLabel(
                title: "Notifications",
                systemImage: status.isOn ? "bell" : "bell.slash",
                detail: status.detail,
                value: status.isOn ? "On" : "Off",
                accessory: status.opensSettings ? .external : .disclosure
            )
        }
        .accessibilityHint(status.opensSettings ? "Opens Quoted\u{2019}s notification settings" : "Opens Reminders")
        .marginCardRow(.single, outerSpacing: Theme.Spacing.s)
    }

    /// On only when Quoted may notify and the Reminders toggle is on. Denied permission can only be
    /// fixed in iOS Settings, so that row opens Settings; every other state opens Reminders.
    private var notificationStatus: (isOn: Bool, detail: String, opensSettings: Bool) {
        switch reminders.permission {
        case .denied:
            (false, "Turned off in iOS Settings", true)
        case .notDetermined:
            (false, "Notifications aren\u{2019}t allowed yet", false)
        case .authorized:
            reminders.settings.enabled
                ? (true, reminders.scheduleSummary, false)
                : (false, "Reminders are turned off", false)
        }
    }

    // MARK: Privacy and safety

    @ViewBuilder
    private var safetySection: some View {
        MarginSectionHeader("Privacy and safety")
        Button {
            router.push(.blockedUsers)
        } label: {
            AccountRowLabel(title: "Blocked users", systemImage: "hand.raised", accessory: .disclosure)
        }
        .marginCardRow(.single)
    }

    // MARK: About

    @ViewBuilder
    private var aboutSection: some View {
        let supportURL = AppInfo.supportMailURL
        let pages: [(LegalPage, String, String)] = [
            (.communityGuidelines, "Community guidelines", "person.2.wave.2"),
            (.terms, "Terms of use", "doc.text"),
            (.privacy, "Privacy policy", "lock"),
        ]
        let rowCount = pages.count + (supportURL == nil ? 0 : 1)
        MarginSectionHeader("About")
        ForEach(Array(pages.enumerated()), id: \.element.0) { index, item in
            Button {
                router.push(.textPage(item.0))
            } label: {
                AccountRowLabel(title: item.1, systemImage: item.2, accessory: .disclosure)
            }
            .marginCardRow(MarginCardPosition(index: index, count: rowCount), separatorInset: AccountRowLabel.separatorInset)
        }
        if let supportURL {
            Button {
                openURL(supportURL)
            } label: {
                AccountRowLabel(
                    title: "Contact support",
                    systemImage: "envelope",
                    detail: AppInfo.supportEmail,
                    accessory: .external
                )
            }
            .accessibilityHint("Writes an email to support")
            .marginCardRow(MarginCardPosition(index: rowCount - 1, count: rowCount), separatorInset: AccountRowLabel.separatorInset)
        }
    }

    // MARK: Sign out and delete

    private var signOutRow: some View {
        Button {
            isConfirmingSignOut = true
        } label: {
            HStack {
                Text("Sign out")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if isSigningOut {
                    ProgressView()
                        .accessibilityLabel("Signing out")
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .marginCardRow(.single, outerSpacing: Theme.Spacing.s)
    }

    private var deleteRow: some View {
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Text("Delete account")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.xxs)
                .contentShape(Rectangle())
        }
        .marginCardRow(.single)
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text("Deleting your account permanently removes your quotes, friends and shares from our servers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(AppInfo.versionLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.l)
        }
        .marginPlainRow(top: Theme.Spacing.xs, bottom: Theme.Spacing.xl)
    }

    private var deletingOverlay: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
                .controlSize(.large)
            Text("Deleting your account\u{2026}")
                .font(.headline)
        }
        .padding(Theme.Spacing.l)
        .background(.regularMaterial, in: Theme.cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Actions

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await session.signOut()
            isSigningOut = false
        }
    }

    private func deleteAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        Task {
            do {
                try await session.deleteAccount()
                toasts.show("Your account was deleted", style: .success)
            } catch {
                Logger.session.error("Account deletion failed: \(String(describing: error), privacy: .public)")
                let message = error.friendlyMessage
                deleteError = message.isEmpty ? "Something went wrong. Your account is still here; try again." : message
                isDeleting = false
            }
        }
    }

    private var isShowingDeleteError: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }
}

// MARK: Row

/// An Account row: an accent glyph, a title (with an optional detail line), an optional value and a
/// trailing chevron (pushes) or arrow (leaves the app).
struct AccountRowLabel: View {
    enum Accessory {
        case disclosure
        case external
        case none
    }

    let title: String
    let systemImage: String
    var detail: String?
    var value: String?
    var accessory: Accessory = .disclosure

    /// Lines separators up with the titles, after the glyph column.
    nonisolated static let separatorInset: CGFloat = Theme.Spacing.cardPadding + 28 + Theme.Spacing.s

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            switch accessory {
            case .disclosure:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            case .external:
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Account") {
    NavigationStack { AccountView() }
        .previewEnvironment()
}

#Preview("Account dark") {
    NavigationStack { AccountView() }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
