# Social redesign: progress log

Branch `social-redesign`, started 2026-10-28. One commit per stage. Nothing is pushed or deployed to the hosted project; run `scripts/deploy-backend.sh` yourself when you want the backend live.

## Founder answers (2026-10-28)

| Question | Answer |
|---|---|
| Who sees Feed posts and public Profile items | Friends by default. Each post or playlist can be made public. |
| Push notifications for messages and shares | Not yet. In-app badges only. |
| Creator shown when a quote is passed on | Always the creator's username. |
| Very long quotes in the quote view | Shrink to fit, down to a readable minimum size. |

## Assumptions

- The competitor is "Motivation - Daily quotes" (Monkey Taps).
- "Public library" means the verified catalog (today the starter pack). Playlists are new.
- Chats are between accepted friends only and can hold text, quotes and playlists. No photos.
- The untracked game and catalog docs stay out of every commit.

## Stages

| Stage | Status | Commit |
|---|---|---|
| 0. Research, council, baseline | done | Stage 0 commit |
| 1. Data model and endpoint security | done | Stage 1 commit |
| 2. Nav shell (Feed, Library, Inbox, Profile, Search) | done | Stage 2 commit |
| 3. Quote view fit and created-by label | | |
| 4. Feed and Library | | |
| 5. Inbox | | |
| 6. Profile and settings | | |
| 7. QA pass in the simulator | | |

## Log

**2026-10-28, baseline.** 130 package tests pass. The app builds (Debug-Local). The shared local stack lacks the 10-24 and 10-25 migrations, so 3 pgTAP files fail there (a stale stack, not a code fault). This work tests on its own stack in `build/socialstack` (ports 567xx) so the shared one stays untouched. On that fresh stack all 16 pgTAP files pass (511 of 511).

**2026-10-28, research.** Competitor report: `docs/research/2026-10-28-motivation-competitor.md`. Motivation has no social features at all, and about half of its 1-3 star reviews are about money. No quote app shows who said a quote, who added it and whether it was checked. That is the line Quoted owns.

**2026-10-28, council.** Two councils (social layer; content and identity), each with five advisors, anonymous peer review and a chairman, then a marketing positioning check. Record: `docs/decisions/2026-10-28-social-redesign-council.md`.

How I applied it (my calls, so you can overrule them later):
- **Stage order.** The council wanted each step on TestFlight before the next. You asked for data model first, then the nav shell, then each tab, so that order wins. Nothing ships between stages.
- **Public ("Anyone with your username").** Built into the data model, hidden in the app. The server allows it only for an account linked to Sign in with Apple, and none is linked yet. It turns on after your to-do items 7 and 8.
- **Deferred with Public:** the Declared Age Range check and bans tied to an Apple identity.
- **Report alert emails.** Need an email provider and its key in Edge Function secrets, so they wait for you. Until then the daily queue in `private.reports_to_review` covers every report type.
- **Blocked terms.** The server filter ships with an empty list. You fill it (to-do item 3); the tests use their own terms.

**2026-10-28, design.** Five designers specced the new screens, a critic reviewed them, and the result is now the UI contract (`docs/ui-spec.md`, commit "Spec the social redesign screens"). The critique changed two council rules for first-time users. The app opens on Feed only once a friend has posted, so new users don't land on an empty "quote of the day". With no friends yet, the quote screen's main button is Share Image instead of a Send that leads nowhere.

**2026-10-29, Stage 1 server.** Five migrations (`20261030030000` to `030400`):
- **Provenance and accounts:** a server-owned "Added by" on every quote, plus Undo that keeps it.
- **Safety:** versioned terms, suspensions, the word filter, retired usernames and the 150-friend cap.
- **Social data:** playlists, posts, and 1:1 conversations and messages (shares moved in, then dropped). Reports now cover every target, with an auto-hold after two reporters. Plus `profile_view`.

Only the two people in a conversation can read or send in it. Test file 19 proves this for every table and RPC, with a third user who is a friend of one of them.

Four attack reviewers found 21 problems and all 21 are fixed, each with a regression test. Among them:
- a blocked person could read messages back through their own report;
- a blocked sender could erase the blocker's evidence;
- an unsend could be detected from a timestamp;
- a hidden creator leaked on checked quotes;
- deleting items reset the daily limits;
- look-alike letters slipped past the word filter, and a long term list would have timed out the API.

1,260 database tests pass on a fresh reset.

Left for you (no change made):
- **"Edited from @name"** can be attached to any edit of that person's quote, and they can't remove it. This is the council's rule. Options: drop the name once most of the words change, or let the original creator detach it.
- **Usernames of deleted accounts are retired for good,** so a throwaway account can reserve a name. You can release one from the SQL editor.
- **Bumping the terms version** hides everyone's public items from strangers until each owner accepts again (friends are unaffected).
- **Not built yet:** report alert emails (need an email provider), the age check and Apple-identity bans. All wait for Public.

