# Decision: new quotes in Reminders (LLM Council, 2026-10-26)

## Status

Recommended by the council, not yet approved by the founder. The design that implements it is `docs/new-quotes-in-reminders.md`. A second council pressure-tested that design; its verdict is at the end of this file.

**Trigger.** A TestFlight tester: "can you make it so it's not the same 5 quotes I select that repeat. I selected those cause I wanted the quotes to be in that genre but I want to be exposed to new ones. Adding quote doesn't work. Not the same ones if that makes sense."

**Reproduced on build 5.** After onboarding, every Library quote is in Reminders, so Reminders > "Add quotes" is disabled but looks enabled. Tapping it does nothing (`docs/reviews/2026-10-26-ux-audit.md`, F1). The Add sheet itself works.

**Supersedes** the API-based "Discover" option in `docs/decisions/2026-10-18-in-app-search-council.md`. New quotes come only from a verified catalog the founder owns.

---

## Chairman verdict

## Where the Council Agrees

- **No third-party quote API.** All five advisors reject API Ninjas and similar sources. Their attributions are unverified, and showing them next to a "verified" seal would wipe out the one thing that sets Quoted apart. New quotes come from a verified, public-domain catalog that the founder owns. This replaces the API option from the 2026-10-18 council.
- **New quotes have to arrive in the notifications.** A Discover tab doesn't reach users who have stopped opening the app. Four of five put new quotes straight into the Reminders notifications and the widget.
- **Reminders becomes a stream, not a closed playlist.** The tester's picks show their taste; they were never meant to be the whole list. New quotes are mixed in at about 1 in 3 slots, and each one appears once. "Keep" copies it into the Library. A quote that isn't kept leaves the rotation.
- **There is a negative signal as well as Keep** ("Not for me" or Skip), in three of five plans.
- **The 55 starter quotes the tester never picked are the first supply.** Nothing new has to be sourced before shipping.
- **The catalog is tagged by hand** with a small set of themes. No embeddings and no taste model.
- **"Adding quote doesn't work" probably means the dead end** where the picker says "Every quote is in your reminders" and only offers typing. Reproduce it before building anything (four of five).
- **Supply is the long-term limit.** The founder's verification hours decide how many new quotes the app can deliver.

## Where the Council Clashes

1. **Ask for the genre, or infer it?**
   - The Contrarian and the Outsider say ask: one screen where the user picks 2 or 3 moods. Five picks spread across Seneca and Emerson are too noisy, and inferring from them just applies the founder's tags.
   - The First Principles Thinker, the Expansionist and the Executor say infer it. The tester believes they already told the app: "I selected those cause I wanted the quotes to be in that genre." Asking again tells them the app wasn't listening.
   - Both sides have a point. Five picks are a weak signal, and an extra question adds friction.

2. **Keep and "Not for me" buttons on the notification itself in v1?**
   - The Executor wants Keep only in the full-screen view, to keep the build small.
   - The Contrarian and the Expansionist (and Reviewer 3) point out that people read quotes in the notification, and someone drifting away never opens the full-screen view.

3. **How big the catalog gets, and how.**
   - The Expansionist wants 1,000+ passages taken from Gutenberg texts the founder has already checked, plus premium packs.
   - The others want hand-verified quotes added at a steady pace: 20 a week (Executor), about 300 (Contrarian), 500+ (First Principles).
   - All five reviewers sided with steady hand verification. A passage pulled out of a long book is usually not a quote anyone would want in a notification.

4. **On by default, or a "Surprise me" setting the user turns on?**
   - The Contrarian prefers a setting, to protect users who built their playlist on purpose.
   - The others want it on by default. That is the only way the tester's problem gets fixed without them having to find a setting.

## Blind Spots the Council Caught

- **A fixed 1 in 3 doesn't fix this tester's problem.** With 5 picks filling 2 of every 3 slots, each pick still comes back about every two days. The app needs a minimum gap between repeats of the user's own quotes, and the share of new quotes has to change with the size of Reminders.
- **Nobody defined when a quote counts as "seen".** iOS doesn't report whether a notification was read, and the app replans about 60 notifications every time it opens:
  - If a quote counts as seen when it is scheduled, replanning uses up new quotes far too fast.
  - If it counts only when read, the same quote keeps coming back.
  - The fix: tie each new quote to a delivery time, keep that pairing when the app replans, and count the quote as delivered once that time has passed.
- **The record of what was delivered must live on the server** under RLS. Because accounts are anonymous, reinstalling the app loses it, the same way it loses the Library. Accept that for now.
- **Avoiding duplicates needs a link.** A Library quote copied from the catalog needs a `catalog_id`, so "unseen" can leave out quotes the user already owns.
- **The device has to keep a copy of each new quote's text.** The text goes into the notification when it is scheduled, and it must be stored where the widget and the full-screen view can read it, because these quotes are not Library rows.
- **Translations can be copyrighted.** Seneca and Marcus Aurelius are only safe in public-domain translations (for example Gummere for Seneca, Long for Marcus Aurelius). Verification has to record the translator.
- **A seal proves who wrote the words, not that they belong in a notification.** Mining books is not curating them, and where an excerpt starts and ends needs a check against its context.
- **Public domain sets a limit.** If the tester's "genre" is modern writing, an owned public-domain catalog can't serve it.
- **Existing users need a one-time notice** when new quotes start mixing into a playlist they built themselves.
- **No advisor proposed a way to measure success.** Track how often people keep new quotes, how often they choose "Not for me", and how often they tap the notification.

## The Recommendation

Build **"New quotes in Reminders"**. Reminders becomes the user's own picks plus a steady trickle of verified quotes they haven't seen. The new quotes match the themes of what they picked, arrive in the same notifications and widget, and each one has Keep and "Not for me".

**How the genre is known: infer it, and let the user edit it.**
- Tag every catalog quote by hand with 1 to 3 of seven themes: Courage and endurance, Calm and acceptance, Time and mortality, Love and friendship, Nature and wonder, Work and purpose, Solitude and the self. Author and work are stored as their own fields.
- The server works out each user's taste from what they already have and do:
  - each Library quote: +1 for each of its themes
  - each heart: +2
  - each Keep: +2
  - each "Not for me": −2
  - a bonus for authors the user already has
- Show the inferred themes in Reminders settings under "More of", already selected and editable. That answers the worry that five picks are noisy, without adding an onboarding question.
- Fill 1 in 4 new-quote slots from any unseen quote outside the top themes. If the app guessed the genre wrong, what the user keeps will correct it.

**Where new quotes come from: only a catalog the founder owns.**
- A `catalog_quotes` table in Postgres holding public-domain text checked word for word against Gutenberg or Wikisource. Each row stores the author, work, location in the work, source URL, themes, verified date, and the translator (required for translated works, which must be public-domain translations).
- Everyone can read it under RLS. Only the service role writes to it.
- It is seeded from the 60 starter quotes, which become rows marked `is_starter`.
- It grows by about 20 quotes a week, chosen from lines people actually quote. The source texts already checked serve as a list of leads, never as bulk extraction.
- No API, no scraping, no other users' quotes, no embeddings.
- Record this decision and update `docs/system-design.md`, replacing the API option from 2026-10-18.

**How new quotes reach the user: inside Reminders, on by default.**
- **Planner** (in `QuotedCore`, pure logic with unit tests):
  - The user's own quotes don't repeat within 48 hours when the pool allows it.
  - New quotes fill the slots that leaves open, with at least 1 in 3 slots and at most 1 in 2. If the two rules conflict, the 1-in-2 cap wins.
  - At 4 notifications a day that is about 14 new quotes a week, so 20 verified a week stays ahead. The 55 unseen starter quotes cover about four weeks before any newly verified quote is needed.
  - When the unseen pool runs out, the planner falls back to spaced repeats and Reminders says "You've seen every new quote. More arrive weekly." It never quietly loops again.
- **Getting quotes to the device:**
  - A server function, `fresh_queue(limit)`, returns the next 30 or so unseen catalog quotes for the user, ranked by their theme weights.
  - It leaves out anything already delivered, kept, dismissed, or in the Library. Library quotes are matched through `quotes.catalog_id`, which is filled in for existing starter copies by matching their text.
  - The device stores the full text in the App Group store, so notifications, the widget and the full-screen view work without a network connection.
