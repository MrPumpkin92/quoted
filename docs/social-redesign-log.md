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
| 1. Data model and endpoint security | | |
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