**2026-10-29, Stage 1b: forwarding, the data layer, the app on the new server.**
- **Forwarding (`030500`):** a friend's post, or a quote someone sent you, can be sent on without saving it first. The server copies only what you can still read; anything else gets "This quote is not available."
- **Review fixes (`030600`):**
  - Read marks stop at the newest message the app actually showed.
  - Reports about deleted items are no longer lost as duplicates. One person can file at most 3 profile reports a day about the same person.
  - A playlist reorder is saved in one statement.
  - "Shared with you" reads through an index instead of scanning every message.
- **QuotedKit:**
  - New models: provenance, account, posts, playlists, conversations, messages, profile page and reports.
  - New repositories: profiles, posts, messages, playlists and reports.
  - Every table read names its columns.
- **App:**
  - Today's screens now run on the new server; sending to a friend is now a quote message.
  - The Terms sheet appears before your first friend request, accept or send.
  - The per-quote Delete in "Shared with you" is gone: a received message can't be deleted on its own. Delete Conversation comes with the Inbox.

Two review rounds: four reviewers found 26 problems in the first, and three found 6 more in the fixes. 31 are fixed. The one left is the deploy order below. Fixed problems included:
- older shared quotes vanishing (only 50 per friend were read);
- opening Friends marking unloaded messages as read;
- two people who blocked each other could never unblock;
- a send cancelled during the terms check coming back later as a Terms sheet.

Tests:
- 1,378 database tests pass on a fresh reset.
- 128 data-layer and 164 core Swift tests pass.
- The live-server Swift tests pass. Docker had too little memory, so they passed one at a time: requests timed out at random while the VM was short of memory.
- The app builds with no warnings in our code, and I checked it in the simulator against the new server.

My calls:
- **Save a copy** of a friend's playlist starts as Only me, like everything else you save (the spec said Friends).
- Forwarding a friend's favorite or playlist item still saves it to your library first, because the server can't forward those yet. The Send sheet says so.
- At most 3 profile reports a day by one person about the same person (easy to change).

For you:
- **Deploy order.** The new server breaks every build without the redesign client. Builds 6 and earlier read a column, write a table and use quote types that no longer exist. Any later build cut from main with the catalog client (Verified Quotes) breaks too: it adds catalog quotes by writing their origin itself, which the new server refuses, and it reads and writes shares, which the new server drops. Upload the redesign build, expire every older build, then run `scripts/deploy-backend.sh`.
- **Migration order.** When main's catalog was merged in, the redesign migrations were renamed from `20261029090000`–`090600` to `20261030030000`–`030600`, after the newest catalog migration (`20261030022806_catalog_repin_001`), so `supabase db push` applies them in order. If another catalog migration reaches hosted first, rename them again to sort after it: they have never been deployed, and `db push` refuses local migrations older than the newest one on hosted. A local stack that applied the old names needs `supabase db reset`.
- **Docker memory.** Four Supabase stacks share a 4 GB Docker VM. It runs out of memory and requests time out. Raising the limit in Docker Desktop (Settings > Resources) to 8 GB fixes it.

Known, for later stages: text and playlist messages have no screen until the Inbox (Stage 5). The Terms sheet's footnote overlaps the faded last row at the bottom (Stage 7).

**2026-10-30, main's verified catalog merged in; Stages 0 to 1 are on main.** Main had gained the verified catalog (`catalog_quotes`, batches 001 and 002, the quote 88 re-pin, Verified Quotes). It conflicted with the redesign in 14 files and in the database, so it was merged into this branch first. Then pull request #1 merged the branch into main (merge commit `820af10`). Nothing was deployed.
- **Database:** the redesign migrations now point at `catalog_quotes` with integer ids, and any live catalog quote can be added, sent or posted by id. With shares gone, the catalog's reseal and withdraw functions now recheck quote messages and posts too. A copy that loses its seal gets back only its own sender's or author's credit.
- **Origin:** adding a catalog quote now goes through the server (`add_catalog_quotes`) instead of the app writing its origin.
- **Migration names:** the migrations were renamed to sort after the catalog's (see Migration order above).
- **Review:** three reviewers (catalog, security, contract) found 5 problems, and all 5 are fixed.
- **Tests:** 27 pgTAP files, 1,490 tests pass on a fresh reset, including the new `24_catalog_social`; the catalog's selftest and generate check pass; and 133 data-layer and 168 core Swift tests pass. The live-server Swift tests pass one at a time; run together, some time out on the VM's memory.

