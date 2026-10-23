// Welcome / Sign in ⇄ Create account → Check your inbox (docs/ui-spec.md §1).
//
// RootView shows `AuthFlowView()` while `SessionStore.phase == .signedOut`. Signing in (or a sign-up
// that needs no confirmation) moves the phase on by itself; a sign-up that needs confirmation sets
// `SessionStore.pendingConfirmationEmail`, which swaps the form for "Check your inbox".

import Accessibility
import QuotedCore
import SwiftUI

struct AuthFlowView: View {
    @Environment(SessionStore.self) private var session

    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var legalPage: LegalPage?

    init() {}

    var body: some View {
        ZStack {
            if let address = session.pendingConfirmationEmail {
                CheckEmailView(email: address, password: password)
                    .transition(.opacity)
            } else {
                AuthFormView(mode: $mode, email: $email, password: $password) { page in
                    legalPage = page
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.pendingConfirmationEmail)
        .sheet(item: $legalPage) { page in
            LegalSheet(page: page)
        }
    }
}

// MARK: - Mode

/// Which form the Welcome screen shows.
enum AuthMode: Hashable, Sendable {
    case signIn
    case createAccount

    /// The other mode (the "New here? / Already have an account?" link).
    var toggled: AuthMode { self == .signIn ? .createAccount : .signIn }
}

// MARK: - Form

/// Wordmark, subtitle, the hanging Shelley quote, then the email/password card, the primary action and
/// the secondary links. Scrolls so the card and button stay above the keyboard.
private struct AuthFormView: View {
    @Binding var mode: AuthMode
    @Binding var email: String
    @Binding var password: String
    let onShowLegal: (LegalPage) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts

    @FocusState private var focus: AuthFocus?
    @State private var errorText: String?
    @State private var isSubmitting = false
    @State private var isSendingReset = false

    private enum AuthFocus: Hashable {
        case email
        case password
    }

    private static let formID = "auth-form"
    /// Supabase's own minimum is lower; the Create account screen promises "8+ characters", and
    /// `NewPasswordView` uses the same rule.
    static let minimumPasswordLength = SessionStore.minimumPasswordLength

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Spacer(minLength: Theme.Spacing.xl)
                        hero
                        Spacer(minLength: Theme.Spacing.xl)
                        form
                            .id(Self.formID)
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.m)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                // No navigation bar here: keep scrolled text out from under the status bar.
                .clipped()
                .onChange(of: focus) { _, newFocus in
                    guard newFocus != nil else { return }
                    withAnimation(.snappy) { scroller.scrollTo(Self.formID, anchor: .bottom) }
                }
                .onChange(of: geometry.size.height) { oldHeight, newHeight in
                    // The keyboard just came up: keep the fields and the button above it.
                    guard focus != nil, newHeight < oldHeight else { return }
                    withAnimation(.snappy) { scroller.scrollTo(Self.formID, anchor: .bottom) }
                }
            }
        }
        .groundBackground()
        .sensoryFeedback(.error, trigger: errorText) { _, new in new != nil }
        .onChange(of: errorText) { _, new in
            if let new, !new.isEmpty {
                AccessibilityNotification.Announcement(new).post()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Wordmark(textStyle: .title2)
            Text("Keep the words that move you, and see them again every day.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hero: some View {
        WelcomeHero()
    }

    private var form: some View {
        VStack(spacing: Theme.Spacing.m) {
            fields
            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.inlineError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            PrimaryButton(mode == .signIn ? "Sign in" : "Create account", isLoading: isSubmitting) {
                submit()
            }
            .padding(.top, Theme.Spacing.xs)
            links
        }
        .animation(.snappy, value: errorText)
    }

    private var fields: some View {
        CardContainer(padding: 0) {
            AuthFieldRow(label: "Email", onTap: { focus = .email }) {
                TextField("Email", text: $email, prompt: Text(verbatim: "name@example.com"))
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }
            HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
            AuthFieldRow(label: "Password", onTap: { focus = .password }) {
                SecureField(
                    "Password",
                    text: $password,
                    prompt: Text(mode == .signIn ? "Your password" : "\(Self.minimumPasswordLength)+ characters")
                )
                .textContentType(mode == .signIn ? .password : .newPassword)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { submit() }
                // A new content type only takes effect on a fresh field.
                .id(mode)
            }
        }
        .disabled(isSubmitting)
        .onChange(of: email) { errorText = nil }
        .onChange(of: password) { errorText = nil }
    }

    @ViewBuilder
    private var links: some View {
        VStack(spacing: 0) {
            switch mode {
            case .signIn:
                Button {
                    sendPasswordReset()
                } label: {
                    ZStack {
                        Text("Forgot password?").opacity(isSendingReset ? 0 : 1)
                        if isSendingReset {
                            ProgressView().accessibilityLabel("Sending reset link")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || isSendingReset)
            case .createAccount:
                LegalConsentText(onShow: onShowLegal)
            }
            switchModeButton
        }
    }

    private var switchModeButton: some View {
        Button {
            focus = nil
            errorText = nil
            withAnimation(.snappy) { mode = mode.toggled }
        } label: {
            let prompt = mode == .signIn ? "New here?" : "Already have an account?"
            let action = Text(mode == .signIn ? "Create account" : "Sign in")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text("\(prompt) \(action)")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    // MARK: Actions

    private func submit() {
        guard !isSubmitting else { return }
        errorText = nil
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = "Enter your email address."
            focus = .email
            return
        }
        if password.isEmpty {
            errorText = "Enter your password."
            focus = .password
            return
        }
        if mode == .createAccount, password.count < Self.minimumPasswordLength {
            errorText = "Use at least \(Self.minimumPasswordLength) characters for your password."
            focus = .password
            return
        }
        focus = nil
        isSubmitting = true
        let mode = self.mode
        let email = self.email
        let password = self.password
        Task {
            defer { isSubmitting = false }
            do {
                switch mode {
                case .signIn:
                    try await session.signIn(email: email, password: password)
                case .createAccount:
                    try await session.signUp(email: email, password: password)
                }
            } catch {
                let message = error.friendlyMessage
                errorText = message.isEmpty ? nil : message
            }
        }
    }

    private func sendPasswordReset() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            errorText = "Enter your email above, then tap Forgot password."
            focus = .email
            return
        }
        focus = nil
        errorText = nil
        isSendingReset = true
        Task {
            defer { isSendingReset = false }
            do {
                try await session.sendPasswordReset(email: address)
                toasts.show("We sent a reset link to \(address).", style: .success)
            } catch {
                let message = error.friendlyMessage
                errorText = message.isEmpty ? nil : message
            }
        }
    }

}

// MARK: - Check your inbox

/// Shown after a sign-up that needs email confirmation. The link opens `quoted://auth-callback`,
/// which signs the user in and moves the phase on by itself.
private struct CheckEmailView: View {
    let email: String
    /// The password from the form, so Resend can repeat the sign-up. Empty hides Resend.
    let password: String

    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL
    @State private var isResending = false
    @ScaledMetric(relativeTo: .title) private var tileSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Wordmark(textStyle: .title2)
                        .padding(.bottom, Theme.Spacing.xxl)
                    Image(systemName: "envelope.badge")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: tileSize, height: tileSize)
                        .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Check your inbox")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    message
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipped()

            VStack(spacing: Theme.Spacing.xs) {
                PrimaryButton("Open Mail", systemImage: "envelope") {
                    openMail()
                }
                if !password.isEmpty {
                    Button {
                        resend()
                    } label: {
                        ZStack {
                            Text("Resend").opacity(isResending ? 0 : 1)
                            if isResending {
                                ProgressView().accessibilityLabel("Sending")
                            }
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .disabled(isResending)
                }
                Button {
                    session.clearPendingConfirmation()
                } label: {
                    Text("Use a different email")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.m)
        }
        .groundBackground()
    }

    private var message: some View {
        let address = Text(verbatim: email)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        return Text("We sent a link to \(address). Open it on this iPhone.")
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openMail() {
        guard let url = URL(string: "message://") else { return }
        openURL(url) { accepted in
            if !accepted {
                toasts.show("Couldn't open Mail. Check your inbox in your email app.", style: .error)
            }
        }
    }

    private func resend() {
        guard !isResending else { return }
        isResending = true
        Task {
            defer { isResending = false }
            do {
                try await session.signUp(email: email, password: password)
                toasts.show("We sent another link to \(email).", style: .success)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

// MARK: - Previews

#Preview("Sign in") {
    AuthFlowView()
        .previewEnvironment(.preview(phase: .signedOut))
}

#Preview("Sign in, dark, large type") {
    AuthFlowView()
        .previewEnvironment(.preview(phase: .signedOut))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Create account") {
    @Previewable @State var mode = AuthMode.createAccount
    @Previewable @State var email = "alex@example.com"
    @Previewable @State var password = ""
    AuthFormView(mode: $mode, email: $email, password: $password) { _ in }
        .previewEnvironment(.preview(phase: .signedOut))
}

#Preview("Check your inbox") {
    CheckEmailView(email: "alex@example.com", password: "correct horse")
        .previewEnvironment(.preview(phase: .signedOut))
}
