# Quoted: system design (MVP)

Status: approved for MVP build, 2026-10-18. Owner: hwei. Inputs: the founder brief, the search council decision (`docs/decisions/2026-10-18-in-app-search-council.md`) and the UI critique decision (`docs/decisions/2026-10-18-ui-direction.md`).

## 1. Requirements

### Functional
| # | Requirement | MVP behaviour |
|---|---|---|
| F1 | Accounts | Email and password sign up and sign in through Supabase Auth. A username (handle) is chosen after the first sign-in. Sign out. In-app account deletion (App Store 5.1.1(v)). |
| F2 | Quotes | Create, edit and delete quotes: text, author, source. Rich text supports **bold**, *italic* and <u>underline</u>. |
| F3 | Rotation | An ordered subset of the user's own quotes (the "playlist"). The user can reorder it and switch between in-order and shuffle. |
| F4 | Reminders | Local notifications cycle through the Rotation, N times a day, spaced evenly inside a time window on chosen weekdays. |
| F5 | Widgets | Home-screen widgets (small and medium) and a Lock Screen rectangular widget show the current Rotation quote, matching the latest reminder. |
| F6 | Friends | Add a friend by exact username (sends a request), accept or decline, unfriend, block. |
| F7 | Sharing | Send a quote to one or more friends with an optional note. The recipient sees it under "Shared with you" and can save it to their library, report it or block the sender. Plain-text sharing to any app goes through the system share sheet. |
| F8 | Search | A `.searchable` bar over the library and shared quotes. The last row reads "Search the web for '<term>' quotes" and opens Google in an in-app browser (`SFSafariViewController`; this counts as unrestricted web access for the age rating, see docs/decisions/2026-10-19-web-search-browser.md). A `PasteButton` in Add brings a copied quote back. Taps on the web row are logged. |
| F9 | Starter pack | About 60 public-domain quotes with checked attributions. During onboarding the user picks some; they are copied into the library and the Rotation. |

### Non-functional
- **Native and smooth.** SwiftUI on iOS 26+, 60/120 fps scrolling, no spinners on launch. The library loads from a local cache and then refreshes.
- **Secure by default.** RLS on every exposed table. The client holds only the publishable key. Server state is never trusted from the client.
- **Cheap.** $0 at MVP scale (Supabase free tier, no paid APIs, no push server).
- **App Store ready.** Privacy manifest, account deletion, UGC report and block (1.2), export compliance, app icon, versioning.

### Constraints
- A solo founder. Ship the MVP fast and keep the moving parts few.
- Supabase project `yyajndbishiyugtbpzmk`, with a publishable key in the client.
- No Google search API is available: Custom Search JSON API is closed to new customers and ends 2027-01-01.

## 2. High-level design

```
┌──────────────────────────── iPhone ─────────────────────────────┐
│  Quoted.app (SwiftUI)                                           │
│   ├─ Feature UI (Onboarding, Library/Home, Search, Add/Edit,    │
│   │   Rotation, Friends, Profile)                               │
│   ├─ AppModel (@Observable, @MainActor) ── stores:              │
│   │     SessionStore · LibraryStore · SocialStore               │
│   ├─ QuotedKit (SPM) ── Supabase repositories (supabase-swift)  │
│   └─ QuotedCore (SPM) ── models, RichText, ReminderPlanner,     │
│         SearchIndex, WidgetSnapshot, AppGroupStore              │
│        │ writes snapshot JSON          │ schedules              │
│        ▼                               ▼                        │
│  App Group container          UNUserNotificationCenter          │
│        │ reads                 (≤ 60 pending local requests)    │
│        ▼                                                        │
│  QuotedWidgets.appex (WidgetKit, links QuotedCore only)         │
└──────────────┬──────────────────────────────────────────────────┘
               │ HTTPS (PostgREST, GoTrue, Functions)
┌──────────────▼──────────── Supabase ─────────────────────────────┐
│  Auth (email/password, JWT)                                      │
│  Postgres (public schema, RLS on every table; private schema     │
│    for SECURITY DEFINER helpers, not exposed)                    │
│  Edge Function: delete-account (service role → auth.admin)       │
└──────────────────────────────────────────────────────────────────┘
Web search: SFSafariViewController (in-app) → https://www.google.com/search?q=<term>%20quotes
            (no API, no key, no in-app browser; user copies, comes back → PasteButton in Add)
```

