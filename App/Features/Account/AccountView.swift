import OSLog
import QuotedCore
import SwiftUI

/// Account (docs/ui-spec.md §12): your profile (the username is selectable; with anonymous accounts a
/// line says the account lives on this iPhone), your display name (editable), Your profile (favorites
/// and whether friends see them), the Reminders status,
/// blocked users, the legal pages, support, sign out (email accounts only) and account deletion, with
/// the version in the footer.
///
/// Delete account asks first (it is permanent), shows progress while the server deletes everything,
/// and on failure explains why and offers Try again. On success `SessionStore` cleans up the device
/// and the app returns to Welcome, or with anonymous accounts starts a new one (Username).
/// `Route.account` maps to `AccountView()`.
struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ReminderStore.self) private var reminders
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isSigningOut = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var isEditingName = false

    init() {}

    var body: some View {
        List {
            header
            displayNameRow
            profileRow
            remindersRow
            safetySection
            aboutSection
            if session.canSignOut {
                signOutRow
            }
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
        .sheet(isPresented: $isEditingName) {
            DisplayNameSheet(profile: session.profile)
                .toastHost()
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
            if session.isAnonymous {
                Text("This permanently deletes your account, your quotes, your friends and every quote shared with you or by you. Quoted then starts over with a new, empty account. It can\u{2019}t be undone.")
            } else {
                Text("This permanently deletes your account, your quotes, your friends and every quote shared with you or by you. It can\u{2019}t be undone.")
            }
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
            // The avatar is only an initial; at accessibility sizes it would fill half the screen.
            if !dynamicTypeSize.isAccessibilitySize {
                if let profile = session.profile {
                    AvatarCircle(profile: profile, size: 72)
                        .padding(.bottom, Theme.Spacing.xxs)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(session.profile?.displayName ?? "Your account")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let handle = session.profile?.handle {
                // Selectable, so it can be copied to send to a friend (they add you by username).
                Text(verbatim: handle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let email = session.email {
                // Secondary, not tertiary: which account is signed in matters before Delete account.
                Text(verbatim: email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if session.isAnonymous {
                // The fact people need before they delete the app or change phones, so it sits with
                // who you are instead of under Delete account.
                Text("\(Image(systemName: "iphone")) This account lives on this iPhone, with no email or password. If you delete the app, it can\u{2019}t be recovered.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.xxs)
                    .padding(.horizontal, Theme.Spacing.s)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .marginPlainRow(top: Theme.Spacing.m, bottom: Theme.Spacing.xs)
    }

    // MARK: Display name

    /// Your display name, which friends and requesters see next to your username. Opens a small
    /// sheet to change or clear it.
    private var displayNameRow: some View {
        Button {
            isEditingName = true
        } label: {
            AccountRowLabel(
                title: "Display name",
                systemImage: "person.text.rectangle",
                value: customDisplayName ?? "Not set",
                accessory: .disclosure
            )
        }
        .accessibilityHint("Changes the name friends see next to your username")
        .disabled(session.profile == nil)
        .marginCardRow(.first, separatorInset: rowSeparatorInset, outerSpacing: Theme.Spacing.s)
    }

    /// The display name, or nil when there is none (`Profile.displayName` then falls back to the
    /// username).
    private var customDisplayName: String? {
        guard let profile = session.profile, profile.displayName != profile.username else { return nil }
        return profile.displayName
    }

    // MARK: Profile

    /// Your profile: your favorites and the switch that shows them to friends. The detail line says
    /// who can see them.
    private var profileRow: some View {
        let shows = session.profile?.showsFavorites == true
        return Button {
            if let profile = session.profile {
                router.push(.profile(profile))
            }
        } label: {
            AccountRowLabel(
                title: "Your profile",
                systemImage: "heart.text.square",
                detail: shows ? "Friends can see your favorites" : "Your favorites are private",
                accessory: .disclosure
            )
        }
        .accessibilityHint("Shows your favorites and who can see them")
        .disabled(session.profile == nil)
        .marginCardRow(.middle, separatorInset: rowSeparatorInset)
    }

    // MARK: Reminders

    /// "Reminders · On" with the same line the Reminders toggle shows ("3× a day · Next at 8:00 AM"),
    /// or "Off" with why. On only while reminders actually go out (`ReminderStore.isDelivering`).
    /// Notifications denied in iOS Settings can only be fixed there, so that row opens Settings; every
    /// other state opens Reminders.
    private var remindersRow: some View {
        let opensSettings = reminders.settings.enabled && reminders.permission == .denied
        let isOn = reminders.isDelivering
        return Button {
            if opensSettings {
                Task { await ReminderStore.openNotificationSettings() }
            } else {
                router.push(.reminders)
            }
        } label: {
            AccountRowLabel(
                title: "Reminders",
                systemImage: isOn ? "bell" : "bell.slash",
                detail: isOn || reminders.settings.enabled ? reminders.statusLine : nil,
                value: isOn ? "On" : "Off",
                accessory: opensSettings ? .external : .disclosure
            )
        }
        .accessibilityHint(opensSettings ? "Opens Quoted\u{2019}s notification settings" : "Opens Reminders")
        .marginCardRow(.last, separatorInset: rowSeparatorInset, outerSpacing: Theme.Spacing.s)
    }

    /// Separators line up with the titles: after the glyph column, or at the card's padding at
    /// accessibility sizes, where `AccountRowLabel` drops the glyph.
    private var rowSeparatorInset: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? Theme.Spacing.cardPadding : AccountRowLabel.separatorInset
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
            .marginCardRow(MarginCardPosition(index: index, count: rowCount), separatorInset: rowSeparatorInset)
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
            .contextMenu {
                Button("Copy Address", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = AppInfo.supportEmail
                    toasts.show("Copied the support address", style: .success)
                }
            }
            .marginCardRow(MarginCardPosition(index: rowCount - 1, count: rowCount), separatorInset: rowSeparatorInset)
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
        // A group of its own, 24 pt from About whether or not Sign out shows, so it never reads as
        // a fifth About row.
        .marginCardRow(.single, outerSpacing: Theme.Spacing.l, bottomSpacing: 0)
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
///
/// At accessibility text sizes the glyph column goes and the value joins the detail line under the
/// title ("On · 3× a day · Next at 8:00 AM"), so titles get the full width and never break mid-word.
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

    /// Lines separators up with the titles, after the glyph column (at the default text size; at
    /// accessibility sizes there is no glyph column, so use the card padding).
    nonisolated static let separatorInset: CGFloat = Theme.Spacing.cardPadding + 28 + Theme.Spacing.s

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: Theme.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if let stackedDetail {
                            Text(stackedDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    accessoryGlyph
                }
            } else {
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
                            .lineLimit(1)
                    }
                    accessoryGlyph
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The value and the detail on one line, for the stacked layout.
    private var stackedDetail: String? {
        let parts = [value, detail].compactMap(\.self).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var accessoryGlyph: some View {
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
}

// MARK: Display name sheet

/// "Display name": a field with the current name, Save and Cancel. Blank clears it, so friends see
/// your username. Checks the name like the server does (1–50 characters) and shows a failed save
/// inline, keeping what was typed.
private struct DisplayNameSheet: View {
    let profile: Profile?

    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(profile: Profile?) {
        self.profile = profile
        let current = profile.flatMap { $0.displayName == $0.username ? nil : $0.displayName }
        _name = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    TextField("Display name", text: $name, prompt: Text(profile?.username ?? "Display name"))
                        .textContentType(.nickname)
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(save)
                        .disabled(isSaving)
                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                        .card(padding: Theme.Spacing.s + Theme.Spacing.xxs)
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.inlineError)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(helpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.m)
            }
            .scrollBounceBehavior(.basedOnSize)
            .groundBackground()
            .navigationTitle("Display name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving")
                    } else {
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .disabled(!hasChanges)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
        .onAppear { isFocused = true }
        .onChange(of: name) { error = nil }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        // A name may be typed: a reminder tap waits until this closes.
        .holdsDeepLinks()
    }

    private var helpText: String {
        if let handle = profile?.handle {
            return "Friends see it next to \(handle). Leave it blank to show your username instead."
        }
        return "Friends see it next to your username. Leave it blank to show your username instead."
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        let current = profile.flatMap { $0.displayName == $0.username ? nil : $0.displayName } ?? ""
        return trimmed != current
    }

    private func save() {
        guard !isSaving, hasChanges else { return }
        let newName: String?
        if trimmed.isEmpty {
            newName = nil
        } else {
            do throws(DisplayNameError) {
                newName = try DisplayName.validate(trimmed)
            } catch {
                self.error = error.errorDescription
                return
            }
        }
        isSaving = true
        Task {
            do {
                try await session.updateDisplayName(newName)
                isSaving = false
                toasts.show(newName == nil ? "Display name cleared" : "Display name updated", style: .success)
                dismiss()
            } catch {
                isSaving = false
                let message = error.friendlyMessage
                self.error = message.isEmpty ? "Couldn\u{2019}t save your name. Try again." : message
            }
        }
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
