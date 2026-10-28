# Quoted: practice, by-heart count and quote book (plan)

Status: proposal, 2026-10-26. Not approved, nothing built. Owner: hwei.

- **Research:** `docs/research/2026-10-26-practice-streak-quote-book.md`. Desk research only, with the 12 decision-critical numbers fact-checked.
- **Decision record:** `docs/decisions/2026-10-26-practice-streak-quote-book-council.md`.
- **Builds on:** Recall in `docs/quote-game.md` §5.2, the catalog design in `docs/new-quotes-in-reminders.md`, and favorites and profiles (shipped 2026-10-25).

## 1. The answer

**Viable as a feature set inside Quoted. Not viable as a new platform or a standalone business.**

| Question | Answer | Evidence |
|---|---|---|
| Is there a market? | Yes, but the paying part is small. Passive quote feeds are huge and paid for mostly by ads. The apps for memorising short text get real use but each earns under $10K a month (est.). Readwise proves people pay $67 to $120 a year to review text they saved themselves. | Research §1, §8 |
| Is the gap real? | Yes. No general quote app combines practice on your own lines, a forgiving habit signal, a finished quote book, and checked wording. The Bible Memory App does all of it, but for scripture only. | Research §3, §4 |
| Who first? | People who save lines and have tried to learn one by heart in the past year. Recruit in Stoic and self-improvement communities, and test English-literature and poetry readers alongside them (their lines need no translation caveat). | Council ruling 6 |
| What kills it? | Distribution, not the product: 83% of new subscription apps never reach $1K a month within 2 years, and the median app earns about $72 a month one year in. After that: practice that feels like homework, streak nagging, and billing distrust. | Research §1, §9.3 |
| Realistic outcome | A small, durable indie app. Low thousands to low tens of thousands of dollars a year in the base case. | Research §8.2 |

## 2. What to build from your idea

| Your piece | Decision | What it becomes |
|---|---|---|
| **Practice** | Build first. This is the bet. | "Know it by heart": at most 3 lines a day, under a minute, typing the first letter of each word. The full line shows after every attempt. Lines come back on a spaced schedule. Section 4. |
| **Gather** | Already built. Keep it free forever. | Library, Reminders, widgets, sharing, favorites. Build 5.1 fixes the "Add quotes" dead end. Build 6 mixes in new verified quotes (`docs/new-quotes-in-reminders.md`). |
| **Streak tab** | Cut. No new tab. | A **By heart** count that only goes up, and a row of dots for this week, both inside Practice. Nothing resets, and no notification ever mentions it. Section 5. |
| **My own quote book** | Build third. | An on-device PDF made to be given: a title page, a dedication, a "Known by heart" section, and every line with its source and a **Verified** or **Yours** label. No printing yet. Section 6. |

**Why the streak tab goes:**
- The research shows that a broken streak makes people engage *less* afterwards (Silverman and Barasch, 2023, 7 studies).
- "Streak anxiety" is the top complaint in I am's low-star reviews.
- Duolingo's streak gains come from company A/B tests on a game people open for other reasons.

A count that only grows gives the same sense of progress without the shame.

## 3. Order of work

| Step | What | Code? | Est. |
|---|---|---|---|
| 0 | **Build 5.1**: the Add-quotes dead-end fixes (finishing in a separate session) | done or nearly | 0 |
| 1 | **Validation test**, 2 weeks (section 7). Runs alongside step 2. | no | founder time |
| 2 | **Build 6**: new verified quotes in Reminders, already designed. Gated on at least 40 new verified quotes. | yes | 5.5 days + content |
| 3 | **Practice** with the by-heart count (sections 4 and 5), if the test passes | yes | about 7 days |
| 4 | **Sign in with Apple** (account linking) before Practice reaches the App Store. A by-heart record raises what a lost phone costs. | yes | about 4 days |
| 5 | **Quote book PDF** (section 6) | yes | about 3 days |
| 6 | **StoreKit 2** paid tier (section 8) | yes | about 4 days |

