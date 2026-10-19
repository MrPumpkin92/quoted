import SwiftUI

/// The three-step "add a widget" guide, presented from the Library widget tip (`SheetRoute.widgetGuide`).
/// Each step has a small drawn illustration (decorative, hidden from VoiceOver).
struct WidgetGuideView: View {
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Put a quote on your Home Screen")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("The widget shows a quote from your reminders, the same one as your latest reminder.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    GuideStep(number: 1, text: "Touch and hold an empty spot on your Home Screen until the apps jiggle.") {
                        HomeScreenIllustration()
                    }
                    GuideStep(number: 2, text: "Tap Edit in the top corner, then Add Widget.") {
                        EditMenuIllustration()
                    }
                    GuideStep(number: 3, text: "Search for Quoted, pick a size, then tap Add Widget.") {
                        WidgetIllustration()
                    }

                    Label {
                        Text("On the Lock Screen: touch and hold it, tap Customize, then add Quoted under the clock.")
                    } icon: {
                        Image(systemName: "lock.iphone")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.m)
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton("Got it") { dismiss() }
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(Color.ground)
            }
            .groundBackground()
            .navigationTitle("Add the widget")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }
}

/// One numbered step: the number in a soft accent circle, the instruction, then the illustration.
private struct GuideStep<Illustration: View>: View {
    let number: Int
    let text: LocalizedStringKey
    @ViewBuilder let illustration: () -> Illustration

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Text("\(number)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .frame(width: badgeSize, height: badgeSize)
                .background(Color.accentSoft, in: Circle())
                .accessibilityLabel("Step \(number).")
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                illustration()
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(Color.ground, in: RoundedRectangle(cornerRadius: Theme.Radius.tile + 4, style: .continuous))
                    .dynamicTypeSize(.small ... .large)
                    .accessibilityHidden(true)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Illustrations

/// A Home Screen grid with apps jiggling and a press on an empty spot.
private struct HomeScreenIllustration: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(0..<4, id: \.self) { index in
                    appIcon(tilt: index.isMultiple(of: 2) ? -5 : 5)
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                appIcon(tilt: 5)
                appIcon(tilt: -5)
                Color.clear.frame(width: 32, height: 32)
                Circle()
                    .fill(Color.accentSoft)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: 36, height: 36)
                    .frame(width: 32, height: 32)
            }
        }
    }

    private func appIcon(tilt: Double) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
            .frame(width: 32, height: 32)
            .rotationEffect(.degrees(tilt))
    }
}

/// The "Edit" button with its menu open on "Add Widget".
private struct EditMenuIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Edit")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xxs + 2)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                menuRow("Add Widget", systemImage: "plus.square.on.square", highlighted: true)
                HairlineDivider()
                menuRow("Customize", systemImage: "paintbrush", highlighted: false)
            }
            .frame(width: 168)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        }
    }

    private func menuRow(_ title: LocalizedStringKey, systemImage: String, highlighted: Bool) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(highlighted ? .semibold : .regular))
            Spacer()
            Image(systemName: systemImage)
                .font(.caption)
        }
        .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(highlighted ? Color.accentSoft : Color.clear)
    }
}

/// A small Quoted widget next to the "Add Widget" button.
private struct WidgetIllustration: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Trust thyself.")
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("EMERSON")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.s)
            .frame(width: 92, height: 92, alignment: .topLeading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))

            Text("Add Widget")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Color.accentColor, in: Capsule())
        }
    }
}

#Preview("Widget guide") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            WidgetGuideView()
                .toastHost()
        }
        .previewEnvironment()
}

#Preview("Widget guide, dark") {
    Color.ground
        .sheet(isPresented: .constant(true)) {
            WidgetGuideView()
                .toastHost()
        }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
