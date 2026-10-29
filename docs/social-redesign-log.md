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
| 2. Nav shell (Feed, Library, Inbox, Profile, Search) | | |
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

**2026-10-29, Stage 1 server.** Five migrations (`20261029090000` to `090400`):
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
- **Forwarding (`090500`):** a friend's post, or a quote someone sent you, can be sent on without saving it first. The server copies only what you can still read; anything else gets "This quote is not available."
- **Review fixes (`090600`):**
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
- **Deploy order.** The new server breaks TestFlight build 6 and earlier: they read a column, write a table and use quote types that no longer exist. Upload the redesign build, expire builds 6 and earlier, then run `scripts/deploy-backend.sh`.
- **Docker memory.** Four Supabase stacks share a 4 GB Docker VM. It runs out of memory and requests time out. Raising the limit in Docker Desktop (Settings > Resources) to 8 GB fixes it.

Known, for later stages: text and playlist messages have no screen until the Inbox (Stage 5). The Terms sheet's footnote overlaps the faded last row at the bottom (Stage 7).
