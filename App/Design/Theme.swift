import SwiftUI

// MARK: Colors
//
// Every color is an asset-catalog color set with a dark variant (App/Resources/Assets.xcassets).
// Xcode generates the Swift symbols (ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS), so
// use them directly:
//
//   Color.ground      Screen background (#F8F8F6 / #0C0C0E)
//   Color.surface     Cards, the editor page, the share card (#FFFFFF / #161619)
//   Color.hairline    Separators and card strokes (#E6E4DF / white 8%)
//   Color.accentColor The ink-blue accent (#2B44C9 / #8B98FF). Also the app-wide `.tint`.
//   Color.accentSoft  Selected chips and highlights (accent 10% / 18%)
//   Color.onAccent    Text and glyphs on an accent fill (white / #0C0C0E, so dark mode passes AA)
//   .inlineError      Inline error text (#C4271C / #FF6B60; defined in code, InlineErrorColor.swift)
//
// Text uses the system hierarchy (`.primary`, `.secondary`, `.tertiary`). Never hand-roll ink opacities.

/// Layout constants for the Margin design: an 8-pt grid, 20-pt continuous corners, 52-pt primary buttons.
enum Theme {
    /// Spacing on the 8-pt grid.
    enum Spacing {
        /// 4 pt. Hairline gaps (icon to label inside a chip).
        static let xxs: CGFloat = 4
        /// 8 pt. Between a quote and its attribution, between stacked labels.
        static let xs: CGFloat = 8
        /// 12 pt. Row vertical padding.
        static let s: CGFloat = 12
        /// 16 pt. Screen gutters and card padding.
        static let m: CGFloat = 16
        /// 24 pt. Between groups (cards, sections).
        static let l: CGFloat = 24
        /// 32 pt. The QuoteCard page padding.
        static let xl: CGFloat = 32
        /// 48 pt. Generous vertical breathing room (Welcome, empty states).
        static let xxl: CGFloat = 48

        /// Leading and trailing screen margin.
        static let gutter: CGFloat = m
        /// Space between groups on a screen.
        static let group: CGFloat = l
        /// Padding inside a CardContainer.
        static let cardPadding: CGFloat = m
        /// Padding inside the big QuoteCard page.
        static let pagePadding: CGFloat = xl
    }

    /// Corner radii (always `.continuous`).
    enum Radius {
        /// Cards, the editor page and the QuoteCard.
        static let card: CGFloat = 20
        /// Small tiles, such as the bell tile in the StatusCard.
        static let tile: CGFloat = 10
    }

    /// Fixed control metrics.
    enum Metrics {
        /// Height of a PrimaryButton.
        static let primaryButtonHeight: CGFloat = 52
        /// The minimum touch target for any control.
        static let minTouchTarget: CGFloat = 44
        /// Hairline stroke width.
        static let hairline: CGFloat = 1
        /// Extra bottom padding that keeps a root-level toast clear of the floating tab bar.
        static let tabBarClearance: CGFloat = 64
    }

    /// The card shape: a 20-pt continuous rounded rectangle.
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }
}

// MARK: Surfaces

extension View {
    /// Fills the screen behind the content with `Ground` (edge to edge) and hides the default
    /// `List`/`Form`/`ScrollView` background, so every screen sits on the same paper.
    func groundBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.ground.ignoresSafeArea())
    }

    /// Styles a `List` row for a plain list on `Ground`: ground background, hairline separators,
    /// 16-pt gutters. Use on `QuoteRow`s in Library, Search and the starter list.
    func groundListRow() -> some View {
        self
            .listRowBackground(Color.ground)
            .listRowSeparatorTint(Color.hairline)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.s,
                leading: Theme.Spacing.gutter,
                bottom: Theme.Spacing.s,
                trailing: Theme.Spacing.gutter
            ))
    }

    /// Wraps the view in a card: `Surface` fill, 1-px `Hairline` stroke, 20-pt continuous corners and
    /// `padding` inside. Same as `CardContainer`, as a modifier.
    func card(padding: CGFloat = Theme.Spacing.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Color.hairline, lineWidth: Theme.Metrics.hairline))
    }
}

// MARK: Avatar palette

/// A soft fill with a matching ink, chosen per user so the same person always gets the same color.
struct AvatarTint: Hashable, Sendable {
    let fill: ColorResource
    let ink: ColorResource

    /// Six tints that read well in light and dark mode.
    static let palette: [AvatarTint] = [
        AvatarTint(fill: .avatarRoseFill, ink: .avatarRoseInk),
        AvatarTint(fill: .avatarSageFill, ink: .avatarSageInk),
        AvatarTint(fill: .avatarSandFill, ink: .avatarSandInk),
        AvatarTint(fill: .avatarInkFill, ink: .avatarInkInk),
        AvatarTint(fill: .avatarLilacFill, ink: .avatarLilacInk),
        AvatarTint(fill: .avatarTealFill, ink: .avatarTealInk),
    ]

    /// The tint for a user ID. Deterministic across launches and devices.
    static func forID(_ id: UUID) -> AvatarTint {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return palette[sum % palette.count]
    }
}
