# Design directions (agent rationales)

## Margin

**Direction:** Margin: editorial calm, light. Quoted looks like a well-set book page. The quotes are set large in Newsreader serif with plenty of white space, and everything around them is plain native iOS in the system font. The motif that names the direction is the margin itself. The ink-blue rotation dot sits in the left margin beside a quote, like a reader's pencil mark, and the Welcome quote's opening quotation mark hangs into that same margin. Attributions follow book style throughout: the author in small tracked uppercase, followed by the source in serif italic (MARY SHELLEY Frankenstein).

**Fonts:** Newsreader (Google Fonts, opsz 6..72; 400, 600, 400 italic): quote text, the 'Quoted' wordmark and source titles in italic; System UI stack (-apple-system, system-ui, sans-serif, which renders as SF Pro): all interface text; Type scale across all screens: 34 / 20 / 17 / 13 px. Weights: 400 and 600 only. No screen uses more than 4 sizes.

**Palette:** Ground #F8F8F6 (near-white). Surface #FFFFFF for cards and the editor page. Ink #16161A at 100% for headings and quotes, 80% for minor body text and 62% for secondary text, captions, authors and placeholders. Hairlines #E6E4DF. Fills such as the search field, stepper, segmented track and time pills use rgba(22,22,26,0.06). The single accent is ink-blue #2B44C9, used for the selected tab and its 8% tint, primary buttons (Sign in, Continue, Save, Accept, +), the rotation dot, toggles, starter checkmarks, day chips at a 12% tint, the 'courage' search highlight at 12%, and the outbound web-search link. Avatar initials use muted tints: Maya #F3E3DC/#8A3B1E, Jordan #DFEBE3/#2E6143, Sam #F2E8D0/#7A5410, Alex #E3E7F9/#2B44C9. All text pairs pass 4.5:1. The Widgets wallpaper is a flat two-tone block, #3D4966 over #343F58, with no gradient. Glass surfaces use rgba(255,255,255,0.72) with blur(20px), a hairline ring and a soft ink-tinted shadow.

**Rationale:**

What the user notices first on each screen:
1. Welcome: Mary Shelley's line at 34px serif, with the opening quote mark hanging in the margin. It shows what the app is for before asking for anything. The small wordmark and the promise "Keep the words that move you." sit above it. The email/password card, Sign in and "New here? Create account" are in the bottom third.
2. Starter: three filled ink-blue checks running down a quiet list of six quotes with hairlines between them. The whole row is the tap target. "Continue with 3 quotes" spans the bottom and Skip is a quiet nav-bar text button.
3. Library: the quotes themselves, with bold, italic and underline visible on Q4, Q1 and Q6. Ink-blue dots in the left margin mark the quotes in rotation; the "8 quotes / • In rotation" header explains them, and Whitman's quote has no dot. Above the list are the searchable field and a single "2 shared with you" row. Add is the one filled + in the top-right nav bar, and each row has one small share icon on its author line.
4. Search: the highlighted, bolded word "courage" in each result, grouped into "In your library" and "Shared with you (Jordan Lee · yesterday)". The last item is a quiet white card: globe icon, an ink-blue "Search the web for “courage” quotes" label and a ↗ arrow, so it reads as leaving the app without competing with the results.
5. Add: a large 34px serif "page" with Q4 typed. "Trust thyself" is bold and selected with native-style handles, and "iron string" is underlined, so saving feels like setting type rather than filling in a form. A glass bar sits at thumb height with B (active), I, U and a native Paste capsule. Author, Source (optional) and Add to rotation (on) are grouped in cards, and Save is the only filled button in the header.
6. Rotation: one settings card with the values in bold where they matter: the Reminders toggle, "3× a day" with a stepper, 8:00 AM – 9:00 PM time pills, and seven tinted day chips. Below it, "6 quotes" with an In order / Shuffle control, then numbered rows with reorder handles; four are fully visible and the rest scroll under the glass tab bar.
7. Friends: Sam's request, with a single filled Accept next to a neutral Decline. The profile entry is a glass pill in the nav bar (A · Alex · @alex), the usual place for Account, sign out and delete account. "Add by username" sits where Library's search does. Maya's shared Q2 card has a tinted Save and a "…" button for report and block, followed by the Maya and Jordan friend rows.
8. Widgets: the Quoted banner with Q6 in plain text, then white widgets that look like book pages on a dark two-tone wallpaper (medium: Q4 with "Trust thyself" in bold; small: Q7), among plain app-icon squares and a glass dock that holds the Quoted icon.

