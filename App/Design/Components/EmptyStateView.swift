import SwiftUI

/// A guided empty state: a glyph, a title, a line of help, exactly one filled action and an optional
/// quiet link below it.
///
/// Example (Library): "Your library is empty" · Add your first quote · Browse verified quotes.
struct EmptyStateView: View {
    private let systemImage: String?
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?
    private let secondaryTitle: LocalizedStringKey?
    private let secondaryAction: (() -> Void)?

    /// - Parameters:
    ///   - systemImage: An optional SF Symbol above the title.
    ///   - title: The headline ("Nothing shared yet").
    ///   - message: An optional line of guidance.
    ///   - actionTitle: The filled PrimaryButton title. Nil for no button.
    ///   - action: The filled button's action.
    ///   - secondaryTitle: An optional quiet text button below.
    ///   - secondaryAction: The quiet button's action.
    init(
        systemImage: String? = nil,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        secondaryTitle: LocalizedStringKey? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .padding(.bottom, Theme.Spacing.xs)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                PrimaryButton(actionTitle, action: action)
                    .padding(.top, Theme.Spacing.xs)
            }
            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text(secondaryTitle)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// A spinner that appears only after `delay`, so fast loads never flash one ("no spinner unless > 1 s").
struct DelayedProgressView: View {
    var delay: Duration = .seconds(1)
    var label: LocalizedStringKey = "Loading"
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .accessibilityLabel(Text(label))
            .opacity(isVisible ? 1 : 0)
            .task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { isVisible = true }
            }
    }
}

#Preview("EmptyStateView") {
    EmptyStateView(
        systemImage: "text.quote",
        title: "Your library is empty",
        message: "Save the lines you want to see again.",
        actionTitle: "Add your first quote",
        action: {},
        secondaryTitle: "Browse verified quotes",
        secondaryAction: {}
    )
    .frame(maxHeight: .infinity)
    .groundBackground()
}

#Preview("EmptyStateView quiet") {
    EmptyStateView(systemImage: "tray", title: "Nothing shared yet", message: "Quotes your friends send show up here.")
        .frame(maxHeight: .infinity)
        .groundBackground()
}