### Data flow, main paths
1. **Launch.** Restore the session from the Keychain. Render the library from the App Group cache, then refresh it from Postgres. Plan reminders and write the widget snapshot, then reload widget timelines.
2. **Save a quote.** Validate on the client. `insert` returns the row and updates the cache. If it is in the Rotation, re-plan reminders and the widget.
3. **Reminder fires.** iOS delivers the local notification and no code runs. A tap deep-links to `quoted://quote/<id>`.
4. **Share.** `insert into shares` with a content snapshot. RLS checks for an accepted friendship. The recipient sees it on the next refresh (on foreground and pull to refresh).
5. **Delete account.** Call `functions.invoke("delete-account")`. The function verifies the JWT and calls `auth.admin.deleteUser`, and FK cascades remove the user's rows (reports are kept for moderation with the user's id set to null; events never carry a user id). The client then signs out, wipes the cache and snapshot, and removes pending notifications.

## 3. Data model (Postgres, `public` schema)

`profiles.id` and `quotes.owner_id` reference `auth.users(id) on delete cascade`. The social tables (`friendships`, `blocks`, `shares`) reference `profiles(id) on delete cascade` instead. This lets PostgREST embed the other party's profile (`sender:profiles!shares_sender_id_fkey(username, display_name)`) in one request, and deleting an auth user still cascades through `profiles`. `reports` also references `profiles`, but `on delete set null`, so a report outlives the deletion of either account (moderation evidence). `events` has no user column at all. Every table has RLS enabled and explicit grants to `authenticated` only (nothing to `anon`). Policies use `(select auth.uid())`, which is evaluated once per statement.

The server owns every timestamp: BEFORE INSERT triggers (`<table>_stamp_created_at`) set `created_at` to the server clock whatever the client sends, `profiles` and `quotes` keep `created_at` on update (`<table>_keep_created_at`), and the other timestamps are noted per table below. Text the app trims must contain something other than whitespace on the server too (`<table>_<column>_not_blank` checks through `private.is_blank`, which strips exactly Unicode White_Space, the set Swift trims, so the server is never stricter than the app).

Implemented in `supabase/migrations/20261019040000_core_schema.sql` (plus `20261019050000_report_snapshot.sql` for the report snapshot and `20261019060000_hardening.sql` for the format, text and timestamp checks, anonymous events and report retention) and covered by `supabase/tests/database/*.test.sql`. Foreign keys are named `<table>_<column>_fkey` (for example `shares_sender_id_fkey`, `shares_recipient_id_fkey`, `friendships_requester_id_fkey`, `friendships_addressee_id_fkey`), so embedding hints are stable.

