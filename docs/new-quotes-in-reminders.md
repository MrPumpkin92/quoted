# Quoted: new quotes in Reminders (design)

Status: proposal, 2026-10-26. Not approved, nothing built. Owner: hwei.

- **Why this approach:** `docs/decisions/2026-10-26-new-quotes-council.md`, council 1.
- **How it was pressure-tested:** the same file, council 2. The changes it required are applied below.
- **Related:** `docs/reviews/2026-10-26-ux-audit.md` (F1–F4, F10).

## 1. The problem

A TestFlight tester picked 5 starter quotes "because I wanted the quotes to be in that genre", and got those 5 on a loop. At 3 reminders a day, each one returns every 1.7 days. They asked for new quotes in the same vein, and said "Adding quote doesn't work".

Reproduced on build 5 (iPhone Air simulator, fresh install, 5 starter picks):

- **Reminders > Add quotes does nothing.** Every Library quote is already in Reminders, so the button is `.disabled`, yet it still looks enabled. Its footnote ("Every quote in your library is in your reminders.") offers no way forward (`RemindersView.addQuotesSection`).
  - The only other path is typing a quote into the Add sheet. The Add sheet itself works: the quote saves and joins Reminders.
- **The starter pack is reachable only from an empty Library** (audit F2). The 55 quotes the tester didn't pick can never be browsed again.

**Premise:** the user's picks are a sample of their taste, not the whole list of quotes Quoted should deliver. Reminders becomes a stream: the user's own quotes, plus a steady trickle of verified quotes they haven't been sent, chosen to match what they picked.

## 2. Requirements

### Functional

| # | Requirement |
|---|---|
| N1 | When "Mix in new quotes" is on (the default), some reminder slots carry a verified catalog quote that has not counted as seen for this user, and that is not in their Library. |
| N2 | New quotes match the user's taste. Themes are inferred from their catalog-linked Library quotes, hearts, Keeps and dismissals. Non-starter quotes come before starter quotes the user passed on. |
| N3 | The user's own quotes are spaced out. With a small Library, half the slots are new. With a larger one, a quote doesn't repeat within 48 hours where the pool allows it. |
| N4 | Each new quote is sent once. Keep (from the full-screen view) copies it into the Library and Reminders. Not for me removes it for good and lowers its themes. |
| N5 | Notifications, the widget and the full-screen view show the same quote for the same slot. New quotes carry "New" and the verified seal. |
| N6 | It works offline for the whole planned window (60 slots). New quotes are cached on the device, enough to fill every fresh slot. |
| N7 | When the user has seen every catalog quote, Quoted says so ("You've seen every new quote. More arrive weekly.") and falls back to own quotes. It never loops silently. |
| N8 | Reminders > Add quotes is never a dead end. It offers new quotes for you, Library quotes not yet in Reminders, the starter pack, and Write your own. |
| N9 | Existing users get a one-time notice the first time new quotes mix into their Reminders, with a way to turn them off. |
| N10 | A quote that is corrected or withdrawn leaves every device at the next online plan, and loses its seal if it was inaccurate. A server flag can switch mixing off for everyone. |

### Non-functional and constraints

- **Accuracy is the brand.**
  - Only founder-verified, public-domain text, checked word for word against a full text.
  - Translations only in public-domain translations, with the translator recorded.
  - No third-party quote API, no scraping, no other users' quotes, no generated text. This replaces the API "Discover" option from the 2026-10-18 council.
- **Architecture limits.**
  - The server owns data (RLS with `with check` everywhere). The only client dependency stays supabase-swift.
  - No push: planning stays on the device and is refreshed on foreground and in background refresh.
- **Old builds keep working.**
  - Builds 4 and 5 read `starter_quotes` (every row, ordered by `sort_order`).
  - Their `QuoteOrigin` decodes unknown values as `.manual` (`Quote.swift:14-18`), so a new origin value is safe.
  - Their widget rejects snapshots of another version, so the new snapshot reader must keep accepting version 1.
- **Supply is the budget.**
  - At 3 reminders a day and half of them new, a small-library user receives about 10 new quotes a week.
  - Build 6 doesn't go to the tester until at least 40 verified non-starter quotes have landed (section 8).
  - After that, the founder adds about 20 a week.
- **Anonymous accounts.** A reinstall starts over, including which new quotes were sent. Accepted, as for the Library.

## 3. High-level design

