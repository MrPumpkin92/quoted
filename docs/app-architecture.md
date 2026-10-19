# Quoted app architecture (the shell contract)

The SwiftUI app shell that every feature builds on. `docs/ui-spec.md` says what each screen does. This document says which APIs a screen uses. The shell owns everything outside `App/Features/`. Feature agents replace the placeholder files in `App/Features/**`, may add files in their own feature folders, and do not edit shell files. If you need a shell change, ask for it.

```
App/
  QuotedApp.swift          @main: Backend.fromBundle() → InstallMarker (first-launch session wipe), HTTP cache
                           purge → AppModel, notification delegate, BG refresh task
  AppModel.swift           Composition root, .appEnvironment(_:), AppModel.preview(), .previewEnvironment()
  Stores/                  SessionStore, LibraryStore, SocialStore, ReminderStore, StarterStore, RecentSearches,
                           WriteTracker (+ RefreshOutcome, ToastCenter.show(error:failure:))
  Services/                NotificationScheduler (+ NotificationDelegate), WidgetBridge, BackgroundRefresh,
                           BackgroundTaskAssertion, AppPreferences, AppInfo, Haptics, Logger categories,
                           Error.friendlyMessage
  Navigation/              Router, Route / SheetRoute / AppTab / LegalPage, RootView, LaunchView, MainTabView
  Design/                  Theme (tokens, modifiers), Typography (QuoteStyle, QuoteContent, Wordmark),
                           Samples (preview data), ComponentGallery (DEBUG), Components/*
  Resources/               Assets.xcassets (colors with dark variants, AppIcon), Legal/*.md
  Features/                Feature-owned screens (placeholders until replaced)
```

## 1. Rules for feature code

- **State lives in stores.** Views read store properties and call store methods. Nothing else talks to `Backend`. Never set `SessionStore.phase` or edit store arrays from a view.
- **Errors become toasts.** Store mutations show their own error toast (and roll back), so views don't. Form-style calls (`SessionStore.signIn`, `createProfile`, ...) throw for inline errors instead. A plain `catch` binds `any Error`, so write `catch { errorText = error.friendlyMessage }`. Never show a raw error string.
- **Optimistic by default.** Mutations update the UI first, then the server. They return `Bool` or an optional value so you can decide whether to dismiss. Two calls wait for the server because a sheet shows progress: `create` and `importStarter`. Show a `ProgressView` on the button (`PrimaryButton(isLoading:)`) and keep the sheet open when they return nil or false.
- **Loading.** Show cached data first. Show a spinner only on a cold load with no data: `!store.hasLoaded`, using `DelayedProgressView()`, which appears after 1 s. Pull to refresh calls `await store.refresh(userInitiated: true)`, which toasts when it fails.
- **Navigation.** Tab roots (`LibraryView`, `FriendsView`, `SearchView`) are already inside a `NavigationStack`, so don't add one. Push with `router.push(_:)` or `NavigationLink(value: Route.x)`. Never add `navigationDestination(for: Route.self)`; the shell maps every route. Views shown as sheets, plus the root views `AuthFlowView`, `UsernameView` and `StarterFlowView`, bring their own `NavigationStack` when they need a toolbar.
- **Sheets.** Present shell sheets with `router.present(.addQuote)` etc., and dismiss with `@Environment(\.dismiss)`. If you present your own `.sheet` or `.fullScreenCover`, add `.toastHost()` to its root so toasts show above it.
- **Search.** The search field is `.searchable` on the search tab's stack, bound to `router.searchText`. `SearchView` reads `router.searchText` and never adds its own `.searchable`.
- **Style.** Use the tokens and components below (no hard-coded colors or fonts). Quote bodies always go through `QuoteText` (or `QuoteRow` / `QuoteCard`) so runs and serif scaling stay consistent. Icon-only controls need `accessibilityLabel`. Touch targets are at least 44 pt, and the size goes **inside** the Button's label (`.frame(minHeight: Theme.Metrics.minTouchTarget).contentShape(Rectangle())` for text buttons, `.capsuleButtonLabel()` for `.bordered` capsules): a frame outside a Button adds layout space, not hit area. UI copy says "Reminders", never "Rotation" or "Playlist"; the glyph is `bell` / `bell.fill`.
- **Swift.** Swift 6 strict concurrency: views and stores are `@MainActor`. No force unwraps and no `print` (use `Logger.<category>`). `Text + Text` is deprecated in iOS 26, so use interpolation: `Text("\(a)\(b)")`. Previews use `.previewEnvironment()`.
- **Build check** (your own derived data): `xcodebuild -project Quoted.xcodeproj -scheme "Quoted Local" -configuration Debug-Local -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build/DD-<agent> build`. Your files must compile with zero warnings.

## 2. Placeholder ownership

Keep every type name and initializer exactly as listed. The shell's routing calls them.