| Table | Columns (abridged) | Access (RLS) |
|---|---|---|
| `profiles` | `id uuid pk → auth.users`, `username text unique` (`^[a-z0-9_.]{3,20}$`), `display_name text null` (1–50 when set, not blank), `created_at` (server clock, never changes) | select: any authenticated user, since usernames are public handles. insert and update: only your own row. No client delete; it cascades from auth. |
| `quotes` | `id uuid pk`, `owner_id uuid → auth.users default auth.uid()`, `body text` (1–2000, not blank), `body_format jsonb default '[]'` (valid runs, see the contract below), `author text null` (≤200, not blank), `source text null` (≤200, not blank), `origin text default 'manual'` (`manual`, `starter`, `shared` or `pasted`), `rotation_position int null` (≥ 0; null = not in the Rotation), `created_at` (server clock, never changes), `updated_at` (server clock on insert and every update) | All operations owner only. `with check` keeps `owner_id = auth.uid()`. |
| `friendships` | `id uuid pk`, `requester_id → profiles default auth.uid()`, `addressee_id → profiles`, `status text default 'pending'` (`pending` or `accepted`), `created_at` (server clock), `responded_at` (server-owned: null on insert, stamped by trigger on accept); `check requester <> addressee`; unique index on `(least(a,b), greatest(a,b))` | select: either party. insert: requester is you, status is pending, and there is no block in either direction (via `private.is_blocked_pair`). update: only the addressee, and only pending → accepted; column grants allow only `status` (and `responded_at`, which the trigger overrides). delete: either party (decline, cancel, unfriend). A second request for the same pair, in either direction, fails with 23505. |
| `blocks` | `blocker_id → profiles default auth.uid()`, `blocked_id → profiles`, `created_at` (server clock); `pk (blocker, blocked)`; `check blocker <> blocked` | Blocker only (select, insert, delete; no update). An AFTER INSERT trigger (`private.blocks_after_insert`, SECURITY DEFINER) deletes the friendship between the pair, pending or accepted, and any shares in either direction. |
| `shares` | `id uuid pk`, `sender_id → profiles default auth.uid()`, `recipient_id → profiles`, `quote_id → quotes on delete set null`, a snapshot of `body` (1–2000, not blank), `body_format` (valid runs, as `quotes`), `author` and `source` (≤200, not blank), `note text` (≤280, not blank), `created_at` (server clock, so a share cannot date itself into the future and pin itself to the top of the inbox), `seen_at`, `saved_at` (server clock; the first time wins, and null clears) | select: sender or recipient. insert: sender is you, there is an accepted friendship with the recipient, `quote_id` is null or one of your quotes, and `seen_at`/`saved_at` are null. update: the recipient may set only `seen_at` and `saved_at` (column grants); the trigger `private.shares_stamp_seen_saved` replaces any non-null value with the stored time or, the first time, the server clock. delete: sender (unsend) or recipient (remove from inbox); nobody else. |
| `reports` | `id uuid`, `reporter_id → profiles on delete set null default auth.uid()`, `share_id → shares on delete set null`, `reported_user_id → profiles on delete set null`, `reason text` (`spam`, `harassment`, `inappropriate` or `other`), `details text` (≤500, not blank), a snapshot of the reported content in `content_body` (≤2000), `content_author` and `content_source` (≤200, all nullable), `content_verified bool` (server-owned), `reported_username` (server-owned), `created_at` (server clock), `reviewed_at` (null = waiting for review); `check reporter <> reported` | Insert and select your own only (no update or delete). A `share_id`, when given, must be a share you received from `reported_user_id`. A BEFORE INSERT trigger (`private.reports_snapshot_share`, SECURITY INVOKER) requires both user ids (23502 otherwise, even with the secret key), copies the snapshot from the share whenever `share_id` names a share the reported user sent the reporter and then sets `content_verified = true`, and ignores the client's values for all of these columns. With no `share_id` the client's snapshot is kept as sent and `content_verified` stays false: it is the reporter's account, not the server's copy (a report about a user without a share is allowed, but unverified). The trigger also snapshots `reported_username` and clears `reviewed_at`. The snapshot outlives the share, so a block does not erase what was reported, and the report outlives both accounts: deleting the reporter or the reported user only sets that id to null. Reviewed daily by the developer through `private.reports_to_review` (section 7). |
| `starter_quotes` | `id smallint pk`, `body text` (1–2000, not blank), `body_format jsonb default '[]'` (valid runs, as `quotes`), `author text not null` (1–200, not blank), `source text null` (≤200, not blank), `sort_order smallint unique` | select: any authenticated user. No writes from clients. Seeded by migration, so it exists on hosted too. |
| `events` | `id bigint identity`, `name text` (`web_search_tap`), `created_at` (server clock rounded down to the hour) | Anonymous: no user column, so a row says only that a tap happened in a given hour. insert: any signed-in user, for a known event name (the policy checks the name). No select from clients. The search term is never stored. Rows do not change when an account is deleted, because none belongs to anyone. |

`private` schema (not exposed by the Data API): `is_blocked_pair(a, b)` is SECURITY DEFINER with `search_path = ''`, executable by `authenticated` only, and answers only for pairs that include the caller (otherwise false), so it cannot probe other people's blocks. The trigger functions (`set_updated_at`, `stamp_created_at`, `keep_created_at`, `events_stamp_created_at`, `shares_stamp_seen_saved`, `friendships_set_responded_at`, `blocks_after_insert`, `reports_snapshot_share`) also live there and are not executable by clients. The CHECK validators `is_blank(text)` and `is_valid_body_format(jsonb)` are IMMUTABLE, read no data and are executable by `authenticated` and `service_role`, because a CHECK runs with the privileges of the role writing the row. The view `reports_to_review` (security_invoker, granted to no API role) is the moderation queue. `service_role` (secret key) gets explicit table grants too. Supabase stops auto-granting new `public` tables to the Data API roles (new projects since 2026-05-30, all projects from 2026-10-30), so the migration's explicit grants are what expose the tables, locally and on hosted alike.

