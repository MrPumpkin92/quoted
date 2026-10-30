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
- `QuoteStyle.hero`: `.largeTitle`, serif, regular. Used on the detail screen and Welcome (dormant, §1).
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
├─ launching          → Ground with the wordmark (no spinner unless > 1 s), also while the anonymous
│                       account is created; a failure shows the error with Try again
├─ signedOut          → anonymous accounts: the same launch screen, until the new account exists
│                       (AccountMode.emailPassword only: AuthFlow: Welcome/SignIn ⇄ CreateAccount → CheckEmail)
├─ needsUsername      → UsernameView (the first screen on a fresh install)
├─ needsStarter       → StarterPackView → NotificationPrimingView
└─ ready              → MainTabView (iOS 26 TabView)
     ├─ Tab "Library" (books.vertical)   NavigationStack → LibraryView
     ├─ Tab "Friends" (person.2, badge = incoming requests + unseen shares) → FriendsView
     └─ Tab(role: .search) "Search"      NavigationStack → SearchView
Sheets: AddEditQuoteView, ShareQuoteSheet, WidgetGuideView, ReminderQuotePicker
Pushes: QuoteDetailView, RemindersView, SharedInboxView, ProfileView, AccountView, BlockedUsersView, TextPageView
```
Deep links (`quoted://`):
- `quote/<id>` (from a notification tap or a widget) shows that quote full screen (§6a), over whatever is on screen.
- `rotation` pushes `RemindersView`.
- `auth-callback` completes email confirmation (email accounts only).

## Screens

### 1. Welcome / Sign in (`Main.png`, dormant)
- **Dormant.** Shown only with `AccountMode.emailPassword` (docs/decisions/2026-10-20-anonymous-accounts.md). While accounts are anonymous there is no sign-in screen: the app creates an account for this iPhone and opens on Username (§2). The design below stays for when email sign-in returns.
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
- The first screen on a fresh install, and again after Delete account or a lost session: the app has just created an anonymous account for this iPhone.
- Title "Choose a username".
- An `@` prefixed field with live validation (`Username.validate`). Check availability with a debounce: a checkmark when it's free, "Taken" when it isn't.
- A Display name field.
- Primary button **Continue**.
- Above Continue, the consent line "By continuing you agree to the Terms and Community Guidelines. See our Privacy Policy." Each name is a link that opens the page in a sheet (`LegalConsentText`, shared with Create account). Shown only with anonymous accounts, where no Create account screen comes first.
- Sign out at the top left only when `session.canSignOut`: `AccountMode.emailPassword` and an account that is not anonymous. In this build no account gets it, including a leftover or DEBUG email session. To leave the DEBUG demo account locally, launch with `-UITestReset` or reinstall.

### 3. Starter pack (`Margin-Starter.png`)
- Title "Pick a few to start", with the subtitle "They'll show up in your widget and reminders." and, under it, the verified seal with "Every quote is checked word for word against its source." The rows don't repeat the seal.
- A list of all 60 `starter_quotes`, each row a serif excerpt plus an attribution. Tapping the whole row toggles it; a check circle in the accent shows the selected state.
- The bottom button reads **Continue with N quotes** and is disabled at 0.
- "Skip" in the nav bar.
- Selected quotes are imported with `addToRotation: true`.

### 4. Notification priming (council fix, critical)
- Title "Your quotes, a few times a day".
- A sample notification card, plain text, showing one of the user's quotes laid out like the real one: "Quoted", the author as the subtitle, then the quote.
- Copy: "Quoted will show you 3 of your quotes a day, between 8 AM and 9 PM. You can change this anytime."
- **Allow notifications** opens the system prompt. "Not now" is a text button.
- Both paths lead to Main. If the user denied, the status card shows the off state (Library section).

### 5. Library (Home)
- Large title "Library". A filled accent `+` in the toolbar opens a menu:
  - **New Quote** opens Add.
  - **Browse Verified Quotes** (`checkmark.seal`) opens the **Verified Quotes** sheet: every live quote in `catalog_quotes` (the starters and the later batches), in sections by theme in a fixed order (Courage, Calm, Time, Love, Nature, Purpose, Self). Each quote shows once, under its first theme. The top says "They'll show up in your widget and reminders." and, with the seal, "Every quote is checked word for word against its source."; the rows don't repeat the seal. Rows toggle a check circle; the quotes you already have are dimmed. The pinned button reads **Add N quotes**; the picks join your library and the end of your reminders, in list order, with "Added N quotes".

  This is how people find more verified quotes after onboarding; the empty state used to be the only way in. Onboarding (§3) still offers only the starters.
