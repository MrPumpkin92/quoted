import QuotedCore
import SwiftUI

/// "Verified quote": what the verified seal means for one quote. Its wording, author and source match a
/// catalog quote that was checked word for word against a public-domain edition
/// (docs/catalog-sources.md); the sheet names the work, who speaks the line (when it isn't the
/// author's own voice), where in the work it is, and opens that full text in the in-app browser.
///
/// Presented from the quote detail's "Verified quote" button for the quote's `verifiedStarterID` (any
/// catalog id, a starter or not), and from the empty Feed's provenance block for its catalog quote.
/// The location and link come from `catalog_quotes` through `CatalogStore`, looked up once per
/// session; offline, a starter still resolves from the starter pack if it was loaded, and otherwise
/// the sheet explains the check without them.
///
/// Both present it with their own `.sheet`, which the router can't see, so it holds deep links: a
/// reminder or widget tap opens once it is dismissed, since the full-screen quote can't be presented
/// over it.
struct VerifiedQuoteSheet: View {
    let catalogID: Int
    let author: String?
    let work: String?

    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var details: CatalogQuote?
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
            details = await catalog.verifiedSource(id: catalogID)
            didLoad = true
        }
        .sheet(isPresented: $isReadingSource) {
            if let url = details?.sourceURL {
                SafariView(url: url)
            }
        }
        // A local sheet: a link tapped under it waits until it closes (see above).
        .holdsDeepLinks()
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
                    if let speaker = details?.speaker, speaker != author {
                        Text("Spoken by \(speaker)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
            VerifiedQuoteSheet(catalogID: 3, author: Samples.emerson.author, work: Samples.emerson.source)
        }
        .previewEnvironment()
}

#Preview("Verified quote, spoken by a character") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            VerifiedQuoteSheet(catalogID: 62, author: "William Shakespeare", work: "Hamlet")
        }
        .previewEnvironment()
}
