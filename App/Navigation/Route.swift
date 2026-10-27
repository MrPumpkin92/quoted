import Foundation
import QuotedCore

/// The three tabs of `MainTabView`.
enum AppTab: Hashable, Sendable, CaseIterable {
    /// "Library" (books.vertical).
    case library
    /// "Friends" (person.2), badged with incoming requests + unseen shares.
    case friends
    /// The search tab (`Tab(role: .search)`).
    case search
}

/// A screen pushed onto a tab's `NavigationStack`. The shell maps every case to its view
/// (`RouteDestinations`); feature views never add `navigationDestination(for: Route.self)`.
enum Route: Hashable, Sendable {
    /// `QuoteDetailView(quoteID:contextIDs:)`: the pager covers `contextIDs` (the list it was opened
    /// from: Library order, reminder order, or search results), starting at `id`.
    case quote(id: UUID, contextIDs: [UUID])
    /// `RemindersView()`: reminder settings and the reorderable reminder list.
    case reminders
    /// `SharedInboxView()`: every quote shared with you.
    case sharedInbox
    /// `ProfileView(profile:)`: a friend's favorites (when they show them), or your own with the
    /// switch that shows them to friends.
    case profile(Profile)
    /// `AccountView()`: profile, notifications, legal, sign out, delete account.
    case account
    /// `BlockedUsersView()`.
    case blockedUsers
    /// `TextPageView(page:)`: a bundled legal page.
    case textPage(LegalPage)
}

/// A sheet presented by `Router.present(_:)`. The shell wraps each in `.toastHost()`; sheet views
/// bring their own `NavigationStack` when they need a toolbar.
enum SheetRoute: Identifiable, Hashable, Sendable {
    /// `AddEditQuoteView(editing: nil)`.
    case addQuote
    /// `AddEditQuoteView(editing: nil, pasted: text)`: a new quote filled from text pasted with the
    /// system Paste button after a web search (split into body, author and source when it can be).
    case pastedQuote(String)
    /// `AddEditQuoteView(editing: quote)`.
    case editQuote(Quote)
    /// `ShareQuoteSheet(quote:)`.
    case share(Quote)
    /// `WidgetGuideView()`: the three-step "add a widget" guide.
    case widgetGuide
    /// `ReminderQuotePicker()`: multi-select library quotes to add to reminders.
    case reminderPicker
    /// `StarterFlowView(mode: .addMore)`: pick more starter quotes after onboarding.
    case starterPack
    /// `SafariView(url:)`: Google inside Quoted, from the search tab's web row.
    case safari(URL)

    /// Whether the sheet can hold input the user would lose if it closed without asking (a draft, a
    /// selection, a note, or a save in progress). A deep link never closes such a sheet; it opens
    /// after the sheet is dismissed (see `Router.open(_:reminderQuoteIDs:)`).
    var mayHoldUnsavedInput: Bool {
        switch self {
        case .addQuote, .pastedQuote, .editQuote, .share, .reminderPicker, .starterPack: true
        case .widgetGuide, .safari: false
        }
    }

    var id: String {
        switch self {
        case .addQuote: "addQuote"
        case .pastedQuote: "pastedQuote"
        case .editQuote(let quote): "editQuote-\(quote.id.uuidString)"
        case .share(let quote): "share-\(quote.id.uuidString)"
        case .widgetGuide: "widgetGuide"
        case .reminderPicker: "reminderPicker"
        case .starterPack: "starterPack"
        case .safari(let url): "safari-\(url.absoluteString)"
        }
    }
}

/// The quote a reminder or widget tap opens full screen (`QuoteSpotlightView`), presented by the
/// shell with `fullScreenCover(item:)`.
struct QuoteSpotlight: Identifiable, Hashable, Sendable {
    let quoteID: UUID

    var id: UUID { quoteID }
}

/// The bundled legal pages (`App/Resources/Legal/*.md`), shown by `TextPageView(page:)`.
enum LegalPage: String, Hashable, Sendable, CaseIterable, Identifiable {
    case terms
    case privacy
    case communityGuidelines

    var id: String { rawValue }

    /// The navigation title.
    var title: String {
        switch self {
        case .terms: "Terms of Use"
        case .privacy: "Privacy Policy"
        case .communityGuidelines: "Community Guidelines"
        }
    }

    /// The bundled file name, without the `.md` extension.
    var resourceName: String {
        switch self {
        case .terms: "terms"
        case .privacy: "privacy"
        case .communityGuidelines: "community-guidelines"
        }
    }

    /// The bundled Markdown file, or nil if it is missing from the bundle.
    var url: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "md", subdirectory: "Legal")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "md")
    }

    /// The page's Markdown source, or nil if the file is missing or unreadable.
    func loadMarkdown() -> String? {
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
