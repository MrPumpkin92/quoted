# Quoted: UI spec for implementation (Margin + council grafts)

Source of truth for the SwiftUI build. Visual reference: `design/renders/Main.png` and `design/renders/Margin-*.png` (the Margin direction). Decision and full critique: `docs/decisions/2026-10-18-ui-direction.md`. Where this spec and the mockups disagree, **this spec wins**: it already includes the council's grafts and fixes.

The social redesign (`docs/decisions/2026-10-28-social-redesign-council.md`) adds the Feed, Inbox and Profile tabs, conversations, posts, playlists and provenance. It ships in build steps 1 to 6; "step N" below refers to that build order. Two of its rules changed after the design critique and are marked **record change**: the launch tab and the zero-friend action row.

## Principles
- The quote is the loudest thing on every screen. Each screen has at most one filled accent action, in every state; a disabled `.borderedProminent` still counts. Everything is stock SwiftUI on iOS 26 (Liquid Glass tab bar, large titles, `.searchable` with tokens, sheets, `List`, `Form`, `Toggle`, `Stepper`, `DatePicker`, segmented `Picker`, `PasteButton`, `ShareLink`, `ContentUnavailableView`, `safeAreaBar`, `ToolbarSpacer`).
- Light and dark from day one (asset-catalog colors). Dynamic Type everywhere, with rows truncating with a line limit. The single-quote screens never truncate. VoiceOver labels on every icon-only control. Touch targets ≥ 44pt.
- **Words.** Each word has one job in UI copy.
  - **Post** means the Feed. **Send** means to a friend. **Share** appears only as "Share Image…" and "Share my username", which open the iOS share sheet.
  - **Added by** names who brought a wording into Quoted: "Added by you", "Added by @alice", "Added by a person". Never "Created by", "by @x" or "from @x".
  - **Reminders** is your private list that feeds notifications and widgets. Never "Rotation"; the code keeps the `rotation` naming internally. The glyph is `bell` / `bell.fill`, never the repeat arrows.
  - **Playlist** is its own feature: a titled list of your quotes that you can send to a friend and show on your profile (§19). A playlist never means Reminders, and Reminders is never called a playlist. The glyph is `rectangle.stack`, with no music glyphs. The only bridge is the one-time **Add All to Reminders**.
  - **Quoted Catalog** is the set of checked quotes Quoted ships. Never "public library", and never "starter pack" outside onboarding (§3).
- **Casing.**
  - Title Case: navigation titles, toolbar labels, menu items, swipe actions, dialog and alert buttons, and list rows that act. Examples: "New Post", "Edit Quote", "Choose a Quote", "See All", "New Playlist".
  - Sentence case: `PrimaryButton`, bordered capsules and inline text buttons in content. Examples: "Try again", "Add a quote", "Post a quote", "Save a copy", "Show Quoted Catalog".
  - Legal names are proper nouns everywhere: "Terms of Use", "Community Guidelines", "Privacy Policy".
- **Names and times.**
  - The @username shows wherever credit is meant: provenance, post footers, toasts. The display name shows where the person is the point (Inbox rows, the conversation title, friend rows), always with the @username on a second line or as a subtitle. VoiceOver never speaks the "@".
  - Timestamps: "Just now", "5m" and "2h" within 24 hours (Feed, Search posts); the Inbox list shows the clock time today. Then "Yesterday", then the weekday within 7 days, then "Oct 12", then "Oct 12, 2025". VoiceOver reads full phrases ("2 hours ago"). Conversation separators add the time: "Today 9:41 AM".
- **Buttons and sheets.**
  - Root add buttons (Library +, Playlists +) are `.glassProminent`. They turn quiet `.glass` while an empty state shows its own filled button.
  - Sheet confirmations (Save, Post, Create, Add N) are `.confirmationAction` with a `.borderedProminent` capsule. Sheets that edit have Cancel at `.cancellationAction`. Read-only sheets (Provenance, View As) close with `Button(role: .close)`.
  - A filled action pinned on a tab screen sits in `.safeAreaBar(edge: .bottom)` as a `PrimaryButton` and reports its height for toast clearance (`Toast`). At accessibility sizes it joins the end of the scroll content.
  - List deletes are deferred with a 5-s Undo: rows, posts, conversations, unsend. These ask first with a `confirmationDialog`: a quote from the single-quote screen, a playlist, the account.
  - Saving someone else's quote or a catalog quote puts it in the Library only. It joins Reminders only through the toast's **Add to Reminders**, or through the Reminders picker's Quoted Catalog segment (§8).
- **Glyphs.**
  - Send `paperplane`. Post… `text.quote`. Share Image… `square.and.arrow.up`. New Quote, New Post and New Message use `square.and.pencil`, each in its own tab.
  - Add to Playlist `text.badge.plus`. Playlist `rectangle.stack`. Reminders `bell` / `bell.fill`. Favorite `heart` / `heart.fill`.
  - Report `flag`. Block and Report and Block `hand.raised`. Held `eye.slash`. Unsend `arrow.uturn.backward`. Copy `doc.on.doc`. Delete `trash`.
  - View Profile `person.crop.circle`. Add Friend `person.badge.plus`. Message `bubble.left`.
  - Checked `checkmark.seal.fill` in the accent. Not checked: hollow `seal` in `.secondary`. Never `checkmark.seal` or `person` for provenance.
  - Audience: `lock` (Only me), `person.2` (Friends), `globe` (Anyone with your username, hidden until Public ships).
- **Feedback.** Haptics only through `.sensoryFeedback` with `.success`, `.warning`, `.selection` and `.impact(weight: .light)`. `ToastCenter.show(error:)` already plays the error haptic; never add a second one. Motion is `.snappy` springs and opacity fades; with Reduce Motion every move becomes a fade. No confetti, particles or looping symbol effects.

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
- `QuoteStyle.row`: `.title3`, serif, regular, line limit 4. Feed and conversation cards pass a line limit of 10.
- `QuoteStyle.compact`: `.body`, serif, line limit 6 (Search results).
- `QuoteStyle.excerpt`: `.title3`, serif, one line (Reminders and playlist rows).
- `QuoteStyle.page(_:)`: serif at a system text style, no line limit. `QuoteStyle.hero` is `.page(.largeTitle)`, used on Welcome (dormant, §1) and as the first step on the single quote. `pageSteps` are `.largeTitle`, `.title`, `.title2`, `.title3` and `.body`; `spotlightSteps` put `.spotlight` (about 40 pt) first. `FittedQuote` steps through them (§6).
- `QuoteStyle.editor`: about 26pt, serif, relative to `.title2`.
- `Attribution`: author in `.caption` semibold, uppercase, tracking 1.2, `.secondary`. The source follows in `.caption` serif italic, `.secondary`. A blank author reads "UNKNOWN AUTHOR" (VoiceOver "Unknown author"), except in widgets and notifications.
- **Sizes on a screen.** Content text uses at most 4 sizes and 2 weights (regular, semibold). Quote rows and cards are serif `.title3`. `AttributionLine` and `ProvenanceLine` are `.caption`. `ProvenanceBlock` is `.footnote`. Names are `.body` semibold, with the @username in `.subheadline` or `.footnote` `.secondary`. System bars, the large title, segmented controls, search fields and glyphs don't count.

**Shape and spacing.** Cards are `RoundedRectangle(cornerRadius: 20, style: .continuous)` filled with `Surface` and stroked with a 1px `Hairline`. Primary buttons are capsules, 52pt tall, filled with the accent. Spacing follows the 8-pt grid: 16pt screen gutters, 24pt between groups, 16pt card padding. Use `Theme.Spacing` only (4, 8, 12, 16, 24, 32, 48): 4 or 8 inside a group, 12 between the parts of a card. No shadows, gradients or glows.

## Shared components (`App/Design/Components/`)
- `QuoteText(body:runs:style:)` renders runs through `RichText` to `AttributedString`.
- `AttributionLine(author:source:inReminders:favorite:)` shows a small `bell.fill` before the author when the quote is in reminders, with `accessibilityLabel("In reminders")`, and a small `heart.fill` for a favorite. It no longer draws a seal or takes `verified:`. The seal lives only in `ProvenanceGlyph`, so no surface shows two.
- `QuoteRow(_:inReminders:favorite:provenance:style:highlighting:)`. `provenance: ProvenanceLine.Style? = .row` replaces `verified:`. Pass `nil` where a header already states the seal: the Quoted Catalog promise row (§17), the catalog picker header and the starter picker. Reminders excerpts show no provenance.
- `QuoteCard` is now used only for the share image (§11).
- `FittedQuote(_:steps:quoteMarks:footer:)`: a serif body that never truncates. It steps down until the body and footer fit the proposed height; the last step scrolls (§6).
- `StatusCard`
- `AvatarCircle(name:)` shows initials on a tint picked deterministically from the user ID.
- `PrimaryButton` (one line; at accessibility text sizes the title wraps and the button grows, never truncates)
- `Toast` (one message with an optional Undo). While VoiceOver or Switch Control runs, an Undo toast stays 10× as long (50 s), never closes while VoiceOver is on it, takes VoiceOver focus and is announced as "Quote deleted. Undo available."; double-tap or Magic Tap runs Undo.
  - **Clearance.** The root toast host places a toast 8 pt above whichever is higher: the visible tab bar, or a bottom bar the screen reports. Every bottom `safeAreaBar` (the single-quote controls, the conversation composer and its closed banner, the empty-Feed bar, the profile and playlist bars) reports its height through a `ToastBarHeightKey` preference with `.reportsToastClearance()`. Screens that hide the tab bar report their controls. There are no fixed offsets.
- `EmptyState`
- `SaveToLibraryButton`, the one way to save someone else's quote.
  - Glyph `bookmark`, which becomes `checkmark` with `.contentTransition(.symbolEffect(.replace))`.
  - `.inline` style: borderless, labelled "Save to Library". Used on Feed cards and conversation quote cards.
  - `.capsule` style: bordered, labelled "Save". Used trailing in list rows: Search, Quoted Catalog, friend favorites, a friend's playlist.
  - VoiceOver: always "Save to Library".
  - Once held (same text and author, worked out on the phone with `library.containsCopy`): `Label("In your library", systemImage: "checkmark")` in the replaced control's font, `.secondary`, not a button. A menu item reads "In Your Library", disabled.
  - The save sends a client id, so a retry never doubles it. `.sensoryFeedback(.success)` once the server confirms. Then the save toast (Provenance) with **Add to Reminders**.
- `PostCard(post, variant:)` (§15), `ProfileHeader(profile:)` (§10a), and `Audience`, `AudienceLabel`, `AudiencePicker` and `PlaylistRow` (§19).
- `QuotePickerList(onPick:)`: the one quote picker (§16), used by the post composer, the conversation's attach button and the Inbox empty state.
- The Margin parts (`marginCardRow`, `marginCardList`, `MarginSectionHeader`, `MarginCardMessage`, `SocialPersonLabel`, `MoreMenuLabel`, `capsuleButtonLabel`) and the report and block confirmations move out of the Friends and shared-inbox files into `App/Design/`.
- **Report and block.** One pattern everywhere.
  - Wherever someone else's content or profile appears (posts, messages, playlists, profiles, conversation rows, the provenance sheet), the report items are exactly two: **Report…** (`flag`) and **Report and Block @bob…** (`hand.raised`, destructive). The first reads "Report Post…", "Report Message…", "Report Playlist…" or "Report @bob…". A catalog quote has only **Report Wrong Wording…**.
  - Each item opens one `confirmationDialog`. Reasons: Spam, Harassment, Inappropriate, Copyright, Other. Message: "We review every report within 24 hours. @bob isn't told who reported it." Wrong wording: "We'll check it against the source within 24 hours." There is no "Also block?" follow-up.
  - The item disappears for the reporter at once. Toasts: "Thanks, we'll review it"; Report and Block: "Blocked @bob. Thanks, we'll review it."; wrong wording: "Thanks, we'll check it against the source". `.success` on a report, `.warning` on Report and Block. A failure keeps the screen and toasts `friendlyMessage`.
  - **Block @bob** on its own stays where people are listed: profiles, friend and request rows, conversation rows and the conversation menu. Its confirmation (`BlockCopy.consequences`): "Maya won't be able to find you or message you, and won't see your posts, playlists or profile. Your friendship ends. You keep your conversation, read only, so you can report from it. They aren't told. You can unblock them in Settings." Nothing is deleted.

### Provenance
Every quote says who brought its wording into Quoted and whether Quoted checked it. The server owns the creator; the client only shows it.

- **Model** (QuotedCore, pure, `Provenance.swift`): `Provenance` holds `catalogID` (non-nil means checked), `creatorUsername` and `editedFromUsername`. `who(viewer:perspective:)` returns `.catalog`, `.you`, `.person(username)` or `.unknown`. Perspectives: `.viewer` (the signed-in person), `.friends` (Profile's "How your quotes appear": your own read "@yourname") and `.outsideQuoted` (the share image: your own read "@yourname", everyone else "a person", no "edited from"). `isPublicEligible(viewer:)` is true for a checked quote, or one added by you with no "edited from".
- `QuoteContent` gains `provenance`. Quotes, post and message snapshots, playlist items and friend favorites decode `creator_username` and `edited_from_username`; catalog quotes are `.catalog(id)`. The App Group cache stores them, so the labels work offline. The `provenanceViewer` environment value is set once on `MainTabView` from the session's username.
- `ProvenanceCopy` holds every string below, so `swift test` pins the exact copy.

| Case | Row line | Card line | VoiceOver |
|---|---|---|---|
| Checked | Quoted Catalog | Quoted Catalog · Checked | "Quoted Catalog, checked word for word" |
| Yours | Added by you | Added by you · Not checked | "Added by you, not checked" |
| Someone else | Added by @alice | Added by @alice · Not checked | "Added by alice, not checked" |
| Unknown or deleted | Added by a person | Added by a person · Not checked | "Added by a person, not checked" |

- Row lines never say "Not checked"; the hollow glyph and the VoiceOver words carry it.
- "Edited from @bob", or "Edited from you" when the earlier version was yours. Never on a checked quote.
- Status line, checked: "Checked word for word against <work>, <location>", from the catalog's `source` and `source_location`. When the location already contains the work's title, the location stands alone. With no location: "Checked word for word against <work>". Unchecked: "Not checked against a source".
- `ProvenanceGlyph(checked:)`: the filled accent seal or the hollow `.secondary` seal, sized to its text, hidden from VoiceOver.
- **`ProvenanceLine(_:style:perspective:lineLimit:action:)`.**
  - `.row`: your Library, Search's Your Library group and the pickers. Glyph plus the row line.
  - `.card`: other people's content (Feed posts, conversation quote cards, a friend's playlist, friend favorites, Search's Inbox and Friends' posts groups). Glyph plus the card line.
  - Both are `.caption` `.secondary`, 4 pt under the `AttributionLine`, so the two read as one meta group 8 pt under the quote. Line limit 2, tail truncation; VoiceOver reads it all.
  - With an `action` it is a plain button, the full card width and at least 44 pt tall, that opens the Provenance sheet. Hint: "Shows who added it and how it was checked." Every card uses it.
- **`ProvenanceBlock`** (the single-quote screens, §6 and §6b), in `.footnote`.
  - Line 1 (`.primary`): the glyph, then "Quoted Catalog", "Added by you", "Added by @alice" or "Added by a person", plus " · Edited from @bob" when set.
  - Line 2 (`.secondary`): the status line. It aligns with line 1's text, not the glyph.
  - A trailing `chevron.forward` in `.tertiary`. One plain `Button`, full width, at least 44 pt. No line limit: it wraps, keeps its height and never shrinks.
  - Tap: the Provenance sheet. Long press (and VoiceOver actions): **About This Quote** (`info.circle`), **View @alice's Profile**, **Read It on Project Gutenberg** or **Wikisource** (`book`, checked only, opens `SafariView`), and the report items.
  - VoiceOver: one button, for example "Added by alice, edited from bob, not checked against a source" or "Quoted Catalog, checked word for word against Frankenstein, 1831 edition, Chapter 20".