| File | Type and initializer | Shown by | Owner |
|---|---|---|---|
| Features/Auth/AuthFlowView.swift | `AuthFlowView()` | Root, phase `.signedOut` | auth |
| Features/Auth/NewPasswordView.swift | `NewPasswordView()` | Root sheet while `session.isRecoveringPassword` (any phase) | auth |
| Features/Onboarding/UsernameView.swift | `UsernameView()` | Root, phase `.needsUsername` | auth |
| Features/Onboarding/StarterFlowView.swift | `StarterFlowView(mode: StarterFlowMode)`, `enum StarterFlowMode { case onboarding, addMore }` | Root, phase `.needsStarter` (`.onboarding`); sheet `.starterPack` (`.addMore`) | auth |
| Features/Library/LibraryView.swift | `LibraryView()` | Library tab root | library |
| Features/Library/WidgetGuideView.swift | `WidgetGuideView()` | sheet `.widgetGuide` | library |
| Features/Quote/QuoteDetailView.swift | `QuoteDetailView(quoteID: UUID, contextIDs: [UUID])` | route `.quote(id:contextIDs:)` | library |
| Features/Quote/AddEditQuoteView.swift | `AddEditQuoteView(editing: Quote?)` | sheets `.addQuote`, `.editQuote(quote)` | library |
| Features/Quote/ShareQuoteSheet.swift | `ShareQuoteSheet(quote: Quote)` | sheet `.share(quote)` | library |
| Features/Search/SearchView.swift | `SearchView()` | Search tab root | search |
| Features/Reminders/RemindersView.swift | `RemindersView()` | route `.reminders` | search |
| Features/Reminders/ReminderQuotePicker.swift | `ReminderQuotePicker()` | sheet `.reminderPicker` | search |
| Features/Friends/FriendsView.swift | `FriendsView()` | Friends tab root | friends |
| Features/Friends/SharedInboxView.swift | `SharedInboxView()` | route `.sharedInbox` | friends |
| Features/Account/AccountView.swift | `AccountView()` | route `.account` | friends |
| Features/Account/BlockedUsersView.swift | `BlockedUsersView()` | route `.blockedUsers` | friends |
| Features/Account/TextPageView.swift | `TextPageView(page: LegalPage)` | route `.textPage(page)` | friends |

`StarterFlowView(.onboarding)` ends with notification priming, then `session.completeOnboarding()`. Its "Skip" also calls `completeOnboarding()`. In `.addMore` it imports the picked quotes and dismisses.

## 3. AppModel and the environment

```swift
@Observable @MainActor final class AppModel {
    let backend: Backend
    let session: SessionStore
    let library: LibraryStore
    let social: SocialStore
    let reminders: ReminderStore
    let starter: StarterStore
    let recentSearches: RecentSearches
    let router: Router
    let toasts: ToastCenter
    let preferences: AppPreferences
    let widgets: WidgetBridge

    init(backend: Backend, appGroup: AppGroupStore? = AppGroupStore(), sideEffects: Bool = true)
    func start()                              // follows the auth session (RootView calls it)
    func handle(url: URL) async               // .onOpenURL: auth-callback, quote/<id>, rotation
    func open(_ link: DeepLink)               // routes now if .ready, else defers until ready
    func sceneDidBecomeActive() async         // permission + replan + refreshIfStale
    func sceneDidEnterBackground() async      // flushes pending deferred toasts (under background time), schedules BG refresh
    func performBackgroundRefresh() async     // BGAppRefreshTask handler
    static func preview(phase: SessionPhase = .ready, emptyLibrary: Bool = false) -> AppModel
}
extension View {
    func appEnvironment(_ model: AppModel) -> some View   // injects the model, every store, and .tint(accent)
    func previewEnvironment(_ model: AppModel = .preview()) -> some View  // + a toast host, for #Preview
}
```

In views, read only what you need:

```swift
@Environment(LibraryStore.self) private var library
@Environment(Router.self) private var router
@Environment(ToastCenter.self) private var toasts
// also: SessionStore, SocialStore, ReminderStore, StarterStore, RecentSearches, AppPreferences, AppModel
```

For bindings, use `@Bindable var reminders = reminders` inside `body`, then `$reminders.settings.timesPerDay`.

## 4. Store APIs

All stores are `@Observable @MainActor final class`. State is `private(set)`. Mutations never throw unless noted.

### SessionStore: auth, profile, onboarding

```swift
enum SessionPhase { case launching, signedOut, needsUsername, needsStarter, ready }

private(set) var phase: SessionPhase
private(set) var userID: UUID?
private(set) var email: String?
private(set) var profile: Profile?                 // your own profile (username, displayName, handle)
private(set) var pendingConfirmationEmail: String? // non-nil after signUp needed email confirmation
private(set) var launchError: String?              // LaunchView shows it with "Try again"
var isRecoveringPassword: Bool                     // a reset link signed the user in: RootView shows NewPasswordView
static let minimumPasswordLength = 8

func signIn(email: String, password: String) async throws(QuotedError)
@discardableResult func signUp(email: String, password: String) async throws(QuotedError) -> SignUpResult
func clearPendingConfirmation()
func sendPasswordReset(email: String) async throws(QuotedError)
func handleAuthCallback(_ url: URL) async          // AppModel calls it for quoted://auth-callback; toasts on failure
func updatePassword(_ password: String) async throws(QuotedError)
func setNewPassword(_ password: String) async throws(QuotedError)  // NewPasswordView Save: ≥ 8 chars, clears isRecoveringPassword, toasts "Password updated"
func cancelPasswordRecovery()                      // NewPasswordView "Not now" / swipe: stays signed in
func isUsernameAvailable(_ username: String) async throws(QuotedError) -> Bool
func createProfile(username: String, displayName: String?) async throws(QuotedError)
func updateDisplayName(_ displayName: String?) async throws(QuotedError)
func completeOnboarding()
func signOut() async
func deleteAccount() async throws(QuotedError)
func retryLaunch() async
```