Why it fits "simple, clean, few buttons": each screen has at most one filled accent action, and the accent is used about 10% of the time, so the next step is always obvious. Navigation is three native tabs (Library, Rotation, Friends) in a floating glass pill that is identical on every screen. Everything maps to stock SwiftUI: large titles, .searchable, inset grouped cards, Toggle, Stepper, compact DatePicker, a segmented Picker, a sheet with a grabber, PasteButton, an AttributedString TextEditor with a keyboard toolbar, and List with onMove. Rotation status is shown by a dot in the margin, not by an extra control.

Self-check: all 8 files rendered at 390x844 with no unrendered holes or errors, before and after the fixes. After reading the PNGs I made four changes and re-rendered once:
- Add: aligned the sheet header's Cancel/Save with the 24px card edges.
- Starter: shortened the subtitle to one line.
- Widgets: grouped and vertically centred the quote and author in both widgets, and removed the redundant rotation dot from the medium widget.
- Widgets: balanced the notification text so "by." no longer sits alone on a line.

**Known issues:** 1. The brief conflicts on Q2. Search shows Q2 "In your library", while Friends shows Maya's Q2 with a Save action, so I treated them as two moments in time (before and after saving).
2. To fit everything above the tab bar, rows in the Rotation list show the quote on one truncated line and the author only (no source). The Search web-row label wraps onto two balanced lines because the exact wording does not fit on one line at 17px with both icons.
3. The small widget's "WILLIAM SHAKESPEARE" wraps onto two lines at 13px tracked uppercase.
4. Touch targets were kept at 44px or more by drawing the stepper, segmented control, time pills and toggles taller than stock iOS. The SwiftUI build can use native sizes and rely on the row hit areas instead.
5. The Rotation time-window row is labelled "Between" rather than "Time window" so the label and both pills fit on one line.
6. The selection end handle in the Add editor sits right against the colon after "thyself".
7. Day chips have no visible "Days" label; they are labelled for accessibility only.

## Daily

**Direction:** Daily: one quote at a time, card-first. The app opens on today's quote as a big tinted card, not on a list. Every quote is a soft-tinted card the user collects, and the same card language runs through onboarding, Today, search results, shared items, the Add editor (which looks like the card it will become) and the widgets. Navigation is a floating glass pill with three tabs (Today, Library, Friends) and a separate circular glass "+" for Add, all on a white ground with a single coral accent.

**Fonts:** Figtree 400/600 (UI: titles, rows, buttons, captions); Fraunces 400, 400 italic, 600 (quote text and the 'Quoted' wordmark; bold runs use 600)

**Palette:** Ground #FFFFFF. Ink #1F1A17, with body text at 80%, secondary at 66% on white and grouped fills, and 72% on tinted cards so it passes 4.5:1. Grouped-list fill #F7F5F2. Control fill #EBE6E1 and search-field fill #F2EEEA. Hairlines are ink at 6-10%. Card tints, chosen per quote: sand #F3EBDD (Q4), blush #F6E3E1 (Q1, Q7), sage #E3EDE4 (Q3), sky #E1ECF6 (Q2, Q5), lilac #ECE6F4 (Q6, Q9). There is one accent, coral #C63F24, used only for primary buttons (Sign in, Continue, Accept), Save in the sheet, the selected tab, the "+" glyph, toggles that are on, the selected day chips, the active Bold button, the active page dot and the selected-card ring. White on coral measures 5.07:1. The glass bar is rgba(255,255,255,0.72) with blur(20px), a hairline border and a soft ink-tinted shadow. Card shadows are tinted with each card's own hue. The Add sheet backdrop is a dimmed #A5A3A2. The widget wallpaper is a flat deep sage, #3A4A41. Type scale: 34/41 for large titles, hero quotes and the wordmark; 22 for compact cards (Welcome, medium widget); 17/24 for body and list quotes; 13/18 for captions and tab labels. Screen 8 also uses 15 for notification text. No screen uses more than 4 sizes or more than 2 weights.

**Rationale:**

What you notice first on each screen:
1. Welcome: a stack of quote cards with the Q1 card on top ("Today's card", with fearless in italic), under the Quoted wordmark and the line "Collect the words that move you." Sign in is a coral capsule in the thumb zone; Create account sits under it as plain text.
2. Starter: the three selected cards (Q4, Q1, Q6), each with a coral ring and a check badge, in a two-column card grid. These are the same three quotes that open the Rotation, so the setup carries straight into the app. "Continue with 3" is at the bottom and Skip is small at top-right.
3. Home (Today): the big sand card holding Q4, with "Trust thyself" bold, set at 34pt and taking about 54% of the screen.
   - The card's caption "In Rotation · 1 of 6" and its page dots show rotation membership.
   - A share button sits on the card.
   - Under the card is the "Next reminder 8:00 PM" chip, which opens Rotation.
   - Below that is an "up next" shelf with Q1 (fearless in italic) and Q6 (life underlined), plus a sliver of the next card. Add is the glass "+" beside the tab bar.
