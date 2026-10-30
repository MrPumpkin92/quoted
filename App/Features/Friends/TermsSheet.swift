import SwiftUI

/// The Terms sheet (docs/ui-spec.md §22): shown before the first social write (a friend request,
/// accepting one, a send) until the current Terms of Use are accepted. Never a `SheetRoute`: the
/// `.termsSheet()` modifier presents it over whatever asked, including a sheet, and leaves that
/// screen and its typed text as they were.
///
/// Accept calls `accept_terms(version)` while loading; success closes the sheet and runs the waiting
/// write (its own feedback is the reward, so no toast here). A failure keeps the sheet and toasts.
/// Not Now, or a swipe down, drops the write. The two pages open inside the sheet. It holds deep
/// links until it closes.
struct TermsSheet: View {
    let request: TermsRequest

    @Environment(SocialStore.self) private var social
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isAccepting = false

    /// The date the current terms took effect, in the intro and the footnote.
    static let updatedOn = "October 25, 2026"

    var body: some View {
        NavigationStack {
            List {
                Text(intro)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .marginPlainRow(top: Theme.Spacing.xs, bottom: Theme.Spacing.s)
                points
                    .marginCardRow(.single, bottomSpacing: Theme.Spacing.l)
                pageLink("Terms of Use", page: .terms)
                    .marginCardRow(.first)
                pageLink("Community Guidelines", page: .communityGuidelines)
                    .marginCardRow(.last)
                if dynamicTypeSize.isAccessibilitySize {
                    // At accessibility sizes the bar would cover most of the screen: it ends the list.
                    acceptBar
                        .marginPlainRow(top: Theme.Spacing.l, bottom: Theme.Spacing.l)
                }
            }
            .marginCardList()
            .navigationTitle(request.isUpdate ? "Updated Terms" : "Community Terms")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        social.cancelTerms()
                    }
                    .disabled(isAccepting)
                }
            }
            .safeAreaBar(edge: .bottom) {
                if !dynamicTypeSize.isAccessibilitySize {
                    acceptBar
                        .padding(.horizontal, Theme.Spacing.gutter)
                        .padding(.top, Theme.Spacing.s)
                        .padding(.bottom, Theme.Spacing.m)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isAccepting)
        .holdsDeepLinks()
        .toastHost()
    }

    // MARK: Parts

    private var intro: String {
        request.isUpdate
            ? "We updated the terms on \(Self.updatedOn). Accept them to keep sending and posting."
            : "Friends on Quoted send each other quotes, messages and playlists. Everyone agrees to the same terms first."
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            point(
                "hand.raised",
                "Quoted has no tolerance for objectionable content or abusive users. No harassment, threats, hate, sexual content or spam."
            )
            point("flag", "Report anything that breaks these terms. We review every report within 24 hours.")
            point("person.crop.circle.badge.xmark", "People who break them are removed, and so is what they posted.")
            point("at", "Your username stays with the quotes you add, wherever they go.")
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func point(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private func pageLink(_ title: LocalizedStringKey, page: LegalPage) -> some View {
        NavigationLink {
            TextPageView(page: page)
        } label: {
            Text(title)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
    }

    private var acceptBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Terms of Use, updated \(Self.updatedOn).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton("Accept", isLoading: isAccepting) {
                accept()
            }
            .accessibilityHint("Agrees to the Terms of Use and Community Guidelines, then continues.")
        }
    }

    // MARK: Actions

    private func accept() {
        guard !isAccepting else { return }
        isAccepting = true
        Task {
            await social.acceptTerms()
            isAccepting = false
        }
    }
}

// MARK: - Presenting

extension View {
    /// Presents the Terms sheet while `SocialStore.requireTerms(for:then:)` waits for the terms. Apply it
    /// once on the root, and inside every sheet a gated write can start from (`SheetHost`, the
    /// spotlight's Share sheet) with `.environment(\.isInShellSheet, true)`: the root one presents
    /// only while neither a shell sheet nor the spotlight is up, so the sheet always stacks over the
    /// screen that asked.
    func termsSheet() -> some View {
        modifier(TermsSheetPresenter())
    }
}

private struct TermsSheetPresenter: ViewModifier {
    @Environment(SocialStore.self) private var social
    @Environment(Router.self) private var router
    /// True inside a shell sheet (`SheetHost` sets it).
    @Environment(\.isInShellSheet) private var isInShellSheet

    func body(content: Content) -> some View {
        // Read here, in `body`, so Observation re-renders when either changes (a Binding's getter
        // runs outside the tracked body). The root presents only when no shell sheet and no
        // spotlight is up (nothing can be presented from under them); their own copy presents then.
        let pending = isInShellSheet || (router.sheet == nil && router.spotlight == nil) ? social.termsRequest : nil
        content
            .sheet(item: binding(pending)) { request in
                TermsSheet(request: request)
            }
    }

    private func binding(_ pending: TermsRequest?) -> Binding<TermsRequest?> {
        let social = self.social
        return Binding(
            get: { pending },
            set: { newValue in
                // A swipe down: drop the waiting write. (Accept clears the request itself.)
                if newValue == nil { social.cancelTerms() }
            }
        )
    }
}

extension EnvironmentValues {
    /// Whether the view is inside a sheet that presents its own Terms sheet: one the shell presents
    /// (`SheetHost`), or the spotlight's Share sheet.
    @Entry var isInShellSheet = false
}
