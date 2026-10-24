import QuotedCore
import SwiftUI

/// The quote a reminder or widget tap opens, full screen (the council's graft from Daily: the big card
/// is the screen a notification or widget opens, not the home tab). One quote, large serif type with
/// hanging quotation marks, its attribution (bell and verified seal included), Share, and
/// "Open in Library" for the detail screen with its toggle, Edit and Delete.
///
/// Presented by `MainTabView` with `fullScreenCover(item: $router.spotlight)`. Short quotes use the
/// `.spotlight` size and sit centred; long ones, and every quote at accessibility text sizes, use
/// `.hero`. At accessibility sizes the buttons scroll with the quote instead of staying pinned, as on
/// the detail screen. Before the library has loaded (a cold launch from a tap), or while a refresh may
/// still bring the quote in, it shows a delayed spinner; if the library can't load it offers Try
/// again; a quote that is no longer in the library (deleted here or on another device) gets an
/// explanation and Close.
///
/// Share is presented here, not through the router: the shell's sheet sits under this cover and can't
/// be presented while it is up. While it is up, links wait (`ShareQuoteSheet` holds them).
///
/// The cover brings one toast host for all its states, so "Sent to Maya · Undo" shows over the
/// cover and never covers the buttons.
struct QuoteSpotlightView: View {
    let quoteID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var sharing: Quote?

    /// Above this many characters the quote uses `.hero` instead of `.spotlight`, so it stays readable.
    static let largeTypeMaxLength = 280

    var body: some View {
        NavigationStack {
            // One host for every state, inside the pinned buttons' inset, so a toast sits above Share
            // and is never re-registered when the state changes under an open Share sheet.
            content
                .toastHost()
                .safeAreaInset(edge: .bottom) {
                    if let quote = library.quote(id: quoteID), !actionsScrollWithQuote {
                        actions(for: quote)
                            .padding(.top, Theme.Spacing.xs)
                            .background(Color.ground)
                    }
                }
                .groundBackground()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
        }
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $sharing) { quote in
            ShareQuoteSheet(quote: quote)
                .toastHost()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let quote = library.quote(id: quoteID) {
            page(for: quote)
        } else if !library.hasLoaded, let error = library.lastError {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn't load this quote",
                message: LocalizedStringKey(error.errorDescription ?? "Check your connection and try again."),
                actionTitle: "Try again",
                action: { Task { await library.refresh(userInitiated: true) } },
                secondaryTitle: "Close",
                secondaryAction: { dismiss() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !library.hasLoaded || library.isRefreshing {
            DelayedProgressView(label: "Loading quote")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                systemImage: "text.quote",
                title: "This quote is gone",
                message: "It's no longer in your library. It may have been deleted on another device.",
                actionTitle: "Close",
                action: { dismiss() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// At accessibility text sizes the buttons scroll with the quote, so they don't take half the screen.
    private var actionsScrollWithQuote: Bool { dynamicTypeSize.isAccessibilitySize }

    private func style(for quote: Quote) -> QuoteStyle {
        actionsScrollWithQuote || quote.body.count > Self.largeTypeMaxLength ? .hero : .spotlight
    }

    private func page(for quote: Quote) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        QuoteText(quote, style: style(for: quote), quoteMarks: .hanging)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AttributionLine(quote, inReminders: quote.isInRotation)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal, Theme.Spacing.xl)
                    if actionsScrollWithQuote {
                        actions(for: quote)
                    }
                }
                .padding(.vertical, Theme.Spacing.l)
                .frame(maxWidth: .infinity, minHeight: actionsScrollWithQuote ? nil : proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func actions(for quote: Quote) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            PrimaryButton("Share", systemImage: "square.and.arrow.up") {
                sharing = quote
            }
            Button {
                router.openSpotlightInLibrary(quote.id, reminderQuoteIDs: library.reminderQuotes.map(\.id))
            } label: {
                Text("Open in Library")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityHint("Shows this quote with Edit, Delete and the reminders switch")
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.bottom, Theme.Spacing.xs)
    }
}

#Preview("Spotlight") {
    QuoteSpotlightView(quoteID: Samples.shelley.id)
        .previewEnvironment()
}

#Preview("Spotlight, long quote") {
    QuoteSpotlightView(quoteID: Samples.austen.id)
        .previewEnvironment()
}

#Preview("Spotlight, dark, large text") {
    QuoteSpotlightView(quoteID: Samples.emerson.id)
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
