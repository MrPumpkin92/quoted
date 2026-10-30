#if DEBUG
import QuotedCore
import SwiftUI

/// Every design component on one scrolling page, with sample data. Debug builds only.
///
/// Launch it with `xcrun simctl launch <udid> com.hwei.quoted -QuotedGallery` (add
/// `xcrun simctl ui <udid> appearance dark` for dark mode) to check the design system on a device.
/// `-QuotedGalleryPage 1`, `2` or `3` opens it scrolled to a later section, for screenshots.
struct ComponentGallery: View {
    @Environment(ToastCenter.self) private var toasts
    private let startPage = UserDefaults.standard.integer(forKey: "QuotedGalleryPage")

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    Wordmark()
                    QuoteText(Samples.shelley, style: .hero, quoteMarks: .hanging)
                    AttributionLine(Samples.shelley)

                    StatusCard(title: "6 quotes in your reminders", detail: "3\u{00D7} daily \u{00B7} Next at 8:00 PM", onOpen: {})
                    StatusCard(title: "Notifications off in Settings", detail: "6 quotes in your reminders", isOff: true, actionTitle: "Turn on", onOpen: {}, onTurnOn: {})

                    CardContainer {
                        HStack(spacing: Theme.Spacing.s) {
                            AvatarStack(profiles: [Samples.maya, Samples.jordan])
                            VStack(alignment: .leading) {
                                Text("2 friend requests").font(.headline)
                                Text("From Maya and Jordan").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach([Samples.emerson, Samples.seneca, Samples.whitman]) { quote in
                            QuoteRow(quote)
                            HairlineDivider()
                        }
                        QuoteRow(Samples.austen, highlighting: ["courage"])
                            .id(3)
                    }

                    QuoteCard(Samples.emerson, showsWordmark: true)
                        .id(1)

                    HStack(spacing: Theme.Spacing.m) {
                        ForEach([Samples.alex, Samples.maya, Samples.jordan, Samples.sam, Samples.riley]) { profile in
                            AvatarCircle(profile: profile)
                        }
                    }

                    CardContainer(padding: 0) {
                        Toggle("Include in reminders", isOn: .constant(true))
                            .padding(Theme.Spacing.cardPadding)
                        HairlineDivider(leadingInset: Theme.Spacing.cardPadding)
                        Text("Shows up in widgets and reminders")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Spacing.cardPadding)
                    }

                    PrimaryButton("Sign in") { toasts.show("Sent to Maya") {} }
                    PrimaryButton("Continue", isLoading: true) {}
                    PrimaryButton("Continue with 0 quotes") {}.disabled(true)

                    ToastView(toast: Toast(id: UUID(), message: "Sent to Maya", style: .info, actionTitle: "Undo", duration: .seconds(5)))
                        .id(2)
                    ToastView(toast: Toast(id: UUID(), message: "You\u{2019}re offline. Try again when connected.", style: .error, actionTitle: nil, duration: .seconds(4)))

                    EmptyStateView(
                        systemImage: "text.quote",
                        title: "Your library is empty",
                        actionTitle: "Add your first quote",
                        action: {},
                        secondaryTitle: "Browse verified quotes",
                        secondaryAction: {}
                    )
                    .card()
                }
                .padding(Theme.Spacing.gutter)
            }
            .onAppear {
                if startPage > 0 { proxy.scrollTo(startPage, anchor: .top) }
            }
            }
            .groundBackground()
            .navigationTitle("Components")
        }
    }
}

#Preview {
    ComponentGallery()
        .previewEnvironment()
}
#endif