**2026-10-29, Stage 2: the nav shell.**
- **Tabs:** Feed, Library, Inbox, Profile, and Search at the bottom right. Each tab keeps its own back stack. The app opens on Library until friends' posts exist (Stage 4), then on the Feed once a friend has posted.
- **Feed (for now):** the "Checked against the source" page. It shows one quote a day from the whole live verified catalog (not only the 60 starters), sized to fit the screen, and "Quoted Catalog" opens how it was checked. The card menu has Save to Library and Send. The line under it depends on how many friends you have; with none, the main button is Add a friend.
- **Inbox:** the quotes friends sent you (moved from "Shared with you", which is gone), friend requests, and a Friends button. Its badge is the app's only badge.
- **Profile:** your header (long-press copies your username) and a gear that opens Settings (today's Account screen, renamed).
- **Friends** now opens from the Inbox. It lost its Account and "Shared with you" rows and gained Blocked Users.
- **Notifications:** the app icon is never badged, and the background "new quote" alerts are gone (badges only, as you chose). `quoted://inbox` opens the Inbox, and tapping an old alert goes there too.

Two review rounds. In the first, three reviewers found 19 problems: 10 were confirmed and 9 fixed, and the legal pages are left for you (below). In the second, three reviewers found 13: 8 were confirmed and all 8 fixed. Fixed problems included:
- on iOS 27 the Feed and Profile showed a search field that searched nothing;
- on iOS 26.5, opening the Inbox link or a reminder while typing in Search left a blank screen;
- going back to Search after Close could show the old results under an empty field;
- VoiceOver lost Next quote and Previous quote on the quote screen;
- when friends failed to load, the Feed told someone who has friends to add one.

**On the catalog (2026-10-30).** Stage 2 was written before main's catalog arrived, so it was moved onto the merged branch and adapted:
- **Quote of the day:** the Feed's quote now comes from the live catalog in id order. Each device remembers the day's pick, so a new batch or a retired quote doesn't change it mid-day. A withdrawn pick is replaced.
- **Reloads:** on a new day the Feed reloads the catalog and keeps the earlier quote until the reload answers, so the quote never swaps while you look at it. A Save or Send that fails because a quote was retired reloads it too.
- **Save and Send:** both go through the server's catalog add, and both stay disabled until the library has loaded. Send uses your checked copy of the quote. If you only have a look-alike you typed, Send saves a checked copy first (the toast says "Saved a checked copy").
- **Onboarding:** after a failed Continue, the starter list reloads, so a starter retired since the list loaded drops out.
- **Catalog adds:** the retry rule now always adds a new copy after you edited the old one. A retried add that overlaps the first one reads back the saved quote instead of showing an error.

Two review rounds on this. The first found 16 problems (12 once duplicates were merged), all fixed. The second found 8 small ones: 7 are fixed, and the eighth only in part (below).

Tests:
- 133 data-layer and 178 core Swift tests pass. The clean build has no warnings in our code.
- UI tests against the local server:
  - The friends and Inbox test passes on iOS 26.5 and 27.0, and sign-in passes on 26.5.
  - The full happy path passes on 26.5. On 27.0 one run walked every screen through Settings, then the test's own server read-back hit a database statement timeout.
  - The other 27.0 runs stopped at different steps. Each step had passed on 26.5, and each stop was a request the stalled Docker VM didn't answer in time.
  - One 27.0 run crashed inside Apple's Liquid Glass drawing, with none of our code on the crashing thread. Watch for it on a device.
- Checked in the simulator on iOS 26.5 and 27.0: the Feed with and without friends, the Inbox, Profile, Settings, Friends, Search and the deep links.

My calls:
- **Search placement.** Search is a field on its own tab, on iOS 26 and 27 alike, and Close goes back to the tab you were on. Stage 1 split the placement by OS, which on iOS 27 left a dead field on every tab.
- **Interim badge.** Until conversations have a screen (Stage 5), the badge counts friend requests plus friends whose sent quote you haven't seen, so opening the Inbox always clears it.
- **Send from the Feed saves first.** Sending the Feed's quote puts it in your library first (with a toast), because the send sheet needs a library quote until Stages 4 and 5.
- **Search's Inbox results** switch to the Inbox tab for now. In Stage 5 they open the conversation.
- **Quote of the day** changes after midnight the next time the Feed appears or the app comes back, never while you are looking at it.
- **"Blocked Users"** is now Title Case everywhere, as the spec's casing rule asks. Settings' other rows follow in Stage 6.

For you:
- **Legal pages** still name screens that are gone. "Shared with you" is now the Inbox, and "Account >" is now Profile > Settings:
  - `App/Resources/Legal/terms.md` lines 33, 35 and 41;
  - `community-guidelines.md` lines 29 and 31;
  - `privacy.md` lines 43, 49 and 61.

  Legal wording is your call. Stage 6 rebuilds Settings, so you may want to wait for it.
- **Deploy order and Docker memory:** unchanged from Stage 1b.

Known, for later stages:
- **Send from the Feed with a look-alike:** if your library holds an unchecked copy of the Feed's quote, Send adds a second, checked one. The Send sheet will send the catalog quote itself in Stage 5.
- Profile > Settings > Your profile shows your header a second time, until Stage 6 rebuilds Profile and Settings.
- The quote screen still shows the tab bar; the spec hides it there (Stage 3).
- A toast shown while you type in Search covers the field. At accessibility sizes, Friends cuts off "Your username: @…" (both Stage 7).
- **A delete that times out:** if the server deletes a quote but its answer comes after the app gave up waiting, the app keeps the quote on screen and Undo does nothing on the server. The next refresh then removes it. The UI tests hit this once on the stalled local server. The code is older than the redesign (Stage 7).