```
 Postgres (Supabase, RLS)                          iPhone (App + App Group)                       Widget
 ┌──────────────────────────────┐  fresh_queue   ┌──────────────────────────────────┐          ┌──────────────┐
 │ catalog_quotes (renamed from  │ ─────────────▶ │ FreshStore (App/Stores)           │          │ reads stored │
 │   starter_quotes)             │ (limit,exclude)│  queue cache   fresh-queue.json   │          │ SlotPlan from│
 │  + themes, translator,        │                │  outbox        fresh-outbox.json  │          │ snapshot v2: │
 │    is_starter, status         │ ◀── status ─── │  (models in QuotedCore)           │          │ latest slot  │
 │ view starter_quotes (compat)  │   check        └────────┬─────────────▲───────────┘          │ ≤ now        │
 │ catalog_deliveries            │ ◀── record_catalog_events│ events      │                      └──────▲───────┘
 │ app_flags (kill switch)       │                          ▼             │                             │
 │ quotes.verified_starter_id    │                 SlotPlanner (QuotedCore, pure)                        │
 │  (= catalog id, exact text)   │                  stored 60-slot plan: own | fresh ─────▶ widget-snapshot.json
 └──────────────────────────────┘                          │
                                                           ▼
                                                  NotificationScheduler (reminder-<epoch> per slot, unchanged)
```

### Main paths

1. **Plan** (on foreground, background refresh, or any Library or settings change). `SlotPlanner` updates the stored plan (section 5). The scheduler replaces the pending requests, and the snapshot is written.
2. **Refill.** When the plan needs more fresh quotes than the cache holds, `FreshStore` calls `fresh_queue(limit, exclude: cached ∪ bound ids)`.
3. **Status check** (every online plan). The app reads `id, status` for the cached and bound ids, and purges anything that is no longer live. Then it reads `app_flags`.
4. **Seen.** A fresh slot that has passed becomes a `delivered` event only if the user could have seen it (section 5.4). The outbox flushes through `record_catalog_events`.
5. **Keep or Not for me** in the full-screen view. The event goes to the outbox first, then syncs.
   - Keep also inserts a Library quote with `origin = 'catalog'`, and the existing seal trigger links it.
   - The next plan swaps the quote out of any future slot.

## 4. Data model (one migration, `2026110x_catalog`)

### 4.1 `catalog_quotes` (rename of `starter_quotes`)

`alter table public.starter_quotes rename to catalog_quotes`. Foreign keys follow the table, so `quotes.verified_starter_id` and `shares.verified_starter_id` keep working. New columns:

| Column | Type | Notes |
|---|---|---|
| `themes` | `text[] not null default '{}'` | 1 to 3 of `courage`, `calm`, `time`, `love`, `nature`, `purpose`, `self`. A check enforces the set, and the count when `status <> 'withdrawn'`. |
| `is_translation` | `boolean not null default false` | |
| `translator` | `text null` | Required (check) when `is_translation`. |
| `is_starter` | `boolean not null default false` | The existing 60 are `true`. Only these appear in onboarding and in the starter pack. |
| `status` | `text not null default 'live'` | `live`; `retired` (out of the queue, seal kept); `withdrawn` (found inaccurate: out of the queue, seal removed). |
| `added_at` | `timestamptz not null default now()` | Server-owned. |

- `sort_order` becomes nullable and stays unique where `is_starter`.
- New rows must be at most 280 characters (enforced by a check against `added_at > <migration date>`, so the existing 60 are grandfathered).
- **Compatibility view for builds 4 and 5:**
  ```sql
  create view public.starter_quotes with (security_invoker = true) as
    select id, body, body_format, author, source, sort_order, source_location, source_url
    from public.catalog_quotes where is_starter and status = 'live';
  ```
  `grant select … to authenticated`. Old onboarding and the starter pack keep showing exactly the 60.
- **Seal, in the same migration.** `create or replace function private.set_verified_starter()` matches against `public.catalog_quotes where status <> 'withdrawn'`. The function names the table and runs with `search_path = ''`, so without this rewrite it would quietly read the filtered view after the rename.
  - Withdrawing a row re-runs the seal on the linked `quotes` and `shares` rows (`update … set body = body where verified_starter_id = <id>`), which clears it.
  - The column keeps the name `verified_starter_id`. It now means "the catalog quote this text matches exactly" (glossary in `docs/system-design.md`).