- **StatusCard** (shown when at least one quote is in reminders) pushes Reminders. It has a bell tile in a soft accent square and reads:
  - Normal: "**6 quotes in your reminders**" / "3× daily · Next at 8:00 PM".
  - Off states: "Reminders off · Turn on", or "Notifications off in Settings · Turn on", which opens `UIApplication.openNotificationSettingsURLString`.
- **Widget tip** (one-time and dismissible): "Put a quote on your Home Screen" opens `WidgetGuideView` (three numbered steps). Hide it permanently after dismissal, or when `WidgetCenter.shared.currentConfigurations()` reports a Quoted widget.
- **Shared row**: "2 shared with you · From Maya and Jordan", with overlapping avatars. Shown only when unseen shares exist. Pushes `SharedInboxView`.
- Once any quote is a favorite, a segmented **All / Favorites** control above the count. Favorites lists only hearted quotes, newest heart first, and the count reads "3 favorites". Removing the last favorite returns to All.
- A count header ("8 quotes"), then the `QuoteRow` list:
  - Rows have no per-row share icon (council fix). The attribution line starts with a small accent bell for quotes in reminders and a small accent heart for favorites.
  - Tapping a row opens `QuoteDetailView`, paging across the list as shown.
  - Leading swipe: Share and Favorite / Remove from favorites (pink fill). Trailing swipe: Delete (destructive) and Reminders (add or remove).
  - The context menu holds Share, Add to / Remove from reminders, Favorite / Remove from favorites, Edit and Delete.
- Pull to refresh.
- **Empty state:** "Your library is empty" with a filled **Add your first quote** button and a quiet "Browse verified quotes" link (presents Verified Quotes). The StatusCard stays hidden. The toolbar `+` turns quiet (glass with an accent glyph) while the empty or load-failed state shows, so the screen keeps one filled action.

