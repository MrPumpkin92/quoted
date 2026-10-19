import SwiftUI

/// The reminders status card at the top of Library: a bell tile in a soft-accent square, a bold title
/// and a detail line.
///
/// - Normal: "6 quotes in your reminders" / "3× daily · Next at 8:00 PM", with a chevron.
/// - Off: "Reminders off" or "Notifications off in Settings", with a "Turn on" button (under the text
///   at accessibility text sizes).
///
/// Tapping the card calls `onOpen` (push `.reminders`). Tapping "Turn on" calls `onTurnOn`
/// (usually `reminders.turnOn()`). Build it from `ReminderStore.statusSummary`.
struct StatusCard: View {
    private let title: String
    private let detail: String
    private let isOff: Bool
    private let actionTitle: String?
    private let onOpen: () -> Void
    private let onTurnOn: (() -> Void)?

    /// - Parameters:
    ///   - title: The bold first line.
    ///   - detail: The secondary second line.
    ///   - isOff: Uses the `bell.slash` glyph and shows the action button.
    ///   - actionTitle: The button title for the off state ("Turn on"); nil hides it.
    ///   - onOpen: Called when the card body is tapped.
    ///   - onTurnOn: Called when the action button is tapped.
    init(
        title: String,
        detail: String,
        isOff: Bool = false,
        actionTitle: String? = nil,
        onOpen: @escaping () -> Void,
        onTurnOn: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.isOff = isOff
        self.actionTitle = actionTitle
        self.onOpen = onOpen
        self.onTurnOn = onTurnOn
    }

    /// A card for `ReminderStore.statusSummary`.
    init(summary: ReminderStatusSummary, onOpen: @escaping () -> Void, onTurnOn: (() -> Void)? = nil) {
        self.init(
            title: summary.title,
            detail: summary.detail,
            isOff: summary.isOff,
            actionTitle: summary.actionTitle,
            onOpen: onOpen,
            onTurnOn: onTurnOn
        )
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the row stacks (tile over text, "Turn on" under both), so the
        // title never breaks mid-word. `AnyLayout` keeps the buttons' identity when the size changes.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let outer = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
        let inner = IconTile.layout(for: dynamicTypeSize)
        outer {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.s) {
                    inner {
                        bellTile
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !showsAction {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens reminder settings")

            if showsAction, let actionTitle, let onTurnOn {
                Button(action: onTurnOn) {
                    // The 44-pt target is in the label: a frame outside a Button adds no hit area.
                    Text(actionTitle)
                        .fontWeight(.semibold)
                        .capsuleButtonLabel()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .fixedSize()
            }
        }
        .card()
    }

    private var showsAction: Bool { isOff && actionTitle != nil && onTurnOn != nil }

    private var bellTile: some View {
        IconTile(systemName: isOff ? "bell.slash.fill" : "bell.fill", tone: isOff ? .muted : .accent)
    }
}

/// A glyph in a rounded tile: the status card's bell, the widget tip and the notification banners.
///
/// 40 pt at the default text size. The tile grows with Dynamic Type up to 64 pt and the glyph stops
/// growing at AX1, so at the largest sizes the glyph never spills out of its tile. Hidden from
/// VoiceOver (decorative).
struct IconTile: View {
    enum Tone {
        /// Accent glyph on `AccentSoft`.
        case accent
        /// Secondary glyph on a quaternary fill (off states).
        case muted
    }

    private let systemName: String
    private let tone: Tone

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 40

    init(systemName: String, tone: Tone = .accent) {
        self.systemName = systemName
        self.tone = tone
    }

    var body: some View {
        let size = min(max(scaledSize, 40), 64)
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .foregroundStyle(tone == .accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(
                tone == .accent ? AnyShapeStyle(Color.accentSoft) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// Lays out a tile and its text: side by side, or the tile above the text at accessibility text
    /// sizes, so a long word ("Notifications") never breaks mid-word in a narrow column. `AnyLayout`
    /// keeps the children's identity when the text size changes.
    static func layout(for size: DynamicTypeSize, alignment: VerticalAlignment = .center) -> AnyLayout {
        size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: Theme.Spacing.s))
    }
}

#Preview("StatusCard") {
    VStack(spacing: Theme.Spacing.m) {
        StatusCard(title: "6 quotes in your reminders", detail: "3× daily · Next at 8:00 PM", onOpen: {})
        StatusCard(title: "Reminders off", detail: "6 quotes waiting", isOff: true, actionTitle: "Turn on", onOpen: {}, onTurnOn: {})
        StatusCard(title: "Notifications off in Settings", detail: "6 quotes waiting", isOff: true, actionTitle: "Turn on", onOpen: {}, onTurnOn: {})
    }
    .padding(Theme.Spacing.gutter)
    .frame(maxHeight: .infinity, alignment: .top)
    .groundBackground()
}

#Preview("StatusCard, AX5") {
    ScrollView {
        VStack(spacing: Theme.Spacing.m) {
            StatusCard(title: "6 quotes in your reminders", detail: "3× daily · Next at 8:00 PM", onOpen: {})
            StatusCard(title: "Notifications off in Settings", detail: "6 quotes waiting", isOff: true, actionTitle: "Turn on", onOpen: {}, onTurnOn: {})
        }
        .padding(Theme.Spacing.gutter)
    }
    .groundBackground()
    .dynamicTypeSize(.accessibility5)
}
