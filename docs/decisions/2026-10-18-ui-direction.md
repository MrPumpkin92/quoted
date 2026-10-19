# Decision: UI direction (LLM Council + design critique, 2026-10-18)

**Winner:** Margin, with grafts from the runners-up (below).

**Votes:** The Contrarian: Margin; The First Principles Thinker: Nocturne; The Expansionist: Daily; The Outsider: Daily; The Executor: Margin

Mockups: `design/canvas/project/*.dc.html`. Renders: `design/renders/*.png`. Live canvas: https://claude.ai/artifact/1TEs8buEjUWDh4q251puea

---

## Where the Council Agrees

- **Rotation is a flag plus a schedule. It doesn't need its own place in the app.** Both Margin voters (Contrarian, Executor) drop Margin's Rotation tab. The First Principles Thinker reaches the same model by another route. A tab for a screen you set once also lists Library's quotes a second time.
- **Nocturne's status line is the clearest sentence in all 24 screens.** "6 quotes in rotation · 3× daily · Next at 8:00 PM" explains the core loop and answers "is it working?" in one row. The Outsider, First Principles, Contrarian and Executor all praise it.
- **Nocturne's bottom-right search tab is the best native iOS 26 move.** Four advisors want `Tab(role: .search)`, which is stock, sits under the thumb and gives library, shared and web results their own screen.
- **Margin has the cleanest hierarchy and the lowest build risk.** UI text is SF, quotes are Newsreader, and every control is stock. Each screen has one filled action. Margin-Add is the clearest editor of the three: a filled Save, a quiet B tint and helper text under the toggle. I checked this in the renders.
- **Daily's big card is worth keeping, but as the screen that opens when someone taps a notification or widget.** It should not be the home tab (Contrarian, First Principles). The Expansionist's share-object idea fits that screen.
- **Nocturne's identity is a liability.** It is dark only, every quote is heavy white 22pt text in its own card, and its black widgets nearly vanish on dark wallpapers. All five advisors raise some part of this.
- **Daily costs the most to build.** Its costs:
  - Figtree in system chrome
  - an overlay "+" sitting where iOS 26 puts the search tab
  - a masonry Starter grid that needs a custom `Layout`
  - five tints, each needing dark-mode and tinted/clear widget versions

  Four advisors and every peer reviewer say so.
- **The day chips are broken in all three directions.** No render shows what an "off" day looks like.

## Where the Council Clashes

- **Should Home open on a Today card or on the library?** The Expansionist and Outsider say Today, because Daily passes the 2-second test.
  - *Chairman:* the 2-second test is the right test. A list with Nocturne's status card on top also passes it. "Today's card" contradicts a rotation that fires 3× a day, and it repeats a quote the user has already seen in the widget and the notification. The app's own job is to capture and curate.
- **How hard is Daily to build?** The Expansionist says "effort: low"; everyone else says high.
  - *Chairman:* the renders show the masonry grid, the overlay "+", Figtree in the tab bar and the swatch row. It is high.
- **Is "Margin plus Nocturne's navigation" a Margin win or a Nocturne win?** The First Principles Thinker says Nocturne, because structure comes first. The Contrarian and Executor say Margin, because the look is the identity.
  - *Chairman:* moving to two tabs plus a status card takes about a day of work. Turning Nocturne into a light app with a reading face and a list layout means designing a fourth direction. The grafts go one way, so the winner is Margin.
- **Where should search go?** The Outsider found Nocturne's collapsed tab bar during search (a single quote-mark circle) confusing.
  - *Chairman:* that collapse is standard iOS 26 behavior that users already see in system apps. Take the search tab anyway.
- **Who owns the Seneca/Emerson mismatch?** The Contrarian blamed Daily.
  - *Verified:* all three Widgets renders show Seneca in the notification and Emerson in the widget. Daily's "Today's card" label does make its version a stated contradiction.
- **What is wrong with Margin's day chips?** The Contrarian measured them against a gray fill.
  - *Verified:* they sit on a white card. The conclusion still holds, because all seven chips share one pale tint and you can't tell on from off. Daily's solid coral chips don't fix this either (Reviewer 4), since no direction draws an off state.
- **How prominent should share be?** The Contrarian says a share icon on every row is the button noise the brief rules out. The Expansionist says sharing should feel like a moment.
  - *Chairman:* both are right. Take the icon off the rows and make share large on the single-quote screen, as an image card.

## Blind Spots the Council Caught