- Phases change only inside the store. After `signIn`, `createProfile` or `completeOnboarding`, RootView switches by itself.
- `signUp` returns `.confirmationRequired(email:)` and sets `pendingConfirmationEmail` → show "Check your inbox". **Resend** calls `signUp` again with the same email and password. "Open Mail" is the auth agent's own UI.
- Thrown errors are `QuotedError`: `.usernameTaken`, `.validation(message)` (the message is user-facing), `.network`, and so on. Show `error.friendlyMessage` inline.
- **Phase rules.** Signed in with no profile → `.needsUsername`. With a profile → `.ready` if this user finished onboarding on this device or already has quotes, else `.needsStarter`. A cached profile makes an offline launch go straight to `.ready`. Without the onboarding flag (new device, reinstall) an empty library is checked with the server first; if that check fails, the phase stays `.launching` with `launchError` and "Try again" (an existing user is never sent to the starter pack because a fetch failed).
- **Password reset.** The reset email's link opens `quoted://auth-callback`; `handleAuthCallback` signs the user in and, for a recovery link (`AuthCallbackResult.passwordRecovery`), sets `isRecoveringPassword`. `RootView` then presents `NewPasswordView()` as a sheet over whatever phase follows. The screen asks for the new password twice, ticks off the two rules (8+ characters, both match) as they are met and checks them on Save, which then calls `setNewPassword(_:)` (throws `.validation` under 8 characters, else the server's error; shown inline with `error.friendlyMessage`); success closes the sheet and the user carries on signed in. "Not now" calls `cancelPasswordRecovery()`.
- `signOut()` and `deleteAccount()` commit pending deferred toasts, then wipe the App Group (library cache, widget snapshot, rotation state) after any queued cache write has landed, cancel pending and delivered reminders, reload widgets, empty the HTTP cache (`Backend.purgeHTTPCaches()`), clear recent searches and reset every store and the router. **Reminder settings are per device**: sign-out and session expiry keep them (reminders resume as configured at the next sign-in); only `deleteAccount()` resets them to the defaults. Both run under background time.
- `deleteAccount()` throws (and keeps the account) if the server call fails. A retry after a lost answer succeeds (QuotedKit confirms the user is gone). `.notSignedIn` means the session is unusable while the account may still exist: the store signs out on this device, toasts "Your session has ended. Sign in again to delete your account." and rethrows.

### LibraryStore: quotes, reminder membership, offline cache

```swift
private(set) var quotes: [Quote]            // newest first; a pending (undoable) delete is already removed
private(set) var hasLoaded: Bool            // the cache or the server has answered (gate empty states on it)
private(set) var isRefreshing: Bool
private(set) var lastError: QuotedError?
private(set) var lastRefreshed: Date?
var reminderQuotes: [Quote]                 // in reminder order (rotationPosition)
var quotesNotInReminders: [Quote]           // newest first, for ReminderQuotePicker
var isEmpty: Bool
func quote(id: UUID) -> Quote?
func contains(starter: StarterQuote) -> Bool  // already imported (same body and author)
func reminderPosition(of id: UUID) -> Int?    // index in the reminder order; capture before removing, for Undo

@discardableResult func refresh(userInitiated: Bool = false) async -> Bool
func refreshIfStale(maxAge: TimeInterval = 60) async
@discardableResult func create(draft: QuoteDraft, includeInReminders: Bool, origin: QuoteOrigin = .manual) async -> Quote?
@discardableResult func update(_ quote: Quote) async -> Bool          // body/format/author/source only
func delete(_ quote: Quote)                                            // deletes now; "Quote deleted · Undo" restores it
@discardableResult func setInReminders(_ quote: Quote, _ included: Bool) async -> Bool
@discardableResult func addToReminders(_ ids: [UUID]) async -> Bool    // appended in the given order
@discardableResult func removeFromReminders(_ ids: [UUID]) async -> Bool
@discardableResult func restoreReminder(id: UUID, position: Int) async -> Bool  // Undo for a removal: back at its old index
@discardableResult func reorderReminders(_ ids: [UUID]) async -> Bool
func moveReminders(fromOffsets: IndexSet, toOffset: Int)               // List.onMove
@discardableResult func importStarter(_ starters: [StarterQuote]) async -> Bool   // into the library + end of reminders
@discardableResult func saveShared(_ share: SharedQuote, addToReminders: Bool) async -> Quote?  // "Saved to your library", or "Already in your library"
```

- `create` waits for the server and returns nil on failure (the toast is already shown, so keep the sheet open). Build the draft with `QuotedCore.QuoteDraft(body:format:author:source:)`. Check `draft.isValid` to enable Save, and use `try draft.validated()` for inline errors. Pass `origin: .pasted` when the body came from the PasteButton.
- **`delete` commits immediately; Undo is the inverse.** The quote disappears, the server delete starts at once, and the toast "Quote deleted · Undo" shows (`ToastCenter.show(_:action:)`, not `showDeferred`). Undo waits for the delete, then `QuotesRepository.restore` puts the same quote back (same ID, content, origin and reminder position; if the reminders changed meanwhile it goes back next to its old neighbours). The server owns `created_at`, so a restored quote sorts as the newest. A failed delete puts the quote back with "Couldn't delete. …". If you delete from `QuoteDetailView`, pop or move the pager when `library.quote(id:)` becomes nil.
- Membership changes (`setInReminders`, `add/remove/restore/reorder`) are optimistic and serialized; each queued write sends the reminder order as it is when its turn comes. On failure a write rolls back only the positions it set that nothing has changed since, toasts, and resyncs. For "Removed from reminders · Undo", capture the index first:

  ```swift
  let position = library.reminderPosition(of: quote.id)
  guard await library.setInReminders(quote, false) else { return }
  toasts.show("Removed from reminders") {
      if let position { await library.restoreReminder(id: quote.id, position: position) }
  }
  ```

  Library, Search and Reminders share this through `ReminderMembership.toggle(_:library:toasts:)` / `ReminderMembership.remove(_:library:toasts:)` (in `Features/Library/LibraryView.swift`): "Added to reminders", or "Removed from reminders · Undo" with Undo back at the old position. They show the toast at once (the change is already on screen); a failed write replaces it with the store's error toast.
