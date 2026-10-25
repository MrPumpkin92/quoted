import QuotedCore
import SwiftUI

/// The heart in the detail and spotlight toolbars: adds the quote to your favorites or takes it out.
/// Filled while it is a favorite. Favorites show on your profile, and to friends only when you turn
/// that on (`ProfileView`).
///
/// VoiceOver reads "Favorite" with the Selected trait while it is on, like a toggle.
struct FavoriteButton: View {
    let quote: Quote

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button {
            Task { await library.setFavorite(quote, !quote.isFavorite) }
        } label: {
            Label("Favorite", systemImage: quote.isFavorite ? "heart.fill" : "heart")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityAddTraits(quote.isFavorite ? .isSelected : [])
        .accessibilityHint(quote.isFavorite ? "Removes it from your favorites" : "Adds it to your favorites")
    }
}

/// "Favorite" or "Remove from favorites", for context menus and swipe actions.
struct FavoriteActionLabel: View {
    let isFavorite: Bool

    var body: some View {
        if isFavorite {
            Label("Remove from favorites", systemImage: "heart.slash")
        } else {
            Label("Favorite", systemImage: "heart")
        }
    }
}

#Preview("FavoriteButton") {
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FavoriteButton(quote: Samples.shelley)
                }
            }
    }
    .previewEnvironment()
}