**Parked:**
- printing;
- group books;
- a public quote-checker page;
- the Verbatim daily puzzle;
- a Practice tab;
- breakable streaks.

**If the test fails:** follow the decision table in section 7. The main branches are "book leads" and "fix distribution first".

## 4. Practice ("Know it by heart")

### 4.1 How it feels

- **Entry:** a card pinned at the top of Library, "3 lines to know by heart", with a Start button. It appears only when lines are due. It also opens from the Practice widget and from an opt-in reminder. There is no new tab.
- **One line at a time, three stages.** A line moves up a stage as the user gets it right:
  1. **Read and type:** the full line shows, and the user types the first letter of each word.
  2. **First letters:** only the first letters show ("T t: e h v t t i s"), and the user types them from memory.
  3. **From memory:** only the author and source show.
- **Feedback after every attempt.** A wrong letter fills in the right word, in place, in the accent colour. Then the full line shows with "Got it" or "Not yet" (the app decides; the user can override "Not yet" once).
  - A miss reads "Not yet", never "Wrong".
  - The success haptic plays once per line.
- **Cap:** 3 due lines per session. Overdue lines roll forward instead of piling up.
- **Which lines:** Reminders lines first, then favorites, then the rest. Any line can be left out ("Don't practise this" in its menu).
- **The words:** the UI says "Know it by heart" and "By heart", never "study", "drill" or "practice session".

### 4.2 Why typing first letters

- It is the Bible Memory App's method: fast, objective, and it ignores punctuation, capitals and spacing.
- Speech grading is the most complained-about mechanic in Verses.
- Self-graded cards (Anki) feel like homework.
- Retrieval with feedback roughly doubles the benefit over rereading on delayed tests (research §9.1).

### 4.3 Scheduling

Leitner boxes, as in `docs/quote-game.md` §5.2:
- a line comes back after 1, 3, 7, 14, then 30 days;
- a line answered right moves up a box, and a miss drops it to box 1;
- a line that clears box 5 is **known by heart**: the Library row gets a small glyph, and the detail screen says "You know this by heart".

### 4.4 Engineering

**QuotedCore** (pure, unit-tested):

| Type | Job |
|---|---|
| `RecallTokens` | Splits a body into words in UTF-16 offsets, per the rich-text contract. Keeps punctuation attached for display, and takes each word's first letter (or digit) after `SearchIndex.fold`, so case and diacritics don't count. |
| `FirstLetterGrader` | Compares a typed letter sequence with the tokens. Returns per-word correct or wrong, and a score. Unit tests cover poems with line breaks, apostrophes ("we'll"), hyphens, em dashes, numbers, non-Latin text (skipped) and very long quotes (capped at 280 characters for practice). |
| `Leitner` | Box and due-date arithmetic, mirrored exactly in SQL. |
| `RecallCard` | The card model. |

**Server** (one migration, pgTAP file `19_recall.test.sql`):
- **`recall_cards`** columns:
  - `quote_id` (primary key, `quotes on delete cascade`);
  - `owner_id` (default `auth.uid()`);
  - `box` (1–5);
  - `due_on` (date);
  - `reps`, `lapses`;
  - `known_at`;
  - `excluded`;
  - `updated_at` (server clock).
- **RLS:** owner only, `with check`.
- **Writes** go through `public.record_recall(p_quote_id, p_correct)` (SECURITY INVOKER). It computes the box and due date on the server, so the client can't skip boxes. Limit QR001: 200 a day.
- **Trigger:** editing a quote's body resets its card to box 1 and clears `known_at`, because the words changed.

**App:**
- `PracticeStore` (`@Observable @MainActor`). It works offline from the cached Library, and queues answers in the App Group outbox. That outbox is the same QuotedCore outbox model as build 6 (`docs/new-quotes-in-reminders.md` §6).
- `Features/Practice/`: the Library card, the session view and the result view.