- **Notification permission.** The whole loop stops at "Don't Allow". No screen shows when the app asks, and none shows the state after a denial. After a denial, the "Next at 8:00 PM" line would be wrong.
- **The 64-notification cap.** iOS keeps only 64 pending local notifications, which lasts about 21 days at 3× a day. The app has to reschedule regularly and needs a "Reminders paused" state.
- **One schedule for both surfaces.** Notifications and the WidgetKit timeline have to read from one schedule that defines which quote is current. Every direction's Widgets render currently disagrees with itself.
- **App Store requirements.** No screen has Settings, sign-out or account deletion, which Guideline 5.1.1(v) requires in the app. For user-generated content, Guideline 1.2 also expects terms, a way to manage blocked users and a support contact. Report and block exist behind the "…" button.
- **Login comes before any value.** Users must enter email and password before the starter pack. There is no forgot-password link and no Sign in with Apple. Collecting quotes and getting reminders don't need an account; only Friends does.
- **Notifications are plain text in SF.** Bold, italic, underline and the custom font are all lost, so the surface people see most looks almost the same in all three directions. The direction only matters in the app and the widget.
- **Undesigned flows.** The share flow (friend picker or system share sheet) and a guide to adding the widget are both missing.
- **Gaps the Contrarian found, which the peer reviewers confirmed:**
  - no quote detail, edit or delete screen
  - no way to add an existing quote to rotation
  - no empty library after Skip
  - the keyboard isn't drawn on Add, and it will cover Author, Source and the toggle
  - shared search results have no Save button

## The Recommendation

**Build Margin, using Nocturne's navigation.**

- **Margin's weaknesses are cheap to fix.** Adopt Nocturne's navigation (drop a tab, pin a status card, add a search tab) and Margin's problems are gone. Nocturne's problems (dark only, heavy type, black widgets) and Daily's (the "Today" concept, custom chrome, the tint system) are what make those directions what they are. Fixing them would mean starting again.
- **It is the most native build for one person.** Custom work is one font on one text style. Everything else is stock SwiftUI on iOS 26, so Liquid Glass, Dynamic Type, dark mode and the iOS 26 `TextEditor` with `AttributedString` come almost free. It also has the least to break across iOS 26.x point releases.
- **It fits the brief best.** It has one filled action per screen, the quote is the loudest thing on every screen, and nothing is decoration.
- **It is the right tone for a reading app.** Newsreader on near-white reads like a book. Margin's plain white widgets are also the most likely of the three to keep working in iOS 26's tinted and clear home-screen modes.
- **The resulting structure:**
  - Two tabs, Library and Friends, plus the search tab.
  - The status card is pinned at the top of Library and pushes to the rotation settings.
  - A single-quote screen in Daily's large-card style. It opens from a notification tap, a widget tap or a Library row, and it carries Share, Edit, the rotation toggle and Delete.
  - The Account row sits at the top of Friends.
- **Why not Daily:** a "today" card doesn't fit a rotation that fires 3× a day. Its Library screen was never drawn, Rotation can only be reached from a small chip, and it has the highest build risk of the three.
- **Why not Nocturne:** its structure is right and has been taken. Its skin would ship as dark only, with heavy white text that is tiring to read at length and widgets that look like black squares.

## The One Thing to Do First

- **Build the rotation schedule and the status card before any visual polish.**
  - Write one `RotationSchedule` model in the App Group. It decides which quote is current.
  - The same model generates the pending notification requests (fewer than 64, topped up at every launch and on background refresh) and the WidgetKit timeline.
  - The Library status card shows its three states: "Next at 8:00 PM", "Reminders paused" and "Notifications off · Turn on".
- **Why this first:** it is the core loop, most of the council's blind spots live there, and it decides the copy on the one card that explains the app. Margin's look can be applied on top afterward.

---

## Grafts into the winner

- **Replace Margin's three tabs with two (Library, Friends) plus the iOS 26 search tab (Tab(role: .search)) at the bottom right. Drop the Rotation tab and the search field under the Library title.** (from Nocturne): Rotation is a setting on one collection, so it doesn't need a tab, and Margin's tab only lists Library's quotes again. The search tab is stock, sits under the thumb and gives library, shared and web results their own screen. It also removes a custom element.
- **Pin a rotation status card at the top of Library: "6 quotes in rotation · 3× daily · Next at 8:00 PM". Tapping it pushes the Reminders/Rotation settings, which also gain the subtitle "Every day · Next at 8:00 PM" under the Reminders toggle.** (from Nocturne): It is the one line that makes a new user understand the app, so Margin's list passes the Outsider's 2-second test without a Today screen. It answers "is it working?" and is the only way into Rotation once that tab is gone.
- **Mark quotes that are in rotation with a small glyph inline before the author name, and remove the ~5pt dot in the left margin and the "• In rotation" legend.** (from Nocturne): Margin's dot is color-only, sits about 11pt from the screen edge, can't be seen by VoiceOver and reads as a bullet point. Use a glyph that doesn't suggest sync or refresh, and give it an accessibilityLabel("In rotation").
- **Add a single-quote screen in the big-card style: the quote set large in Newsreader on a Margin page surface, with the attribution, Share, Edit, an In-rotation toggle, Delete and a swipe to the next quote in rotation. It opens from a notification tap, a widget tap (widgetURL) or a Library row.** (from Daily): It covers the missing detail, edit and delete screen and the missing way to add an existing quote to rotation. It also gives the Expansionist's shareable 'moment' a place, without making 'Today' the home tab.
- **Share a quote as a styled image card (rendered with ImageRenderer through ShareLink), with a 'Send to a friend' row above the system share sheet.** (from Daily): Sharing is the growth step, and plain text loses the bold, italic and underline. One card in Margin's style then serves as the share image, the widget look and the single-quote screen.
- **Replace Margin's 'A · Alex · @alex' pill in the nav bar with a full-width profile row at the top of Friends: 'Alex · @alex · Account and settings'.** (from Daily): The Outsider read the pill as another friend. A labeled row also gives sign-out, account deletion, blocked users and terms an obvious home, which the App Store requires.
- **Use the Welcome subtitle 'Keep the words that move you, and see them again every day.'** (from Nocturne): Margin's line describes collecting but leaves out resurfacing. This one states the whole loop before sign-in.
- **Base dark mode on Nocturne's surfaces: ground #0C0C0E, surface #161619, hairlines at 8% white. Keep Newsreader for quotes, SF for UI and one ink-blue accent lightened for dark backgrounds, with no amber and no grotesk.** (from Nocturne): Only light Margin was rendered. These are tested dark values, and keeping one typeface and one accent keeps a single brand across both appearances and in dark-mode and StandBy widgets.
- **On Add, use label-left Author and Source rows (LabeledContent with a TextField) in place of the stacked label-above-value fields.** (from Daily / Nocturne): They are stock Form rows and save vertical space, which matters once the keyboard covers the bottom half of the sheet.