- **Origin.** `quotes_origin_valid` adds `'catalog'` (kept from a new quote).
  - Builds ≤5 decode it as `.manual`.
  - An Undo of a delete on those builds writes it back as `'manual'`. That is cosmetic, and documented.
- **Tests.** pgTAP files 00, 04, 06, 08, 10 and 14 refer to `starter_quotes` as a table and are updated in the same change. A new test runs, as `authenticated`, build 5's exact starter select (`Rows.swift`, `StarterEventsAccount.swift:15`) against the view. It also asserts that non-starter and non-live rows are hidden.

### 4.2 `catalog_deliveries`

| Column | Type | Notes |
|---|---|---|
| `user_id` | `uuid → profiles on delete cascade default auth.uid()` | |
| `catalog_id` | `smallint → catalog_quotes` | |
| `state` | `text` | `delivered`, `kept` or `dismissed` |
| `shown_at` | `timestamptz` | The slot time reported by the client, clamped to `[profiles.created_at, now()]`. The first value wins. |
| `updated_at` | `timestamptz` | Server clock |

- Primary key `(user_id, catalog_id)`.
- RLS: select, insert and update own rows only, `with check (user_id = (select auth.uid()))`. No delete; account deletion cascades.
- Trigger `catalog_deliveries_keep_strongest`: `kept` and `dismissed` never fall back to `delivered`, and `kept` never becomes `dismissed`. This makes the outbox idempotent.
- Writes go through `public.record_catalog_events(p_events jsonb)` (SECURITY INVOKER), up to 100 events per call. Limit QR001: 300 state changes per user per rolling 24 hours.

### 4.3 `public.fresh_queue(p_limit int default 30, p_exclude smallint[] default '{}')`

SECURITY INVOKER, stable. Returns `catalog_quotes` columns.

