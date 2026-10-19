import Accessibility
import SwiftUI

/// "Choose a new password" after a password-reset link signed the user in
/// (`SessionStore.isRecoveringPassword`). `RootView` presents it as a sheet over whatever phase the
/// session is in.
///
/// The Welcome form's look: a card with New password and Confirm password, the two rules (length,
/// match) ticking as they are met, an inline error under the card, and **Save password**. Save calls
/// `SessionStore.setNewPassword(_:)`, which closes the sheet and toasts "Password updated" on success,
/// so the user carries on signed in. "Not now" calls `cancelPasswordRecovery()`: they stay signed in
/// and the old password keeps working.
struct NewPasswordView: View {
    @Environment(SessionStore.self) private var session

    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorText: String?
    @State private var isSaving = false
    @FocusState private var focus: Field?
    @ScaledMetric(relativeTo: .title) private var tileSize: CGFloat = 56

    private enum Field: Hashable {
        case password
        case confirmation
    }

    private static let minimumLength = SessionStore.minimumPasswordLength

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    header
                    fields
                    rules
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.inlineError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                    PrimaryButton("Save password", isLoading: isSaving, action: save)
                        .disabled(password.isEmpty || confirmation.isEmpty)
                        .padding(.top, Theme.Spacing.xs)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy, value: errorText)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .groundBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { session.cancelPasswordRecovery() }
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .sensoryFeedback(.error, trigger: errorText) { _, new in new != nil }
        .onChange(of: errorText) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .onAppear { focus = .password }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Image(systemName: "key")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: tileSize, height: tileSize)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .accessibilityHidden(true)
            Text("Choose a new password")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            subtitle
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var subtitle: Text {
        if let email = session.email {
            let address = Text(verbatim: email)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            return Text("You\u{2019}re signed in as \(address). Choose a new password to finish resetting it.")
        }
        return Text("You\u{2019}re signed in. Choose a new password to finish resetting it.")
    }

    private var fields: some View {
        CardContainer(padding: 0) {
            AuthFieldRow(label: "New password", onTap: { focus = .password }) {
                SecureField(
                    "New password",
                    text: $password,
                    prompt: Text("\(Self.minimumLength)+ characters")
                )
                .textContentType(.newPassword)
                .submitLabel(.next)
                .focused($focus, equals: .password)
                .onSubmit { focus = .confirmation }
            }
            HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
            AuthFieldRow(label: "Confirm password", onTap: { focus = .confirmation }) {
                SecureField("Confirm password", text: $confirmation, prompt: Text("Type it again"))
                    .textContentType(.newPassword)
                    .submitLabel(.done)
                    .focused($focus, equals: .confirmation)
                    .onSubmit(save)
            }
        }
        .disabled(isSaving)
        .onChange(of: password) { errorText = nil }
        .onChange(of: confirmation) { errorText = nil }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            PasswordRule(text: "At least \(Self.minimumLength) characters", isMet: isLongEnough)
            PasswordRule(text: "Both passwords match", isMet: passwordsMatch)
        }
    }

    // MARK: Validation

    private var isLongEnough: Bool { password.count >= Self.minimumLength }

    private var passwordsMatch: Bool { !confirmation.isEmpty && password == confirmation }

    // MARK: Actions

    private func save() {
        guard !isSaving else { return }
        errorText = nil
        if !isLongEnough {
            errorText = "Use at least \(Self.minimumLength) characters for your password."
            focus = .password
            return
        }
        if !passwordsMatch {
            errorText = "The passwords don\u{2019}t match. Type the new password again."
            focus = .confirmation
            return
        }
        focus = nil
        isSaving = true
        let password = self.password
        Task {
            defer { isSaving = false }
            do {
                try await session.setNewPassword(password)
            } catch {
                let message = error.friendlyMessage
                errorText = message.isEmpty ? nil : message
            }
        }
    }
}

/// One password rule under the card: a check in the accent once it is met, an empty circle until then.
private struct PasswordRule: View {
    let text: String
    let isMet: Bool

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(isMet ? .primary : .secondary)
        } icon: {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isMet ? Color.accentColor : Color.secondary)
        }
        .font(.footnote)
        .animation(.snappy, value: isMet)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(isMet ? "Done" : "Not yet")
    }
}

#Preview("New password") {
    NewPasswordView()
        .previewEnvironment()
}

#Preview("New password, dark, large type") {
    NewPasswordView()
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
