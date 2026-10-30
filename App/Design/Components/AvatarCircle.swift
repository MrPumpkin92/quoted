import QuotedCore
import SwiftUI

/// A round avatar with the person's initial on a soft tint picked deterministically from their user ID.
///
/// Decorative by default (hidden from VoiceOver): the row it sits in already says the name.
struct AvatarCircle: View {
    private let name: String
    private let id: UUID
    private let size: CGFloat

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// - Parameters:
    ///   - name: The display name (or username) the initial comes from.
    ///   - id: The user ID that picks the tint.
    ///   - size: The diameter at the default Dynamic Type size (scales with it). 40 pt by default.
    init(name: String, id: UUID, size: CGFloat = 40) {
        self.name = name
        self.id = id
        self.size = size
    }

    /// An avatar for a profile (display name, falling back to the username).
    init(profile: Profile, size: CGFloat = 40) {
        self.init(name: profile.displayName, id: profile.id, size: size)
    }

    var body: some View {
        let tint = AvatarTint.forID(id)
        let diameter = size * min(scale, 1.6)
        Text(initial)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(Color(tint.ink))
            .frame(width: diameter, height: diameter)
            .background(Color(tint.fill), in: Circle())
            .accessibilityHidden(true)
    }

    /// The first letter of the name, uppercased ("?" when the name has no letters).
    var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).localizedUppercase
    }
}

/// Up to three overlapping avatars, each ringed in `Surface` (the Inbox's requests row).
struct AvatarStack: View {
    private let profiles: [Profile]
    private let size: CGFloat

    init(profiles: [Profile], size: CGFloat = 32) {
        self.profiles = Array(profiles.prefix(3))
        self.size = size
    }

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(profiles) { profile in
                AvatarCircle(profile: profile, size: size)
                    .padding(2)
                    .background(Color.surface, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("AvatarCircle") {
    VStack(spacing: Theme.Spacing.l) {
        HStack(spacing: Theme.Spacing.m) {
            AvatarCircle(profile: Samples.alex)
            AvatarCircle(profile: Samples.maya)
            AvatarCircle(profile: Samples.jordan)
            AvatarCircle(profile: Samples.sam)
            AvatarCircle(profile: Samples.riley, size: 56)
        }
        AvatarStack(profiles: [Samples.maya, Samples.jordan])
    }
    .padding(Theme.Spacing.gutter)
    .card()
    .padding(Theme.Spacing.gutter)
    .groundBackground()
}