- **Excludes:**
  - `status <> 'live'`;
  - the ids in `p_exclude` (the client's cached and bound ids);
  - any id in the caller's deliveries;
  - any id equal to a `verified_starter_id` among the caller's quotes.
- **Theme weights** (inferred only, floored at 0):
  - +1 per theme of each catalog-linked Library quote;
  - +2 for each heart or Keep;
  - −2 for each dismissal.
  - No signal means uniform weights.
- **Order:** theme score descending, then `is_starter` ascending (non-starter first, because the user has already passed on the starters), then a per-user stable hash (`hashtext(user_id::text || id)`).
- `p_limit` is clamped to 1–60. The client asks for `min(60, unfilled fresh slots + 15)`.

### 4.4 `public.app_flags` (kill switch)

One row: `mix_new_quotes boolean not null default true`.

- RLS on. Select for `authenticated`. Writes only by the founder (postgres / secret key).
- When it is false, the client uses f = 0 and drops every future fresh slot at the next plan.

### 4.5 Unchanged

`quotes` gets no new column. A kept catalog quote is an ordinary Library quote (`origin 'catalog'`), and the seal trigger fills `verified_starter_id`. Editing its text clears the link, exactly as today. Its `kept` delivery still keeps it out of the queue.

## 5. Planning: a stored slot plan (QuotedCore, pure, unit-tested)

The planner no longer decides fresh slots by arithmetic on a moving anchor. It stores the resolved decision for every planned slot, and the widget reads the same stored plan.

### 5.1 How much is new

```
n = own quotes in Reminders, s = slots per day
n = 0 and mixing on:   f = 1      (Reminders is all new quotes)
1 ≤ n ≤ 10:            f = 1/2
n > 10:                f = the smallest of {1/3, 2/5, 1/2} with 1 − f ≤ 24·n / (s·48); 1/2 if none
mixing off, app_flags off, or nothing cached: f = 0
```

**The tester (n = 5, s = 3):** f = 1/2. That is 1.5 new quotes a day, and each own quote comes back every 3.3 days instead of 1.7.

### 5.2 The model

`SlotPlan` is stored in snapshot v2:

| Field | Meaning |
|---|---|
| `slots: [PlannedSlot { date, content: .own(UUID) \| .fresh(Int) }]` | The 60-slot window, resolved. |
| `cursor: RotationState` | The own cycle, positioned at the first future own slot. |
| `credit: Int` | Running counter, in units of 1/q, that decides when an appended slot is fresh. |
| `share: (p, q)` | The f the plan was built with. |
| `signature` | Times, days, order mode, mixing on/off and share. A change re-patterns the plan. |

### 5.3 Replan, in order

1. **Drop passed slots.** Remove slots with `date ≤ now`. Each dropped own slot advances `cursor` by one. Each dropped fresh slot is handed to the seen rule (5.4).
2. **Re-pattern if the signature changed.** Rebuild the pattern for every future slot and reset `credit`. Fill fresh slots with the previously bound ids first, in their original order, then from the queue.
3. **Otherwise keep decisions.**
   - Every future fresh slot whose quote is still eligible (live, not kept, dismissed or in the Library) stays exactly as it is.
   - An ineligible one takes the next queue item. With an empty queue, it becomes an own slot.
4. **Append until 60.** For each new slot, `credit += p`. If `credit ≥ q` and the queue has an item, the slot is fresh and `credit −= q`. Otherwise it is own.
5. **Assign own quotes.** Walk the own cycle from `cursor` across the future own slots. Rotation edits (add, remove, reorder) apply immediately, as today.

Notification identifiers stay date-based (`reminder-<epoch>`), so a slot whose decision didn't change keeps its pending request unchanged.

**The widget** shows the content of the latest stored slot at or before `now`. Past the end of the window it falls back to the existing own walk (`ReminderPlanner.timeline`). There is no second planner and no disagreement.

**Shuffle** (audit F14, council decision 7): the own cycle deals like a deck. It reshuffles after each full pass, and the last quote of one pass never opens the next. This lives in `cursor`, so it applies with mixing on or off.

### 5.4 When a new quote counts as seen

A passed fresh slot becomes `delivered` only if the user could have seen it. That is true if any of these holds:

- notification authorization was `.authorized` when the slot was scheduled (recorded on the slot);
- a Quoted widget is installed (`WidgetCenter.currentConfigurations`);
- the user opened the quote.

Otherwise the quote goes back to the head of the cached queue, so muted or Focus-only users don't use up the supply.

### 5.5 Edge cases

| Case | Behaviour |
|---|---|
| Offline at plan time | The stored plan and cache are used as they are. No new fresh slots beyond the cache; own quotes fill the rest. |
| Queue empty from the server | Remaining slots are own. Reminders shows the N7 message. |
| A quote withdrawn or retired | The status check purges it from the cache and from future slots, and the replan replaces those pending requests. A withdrawn quote also loses its seal in the Library (4.1). |
| Settings change | The signature changes: re-pattern, reusing bound ids in their order. |
| Clock moves backwards | Slots after the new `now` stay. The cursor never moves back. |
| 64-request iOS limit | Unchanged: 60 slots plus the nudge. |
| Update from build ≤5 | The version 1 snapshot reads as a plan with no fresh slots (the reader accepts versions 1 and 2), so the widget isn't blank. The first plan writes version 2. |

### 5.6 Invariant tests, written first

- **Stable:** a replan with no change produces the identical plan.
- **Survives time:** for any k, after k slots pass, no surviving future fresh slot changes unless its quote became ineligible.
- **Agree:** the widget lookup equals the scheduled notification for every slot.
- **Spacing:** the own repeat gap holds for n = 1…40 and s = 1…12.
- **Re-pattern:** a signature change reuses bound ids in their original order.
- **Edges:** exhaustion, the kill switch, a version 1 snapshot, and the shuffle deck not repeating across passes.

## 6. On the device

- **`FreshStore`** (App/Stores, `@Observable @MainActor`):
  - queue cache `fresh-queue.json` and outbox `fresh-outbox.json` in the App Group;
  - their Codable models and file I/O live in QuotedCore, so a later widget App Intent can reuse them;
  - API: `refill()`, `checkStatus()`, `keep(_:)`, `dismiss(_:)`, `flush()`, `isExhausted`;
  - `reset()` on sign-out and account deletion, like the other stores.
- **Notifications:**
  - A fresh slot's content: subtitle `New · Author` (no author: `New`), body `“…”`, `userInfo = {catalogID, slot}`.
  - Tapping it opens `quoted://new/<catalogID>`.
  - No notification actions in build 6. They move to build 7 alongside widget App Intents (section 12).
- **Deep link:** `DeepLink.newQuote(Int)`. `Router` shows it in the spotlight cover. `QuoteSpotlightView` gets a fresh mode that resolves the quote from the `FreshStore` cache, or from the snapshot for widget taps.
- **Widget:** a fresh entry shows the quote with "New" and the seal. Tapping it opens `quoted://new/<id>`.
- **Keep:**
  - inserts a Library quote with `origin 'catalog'`, using a client-made `id` stored in the outbox event, so a retry after a lost answer finds the same row;
  - adds it to the end of Reminders;
  - records the `kept` event.

## 7. Interface

1. **Reminders screen.** A "New quotes" card under the schedule:
   - Toggle "Mix in new quotes", on by default. Caption: "About 1 in 2 reminders is a verified quote you haven't seen." The share shown is the real one: 1 in 2, 2 in 5, 1 in 3, or "All your reminders" at n = 0.
   - Status line: "12 new quotes ready", or the exhaustion message.
2. **Add quotes** is never disabled. It opens the picker with a segmented control:
   - **New for you:** the cached queue, each row with an Add capsule. Add is the same as Keep.
   - **Your library:** today's list.
   - **Footer:** Browse the starter pack and Write your own.

   When every Library quote is already in Reminders, the picker opens on New for you.
3. **Full-screen quote, fresh mode.**
   - A "New" capsule and the seal above the quote.
   - **Keep** (PrimaryButton) and **Not for me** (quiet).
   - Below: "Where it's from", which opens the verified sheet.
   - After Keep, the view becomes the normal mode with Share and Open in Library.
4. **Copy:**
   - Priming: "Quoted will show you 3 quotes a day: the ones you picked, and new ones like them. You can change this anytime."
   - Starter picker caption: "Pick a few you love. We'll send them, and new ones like them."
5. **One-time notice** for existing users, as a Library header card in the widget-tip style:
   - "New quotes are mixing into your reminders" / "Verified quotes like yours. Keep the ones you love."
   - Actions: **OK** and **Turn off**.

All controls are stock SwiftUI (Toggle, segmented Picker, bordered capsules), as `docs/ui-spec.md` requires.

## 8. Content pipeline (the real bottleneck)

- **Theme tags for the existing 60:** a draft is in `docs/new-quotes-theme-tags.csv`, for the founder to confirm or edit before the migration.
- **Content gate:** before build 6 goes to the tester, a batch migration adds at least 40 verified non-starter quotes. This is founder time, in parallel with the engineering. After that, about 20 a week in `supabase/migrations/<date>_catalog_batch_NN.sql`, deployed with `scripts/deploy-backend.sh`.
- **Rules for every new quote:**
  - it is a line people actually quote;
  - it is checked word for word against a public-domain full text, with the location recorded;
  - translations are public-domain, with the translator recorded;
  - it passes a context check (the excerpt doesn't mean something else in context);
  - it is at most 280 characters;
  - it has 1 to 3 themes.
- **Test:** `supabase/tests/database/16_catalog.test.sql` fails any batch that breaks the rules. It checks:
  - an https `source_url`;
  - a translator when `is_translation`;
  - the theme set and count;
  - no duplicate bodies;
  - the 280-character limit for new rows;
  - `is_starter` rows are unchanged.
- **Sources doc:** `docs/starter-pack-sources.md` becomes `docs/catalog-sources.md`, with the misattribution reject list. Corrections use `status = 'withdrawn'`, never a delete.

## 9. Scale, reliability, measurement, privacy

- **Load.** About 10 deliveries per user per week, or roughly 520 rows a year. 10,000 users is about 5M rows a year on a primary-key index.
  - `fresh_queue` scans the catalog (thousands of rows at most) and the caller's own rows.
  - The status check reads at most 75 ids.
- **Failure.**
  - Every server dependency degrades to own quotes, spaced.
  - Events are at least once (the outbox) and idempotent (the strongest-state trigger).
  - A lost Keep answer is resolved by the client-made quote id.
  - The kill switch turns mixing off everywhere at the next plan.
- **Measurement.** No analytics library. One SQL query, kept in `docs/system-design.md` §7, gives the weekly Keep rate (kept ÷ all states) and the Not for me rate.
  - A Keep rate above about 10% means the matching works.
  - More Not for me than Keep means the tags are wrong.
  - With a handful of testers, read it as anecdotes rather than numbers.
- **Privacy.**
  - `privacy.md` adds: "Which new quotes we sent you, and whether you kept them or chose Not for me. Used to avoid repeats and to choose quotes you'll like." Linked to the account; deleted with it.
  - The App Store privacy label adds Usage Data > Product Interaction (App Functionality).

## 10. Trade-offs

| Decision | Chosen | Rejected, and why |
|---|---|---|
| Source of new quotes | The founder-owned verified catalog | Quote APIs (unverified attributions under a seal); mining whole books (a passage isn't a quote); friends' quotes (consent) |
| Taste | Hand-tagged themes, inferred weights | Asking at onboarding (friction; the tester believes they already told the app); embeddings (a dependency, and opaque); "More of" chips in build 6 (a frozen manual choice overrides inference; moved to build 7) |
| Delivery | Inside Reminders, on by default | A Discover tab (doesn't reach lapsed users); opt-in "Surprise me" (the tester wouldn't find it); a Library drip, adding one catalog quote to the Library each day (council 2: every unreviewed addition then repeats, which is the original complaint, slower) |
| Slot model | A stored, resolved slot plan read by the widget | Phase arithmetic on a moving anchor (reshuffles pending new quotes on almost every foreground); a separate fresh epoch (still reshuffles when the share changes, still needs a second walk in the widget) |
| Catalog table | Rename `starter_quotes`, add a compat view | A second table (two seal sources); not renaming and letting old builds expire (builds 4 and 5 select every row, so new quotes would leak into their onboarding; expiring a TestFlight build doesn't make testers update) |
| Kept quote origin | A new value, `'catalog'` | Reusing `'starter'` (that rested on a false closed-enum premise; old builds decode unknown values as `.manual`) |
| Seen state | Server table plus device outbox, with the seen rule | Device only (repeats on a second device or after a reinstall; no Keep-rate data); counting any passed slot as seen (muted users burn supply) |
| Notification actions | Build 7 | Build 6 (background launch, a delegate before launch finishes, and Keychain while locked: the riskiest code for the least-used path) |

## 11. Plan

| Step | Work | Days |
|---|---|---|
| **Build 5.1 (now)** | The "Adding quote doesn't work" cluster (audit F1, F2, F3, F10): "Add quotes" never disabled, with an empty state offering Browse the starter pack and Write your own; the starter pack in Library's `+` menu; "Add the copied quote" after web search; a saved-quote toast that resets the filter. The release note asks the tester whether this was their "Adding quote doesn't work". | 0.5 |
| 6.1 | Migration (rename, compat view, columns, seal rewrite, `withdrawn`, `'catalog'` origin, deliveries, `record_catalog_events`, `fresh_queue`, `app_flags`, theme tags for the 60). pgTAP: update 00/04/06/08/10/14; new 16 (catalog rules), 17 (deliveries, queue, flags), 18 (build-5 compat select). | 1.5 |
| 6.2 | QuotedCore: `SlotPlan`, the shuffle deck, snapshot v2 (reader accepts v1), `DeepLink.newQuote`, outbox model. Invariant tests first (5.6). | 1.5 |
| 6.3 | App: `FreshStore` (queue, status check, outbox, kill switch), fresh content in notifications, spotlight fresh mode, Reminders card, picker segment, one-time notice, copy. | 1.5 |
| 6.4 | Docs: system-design.md (tables, RPCs, glossary, F11), ui-spec.md, app-architecture.md, privacy.md, app-store-submission.md (privacy label). | 0.5 |
| 6.5 | Verify: tests; both builds with no warnings; simulator run (a fresh slot 2 minutes ahead, then tap, Keep, check the outbox and server row); widget gallery check; upgrade from a build 5 snapshot. | 0.5 |
| Content | At least 40 verified non-starter quotes, tagged (founder, in parallel). | about 2 (founder) |

**Total:** about 5.5 engineering days plus the content work. Build 6 goes to the tester only after the content gate.

## 12. Later (build 7 and beyond)

- **Build 7:**
  - Notification actions (Keep, Not for me) and widget App Intents, both reusing the QuotedCore outbox.
  - "More of" theme chips and `my_theme_weights`.
  - An exploration slot (every 4th new quote from outside the top themes).
  - Search: the suggestion chips become the seven themes, and a "From the Quoted catalog" section (`search_catalog(q)`) answers them with verified quotes and Add (audit F4).
- **Later:**
  - Themed packs as a paid tier, once the catalog passes about 500 quotes.
  - "Read the whole letter" from the full-screen view.
  - The quote game (`docs/quote-game.md`) as a second discovery path feeding the same catalog.
  - Server-side scheduling, once push exists.
