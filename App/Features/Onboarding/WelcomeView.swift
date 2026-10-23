// Welcome (docs/ui-spec.md §1): the first screen with anonymous accounts (`AccountMode`).
//
// RootView shows `WelcomeView()` while `SessionStore.phase == .signedOut`. Nothing reaches the network
// until Get started: `SessionStore.startAccount()` creates the account, and the phase moves on to
// Choose a username by itself. The page scrolls as one column, so at large text sizes on a small iPhone
// the button follows the hero instead of a pinned bar covering it.

import Accessibility
import QuotedKit
import SwiftUI

struct WelcomeView: View {
    @Environment(SessionStore.self) private var session

    @State private var isStarting = false
    /// Why the last Get started failed, shown above the button.
    @State private var errorText: String?
    @State private var legalPage: LegalPage?

    init() {}

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Spacer(minLength: Theme.Spacing.xl)
                    WelcomeHero()
                    Spacer(minLength: Theme.Spacing.xl)
                    actions
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.m)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            // No navigation bar here: keep scrolled text out from under the status bar.
            .clipped()
        }
        .groundBackground()
        .sheet(item: $legalPage) { page in
            LegalSheet(page: page)
        }
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

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.inlineError)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            } else if let notice = session.signedOutNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            PrimaryButton("Get started", isLoading: isStarting) {
                start()
            }
            .disabled(isStarting)
            LegalConsentText { page in
                legalPage = page
            }
        }
    }

    // MARK: Actions

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        errorText = nil
        Task {
            defer { isStarting = false }
            do {
                try await session.startAccount()
            } catch {
                errorText = QuotedError(error).userMessage
            }
        }
    }
}

#Preview("Welcome") {
    WelcomeView()
        .previewEnvironment(.preview(phase: .signedOut))
}

#Preview("Welcome, large type") {
    WelcomeView()
        .previewEnvironment(.preview(phase: .signedOut))
        .dynamicTypeSize(.accessibility3)
}