4. Search: the two tinted result cards, with "courage" highlighted. The last row is a quiet white outlined row with a globe icon, the label "Search the web for “courage” quotes", the Google caption and an arrow pointing up and out. It reads as leaving the app but carries less visual weight than the results.
5. Add: the editor is the card itself, at the same size and tint as Today, so saving feels like making a card. Q4 is shown with "Trust thyself" bold (selected) and "iron string" underlined. A B / I / U glass bar (Bold active) and a Paste capsule sit at the bottom for the thumb. Author and Source are a grouped form, and color is picked by tapping one of five swatches. "Add to Rotation" is on.
6. Rotation: one grouped block holds the reminder toggle, the "3 times a day" stepper, the 8:00 AM to 9:00 PM window and seven day chips. Below it are a full-width In order / Shuffle control and the numbered list, where each row has a tinted mini-card thumbnail and a reorder handle. Four rows are fully visible and the fifth scrolls under the glass bar.
7. Friends: Maya's shared Q2 card, with Save and a "more" button for report/block. Above it is the Alex (@alex) profile row that leads to Account. Below it is one grouped list: Add by username, Sam's request (Decline as text, Accept in coral), then Maya and Jordan.
8. Widgets: the widgets are the same tinted cards (sand medium with Q4, blush small with Q7) on a flat dark wallpaper. The notification above them shows Q6 in plain text with a coral app icon.