**Reminders hook (opt-in):**
- "Know it by heart sometimes" in the Reminders screen. About 1 slot in 5 becomes a first-letter cue for a due line.
- This adds a third slot type, `.recall(UUID)`, to build 6's stored slot plan.
- Tapping it opens the card in Practice.

**Widget:** a "Finish the line" family shows the first letters of the next due line, and a tap opens it. Widgets can't take typed input.

**Docs:** system-design (F12, `recall_cards`, RPC), ui-spec (§5 Library card, a new Practice section), app-architecture (store, routes), privacy (practice records: linked to the account, deleted with it).

**Estimate:** QuotedCore with tests 1.5 days, migration with tests 1 day, store and UI 2.5 days, Reminders and widget hooks 1 day, docs and verification 1 day. About 7 days.

## 5. The By heart count (replaces the streak tab)

- **Inside Practice:** the "By heart" number (lines that cleared box 5), and a row of 7 dots for this week (filled on days with at least one line reviewed).
- **Only goes up:**
  - a known line that later slips back to box 1 stays counted, with its glyph dimmed until it clears again;
  - the week dots reset each Monday by design, so a quiet week can't be "lost".
- **The friend profile** can show "Knows 12 lines by heart" when the user turns on "Show favorites to friends". That links the count to the social feature you already have.
- **Never:**
  - a streak number that resets;
  - a notification about a missed day;
  - a paid repair.

  If the Verbatim daily puzzle ever ships, its streak follows `docs/quote-game.md` §8: it counts days finished, not won, and uses "Bookmarks" as freezes.

## 6. My quote book (on-device PDF)

**What it is.** Library > `+` menu or Account > **Make a quote book**:
1. A sheet asks for the title ("Lines I Keep"), an optional dedication ("For Mum"), which lines (Favorites / Known by heart / All / pick by hand) and the order (by date / by author).
2. A preview shows.
3. Share opens the system share sheet with the PDF.

**Pages.**
- Title page, then the dedication, then "Known by heart" first, then the rest.
- One to three lines per page in the hero serif, each with author, source and its label:
  - **Verified · Long translation, Book II §1**, with the named edition, for catalog lines;
  - **Yours** for the user's own lines.
- A small colophon on the last page: "Made with Quoted".
- Light theme, A5 and US Letter.

**How.**
- SwiftUI page views rendered with `ImageRenderer.render(rasterizationScale:renderer:)` into a PDF `CGContext`. The API is checked in the iOS 26.5 SDK, and Quoted already uses `ImageRenderer` for share images.
- Vector text, no server, no new dependency.
- The rich-text runs (bold, italic, underline) come through `QuoteText`.

**Rules.**
- The book is a personal export, like "Share as text". Nothing is uploaded.
- Printing (a vendor, addresses, copyrighted modern lines) waits for real demand and a copyright check.

**Estimate:** about 3 days, including Dynamic Type-independent page layout and tests for pagination.

## 7. Validation test (2 weeks, no new code)

The council's version supersedes research §11.4. Write the thresholds into `docs/decisions/` before Day 0.

**Before Day 0:**
- Collect 20 Stoic lines that strangers post and note which translation each one uses. If 10 or more are in-copyright translations, lead the Stoic pitch with "know your lines by heart", not "verified".
- The founder's own results are left out.

**Track A: strangers (this track can fail).**
- **5-second test:** 10 strangers see App Store-style screenshots of the first-letter card ("T a a: t t o s b t", with "Finish the line" under it) and say what the app does. Pass: 6 or more explain the idea back. Fail: 3 or fewer. The frames, the script and a scoring sheet are in `design/practice-test/`.
- **Reservation page:** a simple page showing the card, with "Reserve Quoted Pro: $34.99 a year, no charge now". Post it in r/Stoicism, r/commonplacebook and one poetry or literature community, within each one's self-promotion rules. Count visits from server logs, with no tracking script.
  - Pass: 3% or more of at least 300 unique visitors reserve.
  - Stop: under 1%.
  - Under 300 visitors means there is no channel yet.