### 6. Quote detail (graft from Daily)
- The `QuoteCard` page fills the width: `Surface` and hairline, 32pt padding, the hero serif quote and the attribution.
- A horizontal pager (`TabView` `.page` style) across the list it was opened from: the Library order, or the reminder order when opened from a deep link. For VoiceOver the "2 of 8" counter is adjustable ("Quote, 2 of 8": swipe up or down to change quotes) and each card has Next quote / Previous quote actions.
- Below the card:
  - For a verified quote, a bordered accent capsule **Verified quote** (`checkmark.seal.fill`) above Share. It opens a sheet: the seal and "Verified quote", one sentence on the check, a card with the work (serif italic), the author, "Spoken by …" when a character speaks the line, and where in the work (looked up in `catalog_quotes` by the quote's seal id), a **Read it on Project Gutenberg / Wikisource** row (in-app browser), and "Change the wording, author or source and the seal comes off."
  - A primary **Share** button.
  - An "In reminders" `Toggle` with the caption "Shows up in widgets and reminders".
- Toolbar: the favorite heart (`heart` / `heart.fill`; VoiceOver "Favorite", Selected while on), then Edit and a `…` menu with Delete (behind a confirmation).

### 6a. Full-screen quote (a reminder or widget tap; graft from Daily)
- The council's call: Daily's big card is the screen a notification or widget opens. `QuoteSpotlightView` in a `fullScreenCover` over the tabs (no tab bar), Ground background.
- The quote alone, centred: serif `.spotlight` (about 40 pt, scaled with Dynamic Type; quotes over 280 characters use `.hero`), hanging quotation marks, then the attribution line (bell when in reminders, verified seal). Long quotes and large text sizes scroll.
- Pinned at the bottom: a primary **Share** (the share sheet opens over the cover) and a quiet **Open in Library**, which closes the cover and shows the quote's detail (§6), paging across the reminder quotes.
- The system close button (`Button(role: .close)`) top left; VoiceOver escape closes it too. The favorite heart top right, as on the detail screen.
- At accessibility text sizes the quote uses `.hero` and the buttons scroll with it instead of staying pinned.
- Before the library has loaded (a cold launch from a tap), or while a refresh may still bring the quote in: a delayed spinner. If the library can't load: the error with Try again and Close. A quote that is no longer in the library: "This quote is gone" with Close.
- A newer tap replaces the quote shown. A tap while Share or the display-name sheet is open (they may hold typed text) waits until it closes. Toasts sit above Share.

### 7. Add / Edit quote (`Margin-Add.png`)
- A sheet with a grabber, Cancel, the title "New quote" or "Edit quote", and a filled **Save** capsule (disabled until the body is valid).
- Use a `ScrollView` with `.scrollDismissesKeyboard(.interactively)`.
  - **Editor card:** a `RichTextEditor` (a UITextView representable, serif, about 26pt, placeholder "Type or paste a quote"). While empty, the card shows a `PasteButton`.
  - **Card 2:** label-left `LabeledContent` rows for Author and Source (optional).
  - **Card 3:** an "Include in reminders" toggle, on by default, with the caption "Shows up in widgets and reminders".
- **Keyboard toolbar:** B, I and U toggle buttons with the selected state in `AccentSoft`. They reflect the selection's current flags and toggle runs through `RichText.toggle`. Then a `Spacer`, then a `PasteButton`. Return in the editor inserts a newline. The Author field submits to Source, and Source submits to Save.
- **Paste heuristics:** text like `“…” — Name` or `"…" - Name, Work` is split into body, author and source. Smart quotes around the body are stripped. `QuotedCore.PastedQuote`, linear in the pasted length, so pasting a long page doesn't stall the sheet.
- Validation errors appear inline. If saving fails, keep the sheet open and show a toast.
- A new quote closes with the toast "Saved to your library", or "Saved to your library and reminders" when it joined them. Library switches to All and scrolls to the quote, so it's visible even if Favorites was selected or the list was scrolled down.
- Opened from the Search tab's copied-quote card (`SheetRoute.pastedQuote`), the sheet starts filled from the pasted text, using the same split as Paste.

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
  - The button is never disabled.
  - When every library quote is already in reminders (where onboarding leaves everyone), the picker says "Every quote is in your reminders" and offers **Browse verified quotes** (filled, presents Verified Quotes) and **Write your own** (quiet).
- Every change re-plans notifications and updates the widget snapshot right away.

### 9. Search (`Tab(role: .search)`, `Margin-Search.png`)
- **Empty query:** "Recent" searches (the last 5, stored locally, with a clear button) and suggestion chips (courage, time, kindness, love, hope).
- **Typing:** results are grouped as follows.
  - **In your library**: `QuoteRow`s with matched terms highlighted in `AccentSoft`. Tapping one opens the detail.
  - **Shared with you**: the row adds "from Jordan · yesterday" and a **Save** (bookmark) button. Save works as in the inbox: the quote goes to the library and the reminders.
  - **Web row, always last:** a globe icon, then "Search the web for “courage” quotes" (in the accent), the caption "Opens Google. Copy a quote, then come back here to add it.", and `arrow.up.right`. It opens `SearchIndex.googleURL` in the in-app browser (`SafariView` through `router.present(.safari(url))`; see docs/decisions/2026-10-19-web-search-browser.md) and logs `web_search_tap`.
  - **No matches:** a short "Nothing in your library yet" line, followed by the web row.
  - **Copied-quote card:** when the in-app browser closes and the pasteboard changed while it was open (`changeCount` and `hasStrings`, which show no paste prompt), a card at the top reads "Add the quote you copied".
    - It has the system `PasteButton` and "Not now".
    - Paste opens Add filled from the copied text (`SheetRoute.pastedQuote`).
    - The card scrolls into view when it appears, and VoiceOver announces it.
    - It goes away once something else is copied (checked on return to the app and to the tab).

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
- **Friends:** rows with avatar, name and @handle. Tapping the person opens their profile (§10a). Swipe for Remove. The `…` menu and the context menu have View Profile, Remove, Report @x… and Block @x (also VoiceOver actions).
- **Empty states:** "Add friends by username to share quotes" and "Nothing shared yet".
- **Report:** a confirmation dialog with reasons (spam, harassment, inappropriate, other) and "We review reports every day", then a toast "Thanks, we'll review it". The same dialog reports a person ("Report @x?") from a request, a friend, a friend's profile or a blocked user. **Block:** a confirmation, after which the friendship and shares disappear.
- **Shared with you (inbox):** swipe left for Delete (full swipe deletes), Block and Report; the "…" menu also has Delete. Delete asks nothing: the card goes at once with "Deleted the quote from Maya" and Undo for 5 s, and the server delete happens when the toast closes.

### 10a. Profile (`ProfileView`, route `.profile`)
- Margin cards on Ground, inline title (the person's name, or "Your profile"). Header: a 72-pt avatar (hidden at accessibility sizes), display name, @handle.
- **A friend's profile:** a `…` menu in the toolbar with **Report @x…** and **Block @x** (the same confirmations as on the Friends list; Guideline 1.2). A "Favorites" section with their favorites as `QuoteRow` cards (verified seal included), newest first, each with a bordered **Save** capsule, or "✓ In your library" once you have the same text and author. Save copies it into your library (not into reminders) with "Saved to your library".
  - States: a delayed spinner while loading; "<Name> keeps favorites private" (lock tile) when they haven't turned sharing on; "No favorites yet" when they have none; "You're not friends" (Only friends can see each other's favorites) after an unfriend or block; "Couldn't load favorites" with Try Again. Pull to refresh.
- **Your profile** (Account > Your profile): a **Show favorites to friends** toggle (caption: "Friends can see the quotes you heart." / "Only you can see your favorites."), the footnote "Your other quotes always stay private.", then your favorites as cards that open the detail pager. Empty: "No favorites yet", "Tap ♡ on any quote to add it here."
- Reminders (the playlist) never show on a profile.

### 11. Share sheet (council fix)
- A custom sheet in two parts.
- **"Send to a friend":** friend rows with tap-to-select checkmarks, an optional note field (≤ 280 characters) and a **Send** button. Send shows progress until the server answers; a failed send keeps the sheet, the selection and the note. Afterwards, show the toast "Sent to Maya" with **Undo** for 5 s (Undo deletes the share).
- **Other ways:** a `ShareLink` with an image of the `QuoteCard`, rendered by `ImageRenderer` at 3x in light appearance, followed by "Share as text". The text form is `“body” — Author, Source`.
- With no friends yet, the first part reads "Add friends to send quotes in Quoted" and links to the Friends tab.

### 12. Account (graft + App Store fixes)
- Header: avatar, display name, @username, and, for an email account only, the sign-in email in `.secondary`.
- **Your profile:** "Friends can see your favorites" or "Your favorites are private" under the title; pushes §10a.
- **Notifications:** the status (On/Off), opening Settings or Reminders.
- **Blocked users:** a list with Unblock.
- **Community guidelines**, **Terms of use** and **Privacy policy** open in-app `TextPageView` with bundled markdown in `App/Resources/Legal/` (no draft banner; legal review is a founder step in `docs/app-store-submission.md`). `{{SUPPORT_EMAIL}}` in the pages becomes a `mailto:` link; without an address the sentence is left out.
- **Contact support:** a `mailto:` link to the `SupportEmail` Info.plist value (`SUPPORT_EMAIL` in `Config/Shared.xcconfig`; Release builds fail without it). Hide the row when it is empty.
- **Blocked users:** each row's context menu (and VoiceOver actions) also has Report.
- **Sign out:** only when `session.canSignOut`: `AccountMode.emailPassword` and an account that is not anonymous. In this build no account gets it, including a leftover or DEBUG email session (nothing could sign back in to an anonymous account). To leave the DEBUG demo account locally, launch with `-UITestReset` or reinstall.
- **Delete account:** destructive. A confirmation alert explains that it is permanent and removes quotes, friends and shares. Then call `AccountService.deleteAccount()`, clear the App Group, cancel notifications and reload widgets. With anonymous accounts the app then creates a new, empty account and returns to Choose a username (§2); with email accounts it returns to Welcome.
- Footer: for an anonymous account, "Your account belongs to this iPhone and has no email or password. If you delete the app, it can't be recovered." Then "Deleting your account permanently removes your quotes, friends and shares from our servers." and "Quoted 1.0.0 (1)".

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
- The subtitle is the author, and the body reads `“body”` in plain text with the quote's line breaks (each line tidied, runs of blank lines kept to one): notifications can't render runs. There is no title, so iOS shows "Quoted". `threadIdentifier` is `reminders`. `userInfo` carries `quoteID`, and a tap opens the quote full screen (§6a).
- Plan with `ReminderPlanner` (at most 60). Replan on launch, on foreground, on any change, and in a `BGAppRefreshTask` (`com.hwei.quoted.refresh`, about every 12 h) that also refreshes the widget snapshot.

## States checklist (every screen)
- **Loading:** cached data first; a spinner only on a cold start with no cache.
- **Empty:** guided, with exactly one filled action.
- **Error:** inline or toast with retry. Never a raw error string.
- **Offline:** reads work from the cache; writes show "You're offline. Try again when connected."
- **Signed out** (email accounts; with anonymous accounts only the moment before a new account exists): the widget shows its empty state, and notifications are cancelled.