Why this fits "simple, clean, few buttons":
- Each screen has one hero card and at most one coral action. The quote is always the loudest thing on screen.
- Color carries meaning (each quote's own tint) instead of chrome.
- Everything maps to native SwiftUI: TabView with an overlaid glass button, a horizontal paging ScrollView, .searchable, sheets with a grabber, Form or inset-grouped List with .onMove, Toggle, Stepper, compact DatePicker, a segmented Picker, PasteButton, and a keyboard toolbar.
- The card a user sees in the app looks the same in onboarding, widgets and sharing, so there is one thing to learn.

**Known issues:** 1. Fields are left empty on purpose. The Welcome email and password fields show placeholders only, and the Add sheet's editor card keeps about one line of empty room below Q4 for more typing.
2. Three controls go beyond a stock component:
   - The "+" beside the tab bar needs an overlay or a search-role Tab to place it there.
   - The Starter check badge overlaps the card corner (an overlay with an offset).
   - The Search web row uses balanced wrapping (CSS text-wrap: balance), which SwiftUI does not do on its own. The title will wrap at a natural point instead.
3. Two touch-target compromises:
   - Toggles are drawn at the native 51x31.
   - The stepper and time pickers are 36pt visually but have 44pt tap areas.
4. On the Rotation screen, rows 5 and 6 scroll under the glass tab bar, so their text shows faintly through the blur.
5. The screen 8 notification is set in Figtree to stay within the two-font limit. On a real device it would render in SF Pro.
6. I did not touch canvas.json or any other direction's files.

## Nocturne

**Direction:** Nocturne: a dark app built on bold type and very little chrome. Quotes are set in big confident text on near-black cards. Amber #FFB547 is the only accent and marks just three things: the main action, what is in rotation, and the selected tab. Navigation is the iOS 26 floating glass pill with two tabs (Quotes, Friends) plus the separate round search tab at the bottom right, so search sits under the thumb. An amber "+" (Add) is at the top right of the nav bar. Every screen shares one set of parts: 24px-radius surface cards, inset grouped rows, 13px section headers at 64% opacity, the same tab bar, and large titles at y=98.

**Fonts:** Schibsted Grotesk (Google Fonts; 500/700, roman + italic): quote text, large titles, wordmark; System UI stack (-apple-system, system-ui, sans-serif = SF Pro): all UI chrome

**Palette:** Ground #0C0C0E; surface #161619 (cards, grouped lists, sheet); elevated #1E1E22 (fields inside the sheet, icon chips); ink #F5F5F4 at 100% for headings and quotes, rgba(245,245,244,0.80) for icon buttons, 0.64 for secondary text and labels, 0.56 for placeholders; hairlines rgba(255,255,255,0.08), glass edges 0.12. Glass (tab bar, search field, format bar): rgba(30,30,34,0.72) with blur(20px). Accent: amber #FFB547 with #1A1206 text on amber fills, and amber at 12-16% opacity for tinted chips (rotation icon tile, Save, day chips, active Bold). Shadows are tinted near-black, rgba(4,4,8,0.56). Avatars are flat pastel circles with dark initials: Alex #F2A7A0, Maya #7CCFB8, Jordan #8FB0FF, Sam #C6A6FF. The Widgets wallpaper is a flat two-tone block: #1C1F28 on top, #13151B from y=544 down.

**Rationale:**

What the user notices first on each screen:
1. Welcome: a 34px Mary Shelley line with "fearless" in italic, so the product is shown before it is explained. The amber "Sign in" capsule and labeled Email and Password rows sit in the bottom third, with "Create account" as a plain text button.
2. Starter: the three amber check circles on a single inset list. "Continue with 3 quotes" stays in the thumb zone and "Skip" is quiet at the top right.
3. Home (Quotes): the amber "+" and the pinned "6 quotes in rotation · 3× daily · Next at 8:00 PM" card. The quote cards below are never truncated: 22px grotesk with bold "Trust thyself", italic "fearless" and underlined "life". The amber rotation icon from the summary card is repeated next to the author on each quote in rotation. Q8 (Whitman) has no icon, so the difference is visible. Each card has one share button.
4. Search: the field with "courage" sits at the bottom where the search tab puts it, and the match is set in amber bold inside Q2 (In your library) and Q9 (Shared with you, from Jordan). The last row is a neutral card with an amber globe and an up-right arrow plus the Google caption. It reads as an outbound link but stays quieter than the results.
5. Add: the quote being typed, at 22px, with the Save capsule as the one amber button (the moment of saving). B / I / U (Bold active) and the native-style Paste capsule share one glass bar where the keyboard toolbar would be. Author and Source are grouped rows, Source marked "Optional", and "Add to rotation" is a switch that is on.
6. Rotation: the schedule controls, with values louder than labels: 3× a day with a stepper, 8:00 AM to 9:00 PM time capsules, and 7 day chips. The In order / Shuffle segmented control sits on the list header it affects. Four full rows are visible, each with a number, the formatted quote, the author and a reorder handle; rows 5 and 6 scroll under the glass bar.
7. Friends: Sam's amber "Accept", the only filled accent on the page. Above it are the profile entry (Alex, @alex · Account) and the Add by username row. Below are Maya and Jordan, then Maya's shared Q2 with a tinted Save and a "⋯" button for report and block.
8. Widgets: a glass banner with plain-text Q6 and the Quoted icon, then black widgets in the app's own type (medium Q4 with bold, small Q7) next to plain placeholder icons and the amber app icon.

Why this fits "simple, clean, few buttons": each screen has one amber primary action. Everything else is ink at different opacities, so the next step is always obvious. The whole app has only two tabs plus search, and search is in reach of the thumb. Every control maps to a stock SwiftUI piece: NavigationStack large titles, Tab(role: .search), a toolbar button with .glassProminent, Form/List inset grouped rows, Toggle, Stepper, Picker(.segmented), DatePicker(.compact), PasteButton, a ToolbarItemGroup(placement: .keyboard), and sheet detents with a drag indicator.

Type and grid rules: at most 4 sizes per screen (34 / 22 / 17 / 13), two weights (500 / 700), and an 8-pt grid.

Self-check: every artboard renders at 390x844 with no unrendered holes and no errors. I checked each PNG, fixed what I found and re-rendered: the quote glyph looked like "66", Sam's row wrapped, the small widget's attribution wrapped badly, and content showed below the tab bar. The renders were clean after the fixes.

**Known issues:** Schibsted Grotesk was chosen over Space Grotesk, Bricolage and Sora because those three have no true italic, and italic is one of the app's formatting options. The tab bar labels use 13px, not the native 10pt, to stay within 4 font sizes. Controls with a 44px touch target draw a smaller 32–36px visual capsule using a transparent border and background-clip, so in SwiftUI they map to native control sizes with contentShape padding. The small widget shows the attribution on two lines ("William Shakespeare" / "Hamlet") because "William Shakespeare, Hamlet" does not fit in 158pt. The Search field has no drawn caret because the input is shown unfocused. On Home and Rotation the content is cut off at y=812 behind the glass tab bar instead of being drawn through the home-indicator area. The Welcome hero's italic "f" hangs about 3px to the left of the text edge.
