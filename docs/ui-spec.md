# Quoted: UI spec for implementation (Margin + council grafts)

Source of truth for the SwiftUI build. Visual reference: `design/renders/Main.png` and `design/renders/Margin-*.png` (the Margin direction). Decision and full critique: `docs/decisions/2026-10-18-ui-direction.md`. Where this spec and the mockups disagree, **this spec wins**: it already includes the council's grafts and fixes.

## Principles
- The quote is the loudest thing on every screen. Each screen has at most one filled accent action. Everything is stock SwiftUI on iOS 26 (Liquid Glass tab bar, large titles, `.searchable`, sheets, `List`, `Toggle`, `Stepper`, `DatePicker`, segmented `Picker`, `PasteButton`, `ShareLink`).
- Light and dark from day one (asset-catalog colors). Dynamic Type everywhere, with rows truncating with a line limit. The single-quote screen never truncates. VoiceOver labels on every icon-only control. Touch targets ≥ 44pt.
- UI copy says **"Reminders"**, never "Rotation" or "Playlist" (the council's naming fix). The code keeps the `rotation` naming internally. The glyph is `bell` / `bell.fill`, never the repeat arrows.

## Design tokens (`App/Design/Theme.swift` + `Assets.xcassets`)
| Token | Light | Dark | Use |
|---|---|---|---|
| `Ground` | #F8F8F6 | #0C0C0E | Screen background |
| `Surface` | #FFFFFF | #161619 | Cards, editor page, widgets |
| `Hairline` | #E6E4DF | white 8% | Separators, card strokes |
| `AccentColor` | #2B44C9 | #8B98FF | Tint, selected states, filled buttons. Use dark text #0C0C0E on dark-mode fills when white fails AA. Verify contrast. |
| `AccentSoft` | accent 8–12% | accent 18% | Selected chips and highlight backgrounds |
| Text | `.primary` / `.secondary` / `.tertiary` (system hierarchical) | same | Do not hand-roll ink opacities |

**Type.** Quotes use the system serif (New York): `.fontDesign(.serif)`. It replaces the mockup's Newsreader, with no bundled font, full Dynamic Type, and bold and italic for free. UI text uses the default SF.
- `QuoteStyle.row`: `.title3`, serif, regular, line limit 4.
- `QuoteStyle.hero`: `.largeTitle`, serif, regular. Used on the detail screen and Welcome.
- `QuoteStyle.editor`: about 26pt, serif, relative to `.title2`.
- `Attribution`: author in `.caption` semibold, uppercase, tracking 1.2, `.secondary`. The source follows in `.caption` serif italic, `.secondary`.

**Shape and spacing.** Cards are `RoundedRectangle(cornerRadius: 20, style: .continuous)` filled with `Surface` and stroked with a 1px `Hairline`. Primary buttons are capsules, 52pt tall, filled with the accent. Spacing follows the 8-pt grid: 16pt screen gutters, 24pt between groups, 16pt card padding.

**Shared components** (`App/Design/Components/`):
- `QuoteText(body:runs:style:)` renders runs through `RichText` to `AttributedString`.
- `AttributionLine(author:source:inReminders:)` shows a small `bell.fill` glyph before the author when the quote is in reminders, with `accessibilityLabel("In reminders")`.
- `QuoteRow`
- `QuoteCard` (the big page card)
- `StatusCard`
- `AvatarCircle(name:)` shows initials on a tint picked deterministically from the user ID.
- `PrimaryButton` (one line; at accessibility text sizes the title wraps and the button grows, never truncates)
- `Toast` (one message with an optional Undo). While VoiceOver or Switch Control runs, an Undo toast stays 10× as long (50 s), never closes while VoiceOver is on it, takes VoiceOver focus and is announced as "Quote deleted. Undo available."; double-tap or Magic Tap runs Undo.
- `EmptyState`

## App structure
```
RootView (SessionStore.phase)
├─ launching          → Ground with the wordmark (no spinner unless > 1 s)
├─ signedOut          → AuthFlow: Welcome/SignIn ⇄ CreateAccount → CheckEmail
├─ needsUsername      → UsernameView
├─ needsStarter       → StarterPackView → NotificationPrimingView
└─ ready              → MainTabView (iOS 26 TabView)
     ├─ Tab "Library" (books.vertical)   NavigationStack → LibraryView
     ├─ Tab "Friends" (person.2, badge = incoming requests + unseen shares) → FriendsView
     └─ Tab(role: .search) "Search"      NavigationStack → SearchView
Sheets: AddEditQuoteView, ShareQuoteSheet, WidgetGuideView, ReminderQuotePicker
Pushes: QuoteDetailView, RemindersView, SharedInboxView, AccountView, BlockedUsersView, TextPageView
```
Deep links (`quoted://`):
- `quote/<id>` (from a notification tap or a widget) selects the Library tab and pushes `QuoteDetailView`. The pager covers the reminder quotes.
- `rotation` pushes `RemindersView`.
- `auth-callback` completes email confirmation.

## Screens

### 1. Welcome / Sign in (`Main.png`)
- Wordmark "Quoted" in serif semibold, followed by an accent-colored period.
- Subtitle: **"Keep the words that move you, and see them again every day."**
- Hero quote: Shelley, with the "fearless" italic run, a hanging open-quote and an attribution line.
- At the bottom, a card holds the Email and Password fields with labels. Use `textContentType` `.username` / `.password` for AutoFill and submit labels next / go.
- Primary button: **Sign in**.
- Below it, a "Forgot password?" text button, which sends a reset email and shows a toast, and "New here? **Create account**".
- Errors appear inline under the card in `.footnote`, in `.inlineError` (a red that keeps 4.5:1 contrast) only for the error text.
- **Create account** has the same layout: email, a password field with "8+ characters", a primary **Create account** button, and the line "By continuing you agree to the Terms and Community Guidelines. See our Privacy Policy." (links open `TextPageView`).
  - If the server requires confirmation, show **CheckEmail**: "Check your inbox. We sent a link to *x*. Open it on this iPhone." Offer "Open Mail" and "Resend".

### 2. Username
- Title "Choose a username".
- An `@` prefixed field with live validation (`Username.validate`). Check availability with a debounce: a checkmark when it's free, "Taken" when it isn't.
- A Display name field.
- Primary button **Continue**.

### 3. Starter pack (`Margin-Starter.png`)
- Title "Pick a few to start", with the subtitle "They'll show up in your widget and reminders."
- A list of all 60 `starter_quotes`, each row a serif excerpt plus an attribution. Tapping the whole row toggles it; a check circle in the accent shows the selected state.
- The bottom button reads **Continue with N quotes** and is disabled at 0.
- "Skip" in the nav bar.
- Selected quotes are imported with `addToRotation: true`.

### 4. Notification priming (council fix, critical)
- Title "Your quotes, a few times a day".
- A sample notification card, plain text, showing one of the user's quotes.
- Copy: "Quoted will show you 3 of your quotes a day, between 8 AM and 9 PM. You can change this anytime."
- **Allow notifications** opens the system prompt. "Not now" is a text button.
- Both paths lead to Main. If the user denied, the status card shows the off state (Library section).

### 5. Library (Home)
- Large title "Library". A filled accent `+` in the toolbar opens Add.
- **StatusCard** (shown when at least one quote is in reminders) pushes Reminders. It has a bell tile in a soft accent square and reads:
  - Normal: "**6 quotes in your reminders**" / "3× daily · Next at 8:00 PM".
  - Off states: "Reminders off · Turn on", or "Notifications off in Settings · Turn on", which opens `UIApplication.openNotificationSettingsURLString`.
- **Widget tip** (one-time and dismissible): "Put a quote on your Home Screen" opens `WidgetGuideView` (three numbered steps). Hide it permanently after dismissal, or when `WidgetCenter.shared.currentConfigurations()` reports a Quoted widget.
- **Shared row**: "2 shared with you · From Maya and Jordan", with overlapping avatars. Shown only when unseen shares exist. Pushes `SharedInboxView`.
- A count header ("8 quotes"), then the `QuoteRow` list:
  - Rows have no per-row share icon (council fix).
  - Tapping a row opens `QuoteDetailView`.
  - Leading swipe: Share. Trailing swipe: Delete (destructive) and Reminders (add or remove).
  - The context menu holds Share, Add to / Remove from reminders, Edit and Delete.
- Pull to refresh.
- **Empty state:** "Your library is empty" with a filled **Add your first quote** button and a quiet "Pick from the starter pack" link (presents the starter picker). The StatusCard stays hidden. The toolbar `+` turns quiet (glass with an accent glyph) while the empty or load-failed state shows, so the screen keeps one filled action.

### 6. Quote detail (graft from Daily)
- The `QuoteCard` page fills the width: `Surface` and hairline, 32pt padding, the hero serif quote and the attribution.
- A horizontal pager (`TabView` `.page` style) across the list it was opened from: the Library order, or the reminder order when opened from a deep link. For VoiceOver the "2 of 8" counter is adjustable ("Quote, 2 of 8": swipe up or down to change quotes) and each card has Next quote / Previous quote actions.
- Below the card:
  - A primary **Share** button.
  - An "In reminders" `Toggle` with the caption "Shows up in widgets and reminders".
- Toolbar: Edit, plus a `…` menu with Delete (behind a confirmation).

### 7. Add / Edit quote (`Margin-Add.png`)
- A sheet with a grabber, Cancel, the title "New quote" or "Edit quote", and a filled **Save** capsule (disabled until the body is valid).
- Use a `ScrollView` with `.scrollDismissesKeyboard(.interactively)`.
  - **Editor card:** a `RichTextEditor` (a UITextView representable, serif, about 26pt, placeholder "Type or paste a quote"). While empty, the card shows a `PasteButton`.
  - **Card 2:** label-left `LabeledContent` rows for Author and Source (optional).
  - **Card 3:** an "Include in reminders" toggle, on by default, with the caption "Shows up in widgets and reminders".
- **Keyboard toolbar:** B, I and U toggle buttons with the selected state in `AccentSoft`. They reflect the selection's current flags and toggle runs through `RichText.toggle`. Then a `Spacer`, then a `PasteButton`. Return in the editor inserts a newline. The Author field submits to Source, and Source submits to Save.
- **Paste heuristics:** text like `“…” — Name` or `"…" - Name, Work` is split into body, author and source. Smart quotes around the body are stripped.
- Validation errors appear inline. If saving fails, keep the sheet open and show a toast.

### 8. Reminders (`Margin-Rotation.png` + fixes)
- Pushed screen titled "Reminders".
- **Card 1**, the settings:
  - A Reminders toggle with the subtitle "Every day · Next at 8:00 PM".
  - How often: "3× a day" with a `Stepper` (1–12).
  - Between: two compact `DatePicker` controls (`.hourAndMinute`), start before end.
  - Days: a labeled row of 7 chips at 44pt or larger. An ON chip is a solid accent circle with a white letter; an OFF chip is outlined with an ink letter. VoiceOver reads "Monday, on".
- If notification permission is denied, a banner appears above the card: "Notifications are off for Quoted" with **Open Settings**.
- **Section header:** "6 quotes", plus a segmented `Picker` with In order and Shuffle.
- **List:** reorderable rows (drag handles via `onMove`, always in edit mode for this list). Each row shows a number, a one-line serif excerpt and the author in small caps. Swipe a row to remove it from reminders ("Removed from reminders · Undo"; Undo puts it back in its old place).
- **Shuffle:** the order is random each cycle, so rows show no numbers and can't be reordered (no drag handles, no Move up/down actions). The section footer reads "Shown in random order. Choose In order to arrange them."
- An "Add quotes" button opens `ReminderQuotePicker`, a multi-select of library quotes that aren't in reminders.
- Every change re-plans notifications and updates the widget snapshot right away.

### 9. Search (`Tab(role: .search)`, `Margin-Search.png`)
- **Empty query:** "Recent" searches (the last 5, stored locally, with a clear button) and suggestion chips (courage, time, kindness, love, hope).
- **Typing:** results are grouped as follows.
  - **In your library**: `QuoteRow`s with matched terms highlighted in `AccentSoft`. Tapping one opens the detail.
  - **Shared with you**: the row adds "from Jordan · yesterday" and a **Save** (bookmark) button. Save works as in the inbox: the quote goes to the library and the reminders.
  - **Web row, always last:** a globe icon, then "Search the web for “courage” quotes" (in the accent), the caption "Opens Google. Copy a quote, then tap Paste in Add.", and `arrow.up.right`. It opens `SearchIndex.googleURL` in the in-app browser (`SafariView` through `router.present(.safari(url))`; see docs/decisions/2026-10-19-web-search-browser.md) and logs `web_search_tap`.
  - **No matches:** a short "Nothing in your library yet" line, followed by the web row.

### 10. Friends (`Margin-Friends.png` + graft)
- Large title "Friends".
- **Profile row** (graft): avatar, "Alex", "@alex", and "Account and settings" with a chevron. Pushes `AccountView`.
- **Add by username** row: a field with an `@` prefix and an **Add** button (VoiceOver: "Add friend"; Voice Control also answers to "Add"). Results come back as a toast, for example "Request sent to @maya" or "No user named @x".
- **Requests:**
  - Incoming: name, @handle, a filled **Accept** and a plain **Decline**.
  - Outgoing: "Requested" with Cancel.
  - At the default text size the buttons stay beside the person; a long name wraps to two lines instead. They move under the name only at larger sizes.
  - Press and hold (or VoiceOver actions): **Report @x…** and **Block @x**.
- **Shared with you:** the latest 2 as cards (quote, from-line, **Save**, and a `…` menu with Report and Block @x), then "See all" pushing `SharedInboxView`. Opening the tab or the inbox marks shares as seen.
- **Friends:** rows with avatar, name and @handle. Swipe for Remove. The context menu has Remove, Report @x… and Block @x (also VoiceOver actions).
- **Empty states:** "Add friends by username to share quotes" and "Nothing shared yet".
- **Report:** a confirmation dialog with reasons (spam, harassment, inappropriate, other) and "We review reports every day", then a toast "Thanks, we'll review it". The same dialog reports a person ("Report @x?") from a request, a friend or a blocked user. **Block:** a confirmation, after which the friendship and shares disappear.
- **Shared with you (inbox):** swipe left for Delete (full swipe deletes), Block and Report; the "…" menu also has Delete. Delete asks nothing: the card goes at once with "Deleted the quote from Maya" and Undo for 5 s, and the server delete happens when the toast closes.

### 11. Share sheet (council fix)
- A custom sheet in two parts.
- **"Send to a friend":** friend rows with tap-to-select checkmarks, an optional note field (≤ 280 characters) and a **Send** button. Send shows progress until the server answers; a failed send keeps the sheet, the selection and the note. Afterwards, show the toast "Sent to Maya" with **Undo** for 5 s (Undo deletes the share).
- **Other ways:** a `ShareLink` with an image of the `QuoteCard`, rendered by `ImageRenderer` at 3x in light appearance, followed by "Share as text". The text form is `“body” — Author, Source`.
- With no friends yet, the first part reads "Add friends to send quotes in Quoted" and links to the Friends tab.

### 12. Account (graft + App Store fixes)
- Header: avatar, display name, @username, and the sign-in email in `.secondary`.
- **Notifications:** the status (On/Off), opening Settings or Reminders.
- **Blocked users:** a list with Unblock.
- **Community guidelines**, **Terms of use** and **Privacy policy** open in-app `TextPageView` with bundled markdown in `App/Resources/Legal/` (no draft banner; legal review is a founder step in `docs/app-store-submission.md`). `{{SUPPORT_EMAIL}}` in the pages becomes a `mailto:` link; without an address the sentence is left out.
- **Contact support:** a `mailto:` link to the `SupportEmail` Info.plist value (`SUPPORT_EMAIL` in `Config/Release.xcconfig`; Release builds fail without it). Hide the row when it is empty (Debug).
- **Blocked users:** each row's context menu (and VoiceOver actions) also has Report.
- **Sign out.**
- **Delete account:** destructive. A confirmation alert explains that it is permanent and removes quotes, friends and shares. Then call `AccountService.deleteAccount()`, clear the App Group, cancel notifications, reload widgets, and return to Welcome.
- Footer: "Quoted 1.0.0 (1)".

### 13. Widgets (`Margin-Widgets.png` + fixes)
- Families: `.systemSmall`, `.systemMedium` and `.accessoryRectangular`.
- `containerBackground(for: .widget) { Surface }`. Quote text is `widgetAccentable()` so it works in the tinted and clear modes. The serif design and runs are applied through `QuoteText`.
- **Small:** the quote (up to 5 lines, scaling down) and the author in small caps.
- **Medium:** the quote plus the author and source.
- **Rectangular:** the quote (3 lines) followed by "— Author".
- **Timeline:** `ReminderPlanner`, so it matches the latest notification, with one entry per slot over the next 24 h plus "now". `widgetURL` is `quoted://quote/<id>`.
- **Empty or signed out:** "Add quotes to your reminders", linking to `quoted://rotation`.
- Gallery: display name "Quote", description "A quote from your reminders, matching your latest reminder."

### 14. Notifications
- The body reads `“body” — Author`, plain text: notifications can't render runs. There is no title, so iOS shows "Quoted". `threadIdentifier` is `reminders`. `userInfo` carries `quoteID`, and a tap opens the detail.
- Plan with `ReminderPlanner` (at most 60). Replan on launch, on foreground, on any change, and in a `BGAppRefreshTask` (`com.hwei.quoted.refresh`, about every 12 h) that also refreshes the widget snapshot.

## States checklist (every screen)
- **Loading:** cached data first; a spinner only on a cold start with no cache.
- **Empty:** guided, with exactly one filled action.
- **Error:** inline or toast with retry. Never a raw error string.
- **Offline:** reads work from the cache; writes show "You're offline. Try again when connected."
- **Signed out:** the widget shows its empty state, and notifications are cancelled.