- `saveShared` never duplicates: if the library already holds the same text and author, it returns that quote (adding it to reminders when asked) and toasts "Already in your library"; a second call while a save runs (double tap) waits for the first. In that case the share is marked saved on the server with `SocialRepository.markSaved(_:)`, without a copy.
- **Refresh.** Calls made while a refresh runs join it (single flight). A refresh that overlapped a server write is dropped, because its rows may predate the write, and a new one runs once the writes settle; a failed write also resyncs then. So a slow fetch never makes a just-created quote vanish or a deleted one come back. Returns true whenever the server answered.
- Every server write runs under `BackgroundTaskAssertion`, so pressing Home right after an action does not cut the request off.
- Every mutation writes the App Group cache and replans reminders and the widget. You never call `replan()` yourself.

### SocialStore: friends, requests, inbox, blocks, reports, sending

```swift
struct Connection: Identifiable, Hashable { let id: UUID /*friendship*/; let kind: Kind /*.friend/.incoming/.outgoing*/; let profile: Profile; let createdAt: Date }
struct FriendRequestResult { let isSuccess: Bool; let message: String }

private(set) var friends: [Connection]              // by name
private(set) var incomingRequests: [Connection]
private(set) var outgoingRequests: [Connection]
private(set) var inbox: [SharedQuote]               // newest first; sender profile in share.sender
private(set) var blockedProfiles: [Profile]         // call loadBlocked() first
private(set) var hasLoaded: Bool, isRefreshing: Bool, lastError: QuotedError?
var unseenShares: [SharedQuote]; var unseenCount: Int
var badgeCount: Int                                 // incoming + unseen (the Friends tab badge, already wired)
var friendProfiles: [Profile]                       // share sheet recipients
var unseenSummary: String?                          // "From Maya and Jordan"
var unseenSenders: [Profile]                        // for AvatarStack
func connection(with userID: UUID) -> Connection?

@discardableResult func refresh(userInitiated: Bool = false) async -> Bool
func refreshIfStale(maxAge: TimeInterval = 60) async
func loadBlocked() async
@discardableResult func sendRequest(toUsername: String) async -> FriendRequestResult   // toasts the message
@discardableResult func accept(_ request: Connection) async -> Bool
@discardableResult func decline(_ request: Connection) async -> Bool
@discardableResult func cancel(_ request: Connection) async -> Bool
@discardableResult func removeFriend(_ friend: Connection) async -> Bool
@discardableResult func block(_ profile: Profile) async -> Bool          // toasts "Blocked @x"
@discardableResult func blockSender(of share: SharedQuote) async -> Bool
@discardableResult func unblock(_ profile: Profile) async -> Bool
@discardableResult func report(_ share: SharedQuote, reason: ReportReason, details: String? = nil) async -> Bool  // "Thanks, we'll review it"
@discardableResult func reportUser(_ userID: UUID, reason: ReportReason, details: String? = nil) async -> Bool  // no share needed
@discardableResult func reportAndBlock(_ share: SharedQuote, reason: ReportReason, details: String? = nil) async -> Bool
@discardableResult func share(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) -> Bool       // sends now, toast + Undo
@discardableResult func send(_ quote: Quote, to recipientIDs: [UUID], note: String? = nil) async -> Bool  // waits; false keeps the sheet open
@discardableResult func deleteShares(_ ids: [UUID]) async -> Bool  // inbox swipe delete; comes back with a toast on failure
func markInboxSeen() async
func markSeen(_ shares: [SharedQuote]) async
```

- `sendRequest` accepts "@maya" or "maya" and shows "Request sent to @maya", "No user named @x" or the error as a toast. Clear the field when `isSuccess`.
- `block` removes the friendship, requests and shares at once. `ReportReason.allCases` and `.title` drive the report dialog. To report and then block, use `reportAndBlock`: the report must be filed before the block, because a block deletes the share.
- **Sending commits immediately; Undo deletes.** Both `share` and `send` validate (at least one recipient, note ≤ 280 characters; otherwise a toast and false) and insert the shares at once. `share` is synchronous: it shows "Sent to Maya" with Undo for 5 s right away and returns true, so dismiss the sheet; a send that then fails shows "Couldn't send. …". `send` waits for the server (show progress on Send): on success it shows the same toast and returns true; on failure it toasts and returns false, so the sheet keeps the selection and the note. Prefer `send`. Undo waits for the insert, then deletes the sent shares (`SocialRepository.deleteShares`); "Couldn't undo. …" if that fails.
- `deleteShares` removes inbox shares at once (no Undo: only the sender can create a share, so confirm first if you need to). Either party may delete; the sender's copy is the same row. `SharedInboxView` deletes without asking: it hides the share at once and shows "Deleted the quote from Maya" with Undo through `ToastCenter.showDeferred`, and calls `deleteShares` only when that toast closes (timeout, a newer toast, leaving the inbox, going to the background, signing out). Undo just shows the share again.
- `reportUser` is the report for a person rather than a quote: Friends offers it on request and friend rows (context menu and VoiceOver actions) and Blocked users on each row, through `.reportUserConfirmation(isPresented:profile:context:)` / `.reportUserConfirmation(item:context:)` (in `SharedInboxView.swift`). The details record where it came from and the display name the reporter saw, since the server snapshots only the username.
- Mutations roll back only what they changed (an accept that fails removes just that friend and puts just that request back), and refreshes follow the same single-flight and drop-if-overlapped rules as `LibraryStore`.
- Your own profile is `SessionStore.profile`, not here.
- Call `markInboxSeen()` when Friends or the inbox appears.

