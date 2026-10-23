// Pieces shared by the first-run screens: Welcome (`WelcomeView`), Choose a username
// (`UsernameView`) and the dormant email sign-in (`AuthFlowView`).

import QuotedCore
import SwiftUI

/// The Welcome hero: the Shelley quote with hanging quotation marks and its attribution.
struct WelcomeHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            QuoteText(body: WelcomeQuote.body, runs: WelcomeQuote.runs, style: .hero, quoteMarks: .hanging)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttributionLine(author: WelcomeQuote.author, source: WelcomeQuote.source)
        }
        .accessibilityElement(children: .combine)
    }
}


/// A label-above-value field inside a `CardContainer` (the Username card, and the dormant email form).
/// Tapping anywhere in the row focuses the field. The visible label is hidden from VoiceOver because
/// the field's own title already names it.
struct AuthFieldRow<Field: View>: View {
    private let label: LocalizedStringKey
    private let onTap: () -> Void
    private let field: Field

    init(label: LocalizedStringKey, onTap: @escaping () -> Void, @ViewBuilder field: () -> Field) {
        self.label = label
        self.onTap = onTap
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .font(.body)
        }
        .padding(.horizontal, Theme.Spacing.cardPadding)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// "By continuing you agree to the Terms and Community Guidelines. See our Privacy Policy.", with each
/// name a link that calls `onShow` (Welcome, and the dormant Create account form).
struct LegalConsentText: View {
    let onShow: (LegalPage) -> Void

    var body: some View {
        Text("By continuing you agree to the [Terms](quoted-legal://terms) and [Community Guidelines](quoted-legal://guidelines). See our [Privacy Policy](quoted-legal://privacy).")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
            .environment(\.openURL, OpenURLAction { url in
                guard let page = Self.page(for: url) else { return .discarded }
                onShow(page)
                return .handled
            })
    }

    /// Maps the in-text legal links to their pages.
    static func page(for url: URL) -> LegalPage? {
        guard url.scheme == "quoted-legal" else { return nil }
        switch url.host() {
        case "terms": return .terms
        case "guidelines": return .communityGuidelines
        case "privacy": return .privacy
        default: return nil
        }
    }
}

/// A bundled legal page in a sheet (the consent links). There is no tab stack before onboarding
/// ends, so the page gets its own `NavigationStack` and a Close button.
struct LegalSheet: View {
    let page: LegalPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextPageView(page: page)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .toastHost()
    }
}

/// The Welcome hero: Mary Shelley, with "fearless" in italic.
enum WelcomeQuote {
    static let body = "Beware; for I am fearless, and therefore powerful."
    static let author = "Mary Shelley"
    static let source = "Frankenstein"
    static let runs: [TextRun] = {
        let word = "fearless"
        guard let range = body.range(of: word) else { return [] }
        let start = body.utf16.distance(from: body.utf16.startIndex, to: range.lowerBound)
        return [TextRun(start: start, length: word.utf16.count, flags: .italic)]
    }()
}
