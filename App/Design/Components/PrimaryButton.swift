import SwiftUI

/// The one filled action on a screen: a 52-pt accent capsule with `OnAccent` text (taller, wrapping,
/// at accessibility text sizes).
///
/// Shows a spinner instead of the title while `isLoading` (and ignores taps). Disable it with
/// `.disabled(_:)`; it dims. Use `.buttonStyle(.primary)` to give any `Button` the same look.
struct PrimaryButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let isLoading: Bool
    private let action: () -> Void

    /// - Parameters:
    ///   - title: The label, for example "Sign in" or "Continue with 3 quotes".
    ///   - systemImage: An optional leading SF Symbol.
    ///   - isLoading: Shows a progress spinner and blocks taps.
    ///   - action: Called on tap.
    init(_ title: LocalizedStringKey, systemImage: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            ZStack {
                label.opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(Color.onAccent)
                        .accessibilityLabel("Working")
                }
            }
        }
        .buttonStyle(.primary)
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// The primary button look: full width, at least 52 pt, accent capsule, semibold `OnAccent` text.
///
/// Up to the largest standard text size the title stays on one line (shrinking to 80% before it
/// truncates). At accessibility text sizes it wraps instead, centered, and the button grows taller with
/// 26-pt corners, so a title like "Continue with 12 quotes" is never cut off.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            let wraps = dynamicTypeSize.isAccessibilitySize
            // A wrapped title makes the button taller; keep the 26-pt ends instead of a tall oval.
            let shape = wraps
                ? AnyShape(RoundedRectangle(cornerRadius: Theme.Metrics.primaryButtonHeight / 2, style: .continuous))
                : AnyShape(Capsule())
            configuration.label
                .font(.headline)
                .foregroundStyle(Color.onAccent)
                .multilineTextAlignment(.center)
                .lineLimit(wraps ? nil : 1)
                .minimumScaleFactor(wraps ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: wraps)
                .padding(.horizontal, wraps ? Theme.Spacing.m : Theme.Spacing.l)
                .padding(.vertical, wraps ? Theme.Spacing.s : 0)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.primaryButtonHeight)
                .background(Color.accentColor, in: shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .contentShape(shape)
                // A wrapped title never gets squeezed below its height by a crowded stack.
                .fixedSize(horizontal: false, vertical: wraps)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// The filled accent capsule (see `PrimaryButton`).
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

#Preview("PrimaryButton") {
    VStack(spacing: Theme.Spacing.m) {
        PrimaryButton("Sign in") {}
        PrimaryButton("Continue with 3 quotes", isLoading: true) {}
        PrimaryButton("Share", systemImage: "square.and.arrow.up") {}
        PrimaryButton("Continue") {}.disabled(true)
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxHeight: .infinity)
    .groundBackground()
}

#Preview("PrimaryButton, AX5") {
    VStack(spacing: Theme.Spacing.m) {
        PrimaryButton("Continue with 12 quotes") {}
        PrimaryButton("Send to 3 friends", systemImage: "paperplane.fill") {}
        PrimaryButton("Allow notifications", isLoading: true) {}
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxHeight: .infinity)
    .groundBackground()
    .dynamicTypeSize(.accessibility5)
}