- **Keeping delivery stable:**
  - Each new quote is tied to a delivery time, and replanning keeps those pairings.
  - A quote counts as delivered only after its time has passed. The app reports that the next time it opens or runs a background refresh.
  - Reports go to a `catalog_deliveries` table: `user_id`, `catalog_id`, `fire_at`, and a state of delivered, kept or dismissed. Each user can have only one row per quote. The owner is the only one who can read or write rows, with `with check (user_id = auth.uid())`.
- **Labeling:** new quotes show "New" and the verified seal in the notification subtitle, the full-screen view and the widget.

**What control the user has:**
- In Reminders settings, a "Mix in new quotes" switch, on by default. Existing users see a one-time notice the first time it applies.
- The editable "More of" theme chips.
- On every new quote:
  - **Keep** adds it to the Library and Reminders with its `catalog_id`, the same default as the Add sheet.
  - **Not for me** means it never comes back and lowers the weight of its themes.
  - Both buttons appear on the notification and in the full-screen view. On the notification they run without opening the app; the action is saved on the device and synced later.
- The dead end goes away. When every Library quote is already in Reminders, "Add quotes" shows unseen catalog quotes in the user's themes, with "Write your own" as the second option.

**How to measure it.** Use the `catalog_deliveries` table, with no analytics library: Keep rate, "Not for me" rate, and notification taps before and after build 6.
- A Keep rate above about 10% means the theme matching works.
- More "Not for me" than Keep means the tags are wrong.

**What ships first: build 6, in this order.**
1. The dead-end fix in the "Add quotes" picker.
2. The database migration:
   - `catalog_quotes` seeded with the 60 hand-tagged quotes
   - `quotes.catalog_id`, filled in for existing copies
   - `catalog_deliveries`
   - the `fresh_queue` function
   - pgTAP tests for the RLS on all of them
3. The planner changes, with tests for:
   - the repeat gap
   - the 1-in-3 minimum and 1-in-2 maximum
   - delivery times that stay put when the app replans
   - what happens when the pool runs out
4. On the device:
   - the stored copy of each new quote's text
   - the "New" label
   - Keep and "Not for me" on the notification and in the full-screen view
   - the one-time notice
5. Send build 6 to the tester.

**Left out of v1:** premium packs, a "read the whole letter" link, friends' hearts as a signal, buttons on the widget, and Verbatim.

## The One Thing to Do First

Recreate the tester's exact situation in the simulator: a fresh install with 5 starter quotes picked, then adding a quote through both the Add sheet and the Reminders "Add quotes" picker. That shows whether "Adding quote doesn't work" is a real save bug or the "Every quote is in your reminders" dead end. A broken core flow on TestFlight comes before everything else in this plan, and the answer decides whether build 6 starts with a bug fix or with replacing the empty state.

---

## Framed question

**Product:** Quoted, a native iOS 26 app (SwiftUI, Supabase backend), on TestFlight, pre-launch, built by a solo founder. Users save quotes (text, author, source, light formatting) to a Library. "Reminders" is an ordered subset of the Library (a playlist), delivered as local notifications several times a day (planned on device, about 60 at a time; iOS caps pending local notifications at 64), in order or shuffled. Home and Lock Screen widgets show the current reminder quote. Friends can share quotes into each other's inbox. As of yesterday, friends can opt in to see each other's hearted favorites.

**Onboarding:** a starter pack of 60 public-domain quotes (Emerson, Seneca, Marcus Aurelius, Dickinson, Shelley, Thoreau, Austen, Shakespeare and others). Each was checked word for word against a full text on Project Gutenberg or Wikisource, and they carry a "verified" seal in the app. The user picks some, and those are copied into the Library and Reminders. The starter quotes have no genre or theme tags. Later, "Pick from the starter pack" can add more of the same 60. Adding any other quote means typing it (or pasting).

**Tester feedback (verbatim):** "can you make it so it's not the same 5 quotes I select that repeat. I selected those cause I wanted the quotes to be in that genre but I want to be exposed to new ones. Adding quote doesn't work. Not the same ones if that makes sense."

Notes on "Adding quote doesn't work":
- It is ambiguous. It could be a bug, or it could mean "typing quotes myself isn't the answer".
- The Add sheet puts new quotes into Reminders by default.
- When every Library quote is already in Reminders, the Reminders "Add quotes" picker says "Every quote is in your reminders" and offers only "Add a quote", which means typing one.

**Constraints and past decisions:**
- Accuracy is the brand. The app keeps a list of famous quotes it rejected as misattributed.
- An earlier council (2026-10-18) deferred discovery until there was demand. It suggested a later "Discover" built either on one Supabase Edge Function calling a structured quote API (for example API Ninjas, cached in Postgres) or on a curated corpus the founder owns. It ruled out ever scraping web search results, and ruled out ever using other users' private quotes.
- Quotes appear in notifications, widgets and share images, so copyrighted modern text is a risk.
- The only allowed third-party dependency in the app is supabase-swift. Secrets live only in Edge Functions, and the server owns all data.
- Accounts are anonymous (one per iPhone).
- No push notifications in v1. Everything is scheduled locally on the device, refreshed when the app opens or during background refresh.
- A separate unapproved proposal, a daily quote puzzle ("Verbatim") with Save to Library, exists as a possible future discovery engine.

**What's at stake:** retention. The core promise is "the words that move you, delivered daily". If Reminders feel like the same five cards on a loop, people stop reading the notifications and then delete the app. The founder will build whatever the council recommends.

**Decide:**
- the best product solution for exposing users to new quotes in the genre or vibe they signaled, without breaking what makes Quoted trustworthy;
- how the genre is known;
- where new quotes come from;
- how they reach the user (into Reminders automatically? suggested? a separate stream?);
- what control the user has;
- what to ship first.

## Advisor responses

### The Contrarian

**Fatal flaw 1: the corpus is too small for any "discovery" to work.** Five quotes at about four notifications a day means each quote comes back daily. Ship all 60 starter quotes and you only buy about 15 days before they loop again. Discovery is a supply problem, and every option has to be judged by burn rate. If the verified pool can't stay ahead of what the notifications use up, "new quotes" is a two-week illusion.

**Fatal flaw 2: there is no genre.** The starter quotes have no tags, and five picks don't tell you a genre. Tagging 60 quotes yourself just turns your taste into categories, not the tester's. Don't build inference. Ask the user to pick two or three vibes in one tap.

**Fatal flaw 3: quote APIs kill the brand.** API Ninjas and similar sources are full of the misattributions you already keep a reject list for. Show one fake Einstein in a widget next to verified quotes and the seal means nothing. Anything unverified that goes into notifications is a brand risk.

**Fatal flaw 4: "suggested" quotes never get seen.** The notification is the product, and people who are drifting away don't open the app. A Discover tab that nobody visits fixes nothing. New quotes have to go into the locally planned notifications and be downloaded ahead of time, because background refresh is unreliable. Tapping one also has to open something real, so it needs a record that isn't in the Library.

**The question you're avoiding:** "Adding quote doesn't work" may be a real bug, or it may be the dead end where the Reminders picker says "every quote is in your reminders" and only offers typing. Reproduce it before building anything. A broken core flow on TestFlight matters more than discovery.

**My call:**
1. Fix or clarify the Add dead end first.
2. Grow the founder-verified, public-domain corpus to about 300, tagged by vibe.
3. Add a "Surprise me" toggle that mixes unseen verified quotes into Reminders, capped at about one in three.
4. Add Keep and Skip actions on the notification itself.

No API, no inference.

### The First Principles Thinker

**The question is wrong.** The council is being asked how to find quotes "in the genre". The real defect is that Quoted treats a sample of taste as the full set of things to deliver. The tester picked 5 quotes to show what they like, and the app took that as the complete playlist. A delivery app whose only supply is whatever the user brings will always loop. Genre detection does nothing about that.

**Rebuild from that:**

1. **Reminders should be a stream, not a closed playlist.** The user's own quotes are the anchor. A default "fresh" share of slots, about 1 in 3, delivers quotes the user has never seen. Each one appears once. A notification action, "Keep", copies it into the Library. A quote that isn't kept simply leaves the rotation. The dead end in the picker ("Every quote is in your reminders") is the closed design showing through.