- **Provenance sheet** (`ProvenanceSheet`, replaces `VerifiedQuoteSheet`; `SheetRoute.provenance`, presented by the shell).
  - Opens from the block, any `ProvenanceLine` with an action and every "About This Quote" menu item. Detents `.medium` and `.large`, drag indicator, inline title "About This Quote", `Button(role: .close)`. A deep link closes it.
  - A `ScrollView` on Ground, 16-pt gutters, 24 pt between groups. The trust answer comes first, then the people, then the actions.
  - **Header** (`.isHeader`): the card line with its glyph in `.headline` ("Added by you · Not checked", "Quoted Catalog · Checked"). Under it, the status in `.body` `.secondary`. Checked: "Quoted checked this quote word for word against a public-domain edition of the work, and its author against the same edition." Unchecked: "Quoted hasn't checked this wording against a source."
  - **Checked: source card.** The work in serif italic, the author, the location (a spinner while it loads), a divider, then **Read it on Project Gutenberg** or **Wikisource** (`book`, at least 44 pt), which opens `SafariView`.
  - **Unchecked: people card.** `LabeledContent` rows "Added by" ("@alice", "You (@hwei)" or "A person") and "Edited from" (only when set). Footnote: yours "Your username stays with this quote when you send or post it."; unknown "Quoted doesn't know which account added it."
  - **Actions card**, hidden when empty: **View @alice's Profile** and, for "edited from", **View @bob's Profile**. Each closes the sheet, then pushes `.profile` on the current tab. Then the report items for the context: a checked quote, Report Wrong Wording…; a post, message or playlist, Report Post… (Message…, Playlist…) and Report and Block @alice…; your Library or a friend favorite with another creator, Report @alice… and Report and Block @alice…; an unknown creator, none.
  - Checked and in your Library: "Change the wording, author or source and the seal comes off."
  - States: offline, the link row and location are left out when not cached. A profile push for a blocked or deleted person lands on "This profile isn't available". A reported post, message or playlist closes the sheet.
- **Copy that travels with a quote.**
  - Save toast (`savedToast`): someone else's unchecked quote, "Saved to your library · Added by @alice"; anything else, "Saved to your library". Always with **Add to Reminders**, which toasts "Added to your reminders".
  - Send footnote (`sendFootnote`): your own, "Your username stays with this quote."; someone else's, "Added by @alice stays with this quote.", plus " Sending also saves it to your library." when Send has to save a copy first (a friend favorite or a playlist item, §11); catalog and unknown, none.
  - Composer footnote: "Your username shows on the post." followed by the send footnote when there is one (§16).
  - Edit note (`editNote`): §7.
- **Never shown** in widgets or notifications: no "Added by" text and no hollow seal (§13, §14). Reminders are private, and your Library must not read as a list of failures.

## App structure
```
RootView (SessionStore.phase)
├─ launching          → Ground with the wordmark (no spinner unless > 1 s), also while the anonymous
│                       account is created; a failure shows the error with Try again
├─ signedOut          → anonymous accounts: the same launch screen, until the new account exists
│                       (AccountMode.emailPassword only: AuthFlow: Welcome/SignIn ⇄ CreateAccount → CheckEmail)
├─ needsUsername      → UsernameView (the first screen on a fresh install)
├─ needsStarter       → StarterPackView → NotificationPrimingView
└─ ready              → MainTabView (iOS 26 TabView, selection: router.selectedTab)
     ├─ Tab "Feed" (text.quote)               NavigationStack(feedPath)    → FeedView
     ├─ Tab "Library" (books.vertical)        NavigationStack(libraryPath) → LibraryView
     ├─ Tab "Inbox" (tray, the only badge)    NavigationStack(inboxPath)   → InboxView
     ├─ Tab "Profile" (person.crop.circle)    NavigationStack(profilePath) → MyProfileView
     └─ Tab(role: .search) "Search"           NavigationStack(searchPath)  → SearchView
Shell: .sheet(item: router.sheet) → SheetHost · .fullScreenCover(item: router.spotlight) → QuoteSpotlightView
       .termsSheet() on the root and inside SheetHost · .toastHost on the root and in each sheet
```

**Tabs.**
| Tab | Glyph | VoiceOver | UI test id |
|---|---|---|---|
| Feed | `text.quote` | "Feed" | `tab.feed` |
| Library | `books.vertical` | "Library" | `tab.library` |
| Inbox | `tray` | "Inbox", with the badge as its value | `tab.inbox` |
| Profile | `person.crop.circle` | "Profile" | `tab.profile` |
| Search | `magnifyingglass` (system, role `.search`) | "Search" | `tab.search` |

- The order is Feed, Library, Inbox, Profile, then the search-role tab, which iOS 26 draws as its own glass circle at the bottom right. The old Friends tab is gone: Friends is pushed from the Inbox (§10).
- Each tab owns one `NavigationStack` bound to its own router path (five stored paths, not a dictionary). Each stack root applies `.routeDestinations()`; feature views never add `navigationDestination`.
- The system picks each symbol's fill variant; never pass `.fill` names. The Profile tab never shows a photo or initials.
- `tabBarMinimizeBehavior` stays `.automatic`, never `.onScrollDown`: a minimized bar hides the Inbox badge, the only signal for new messages. No `tabViewBottomAccessory`, custom overlay or floating button.
- The tab bar hides only on `.quote` (§6) and `.quoteSnapshot` (§6b).
- The search field keeps today's placement rule (`MainTabView.searchFieldOnTabView`): on iOS 26 the `.searchable` sits on the search tab's stack, on iOS 27 on the `TabView`. Both use `.tabViewSearchActivation(.searchTabSelection)`, so selecting the tab focuses the field.
- Re-tapping the selected tab pops it to its root. At the root, a re-tap scrolls to the top. Verify that the iOS 26 `TabView` does this for a `List`; if it doesn't, the root scrolls with `ScrollViewReader`, without animation under Reduce Motion. Re-tapping Search at its root focuses the field.
- Offline, the tabs never change or hide. Each tab shows its own offline state.

**Launch tab (record change).**
- Library, unless the cached Feed's first page has at least one post by someone other than you. Then Feed.
- Decided once per session, before the first frame of `MainTabView`, when `phase` becomes `.ready`: `router.selectLaunchTab(opensOnFeed:)`. The tabs never appear on Library and then jump.
- `AppPreferences.opensOnFeed` (per user ID) is recomputed after each Feed refresh. It never moves the user mid-session; the next cold launch applies it. With no cache (fresh install, `-UITestReset`, a new account after Delete account): Library.
- A cold launch from a notification or widget tap applies the rule first; the spotlight then opens over that tab.

**Cross-tab rule.** Links push onto the current tab's stack: "Add a friend" on the empty Feed pushes Friends onto the Feed stack. Only deep links, the full-screen quote's "Open in Library" and toast actions switch tabs. Tapping your own @username pushes your profile on the current stack, without the gear.

**Routes (pushed).**
| Route | Screen | Pushed from |
|---|---|---|
| `.quote(id:contextIDs:)` | Single quote, yours (§6) | Library, Favorites and playlist rows, Search › Your Library, "How your quotes appear", a Quoted Catalog row you hold, "Open in Library" (§6a, §6b) |
| `.quoteSnapshot(SnapshotRef)` | Someone else's quote (§6b). `SnapshotRef` is `.post`, `.message`, `.catalog`, `.favorite` or `.playlistItem` | Feed cards, conversation quote cards, Search's Inbox, Friends' posts and Quoted Catalog rows, the Quoted Catalog screen, a friend's playlist, favorites and posts |
| `.profile(ProfileRef)` | Your profile without the gear (§10a), or someone else's (§10b). `ProfileRef` is a username plus an optional stub | Any @username: the provenance sheet, post footers, the conversation header, playlist owner lines, friend rows, Search › People |
| `.profileItems(ProfileRef, ProfileItemKind)` | See All posts, playlists or favorites (§10b) | See All on a profile |
| `.friends(FriendsEntry)` | Friends (§10). `FriendsEntry` is `.list`, `.requests` or `.add` | See "Where things open from" |
| `.conversation(ConversationRef)` | Conversation (§21). The ref holds the id, the other person's stub and an optional `highlight` | Inbox rows, New Message, Message on a friend's profile and in Friends, Search › Inbox, the friend-accepted toast |
| `.reminders` | Reminders (§8) | The Library status card, Settings › Reminders, a playlist's empty state, `quoted://rotation` |
| `.favorites` | Favorites (§18) | The Library top section, See All in your profile's Favorites |
| `.playlists` | Playlists (§19) | The Library top section, See All in your profile's Playlists |
| `.playlist(id:)` | A playlist, yours or a friend's (§19) | Playlists, a profile, Search › Your Library, a conversation's playlist card, Open on the "Saved to your playlists" toast |
| `.catalog` | Quoted Catalog (§17) | The Library top section |
| `.settings` | Settings (§12) | The Profile tab root's gear only |
| `.blockedUsers` | Blocked users (§12) | Settings › Privacy, the last row of Friends |
| `.textPage(LegalPage)` | `TextPageView` | Settings › About, the Terms sheet |

Removed: `.sharedInbox` ("Shared with you" is retired), `.account` and `.profile(Profile)`.

**Sheets.**
| SheetRoute | Screen | Presented from |
|---|---|---|
| `.addQuote`, `.pastedQuote(String)`, `.editQuote(Quote)` | Add / Edit (§7) | Library "+", the composer's New Quote, Search's copied-quote card, Edit, "Add a quote" on your profile |
| `.composePost(PostSeed?)` | Post composer (§16) | New Post, "Post a quote", every bordered Post and Post… item |
| `.send(SendItem)` | Send sheet (§11). `SendItem` is `.quote(UUID)`, `.catalog(Int)`, `.snapshot(SnapshotRef)` or `.playlist(UUID)` | Every Send |
| `.newMessage` | New Message (§20) | The Inbox toolbar |
| `.provenance(ProvenanceRef)` | Provenance sheet (Shared components) | The provenance block, a card's provenance line, About This Quote |
| `.addToPlaylist(quoteID: UUID)` | Add to Playlist (§19), your own quotes only | The single quote's `…`, Library, Favorites and Search context menus |
| `.newPlaylist(adding: UUID?)` | New Playlist (§19) | Playlists `+`, your profile, the playlist empty states, Add to Playlist |
| `.playlistQuotePicker(UUID)` | Add Quotes (§19) | Your playlist's bottom bar |
| `.profilePreview(Audience)` | View As (§10a) | Your profile's toolbar |
| `.catalogPicker(joinsReminders:)` (was `.starterPack`) | The Quoted Catalog picker (§5) | Library "+" (`false`). The Reminders picker's Quoted Catalog segment reuses its list with `true` (§8) |
| `.widgetGuide`, `.reminderPicker`, `.safari(URL)` | As before | As before |

- Removed: `.share(Quote)`. Its two halves are now `.send` and the **Share Image…** `ShareLink`, which needs no route.
- Terms are never a route. The `.termsSheet()` modifier, driven by `SocialStore.requireTerms(for:then:)`, stacks over whatever asked, including a sheet (§22).
- The provenance sheet moves from a local `.sheet` in `QuoteDetailView` to the shell, so a link tapped under it is no longer lost.
- Sheets that may hold typed text or a selection hold a deep link until they close: Add / Edit, the post composer, Send, New Message, Add to Playlist, New Playlist, Add Quotes, the catalog and Reminders pickers, the display-name sheet and the Terms sheet. A link closes the Provenance sheet, the widget guide and Safari.

**Deep links** (`quoted://`):
- `quote/<id>` (from a notification tap or a widget) shows that quote full screen (§6a), over whatever is on screen.
- `rotation` closes the spotlight, selects Library and pushes `RemindersView`.
- `inbox` (new) closes the spotlight, selects Inbox and pops it to its root, with the same holding rules as `rotation`. `NotificationDelegate` maps a tap on an old inbox alert (thread `inbox`, or an identifier starting `inbox-`, posted by earlier builds) to it.
- `auth-callback` completes email confirmation (email accounts only).
- No links for profiles, posts, conversations or the catalog. There is no push to carry them, and Universal Links are out of scope.

**Badges.**
- The Inbox tab only: unread conversations plus pending incoming friend requests. A conversation counts once, however many messages are unread. Zero hides it; above 99 it shows "99+". VoiceOver value: "2 unread conversations, 1 friend request". Feed, Library, Profile, Search and toolbar buttons never show a badge.
- It updates when the Inbox appears, on return to the foreground, on pull to refresh in Inbox or Friends, on each 10-s poll in an open conversation, and after your own accept, decline or read. There is no push and no Realtime, so a friend's message doesn't change the badge on another tab until one of those moments.
- Opening a conversation drops it from the count at once. A request leaves the count on Accept or Decline. No haptic, sound or toast when the badge changes.
- The app icon is never badged. Call `setBadgeCount(0)` when `phase` becomes `.ready`, on every return to the foreground and at sign-out. Background refresh stops posting inbox alerts and stops refreshing social data; it keeps reminders and the widget. On the first launch of this build, remove delivered notifications in the `inbox` thread. Notification permission no longer asks for `.badge`.

**Where things open from.**
- **Friends:** the Inbox toolbar's `person.2` (leading, VoiceOver "Friends", id `inbox.friends`) pushes `.friends(.list)`. The Inbox requests row pushes `.friends(.requests)`. "Add a friend" on the empty Feed, the empty Inbox, New Message and the Send sheet with no friends pushes `.friends(.add)` on the current stack with the username field focused; a sheet closes first.
- **Settings:** only the Profile tab root's `gearshape` (trailing, VoiceOver "Settings", id `profile.settings`). View As (`eye`) sits beside it.
- **Reminders:** the Library status card and Settings › Reminders, each onto its own stack.
- **Blocked users:** Settings › Privacy and the last row of Friends. A profile you blocked shows Unblock in place.
- **Legal and support:** Settings › About. The Terms sheet opens its pages inside the sheet.

**Moments the shell owns.**
- **A friend accepted.** After every accept, wherever it happens (Friends, a profile, the Inbox requests row), toast "You and @sam are now friends" with **Send a Quote**. It pushes their conversation on the current stack with the quote picker open. `.success` plays only when the user tapped Accept; an acceptance found by a refresh shows the same toast silently. Nothing else: no dialog and no tab switch.
- **Posted from outside the Feed.** Toast "Posted to Feed" with **View**, which selects Feed scrolled to the top (§16).
- **First quote received.** The Inbox badge only. No toast, haptic or banner.
- **Saving someone else's quote.** `SaveToLibraryButton`, wherever Save appears.

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

### 5. Library (tab)
- Large title "Library". A filled `+` (`.glassProminent`) in the toolbar opens a menu (VoiceOver hint "Write a new quote or add some from the Quoted Catalog"):
  - **New Quote** (`square.and.pencil`) opens Add.
  - **From the Quoted Catalog** (`checkmark.seal.fill`) presents `.catalogPicker(joinsReminders: false)`, the starter picker renamed. Title "Quoted Catalog". Its header is the filled seal with "Every quote here was checked word for word against a public-domain edition."; the rows pass `provenance: nil`. It keeps multi-select, quotes you already have dimmed, and **Add N quotes**. Picks go to the library only, with the toast "Added 3 quotes to your library" and **Add to Reminders**.
- **StatusCard** (shown when at least one quote is in reminders) pushes Reminders. It has a bell tile in a soft accent square and reads:
  - Normal: "**6 quotes in your reminders**" / "3× daily · Next at 8:00 PM".
  - Off states: "Reminders off · Turn on", or "Notifications off in Settings · Turn on", which opens `UIApplication.openNotificationSettingsURLString`.