Client notes (these follow from the grants and policies above):
- `events` has no select grant, so inserts must not ask for the row back (supabase-swift `returning: .minimal`, PostgREST `Prefer: return=minimal`). The same applies to any insert whose row you could not read.
- The Rotation is written with `public.set_rotation(ordered uuid[], removed uuid[])` (migration `20261019070000_set_rotation`, called as `POST /rest/v1/rpc/set_rotation`). It is SECURITY INVOKER with `search_path = ''` and executable by `authenticated` and `service_role` only, so the quotes RLS policies and grants apply as for a direct UPDATE. One UPDATE gives the caller's own quotes in `ordered` positions 0…n-1 (first occurrence wins; IDs that are not the caller's or no longer exist are skipped without leaving a gap), sets `removed` to null (an ID in both lists stays in the Rotation), touches nothing else and returns the updated rows. Only IDs travel, in the POST body, so the request is small for any Rotation size, a quote deleted elsewhere is never re-inserted, and no content is written, so a stale copy on one device cannot undo an edit made on another. (It replaced a client-side upsert of whole rows, which an upsert needs because Postgres checks NOT NULL on the proposed insert before resolving the conflict.)
- Timestamps the client sends (`created_at`, `updated_at`, `seen_at`, `saved_at`) are replaced by the server clock, so read them back from the returned row rather than trusting the local `Date()`. Blank optional text must be sent as null; whitespace-only values fail a `*_not_blank` check with 23514 (the constraint name contains the column, for example `profiles_display_name_not_blank`).
- Reporting then blocking: the block deletes the shares between the pair, so the report keeps `reported_user_id` and its content snapshot but its `share_id` becomes null. File the report before the block so the snapshot is the server's copy. `report(share:)` always sends the share's content, so if the share is already gone it falls back to a user report that still carries the content (as the reporter's app held it).

Why the content is snapshotted in `shares`: the recipient never needs RLS access to the sender's `quotes`. Edits and deletes by the sender don't silently change what was received. "Save" copies the snapshot into the recipient's `quotes` with `origin = 'shared'`.

Why `rotation_position` is a column and not a join table: rotation membership is per user per quote, and only your own quotes can be in your Rotation. That means one table and one set of RLS policies. Reordering is a small bulk update.

Reminder settings (times per day, window, weekdays, shuffle) are **device-local**, in App Group `UserDefaults`, because notifications are device-local too.

### Rich-text format, the `body_format` contract
`body` is plain text, which is what notifications, search, plain sharing and accessibility use. `body_format` is a normalized array of runs:
```json
[{"start":0,"length":13,"bold":true},{"start":40,"length":11,"underline":true}]
```
- `start` and `length` are **UTF-16 code units** in `body`. This is the same as `NSRange` and JavaScript.
- Runs are sorted, non-overlapping and non-empty. Adjacent runs with identical flags are merged. Each run has at least one true flag among `bold`, `italic` and `underline`; false flags are omitted.
- The server checks the shape (`private.is_valid_body_format`, used by `quotes`, `shares` and `starter_quotes`): a JSON array of at most 200 runs; each run an object with integer `start` and `length` from 0 to 4000 (the most UTF-16 units a 2000-character body has) and optional boolean `bold`, `italic`, `underline`; no other keys; at most 16384 bytes as text. It does not check runs against `body`, sorting or overlap; that is the client's normalization.
- Clients must clamp runs to `body` when decoding, so bad data can never crash rendering.
- `QuotedCore.RichText` owns the conversions: runs ↔ `AttributedString` (for SwiftUI `Text` and widgets) and runs ↔ `NSAttributedString` (for the UITextView editor). Both are covered by round-trip unit tests.

## 4. API contracts (supabase-swift 2.55.x)
- Auth: `auth.signUp(email:password:redirectTo: quoted://auth-callback)`, `auth.signIn(email:password:)`, `auth.signOut()`, `auth.authStateChanges`, and `auth.session(from:)` for the `quoted://auth-callback` deep link. With PKCE, GoTrue redirects confirmation and password-reset links alike with only `?code=`, and supabase-swift emits `passwordRecovery` only for implicit-flow links, so `AuthService.handle(url:)` returns `AuthCallbackResult.passwordRecovery(id)` when the new access token's `amr` claim has `method: "recovery"` (or the URL has `type=recovery`), else `.signedIn(id)`.
- Session storage: the Keychain, service `supabase.gotrue.swift`, account `sb-<project ref>-auth-token` (the SDK default, passed explicitly), written `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` by `DeviceKeychainStorage` so backups never carry the tokens to another device (items from older builds convert on their next write). Keychain items survive deleting the app, so the app calls `AuthService.clearLocalSession()` (no network) on the first launch after an install.
- Network: one `URLSession` from `Backend.makeURLSessionConfiguration()` (ephemeral, `urlCache = nil`, `.reloadIgnoringLocalCacheData`, no cookies or credential store) for Auth, PostgREST and Functions, so tokens and library, inbox and friend responses never reach `Library/Caches/…/Cache.db`. `Backend.purgeHTTPCaches()` empties `URLCache.shared`, which builds before this used; the app calls it at launch and on sign-out or account deletion.
- Data: PostgREST through `client.from("quotes")…`, returning typed `Codable` DTOs (snake_case keys through `CodingKeys`). List reads (`fetchMine`, `inbox`, `sent`, `friendships`, `blockedIDs`, `blockedProfiles`) page with `range(from:to:)`, 500 rows at a time with `count=exact`, until the count is reached, so nothing is cut at `max_rows` (1000). Rotation writes are one `set_rotation` RPC call carrying IDs only (see the client notes in section 3); deleting shares sends at most 100 IDs per request.
- Function: `client.functions.invoke("delete-account")` with the user's JWT. The function requires `POST`, verifies the user with `auth.getUser(jwt)`, and deletes with the service-role or secret key from function env (never in the app).
- Search: client-side, over the cached library and received shares. Case- and diacritic-insensitive, on body, author and source. Per-user data is small (at most a few thousand rows), so there are no round trips.

## 5. iOS architecture

### Targets and modules
| Target | Contents | Depends on |
|---|---|---|
| `QuotedCore` (SPM library, no UIKit or Supabase, builds on macOS for `swift test`) | `Quote`, `TextRun`, `RichText` conversions, `ReminderSettings`, `ReminderPlanner`, `SearchIndex`, `WidgetSnapshot`, `AppGroupStore`, `DeepLink` | Foundation only |
| `QuotedKit` (SPM library) | `SupabaseConfig`, `AuthService`, `QuotesRepository`, `SocialRepository` (profiles, friendships, blocks, shares, reports), `StarterRepository`, `EventsRepository`, DTOs, error mapping | `QuotedCore`, `Supabase` |
| `Quoted` (iOS app) | SwiftUI features, `AppModel` and stores, `NotificationScheduler` (UNUserNotificationCenter), `RichTextEditor` (UITextView representable plus a B/I/U bar), theme | `QuotedKit` |
| `QuotedWidgets` (WidgetKit extension) | `TimelineProvider` reading `WidgetSnapshot`, with systemSmall, systemMedium and accessoryRectangular views | `QuotedCore` only, which keeps the extension small |
| Tests | `QuotedCoreTests` (swift test), DB tests (pgTAP via `supabase test db`), and a `QuotedUITests` smoke flow against the local stack | |

### State
`AppModel` (`@Observable @MainActor`) owns `SessionStore` (phase: `launching`, `signedOut`, `needsUsername`, `needsStarter` or `ready`), `LibraryStore` (quotes, rotation, cache I/O) and `SocialStore` (profile, friends, requests, shares). Views read the stores. Mutations are `async` methods that update optimistically and roll back on error with a toast.

### Reminder planning (`ReminderPlanner`, pure and unit-tested)
Inputs are the ordered Rotation quote IDs, the settings (`timesPerDay` 1–12, `windowStart` < `windowEnd`, weekdays, shuffle), the rotation `anchor` date, `seed` and `startIndex` (`RotationState`, saved whenever the Rotation changes), `now`, and the calendar.
- **Slots:** for each enabled day, `n` times spread evenly from `windowStart` to `windowEnd`. With `n = 1` the slot is at `windowStart`.
- **Quote for a slot:** the slot's ordinal since `anchor`, plus `startIndex`, mod the count. For shuffle, that position indexes a permutation seeded by `seed`, so the order is the same on every replan.
- **Rotation changes continue the cycle.** `RotationState.updated(with:at:seed:settings:calendar:)` keeps `anchor` and picks `startIndex` so the next slot plays the quote after the one shown last (the most recent slot's quote) in the new order. If that quote left the Rotation, the next one still in it (in the old order) plays; before any slot has passed, the upcoming quote stays next. The widget's "now" entry keeps showing the last quote. Adding, removing or reordering therefore never restarts at the top, so every quote is reached within one pass even when quotes are added often. States saved before `startIndex` existed decode with 0.
- **Output:** the next slots up to **60** (iOS caps an app at 64 pending; 4 are left as headroom). That is about 20 days at 3 a day. The app replans on launch, on foreground, and on any Rotation or settings change.
- The widget uses the same planner. Its timeline has one entry per upcoming slot in the next 24 hours, plus a "now" entry showing the most recent slot's quote, so **the widget always matches the last reminder**.

### Widget snapshot
`AppGroupStore` writes `widget-snapshot.json` (version, rotation quotes with runs, settings, anchor, seed, startIndex) to the App Group container and then calls `WidgetCenter.shared.reloadAllTimelines()`. With an empty Rotation the widget shows a friendly prompt and deep-links to Rotation.

### Deep links (`quoted://`)
`auth-callback` (email confirmation), `quote/<uuid>` (from a notification or widget), `rotation`.

### Build configurations
- `Debug`: hosted Supabase (default Run).
- `Debug-Local`: the local stack at `http://127.0.0.1:54321`, used for automated tests and development without touching production.
- `Release`: hosted.

The values come from `Config/*.xcconfig` and reach the app through Info.plist keys `SupabaseURL` and `SupabasePublishableKey`. Publishable keys are designed to ship in clients.

## 6. Security checklist
- RLS on every table. `with check` on every insert and update. UPDATE policies have matching SELECT policies.
- No `user_metadata` in authorization decisions.
- SECURITY DEFINER only in the unexposed `private` schema, with `search_path = ''` and an explicit `auth.uid()` or argument check, and execute granted only to `authenticated`.
- The service role and secret key live only in the Edge Function environment.
- After any schema change, check `supabase db advisors` for zero security findings.
- Deleting an account signs the user out locally right away. Access tokens expire within an hour (Supabase default). A retried delete whose first attempt already deleted the user (response lost) succeeds: when the function answers 401, `AccountService.deleteAccount()` asks `GET /auth/v1/user` with the stored token, and only a definite `user_not_found` counts as deleted; any other answer keeps the error (`notSignedIn`), so a real auth failure is never reported as a deletion.
- Session tokens stay on this device: Keychain `ThisDeviceOnly`, wiped on the first launch after an install, and never written to the HTTP cache (see section 4).

## 7. Scale and reliability
- Load: at MVP scale (≤10k users, a few hundred rows each), Postgres on the free tier is ample. Every foreign key is indexed, and `quotes(owner_id, created_at desc)` serves the library query.
- The app works offline for reading (cache, widgets and reminders are all local). Writes need a network and show an inline error. Lookups that run before a write (`nextRotationPosition`, the username lookup in `sendFriendRequest`) skip the SDK's GET retries (1 + 2 + 4 s), and the Rotation write has no lookup at all, so an offline write fails at once.
- Reminders keep firing with no network. They run out about 20 days after the last app open (accepted; see §9).
- Monitoring: Supabase logs and advisors; `events` count of `web_search_tap` decides whether to build in-app discovery.
- Moderation: the app promises that reports are reviewed within 24 hours, so the founder checks the queue every day in the dashboard SQL editor: `select * from private.reports_to_review;` (unreviewed reports, oldest first, with the reported username, whether the snapshot is server-verified and how many reports that user has). Act on each (delete the content, or the account under Authentication > Users), then `update public.reports set reviewed_at = now() where id = '<id>';`. Optional alert: a Database Webhook (Integrations > Database Webhooks) on INSERT into `public.reports` that POSTs to an endpoint the founder controls; the payload is the whole report row, content included.

## 8. Trade-offs (explicit)
| Decision | Chosen | Alternative | Why |
|---|---|---|---|
| Reminders | Local notifications | APNs and a cron sender | $0, no server, works offline. The cost is no cross-device sync and the 64-pending cap. |
| Rich text storage | Plain `body` plus UTF-16 runs | Markdown or HTML | Lossless for B/I/U, trivially searchable and pushable, safe to render. |
| Search | Client-side plus a Google link-out | FTS RPC or a quote API | Instant, offline, no vendor or cost. Revisit past about 5k quotes per user. |
| Share content | Snapshot | A reference to the sender's row | Simpler RLS, stable for the recipient. Costs a little duplicate storage. |
| Editor | UITextView representable | iOS 26 rich `TextEditor` | Mature attribute APIs (font traits, underline) and precise toolbar toggling. Revisit as SwiftUI matures. |
| Account delete | Edge Function with admin API | SECURITY DEFINER SQL deleting `auth.users` | The documented, supported path. Keeps the service role off the database API surface. |

## 9. Revisit as it grows
A Share Extension (v1.1), which can use the App Group the widgets already have. Sign in with Apple. Background app refresh to top up reminders. Realtime for the shared inbox. Server-side FTS. Discovery through a structured quote API behind an Edge Function, only if `web_search_tap` shows demand. Multiple Rotations.

## 10. Founder steps that need your own accounts
1. **Hosted backend:** run `scripts/deploy-backend.sh`. It runs `supabase login` (browser), `link`, a dry run of `db push` with notes on what the pending migrations change, `db push` (asks for your DB password), `functions deploy delete-account` and the security advisors, then prints the dashboard checklist below.
2. **Supabase dashboard, before release** (the script prints the same list with direct links):
   1. **Custom SMTP (required).** Supabase's built-in email only delivers to members of your Supabase team, at about 2 emails an hour, so sign-up confirmation and "Forgot password?" fail for every real user ("Email address not authorized"). Set up a provider (Resend, Postmark or Amazon SES), verify your sending domain (SPF, DKIM), and enter host, port, username, password, sender name and a sender address on your domain under Authentication → SMTP Settings.
   2. **Email rate limit:** custom SMTP starts at 30 emails an hour; raise it under Authentication → Rate Limits.
   3. **Email templates:** reword "Confirm sign up" and "Reset password" for Quoted (keep `{{ .ConfirmationURL }}`).
   4. **Redirect URL:** Authentication → URL Configuration, add `quoted://auth-callback`.
   5. **"Confirm email":** decide under Authentication → Sign In / Providers → Email. Recommended on for release, only once 1–4 work. You may turn it off for quick MVP testing. Then test sign-up and "Forgot password?" end to end with an address that is not on your Supabase team.
   6. **App Review demo account:** Authentication → Users → Add user (auto-confirmed). Give it a username, a few quotes and a friend who has shared a quote, so the reviewer can reach Friends, Shared with you, Report and Block. The credentials go in App Store Connect → App Review Information, never in the repo.
   7. **Daily report check:** see section 7 (Moderation). Optionally add the Database Webhook alert described there.
3. **Support address:** set `SUPPORT_EMAIL` in `Config/Release.xcconfig` (Info.plist `SupportEmail`: Account → Contact support and the contact line of the bundled Privacy Policy, Terms and Guidelines). The `Check release settings` build phase fails any Release build or archive while it is empty, or while a legal page still has a draft banner.
4. **Legal pages:** have `App/Resources/Legal/*.md` reviewed, then publish the Privacy Policy and a support page at public URLs (for example GitHub Pages) for App Store Connect.
5. **Xcode:** choose your Team under Signing for both targets. If the bundle ID prefix `com.hwei` is taken, change it, along with the App Group `group.com.hwei.quoted`. Then Product → Archive → Distribute to App Store Connect, TestFlight first.

The full submission walkthrough (App Privacy label, age rating, demo accounts, review notes, export compliance, screenshots, versioning) is `docs/app-store-submission.md`.