2. **The genre is already known from the picks.** Don't ask the user to choose themes. Tag the corpus, not the user. The founder hand-assigns about 8 themes (endurance, mortality, love, nature, solitude, work, and so on). The user's picks, hearts, Keeps and skips weight those themes. The user never sees a taxonomy.

3. **New quotes should come from a curated corpus the founder owns.** A third-party API has unverified attributions. Mixing them in would quietly undo the verified seal, which is the only thing that sets Quoted apart. Every quote in the stream should be checked against Gutenberg or Wikisource, with no exceptions.

4. **Planning stays local.** The device fetches a batch of the next 60 or so unseen quote IDs from the server and caches them, so scheduling works exactly as it does now.

**Ship first:** the tester already has 55 unseen starter-pack quotes. Turn on the fresh-slot mix using those, add the Keep action, and hand-tag the 60. Most of this is client work, apart from a few theme tags on the starter data. In parallel, grow the verified corpus to 500 or more quotes; that work is the real product.

Separately, check whether "Adding quote doesn't work" is a real bug. Most likely it means typing quotes in isn't the answer.

### The Expansionist

**The verified corpus is the product here. Treat it as the moat.** The tester is asking for "more like these, but new." Most quote apps can't promise those new quotes are real. Quoted can, because its whole process is checking passages word for word against full texts. Grow the 60 starter quotes into an owned, tagged, verified corpus of 1,000 or more, and drop the API Ninjas idea. A third-party API would mix unverified text into the one thing that sets Quoted apart.

**Mine the source texts you already checked.** Seneca's Letters, Emerson's Essays and Thoreau's Walden are on Gutenberg in full. Each text verified for one quote holds hundreds more lines worth keeping, and every passage keeps its exact citation. That supports a "Read the whole letter" link: Quoted stops being a reminder tool and becomes a doorway into the books. Nobody else in this category offers that.

**Infer genre from what the user does.** Tag the corpus by author, work and theme (resilience, mortality, love, nature, solitude). Build each user's taste from their picks, hearts, keeps and skips. Authors and works are the strongest genre signals: "more Seneca" is something people actually say.

**Deliver new quotes through the notification itself.** Add a "Discover" mix to Reminders that is on by default, with about 1 in 3 slots filled by a fresh verified quote. Give those notifications "Keep" and "Not for me" buttons, so each one teaches the system without opening the app. Kept quotes go to the Library. The widget follows the same rules.

**Bigger plays to follow:**
- Themed packs ("Stoic Mornings", "Dickinson on Death") as the future premium tier. The text is public domain; the value is the curation and verification.
- Verbatim feeds the same corpus.
- Share images carry the seal and citation, and link back to the pack, which gives you a growth loop.
- With opt-in, friends' hearts become a "loved by your friends" signal.

**Ship first:**
1. A `corpus_quotes` table of about 500 tagged quotes mined from your existing Gutenberg sources.
2. Discover slots on by default.
3. The Keep and "Not for me" notification buttons.

Nothing more.

### The Outsider

The tester thinks they told the app a genre. The app never asked for one. They picked 5 quotes to mean "more like these," and the app took it as "only these, forever." That mismatch is the bug. Better content alone won't fix it.

From the outside, the setup is confusing. "Library", "Reminders" and "Starter pack" are the founder's words. To a normal person this is a daily quote app, and a daily quote app shows you something new each day. Nobody expects a playlist. With 5 picks and about 60 scheduled notifications, each quote comes back roughly 12 times. To the tester that looks broken, whatever the design intended.

"Adding quote doesn't work" is almost certainly the dead end, not a crash. They tapped "Add quotes", hoping to find new ones. They got "Every quote is in your reminders" and a blank text box. To the tester, that is the add button failing.

What I'd do:

1. **Ask the genre in plain words.** One onboarding screen: "What do you want more of?" with 5 or 6 moods, such as Courage, Calm, Love and loss, Work, Wonder. Don't try to infer taste from 5 Seneca and Emerson picks; they could signal anything. Hand-tag the 60 quotes with these moods.
2. **Make "mix in new quotes" the default.** Reminders delivers your picks plus unseen quotes in your moods, each marked "New". Each new quote gets two buttons: "Keep" (adds it to Library) and "Not for me".
3. **Fix the dead end now.** When everything is already in Reminders, show the unpicked starter quotes in your moods, not a text box.
4. **Grow the corpus, and own it.** 55 unpicked quotes last about two weeks at several a day. Users won't care where new quotes come from, only that they keep arriving. Keep verifying each one and add them in batches.

**Ship first:** mood tags on the 60, the mixed-in default with Keep and "Not for me", and the fixed empty state. All of it fits in one build.

### The Executor

**Monday morning: fix the dead end, then use the 55 quotes you already have.**

The tester picked 5 of 60 verified quotes, so 55 are already in the app and they've never seen them. You can fix most of the complaint this week without sourcing anything new.

**Day 1.** Reproduce "Adding quote doesn't work" in the simulator. Check two paths: saving from the Add sheet, and the Reminders picker that says "Every quote is in your reminders" and only lets you type. Treat that empty state as a bug. Replace it with "Get new quotes", which opens the starter pack and filters out what they already have. Also message the tester and ask what they tapped. It's one text.

**Days 2–3.** Migration: a `catalog_quotes` table with public read under RLS and service-role writes only. Seed it with the 60 and give each 1–3 theme tags by hand (stoic, nature, love, courage, solitude, mortality). That's about an hour of tagging. Infer the genre from the tags on the quotes they picked. Don't add an onboarding question.

**Days 3–5.** Add a setting in Reminders, "Mix in new quotes", on by default. The planner in `QuotedCore` is pure logic and easy to unit test. Have it fill about 1 in 3 slots with unseen catalog quotes that match the inferred tags, then fall back to any unseen ones. Mark these "New" in the full-screen view with a single "Keep" button that adds the quote to the Library. Leave notification actions out of v1. Ship build 6 to this tester.

**Ongoing.** The real constraint is your verification time. At about 5 minutes per quote checked against Gutenberg, 20 new quotes a week costs under 2 hours. Hold to that and the catalog doubles in about 3 weeks.

**Kill these for now:**
- The API Ninjas Edge Function. Its attributions are unverified, and that breaks the brand.
- The Verbatim puzzle. It has no first step that fixes this complaint.
- An embeddings or "vibe" model. Tags on 200 quotes are enough.

Nothing is left without a first step except the catalog growth rate, and that only depends on your hours.

## Peer reviews (anonymized; Response A = The Executor; Response B = The First Principles Thinker; Response C = The Outsider; Response D = The Contrarian; Response E = The Expansionist)

### Reviewer 1

**1. Strongest: A.** It is the only plan laid out day by day with honest supply math: about 5 minutes per verified quote, so 20 a week. It reproduces "Adding quote doesn't work" before building anything and treats the empty picker as a bug. It ships using the 55 unseen quotes already in the app, with no new sourcing. It cuts the API, Verbatim and embeddings. B has the best reframe (a stream, not a playlist), and A turns that reframe into a buildable plan.

**2. Biggest blind spot: E.** It never mentions the possible Add bug. Its "ship first" step is 500 mined quotes, which means weeks of solo verification before the tester sees any change. It also ignores D's burn-rate point. Pulling passages out of long texts brings context and boundary risks that the word-for-word check doesn't cover.

**3. What all five missed:**
- **The planner itself.** Five quotes fill about 60 slots because nothing limits repeats. Add a no-repeat window, and schedule fewer notifications when the pool is small. Decide what happens when the unseen catalog runs out, so it doesn't quietly loop again.
- **The public-domain ceiling.** An owned verified corpus can only hold text old enough to be public domain. If the tester's "genre" is modern, none of these plans can serve it. Check that before investing.
- **Measurement.** Track the Keep rate and the notification open rate to learn whether the change worked.

### Reviewer 2