### ReminderStore: settings, permission, the coordinator

```swift
var settings: ReminderSettings          // get/set: saves, sanitizes, replans. Bind controls directly.
private(set) var permission: NotificationPermission     // .notDetermined / .denied / .authorized
private(set) var nextReminderDate: Date?
private(set) var scheduledCount: Int
private(set) var rotation: RotationState?
var quoteCount: Int
var statusSummary: ReminderStatusSummary?   // nil when no quote is in reminders (hide the StatusCard)
var scheduleSummary: String                 // toggle subtitle: "Every day · Next at 8:00 PM" / "Off"
var frequencyText: String                   // "3× a day"
var daysDescription: String                 // "Every day" / "Weekdays" / "Weekends" / "Mon, Wed, Fri"
static func weekdayOptions(calendar: Calendar = .current) -> [WeekdayOption]  // 7 chips in locale order: weekday, letter, name

func refreshPermission() async
@discardableResult func requestAuthorization() async -> NotificationPermission   // system prompt (once), then replan
func turnOn() async                         // StatusCard "Turn on": enable / ask / open Settings
static func openNotificationSettings() async
@discardableResult func replan() -> Task<Void, Never>   // coalesced; stores call it, views don't need to

extension ReminderSettings {                // bindings for DatePicker(.hourAndMinute) and day chips
    var windowStartTime: Date { get set }
    var windowEndTime: Date { get set }
    func isEnabled(weekday: Int) -> Bool
    mutating func toggle(weekday: Int)
}
```

- `ReminderStatusSummary { kind (.active/.remindersOff/.needsPermission/.notificationsDenied), title, detail, isOff, actionTitle }` covers the StatusCard copy, for example "6 quotes in your reminders" / "3× daily · Next at 8:00 PM", or "Notifications off in Settings" with "Turn on".
- Order (In order / Shuffle) is `settings.order` (`.inOrder` / `.shuffle`). Times per day is `settings.timesPerDay` (1...12, so use a `Stepper` with `in: ReminderSettings.timesPerDayRange`). The banner "Notifications are off for Quoted · Open Settings" shows when `permission == .denied`.
- Settings are per device and kept across sign-out and session expiry (only account deletion resets them; `SessionStore` calls the internal `reset(keepingSettings:)` after wiping the App Group).
- **Replan** means: rotation state (`RotationState.updated(with:at:seed:settings:calendar:)`: unchanged when the set and order are the same; otherwise the anchor stays and `startIndex` moves so the cycle continues after the quote shown last instead of restarting at the top) → `ReminderPlanner.plan` (≤ 60) → replace the pending `reminder-` notifications → write the widget snapshot → reload widget timelines. It runs on launch, foreground, background refresh, every library mutation and every settings change.

### StarterStore

```swift
private(set) var quotes: [StarterQuote]; private(set) var isLoading: Bool; private(set) var lastError: QuotedError?
func load(force: Bool = false) async        // once per session; show lastError inline with a retry
```

### RecentSearches

```swift
static let limit = 5
private(set) var terms: [String]             // newest first
func add(_ term: String)                     // call on submit (.onSubmit(of: .search))
func remove(_ term: String)
func clear()
```

### AppPreferences

```swift
var widgetTipDismissed: Bool                 // set true when the Library widget tip is dismissed (persists)
// per-user onboarding flag and cached profile are used by SessionStore only
```

Hide the widget tip when `preferences.widgetTipDismissed || await model.widgets.hasInstalledWidget()`.

### ToastCenter: one toast at a time

```swift
func show(_ message: String, style: Toast.Style = .info /* .success, .error */, duration: Duration = .seconds(4))
func show(_ message: String, actionTitle: String = "Undo", duration: Duration = .seconds(5), action: @escaping @MainActor () async -> Void)
func showDeferred(_ message: String, actionTitle: String = "Undo", duration: Duration = .seconds(5),
                  undo: @escaping @MainActor () async -> Void, commit: @escaping @MainActor () async -> Void)
func show(error: any Error)                  // friendly copy; offline → "You're offline. Try again when connected."; ignores cancellation
func show(error: any Error, failure: String) // "Couldn't send. You're offline. …" (Stores/WriteTracker.swift)
func dismiss(); func flushPending() async
nonisolated static func message(for error: any Error) -> String?
extension View { func toastHost(bottomPadding: CGFloat = 16) -> some View }
extension Error { var friendlyMessage: String }   // for inline form errors
```