**Track B: behaviour (8 or more people finish, 3 or more of them strangers from Track A).**
- Each tester adds 3 "practice cards" to their Library: a quote whose text is the first letters of a line they chose. They schedule them in Reminders, plus 1 control line that stays a normal reminder. When a card arrives, they say or type the line, then check it.
- Daily check-in: practised (yes or no), seconds spent, and "felt like homework" on a 1–5 scale.
- Score words recalled from memory on Day 0 and Day 14.
- Pass:
  - half or more practise on 5 or more of 7 days in week 1;
  - practised lines gain 25 or more percentage points over the control for most testers;
  - no more than 1 in 4 rate homework 4 or 5.
- Fail: under a third practise on 5 or more days, or no gain over the control.
- Delete the practice cards after the test.

**Track C: the book.**
- On Day 8, send each tester a hand-made PDF of a list *they* send. Don't pull data from the hosted database.
- On Day 12, ask "Who would you make one for?" and offer a reservation.
- Pass: a third or more share it, ask for edits, or name a recipient and reserve.

**Decisions:**

| Result | Then |
|---|---|
| A and B pass | Build in the order of section 3 |
| B fails, C passes | The book leads, and Practice becomes a reveal card on the widget |
| A fails | Build no new features. Spend the next month finding a channel |

**Founder steps that only you can do:**
- recruit and run the calls;
- post the reservation page (it is public, so it needs your hosting and your accounts);
- read the results.

The research doc has the screener and a 35-minute interview guide (research §11.2, §11.3).

## 8. Money

- **Free forever:**
  - Gather, Reminders, widgets, friends, favorites and profiles;
  - the starter pack and new verified quotes in Reminders;
  - Practice on up to 5 lines with the full mechanism.
- **Quoted Pro:**
  - unlimited Practice lines;
  - extra quote-book layouts;
  - future verified catalog packs.
- **Price:** $34.99 a year (the median yearly price across apps is $34.80) with a 14-day trial, and an in-app reminder 2 days before the trial ends. A lifetime option of about $79.99, tested as a trust signal, because billing distrust is the top complaint in this category.
- **Build:**
  - StoreKit 2 directly.
  - RevenueCat would be a second dependency, which needs your approval under CLAUDE.md.
  - The server learns of purchases from App Store Server Notifications sent to a Supabase Edge Function, which keeps its secret in the function's env.
  - Conversion is measured in App Store Connect's subscription reports, so no analytics SDK.
- **Never for sale:** hints, repairs, progress.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Distribution, not product, is the limit | Track A tests the channel before any code. If it fails, no features get built. |
| Practice feels like homework | Cap of 3 lines, under a minute, feedback every time, "Not yet" copy, opt-out per line, no streak. Track B's homework rating gates the build. |
| Translations and the verified seal | The seal means "checked against the named edition", and the edition shows on every verified line. Users' own lines are practised exactly as saved and never corrected toward the catalog. |
| A lost phone loses the by-heart record | Sign in with Apple ships before Practice reaches the App Store. |
| Small sample, friendly testers | Track A uses strangers and can fail. Track B needs at least 3 strangers. Results guide order, not revenue forecasts. |
| Scope creep into a game | The Verbatim daily stays parked until Practice proves retention. |

## 10. What changes in the docs when this is approved

- `docs/system-design.md`: F12 Practice, the `recall_cards` table, the `record_recall` RPC, F13 Quote book (on-device).
- `docs/ui-spec.md`: the Library Practice card, the Practice session, the quote book sheet.
- `docs/app-architecture.md`: `PracticeStore`, routes.
- `App/Resources/Legal/privacy.md`: practice records.
- `docs/app-store-submission.md`: the privacy label and the paid tier.