**1. Strongest: A.** A is the only plan a solo founder could start on Monday. It reproduces the bug first. It turns the dead-end "Every quote is in your reminders" screen into "Get new quotes". It seeds a public-read `catalog_quotes` table from the 60 quotes and hand-tags them. It puts the mix in the pure `QuotedCore` planner, where it can be unit-tested. It also names the real bottleneck, which is verification hours (about 20 quotes a week), and gives reasons for dropping the API, Verbatim and embeddings. B frames the problem best: the app treats a sample of the user's taste as the whole playlist. A is the one that turns that idea into steps.

**2. Biggest blind spot: E.** E never mentions "Adding quote doesn't work." Its first thing to ship is 500 mined, tagged and verified quotes. That is weeks of a solo founder's time before the tester sees any change. Premium packs and growth loops are a distraction while the app is still on TestFlight.

**3. What all five missed:**
- **What "unseen" means and where it is recorded.** A delivered local notification is no proof the quote was read. The app needs a server-side record of what was delivered, kept and dismissed. With anonymous accounts (one per iPhone), that record is lost when the user reinstalls.
- **Existing users.** Turning the mix on by default quietly changes a playlist they built on purpose. It needs a one-time notice.
- **A success measure.** Nobody said how to tell whether this worked, for example the share of new quotes kept, or notification opens before and after.

### Reviewer 3

**1. Strongest: A.** A is the only response planned around one founder's week. It treats the Reminders picker's dead end as the bug and ships using the 55 starter quotes the tester has never seen. It also budgets verification time. At 4 notifications a day, a 1-in-3 mix uses about 9 new quotes a week. A's 20 verified quotes a week keeps ahead of that, which answers D's "two-week illusion". A's weak point is putting "Keep" only in the full-screen view. D is right that the notification is where people actually see quotes.

**2. Biggest blind spot: E.** E never addresses "Adding quote doesn't work". Its first step is mining 500 or more passages, which means weeks of curation before the tester sees any change. Lines pulled from Walden are not quotes people know. The seal proves who wrote a passage, not that it is worth a daily notification.

**3. What all five missed:**
- **A fixed 1-in-3 share does not fix this tester's problem.** With 5 picks filling 2 of 3 slots, each pick still comes back every two days or so. The fresh share should grow as Reminders shrinks, or each quote should have a weekly repeat cap.
- **New quotes need their own local cache.** Their text must be in the notification content when it is scheduled. It must also be in the App Group store for widgets and the full-screen view, because these quotes are not Library rows.
- **There is no success metric.** No response says how to measure whether the change works, for example the Keep rate or how often people open the app from a notification.

### Reviewer 4

**1. Strongest: A.** A is the only response that is an actual schedule. It reproduces the bug first, then fixes the dead end with the 55 starter quotes the tester never picked. It tags the 60 and fills 1 in 3 slots through the existing pure planner, then ships build 6 to the same tester. It names the real bottleneck, the founder's verification time at about 5 minutes per quote. It also gives reasons for dropping the API, Verbatim and embeddings. B gives the best diagnosis: the app treated a sample of taste as the whole playlist. A is the build that acts on it.

**2. Biggest blind spot: E.** E never mentions "Adding quote doesn't work". Its first ship needs 500 mined, tagged and verified quotes, which is 40 or more hours of verification before the tester sees any change. Taking passages from a book doesn't check their context or where each excerpt starts and ends.

**3. What all five missed:**
- **What "seen" means.** iOS doesn't report that a notification was read. The planner also replaces about 60 pending notifications every time the app opens. If quotes count as seen when they are scheduled, the pool runs out early. Count a quote as seen only once its delivery time passes, and sync that to the server under RLS.
- **Dedupe.** Library copies need a `catalog_id` link so that "unseen" leaves out quotes the user already has.
- **A quick stopgap.** Never repeat a quote within N days.
- **No success metric.** None of them proposes measuring keep rate or tap rate.

### Reviewer 5

**1. Strongest: A.** It is the only response that is ordered, costed and can start Monday. It reproduces the Add dead end first and messages the tester. It uses the 55 unseen starter quotes and limits fresh slots to 1 in 3. Its verification budget answers D's burn-rate worry: at about 5 notifications a day, the mix uses about 12 new quotes a week, and 20 verified a week stays ahead. B frames the problem best ("a stream, not a closed playlist", where an unkept quote leaves the rotation), and A should adopt that.

**2. Biggest blind spot: E.** It never addresses "Adding quote doesn't work". Its first step is 500 mined quotes, which ignores how much verification time the founder has. Mining is not curation: most lines in Walden are not quotable. It also skips translation copyright. Seneca and Marcus Aurelius are only safe in public-domain translations such as Gummere or Long.

**3. All five missed how "seen" works with local scheduling.** The app plans about 60 notifications ahead and replans every time it opens, but it never learns which ones were delivered or read. That causes three problems:
- If a quote counts as seen when it is planned, replanning burns new quotes. If it counts only once read, the same quote repeats.
- The fix is to tie each catalog quote to its fire date and keep that link stable across replans.
- Store the ledger on the server. Accounts are anonymous, so a reinstall wipes it.

Widgets and notification taps also need the text of catalog quotes stored on the device.

---

# Council 2: pressure test of the design (2026-10-26)

**Applied.** The design in `docs/new-quotes-in-reminders.md` was rewritten to follow this verdict:

- a stored slot plan;

- origin `catalog`;

- `withdrawn` status and the kill switch;

- the stricter seen rule;

- f = 1/2 for small libraries;

- notification actions, chips and exploration moved to build 7;

- the content gate;

- the snapshot reader accepting v1;

- the seal function rewrite and test updates.

The author checked the three code claims before applying them: `QuoteOrigin` decodes unknown values as `.manual`; `readSnapshot` rejects other versions; six pgTAP files reference `starter_quotes`.

## Chairman verdict

## Where the Council Agrees

- **The slot model as written cannot ship.** Four of five advisors found this; the Expansionist missed it. I checked it against the code. Today `ReminderPlanner.swift:138` keeps `old.anchor`. §5.3 instead sets `anchor = now` on every replan, while §5.2 decides fresh slots with `(o·p) mod q < p`, where `o` is counted from that anchor.
  - Once k slots have passed, every future `o` shifts by k. With f = 1/3, the set of fresh slots changes whenever k is not a multiple of 3.
  - §5.3's rule "drop bindings that are no longer candidates" then reshuffles the pending fresh notifications on almost every foreground.
  - The widget's second walk can disagree with notifications that were already delivered.
- **Ship step 1 now as build 5.1.** It is the fix for the dead end, and it does not depend on anything else.
- **The seal function must be rewritten in the same migration.** `private.set_verified_starter()` (migration `20261024090000`, line 126) names `public.starter_quotes`. It is plpgsql with `search_path = ''`, so the name is resolved when it runs. After the rename it would quietly read the filtered compat view and seal starter quotes only. The doc says the seal "now matches catalog_quotes", but nothing guarantees it, so a test has to.
- **Cut the notification actions from build 6.** They need a background launch, a delegate in place before launch finishes, and keychain access while the phone is locked. That is the riskiest code for the least-used path. Keep and Not for me in the full-screen view are enough to deliver N4.
- **Cut the "More of" chips and `my_theme_weights`.** The weights inferred from the Library are enough. The Outsider also showed that the chips can freeze inference for good.
- **Supply is the real constraint.** The first "new" quotes are the 55 starter quotes the tester already scrolled past in the picker, so N1's "never been shown" is not true for this tester.
- **6.5 days is not credible for the full scope.**

## Where the Council Clashes

1. **Slots versus a Library drip (the First Principles Thinker against the rest).** The drip is rejected. It adds unreviewed quotes to the user's own Library, and every one of them then repeats, which is the original complaint again, just slower. The First Principles Thinker is right that most of the complexity comes from N4. The answer is to store each slot's decision rather than drop N4.
2. **How to fix the desync: the Contrarian's `freshEpoch` or the Executor's stored decisions.** Stored decisions win. With an epoch, slots still reshuffle when the share changes, and the widget still has to repeat the walk. With stored slots, the widget just looks the slot up.
3. **Fork 3, whether the enum is closed.** The Contrarian, the Outsider and the doc say it is. The Expansionist says it is tolerant, and the Expansionist is right.
   - `Quote.swift:14-18` decodes unknown values as `.manual`. That code has been there since the initial commit (e691eb5), so builds 4 and 5 have it.
   - The premise in doc §2 and §10 is false.
   - One caveat: `QuoteRestoreRow` (`Rows.swift:136-171`) writes `origin` back on Undo of a delete. A build ≤5 Undo would therefore store a `'catalog'` quote as `'manual'`, which is cosmetic.
   - No code branches on `origin == .starter`. The only writer is `QuotesRepository.swift:175`.
