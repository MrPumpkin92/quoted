import QuotedCore
import SwiftUI

/// "Verified quote": what the verified seal means for one quote. Its wording, author and source match a
/// starter quote that was checked word for word against a public-domain edition
/// (docs/starter-pack-sources.md); the sheet names the work, where in it the quote is, and opens that
/// full text in the in-app browser.
///
/// Presented from the quote detail's "Verified quote" button. The location and link come from
/// `starter_quotes` through `StarterStore`; offline, the sheet still explains the check without them.
struct VerifiedQuoteSheet: View {
    let starterID: Int
    let author: String?
    let work: String?

    @Environment(StarterStore.self) private var starter
    @Environment(\.dismiss) private var dismiss

    @State private var details: StarterQuote?
    @State private var didLoad = false
    @State private var isReadingSource = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    sourceCard
                    Text("Change the wording, author or source and the seal comes off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groundBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            details = await starter.verifiedSource(id: starterID)
            didLoad = true
        }
        .sheet(isPresented: $isReadingSource) {
            if let url = details?.sourceURL {
                SafariView(url: url)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label {
                Text("Verified quote")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            Text("Quoted checked this quote word for word against a public-domain edition of the work, and its author against the same edition.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if let work {
                        Text(work)
                            .font(.system(.body, design: .serif).italic())
                    }
                    if let author {
                        Text(author)
                            .font(.subheadline)
                    }
                    if let location = details?.sourceLocation {
                        Text(location)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !didLoad {
                        ProgressView()
                            .padding(.top, Theme.Spacing.xxs)
                    }
                }
                .accessibilityElement(children: .combine)
                if let url = details?.sourceURL {
                    Divider()
                        .padding(.vertical, Theme.Spacing.xxs)
                    Button {
                        isReadingSource = true
                    } label: {
                        Label("Read it on \(Self.siteName(url))", systemImage: "book")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens the full text it was checked against")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Project Gutenberg", "Wikisource", or the host.
    static func siteName(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        if host.hasSuffix("gutenberg.org") { return "Project Gutenberg" }
        if host.hasSuffix("wikisource.org") { return "Wikisource" }
        return host
    }
}

#Preview("Verified quote") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            VerifiedQuoteSheet(starterID: 3, author: Samples.emerson.author, work: Samples.emerson.source)
        }
        .previewEnvironment()
}