## Fixes to apply during implementation

| Severity | Screen | Problem | Fix |
|---|---|---|---|
| critical | Onboarding (between Starter and Library) | The app never asks for notification permission and has no state for a denial, so the core loop stops at 'Don't Allow' and the 'Next at 8:00 PM' line becomes wrong. | After Starter, show a short priming screen ('Quoted will show you 3 of your quotes a day, 8 AM–9 PM') with a single Allow button, then the system prompt. If the user denies, the Library status card reads 'Notifications off · Turn on' and opens UIApplication.openNotificationSettingsURLString, and widgets keep working. |
| critical | Widgets & notification (schedule model) | In every render the widget shows Emerson while the notification shows Seneca, and nothing defines which quote is current. iOS also keeps only 64 pending local notifications, about 21 days at 3× a day. | Keep one RotationSchedule in the App Group that generates both the UNNotificationRequests and the WidgetKit timeline entries for the same times. Top up the queue at every launch and with BGAppRefreshTask. If the queue is about to run out, the status card shows 'Reminders paused · Open to resume'. |
| critical | Friends → Account | There is no Settings screen, so sign-out, in-app account deletion (App Store Guideline 5.1.1(v)) and the user-generated-content items (Guideline 1.2: terms, blocked users, contact) have no place. | The profile row (grafted from Daily) opens an Account screen containing Sign out, Delete account (with confirmation and server-side deletion), Blocked users, Community guidelines/Terms, Contact support and the notification status. |
| critical | Library → single-quote screen | No screen lets you view, edit or delete a saved quote, or put an existing quote into rotation. | Tapping a row opens the single-quote screen (grafted big card) with Edit, an In-rotation toggle, Share and Delete. Rows also get swipe actions (rotation, delete) and a context menu. |
| moderate | Rotation | All seven day chips share one pale ink-blue tint on the white card, so there is no visible off state and the chip edges are about 1.2:1 against the card (WCAG 1.4.11). | Draw an on day as a solid ink-blue chip with a white letter and an off day as an outlined chip with ink text, at 44pt or larger. Give each chip a VoiceOver value such as 'Monday, on'. Add a visible 'Days' label (the designer listed its absence as a known issue). |
| moderate | Add quote | The keyboard state was never drawn. With the keyboard up it will cover Author, Source and the rotation toggle, and the B/I/U/Paste bar floats with nothing holding it in place. | Put B/I/U and PasteButton in ToolbarItemGroup(placement: .keyboard). Wrap the sheet in a ScrollView with .scrollDismissesKeyboard(.interactively), and have Return in the editor move focus to Author. Use the iOS 26 TextEditor with an AttributedString binding, and bundle Newsreader's bold and italic faces so bold and italic runs render. |
| moderate | Search | Shared results have no Save, and tapping any result leads nowhere, so a result is a dead end. | Add a Save (bookmark) control to shared results and make every result open the single-quote screen. When nothing matches, show the 'Search the web' row on its own, with copy saying Paste is waiting in Add. |
| moderate | Library (empty state) | Nothing shows what a user sees after pressing Skip on Starter, and the status card would say '0 quotes in rotation'. | Design an empty Library with a single filled 'Add your first quote' button (which opens Add with Paste ready) and a quiet 'Pick from the starter pack' link. The status card stays hidden until at least one quote is in rotation. |
| moderate | Welcome / sign-in | An email and password are required before the user sees any value, there is no forgot-password link, and the create-account path is not designed. | Add 'Forgot password?' and a designed Create account screen. Strongly consider local-first onboarding: Starter, then reminders, then the app, asking for an account only when the user opens Friends or shares. Sign in with Apple is optional while login is email-only. |
| moderate | App-wide (appearance) | Only light Margin was rendered, and the white widgets have no dark, tinted or clear variants. | Define every color as an asset-catalog color with a dark variant (grafted from Nocturne's surfaces) from the first day. In widgets use containerBackground(for: .widget), mark the quote text widgetAccentable, and check every widget family in the dark, tinted and clear home-screen modes. |
| moderate | Share flow | No direction draws what happens after tapping Share: a friend picker, the system sheet or both. | Show one sheet with the friends list (avatars, tap to send) at the top and the system ShareLink with the rendered image card below it. Show a sent confirmation, plus a toast with Undo. |
| minor | Library | Every row repeats the same share icon, which adds the button noise the brief rules out. | Remove the per-row share icon. Offer share in the context menu, as a leading swipe action and as the main action on the single-quote screen. |
| minor | App-wide (naming) | 'Rotation' is jargon, and its repeat-arrows icon reads as 'repeat' or 'sync' (Outsider). | Test a plain label in the status card, the Add toggle and the settings title, for example 'In your reminders'. Pair it with a glyph that doesn't mean refresh, and keep the helper line 'Shows up in widgets and reminders'. |
| minor | Post-onboarding Library | Half of the core loop is the home-screen widget, and nothing teaches users how to add it. | Show a one-time dismissible tip card under the status card ('Put a quote on your Home Screen') that opens a three-step visual guide. Hide it once the app detects an installed widget through WidgetCenter.getCurrentConfigurations. |
| minor | Widgets & notification | Notifications drop bold, italic, underline and Newsreader, so the alert looks generic. | Accept plain text in the banner. Optionally add a Notification Content Extension so the long-press view renders the styled quote card, and make the notification tap open the single-quote screen. |
| minor | Library / Add (type) | Newsreader is a custom font and won't scale with Dynamic Type unless it is set up for it. | Use Font.custom("Newsreader", size:, relativeTo:) for quote styles. Check the Library rows and the single-quote screen at the accessibility text sizes, and allow line-limit truncation in rows but never on the single-quote screen. |

---

## Advisor critiques

### The Contrarian

**MARGIN**
- First impression: the quotes read first and the screens feel calm and credible. The core loop is hidden on Home, though. Rotation shows only as a dot about 5pt wide, about 12pt from the screen edge, explained by a small 13pt gray legend. A new user sees a list and does not learn that these quotes come back to them.
- Usability: Rotation takes a whole tab for settings people change rarely. No screen shows how to add an existing quote to Rotation.
- Clutter: Home repeats 8 identical share icons, which is the button noise the brief rules out. Move share into a swipe or context menu.
- Accessibility: on Rotation, a selected day chip is a 12% blue tint (about #E6E9F8) on a gray fill (about #F1F1F1). That is roughly 1.1:1, which fails WCAG 1.4.11, so you cannot tell which days are off.
- What works: the colors map to iOS system colors, so dark mode costs little. The interface uses SF. The plain-text white widgets should still read in iOS 26's tinted and clear home-screen modes. Each screen keeps to one filled button.

**DAILY**
- The concept breaks: "Today's card" does not fit a quote that changes 3× a day. On Widgets the notification shows Seneca while the "Today's card" widget shows Emerson.
- Home: two side-scrolling rows (the big card and the "up next" shelf) show the same six quotes. The big card has about 120pt of empty tint between the author and the page dots.
- Navigation: the only way into Rotation is the small "Next reminder" chip. Library, the screen that grows as you add quotes, was never drawn.
- Consistency: the rule of one coral button breaks. Rotation has 7 solid coral day chips plus the toggle, the tab and the "+". On Add, the solid coral B is louder than Save, which is plain text.
- Build risk: the "+" sits in the bottom-right circle where iOS 26 puts the search tab. It needs a custom overlay, which won't shrink or hide when iOS 26 collapses the tab bar on scroll. Figtree won't appear in the system tab bar or notifications. The five card tints each need dark-mode and widget versions.

**NOCTURNE**
- First impression: new users understand it fastest. The pinned card ("6 quotes in rotation · 3× daily · Next at 8:00 PM") explains the loop in one line. Two tabs plus the native iOS 26 search tab is the most native and cheapest navigation of the three.
- Hierarchy: every quote is heavy 22pt white text in its own card, never truncated, so nothing stands out. The Austen quote alone will fill most of a screen. Heavy white text on near-black is tiring to read, which matters in a reading app.
- Dark only: no light theme exists, and making one means designing a fourth direction. The black widgets almost vanish on a dark wallpaper.
- Consistency: Friends puts Accept before Decline, the reverse of the other two. Four bright avatar colors break the amber-only rule. Maya's shared quote, the social payoff, sits below the friend list.

**MY PICK: Margin.** Its problems are on the surface and other directions fix them. Daily's problems are structural: the "Today" idea, the navigation and the custom fonts in system areas. Nocturne's are part of its identity: dark only and heavy type. Margin is also the least risky to build in SwiftUI for one person.

**GRAFT:**
1. Nocturne's navigation: drop Margin's Rotation tab. Pin the rotation summary card at the top of Library (it opens Rotation) and move search to the bottom-right search tab.
2. Nocturne's amber rotation icon next to the author, in place of the dot at the screen edge.
3. Daily's full-screen card as the screen you land on after tapping a notification or widget, which no direction designed. Also Daily's solid day chips, so on and off are clear.

**Missing from all three:** none of the 24 screens shows quote detail, edit or delete, an empty library after Skip, or the keyboard on Add. With the keyboard up, it will cover Author, Source and the rotation toggle. Shared results in Search have no Save button, so the user has nowhere to go from them.

### The First Principles Thinker

**Framing:** the council is comparing three skins, but these are really three different app structures. Most of Quoted's life is outside the app, in the widget and the notification. Inside the app, people capture quotes, curate what comes back, check that reminders are running, and share. Rotation is a flag and a schedule on one collection, not a second place. So judge the structure first. The skin is a cheap, separate choice.

**Margin**
- **First impression (Welcome):** its purpose is the clearest of the three. The hanging serif quote reads as "a book of your own words" in two seconds.
- **Structure flaw:** Rotation gets a whole tab (Margin-Rotation) for a screen you set once. That tab lists Library's quotes again, so the same quotes live in two lists. The margin dot on Margin-Home already shows which quotes are in rotation.
- Margin-Home repeats Friends ("2 shared with you"). The filled + sits top-right, out of thumb reach.
- The hairline List rows are the densest layout and the cheapest in SwiftUI (List, .searchable, onMove). They still work at 300 quotes.
- The day chips have no "off" state, so you can't tell which days are selected.

**Daily**
- **Wrong job:** Today (Daily-Home) is a third copy of the widget and the notification. By the time you open the app you've already seen today's quote. The screen is built for reading, but the app's job is capture and curation.
- Daily-Add's Color row adds a decision to every capture, which goes against "no need for too many buttons."
- It has the most chrome. The coral + competes with the coral Today tab. Seven solid coral day chips are the loudest thing on Daily-Rotation. Rotation itself is hidden behind the reminder chip.
- **Highest build risk:** the masonry Starter grid (needs a custom Layout), the paging hero card, the "up next" shelf and the overlay +.
- **Best widget**, but iOS 26 Clear and Tinted home screens remove widget backgrounds, so the tint is not a lasting identity.

**Nocturne**
- **Right model:** Nocturne-Home is one collection with a rotation icon on each quote in rotation. One status row ("6 quotes in rotation · 3× daily · Next at 8:00 PM") answers "is it working?" and opens the settings.
- **Fewest destinations:** two tabs plus Tab(role: .search), all stock iOS 26. Search also feeds capture (the web row leads to Paste in Add), so putting it under the thumb is justified.
- **Consistent:** every one of the 8 screens has a single amber action.
- **Fix:**
  - Dark-only: bold white text on black blurs for readers with astigmatism.
  - One card per quote won't scale to a large library.
  - Accept sits left of Decline on Nocturne-Friends, the reverse of the iOS order.
  - The black widget disappears on dark wallpapers.
  - The "Search" title sits far from its search field at the bottom.

**MY PICK: Nocturne (its structure).** It is the only direction whose navigation matches what the data is: one library, a rotation flag and a schedule status. It also has the fewest buttons and the least custom SwiftUI.

**GRAFT:**
1. Use Margin's skin as the light appearance (Newsreader for quotes, SF for UI, ink-blue accent) and Nocturne as the dark appearance, following the system setting.
2. Replace Nocturne-Home's cards with Margin's hairline List rows. Keep cards only for shared quotes.
3. Use Daily's big Today card as the screen that opens when someone taps a notification or widget (full-screen quote, share, next), not as a tab.

### The Expansionist

**MARGIN**
- First impression: Welcome is the best-looking of the 24 screens, with the hanging quote mark and Newsreader. But Margin-Home opens on a list, so every daily visit starts in an archive instead of on today's quote. Resurfacing, the thing that makes this an app and not a notes file, sits in the settings-like Rotation tab.
- Usability: it is clean, with one blue action per screen. Share is a small icon repeated on every row (Margin-Home), so it reads as a utility, not a moment, and nothing on screen invites a screenshot.
- Consistency and accessibility: the tightest system of the three. The rotation marker is a ~6pt dot shown only by color. Give it an accessibility label or a shape.
- Margin-Widgets: elegant white pages, but anonymous. Nobody will ask "what app is that?"

**DAILY**
- First impression: correct. The Today card fills 54% of the screen, the quote comes first, and the "1 of 6" dots say there is more. It is the only direction where Starter, Home, Add, Widgets ("Today's card") and the share object are all the same card. One object does the brand, the widget and the share image, which is the growth loop.
- Problems:
  - On Daily-Rotation, the seven solid coral day chips are the loudest thing on the screen. Use a 12% tint.
  - The coral "+" sits next to the coral selected Today tab and competes with it.
  - The hero card's share button is a small corner circle. Make it a labeled "Share card", because sharing is the viral step.
- Gaps: the Library list is never shown, and the up-next shelf truncates to "fearless, and…".
- Effort: low. A tint is one enum on Quote, and the paging ScrollView is stock SwiftUI.

**NOCTURNE**
- First impression: the most striking. Big grotesk on black would make great Story images and StandBy screens. But on Nocturne-Home the eye goes first to the amber "+" and the status card, not to a quote.
- Every card is the same #161619, so nothing feels collectible. The grotesk flattens the rich text: bold "Trust thyself:" barely stands out at 22px.
- The bottom-right search tab (Nocturne-Search) is the best native iOS 26 move in any of the three.
- The 12% amber day chips with amber text look muddy (Nocturne-Rotation). Dark-only also turns away users who prefer light mode.

**MY PICK: Daily**
1. The card is one object that you can share, put on the home screen and collect. That is what people show their friends, and the Today screen turns the app into a daily habit instead of a filing cabinet.
2. The next growth features all extend parts that already exist: Story export, Lock Screen and StandBy widgets, and "send today's card to Maya". Margin and Nocturne would need a new visual object for each of them.

**GRAFT:**
1. Nocturne's search tab (`Tab(role: .search)`) at bottom-right, replacing the floating "+". Move Add to a "+" in the nav bar. This ends the coral clash and puts search under the thumb.
2. Margin's book-style attribution (author in tracked capitals, source in italic) and its margin dot on the cards and share images, for instant literary credibility.
3. Nocturne's dark surfaces as Daily's dark mode, using deep-tinted cards, so the widgets look right in StandBy and on dark wallpapers.

### The Outsider

**MARGIN**
- **First impression:** Welcome shows a quote, which is good. Library is just a list, so it feels like a notes app for quotes. Nothing on Library tells me that quotes come back to me later.
- **Confusing labels:** I'd read the tiny blue dots in the left margin as bullet points. The "• In rotation" key that explains them is small grey text on the far right. The "Rotation" tab uses a two-arrows icon, which to me means "repeat" in a music app, not reminders.
- **Rotation:** all seven day chips are the same pale blue, so I can't tell which days are on and which are off.
- **Friends:** the "Alex @alex" pill at top right looks like another friend. I wouldn't guess it's my own account.
- **What works:** Add is the clearest editor of the three. It has one filled Save button, and the line "Shows up in widgets and reminders" explains the toggle. It's also the easiest to read overall.

**DAILY**
- **First impression:** it passes the 2-second test. Welcome says "Today's card", and Home has a big card plus a "Next reminder 8:00 PM" chip. I get it right away: the app shows me a quote, and another one comes tonight.
- **Add:** the solid coral **B** is the loudest thing on the sheet and looks like the main action, while Save is only coral text. Swap them. The Color swatch row is one more decision that nobody asked for, so pick a color for me by default.
- **Rotation:** seven solid coral day circles are louder than the Reminders toggle and look like alarms. The only way in seems to be the reminder chip (the screen has a back arrow and Today stays highlighted). If reminders are off, how do I find this screen?
- **Home:** the bottom half of the Today card is empty, and the dots and share button float at the bottom. "In Rotation" with a capital R looks like a feature name I'm supposed to already know.

**NOCTURNE**
- **What works:** the Home summary card is the clearest plain-English line in all three sets: "6 quotes in rotation · 3× daily · Next at 8:00 PM". The Welcome line "see them again every day" is also the best description of the app.
- **Confusing icon:** the amber circular arrows next to authors look like "syncing" or "refresh", not "in rotation".
- **Search:** the tab bar shrinks to a single quote-mark circle. I wouldn't know that's how I get back to my quotes.
- **Friends:** shared quotes are buried below the friend list. Save and the day chips are amber on dark brown and look disabled. Accept is on the left of Decline, which is the opposite of the usual order.
- **Widgets:** they're black blocks that disappear on a dark wallpaper. Having only a dark theme is a taste gamble. On Welcome, a password placeholder that says "Required" is odd.

**MY PICK: Daily.** It's the only one where I understand what the app does without reading anything. One quote now and the next reminder at 8 PM is the whole product, and Home shows exactly that. With Margin, I'd think I had downloaded a list to look after. Nocturne needs its summary sentence to explain itself.

**GRAFT:**
1. Replace Daily's bare reminder chip with Nocturne's summary line ("6 quotes · 3× daily · Next at 8:00 PM"), and use Nocturne's tagline "see them again every day" on Welcome.
2. Use Margin's Add hierarchy: one filled Save button, with B/I/U as quiet tints, and Margin's helper text under the toggle.
3. Use Margin's tinted day chips, but show selected days as filled and unselected days as outlines. That fixes both Daily's shouting chips and Margin's ambiguous ones. All three directions use the word "Rotation" without explaining it, so whichever one wins, rename it to something plain like "Your reminders".

### The Executor

**MARGIN**
- First impression and hierarchy: the quote is the loudest thing on every screen (Home, Search, Starter), and each screen has one filled ink-blue action. It looks like a polished book app, not a template.
- Build map: nearly every piece is stock SwiftUI: `NavigationStack` large titles, `.searchable(placement: .navigationBarDrawer(displayMode: .always))`, an inset-grouped `Form` on Rotation, `Toggle`, `Stepper`, compact `DatePicker`, segmented `Picker`, `PasteButton`, `List.onMove`, and "+" as a toolbar button with `.glassProminent`. The only custom font is Newsreader on quote text. The UI stays SF, so the tab bar and nav titles need no appearance overrides.
- Fragile spots: the rotation dot hangs in the margin, which fights List row insets, and VoiceOver can't see it (it needs `.accessibilityLabel("In rotation")`). The label-above-value fields on Welcome and Add are custom. The two-line Alex pill on Friends will fight the glass toolbar's sizing, so make it an avatar button.
- Gaps: all seven day chips use the same tint, so you can't tell which days are on. Only light mode was rendered, so build ground and ink-blue as asset-catalog colors with dark variants from day one.

**DAILY**
- A new user gets it fastest here. The Today card plus the "Next reminder 8:00 PM" chip explain the loop in two seconds, and the widgets look exactly like the app.
- Highest build risk: Figtree replaces SF for all UI, but the iOS 26 tab bar labels and nav titles don't take custom fonts easily. You end up shipping a mix of SF and Figtree, or fighting UIKit appearance.
- The "+" next to the tab pill isn't a stock control. As an overlay it has to track tab-bar minimizing and safe areas. Putting it in the search-role tab slot means intercepting tab selection to show a sheet.
- Starter is a masonry grid. There is no stock layout for that (`LazyVGrid` leaves ragged gaps), so it needs a custom `Layout`. Per-quote tints add a model field, a swatch picker and five dark-mode variants, and iOS 26's tinted and clear widget modes remove them.
- Rotation sits behind the reminder chip as a pushed screen (back button, Today tab still selected). Seven solid coral day chips are the loudest thing on that screen.

**NOCTURNE**
- Most native iOS 26 navigation: `Tab(role: .search)` gives you that bottom-right circle and the bottom search field for free. There are two tabs, and the rotation card is a `NavigationLink`.
- Dark-only means one palette, but `.preferredColorScheme(.dark)` overrides light-mode users, and the widgets become black squares on light wallpapers. That will show in App Store screenshots and reviews.
- The grotesk large titles need appearance overrides. Home cards never truncate, so a 200-quote library at accessibility text sizes becomes a very long scroll.
- Accept sits left of Decline, the opposite of iOS convention.

MY PICK: Margin. It is the only direction where custom work is limited to one font on one text style. Everything else is stock SwiftUI, so it picks up Liquid Glass, Dynamic Type and dark mode without extra work and has the least to break on iOS 26.x point releases. It is the quickest to ship.

GRAFT:
1. Nocturne's `Tab(role: .search)` in place of the search field under the title. It comes free, sits under the thumb, and gives library, shared and web results their own screen.
2. Nocturne's "Every day · Next at 8:00 PM" subtitle under the Reminders toggle, plus Daily's next-reminder line at the top of Library.
3. The label-left Author and Source rows from Nocturne and Daily (`LabeledContent` with a `TextField`) in place of Margin's custom stacked fields.

---

## Peer reviews (Response A = The Expansionist; Response B = The Executor; Response C = The Contrarian; Response D = The Outsider; Response E = The First Principles Thinker)

### Reviewer 1

1. **Strongest: E.** E points out that these are three app structures, and the visual style can be chosen separately. Its plan is one library with a rotation flag and a status row (Nocturne), Margin's look for light mode and Nocturne for dark, and Daily's card shown when a notification is tapped. C ends up at the same plan and has the best checked details: the plain-text Save next to the solid B, missing Save on shared search results, and no detail or edit screens. But C blames Daily for the Seneca notification next to an Emerson widget. Margin-Widgets and Nocturne-Widgets show the same mismatch.

2. **Biggest blind spot: A.** A picks Daily because one card would be the brand, the widget and the image people share. No screen shows a share image. A rates the effort "low" and misses what B, C and E raise: Figtree won't show in the system tab bar, the "+" is a custom overlay, and iOS 26 tinted and clear widgets drop the tints. A praises the "Today's card" widget, which shows a different quote from the notification above it. It also misses Daily-Add, where the solid B is louder than Save.

3. **What all five missed:**
   - None of the 24 screens shows settings, sign-out, account deletion or terms. The App Store requires in-app account deletion (5.1.1(v)) and moderation terms for user-generated content (1.2).
   - iOS allows only 64 pending local notifications. At 3 a day that lasts about 21 days, so "Next at 8:00 PM" needs a "reminders stopped" state.
   - Notifications drop rich text and custom fonts, so the alert looks almost the same in all three directions.

### Reviewer 2

1. **Strongest: E.** It separates structure from skin and names the right model: one library, with rotation as a flag plus a schedule, not a second place. Its grafts add up to a complete, buildable plan: Nocturne's navigation, Margin as light mode, Nocturne as dark mode, hairline list rows, and Daily's card as the screen a notification opens. C reaches almost the same plan and has the best-checked evidence plus the only missing-screens list. E's one slip is faulting Margin's top-right "+" when Nocturne's sits in the same spot.

2. **Biggest blind spot: A.** It picks Daily because one card does the brand, the widget and the share image, and it calls the effort "low." The renders say otherwise. Daily-Widgets labels Emerson "Today's card" while the notification shows Seneca. iOS 26 tinted and clear modes strip the tint. Figtree in system chrome, the overlay "+", the masonry Starter and five tints, each needing dark and widget versions, are not low effort for one person.

3. **What all five missed:**
- **Notification permission.** The loop dies on "Don't Allow." No screen shows when the app asks (after Starter) or what users see once it's denied.
- **Widget and notification out of sync.** All three Widgets renders, not just Daily's, show Seneca in the notification and Emerson in the widget. Notifications and WidgetKit need one shared schedule. iOS also allows only 64 pending local notifications (about 21 days at 3× a day), so the app has to keep rescheduling.
- **The share flow.** No direction draws it: friend picker or system share sheet.

### Reviewer 3

1. **Strongest: C.** It checks its claims against the renders. It estimates the day-chip contrast at about 1.1:1, notes that Rotation can only be reached through the small "Next reminder" chip, and lists the states nobody drew: edit, an empty library, and the keyboard covering Add. It also separates surface flaws that can be fixed from structural ones. E's idea of judging structure first is the best single idea. C and E end up at the same build: Margin's look with Nocturne's navigation. One caveat on C: it blames Daily for the notification showing Seneca while the widget shows Emerson, but all three Widgets renders have that mismatch.

2. **Biggest blind spot: A.** It rates Daily "Effort: low", but the screens show otherwise:
   - Daily-Starter is a masonry grid, which needs a custom Layout.
   - The "+" is a custom overlay.
   - Figtree replaces SF throughout.
   - The per-quote tints need dark-mode and widget versions.

   iOS 26's tinted and clear widget modes also strip those tints. That undercuts A's main argument that one card serves as brand, widget and share image.

3. **What all five missed:**
   - All three Welcome screens make the user enter an email and password before the starter pack. None offers forgot-password, a passkey or Sign in with Apple. Better to let people pick quotes and get a first reminder, then ask for an account when they add a friend.
   - No direction designs the notification permission request or what happens when it is denied, and the core loop depends on it. iOS keeps only 64 pending local notifications, so the "Next at 8:00 PM" line also needs a "paused" state.
   - No direction has a Settings screen, so sign-out and the in-app account deletion the App Store requires (Guideline 5.1.1(v)) have no place.

### Reviewer 4

1. **Strongest: C.** It checks its claims against the renders. On Daily-Widgets the notification shows Seneca while the "Today's card" widget shows Emerson. That shows "Today" doesn't fit a rotation that fires 3× a day, and C is the only response to catch it. C also separates Margin's problems, which are on the surface, from Daily's, which are structural. Its list of missing screens is accurate: no quote detail, edit or delete, no empty state, no keyboard, and no Save on shared search results in either Search render. It has two small errors. Margin's day chips sit on a white card, not a gray one. And Daily's chips are all solid coral with no "off" state either, so grafting them doesn't fix anything.

2. **Biggest blind spot: A.** It rates Daily's effort as "low," but Daily-Starter is a masonry grid that needs a custom Layout. Daily also uses Figtree for UI text the system tab bar won't take, an overlay "+", and per-quote tints that iOS 26's tinted and clear widget modes remove. A's growth-loop case depends on a share image that none of the 24 screens draws; share is only an icon. A also misses the Today/3×-daily mismatch.

3. **What all five missed:** the loop depends on two things the user has to allow in iOS: notification permission and adding the widget. No direction designs the permission ask, what happens after a denial, or a guide to adding the widget. After a denial, Daily's "Next reminder 8:00 PM" chip and Nocturne's summary card would be wrong. Notifications are also plain text in SF, so the surface people see most looks the same in all three directions.

### Reviewer 5

1. **Strongest: C.** I checked its specific claims against the renders and they hold. Daily's solid B is louder than its text-only Save. Rotation is reachable only from the reminder chip. The Library screen is never drawn. Nocturne puts Accept before Decline while the other two put Decline first. Its "missing from all three" list is the only real gap audit: there is no detail/edit/delete screen, no empty library after Skip, the keyboard would cover Add's fields, and shared search results have no Save. It has two errors. The "gray fill" contrast figure is invented, because Margin's day chips sit on a white card. And the Seneca/Emerson mismatch it blames on Daily also appears on Margin-Widgets and Nocturne-Widgets.

2. **Biggest blind spot: A.** It calls Daily's effort "low" and ignores what Daily actually needs:
   - Figtree in system chrome
   - the masonry Starter grid (Daily-Starter)
   - the overlay "+"
   - five tints, each needing dark and tinted/clear widget versions

   Its thesis that one card serves as brand, widget and share image doesn't survive Daily-Widgets, where "Today's card" shows Emerson while the notification shows Seneca. It also claims Margin would need a new visual object for widgets, but Margin's widgets already reuse its list styling.

3. **Missed by all five:**
   - No screen asks for notification permission or handles a denial, and the whole loop depends on notifications.
   - None of the three directions defines which quote is current. The widget timeline and the pre-scheduled notifications need one shared schedule, and iOS allows only 64 pending local notifications.
   - Bold, italic and underline are lost in notifications, which every render shows as plain text.