4. **Fresh share (Contrarian and Outsider against the Executor).** The tester asked for "not the same ones". At 1/3, two of every three reminders are still those 5 quotes. Use 1/2 for small libraries.
5. **Whether to rename the table (the First Principles Thinker: don't rename, expire builds ≤5).** Rejected. Builds 4 and 5 select every row and order by `sort_order` (`StarterEventsAccount.swift:15`). New catalog rows would therefore show up in their onboarding. A filter is needed either way, and the security_invoker view is the cheapest one. Expiring a TestFlight build does not make testers update.
6. **The Expansionist's additions** (friend hearts, a Keep rate across all users, preferences on the server, an interactive widget): defer all of them. Friend hearts conflict with the consent ruling, and with a handful of testers the aggregate signals are noise. One idea is worth taking now: put the outbox's file model in QuotedCore so a later widget intent can reuse it.

## Blind Spots the Council Caught

1. **Corrections never reach devices** (reviewers 1, 2, 4 and 5).
   - A quote that is retired or found wrong stays in `fresh-queue.json`, in the bindings and in pending notifications for up to 60 slots, still showing the seal.
   - `retired` also keeps the seal for good.
   - "Rotated out" and "inaccurate" have to be separate states.
2. **`fresh_queue` excludes only rows already in `catalog_deliveries`** (reviewer 3).
   - Quotes that are cached or bound but not yet delivered come back on every refill. Because the ranking is stable, `refill(30)` returns the same 30 every time.
   - With n = 0 and f = 1, at most about 30 of the 60 slots can ever be bound. N6 fails.
3. **Version 1 snapshots do not "still load".** `AppGroupStore.readSnapshot` (`AppGroupStore.swift:73-77`) returns nil for any version other than the current one. After the update the widget stays blank until the app is opened.
4. **"Delivered" does not mean seen** (the Contrarian). If notifications are denied and there is no widget, a passed slot still uses up a quote for good.
5. **The pgTAP suite treats `starter_quotes` as a table.** Tests 00 (lines 11, 53, 79, 86, 163), 04, 06, 08, 10 and 14 all break on the rename, and the migration estimate leaves that work out.
6. **Build 5's `VerifiedQuoteSheet` resolves the seal through `StarterStore`**, which reads the filtered view. A kept non-starter quote shows the seal, but the sheet falls back to its offline text. Accept this and document it.
7. **There is no server-side kill switch** (reviewer 2). TestFlight builds cannot be recalled quickly.
8. **The tester's exact failure was never confirmed** (reviewer 4). The doc reproduced a dead end on build 5, not necessarily what the tester hit.

## The Recommendation

**The seven forks**

1. **Slot model: change.** Replace the phase arithmetic and moving anchor with a stored, fully resolved slot plan. Details are in change 1 below.
2. **Rename, compat view and reuse of `verified_starter_id`: keep.** Add the seal function rewrite, a `withdrawn` status and the test rewrites (change 3).
3. **Kept quotes stored with origin `'starter'`: change.** Use a new value, `'catalog'`, and widen `quotes_origin_valid`. Correct the false closed-enum premise in §2, §4.4 and §10.
4. **Preferences and seen state: keep the toggle device-local, and keep `catalog_deliveries` with the outbox and the strongest-state trigger.** Cut the chips, `my_theme_weights`, `ReminderSettings.themes` and the every-4th exploration rule. Add `p_exclude` to `fresh_queue`.
5. **Share rule: change.**
   - n = 0: f = 1.
   - 1 ≤ n ≤ 10: f = 1/2.
   - n > 10: the 48 h gap rule, clamped to 1/3..1/2.
   - For the tester (n = 5, 3 a day): 1.5 new quotes a day, and each own quote comes back every 3.3 days instead of 1.7.
6. **Notification actions: change.** Cut them from build 6 and move them to build 7 alongside widget App Intents. Tapping a fresh notification opens `quoted://new/<id>`, the full-screen fresh mode with Keep and Not for me. Keep the outbox, which a full-screen Keep needs when offline.
7. **Scope and sequencing: keep step 1 first as build 5.1, and change the rest.**
   - Build 6 does not reach the tester until a batch of at least 40 verified non-starter quotes has landed.
   - Re-estimate as about 5.5 engineering days, plus about 2 days of the founder's content work in parallel.

**Required design changes**

1. **Rewrite §5.2–5.3 as a stored slot plan.**
   - **The model:** `SlotPlan` in QuotedCore, persisted in snapshot v2. It holds:
     - `slots: [PlannedSlot { date, content: .own(UUID) | .fresh(catalogID) }]` for the 60-slot window;
     - the own-cycle cursor, a `RotationState` re-anchored at the first future slot whose `startIndex` advances by the number of own slots dropped;
     - `credit: Int`, a running counter in units of 1/q that decides when an appended slot is fresh;
     - the `f` the plan was built with.
   - **The replan, in order:**
     a. Drop slots with date ≤ now. Each dropped own slot advances the cursor by one. Each dropped fresh slot becomes a delivered event, subject to change 6.
     b. If the times, the days, the order mode, the mixing toggle or `f` changed, re-pattern every future slot. Reset `credit`, and fill fresh slots with the previously bound IDs first, in their original order, then from the queue.
     c. Otherwise keep every future fresh slot whose quote is still eligible: not kept, dismissed, non-live or in the Library. Fill an ineligible slot with the next queue item. If the queue is empty, it becomes an own slot.
     d. Append slots until the window is full. For each one, `credit += p`. If `credit ≥ q` and the queue has an item, the slot is fresh and `credit −= q`.
     e. Assign own quotes to every future own slot by walking the own cycle from the cursor. Rotation edits then apply immediately, as they do today.
   - **Delete** `(o·p) mod q`, "drop bindings that are no longer candidates", and "own ordinal = slot ordinal minus fresh slots".
   - **The widget** looks up the latest slot ≤ now in the stored plan, and falls back to the existing own walk past the end of the window. There is no second planner in the widget.
   - **Notification identifiers** stay date-based (`reminder-<epoch>`, `NotificationScheduler.swift:145`), which is already correct.
   - **Tests:**
     - a replan with no changes produces an identical plan;
     - for any k, after k slots pass, no surviving future fresh slot changes unless its quote became ineligible;
     - the widget lookup equals the notification for every slot;
     - the own repeat gap holds;
     - a re-pattern reuses the bound IDs in their original order;
     - exhaustion.
2. **Make `AppGroupStore.readSnapshot` accept versions 1 and 2.** A version 1 snapshot reads as a plan with no fresh slots, so the widget is not blank after the update.
3. **Migration (§4.1, §4.3).**
   - `create or replace function private.set_verified_starter()` against `public.catalog_quotes`, matching every row except `status = 'withdrawn'`.
   - `status` becomes one of three values:
     - `live`;
     - `retired`: out of the queue, seal kept;
     - `withdrawn`: inaccurate, out of the queue, seal removed. Withdrawing a quote re-runs the seal trigger on linked `quotes` and `shares` rows so their seal clears.
   - Widen `quotes_origin_valid` to include `'catalog'`.
   - `fresh_queue(p_limit, p_exclude smallint[])`:
     - excludes `status <> 'live'` and every ID in `p_exclude`;
     - has no exploration rule;
     - orders by theme score descending, then `is_starter` ascending (non-starter quotes first), then the per-user hash.
   - The client sends its cached and bound IDs as `p_exclude`, and requests `min(60, unfilled slots + 15)`.
   - Remove `my_theme_weights`.
   - Rewrite pgTAP tests 00, 04, 06, 08, 10 and 14 for the rename.
   - Add a test that runs, as `authenticated`, the exact build 5 starter select from `Rows.swift` and the order-by from `StarterEventsAccount` against the view. It also asserts that the view hides non-starter and non-live rows.
4. **Keep inserts `origin = 'catalog'`.**
   - Document in §10 that Undo of a delete on build ≤5 rewrites it as `'manual'`.
   - Add a glossary to `system-design.md`:
     - `is_starter` = the onboarding pack;
     - `verified_starter_id` = the catalog quote this text matches exactly;
     - `origin 'starter'` = picked at onboarding;
     - `origin 'catalog'` = kept from a new quote.
5. **Let corrections reach devices, and add a kill switch.**
   - At every online plan, select `id, status` from `catalog_quotes` for every cached and bound ID. Purge any non-live ID from the cache and from future slots; the replan then replaces the pending notifications.
   - Add a one-row `public.app_flags (mix_new_quotes boolean)` that authenticated users can read, with RLS on. When it is false, the client uses f = 0 and drops all future fresh slots.
6. **Seen rule.** A passed fresh slot counts as `delivered` only if one of these holds:
   - notification authorization was `.authorized` when the slot was scheduled;
   - a Quoted widget is installed (`WidgetCenter` current configurations);
   - the user opened the quote.

   Otherwise the quote goes back to the head of the queue.
7. **Share copy.** Update §5.1, the card caption ("About 1 in 2 reminders…") and the priming copy to the rule in fork 5.
8. **Move these to §12 (build 7):** notification actions, the "More of" chips, `my_theme_weights`, `ReminderSettings.themes` and the exploration rule. Keep the fresh subtitle `New · Author` and the deep link.
9. **Content gate.** Before build 6 goes to the tester, a batch migration adds at least 40 verified non-starter quotes, tagged with themes and passing `16_catalog`. This is founder time in parallel with the engineering.
10. **Put the outbox's Codable model and its file read and write in QuotedCore.** `FreshStore` stays in `App/Stores`.
11. **New §11 estimate:**

    | Step | Days |
    |---|---|
    | Migration and tests | 1.5 |
    | QuotedCore slot plan and tests | 1.5 |
    | App: `FreshStore`, full-screen fresh mode, toggle card, picker segment, notice | 1.5 |
    | Docs | 0.5 |
    | Verify | 0.5 |
    | **Total** | **5.5** |

    Content runs in parallel.

## The One Thing to Do First

Ship step 1 as build 5.1 now:
- Add quotes is never disabled;
- its empty state offers Pick from the starter pack and Write your own;
- the starter pack opens from Library's `+`.

It removes the reported dead end today with no server or planner risk. In the release note, ask the tester whether that was the "Adding quote doesn't work" they hit.

Before writing any Swift for build 6:
1. Rewrite §5.2–5.3 as the stored slot plan.
2. Write the invariant test first: a replan after k passed slots changes no surviving fresh decision.

Files checked: docs/new-quotes-in-reminders.md, Packages/QuotedKit/Sources/QuotedCore/Reminders/ReminderPlanner.swift, Packages/QuotedKit/Sources/QuotedCore/Models/Quote.swift, Packages/QuotedKit/Sources/QuotedCore/Widget/AppGroupStore.swift, Packages/QuotedKit/Sources/QuotedKit/Data/Rows.swift, supabase/migrations/20261024090000_verified_quotes.sql, App/Services/NotificationScheduler.swift

## Framed question

The founder of Quoted (iOS 26 SwiftUI + Supabase, solo, pre-launch, TestFlight) asked for the best implementation of "new quotes in Reminders", which an earlier council chose to fix a tester complaint: the same 5 starter quotes repeat; the tester wants new quotes in that genre. A full design document is at docs/new-quotes-in-reminders.md. READ IT FIRST (you may read files in the repo, e.g. Packages/QuotedKit/Sources/QuotedCore/Reminders/ReminderPlanner.swift, App/Services/NotificationScheduler.swift, supabase/migrations/20261024090000_verified_quotes.sql, docs/system-design.md). Do not edit anything.

Pressure-test the design, especially these forks where the author made a call:
1. Slot model: deterministic fresh candidates ((o·p) mod q < p), persisted bindings slotDate→catalogID in the App Group, re-anchoring the own cycle at every replan, widget runs the same walk from snapshot v2.
2. Renaming starter_quotes → catalog_quotes with a security_invoker compat view for builds ≤5, and reusing quotes.verified_starter_id (exact-text match) instead of a new quotes.catalog_id column.
3. Kept quotes stored with origin 'starter' to avoid breaking old clients' closed enum.
4. Preferences ("Mix in new quotes", "More of" themes) device-local in ReminderSettings, passed to fresh_queue(p_limit, p_themes); seen/kept/dismissed state on the server (catalog_deliveries) via an on-device outbox and a strongest-state trigger.
5. Fresh share rule from a 48 h repeat gap clamped to 1/3..1/2, and all-fresh when the user has zero own quotes in Reminders.
6. Notification actions (Keep / Not for me) handled with the app launched in the background, writing an outbox first.
7. Scope/sequencing: dead-end fix first (can ship alone), ~6.5 days total.

Stakes: this ships to real testers next; a wrong slot model desyncs notifications and the widget; a wrong migration breaks builds already on TestFlight; the catalog's accuracy is the brand.

## Advisor responses

### The Contrarian

**Fatal flaw: re-anchoring breaks the slot model (§5.2 + §5.3).** Fresh candidacy is `(o·p) mod q < p` with `o` counted from `RotationState.anchor`, and every replan sets `anchor = now`. So the phase moves by however many slots fired since the last replan. Take f = 1/3: one slot fires, the user opens the app, and the old o=3/6/9 bindings become o=2/5/8. They are no longer candidates, so §5.3 drops them and puts them back in the queue. Meanwhile the slot that was going to be own is now o=0 and turns fresh. A user who opens the app between reminders gets a new quote in almost every slot and almost never sees their own. The promise of "bindings stable across replans" fails on its most common path. The order of operations is also fragile: past bindings are "dropped once reported delivered", but the re-anchor walk needs them to count fresh slots since the old anchor. Fix: count candidacy from a separate `freshEpoch` (or from the slot's calendar date) that resets only when settings change. Never drop an eligible future binding.

**Product flaw: "new" means ones you passed on.** Build 6 has no days for content (§11), so the queue is the 55 starters the tester already scrolled past in the picker. At 7 a week that is about 8 weeks of quotes they chose not to pick. Ship with at least 40 verified non-starter quotes, budgeted as real days, or don't ship the feature.

**Share is too timid (§5.1).** With f = 1/3, two of every three reminders are still the 5 quotes the tester complained about. The gap only grows from 1.7 to 2.5 days. Default to 1/2 when n ≤ 10.

**"Delivered" doesn't mean seen.** A slot that passes with notifications muted, permission denied, Focus on, or no widget still uses up a quote for good (N1 says "never shown"). With a supply of 55, that loss matters. Mark a quote seen only on evidence: `getDeliveredNotifications`, a tap, or a spotlight view.

**Migration (§4.1).** `private.set_verified_starter()` refers to `public.starter_quotes` by name. If the rename lands without rewriting that body, the seal silently checks only against the filtered view. Rewrite it in the same migration and add a pgTAP test for it. Also note that build 5 `VerifiedQuoteSheet` falls back to its offline text for non-starter IDs. Acceptable, but say so in the doc.

**Concede:** reusing `'starter'` is right, because `QuoteOrigin` is a closed `Codable` enum. Background actions work, because supabase-swift's Keychain uses `AfterFirstUnlock`.

**Scope:** 2 days for FreshStore, notification actions, spotlight mode, card, chips, picker segment and notice is not credible. Cut the chips, the exploration rule and the notification actions from v1 (Keep from full screen only), and ship step 1 now.

### The First Principles Thinker

**The question is wrong.** The tester's complaint is "my Rotation is 5 quotes and I can't grow it." The design answers a different question: how to put a once-only feed into the reminder grid. Requirement N4, "Each new quote appears once," is the design's own invention. It is what drives most of the complexity: the fresh share (§5.1), the `(o·p) mod q` candidates, the bindings, re-anchoring on every replan, snapshot v2 with a second walk inside the widget, the background notification actions, and the outbox. Repeating a quote you might love is what the product does. Seeing the same 5 is the bug.

**Rebuild: "new" belongs to a quote, not to a slot.** Each day while mixing is on, the app takes the next taste-ranked catalog quote and inserts it as an ordinary Library quote. It goes in with `origin 'starter'` and in Reminders, with a local "New" badge. Everything after that is code that already exists:
- `RotationState.updated` already continues the cycle when members change.
- `WidgetSnapshot(library:…)` v1 already takes quotes from the Library.
- The seal trigger already links exact text.
- Keep is the default. "Not for me" removes the quote and records a dismissal.

The repeat gap fixes itself: after a week the tester has 12 quotes. Throttle the drip: stop adding when 7 "New" quotes are still unreviewed, so an ignored drip pauses on its own. At one a day, the 55 unseen starters last 8 weeks instead of 4, which eases the supply limit in §2.

**Fork 1** has real risk. Today the anchor is kept (`continuation`, line 138). The design makes it `now` at every replan. Correctness would then depend on anchor, `startIndex` and bindings staying in step across two processes. The rebuild avoids this entirely.

**Fork 2** is overbuilt. Builds ≤5 are TestFlight builds you control, so expire them when build 6 ships. Don't rename the table. Add `themes`, `is_starter` and `status` to `starter_quotes`.

**Fork 3:** fine as it is.

**Fork 4:** cut the "More of" chips, `my_theme_weights`, the every-4th exploration row and the −2 weights. With 55 quotes, ranking only changes the order. Keep the theme tags and weights from Library quotes. On the server, keep one dismissals table and nothing else; the Library already records Keeps.

**Forks 5 and 6:** the share math is no longer needed. Leave notification actions out of v1; tap opens the full-screen view with Not for me.

**Fork 7:** ship step 1 now, and point its empty state at the existing starter picker. That fixes most of the complaint today. The rebuild is about 2.5 days, not 6.5.

### The Expansionist

**What the design leaves on the table (Expansionist)**

1. **Fork 3 is based on a wrong premise, and the fix adds a feature.** `QuoteOrigin` in `Packages/QuotedKit/Sources/QuotedCore/Models/Quote.swift:14-18` has decoded unknown values as `.manual` since the initial commit (e691eb5). Builds ≤5 would not crash on a new value. Add `origin = 'catalog'` by widening the check constraint. Then the Library can show "Discovered: 9 kept", which proves to the user that the feature works. One check before shipping: the old clients' update payload must not write `origin` back.

2. **Friends are already a consented ranking signal.** `private.friend_favorites` returns `verified_starter_id` (favorites migration, line 68), gated by `shows_favorites`. §12 holds this back for "consent wording", but friends can already see these hearts. Add +2 in `fresh_queue` for catalog quotes a visible friend hearted, and show "New · Seneca · Sam loves this" in the notification subtitle. That is social proof and a reason to add friends, for about half a day of work.

3. **Use Keeps across all users, not only per user (§9).** A security-definer aggregate of the Keep rate per catalog quote should be the tie-break ahead of `hashtext`. Every tester's Keep then improves ranking for everyone. The Keep rate per theme also tells the founder what to source in the weekly batch. Supply is the budget, so point it at the themes people keep.

4. **Fork 4 leaves the taste profile stuck on one device.** Themes are Quoted's most valuable data, and the future features need them on the server: push or server scheduling (§12), a second device, and paid themed packs. Put `mix_new_quotes boolean` and `themes text[]` on `profiles`. That is two columns, not the table §10 rejected.

5. **Fork 6: put the outbox writer in QuotedCore, with `NSFileCoordinator`, not in `App/Stores`.** An interactive widget Keep (`Button(intent:)`) then takes half a day instead of a redesign. §10 itself says the widget and notifications reach people who stopped opening the app.

6. **Plan for success.** A user with no own quotes on 4 reminders a day gets f = 1, which is 28 new quotes a week. They exhaust the 55 unseen starter quotes in about 2 weeks, faster than the founder adds 20 a week. Cap fresh slots at about 14 a week whatever f is, so catalog growth stays ahead of what people use up and the N7 dead-end message stays rare.

I agree with forks 1, 2, 5 and 7 as written. Ship step 1 as build 5.1 now.

### The Outsider

**Outsider review: what a new engineer or user would misread**

1. **The slot model contradicts itself (§5.2–5.3).** Candidacy is `(o·p) mod q < p`, with `o` counted from `RotationState.anchor`. But every replan moves the anchor to `now`. Once k slots have passed, every future slot's `o` shifts by k. With f = 1/3, that turns over the whole candidate set whenever k isn't a multiple of 3. "Drop bindings that are no longer candidates" then throws out nearly every binding on every foreground, so "stable across replans" doesn't hold. A newcomer would build exactly what the doc says and ship the churn. Fix: fresh slots are the bound slots, and new candidates are picked only after the last bound slot, or counted from a fixed epoch that never moves. The doc also juggles three ordinals: slot ordinal, own ordinal and `PlannedReminder.ordinal`. Name them apart.

2. **The first month of "new" quotes isn't new.** For a 5-pick user, `fresh_queue` serves the 55 starter quotes the tester scrolled past and didn't pick. The doc's own §1 says the picker "offers the same 60". So N1's "never been shown" is false. Ship build 6 only after at least one non-starter batch, and rank `is_starter` rows last.

3. **"Starter" now means three things:**
   - `is_starter` = the onboarding pack;
   - `verified_starter_id` = any catalog quote;
   - `origin = 'starter'` = picked at onboarding (`QuotesRepository.swift:175`) or kept from a reminder.

   The next engineer will write `origin == .starter` meaning "chose at onboarding" and get it wrong. At minimum, add a glossary to `system-design.md`. Better: make the decoder tolerant of unknown values in build 6, so `'catalog'` can land in build 7.

4. **The chips can silently freeze the taste model (§7.1 vs §4.3).** The chips open with the inferred themes selected. If that selection gets saved to `ReminderSettings.themes`, `p_themes` is always sent. Inference then stops for good, including the −2 for dismissals. Store nil as "Auto" and save chips only after the user taps one.

5. **The cap of 1/2 goes against the doc's own premise.** If the picks are "a sample of their taste", why do they still fill at least half of all slots (two thirds for the tester)? The tester will read "1 in 3" as "still mostly my same 5". Treat onboarding picks as a taste seed, not as quotes to repeat.

6. **The snapshot claim is wrong.** `AppGroupStore.swift:75` rejects any `version != currentVersion`. Version 1 snapshots won't "still load" (§5.3), so after the update the widget stays blank until the app opens, unless that check is changed.

7. **"Not for me" is unclear on a lock screen.** It reads like "stop these notifications". "Fewer like this" is clearer.

### The Executor

**Verdict: ship it in two builds, and fix the slot model before writing any Swift.**

**1. The slot model (§5.2–5.3) has a desync bug.** Candidates are `(o·p) mod q < p`, with `o` counted from `RotationState.anchor`, and §5.3 moves the anchor to `now` on every replan. Say one slot fires and the app comes to the foreground. With f = 1/3, the old candidates o=3 and o=6 become o=2 and o=5. "Drop bindings that are no longer candidates" then reshuffles every pending fresh notification on every foreground. If bound slots are kept instead, as the §5.2 wording suggests, the share creeps up. Either way the widget's re-walk disagrees with notifications already delivered. Today's `continuation(of:)` keeps `old.anchor`; the design drops that guarantee.

Fix: store the decisions. Keep the 60-slot window in snapshot v2 as `[slotDate: .own(UUID) | .fresh(catalogID)]`. A replan keeps every future decision whose quote is still eligible. It only decides slots added after the last one, using a stored counter for 1-in-q. The widget looks the slot up and falls back to the own walk after the window. One invariant test covers it: a replan never changes a decided future slot unless its quote became ineligible.

**2. Keep the rename and the compat view.** It is the cheapest way to hide non-starter rows (null `sort_order`) from builds 4 and 5. One catch: the seal functions in `20261024090000_verified_quotes.sql` (lines 126, 152, 160) name `public.starter_quotes`. After the rename they quietly read the filtered view. Rewrite them in the same migration, and add a pgTAP test that runs the exact `Rows.swift` selects against the view. Known gap: if someone shares a kept new quote with a build-5 user, the seal shows but `StarterStore` can't find the quote. Acceptable, but test it.

**3. Reusing `'starter'`:** fine, costs nothing.

**4 and 5. Keep the share formula; it is pure and cheap.** Move the "More of" chips and `my_theme_weights` to build 7. Inferred weights are enough for one tester.

**6. Move the notification actions to build 7.** They need a background launch, the delegate set before launch finishes, and keychain access while the phone is locked. That is the riskiest code for the least-used path. Keep and Not for me in the full-screen view cover N4 for now.

**7. Monday:**
- By the afternoon, ship step 1 as build 5.1. "Pick from the starter pack" alone gives the tester 55 quotes in their genre they haven't seen.
- The founder confirms the Appendix A tags in parallel.
- Start the weekly batch now. Without it, the feature runs dry in about 4 weeks.

Build 6 is the migration, planner, `FreshStore`, full-screen view and toggle. About 5 days is a realistic estimate.

Files: `docs/new-quotes-in-reminders.md`, `Packages/QuotedKit/Sources/QuotedCore/Reminders/ReminderPlanner.swift`, `supabase/migrations/20261024090000_verified_quotes.sql`

## Peer reviews (anonymized; Response A = The Expansionist; Response B = The Executor; Response C = The Contrarian; Response D = The Outsider; Response E = The First Principles Thinker)

### Reviewer 1

1. **Strongest: B.** It finds the fatal slot-model bug. §5.3 sets `anchor = now` at every replan, which shifts every slot's ordinal `o`. Under the rules on lines 169 and 173, every pending fresh notification then gets reshuffled each time the app opens. B also gives the strongest fix: store each slot's decision, decide only newly added slots, and test that a replan never changes a decided future slot. C finds the same bug, but its `freshEpoch` fix still reshuffles slots when the share changes. B also notices that the seal functions refer to `public.starter_quotes` by name, and its build order is realistic.

2. **Biggest blind spot: A.** It accepts fork 1 as written, so it misses the desync, and then adds scope (friend boosts, a Keep rate across all users, server-side preferences). A is right that `QuoteOrigin` already treats unknown values as `.manual` (`Quote.swift:14-18`), which refutes C and D. But old builds' Undo of a delete (`Rows.swift:142-171`) would re-insert a `'catalog'` quote as `'manual'`. D is right that the version check at `AppGroupStore.swift:75` leaves the widget blank after the update until the app opens.

3. **What all five missed: retiring a quote doesn't reach the device.** The eligibility rule on line 167 ignores `status = 'retired'`. A quote pulled for a wrong attribution stays in `fresh-queue.json` and in pending notifications for about 15 days. Line 96 also keeps giving retired rows the verified seal. Fix: drop retired IDs from the cache and bindings at every plan. Also split retired (taken out of the new-quote queue, seal kept) from withdrawn (inaccurate, no seal).

### Reviewer 2

**1. Strongest: B.** B, C and D all find the re-anchoring desync: §5.3 moves the anchor to `now`, which shifts the `(o·p) mod q` phase. B goes furthest. It gives a concrete fix (store each slot's decision and only decide slots added at the end), one invariant test, and a sequence that can actually ship. Its migration catch also checks out: the seal functions at lines 126, 152 and 160 name `public.starter_quotes`. C comes close, but it states that `QuoteOrigin` is a closed enum. That is wrong. The decoder at `Quote.swift:14-18` has mapped unknown values to `.manual` since e691eb5, as A says. One caveat on adding `'catalog'`: `QuoteRestore` (`Rows.swift:134-171`, used by Undo) writes `origin` back, so a build-5 Undo would store `'manual'`.

**2. Biggest blind spot: A.** It accepts fork 1 as written and misses the slot desync that four other responses found. It then adds scope (friend signals, Keep rates across all users, preferences on the server) for a solo founder whose catalog has 55 unseen starter quotes.

**3. What all five missed: corrections to the catalog.** The brand rests on accuracy, and weekly batches will lead to fixes and retired quotes. Pending notifications (up to 60 slots) and the widget snapshot keep the old text with the seal until the app reopens. A kept copy matches by exact text, so after a fix it either silently loses its seal or keeps text that is now wrong. Nothing in the design invalidates bindings when a catalog row changes. There is also no server-side switch to turn the feature off.

### Reviewer 3

1. **Strongest: C.** It finds the re-anchoring desync, as B, D and E also do, and C works it through. With f = 1/3, a slot fires, the app opens, o=3/6/9 become o=2/5/8, the bindings drop, and the user gets almost all new quotes. C's fix is a `freshEpoch` that resets only when settings change. C also adds two points the others lack: "delivered" is not proof the quote was seen, and the first month of "new" quotes is the 55 starters the tester already passed over.

2. **Biggest blind spot: E.** It cuts N4 and replaces it with a drip into the Library. That brings back the original complaint: the Rotation grows, but every quote still repeats, so nothing is ever only new. It also fills the Library with unreviewed quotes. A is a close second: it adds social and global ranking on top of a slot model it calls sound.

3. **What all five missed:** `fresh_queue` excludes only rows in `catalog_deliveries`. Quotes that are bound but not yet delivered are not excluded. So `refill(30)` returns mostly quotes already bound, the queue looks empty mid-window, and N6 fails. With n = 0 and f = 1, at most about 30 of the 60 slots can be bound, and the rest have no own quotes to fall back on. The fix is `p_exclude` or a `bound` state.

**Correction:** `QuoteOrigin` already decodes unknown values as `.manual` (`Quote.swift:14-18`). So `'catalog'` is safe, and A is right about this. C's concession is wrong, and D's proposed decoder change is redundant.

### Reviewer 4

1. **Strongest: B.** B, C, D and E all catch the main flaw. §5.3 resets `RotationState.anchor = now` on every replan, so the `(o·p) mod q` slot phase shifts and pending fresh notifications get reshuffled. B is the only one that also gives a fix you can test: store the per-slot decisions in the snapshot, only decide slots added after the last one, and enforce one rule ("a replan never changes a decided future slot"). B also catches the seal functions that still name `public.starter_quotes`. C and D are wrong on fork 3. `QuoteOrigin` already decodes unknown values as `.manual` (`Quote.swift:15-18`), so `'catalog'` would not break old builds. D is right that `AppGroupStore.readSnapshot` rejects v1 snapshots, which the doc says still load.

2. **Biggest blind spot: A.** It agrees with fork 1, so it approves the desync bug. It also adds scope a solo founder doesn't need right now: friend-heart ranking, which goes against the consent ruling, global Keep rates and server-side preferences. A is right about the enum, though.

3. **What all five missed.**
   - **Retiring a quote doesn't reach devices.** Retirement doesn't clear the on-device queue cache, the bindings or the pending notifications. §5.3 only removes kept, dismissed or in-Library quotes. A misattributed quote can keep firing for up to 60 slots. Treat `retired` as ineligible and purge it on refill.
   - **Nobody reproduced "Adding quote doesn't work" on build 5.** Step 1 assumes it's the disabled button; if adding a quote actually fails, step 1 won't fix it.

### Reviewer 5

1. **Strongest: C.** It names the most serious bug, re-anchoring at every replan, and works it through to what the user sees. When the user opens the app between reminders, nearly every slot turns fresh and their own quotes stop appearing. C also points out that the "new" quotes are the 55 starters the tester skipped, that a delivered reminder is not proof it was seen, and that the seal function still names `starter_quotes`. One correction: B's fix is better than C's `freshEpoch`. B stores each decided slot and adds a test that a replan never changes a decided future slot. C is also wrong about the enum (see 2).

2. **Biggest blind spot: A.** A accepts fork 1 "as written". B, C, D and E all show that this slot model desyncs the notifications and the widget. A also proposes ranking by Keep rate across all users, which is noise with a handful of testers. A was right on one point: `QuoteOrigin` already decodes unknown values as `.manual` (`Quote.swift:14-18`). The doc's "closed enum" premise is false, and C and D repeated it.

3. **What all five missed: a path for correcting or retracting a quote.** The doc says "retired rows stay so old links and seals keep resolving." So a quote retired because it was wrong:
   - keeps the verified seal in every Library that kept it;
   - keeps being delivered from cached bindings for up to 60 slots while the device is offline.

   Fix: a retirement reason that separates "wrong" from "rotated out". A "wrong" retirement removes the seal and drops cached bindings at the next plan.