- With `show(_:action:)` the change has already happened, and the action reverses it.
- **Assistive technology (WCAG 2.2.1).** While VoiceOver or Switch Control runs (`ToastCenter.isAssistiveTechnologyRunning`), a toast with an action stays `assistiveDurationFactor` (10) times as long, so 50 s for Undo. With VoiceOver the host moves focus to it, and it never times out while focused (`accessibilityFocusChanged(_:toastID:)` restarts the full time when focus leaves). The toast is one element, "Quote deleted. Undo, button": double-tap, the named action or a Magic Tap runs the action; "Dismiss" and the escape gesture close it. Every toast is announced; an actionable one as "Quote deleted. Undo available." (`ToastCenter.announcement(message:actionTitle:)`).
- With `showDeferred` exactly one of `undo` or `commit` runs. `commit` runs when the toast times out, is swiped away or replaced, or when the app backgrounds (under background time) or signs out. The stores no longer use it: delete and send commit immediately and their Undo runs the inverse operation, so nothing is lost if the app is killed inside the 5 s.
- Toasts appear above the tab bar at root level and above sheets that carry `.toastHost()`. All shell sheets do.

## 5. Router

```swift
enum AppTab { case library, friends, search }
enum Route: Hashable {
    case quote(id: UUID, contextIDs: [UUID])   // QuoteDetailView pages across contextIDs
    case reminders, sharedInbox, account, blockedUsers
    case textPage(LegalPage)
}
enum SheetRoute: Identifiable, Hashable {
    case addQuote, editQuote(Quote), share(Quote), widgetGuide, reminderPicker, starterPack
}
enum LegalPage: String, CaseIterable, Identifiable { case terms, privacy, communityGuidelines
    var title: String; var resourceName: String; var url: URL?; func loadMarkdown() -> String? }

@Observable @MainActor final class Router {
    var selectedTab: AppTab
    var libraryPath: [Route]; var friendsPath: [Route]; var searchPath: [Route]
    var sheet: SheetRoute?
    var searchText: String                  // the search field (bound by MainTabView)
    var isSearchPresented: Bool
    private(set) var pendingLink: DeepLink?     // waiting for .ready, or for a sheet with input to close

    func select(_ tab: AppTab)              // re-selecting pops to root
    func push(_ route: Route)               // on the selected tab
    func push(_ route: Route, in tab: AppTab)
    func showQuote(_ id: UUID, in contextIDs: [UUID])
    func pop(); func popToRoot(_ tab: AppTab? = nil)
    func path(for: AppTab) -> [Route]; func setPath(_ routes: [Route], for: AppTab)
    func present(_ sheet: SheetRoute); func dismissSheet()
    func search(for term: String)           // suggestion chips / recents: selects Search and fills the field
    @discardableResult func open(_ link: DeepLink, reminderQuoteIDs: [UUID]) -> Bool   // AppModel calls this; false = waiting
    func openPendingLink(reminderQuoteIDs: [UUID])          // MainTabView's sheet onDismiss calls this
}
extension SheetRoute { var mayHoldUnsavedInput: Bool }      // addQuote, editQuote, share, reminderPicker, starterPack
```

Examples:

- Open a quote from a list: `router.showQuote(quote.id, in: library.quotes.map(\.id))`, or `NavigationLink(value: Route.quote(id: quote.id, contextIDs: ids))`.
- Open from Reminders: pass `library.reminderQuotes.map(\.id)`. From search: pass the result IDs.
- Other pushes: `router.push(.reminders)`, `router.push(.account)`, `router.push(.textPage(.privacy))`.
- Sheets: `router.present(.addQuote)`, `.editQuote(quote)`, `.share(quote)`, `.widgetGuide`, `.reminderPicker`, `.starterPack`, `.safari(url)` (the search tab's in-app Google browser; it holds no unsaved input).
- From an Add sheet's "no friends" link to Friends: `router.dismissSheet(); router.select(.friends)`.

## 6. Design system

### Tokens (asset colors with dark variants, generated symbols)

| Token | Light / Dark | Use |
|---|---|---|
| `Color.ground` | #F8F8F6 / #0C0C0E | Screen background (`.groundBackground()`) |
| `Color.surface` | #FFFFFF / #161619 | Cards, editor page, share card |
| `Color.hairline` | #E6E4DF / white 8% | Separators, card strokes |
| `Color.accentColor` (`.tint`) | #2B44C9 / #8B98FF | Tint, selection, filled buttons. The app tint is set by `appEnvironment`. |
| `Color.accentSoft` | accent 10% / 18% | Selected chips, search highlights, tiles |
| `Color.onAccent` | white / #0C0C0E | Text and glyphs on an accent fill (dark mode passes AA) |
| Text | `.primary` / `.secondary` / `.tertiary` | Never hand-roll opacities. Use `.secondary`, not `.tertiary`, for text people need to read (`.tertiary` is about 1.7:1 on Ground). |
| `.inlineError` (`ShapeStyle where Self == Color`) | #C4271C / #FF6B60 (darker or lighter with Increase Contrast) | Inline error text under a form and "Taken". System red is only about 3.3:1 on Ground; this keeps 4.5:1 on Ground and Surface. Defined in `App/Design/InlineErrorColor.swift`; used by Auth, Username, Friends, NewPassword, Add/Edit and the share note counter. |

`Theme.Spacing`: xxs 4, xs 8, s 12, m 16, l 24, xl 32, xxl 48; `gutter` 16, `group` 24, `cardPadding` 16, `pagePadding` 32. `Theme.Radius.card` is 20 (continuous) and `tile` is 10. `Theme.Metrics`: `primaryButtonHeight` 52, `minTouchTarget` 44, `hairline` 1, `tabBarClearance` 64. `Theme.cardShape` is the card shape.

Modifiers:

- `.groundBackground()`: the Ground background, with List/Form/ScrollView backgrounds hidden.
- `.groundListRow()`: a plain-List row with a Ground background, hairline separator and 16-pt gutters.
- `.card(padding:)`: Surface, hairline and 20-pt corners.

### Typography

- `QuoteStyle`: `.row` (title3, 4 lines), `.excerpt` (title3, 1 line), `.hero` (largeTitle, never truncates), `.editor` (26 pt scaled relative to title2), `.compact` (body, 6 lines). All are the system serif.
- `QuoteStyle.editorUIFont(bold:italic:compatibleWith:) -> UIFont` gives the UITextView editor its font.
- `AttributionStyle.author(_:)` and `.source(_:)` return `Text`: the author in caption semibold uppercase with tracking 1.2, and the source in caption serif italic, both secondary.
- `Wordmark(textStyle:)`: "Quoted." with an accent period. Its accessibility label is "Quoted".
- `protocol QuoteContent: RichTextContent { author; source }` is adopted by `Quote`, `SharedQuote`, `StarterQuote` and `SnapshotQuote`, so every component accepts any of them.

### Components (`App/Design/Components/`)

| Component | Signature | Use |
|---|---|---|
| QuoteText | `QuoteText(_ content: some RichTextContent, style: QuoteStyle = .row, quoteMarks: .none/.hanging, lineLimit: Int? = nil, highlighting: [String] = [])`; also `QuoteText(body:runs:style:quoteMarks:lineLimit:highlighting:)` | Every quote body. Use `.hanging` for hero quotes; the open quote hangs left, so give the text ≥ 24 pt leading room. `highlighting` tints search matches. |
| AttributionLine | `AttributionLine(author:source:inReminders: Bool = false)`, `AttributionLine(_ content: some QuoteContent, inReminders:)` | Under quotes. `inReminders` adds the accent `bell.fill` ("In reminders"). |
| QuoteRow | `QuoteRow(_ content: some QuoteContent, inReminders: Bool? = nil /*nil = quote.isInRotation*/, style: .row/.excerpt, highlighting: [String] = [])` | Library, search, starter and picker rows. No padding of its own; use `.groundListRow()` in a List. |
| QuoteCard | `QuoteCard(_ content: some QuoteContent, inReminders: Bool? = nil, showsWordmark: Bool = false)`; `QuoteCard.shareImage(for:width:) -> UIImage?` (3x, light, with wordmark) | Detail pager pages; the share image (`ShareLink` with `Image(uiImage:)`). |
| StatusCard | `StatusCard(summary: ReminderStatusSummary, onOpen: () -> Void, onTurnOn: (() -> Void)?)`; also `StatusCard(title:detail:isOff:actionTitle:onOpen:onTurnOn:)` | Library top: `onOpen: { router.push(.reminders) }`, `onTurnOn: { Task { await reminders.turnOn() } }`. At accessibility text sizes the tile sits above the text and "Turn on" below it. |
| IconTile | `IconTile(systemName: String, tone: .accent / .muted)`; `IconTile.layout(for: DynamicTypeSize, alignment: VerticalAlignment = .center) -> AnyLayout` (in StatusCard.swift) | The 40-pt glyph tile of cards and banners. It grows to 64 pt with Dynamic Type and its glyph stops at AX1. Lay a tile and its text out with `let layout = IconTile.layout(for: dynamicTypeSize); layout { IconTile(…); text }`, which stacks them at accessibility sizes. |
| AvatarCircle | `AvatarCircle(name: String, id: UUID, size: CGFloat = 40)`, `AvatarCircle(profile:size:)` | People rows. One initial on a deterministic tint; hidden from VoiceOver. |
| AvatarStack | `AvatarStack(profiles: [Profile], size: CGFloat = 32)` | "2 shared with you" row. |
| PrimaryButton | `PrimaryButton(_ title: LocalizedStringKey, systemImage: String? = nil, isLoading: Bool = false, action:)`; `.buttonStyle(.primary)` | The one filled action per screen (52-pt accent capsule; at accessibility text sizes the title wraps and the button grows instead of truncating). `.disabled()` dims it. For small capsules (nav-bar Save, Accept, Save on share cards) use stock `.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)`; for quiet ones, `.bordered`. |
| CardContainer | `CardContainer(padding: CGFloat = 16) { … }`, `HairlineDivider(leadingInset:)` | Grouped controls (Add sheet cards, Reminders settings, request rows). |
| EmptyStateView | `EmptyStateView(systemImage:title:message:actionTitle:action:secondaryTitle:secondaryAction:)` | Guided empty states: one filled action and one quiet link. |
| DelayedProgressView | `DelayedProgressView(delay: .seconds(1), label:)` | Cold-load spinners. |
| Toast / ToastView | Driven by ToastCenter. You don't instantiate these. | |

Preview data: `Samples.emerson / shelley / seneca / whitman / thoreau / dickinson / shakespeare / austen`, `Samples.quotes` (eight, six in reminders), `Samples.alex / maya / jordan / sam / riley`, `Samples.friendships`, `Samples.inbox`, `Samples.starters`.

## 7. Flows

- **Launch.** `QuotedApp` builds the Backend (a misconfigured build shows `ConfigurationErrorView`). On the first launch after an install (no `quoted.installMarker` in `UserDefaults.standard`, which iOS deletes with the app) it calls `AuthService.clearLocalSession()`, because Keychain items outlive the app and would otherwise sign the previous user back in. It empties `URLCache.shared` (`Backend.purgeHTTPCaches()`), then builds `AppModel` and installs `NotificationDelegate`. `RootView.onAppear` → `start()` → the session stream. With a stored session, the cached library appears immediately, the cached profile picks the phase, and refreshes run in the background. Signed out → `AuthFlowView`. On the first launch after sign-in, if the profile fetch fails offline, `LaunchView` shows the error and "Try again".
- **Ready.** Entering `.ready` applies any deferred deep link, schedules the BG refresh, refreshes permission, replans, and refreshes the library (if stale) and social data.
- **Deep links** (`quoted://`): `auth-callback` → `SessionStore.handleAuthCallback` (a password-reset link then shows `NewPasswordView`). `quote/<id>` → the Library tab, with the stack set to `[.quote(id, contextIDs: reminder IDs)]`. `rotation` → Library, then `[.reminders]`. **A link never discards a draft:** when the open sheet may hold unsaved input (Add, Edit, Share, the reminder picker, the starter pack), the sheet stays and the link waits in `router.pendingLink`; it opens as soon as the sheet is dismissed (saved or cancelled), from `MainTabView`'s `.sheet(item:onDismiss:)`. The widget guide closes at once. Links that arrive before `.ready` also wait in `router.pendingLink`.
- **Notifications.** The identifier is `reminder-<unix seconds>`. The body is `“body” — Author`, with no title, `threadIdentifier` `reminders`, and `userInfo["quoteID"]`. While the app is open, reminders show as banners. A tap becomes `DeepLink.quote(id)` → `AppModel.open`.
- **Widgets.** Each replan writes `widget-snapshot.json` (QuotedCore `WidgetSnapshot`: the reminder quotes in order, settings, rotation) and reloads all timelines. The widget runs the same `ReminderPlanner`, so it matches the last reminder. An empty or signed-out snapshot shows the widget's empty state, which links to `quoted://rotation`. `widgets.hasInstalledWidget()` asks WidgetKit whether any Quoted widget exists.
- **Background refresh.** `BGAppRefreshTask` `com.hwei.quoted.refresh` runs about every 12 h, registered by `.backgroundTask(.appRefresh(...))`. It refreshes the library if signed in, then replans and reschedules itself. The app also schedules it when going to the background.
- **Scene phase.** Becoming active re-reads permission, replans and refreshes if stale (60 s). Going to the background commits pending deferred toasts under background time and schedules the BG refresh. `.inactive` (Control Center, the app switcher) commits nothing.
- **Background time.** Every store write (create, edit, delete and its Undo, reminder changes, starter import, save shared, send and its Undo, friend actions, blocks, reports, sign-out, account deletion) holds a `BackgroundTaskAssertion` while its request runs, so leaving the app right after an action finishes it instead of failing on resume.
- **Sign-out and delete account.** See SessionStore. Both leave no user data in the App Group, the HTTP cache, the notifications or the stores; only the per-device reminder settings survive a sign-out.
- **Support address and legal pages.** Info.plist `SupportEmail` is `$(SUPPORT_EMAIL)` from the xcconfigs: empty in `Config/Shared.xcconfig`, set by the founder in `Config/Release.xcconfig`. The `Check release settings` pre-build phase (`project.yml`) fails Release builds while it is empty or not an address, or while a legal page still has a draft banner. `AppInfo.supportEmail` drives Account > Contact support, and `TextPageView` turns `{{SUPPORT_EMAIL}}` in `App/Resources/Legal/*.md` into a `mailto:` link (`LegalMarkdown.resolvingPlaceholders(in:supportEmail:)`). Without an address (Debug) it drops each sentence that mentions it, then any section left empty.

## 8. Debug aids

- `xcrun simctl launch <udid> com.hwei.quoted -QuotedDemo` boots into `AppModel.preview()`: signed in as Alex, eight quotes, a request each way and two unseen shares. There is no backend and no side effects. Use it for screenshots of your screens.
- `-QuotedGallery [-QuotedGalleryPage 1|2|3]` shows every design component, in either appearance (`xcrun simctl ui <udid> appearance dark`).
- Both are DEBUG builds only. `Logger.app / .session / .library / .social / .reminders / .ui` log to the `com.hwei.quoted` subsystem.

## 9. Known gaps and decisions

- **Undo is the inverse operation.** Delete and send commit immediately; Undo restores the quote (`QuotesRepository.restore`) or deletes the sent shares (`SocialRepository.deleteShares`). A restored quote gets a new server `created_at`, so it moves to the top of the Library.
- **"Already in your library" marks the share saved.** When an identical quote already exists, `saveShared` makes no copy and stamps the share's `saved_at` with `SocialRepository.markSaved(_:)` (best effort, counted as a social write so a refresh can't flip it back).
- **No "Reminders paused" state.** The app replans on every launch and foreground and in the BG task, so whenever the status card is visible the queue was just refilled (up to 60, about 20 days at 3 a day).
- **Settings changes and the cycle.** Changing times per day or the window re-maps slot ordinals from the same anchor, so the next quote can jump; only membership and order changes keep the cycle's place (`RotationState.updated`).