- **Widget tip** (one-time and dismissible): "Put a quote on your Home Screen" opens `WidgetGuideView` (three numbered steps). It waits until the StatusCard has been seen on 3 launches, so at most one card sits above the top section. Hide it permanently after dismissal, or when `WidgetCenter.shared.currentConfigurations()` reports a Quoted widget.
- **Top section**, after the cards and before the count header: one Margin card of three stock `NavigationLink` rows, each at least 44 pt, with disclosure chevrons. Each row is `LabeledContent { count } label: { Label(…) }` in `.body` with an accent glyph; the count is `.secondary` and shows only above 0.
  1. **Favorites** (`heart.fill`, the count) pushes `.favorites` (§18).
  2. **Playlists** (`rectangle.stack`, the count) pushes `.playlists` (§19).
  3. **Quoted Catalog** (`checkmark.seal.fill`, no count) pushes `.catalog` (§17).
  - VoiceOver: "Favorites, 12", "Playlists, 3", "Quoted Catalog". Hidden in the empty and load-failed states. At accessibility sizes the count goes under the label.
  - Check on an iPhone SE simulator that a quote row shows above the tab bar at the default text size.
- A count header ("8 quotes"), then the `QuoteRow` list:
  - Rows have no per-row buttons (council fix). The attribution line starts with a small accent bell for quotes in reminders and a small accent heart for favorites. A third line, 4 pt below, is the row provenance line: "Added by you", "Added by @alice", "Added by a person" or "Quoted Catalog". VoiceOver: "<quote>. In reminders. Favorite. Mary Shelley, Frankenstein. Added by you, not checked."
  - Tapping a row opens the single quote (§6), paging across the list as shown.
  - Leading swipe: **Send** (`paperplane`, accent; `.send(.quote(id))`) and Favorite / Remove from Favorites (pink fill). Trailing swipe: Delete (destructive) and Reminders (add or remove).
  - The context menu, in groups: **Send…**, **Post…** (`text.quote`, `.composePost(.quote(id))`), **Share Image…**; then Add to / Remove from Reminders, Favorite / Remove from Favorites, **Add to Playlist…** (`text.badge.plus`); then Edit; then Delete.
- Removed: the "N shared with you" row (what friends send lives in the Inbox) and the All / Favorites control (the Favorites row replaces it).
- Pull to refresh.
- **Empty state:** "Your library is empty" with a filled **Add your first quote** button and a quiet "Pick from the Quoted Catalog" link (presents `.catalogPicker`). The StatusCard and top section stay hidden. The toolbar `+` turns quiet (glass with an accent glyph) while the empty or load-failed state shows, so the screen keeps one filled action.
- Type: `.title3` serif; `.body` (top rows, status title); `.subheadline` (status line, count header); `.caption` (attribution and provenance).

### 6. Single quote, yours (`QuoteDetailView`, route `.quote(id:contextIDs:)`)
- A quote in your library. It pages across the list it was opened from (`TabView` `.page` style, no index dots): the Library order, favorites, a playlist's order, or the reminder order from a deep link.
- **Chrome.** The tab bar is hidden (`.toolbarVisibility(.hidden, for: .tabBar)`); the controls take the thumb zone where it sat. Back brings it back with the stock animation. The inline title is the counter, "2 of 8" in monospaced digits, or "Quote" for a one-quote list. No `navigationSubtitle`.
- **Toolbar** (all `.topBarTrailing`): `FavoriteButton` (`heart` / `heart.fill`; VoiceOver "Favorite", Selected while on), `ToolbarSpacer(.fixed)`, the text button **Edit**, and a `…` menu (VoiceOver "More"):
  - **Share Image…**: a `ShareLink` with the §11 image and `SharePreview("Quote card", image:)`.
  - **Add to Playlist…** presents `.addToPlaylist(quoteID:)`.
  - A divider, then **Delete** (`trash`, destructive), behind the confirmation "Delete this quote?" / "It leaves your library, your reminders and the widget." with **Delete Quote** and Cancel.
  - Nothing in the toolbar is filled.
- **Layout** on Ground, with no card. A page column inset 24 pt from both edges, 8 pt below the bar, centred vertically when shorter:
  - `FittedQuote` with `pageSteps` and hanging marks. The “ sits in the margin, so the quote's optical edge lines up with the controls' 16-pt gutter.
  - 12 pt, then `AttributionLine(author:source:)` without the bell and heart (the toggle and toolbar show them). It wraps.
  - 12 pt, a `HairlineDivider`, 8 pt, the `ProvenanceBlock` (context `.library`), then 8 pt to the controls.
- **Controls**, pinned with `.safeAreaBar(edge: .bottom)` (16-pt gutter) so a scrolling page fades under them. They report their height for toast clearance.
  - An **In reminders** `Toggle` with `Label("In reminders", systemImage: bell or bell.fill)`, at least 44 pt. No visible caption; "Shows up in widgets and reminders" is the VoiceOver hint.
  - 8 pt, then the action row, 52 pt: two equal buttons, 12 apart, text only.
    - Leading: **Post**, a bordered capsule in the accent, `.headline`. It opens the composer with this quote (§16).
    - Trailing: **Send**, a `PrimaryButton`. It opens the Send sheet (§11). **The one filled action.**
  - **No friends yet (record change).** While `friends.count == 0`, the action row is one full-width filled **Share Image…** (a `ShareLink` with `PrimaryButtonStyle` and the §11 image). Post and Send are hidden; they come back with the first accepted friend.
  - Bottom margin: 8 pt above the home indicator; on Home-button iPhones `max(16 - safeAreaBottom, 8)`.
- **Shrink to fit.** Only the body changes size; the attribution, block, controls and spacing stay fixed.

| Step | `QuoteStyle` | Default size | Line spacing |
|---|---|---|---|
| 1 | `.page(.largeTitle)` | 34 | 4 |
| 2 | `.page(.title)` | 28 | 4 |
| 3 | `.page(.title2)` | 22 | 4 |
| 4 | `.page(.title3)` | 20 | 2 |
| 5, the floor | `.page(.body)` | 17 | 2 |
| then | step 5 in a `ScrollView` | | |

  - Each step is a system text style, so it scales with Dynamic Type, and the floor is always the person's `.body` size.
  - `FittedQuote` is `ViewThatFits(in: .vertical)` over the steps, then the last step in a `ScrollView` with `.scrollBounceBehavior(.basedOnSize)` and `.scrollIndicatorsFlash(onAppear: true)`. The pager proposes the page height; never put it inside an outer `ScrollView`. Text never truncates.
  - At the default size a 604-character quote fits without scrolling on an iPhone SE (step 5, 14 pt spare) and an iPhone 17 Pro (step 4). Rough capacity before scrolling: about 630 characters on an SE, 965 on a 17 or 17 Pro, 1,155 on a Pro Max. A 2,000-character quote always scrolls.
  - If simulator line breaking loses the SE fit, trim the column's bottom inset from 8 to 4, then the divider-to-block gap from 8 to 4. Type and controls stay.
  - At accessibility sizes the controls join the column and scroll with it. The action row stacks full width: Send first, then Post.
- **Gestures.** A horizontal swipe pages. A long press on the body shows no menu; the `…` holds the actions. A long press on the block shows its context menu.
- **States.**
  - Loading (a cold deep link before the library loads): `DelayedProgressView("Loading quote")`.
  - Quote gone: the pager moves to a neighbour or pops, with "This quote is no longer in your library." unless an Undo toast is up.
  - Offline: everything reads from the cache, provenance included. The toggle fails back with "You're offline. Try again when connected." Send and Post open their sheets, which handle offline. A checked quote whose catalog row isn't cached shows "Checked word for word against <work>".
  - A failed toggle write reverts the switch and toasts `friendlyMessage`.
  - A catalog location that arrives after first layout updates the status line without animation, and the step is chosen again.
  - Light and dark: the filled Send uses `onAccent` text. Check the bordered Post's accent text for AA contrast in dark mode.
- **VoiceOver**, in order: Back; the title "2 of 8"; Favorite, Edit, More; the quote as one element ("<quote>, <author>, <source>"), with the value "2 of 8" when paging, adjustable ("Swipe up or down to change quotes.") and the actions Next quote / Previous quote; the block; In reminders; Post (hint "Posts it to your friends' Feed"); Send (hint "Sends it to a friend").
- **Motion.** The bell swaps with a symbol replace, with only the switch's own haptic. After an edit takes the seal off, the block's glyph swaps and its text cross-fades. Steps never animate.
- Type: four sizes (the body step, 17 for the buttons and toggle, 13 for the block, 12 for the attribution) and two weights.

### 6a. Full-screen quote (a reminder or widget tap; graft from Daily)
- The council's call: Daily's big card is the screen a notification or widget opens. `QuoteSpotlightView` in a `fullScreenCover` over the tabs (no tab bar), Ground background.
- The quote alone, centred: `FittedQuote` with `spotlightSteps` (serif `.spotlight`, about 40 pt scaled with Dynamic Type, then the page steps; this replaces the switch to `.hero` over 280 characters), hanging quotation marks, the attribution line (bell when in reminders), then the row provenance line. Long quotes and large text sizes scroll.
- Pinned at the bottom: a primary **Send** (the Send sheet opens over the cover) and a quiet **Open in Library**, which closes the cover and shows the quote's single-quote screen (§6), paging across the reminder quotes. With no friends yet, the primary is **Share Image…** instead (record change, §6).
- The system close button (`Button(role: .close)`) top left; VoiceOver escape closes it too. The favorite heart top right, as on the single quote.
- At accessibility text sizes the quote uses `.hero` and the buttons scroll with it instead of staying pinned.
- Before the library has loaded (a cold launch from a tap), or while a refresh may still bring the quote in: a delayed spinner. If the library can't load: the error with Try again and Close. A quote that is no longer in the library: "This quote is gone" with Close.
- A newer tap replaces the quote shown. A tap while a sheet that may hold typed text is open (Send, the display-name sheet) waits until it closes. Toasts sit above the pinned buttons.

### 6b. Someone else's quote (`QuoteSnapshotView`, route `.quoteSnapshot(SnapshotRef)`)
- A read-only quote you don't own. `SnapshotRef` is `.post(id)`, `.message(id)`, `.catalog(id)`, `.favorite(friendID:handle:)` or `.playlistItem(playlistID:handle:)`, matching the server's `save_from_*` functions. Feed and conversation cards stop at 10 lines; this is where the rest is read.
- **Chrome and layout:** as §6, with the tab bar hidden. `FittedQuote` with `pageSteps`, then `AttributionLine`, a divider and the `ProvenanceBlock`. The block's context is the snapshot's own (post, message, playlist, friend favorite or catalog), so Report targets the item.
- **Title:** "Quote", or "2 of 12" when opened from a friend's playlist, which pages in the owner's order. No other entry point pages.
- **Context line:** one `.footnote` `.secondary` line under the block, a 44-pt plain button that pushes the person's profile: a post "@bob · 2h", a message "@maya · Monday", a playlist "@maya's playlist · Courage", a favorite "@maya's favorites", the catalog none. The caption or note isn't repeated; the card already showed it in full.
- No heart, Edit or Reminders toggle: the quote isn't yours.
- **Toolbar:** one `…` menu with **Share Image…**; **Post…** (catalog only: to repost a friend's quote, save it and post from Library); **View @bob's Profile**; **Report Post…**, **Report Message…** or **Report Playlist…** (catalog: **Report Wrong Wording…**); **Report and Block @bob…** (not on the catalog).
- **Controls:** a 52-pt action row in `.safeAreaBar`, as §6, reporting its height.
  - Not in your library: bordered **Send**, filled **Save to Library** (`SaveToLibraryButton`).
  - In your library: bordered **Open in Library**, which pushes `.quote(id:)` for your copy, and filled **Send**.
  - No friends yet (catalog only, since the other snapshots come from friends): **Share Image…** takes Send's place.
  - Add to Playlist isn't offered here. It comes after Save, through Open in Library.
- **States.**
  - Loading by id: `DelayedProgressView("Loading quote")`.
  - Gone (deleted, unsent, removed, reported, blocked or unfriended): `ContentUnavailableView("This quote isn't available", systemImage: "text.quote")`, with Back only.
  - Offline: the cached snapshot. Writes show the offline toast.
- **VoiceOver:** the quote (adjustable only when paging), the block, the context line ("Posted by bob, 2 hours ago"), Send, Save to Library.
- **Fit:** §6's budget minus the toggle row (−52 pt) plus the context line (+26 pt), so it fits wherever §6 fits.

### 7. Add / Edit quote (`Margin-Add.png`)
- A sheet with a grabber, Cancel, the title "New Quote" or "Edit Quote", and a filled **Save** capsule (disabled until the body is valid).
- Use a `ScrollView` with `.scrollDismissesKeyboard(.interactively)`.
  - **Editor card:** a `RichTextEditor` (a UITextView representable, serif, about 26pt, placeholder "Type or paste a quote"). While empty, the card shows a `PasteButton`.
  - **Edit note** (editing only): directly under the editor card, above Author and Source, in `.footnote` `.secondary` with a 4-pt inset (`ProvenanceCopy.editNote`). It shows from the moment the sheet opens. An inline error sits above it.
    - Another person's quote: "Changing the words makes this your version. @alice stays as edited from."
    - An unknown creator: "Changing the words makes this your version."
    - A checked quote: "Changing the words makes this your version, and the seal comes off."
    - Your own quote, with or without "edited from": no note.
  - **Card 2:** label-left `LabeledContent` rows for Author and Source (optional).
  - **Card 3:** an "Include in reminders" toggle, on by default, with the caption "Shows up in widgets and reminders".
- **Keyboard toolbar:** B, I and U toggle buttons with the selected state in `AccentSoft`. They reflect the selection's current flags and toggle runs through `RichText.toggle`. Then a `Spacer`, then a `PasteButton`. Return in the editor inserts a newline. The Author field submits to Source, and Source submits to Save.
- **Paste heuristics:** text like `“…” — Name` or `"…" - Name, Work` is split into body, author and source. Smart quotes around the body are stripped. `QuotedCore.PastedQuote`, linear in the pasted length, so pasting a long page doesn't stall the sheet.
- Validation errors appear inline. If saving fails, keep the sheet open and show a toast.
- A new quote closes with the toast "Saved to your library", or "Saved to your library and reminders" when it joined them. Library scrolls to the quote, so it's visible even if the list was scrolled down.
- An edit that moves the creator to you (the server row comes back with you as the creator) toasts "Saved as your version" with `.sensoryFeedback(.success)`. A formatting-only edit (bold, italic, underline) changes nothing and shows no toast.
- Opened from the Search tab's copied-quote card (`SheetRoute.pastedQuote`), the sheet starts filled from the pasted text, using the same split as Paste.
- Opened from the post composer's **New Quote** (§16), Save works as above, then the composer picks the new quote.

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
- An "Add quotes" button opens `ReminderQuotePicker`: a segmented **Library** | **Quoted Catalog** picker over a multi-select. Library lists the library quotes that aren't in reminders. Quoted Catalog reuses the catalog picker's list with `joinsReminders: true`: its picks join your library and your reminders. The toolbar **Add N** is the one filled control.
  - The button is never disabled.
  - When the library is empty or every library quote is already in reminders (where onboarding leaves everyone), the picker opens on Quoted Catalog. The Library segment then ends with the footer line "Every quote is in your reminders." and a quiet **Write your own**.
- Every change re-plans notifications and updates the widget snapshot right away.

### 9. Search (`Tab(role: .search)`, bottom right)
One field, with grouped results across everything you can already reach. Search has no filled action; the copied-quote card's system `PasteButton` is the one exception iOS may draw filled.

- **Field.** `.searchable(text:tokens:suggestedTokens:isPresented:prompt:)` bound to the router, prompt **Quotes, authors, @username**. `.onSubmit(of: .search)` records the text and token in Recent. `.scrollDismissesKeyboard(.immediately)`.
- **Tokens** (`SearchToken` in QuotedCore, drawn as native capsules in the field). At most one; choosing one replaces the other.

| Token | Label | Glyph | VoiceOver | Filters |
|---|---|---|---|---|
| `.checked` | Checked | `checkmark.seal.fill` | "Checked quotes only" | Checked quotes only. Hides People and playlists. |
| `.addedByPeople` | Added by people | `seal` | "Quotes added by people" | Unchecked quotes, "Added by a person" included. Hides Quoted Catalog, People and playlists. |
| `.addedBy(username)` | Added by @maya, or Added by you | `seal` | "Quotes added by maya", "Quotes you added" | Quotes whose creator is that person, wherever they sit. Hides Quoted Catalog, People and playlists. |

  - Add one with the start screen's **Show only** buttons, or while the text starts with "@": `suggestedTokens` then holds up to 3 `.addedBy` tokens for you and accepted friends whose username starts with the typed letters, matched on the phone. Strangers are never suggested and no server call is made, so nobody can list usernames. Choosing one inserts it and clears the text. A recent search restores its token.
  - For an exact friend match, the suggestions also offer "View @maya's profile", which pushes `.profile`.
  - A token alone is a valid search. "Checked" alone lists your checked quotes, checked Inbox quotes, checked friends' posts and the whole Quoted Catalog.
  - Remove a token with backspace, or with **Show all quotes** in the no-match state.
  - Verify on device how iOS 26 draws `suggestedTokens` in a search-role tab. They should cover the results only while the text starts with "@", never the start screen.
- **Empty field** (no text, no token), top to bottom, 16-pt gutters, 24 pt between groups:
  1. **Copied-quote card:** when the in-app browser closes and the pasteboard changed while it was open (`changeCount` and `hasStrings`, which show no paste prompt), a card at the top reads "Add the quote you copied".
     - It has the system `PasteButton` and "Not now".
     - Paste opens Add filled from the copied text (`SheetRoute.pastedQuote`).
     - The card scrolls into view when it appears, and VoiceOver announces it.
     - It goes away once something else is copied (checked on return to the app and to the tab).
  2. **Recent:** the last 5 searches (text plus token), stored locally and cleared at sign-out. Rows: `clock.arrow.circlepath`, the text in `.body`, the token after it in `.subheadline` `.secondary` ("courage · Checked"), and × to remove, with **Clear** in the header. Hidden when empty.
  3. **Show only:** two bordered capsule buttons, neutral tint, at least 44 pt: **Checked** (accent filled seal) and **Added by people** (`seal`). Each inserts its token, keeps the field focused and plays `.selection`. They wrap at accessibility sizes.
  4. **Try searching for:** the chips courage, time, kindness, love and hope in AccentSoft capsules, `.body` regular. Each returns Quoted Catalog results, so a new user's first search finds checked quotes.
  - No `ContentUnavailableView`: the screen is already a guide.
- **With text or a token:** a stock plain `List` on Ground, so rows get native swipes and context menus and VoiceOver gets headings. A section shows only when it has rows, or while a server group loads, fails or is offline. The order never changes:
  1. **Your Library** (on the phone). The header shows the count trailing. Playlists whose title matches come first: up to 3 `rectangle.stack` rows with the title and "12 quotes", pushing `.playlist(id:)`. Then `QuoteRow`s with the row provenance line; a tap pushes `.quote(id:contextIDs:)`, paging across the matches. Swipes and context menu are exactly a Library row's. Shows 5, then a **Show All 23** row that expands in place; a new query collapses it.
  2. **Inbox** (on the phone: the loaded messages). Each row starts with a from-line: a 24-pt avatar, the name in `.subheadline` semibold and " · Yesterday" in `.secondary`. Quote messages: `QuoteText(.compact)`, the `AttributionLine`, the card provenance line and a trailing `SaveToLibraryButton(.capsule)`. Text messages: 3 lines. Playlist messages: the title. A tap pushes `.conversation` with `highlight` set to that message. Leading swipe: Save. Context menu: Save to Library (quote messages), Send…, Open Conversation, and on theirs Report Message… and Report and Block @maya…. Shows 3, then **Show All**.
  3. **Friends' posts** (server: only posts already in your Feed, your own included, at most 20). In Feed card order: the quote (`.compact`), the attribution, the card provenance line, then "@bob · 2h" and the caption (2 lines) in `.subheadline`. The poster never sits above the quote. A tap pushes `.quoteSnapshot(.post(id))`. Leading swipe: Save. Context menu: Save to Library, Send…, View @bob's Profile, and on others' posts Report Post… and Report and Block @bob…. No reactions or counts. Shows 3, then **Show All**.
  4. **Quoted Catalog** (the cached catalog). `QuoteRow` with the "Quoted Catalog" line and a trailing `SaveToLibraryButton(.capsule)`. A catalog quote you hold appears only in Your Library; other groups may repeat a quote, since each carries its own context. A tap pushes `.quoteSnapshot(.catalog(id))`. Leading swipe: Save. Context menu: Save to Library, Send…, Post…. Shows 3, then **Show All**; expanded it caps at 50, with the footer "Showing 50. Add a word to narrow it."
  5. **People** (exact username only, at most one). It looks up only when the text is "@" plus a valid username (`findProfile`), never on plain words or partial names. Row: a 40-pt avatar, the display name in `.body` semibold, "@maya" in `.subheadline` `.secondary`, and the relationship trailing: Friend, Requested, Wants to be friends, You or Blocked. A stranger's row has a trailing bordered **Add** instead, the same action as Friends' Add field with the Terms gate first; it then reads Requested. A tap pushes `.profile`. No such user, or one who blocked you: "No user named @xyz".
  6. **Search the web**, always last: a globe icon, then "Search the web for “courage” quotes" (in the accent), the caption "Opens Google. Copy a quote, then come back here to add it.", and `arrow.up.right`. It opens `SearchIndex.googleURL` in the in-app browser (`SafariView` through `router.present(.safari(url))`; see docs/decisions/2026-10-19-web-search-browser.md) and logs `web_search_tap`. Shown whenever there is text, with or without a token. Hidden for a token alone and when the text starts with "@".
- **Highlights:** matched words show in AccentSoft and semibold, so a match never relies on color alone.
- **Type and spacing:** `.title3` (serif rows, the web row title), `.body`, `.subheadline` and `.caption`, regular and semibold. 4 pt from the attribution to the provenance line; 8 pt from a from-line to its quote and from a header to its first row; 16 pt of padding per row with a Hairline between rows; 24 pt between groups.
- **States.**
  - Cold start before the library loads: `DelayedProgressView("Searching")`. Local groups fill in as soon as the cache loads.
  - Typing: local groups update on every keystroke with no animation. Server groups wait for a 300-ms pause and at least 2 characters, and a new keystroke cancels the request in flight. While one loads, its header shows with "Searching friends' posts…" where its rows will go, so the Quoted Catalog below barely moves.
  - No matches: "No matches" (`.body` semibold) and "Try fewer words, or find it on the web." (`.subheadline` `.secondary`), then the web row. VoiceOver hears "No matches" after a 1-s pause.
  - No matches with a token: "No matches", then "No checked quotes have “courage”." (or "No quotes added by people…", "No quotes added by @maya…", "No quotes you added…"), a plain **Show all quotes** that removes the token, then the web row.
  - Offline: local groups work. One line replaces Friends' posts and People: "You're offline. Friends' posts and people need a connection." The web row stays.
  - Server error: "Couldn't search friends' posts." with a plain **Try again** inside that group. The other groups are untouched.
  - Blocked and reported content never shows.
  - Line limits: quote rows 4 (`.row`) or 6 (`.compact`), text messages 3, captions 2, names 1 (2 at accessibility sizes), playlist titles 2. Search never shows a full quote; a tap opens the screen that does.
  - Accessibility sizes: avatars hide, Save moves under the from-line, the Show only buttons stack and the chips wrap.
- **VoiceOver.** Each header is a heading with its count ("Your Library, 12 results"). A row reads the quote, the attribution, the provenance, then its context ("Posted by bob, 2 hours ago"); Inbox rows start with "From Maya, yesterday". People: "Maya Lee, @maya, friend", hint "Opens their profile". "Show All 23 in Your Library". "Searching friends' posts".
- **Motion.** No animation while typing. Server groups fade in (0.2 s). Show All expands with `.snappy`. Reduce Motion keeps only the fade.

### 10. Friends (`.friends(FriendsEntry)`, pushed)
- No longer a tab. Pushed on any stack (see "Where things open from"). `.requests` scrolls to Requests; `.add` focuses the username field.
- Inline title "Friends". A `List` with `.marginCardList()` and `.refreshable`.
- **Add a friend** (a section header), then one card: `@` plus `TextField("username")` (VoiceOver "Add by username") with live `Username.validate`, and a trailing `.borderedProminent` capsule **Add** (VoiceOver "Add friend"; Voice Control also answers to "Add"), disabled until the username is valid. **The screen's one filled action.**
  - Under the card: "Your username is @alex." (`.footnote` `.secondary`; a long press offers Copy Username) and a borderless `ShareLink` "Share my username" (`square.and.arrow.up`, `UsernameInvite.text`). Add the App Store link once it exists.
  - Toasts: "Request sent to @maya", "No user named @x", "You're already friends with @maya", "@maya already asked you. Accept below." (also scrolls to Requests), and "Quoted keeps circles to 150 friends." (QR002).
- **Requests**, shown only when there are any:
  - Incoming: name, @handle, a bordered **Decline** and a bordered **Accept** in the accent tint. Accept is not filled: Add holds this screen's filled action. From the tap until the server answers (the terms check included), Accept shows a spinner and ignores taps, and Decline is off.
  - Outgoing: "Requested" with **Cancel**.
  - At the default text size the buttons stay beside the person; a long name wraps to two lines instead. They move under the name only at larger sizes.
  - The `…` menu and context menu (and VoiceOver actions): Decline (incoming), Report @x…, Report and Block @x…, Block @x.
- **Friends:** the header shows the count ("12 friends"). Rows: `SocialPersonLabel` with a chevron; a tap pushes `.profile` (§10b). Leading swipe: **Message** (`bubble.left`, accent) pushes the conversation. Trailing swipes: Remove, Block, Report. Context menu: Message, View Profile, Divider, Remove…, Report @x…, Report and Block @x…, Block @x. From 140 friends, a footer: "Quoted keeps circles to 150 friends. You have 143."
- **Blocked Users**, always the last card (Guideline 1.2): one row with "2" or "None", pushing `.blockedUsers`.
- **Remove** asks: "You and Maya won't be able to message each other. Your conversation stays, read only. You can add each other again later."
- **Accept:** the row moves into Friends with `.snappy`, then the shell's "You and @sam are now friends" toast with **Send a Quote**.
- **Empty:** inside Friends, `MarginCardMessage(person.2)` "No friends yet." / "Add someone by their exact username, or share yours." No second filled button.
- **States.** Cached first, a `DelayedProgressView` row on a cold start. "Couldn't load your friends" with **Try again**. Offline, Add, Accept and Remove toast "You're offline. Try again when connected." and roll back.
- **Terms:** Add and Accept are first social actions; the Terms sheet comes first (§22).
- Removed: the profile row ("Account and settings") and the "Shared with you" section. Shares now live in conversations.
- VoiceOver: "Accept request from Sam Kim", "Add friend", and the action "Message Maya" on friend rows.
- Type: `.body`, `.subheadline` and `.footnote`; semibold on headers and buttons.

### 10a. Your profile (Profile tab, `MyProfileView`)
- The Profile tab's root. Tapping your own @username anywhere pushes the same content as `.profile` on the current stack, with View As and no gear: Settings has one way in.
- Inline title "Profile". The header carries the name.
- **Toolbar** (trailing): **View As** (`eye`; until Public ships a plain button that opens View As as a friend, VoiceOver "View as a friend"), `ToolbarSpacer(.fixed)`, then **Settings** (`gearshape`, id `profile.settings`, root only), which pushes §12.
- **Layout** (`List`, `.marginCardList()`):
  1. **`ProfileHeader`:** a 72-pt `AvatarCircle` (hidden at accessibility sizes), the display name in `.title2` semibold (wraps), the @username in `.body` `.secondary` (one line, `minimumScaleFactor(0.8)`), centred. Context menu: **Copy Username** (toast "Copied @alex") and **Share Username…**. No counts, bio or avatar upload. VoiceOver: "Alex Rivera, @alex".
  2. **How your quotes appear:** one card with your newest quote whose creator is you, drawn as friends see it: 4 lines, the attribution, and the card line "Added by @alex · Not checked" (`.friends` perspective). A tap pushes `.quote(id:contextIDs: [id])`. Caption: "When you post or send a quote you added, friends see your username on it." Empty: `MarginCardMessage(seal)` "Friends see your username on quotes you add" with a quiet **Add a quote** (presents `.addQuote`).
  3. **Posts:** the header with a static trailing `AudienceLabel(.friends)` (VoiceOver "Who can see your posts: Friends"). Your newest 3 as own `PostCard`s, then **See All** (`.profileItems(me, .posts)`) when there are more. Empty: "Quotes you post to friends show up here." with a quiet **Post a quote** (presents `.composePost(nil)`).
  4. **Playlists:** your 3 most recently updated as `PlaylistRow(showsAudience: true)`, **See All** (`.playlists`) when there are more, then a **New Playlist** row (`plus`, accent) that presents `.newPlaylist(adding: nil)`. Empty: "Make a playlist to send a set of quotes to a friend." and the New Playlist row.
  5. **Favorites:** the header with a trailing `AudiencePicker(subject: "your favorites", options: [.onlyMe, .friends])` bound to `favorites_visibility` (menu subtitles "Only you can see your favorites." and "Friends can see the quotes you heart."). Never Anyone. Your 3 newest favorites as Library rows, then **See All** (`.favorites`). Empty: "Tap ♡ on any quote to add it here." (VoiceOver "Tap Favorite on any quote to add it here.").
- **Filled action:** none.
- **Context menus:** the header (Copy Username, Share Username…); playlist rows as in §19; favorite rows as Library rows.
- **States.**
  - Everything shows from the cache. With no cache, Posts and Playlists each show a `DelayedProgressView` row; Favorites come from the library and never wait.
  - Error with no cache: per section, `MarginCardMessage` "Couldn't load your posts" or "Couldn't load your playlists" with a bordered **Try again**. With a cache, keep it and toast only after a pull to refresh.
  - Offline: cached reads; a write toasts the offline line and reverts.
  - Pull to refresh reloads `my_account()`, your posts, playlists and the library together.
  - Long names wrap; the handle shrinks to 0.8, then truncates (VoiceOver reads it all).
  - Accessibility sizes: no avatar; each header's trailing control drops under its title; playlist rows drop the excerpt.
- **Motion.** Changing the favorites audience is optimistic with `.sensoryFeedback(.selection)`; a failure springs back and toasts. New posts and playlists join their section with the list's default insert.
- **View As** (`.profilePreview(Audience)`, sheet): a `NavigationStack` with the inline title "Your Profile", `.navigationSubtitle("As friends see it")`, `Button(role: .close)` and detent `.large`. The content is §10b's friend layout, built from your own data filtered by audience: posts and playlists with that audience (never Only me), and favorites only when Friends. A footnote under the header reads "This is your profile as a friend sees it." There are no actions; rows open for reading only. Nothing visible: "@alex hasn't shared anything with friends yet." VoiceOver starts on the footnote.
- Reminders never show on a profile.

### 10b. Someone else's profile (`.profile(ProfileRef)`)
- Opens from any @username. The header draws at once from the `ProfileRef` stub; the rest loads through `profile_view(username)`, which returns the relationship, the person and their visible posts, playlists and favorites.
- Inline title: the display name.
- **Layout** (`List`, `.marginCardList()`):
  1. `ProfileHeader(person)`.
  2. A relationship line, only when there is something to act on (`.subheadline` `.secondary`, centred): "Wants to be friends"; "Requested" with a plain **Cancel request**; or "You blocked @alice" with a bordered **Unblock** (§12's confirmation).
  3. Sections, each only when it has items, each ending with **See All** when there are more: **Posts** (3 others' `PostCard`s); **Playlists** (3 `PlaylistRow(showsAudience: false)`, pushing `.playlist(id:)`); **Favorites** (3 rows: the quote, the attribution, the card provenance line and a `SaveToLibraryButton(.capsule)`; a tap pushes `.quoteSnapshot(.favorite(…))`).
  4. Nothing visible: one `MarginCardMessage`, with no action. A friend: "@alice hasn't shared anything with friends yet." Anyone else: "Only friends can see what @alice shares."
- **Filled action**, in the bottom bar:
  - A friend: **Message** (`PrimaryButton`). It calls `open_conversation`, then pushes the conversation on the current stack. Hint "Opens your conversation with Maya".
  - An incoming request: a bordered **Decline** and a filled **Accept**, side by side; stacked at accessibility sizes, Accept on top. VoiceOver "Accept request from @alice".
  - A stranger, an outgoing request, or someone you blocked: no bottom bar.
- **Toolbar `…`** (VoiceOver "More options for @alice"):
  - A friend: Remove Friend…, Report @alice…, Report and Block @alice…, Block @alice.
  - A stranger: Add Friend (`person.badge.plus`), Report @alice…, Report and Block @alice…, Block @alice.
  - A pending request either way: Report @alice…, Report and Block @alice…, Block @alice.
  - Someone you blocked: Report @alice… only.
  - Unavailable: no menu.
- **Add Friend:** the Terms sheet first if needed, then the toast "Request sent to @alice", `.success`, and the relationship line fades in as "Requested".
- **Accept:** the bottom button cross-fades to Message, the sections reload and fade in, and the shell's "You and @alice are now friends" toast shows.
- **States.**
  - Loading: the header, then `DelayedProgressView("Loading profile")`.
  - Unavailable (they blocked you, the account is gone, or no such user): the whole page is `ContentUnavailableView("This profile isn't available", systemImage: "person.slash")`, with no header or menu.
  - Error: `MarginCardMessage` "Couldn't load @alice's profile" with a bordered **Try again**. Offline, the same card reads "You're offline. Try again when connected."
  - Pull to refresh reloads `profile_view` and friendships. A reported post or playlist leaves the page at once.
- **See All** (`.profileItems(ProfileRef, ProfileItemKind)`): the title "Posts", "Playlists" or "Favorites" with `.navigationSubtitle("@alice")`. The same rows, newest first, 30 per page; the next page loads when the last row appears. Empty: `ContentUnavailableView` "Nothing here anymore". A failed page: "Couldn't load more" with **Try again**.

### 11. Send sheet (`.send(SendItem)`, replaces the Share sheet)
- Sends a quote or a playlist to friends. It opens from every **Send**: the single quote, Library and Search swipes and context menus, Feed cards, Quoted Catalog rows, snapshots and the playlist `…`. Image sharing leaves this sheet: **Share Image…** (below) is a `ShareLink` wherever it appears.
- **Header.** A `NavigationStack` with the inline title "Send Quote" or "Send Playlist", **Cancel**, and detent `.large` with the drag indicator. `.interactiveDismissDisabled(hasNote)`: with a note typed, Cancel asks "Discard this note?" with **Discard** (destructive) and **Keep Editing**.
- **Layout.** One `List(selection:)` in `editMode` `.active`, so the multi-select circles are native.
  1. **Preview**, not selectable: a Margin card showing how the friend will see it. The quote (4 lines), the `AttributionLine` and the card provenance line. A playlist: `rectangle.stack`, the title and "12 quotes", then the first quote's two-line excerpt.
  2. A "To" label row (`.footnote` semibold `.secondary`, header trait), then friends as `SocialPersonLabel` rows (the handle in `.footnote`). Recent conversations first, then A to Z. `.searchable(prompt: "Search friends")` above 8 friends. With exactly one friend, they start selected.
- **Bottom bar** (`.safeAreaBar`, 16-pt gutters, 8 between items):
  - The note: `TextField("Add a note (optional)", axis: .vertical)`, 1 to 4 lines, `.body`, in a Surface rounded rectangle (20) with a hairline; the counter "245/280" shows from 240. Hidden for playlists.
  - The footnote (`.footnote` `.secondary`, `sendFootnote`): your own quote "Your username stays with this quote."; someone else's "Added by @alice stays with this quote."; a catalog or unknown quote, none; a playlist "Each quote keeps who added it."
  - **Send** (`PrimaryButton`): "Send" (disabled with nothing selected), "Send to Maya" or "Send to 3 friends", loading while the server works. **The one filled action.**
- **Someone else's quote** (a post, a message, a friend favorite or a playlist item). A checked one sends its catalog id. A post or a message is forwarded as it is (`source_post_id` or `source_message_id`): nothing is saved, and the server copies what you can read, so a quote you can no longer see fails with "This quote is not available." A friend favorite or a playlist item has no forward source: it is saved to your library first (not into Reminders), and the footnote adds " Sending also saves it to your library."
- **Sending.** Each friend gets one quote message in their 1:1 conversation, sent separately with its own client id. `.sensoryFeedback(.success)`.
  - All sent: the sheet closes with "Sent to Maya", "Sent to Maya and Jordan" or "Sent to 3 friends" and **Undo** for 5 s, which unsends them.
  - Some fail (unfriended, blocked, a closed conversation or a limit): the sheet closes with "Sent to Maya and Jordan. Couldn't send to @sam." and **Undo**, which unsends the delivered ones.
  - All fail: the sheet stays with the selection and note, and toasts the error.
  - QR003 fails every message at once: "Quoted doesn't allow some words in posts and messages." The sheet stays and the note takes focus.
  - Offline: the offline toast; the sheet stays.
  - Terms not yet accepted: the Terms sheet stacks over this sheet first (§22).
- **An Only me playlist** asks once, at Send: `confirmationDialog` "Let friends see “Courage”?", with the message "Friends you send it to can open it. It stays hidden from everyone else." and **Switch to Friends** and Cancel. Then it sends.
- **No friends.** The list becomes `EmptyStateView(person.2, "Add friends to send quotes", "Friends add each other by exact username.", "Add a friend")`. The button closes the sheet and pushes `.friends(.add)` on the current tab; it is the one filled action. A quiet **Share Image instead** (the `ShareLink`) keeps the moment.
- **Other states.** Friends loading: `DelayedProgressView`. Friends failed: "Couldn't load your friends" with **Try again**.
- **Accessibility sizes:** the note, footnote and Send move to the end of the list, so the bar never covers the friends.
- **VoiceOver.** The preview: "Preview: <quote>, <author>. Added by you, not checked." Rows: "Maya Reyes, @maya", with the Selected trait. Send: "Send to Maya".
- Type: `.title3` serif, `.body`, `.footnote` and `.caption`.

**Share Image…** (a `ShareLink` to the iOS share sheet):
- An image of the `QuoteCard`: Surface, hairline, 32-pt padding, light appearance, `.large` Dynamic Type, rendered by `ImageRenderer` at 3x, 390 pt wide. The body steps through `pageSteps` to fit a 4:5 frame (390 × 488 pt); when even the last step doesn't fit, the image grows taller rather than truncating.
- Under the attribution: a hairline, then the provenance label at leading (`ProvenanceLine(.card, perspective: .outsideQuoted)`, glyph included). A checked quote: "Quoted Catalog · Checked". Your own, with or without "edited from": "Added by @hwei · Not checked". Anyone else's, or unknown: "Added by a person · Not checked". No wordmark or other tag.
- `SharePreview("Quote card", image:)`. It opens from the single quote's `…` and the zero-friend action rows (§6, §6a, §6b), the Library, Favorites and playlist context menus, a snapshot's `…`, and the Send sheet's no-friends link. "Share as text" is gone; a conversation's Copy copies `“body” — Author, Source`.

### 12. Settings (`.settings`, replaces Account)
- Pushed only from the Profile tab root's gear. It replaces `AccountView` and `.account`. Favorites visibility now lives on your profile (§10a).
- A stock grouped `Form`: `.scrollContentBackground(.hidden)` on Ground, rows on `Surface`, separators in `Hairline`, `.listSectionSpacing(24)`. Large title "Settings". No row glyphs; values sit on the right in `.secondary`. Check in light mode that Surface sections read on Ground; if they don't, use today's `MarginCardRowBackground` slices. Never `systemGroupedBackground`.
- **Sections, in order:**
  1. **Account.**
     - **Display Name**: `LabeledContent` with the name or "Not set". It opens the display-name sheet (hint "Changes the name friends see next to your username").
     - **Username**: "@alex", selectable, with a context menu Copy Username, and a second line "You can't change this". Not a button.
     - An email account (dormant) also shows its sign-in email in `.secondary`. **Back Up with Apple** stays hidden until it ships.
     - Footer for an anonymous account: "This account lives on this iPhone, with no email or password. If you delete the app, it can't be recovered."
  2. **Reminders** (one row, no header): a `NavigationLink` to `.reminders` with the value On or Off and `reminders.statusLine` as a second line ("3× a day · Next at 8:00 PM"). When notifications are denied it stays a link, with the second line "Notifications are off for Quoted"; the Reminders banner has Open Settings.
  3. **Privacy.**
     - **Friends can text me**: a `Toggle`, on by default, bound to `accepts_text_messages` from `my_account()`. Second line: "Quotes and playlists from friends always arrive." Optimistic with `.selection`; a failure springs back and toasts. Disabled until `my_account()` has loaded, showing the cached value.
     - **Blocked Users** pushes `.blockedUsers`.
  4. **About.**
     - **Community Guidelines**, **Terms of Use** and **Privacy Policy** open in-app `TextPageView` with bundled markdown in `App/Resources/Legal/` (no draft banner; legal review is a founder step in `docs/app-store-submission.md`). `{{SUPPORT_EMAIL}}` in the pages becomes a `mailto:` link; without an address the sentence is left out.
     - **Contact Support**: a `Link` to the `SupportEmail` Info.plist value (`SUPPORT_EMAIL` in `Config/Shared.xcconfig`; Release builds fail without it), with a trailing `arrow.up.forward` and a context menu Copy Address. Hide the row when it is empty.
  5. **Sign Out:** only when `session.canSignOut`: `AccountMode.emailPassword` and an account that is not anonymous. In this build no account gets it, including a leftover or DEBUG email session (nothing could sign back in to an anonymous account). To leave the DEBUG demo account locally, launch with `-UITestReset` or reinstall.
  6. **Delete Account:** destructive, in red, in its own section. Footer: "Deleting your account permanently removes your quotes, posts, playlists, friends and conversations from our servers." Then the version line ("Quoted 1.0.0 (6)"), centred, `.footnote` `.secondary`, 24 pt below.
- **Delete account alert:** "Delete your account?" with **Delete Account** and Cancel. Anonymous accounts: "This permanently deletes your account, your quotes, posts and playlists, your friends and your conversations. Quotes friends saved stay with them as “Added by a person”. Quoted then starts over with a new, empty account. It can't be undone." Email accounts: the same without the sentence about starting over. Then call `AccountService.deleteAccount()`, clear the App Group, cancel notifications and reload widgets, behind the deleting overlay. The toast "Your account was deleted" follows. With anonymous accounts the app then creates a new, empty account and returns to Choose a username (§2); with email accounts it returns to Welcome.
- **Display-name sheet:** today's copy. QR003 shows inline under the field ("Quoted doesn't allow some words in names.") and the sheet stays open.
- **States.** The whole form is disabled during delete and sign out. Offline, toggles revert with the offline toast; links and the bundled pages still work. At accessibility sizes values stack under their labels.
- **VoiceOver:** "Username, @alex, you can't change this". "Friends can text me, on, quotes and playlists from friends always arrive". "Contact support, link, opens Mail".
- UI tests reach Settings through the Profile tab and `profile.settings`.

**Blocked users** (`BlockedUsersView`, `.blockedUsers`, from Settings › Privacy and the last row of Friends). Blocking no longer deletes anything.
- Rows: `SocialPersonLabel` with a bordered **Unblock**. The context menu (and VoiceOver actions) also has Report @x…. Someone who blocked you back is still listed (the server no longer shows you their profile): a `person.slash` circle, "Blocked account" and "Their profile isn't available", with **Unblock** only.
- Footer: "People you block can't find you by username, see your profile, posts, playlists or favorites, or message you. They aren't told. Unblocking doesn't make you friends again or reopen your conversation."
- Empty: `ContentUnavailableView("No blocked users", systemImage: "hand.raised")` with "People you block can't find you by username or see anything you share. Block someone from the … menu on their profile or a conversation."
- Unblock asks (here and on a profile): "Unblock @alice?" with "@alice can find you by username and send a friend request again. Your old conversation reopens only if you become friends again." Then the toast "Unblocked @alice". For "Blocked account" (they blocked you too, and their block still keeps you apart): "Unblock this account?" with "You can find each other again only if neither of you blocks the other. Your old conversation reopens only if you become friends again." Then "Unblocked".
- No filled action.

### 13. Widgets (`Margin-Widgets.png` + fixes)
- Families: `.systemSmall`, `.systemMedium` and `.accessoryRectangular`.
- `containerBackground(for: .widget) { Surface }`. Quote text is `widgetAccentable()` so it works in the tinted and clear modes. The serif design and runs are applied through `QuoteText`.
- **Small:** the quote (up to 5 lines, scaling down) and the author in small caps.
- **Medium:** the quote plus the author and source.
- **Rectangular:** the quote (3 lines) followed by "— Author".
- **Provenance:** small and medium end the author line with the filled `checkmark.seal.fill` for checked quotes only, `.widgetAccentable()` so it takes the tint (VoiceOver "Quoted Catalog, checked word for word"). Rectangular shows no glyph. Never "Added by" text or the hollow seal. A blank author shows no author line.
- **Timeline:** `ReminderPlanner`, so it matches the latest notification, with one entry per slot over the next 24 h plus "now". `widgetURL` is `quoted://quote/<id>`.
- **Empty or signed out:** "Add quotes to your reminders", linking to `quoted://rotation`.
- Gallery: display name "Quote", description "A quote from your reminders, matching your latest reminder."

### 14. Notifications
- The subtitle is the author, and the body reads `“body”` in plain text with the quote's line breaks (each line tidied, runs of blank lines kept to one): notifications can't render runs. There is no title, so iOS shows "Quoted". `threadIdentifier` is `reminders`. `userInfo` carries `quoteID`, and a tap opens the quote full screen (§6a).
- Plan with `ReminderPlanner` (at most 60). Replan on launch, on foreground, on any change, and in a `BGAppRefreshTask` (`com.hwei.quoted.refresh`, about every 12 h) that also refreshes the widget snapshot.
- No glyph and no provenance: a banner can't draw symbols. Reminder notifications never set `content.badge`. Background refresh no longer posts inbox alerts; a tap on an old one opens `quoted://inbox`.

### 15. Feed (tab)
- The first tab, `text.quote`, with `NavigationStack(feedPath)` and `FeedView`. Large title "Feed". No badge. The launch-tab rule is in App structure.
- **Toolbar:** trailing **New Post** (`square.and.pencil`, quiet glass with an accent glyph, id `feed.compose`) presents `.composePost(nil)`. It is never filled.
- **Layout:** a `List` with `.marginCardList()` on Ground, one `PostCard` per post, 12 pt apart, newest first. Only posts by you and your accepted friends; strangers never appear. No section headers, day dividers, ranking or "new posts" pill.
  - **No friends, but you have posted:** above the first card, a quiet `MarginCardMessage(person.2)` "Friends you add will see your posts." with a bordered **Add a friend** that pushes `.friends(.add)` on the Feed stack. It goes once you have a friend.
- **Paging:** 30 per page (keyset on `created_at, id`). When the fifth-from-last row appears, fetch the next 30. While fetching, a footer row with a centred `ProgressView` (VoiceOver "Loading more posts"). A failed page: "Couldn't load more posts." with a bordered **Try again**. A short page ends paging, with no end marker.
- **Refresh:** pull to refresh, and on appear and on return to the foreground when the last refresh is over 60 s old. Newer posts join the top without moving what the reader is looking at. Each refresh recomputes `opensOnFeed`.
- **Cache:** the first page is cached in the App Group, so a cold launch or an offline open shows posts at once.
- **Posts that leave:** a post you reported or deleted, and every post by someone you blocked, fade out at once. An unfriended person's posts go on the next refresh.
- **States.**
  - Loading with no cache: `DelayedProgressView("Loading your Feed")`.
  - Error with no cache: `EmptyStateView(systemImage: "exclamationmark.icloud", title: "Couldn't load your Feed", message: <friendly error>, actionTitle: "Try again")`, the one filled action.
  - Error with a cache: the posts stay; a failed pull to refresh toasts.
  - Offline: cached posts. Pull to refresh, Save, Send, Delete and Report toast "You're offline. Try again when connected." and change nothing.
- **Empty Feed, "Checked against the source"**, when the Feed has loaded with no posts from you or your friends (never while loading or after an error):
  - A `ScrollView` on Ground. The heading "Checked against the source" (`.headline`, header trait), then 12 pt below, a `QuoteCard` with one catalog quote: serif from `.hero` stepping down through `.title`, `.title2` and `.title3` with `ViewThatFits`, so the heading, card and bar fit one screen at the default size; past `.title3` the page scrolls. At accessibility sizes it stays `.hero` and scrolls. Hanging marks and the `AttributionLine`, then a hairline and the checked provenance block ("Quoted Catalog", "Checked word for word against …"), which opens the provenance sheet (hint "Shows how it was checked").
  - The quote comes from the cached catalog in `sortOrder`. Its index is the whole days since 2001-01-01 in the current calendar and time zone, modulo the count. It changes the next time the Feed appears after local midnight, never while it is on screen.
  - **Bottom bar** (`.safeAreaBar`, reporting its height): one guidance line (`.body` `.secondary`, centred) and, 12 pt below, the filled `PrimaryButton`:

    | Friends | Guidance | Filled button |
    |---|---|---|
    | None | "When friends post quotes, they show up here." | **Add a friend**: pushes `.friends(.add)` on the Feed stack |
    | Exactly one | "You and @maya are friends. Post a quote for them to see." | **Post a quote**: presents `.composePost(nil)` |
    | Two or more | "Quotes you and your friends post show up here." | **Post a quote** |

  - When the friend count changes, the guidance and button cross-fade (0.25 s) the next time the Feed is on screen. No haptic.
  - Context menu on the card: Save to Library (or a disabled "In Your Library"), Send…, Post…. No visible buttons, so the screen keeps one action.
  - Catalog unavailable (not cached and the load failed): no heading or card, and `EmptyStateView(systemImage: "text.quote", title: "No posts yet", message: <the guidance>, actionTitle: <the button>)`. A failed decoration never shows an error.
  - At accessibility sizes the guidance and button follow the card at the end of the scroll view.
  - VoiceOver, in order: the heading; the card ("<quote>. Marcus Aurelius, Meditations."); the block ("Quoted Catalog, checked word for word against Meditations, Book 4"); the guidance; the button.
- **Post card** (`PostCard(post, variant:)`, also on profiles and as the composer's preview). Inside a Margin card, padding 16:
  1. The quote: `QuoteText(.row, lineLimit: 10, quoteMarks: .hanging)`.
  2. 8 pt below, the `AttributionLine`; 4 pt below it, the card provenance line, a 44-pt button that opens `.provenance`.
  3. 12 pt below, a hairline, then 12 pt below it the footer in `.subheadline`: **@bob** (semibold, a plain button with `minHeight: 44` and a content shape, pushing `.profile`), then " · 2h" in `.secondary`. Your own reads **You**, which pushes your profile (plain text on your own Profile). Trailing: the `…` menu (`ellipsis`, `.secondary`, 44 × 44, VoiceOver "More").
  4. 4 pt below, the caption in `.subheadline`, full text (at most 280), absent when empty. It never sits above or inside the quote.
  5. Held (your own post, `held_at` set): `Label("Only you can see this while Quoted reviews it.", systemImage: "eye.slash")`, `.footnote` `.secondary`. Send is disabled while held.
  6. 12 pt below, the actions row, 24 apart, borderless, `.subheadline` regular `.secondary` with glyphs, each at least 44 pt: `SaveToLibraryButton(.inline)` and **Send** (`paperplane`, `.send(.snapshot(.post(id)))`). A card has no filled or bordered button.
  - **Taps:** the quote and attribution push `.quoteSnapshot(.post(id))`. Each control is its own borderless button, so a tap never fires two.
  - **Menus and swipes:**

    | Where | Others' post | Your post |
    |---|---|---|
    | `…` menu | Report Post…; Report and Block @bob… | Delete Post |
    | Context menu | Save to Library; Send…; Divider; View @bob's Profile; Report Post…; Report and Block @bob… | Save to Library; Send…; Divider; Delete Post |
    | Leading swipe (Feed only) | **Save** (full swipe), absent once held | the same |
    | Trailing swipe (Feed only) | **Report** (no full swipe) | **Delete** (full swipe) |

  - "Who can see this" stays out of post menus until Public ships. Every post is Friends.
  - **Save to Library:** `save_from_post` with a client id, Library only, with the `SaveToLibraryButton` feedback and the save toast.
  - **Delete Post:** no dialog. The card fades out, the toast "Post deleted" shows **Undo** for 5 s, and the server delete runs when the toast closes. `.warning`. Copies friends saved stay in their libraries.
  - **Report:** the shared pattern. A reported post fades out; Report and Block fades every post by @bob.
  - **Variants:** `.others` and `.own` as above. `.preview` (the composer) has no actions, menu or swipes; its provenance line isn't a button; the footer reads **You** with no time; the caption slot holds the caption field.
  - **Long text and sizes:** a long username wraps the footer, and the `…` stays at the top trailing corner. At accessibility sizes the actions stack and the footer's name and time stack. The 10-line cap stays; §6b holds the rest.
  - **VoiceOver**, in visual order: the quote area ("<full quote>. Mary Shelley, Frankenstein.", hint "Opens the quote", actions Save to Library, Send, then Report Post or Delete Post); the provenance button; the footer ("Posted by bob, 2 hours ago", hint "Opens bob's profile"; your own "Posted by you, 2 hours ago"); "More"; the caption ("bob's caption: …", "Your caption: …"); the held note; Save to Library; Send (hint "Sends this quote to a friend").
- Type: `.title3` serif, `.subheadline`, `.footnote` and `.caption`.

### 16. Post composer (`.composePost(PostSeed?)`, sheet)
- `PostSeed` is `.quote(UUID)` (your library) or `.catalog(Int)`. The sheet holds deep links.
- **Opens from.** No seed: the Feed's **New Post** and the empty Feed's **Post a quote**. A seed: the single quote's bordered **Post**; **Post…** in Library, Favorites, playlist, Quoted Catalog and Search context menus; the empty Feed card; and a catalog snapshot's `…`.
- **Shape.** A `NavigationStack`, detent `.large` with the drag indicator, a `List` with `.marginCardList()` and `.scrollDismissesKeyboard(.interactively)`. With no seed, the root is the picker and a pick pushes the form; Back returns to the picker and keeps the caption. With a seed, the root is the form; its **Change** pushes the picker, and a pick pops back.
- **Dismissal.** `.interactiveDismissDisabled(hasCaption || isPosting)`. Cancel with a caption typed asks "Discard this post?" with **Discard** (destructive) and **Keep Editing**.
- **Choose a Quote** (`QuotePickerList`, the same picker the conversation and the Inbox empty state use):
  - Inline title "Choose a Quote". Toolbar: **Cancel**, and a trailing plain **New Quote** that presents Add over the composer (§7).
  - A segmented **Library** | **Quoted Catalog** picker as the first row: Library by default, Quoted Catalog when your library is empty. `.searchable(placement: .navigationBarDrawer(displayMode: .always), prompt: "Quotes, authors, sources")` filters the selected source on the phone.
  - Library rows: `QuoteRow` with the row provenance line, newest first. Quoted Catalog rows: `provenance: nil`, under a header with the filled seal and "Every quote here was checked word for word against a public-domain edition."
  - A tap picks the quote (`.selection`). The quote already picked shows a trailing accent `checkmark` (VoiceOver: Selected).
  - States: an empty library shows `ContentUnavailableView("No quotes yet", systemImage: "text.quote", description: "Add quotes to your library, or pick one from the Quoted Catalog.")` with a bordered **Show Quoted Catalog**; no match shows `ContentUnavailableView.search(text:)`; the catalog loading shows `DelayedProgressView`; a catalog error shows the message with **Try again**.
  - No filled action: a tap is the action.
- **New Post** (the form):
  - Inline title "New Post". Toolbar: **Cancel** at the root (Back when pushed) and **Post** (`.confirmationAction`, `.borderedProminent` capsule). **Post is the one filled action.** It is disabled until a quote is picked and the caption is at most 280 characters, with the hints "Choose a quote first" or "Shorten the caption to 280 characters". While posting, a spinner in `onAccent` (VoiceOver "Posting"), and the sheet can't be dismissed.
  - `MarginSectionHeader("Quote")` with a trailing **Change** (VoiceOver "Change quote").
  - `PostCard(.preview)`, exactly as friends will see it, with the caption field in the caption slot: `TextField("Add a caption (optional)", axis: .vertical)`, `.subheadline`, 1 to 8 lines, not focused on open. A counter from 240 characters ("241/280", `.footnote` monospaced digits, `.inlineError` over 280; VoiceOver "241 of 280 characters").
  - 24 pt below, one card row: `LabeledContent("Who can see this") { AudienceLabel(.friends) }`. A value, not a control, while Friends is the only choice.
  - 8 pt below, the footnote (`.footnote` `.secondary`): "Your username shows on the post." followed by the send footnote when there is one, for example "Your username shows on the post. Added by @alice stays with this quote." A catalog or unknown quote gets the first sentence only.
- **Posting.** Terms not yet accepted: the Terms sheet stacks over the composer; Accept posts, and Not Now leaves the composer as it was. The insert sends a client `id`, `source_quote_id` or `starter_quote_id`, the trimmed caption (empty becomes null) and `audience` friends. The server builds the snapshot.
- **Success.** The sheet closes with `.sensoryFeedback(.success)`; the composer owns this haptic.
  - On the Feed tab the post slides in at the top (`.move(edge: .top)` with opacity, `.snappy`) and the list scrolls to it. The first post ever also toasts "Posted to Feed". Later posts show no toast: the card is the confirmation.
  - Anywhere else: "Posted to Feed" with **View**.
  - With no friends yet: "Posted. Friends you add will see it."
- **Failure.** The sheet keeps the quote and caption, and Post comes back.
  - QR003: "Quoted doesn't allow some words in posts and messages." The caption takes focus.
  - QR001: "You can post at most 20 quotes a day."
  - Offline: "You're offline. Try again when connected."
  - The picked quote was deleted meanwhile: "That quote is no longer in your library." The form returns to the picker.
  - Anything else: `friendlyMessage`.
- **Accessibility sizes:** the preview reflows like a post card. The form scrolls; nothing is pinned.
- **VoiceOver:** the preview "Preview: <quote>. Mary Shelley, Frankenstein. Added by you, not checked."; the field "Caption"; "Who can see this, Friends"; the footnote; "Post".
- Type: `.title3` serif, `.subheadline`, `.footnote` and `.caption`.

### 17. Quoted Catalog (`.catalog`)
- Pushed onto the Library stack from the top section. Large title "Quoted Catalog".
- **Layout:** a plain `List` on Ground.
  1. **Promise row** (no card, no separator), `.subheadline` `.secondary`: the filled accent seal with "Every quote here was checked word for word against a public-domain edition." No count.
  2. The catalog in `sortOrder`, as `QuoteRow(provenance: nil)` (the promise row states the seal), with a trailing `SaveToLibraryButton(.capsule)` centred vertically. At accessibility sizes the capsule moves under the attribution.
- **Row tap:** a quote you hold pushes your copy (`.quote(id:contextIDs:)`). Any other pushes `.quoteSnapshot(.catalog(id))`, where the whole quote, the edition line and Read it on Project Gutenberg or Wikisource live. The capsule never opens the row.
- **Swipes and menu:** a leading **Save** (full swipe) when not held. Context menu: Save to Library, Send… (`.send(.catalog(id))`), Post… (`.composePost(.catalog(id))`), About This Quote (`info.circle`, `.provenance`).
- **Save:** `add_catalog_quotes` with a client id, Library only, with the `SaveToLibraryButton` feedback and the toast "Saved to your library" with **Add to Reminders**.
- No search field. The Search tab finds catalog quotes, and its "Checked" token alone lists the whole catalog.
- **States.**
  - Loading with no cache: `DelayedProgressView("Loading the Quoted Catalog")`.
  - Error with no cache: `EmptyStateView(systemImage: "exclamationmark.icloud", title: "Couldn't load the Quoted Catalog", message: <friendly error>, actionTitle: "Try again")`, the one filled action of that state. An empty answer shows the same with "The Quoted Catalog isn't available right now."
  - Offline: the cached list; Save toasts the offline line.
  - You hold every quote: a footer row, "Every quote here is in your library."
  - Rows cap at 4 lines; §6b shows the rest.
- **Filled action:** none while the list shows.
- **VoiceOver:** a row reads "<quote>. Marcus Aurelius, Meditations. Quoted Catalog, checked word for word.", then "Save to Library" or "In your library".
- Type: `.title3` serif, `.subheadline` and `.caption`.

### 18. Favorites (`.favorites`)
- Pushed from the Library's Favorites row and from See All in your profile's Favorites, onto that tab's stack. Large title "Favorites".
- **Layout:** a plain `List` on Ground, the Library filtered to favorites, newest heart first.
  1. A first row in `.subheadline` `.secondary` that states `favorites_visibility`: "Only you can see your favorites." or "Friends can see your favorites." The control lives on your profile.
  2. The count header ("3 favorites").
  3. The Library's rows, swipes and context menu, unchanged. A tap pages §6 across the favorites in this order.
- **Unfavorite here:** the row fades out and the toast "Removed from favorites" shows **Undo** for 5 s.
- **Empty:** `EmptyStateView(systemImage: "heart", title: "No favorites yet", message: "Tap ♡ on any quote to add it here.")`, with no button (VoiceOver "Tap Favorite on any quote to add it here."). The action is the heart on each quote.
- **States:** as the Library. **Filled action:** none.

### 19. Playlists and Playlist
A playlist is a titled, ordered list of quotes from your own library: titles of 1 to 60 characters, up to 100 playlists of 200 quotes each, 20 new a day. It is never Reminders.

**Shared parts.**
- `Audience`: `.onlyMe` (`lock`, "Only me"), `.friends` (`person.2`, "Friends") and `.anyone` (`globe`, hidden until Public ships).
- `AudienceLabel(_:)`: glyph plus text, `.subheadline` `.secondary`. VoiceOver "Only you can see it", "Friends can see it".
- `AudiencePicker(subject:selection:options:)`: a stock `Picker` with `.pickerStyle(.menu)`. Its face is the selected `AudienceLabel` in the accent with the system chevrons; each option has a subtitle in the menu. With one option it draws as a plain `AudienceLabel`. VoiceOver "Who can see your favorites, Only me".
- `PlaylistRow(playlist:showsAudience:)`: the title in `.headline` (2 lines); the first quote as a one-line serif excerpt (hidden at accessibility sizes; "No quotes yet" in `.tertiary` when empty); then `AudienceLabel` · "12 quotes" in `.footnote` `.secondary` for yours, or "12 quotes" for a friend's; a chevron. VoiceOver "Courage, Friends can see it, 12 quotes", hint "Opens the playlist". Your rows add the actions Send, Rename and Delete.

**Playlists** (`.playlists`):
- Pushed from the Library's Playlists row and See All on your profile. Large title "Playlists".
- Toolbar: **New Playlist** (`plus`, `.glassProminent`) presents `.newPlaylist(adding: nil)`. It turns quiet `.glass` in the empty state.
- One card of `PlaylistRow(showsAudience: true)`, most recently updated first. No sort control or search; the Search tab finds your playlists by title.
- Leading swipe: **Send** (`paperplane`, accent). Trailing swipe: **Delete** (destructive, asks first, no full swipe). Context menu: Send…, Who can see this (a submenu `Picker`), Add All to Reminders, Rename…, Delete Playlist.
- Empty: `EmptyStateView(systemImage: "rectangle.stack", title: "No playlists yet", message: "Make a playlist to send a set of quotes to a friend.", actionTitle: "New playlist")`.
- Loading: the cache first, else a `DelayedProgressView`. Error: "Couldn't load your playlists" with **Try again**. Pull to refresh. At 100 playlists New Playlist still opens, and QR002 shows there inline.

**Playlist, yours** (`.playlist(id:)`; the view picks yours or a friend's by owner):
- Inline title: the playlist title. The header repeats it so it can wrap: the title in `.title2` semibold, then 4 pt below, `AudiencePicker(subject: "this playlist", options: [.onlyMe, .friends])` followed by " · 12 quotes" in `.subheadline` `.secondary`.
- The quotes in playlist order as Library rows (with the row provenance line), with hairlines and no numbers. A tap opens §6 paging in playlist order.
- Bottom bar: **Add quotes** (`PrimaryButton`, id `playlist.addQuotes`) opens Add Quotes. **The one filled action.**
- **Toolbar.** **Edit Order** (a text button, hidden under 2 quotes) switches the rows to the Reminders excerpt style with drag handles (`onMove` only) and hides the bottom bar and `…`; it becomes **Done** (`.confirmationAction`). Each move saves optimistically and springs back with a toast on failure; VoiceOver gets Move Up and Move Down. Then the `…` menu (VoiceOver "Playlist options"):
  - **Send…** (`paperplane`), disabled when empty. An Only me playlist asks at Send (§11).
  - **Who can see this:** a submenu `Picker`, Only me or Friends. Narrowing to Only me asks with `confirmationDialog` "Only you will see “Courage”" and "Friends you sent it to will see “This playlist is no longer available.”", with **Only Me** and Cancel. Widening is immediate, with the Terms sheet first if needed.
  - **Add All to Reminders** (`bell`): a one-time add of the quotes not yet in reminders, appended in playlist order. Toast "Added 8 quotes to your reminders" with **Undo**, which removes exactly those; when all are in, "Every quote here is already in your reminders". Disabled when empty. `.success`.
  - **Rename…** (`pencil`): `.alert("Rename Playlist")` with a `TextField` (prompt "Playlist title", 60 characters, prefilled), Cancel and **Save** (disabled while blank or unchanged).
  - A divider, then **Delete Playlist** (`trash`, destructive): `confirmationDialog` "Delete “Courage”?" with "The quotes stay in your library. Friends you sent it to will see “This playlist is no longer available.”", **Delete Playlist** and Cancel. It pops with the toast "Deleted “Courage”".
- **Rows.** Trailing swipe: **Remove** (`minus.circle`, full swipe), with the toast "Removed from “Courage”" and **Undo**, which puts it back in its old place; the quote stays in your library. Leading swipe: **Send**. Context menu: Send…, Post…, Share Image…, Add to / Remove from Reminders, Favorite / Remove from Favorites, Remove from Playlist (destructive).
- **States.**
  - Empty: the header and bottom bar stay. Below the header, `ContentUnavailableView("No quotes yet", systemImage: "rectangle.stack")` with "A playlist is a list you can share. To get quotes on your Lock Screen, use Reminders." and a quiet **Open Reminders** (pushes `.reminders`).
  - Held: `eye.slash` "Only you can see this while Quoted reviews it." Send and Who can see this are disabled.
  - Deleted on another device: it pops with the toast "This playlist was deleted".
  - Loading: the cache first, else a `DelayedProgressView`. Error: `MarginCardMessage` with **Try again**. Offline: cached reads; writes revert with the offline toast.
  - The title truncates only in the inline title. Rows keep the 4-line limit. At accessibility sizes Add quotes scrolls after the last row.
- **Errors.** QR003 on a title, inline under the Rename field: "Quoted doesn't allow some words in playlist titles." QR002 at 200: "A playlist holds up to 200 quotes."

**Playlist, a friend's** (`.playlist(id:)` when you're not the owner; `playlist_view(id)`, live and read only):
- Opens from their profile and from a conversation's playlist card (**Open**).
- Header: the title in `.title2` semibold; the owner as a tappable row (a 24-pt avatar, then "Maya Reyes · @maya" in `.subheadline` `.secondary`, pushing their profile; VoiceOver "Maya Reyes, @maya, opens profile"); "12 quotes".
- The quotes in the owner's order: `QuoteText(.row)`, the `AttributionLine`, the card provenance line and a `SaveToLibraryButton(.capsule)`. A tap pushes `.quoteSnapshot(.playlistItem(…))`, paging in the owner's order.
- Bottom bar: **Save a copy** (`PrimaryButton`). `save_playlist_copy` makes a playlist in your Playlists with the same title and audience Only me (saving is private, like the rest of your library; you can switch it to Friends), with its quotes saved to your library (quotes you hold are skipped), each keeping its creator. On success: `.success`, the button becomes a disabled bordered "Saved" with `checkmark` for the rest of the visit, and the toast "Saved “Courage” to your playlists" with **Open**, which pushes your copy.
- Toolbar `…`: View @maya's Profile, Report Playlist…, Report and Block @maya…. A report pops with "Thanks, we'll review it".
- **States.** Loading: `DelayedProgressView`. No longer available (deleted, narrowed to Only me, unfriended, blocked or held): `ContentUnavailableView("This playlist is no longer available", systemImage: "rectangle.stack")` with "Copies you saved stay in your Playlists." and no bottom bar. Empty: "No quotes in this playlist yet." with no bottom bar. Items the server skips (held or filtered) simply aren't there. Error and offline: `MarginCardMessage` with **Try again**. Pull to refresh; it also refreshes on appear and on return to the foreground, with no polling.

**New Playlist** (`.newPlaylist(adding: UUID?)`, sheet):
- From Playlists' `+`, your profile's New Playlist row, the playlist empty states, and Add to Playlist (pushed inside its stack, or opened directly when you have no playlists). It holds deep links while the title isn't empty.
- A `NavigationStack` with a `Form` on Ground, detents `.medium` and `.large`, `.interactiveDismissDisabled` while the title isn't empty (a swipe asks Discard, as Add does). Inline title "New Playlist".
  - Section 1: `TextField("Title", prompt: Text("Playlist title"))`, focused on appear, `.submitLabel(.done)` (Return creates), at most 60 characters. The footer shows "58/60" from 50.
  - Section 2: `Picker("Who can see this")` with **Friends** (the default, `person.2`) and **Only me** (`lock`). Footer: Friends "Friends can see it on your profile and open it when you send it."; Only me "Only you can see it."
- Toolbar: **Cancel**, then **Create** (`.confirmationAction`, `.borderedProminent`), or **Create and Add** when opened with a quote. Disabled while the trimmed title is empty. **The one filled action.**
- Friends with Terms not yet accepted: the Terms sheet stacks over this sheet first; Not Now keeps it open and creates nothing.
- Success: `.success` and the sheet closes. From Playlists or your profile it pushes the new playlist. With a quote, the toast "Added to “Courage”".
- Errors, inline under the field in `.inlineError` (the sheet keeps the title): QR003 "Quoted doesn't allow some words in playlist titles."; QR001 "You can make 20 playlists a day. Try again tomorrow."; QR002 "You can keep up to 100 playlists. Delete one to make another."; offline.
- VoiceOver: the field is "Playlist title"; the counter reads "58 of 60 characters".

**Add to Playlist** (`.addToPlaylist(quoteID:)`, sheet):
- Only for quotes in your library: the single quote's `…` and the Library, Favorites and Search row context menus. A snapshot gets it after Save, through Open in Library.
- A `NavigationStack` with a `List`, detents `.medium` and `.large`, inline title "Add to Playlist", **Cancel**.
  1. **New Playlist…** (`plus.circle`, accent) pushes New Playlist inside this stack with the quote attached.
  2. Your playlists, most recently updated first: the title (`.body`, 2 lines) and `AudienceLabel` · the count (`.footnote`). A tap adds the quote and closes the sheet, with the toast "Added to “Courage”" and `.success`. A playlist that already holds it shows a trailing `.secondary` `checkmark` and can't be tapped (VoiceOver "Courage, already added"). A full one shows "Full" and is disabled.
- With no playlists yet the sheet opens directly on New Playlist (**Create and Add**). Errors toast; the sheet stays open.

**Add Quotes** (`.playlistQuotePicker(UUID)`, sheet from your playlist's bottom bar, modelled on `ReminderQuotePicker`):
- Inline title "Add Quotes". A segmented **Library** | **Quoted Catalog** picker as the first row, and `.searchable(placement: .navigationBarDrawer(displayMode: .always), prompt: "Search quotes")`.
- It opens on Quoted Catalog when your library is empty or every library quote is already in this playlist. The Library segment then shows a footer line instead: "Your library is empty." or "Every quote in your library is in this playlist."
- Rows: `QuoteRow` with a leading check circle (`circle` or the accent `checkmark.circle.fill`); tapping the whole row toggles it. Quotes already in the playlist are dimmed with a `.tertiary` filled check and can't be selected (VoiceOver "Already in this playlist"). Catalog rows show the filled seal; catalog quotes you own show as library quotes. The Quoted Catalog segment's footer: "Quotes you add from here are saved to your library too."
- Toolbar: **Cancel**, then **Add** or **Add 3** (`.borderedProminent`, disabled at 0). **The one filled action.** Selection stops at the room left (200 minus the count); a further tap toasts "A playlist holds up to 200 quotes."
- Picks are appended in tap order, and catalog picks are saved to your library first. The sheet closes with `.success` and "Added 3 quotes to “Courage”" ("Added 1 quote to “Courage”").
- States: no search match "No quotes match “x”"; the catalog loading `DelayedProgressView`; a catalog error "Couldn't load the Quoted Catalog" with **Try again**.

### 20. Inbox (tab)
- The third tab, `tray`, with `NavigationStack(inboxPath)` and `InboxView`. Its badge is described in App structure. It replaces the Friends tab, `SharedInboxView` and the Library's "shared with you" row. Large title "Inbox".
- **Toolbar:** leading **Friends** (`person.2`, VoiceOver "Friends", id `inbox.friends`) pushes `.friends(.list)`, with no badge: the requests row is the signal. Trailing **New Message** (`square.and.pencil`, VoiceOver "New Message") presents `.newMessage`.
- **Friends moved here:** one TipKit tip on the Friends button, "Friends moved here", shown once to accounts that had friends before this build.
- **Layout:** a `List` with `.marginCardList()`.
  1. **Requests row**, only while incoming requests are pending: one Margin card, a `NavigationLink` to `.friends(.requests)` with a chevron. One request: a 40-pt avatar, "Sam Kim wants to be friends" (`.body` semibold, 2 lines) and "@samk" (`.subheadline` `.secondary`). Several: an avatar stack (up to 3), "3 friend requests" and "From Sam, Lee and Ana" (one line). VoiceOver "3 friend requests, from Sam Kim, Lee Park and Ana Ruiz", hint "Opens Friends".
  2. **Conversation rows**, newest `last_message_at` first: plain hairline rows on Ground (`.groundListRow()`), so swipes run edge to edge, with separators inset to the text. Each row has 12 pt of vertical padding:
     - A 48-pt avatar, then 12 pt to the text.
     - Line 1: the display name (`.body` semibold, one line), then the time trailing (`.footnote` `.secondary`; the clock time today, then the shared timestamp rule).
     - Line 2, 4 pt below (`.subheadline`, 2 lines): the text; a quote as `“Trust thyself: every heart…”` in the serif design; a playlist as "Playlist: Morning Pages". Your own last message starts with "You: ". Read rows are `.secondary`, unread rows `.primary`.
     - Unread: a 10-pt accent dot under the time, hidden from VoiceOver, and the preview turns `.primary`, so the state never relies on color alone. No counts per row and no "Seen".
     - Closed: a third line, `Label("Read only", systemImage: "lock")` in `.footnote` `.secondary`.
- **Swipes**, trailing only:
  - **Delete** (`trash`, full swipe; VoiceOver "Delete Conversation", hint "Removes the messages so far, for you only."). The row leaves at once with the toast "Deleted your conversation with Maya" and **Undo**; `cleared_at` is set when the toast closes. Nothing is asked first.
  - **Block** (`hand.raised`), hidden once you blocked them. **Report** (`flag`), a person report with the context "a conversation".
  - No leading swipe. Read state only moves forward, so there is no Mark as Unread.
- **Context menu** (and VoiceOver actions): View Profile, Delete Conversation, Divider, Report @maya…, Report and Block @maya…, Block @maya.
- **Tap:** pushes `.conversation(ConversationRef)`. The ref carries the other person's stub, so the title draws before the messages load.
- **Refresh:** on appear, on return to the foreground and on pull to refresh. The Inbox doesn't poll. New rows slide in with `.snappy` without moving the scroll position.
- **Empty states**, below the requests row when it shows: `EmptyStateView` with `tray`, "No messages yet" and "Quotes your friends send land here."
  - No friends: filled **Add a friend** (pushes `.friends(.add)`) and a quiet **Share my username** (a `ShareLink` with `UsernameInvite.text`).
  - Friends but no conversations: filled **Send a quote** presents the quote picker, and the pick presents `.send(item)`: three taps to a sent quote.
  - With conversations: no filled action. New Message is in the toolbar.
- **States.** Cached conversations first; on a cold start with no cache, a `DelayedProgressView`. Error with a cache: keep the list and toast only after a pull to refresh. Error with no cache: `MarginCardMessage(systemImage: "wifi.exclamationmark", title: "Couldn't load your messages")` with a bordered **Try again**. Offline: the cached list; a swipe write toasts the offline line and the row comes back.
- **Long text and sizes.** Names take one line, previews two; VoiceOver reads the server's full 140-character preview. At accessibility sizes the avatar hides, the name and preview get 3 lines each, the time moves under the name, and the dot stays.
- **VoiceOver:** each row is one element, for example "Maya Reyes, unread, You: “Trust thyself: every heart vibrates to that iron string.”, 9:41 AM". A closed row adds "read only".
- Type: `.body`, `.subheadline` and `.footnote`; semibold only on names.

**New Message** (`.newMessage`, sheet):
- A `NavigationStack` with the inline title "New Message", **Cancel**, and detent `.large` with the drag indicator.
- `.searchable(placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")` filters your friends on the phone by name or username. It is not people search; adding strangers happens in Friends.
- A plain `List` of friends as `SocialPersonLabel` rows: people you have a conversation with, most recent first, then everyone else A to Z. Friends with texts off add "Receives quotes only" (`.footnote` `.secondary`).
- A tap (`.selection`) closes the sheet and pushes `.conversation` on the Inbox stack. `open_conversation` creates or reopens it.
- **States.** Cached friends first, `DelayedProgressView` cold. No friends: `EmptyStateView(systemImage: "person.2", title: "No friends yet", message: "Add a friend by username to send them quotes.", actionTitle: "Add a friend")`, which closes the sheet and pushes `.friends(.add)`; the one filled action. No match: `ContentUnavailableView.search(text:)`. Error: "Couldn't load your friends" with **Try again**.
- **VoiceOver:** "Maya Reyes, @maya", plus "receives quotes only" when texts are off. Hint "Opens your conversation".

### 21. Conversation (`.conversation(ConversationRef)`)
- 1:1 with an accepted friend. Pushed on the current stack from an Inbox row, New Message, **Message** on a friend's profile or in Friends, Search's Inbox group (scrolled to `highlight`), and the friend-accepted toast's **Send a Quote** (which opens the picker). Polling runs only while it is visible, so two stacks never poll at once.
- **Title.** The display name, inline, with `.navigationSubtitle("@maya")`. Trailing: an avatar button (a 32-pt `AvatarCircle` in a 44-pt target, VoiceOver "View Maya's profile") that pushes `.profile`, and a `…` menu (VoiceOver "More options for Maya"): View Profile; Delete Conversation (pops to the Inbox, then the same deferred toast with Undo); Divider; Report @maya…; Report and Block @maya…; Block @maya, or Unblock @maya once blocked (Unblock doesn't reopen the conversation).
- **Body.** A `ScrollView` with a `LazyVStack(spacing: 0)`, `.defaultScrollAnchor(.bottom)`, `.scrollPosition(id:)` and `.scrollDismissesKeyboard(.interactively)` on Ground, with 16-pt gutters. The newest 50 messages load first; older pages load when the first row appears, with a small `ProgressView` at the top.
  - Spacing: 4 between messages from the same sender, 16 at a change of sender, 24 above a date separator and 12 below it.
  - **Date separators,** before the first message of each day and after any gap over 60 minutes: "Today 9:41 AM", "Yesterday 8:02 PM", "Monday 8:02 PM", "Oct 12, 8:02 PM". Centred, `.footnote` `.secondary`, header trait. Messages show no other timestamps; each context menu opens with a section header such as "Sent Monday 9:41 AM".
  - **Text bubble:** `.body`, plain text, no line limit (1,000 at most). Links are not detected or made tappable. 12 by 8 pt padding in a 20-pt continuous rounded rectangle, at most 78% of the width. Theirs: leading, Surface with a hairline. Mine: trailing, AccentSoft with no stroke, never an accent fill.
  - **Quote card:** a Margin card set 48 pt in from the other person's side (theirs inset on the trailing edge, mine on the leading edge), so alignment shows who sent it. The order matches the Feed card: the quote (`.row`, 10 lines, hanging mark); 8 pt below, the `AttributionLine`; 4 pt below, the card provenance line, which opens the provenance sheet; a note when there is one (a hairline 12 pt above and below, then the note in `.body`); and on their cards, 12 pt below, `SaveToLibraryButton(.inline)`. The quote area pushes `.quoteSnapshot(.message(id))`.
  - **Playlist card:** the same card, inset and alignment. A `rectangle.stack` glyph with the snapshot title (`.body` semibold, 2 lines); "12 quotes" (`.footnote` `.secondary`, from `playlist_view`, fetched once per session); and a bordered **Open** that pushes `.playlist(id:)`. When the playlist is gone (a null id, or the view returns nothing): the title, then "This playlist is no longer available", with no Open and no tap (VoiceOver "Playlist, Morning Pages, no longer available").
  - **Accessibility sizes:** bubbles and cards go full width with no inset. Before each change of sender, a sender line, "Maya" or "You" (`.footnote` semibold `.secondary`), hidden from VoiceOver because each message already reads its sender. The toolbar avatar hides; the menu keeps View Profile.
- **Context menus** (long press; the same items are VoiceOver actions):

  | Message | Theirs | Mine |
  |---|---|---|
  | Quote | Save to Library (or a disabled "In Your Library"); Copy; Report Message…; Report and Block @maya… | Copy; Unsend |
  | Text | Copy; Report Message…; Report and Block @maya… | Copy; Unsend |
  | Playlist | Open; Report Message…; Report and Block @maya… | Open; Unsend |

  - **Copy:** a quote copies `“body” — Author, Source`, a text its text, a playlist its title. Toast "Copied".
  - **Unsend** (`arrow.uturn.backward`, destructive): the message leaves at once with the toast "Message unsent" and **Undo**. The server delete runs when the toast closes and keeps its 30-day hidden copy. No confirmation, and no placeholder on either side. The other person's copy goes on their next check.
  - **Report:** the shared pattern. The message disappears for you at once.
- **Composer** (`MessageComposer`, in `.safeAreaBar(edge: .bottom)`, reporting its height; 16 pt horizontal and 8 pt vertical padding):
  - **Attach:** a 44-pt `plus` in `.buttonStyle(.glass)` with a circle shape (VoiceOver "Attach a quote"). It presents the quote picker (`QuotePickerList`); a catalog pick sends the catalog id and isn't saved to your library. From step 5 it becomes a `Menu` with Choose a Quote (`text.quote`) and Choose a Playlist (`rectangle.stack`).
  - **Field:** `TextField("Message", axis: .vertical)`, 1 to 5 lines (1 to 3 at accessibility sizes), `.body`, in a 20-pt glass rounded rectangle at least 44 pt tall. Return inserts a newline; only the button sends. The counter "912/1000" shows in `.footnote` `.secondary` from 900; over the limit it turns `.inlineError` and Send disables.
  - **Send:** `arrow.up.circle.fill` in the accent inside the field at trailing, in a 44-pt target (VoiceOver "Send"). Disabled and `.tertiary` while the text is blank and no quote is attached. **The screen's one filled action.**
  - **Attached quote:** a compact Surface chip above the field (`.compact`, 2 lines, plus the author) with an `xmark.circle.fill` button (VoiceOver "Remove quote"). The placeholder becomes "Add a note" and the limit 280 (the counter shows from 240). Text typed before attaching becomes the note if it fits; if it doesn't, attaching is refused with "Notes can be up to 280 characters."
  - **Texts off** (the other person's `accepts_text_messages` is off): the field is replaced by a plain `.footnote` `.secondary` line, "@alice receives quotes only", above a stock bordered **Choose a quote** (`text.quote`) that opens the picker. Once a quote is attached the note field shows as usual. If text is refused mid-session (QR004), the composer switches to this state, keeps the typed text and toasts "@alice receives quotes only. Attach a quote to send it with a note."
- **Closed conversation** (unfriended, or you blocked them). `ClosedConversationBanner` replaces the composer in the same bar: a Margin card in `.footnote`, "You and Maya aren't friends anymore. You can read this conversation but not reply." or "You blocked @maya. You can read this conversation and report from it.", with a bordered **Report** beside it (under it at accessibility sizes) that opens "Report @maya?". Messages can still be reported one by one. When a new friendship is accepted, the next check swaps the composer back with an opacity transition.
- **Blocked by them.** The conversation is gone for you. If it is open, the next check pops to the Inbox with the toast "This conversation isn't available." It doesn't say why.
- **Polling.** While the screen is visible and `scenePhase` is `.active`, fetch every 10 seconds; fetch once on appear and once on return to the foreground; stop on disappear or in the background. Each check reloads the newest 50 and diffs them, so new messages appear and unsent ones go, and reads the other person's `accepts_text_messages` and `is_closed`. Mark read on appear and when new incoming messages arrive while the newest is on screen; the Inbox dot and badge clear at once.
- **Arrivals.** A polled message fades and moves in from below (`.snappy`) and keeps the view pinned to the bottom when you were there. Scrolled up, a glass capsule "New messages" (`arrow.down`) floats 8 pt above the composer and scrolls to the newest. VoiceOver hears "New message from Maya" without a focus move. Never a haptic.
- **Sending (optimistic).** The message appears at once with "Sending…" (`.footnote` `.secondary`) under it.
  - Failure (network or offline): "Not delivered" in `.inlineError` with a borderless **Try again** (VoiceOver "Not delivered. Double-tap to try again."). Its menu offers Try Again and Delete. The client id makes a retry safe.
  - Errors a retry can't fix: QR003 removes the message, puts its text back in the composer, toasts "Quoted doesn't allow some words in posts and messages." and plays `.warning`. QR001 toasts "You can send at most 300 messages a day." A suspension toasts "You can't send messages right now. Contact support in Settings." The text is kept in every case.
  - Terms not yet accepted: Send presents the Terms sheet first, and Accept sends what was typed.
- **Empty conversation** (a new one, or one you deleted), centred: a 56-pt avatar; 12 pt below, the name in `.title3` semibold; "@maya" in `.footnote` `.secondary`; 16 pt below, "Send @maya a quote." in `.body` `.secondary`; 12 pt below, a bordered **Choose a quote** (`text.quote`) that opens the picker.
- **First message.** The empty header fades out as the first message springs in from the composer, with `.impact(weight: .light)`. While the conversation holds only your messages, a line under it reads "Maya will see it next time they open Quoted." (`.footnote` `.secondary`). VoiceOver announces "Sent". Every later send plays the same light impact and nothing else.
- **Long text.** Quote cards cap at 10 lines and open the full quote; VoiceOver always reads it all. Notes and texts never truncate.
- **VoiceOver.** Each message is one element, in time order: "Maya, 9:41 AM: See you at 6."; "You, 9:41 AM: …"; "Maya sent a quote, 9:41 AM. Trust thyself: every heart vibrates to that iron string. Ralph Waldo Emerson, Self-Reliance. Added by alice, not checked. Note: made me think of you."; "Maya sent a playlist, Morning Pages, 12 quotes." Save to Library follows the card as its own element (hint "Adds the quote to your library"). A "Quotes" rotor jumps between quote cards.
- Type: `.title3` serif (the quote), `.body`, `.footnote` and `.caption`; regular and semibold only.

### 22. Terms sheet (first social action)
- `SocialStore.requireTerms(for:then:)` checks `my_account().terms_version` against the current version before a friend request, accepting one, a post, a message or sent quote, and making a playlist visible to friends. Reading never needs terms.
- The control that asked shows its progress through the check (a server round trip unless the terms are cached as accepted), and its sheet can't close meanwhile. The check belongs to that screen or sheet: if it goes away before the server answers, nothing shows and nothing runs, and if it goes away while the Terms sheet waits, the write is dropped with it. A cancelled send never comes back as a Terms sheet over another screen.
- Presented by the `.termsSheet()` modifier on the root and inside `SheetHost`, never as a `SheetRoute`. It stacks over the sheet that asked (Send, the composer, New Playlist) and never replaces it. Accept runs the pending action inside that sheet. **Not Now** (`.cancellationAction`) or a swipe down cancels the action and leaves that sheet and its typed text untouched.
- A `NavigationStack` with a large title, detent `.large` and the drag indicator. It holds deep links.
  - Title "Community Terms", or "Updated Terms" after a version bump.
  - Intro (`.body` `.secondary`). First time: "Friends on Quoted send each other quotes, messages and playlists. Everyone agrees to the same terms first." Updated: "We updated the terms on October 25, 2026. Accept them to keep sending and posting."
  - A Margin card of four `Label` rows in `.body` with `.secondary` icons, 16 pt apart:
    - `hand.raised`: "Quoted has no tolerance for objectionable content or abusive users. No harassment, threats, hate, sexual content or spam."
    - `flag`: "Report anything that breaks these terms. We review every report within 24 hours."
    - `person.crop.circle.badge.xmark`: "People who break them are removed, and so is what they posted."
    - `at`: "Your username stays with the quotes you add, wherever they go."
  - Two `NavigationLink` rows push `TextPageView` inside the sheet: "Terms of Use" and "Community Guidelines".
  - Bottom bar (`.safeAreaBar`): the footnote "Terms of Use, updated October 25, 2026." above `PrimaryButton("Accept")`, **the one filled action**.
- **Accept** calls `accept_terms(version)` while loading. Success closes the sheet and runs the pending action, with no extra toast; the action's own feedback is the reward. Failure keeps the sheet and toasts `friendlyMessage`; offline, the offline line.
- VoiceOver: the title is a header. Accept's hint: "Agrees to the Terms of Use and Community Guidelines, then continues."
- At accessibility sizes the bottom bar moves to the end of the content.
- Type: `.body` and `.footnote` under the large title; semibold only on the button.

## States checklist (every screen)
- **Loading:** cached data first; a spinner only on a cold start with no cache. This holds for social screens too: the Feed's first page, conversations, friends, posts and playlists are cached.
- **Paging** (the Feed, conversations, See All): a `ProgressView` row while the next page loads; a failed page shows "Couldn't load more" with **Try again**. No end marker.
- **Empty:** guided, with exactly one filled action.
- **Error:** inline or toast with retry. Never a raw error string.
- **Offline:** reads work from the cache; writes show "You're offline. Try again when connected." Server-only groups (Search's Friends' posts and People) show one offline line instead.
- **Signed out** (email accounts; with anonymous accounts only the moment before a new account exists): the widget shows its empty state, and notifications are cancelled. `router.reset()` clears all five paths, the sheet, the spotlight and the search text and tokens, and the social stores reset.
- **No friends yet:** every social surface still works and leads to Friends. The single quote's action row is **Share Image…** (§6, §6a, §6b). The Send sheet, New Message, the empty Feed and the empty Inbox offer **Add a friend**. A post toasts "Posted. Friends you add will see it."
- **Terms:** the first social action shows the Terms sheet over the current screen or sheet (§22). Not Now keeps everything typed.
- **Writes:** optimistic, with a client id so a retry never doubles them. A failure rolls back with a toast. List deletes wait for the 5-s Undo before the server delete.
- **Gone or unavailable:** deleted, unsent, reported or blocked content leaves at once for you, and an unfriended person's on the next refresh. A direct open shows one line with Back only: "This quote isn't available", "This profile isn't available", "This playlist is no longer available" or "This conversation isn't available."
- **Held:** your own post or playlist under review shows `eye.slash` "Only you can see this while Quoted reviews it." Send and Who can see this are disabled.
- **Closed conversation:** read only, with the banner and Report. Never an error.
- **Server refusals** map to plain copy, never raw:
  - QR001, daily limits: "You can post at most 20 quotes a day.", "You can send at most 300 messages a day.", "You can make 20 playlists a day. Try again tomorrow."
  - QR002, caps: "Quoted keeps circles to 150 friends.", "You can keep up to 100 playlists. Delete one to make another.", "A playlist holds up to 200 quotes."
  - QR003, by field: posts and messages "Quoted doesn't allow some words in posts and messages."; names "Quoted doesn't allow some words in names."; playlist titles "Quoted doesn't allow some words in playlist titles." The typed text is kept and its field takes focus.
  - QR004: "@alice receives quotes only. Attach a quote to send it with a note."
  - Suspension: "You can't send messages right now. Contact support in Settings."
- **Fresh data without push:** the Feed refreshes when over 60 s stale, the Inbox on appear, on foreground and on pull, and an open conversation every 10 s. Nothing that arrives by polling plays a haptic.
- **Bottom bars:** a filled action pinned in a `safeAreaBar` joins the end of the scroll content at accessibility sizes, and toasts always clear it.

## Hidden until Public ships
"Anyone with your username" (`Audience.anyone`, `globe`) is built hidden in steps 4 and 5 and switched on in step 6, after the founder's Sign in with Apple, support email and DMCA items. Choosing it needs `private.can_publish()`: a linked Apple account, accepted terms, no suspension, and not declared under 18. Until then it appears nowhere in the app. When it ships, it appears in these places:
- **Post composer:** the "Who can see this" value becomes `AudiencePicker(subject: "this post", options: [.friends, .anyone])`, menu style, default Friends (§16).
- **Your own posts:** a **Who can see this** item returns to the `…` and context menus (Friends or Anyone with your username), with the toasts "Visible to anyone with your username" and "Visible to friends" (§15).
- **Playlists:** the header picker and the `…` **Who can see this** on your playlist, the New Playlist picker, and the playlist row context menus on your profile and in Playlists (§19).
- **Eligibility:** Anyone is offered for a post or playlist only when `Provenance.isPublicEligible(viewer:)` holds for every quote: checked, or added by you with no "edited from".
- **Your profile:** the Posts header's static audience label, and View As, which becomes a `Menu` "View As" with **A Friend** and **Anyone with Your Username** (subtitle "As anyone sees it") (§10a).
- **Someone else's profile:** a stranger sees public items, and the empty line becomes "@alice hasn't shared anything publicly." (§10b).
- **Terms:** the Declared Age Range check runs after Accept, not inside the Terms sheet (§22).
- **Never:** Favorites. They offer only Only me and Friends, because favorites hold other people's quotes.
- **Revisit then:** whether the share image may name other people. Today it names only the person sharing it (§11).
