# Decision: open product questions from the 2026-10-26 UX audit (LLM Council)

## Status

Recommended by the council, not yet approved by the founder. The source is `docs/reviews/2026-10-26-ux-audit.md` ("Needs a product decision").

---

**Checked against the code after the council (it had no code access):**

- **App Review gates.** Already met. In-app account deletion exists (Account > Delete account, which calls the `delete-account` Edge Function). Report and Block exist for requests, friends, shared quotes and (since 2026-10-25) friend profiles. The only open part is Sign in with Apple's token revocation on deletion, which is needed only once item 1 ships.
- **"Adding a quote doesn't work"** was reproduced on build 5. It is the Reminders "Add quotes" dead end (audit F1), not a save bug. Build 5.1 fixes it (audit "Suggested order").
- **Shuffle "no repeats within a day" and "catalog quotes cached on device, with seal, background Save, outbox"** are already in `docs/new-quotes-in-reminders.md` (sections 5 and 6).

## Chairman verdict

## Where the Council Agrees

- **Support address (2):** all five advisors want the personal Gmail replaced before submission. Keep it in one constant that Account, the Privacy Policy, the Terms and the App Store support URL all read.
- **Usernames (6):** before submission, add one line under the field saying the name can't be changed.
- **Shuffle (7):** today's "random order" label is false. Deal the quotes like a shuffled deck, reshuffle after every full pass, and don't let the last quote of one pass open the next.
- **Friend alerts (4):** add a "Friend activity" toggle that works separately from reminders.
- **Reminder sound (3):** an in-app sound control is needed. The advisors disagree only on the default.
- **Nudge (9):** move the nudge into the last queued slot instead of sending it after reminders stop. Build 6.
- **Unsend (5):** never. Four of five agree, because Undo is the honest version. Nobody wants export/import.
- **Friend profiles (10):** make the sender's name tappable, keep favorites private by default, and ask once, in context.
- **Sign in with Apple (1):** offer it as an optional link on the existing anonymous account, not a sign-in wall. The advisors disagree only on timing.
- **Search chips (8):** today's chips mostly show "nothing matches". Later they should open the catalog themes.

## Where the Council Clashes

| Clash | Ruling |
|---|---|
| **When to ship Sign in with Apple.** The Executor says after launch; the other four say before submission. | **Before submission.** The Contrarian's point decides it: usernames are permanent and a reinstall kills the account, so every lost phone also burns a name and a friend graph for good. A "lost everything" review is the worst possible launch review for a trust brand. Build 6 goes to TestFlight without it; the App Store build needs it. |
| **Keep the local cache after an iCloud restore.** The Outsider, Expansionist and Executor say keep it; the Contrarian and First Principles say skip. | **Skip it.** Quotes with no account behind them never sync. With Sign in with Apple, a restore gets the library back from the server. Until then, say plainly in Account: "Your library lives on this iPhone." |
| **Sound on or off by default.** | **Neither.** Use a native Picker with three choices: *Off / First reminder of the day / Every reminder*. Default to *First reminder of the day*: the user notices the daily quote, and you avoid 12 chimes that end with every notification from the app switched off in iOS Settings. |
| **Is reshuffling the fix for "same 5 quotes"?** The Outsider, Contrarian and Executor imply yes. | **No. First Principles is right.** A reshuffled set of five quotes is still five quotes. Reshuffle anyway so the label is true, but the real fix is mixing new verified quotes into reminders. |
| **"Mix in new quotes": opt-in (Expansionist) or default (First Principles).** | **On by default, with an off switch.** It is exactly what the tester asked for. |
| **One username rename later.** | **No rename in v1.** A released name lets someone else take it and pose as the old owner. Sign in with Apple removes the main reason to rename. |
| **Search chips now: hide them all, hide until about 20 quotes, or show only chips that match.** | **Show only chips that match something in the library.** It is the smallest change, and it never shows a dead end. |
| **Expansionist's extras:** custom chime, universal links, groundwork for other devices. | **Later.** None of them changes whether the app works at launch. |

## Blind Spots the Council Caught

- **"Adding quote doesn't work" went unanswered.** The tester reported it and no advisor mentioned it. It may be why the library is stuck at the 5 onboarding picks, which would make it the root cause of the whole complaint.
- **Too many reminders for too few quotes.** Five quotes at 12 reminders a day means each quote plays about 2.4 times daily, however it is shuffled. Rule: no quote repeats within a day, and spare slots are filled with new catalog quotes.
- **Catalog quotes must already be on the phone.** A local notification carries its text when it is scheduled, so catalog quotes have to be cached on the device before planning. They must keep their verified seal and attribution. Link them by catalog id, not by matching text.
- **Widgets repeat too.** They must draw from the same daily selection as reminders.
- **"Save" on a notification needs real work.** It needs a background notification action, plus a local outbox that retries if the save fails while the app is in the background.
- **App Review gates.** Guideline 5.1.1(v) requires in-app account deletion; confirm it exists. With Sign in with Apple, deletion must also revoke the Apple token, which needs an Edge Function holding the Apple keys, so budget for it. Guideline 1.2 asks apps with user content (usernames, user-typed quotes shared with friends) to offer report and block, and nobody checked that they exist.
- **iOS keeps at most 64 pending notifications** (caught only by the Contrarian). Reminders and friend alerts compete for them, so set slots aside explicitly.
- **Onboarding needs a restore entry point.** A returning user on a new iPhone needs "Already have an account? Sign in with Apple" before the username screen. Otherwise they make a new anonymous account first and hit an "identity already linked" conflict.
- **Account switching rule:** switch only when the current anonymous account is empty, and never merge two accounts.
- **Supabase linking:** check the supabase-swift sources for native Apple ID-token linking before you build it. Manual linking must also be enabled in Auth config.

## The Recommendation

"Before submission" means the item gates the App Store build. "Build 6" means it ships in the next build if ready, otherwise in the first update.

| Item | Decision | Priority | Reason |
|---|---|---|---|
| 0. Adding a quote is broken | Reproduce on build 5 and fix, whether it is a bug or confusing UI | **Before submission (first)** | A broken core action, and likely the cause of "same 5 quotes" |
| New quotes in Reminders (the tester's complaint) | On by default. Each day: no repeats, at least 1 in 3 reminders are verified catalog quotes from the themes of the user's picks, and spare slots go to catalog quotes. Quotes are cached on the device, carry the verified seal and get a background "Save" action. Widgets use the same daily selection | **Before submission**, headline of build 6 | Shuffling can't make five quotes feel new, and launch users would hit the same staleness |
| 1. Account durability | Optional "Back up with Apple" in Account and "Sign in with Apple" on the first onboarding screen. Link to the existing anonymous account, switch only when the current account is empty, never merge. Token revocation on deletion. Copy "Your library lives on this iPhone" until it ships. No export/import, no keeping the local cache | **Before submission** (not build 6) | Permanent usernames make every reinstall permanent damage |
| 2. Support address | support@ on your domain forwarding to Gmail, or a dedicated Quoted Gmail if you have no domain. One constant | **Before submission** | It exposes your real name and looks like a side project |
| 3. Reminder sound | Notifications section, Sound picker: Off / First of the day (default) / Every reminder | **Before submission** | Twelve chimes leads to all notifications switched off, and the founder never sees it happen |
| 4. Friend alerts | "Friend activity" toggle, default on, separate from reminders. Ship with the tap-destination fix, or cut the alerts | **Before submission** | An alert you can't turn off that leads nowhere feels broken |
| 5. Sent record and unsend | "Shared between you" on the friend profile, both directions. No unsend | **Build 6**; unsend **never** | Covers the record and fills empty profiles; Undo is the honest limit |
| 6. Usernames | One line: "You can't change this later." No rename | **Before submission**; rename **never** in v1 | Prevents regret; a released name invites impersonation |
| 7. Shuffle | Deal like a deck, reshuffle each pass, no repeat across the boundary, no repeats within a day | **Before submission** | About an hour of work, and it makes the "random order" label true |
| 8. Search chips | Now: show only chips with matches. Build 6: chips become the 7 catalog themes, library results first, then "From the collection" with Save and the seal | **Before submission** / **Build 6** | Stops the empty first impression without building chips twice |
| 9. Late nudge | The last queued reminder still shows its quote, with "Open Quoted to keep reminders coming" added. Also replan reminders in the background refresh that already runs for friend alerts. Keep slots set aside below the 64 cap | **Build 6** | No silent gap, at almost no cost |
| 10. Friend profiles | The sender's name opens their profile everywhere. Favorites stay private by default. Ask once when the first friend request is accepted. Move the toggle to the top level of Account | **Build 6** | Fills profiles without quietly making favorites public |
| App Review gates | Confirm in-app account deletion. Add report and block for users and shared quotes | **Before submission** | Rejection risk under 5.1.1(v) and 1.2 |
| Custom chime, universal links, groundwork for other devices | Not now | **Later** | No launch value for a solo founder |

## The One Thing to Do First

Reproduce and fix "Adding a quote doesn't work" on build 5. If users can't add quotes, the library stays at the five onboarding picks, and every fix for "same quotes" only reshuffles a library that can't grow. After that, in order:
1. The afternoon of copy fixes (2, 6, and the "lives on this iPhone" line).
2. The shuffle and the no-repeats-within-a-day rule.
3. New quotes in Reminders.
4. Starting the Apple and Supabase setup for Sign in with Apple, since it has the longest lead time.

---

## Framed question

Quoted is a pre-launch iOS app (SwiftUI + Supabase, solo founder, TestFlight build 5): save quotes, get them as daily reminder notifications and widgets, share with friends. Accounts are anonymous (one per iPhone, no email or password). A UX audit found these open PRODUCT decisions (the engineering fixes are separate). Decide each one, briefly, with a recommendation and priority (before App Store submission / build 6 / later / never):

1. Account durability: a new iPhone or reinstall loses the account and library (Keychain item is this-device-only; an iCloud restore wipes even the local copy). An earlier council recommended Sign in with Apple as sign-in and account linking; the founder has not decided. Alternatives: export/import the library, or keep the local cache on restore so at least quotes survive.
2. The support address shown to users is a personal Gmail (hanningwei92@gmail.com) in Account, the Privacy Policy and Terms.
3. Every reminder plays a sound, up to 12 a day, with no in-app option (iOS Settings can turn sound off per app).
4. Friend-request and shared-quote alerts (local, from background refresh) can't be turned off in the app, even with reminders off; tapping one goes nowhere today (engineering will fix the destination).
5. There is no record of quotes you sent and no unsend after the 5-second Undo.
6. Usernames are permanent (server-enforced), but the Choose a username screen doesn't say so. Options: say so, or allow one rename.
7. Shuffle plays one fixed order forever (the seed changes only when the set of quotes changes), although the UI says "random order".
8. The Search tab's suggestion chips (courage, time, kindness, love, hope) search only the user's own library, so new users with ~5 quotes mostly see "nothing matches". A separate design is adding a verified quote catalog with themes (courage, calm, time, love, nature, purpose, self) and "new quotes in Reminders".
9. The "keep reminders coming" nudge arrives a full day after reminders stop when the app hasn't been opened (60 queued slots run out).
10. A friend's profile can only be reached from the Friends list, and "Show favorites to friends" is off by default and two levels deep, so most friend profiles will read "keeps favorites private".

Context: accuracy (verified public-domain quotes) is the brand; the only allowed third-party dependency is supabase-swift; no push notifications in v1; the founder wants UI/UX-friendly, native-feeling choices and will build what the council recommends.

## Advisor responses

### The Contrarian

**1. Account durability: before submission.** The real risk is losing the username, not only the library. Usernames are permanent and accounts die on reinstall, so a reinstall burns the name for good. Ship Sign in with Apple, but allow linking only when the new device's anonymous account is empty. Never merge two accounts, because merging brings in conflicts over friends and usernames. Keeping the local cache after a restore would leave quotes that never sync, which confuses more than a clean loss. Skip it.

**2. Personal Gmail: before submission.** It exposes the founder's real name and becomes a spam target. Use a domain address such as support@ that forwards to Gmail.

**3. Sound on every reminder: before submission.** Twelve chimes a day makes people turn off all notifications in iOS Settings, and that kills the core loop. Add an in-app Sound toggle, off by default.

**4. Friend alerts: before submission.** Same failure as item 3: people silence the whole app. Add a "Friend activity" toggle. If tapping an alert still goes nowhere at submission, cut the alerts.

**5. Sent history and unsend.** A Sent list can come later. Unsend: never. The recipient's phone already has local notifications queued, so an unsend can't reach them until their next refresh. It would promise something it can't do.

**6. Usernames: before submission.** Say clearly that the name is permanent. Don't allow renames in v1, because a released name lets someone else take it and pose as the old owner.

**7. Shuffle: before submission.** This is the founder's own complaint, and the UI claims a random order it doesn't deliver. Reshuffle on every planning cycle, and stop the last quote played from opening the next cycle.

**8. Search chips: before submission.** Hide them while the library is small; today they mostly show "nothing matches". When the catalog arrives (build 6), chips should open the catalog with an Add button and keep catalog results clearly separate from the user's own library.

**9. Late nudge: build 6.** Put the nudge in the last queued slot instead of after it. iOS keeps at most 64 pending local notifications, and friend alerts may use the same slots. Set slots aside or the queue runs out silently.

**10. Friend profiles: build 6.** Don't quietly make favorites public. Ask once, the first time someone opens a friend's profile. Also let people open a profile by tapping the sender's name on a shared quote.

### The First Principles Thinker

**Reframe.** These ten items come down to four problems:
- **Trust basics:** 1, 2, 6
- **Notification control:** 3, 4, 9
- **Discovery:** 7, 8, plus the founder's "same 5 quotes" complaint
- **Friend profiles that look empty:** 5, 10

1. **Account durability: before submission.** Losing the library is the only item here that destroys the product's value. Add Sign in with Apple as an optional "Keep your library" link on the existing anonymous account, not a sign-in wall. Skip export/import, because almost nobody uses it. A local cache with no account behind it is orphaned data, so no.

2. **Support email: before submission.** Use a support address on your own domain that forwards to the Gmail. Update Account, the Privacy Policy, the Terms and the App Store support URL.

3. **Sound: before submission.** A quote is never urgent. Add one Notifications section with a "Sound" toggle, off by default. Twelve chimes a day gets every notification from the app switched off.

4. **Friend alerts: before submission.** In the same section, add a "Friend activity" toggle that works separately from reminders.

5. **Sent record: build 6, merged with 10.** The friend profile shows the quotes you have exchanged, in both directions, and that is your record of what you sent. Unsend: never. Undo catches mistakes, and a quote is harmless.

6. **Usernames: before submission.** Add one line under the field: "You can't change this later." Allow one rename later, and only if support mail asks for it.

7. **Shuffle: before submission.** The "random order" label is false today. Pick a new order every time reminders are replanned, and don't repeat a quote until every quote has had its turn.

8. **Search chips: before submission,** show only chips that match something in the user's library. **Build 6:** the chips open catalog themes.

   **The founder's real complaint:** five picks show a taste, not a playlist. The main feature of build 6 is reminders that mix library quotes with verified catalog quotes from the picks' themes, about one in three new, each with a Save action. This is the "new quotes in Reminders" design, and it comes before everything else in build 6.

9. **Nudge: build 6.** Make the last queued reminder the nudge itself ("Open Quoted to keep these coming"), so it arrives exactly when reminders stop.

10. **Friend profiles: build 6.** Tapping the sender on any shared quote opens their profile, and the quotes you've exchanged fill it. Keep favorites private by default, but ask once, when the first friend request is accepted.

### The Expansionist

1. **Account durability: before App Store submission.** Add Sign in with Apple as an optional "Back up your library" step that links the existing anonymous account, so nothing is migrated. Offer it after the 5th saved quote or the first friend added. It also prepares for iPad, Mac and widgets across devices later. In the meantime, keep the local cache when the phone is restored from iCloud.

2. **Support address: before submission.** Buy the domain and use something like support@ at it. The same domain later carries universal links for shared quotes, which turns sharing into a way to bring in new users. A personal Gmail looks unreliable for a brand built on accuracy.

3. **Reminder sound: build 6.** Add a Sound toggle in Reminders, on by default. Ship one soft custom chime as the app's signature sound. iOS allows a sound file bundled with the app, so no new dependency is needed.

4. **Friend alerts: before submission, alongside the engineering fix.** Add a "Friend activity" toggle that works separately from reminders. Make the tap destination good: open the shared quote with a one-tap "Save to library". This is the app's social loop, so it should work well.

5. **Sent quotes: build 6.** Give each friend a "Shared" history in their profile, mixing quotes sent and received. That turns the record into a light conversation thread. Unsend from that view can come later.

6. **Usernames: before submission.** Add one line of copy saying usernames are permanent. Permanence makes a username a handle people can rely on. A single rename can wait until later, if support requests ask for it.

7. **Shuffle: before submission.** Reshuffle on every full pass through the library and never repeat the boundary quote. Then add an optional "Mix in new quotes" setting that draws from the verified catalog in the themes the user picked. This answers the founder's own complaint about seeing the same 5 quotes.

8. **Search chips: ship with the catalog, build 6 at the latest.** The chips should search the user's library first, then show a "From the collection" section with one-tap Save. This turns the most common empty state into the app's discovery feature.

9. **"Keep reminders coming" nudge: build 6.** Put the nudge text in the last 3 queued slots ("2 left, open Quoted to keep them coming") instead of sending it after reminders have stopped. Also replan the queue in background refresh whenever iOS allows it.

10. **Friend profiles: build 6.** Make usernames tappable everywhere: shared quotes, alerts and friend requests. When the user accepts their first friend, ask in context: "Let friends see your favorites?" Friends' favorites then become a second, trusted source of new quotes.

### The Outsider

**1. Account durability: before submission.** People find out about this only after the quotes are gone, and the result is a one-star review saying "lost everything". Add optional Sign in with Apple, labeled "Back up your library", in Account. Also keep the local cache when the phone is restored, which costs little. If Sign in with Apple slips, Account must at least say "Your library lives on this iPhone."

**2. Personal Gmail: before submission.** A personal address makes the app look like a side project and exposes the founder. Use a support@ address on the app's own domain everywhere it appears.

**3. Reminder sound: build 6.** Twelve sounds a day will make me turn off all of Quoted's notifications in iOS Settings, which kills the main feature. Add a "Play sound" toggle next to the reminder settings, on by default.

**4. Friend alerts: before submission.** An alert I can't turn off that leads nowhere when tapped makes the app feel broken. Add a "Friend activity" toggle that works on its own, apart from reminders, and ship it with the destination fix.

**5. Sent record and unsend: later, and never for unsend.** No new user will miss a sent list in v1. Once a friend has seen a quote it can't really be taken back, so the 5-second Undo is the honest version.

**6. Permanent usernames: before submission, one line.** Add "Usernames can't be changed later" under the field. People choose names quickly during onboarding, so add one free rename later.

**7. Shuffle: before submission.** This is the founder's own complaint, that the same 5 quotes keep repeating. The UI says "random order" while the order never changes, and a user who notices will think the app is lying. Reshuffle after every full pass through the library, and don't let the last quote of one pass also open the next.

**8. Search chips: before submission.** "Nothing matches" on first launch makes the app look empty. Hide the chips until the library has about 20 quotes, then point them at the verified catalog once it ships in build 6.

**9. Late nudge: build 6.** Use the last queued slot for the nudge itself ("Open Quoted to keep your reminders coming") so there is never a silent gap.

**10. Empty friend profiles: build 6.** A screen of "keeps favorites private" pages makes the social side feel dead. Ask once, when the first friend request is accepted: "Show your favorites to friends?" Also make the sender's name on a shared quote open their profile.

### The Executor

**Before App Store submission (about one afternoon of copy and config):**

- **2. Support email:** Replace the personal Gmail with a dedicated address, either support@ on your domain or a new Gmail used only for Quoted. Keep it in one constant that Account, the Privacy Policy and Terms all read. It takes 15 minutes.
- **6. Usernames:** Add one line under the field: "Usernames can't be changed later." Don't build rename for v1.
- **1a. Durability, the cheap half:** Stop wiping the local cache on restore. Say plainly in Account: "Your library is tied to this iPhone." Telling users is better than losing their library without warning.

**Build 6 (small fixes users will notice):**

- **7. Shuffle:** Deal the quotes like a shuffled deck, with a new seed each time the deck runs out and no repeat where one round ends and the next begins. It's about an hour in QuotedCore and easy to unit test. Ship it with the "new quotes in Reminders" work, since it's part of the same complaint.
- **3 and 4. Notifications section:** Add two toggles: "Reminder sound" (default on) and "Friend activity" (default on). Apply both when notifications are scheduled. Half a day for both.
- **9. Nudge:** Schedule the nudge before the queue runs out, at the slot a few before the last, not after it. Under an hour.
- **8. Search chips:** Hide them now. When the catalog ships, bring them back as the catalog's seven themes, showing library matches first and catalog quotes below. Don't build chips twice.
- **10. Friend profiles:** Make the sender's name on a shared quote open their profile. Keep favorites private by default, and ask once, when the user's first friend request is accepted: "Let friends see your favorites?"

**Later (first build after launch):**

- **1b. Sign in with Apple:** Offer it as an optional "Back up your account" step that links Apple to the existing anonymous account, with no new dependency. This takes the longest because you have to set up Apple and Supabase, so start that setup now. It shouldn't hold up submission, since few early users will change phones in the first weeks. Confirm in the supabase-swift sources that it can link a native Apple sign-in token before building.
- **5. Sent list:** Build a read-only list of sent quotes only if friends ask for it.

**Never:**

- **Export/import:** Sign in with Apple solves the same problem better.
- **Unsend after Undo:** The 5-second Undo is enough. Recalling a sent quote needs server work and tests, and nobody has asked for it.

**Order of work:** the copy fixes first (2, 6, 1a), then 7 with the catalog work, then the toggles (3, 4), 9, 8 and 10.

## Peer reviews (anonymized; Response A = The Outsider; Response B = The Contrarian; Response C = The Executor; Response D = The Expansionist; Response E = The First Principles Thinker)

### Reviewer 1

**1. Strongest: E.** E is the only response that correctly diagnoses the founder's own complaint. A shuffle fixes the order but not the repetition, so E makes catalog quotes from the user's themes, mixed into reminders with a Save action, the main feature of build 6. Grouping the ten items into four problems makes them easier to act on. C comes second: it sequences the work, gives effort estimates, keeps the support address in one constant and says to check that supabase-swift can link an Apple sign-in. C loses ground by pushing shuffle to build 6. B has the sharpest technical catches. A reinstall permanently burns the username, and friend alerts compete with reminders for the 64 pending-notification slots iOS allows.

**2. Biggest blind spot: D.** D ignores cost for a solo founder before launch. It adds a custom chime, a domain with universal links, per-friend conversation threads, background replanning and Sign in with Apple before submission, with no effort estimates. A also puts Sign in with Apple before submission without an estimate.

**3. What all five missed:**
- With 5 quotes and up to 12 reminders a day, each quote plays two or three times daily however well it's shuffled. The default reminder count should scale with library size until the catalog fills the gap.
- App Store guideline 5.1.1(v) requires in-app account deletion, so confirm it exists. Adding Sign in with Apple also means revoking the Apple token on deletion, which needs an Edge Function holding Apple keys. Whoever recommends it must budget for that.
- Catalog quotes in reminders need the verified seal, or the accuracy brand weakens.

### Reviewer 2

**1. Strongest: E.** E groups the ten items into four problems. It is also the only response that puts the founder's real complaint first in build 6: reminders that mix in verified catalog quotes from the themes of the quotes the user picked. E fills friend profiles by merging items 5 and 10, sets sound off by default, and keeps every fix small. C has the most realistic order of work, but it delays Sign in with Apple until after launch.

**2. Biggest blind spot: B.** B, like A, says reshuffling (item 7) fixes the "same 5 quotes" complaint. It doesn't: a reshuffled set of 5 quotes is still the same 5 quotes. B never proposes adding catalog quotes to reminders. It also rejects keeping the local cache after an iCloud restore, which is the cheapest way to keep a user's library. B's point about a reinstall permanently losing the username is a good one, and C misses it.

**3. What all five missed:**
- The founder also said "Adding quote doesn't work." That bug is part of the request, and no response mentions it.
- Up to 12 reminders a day from about 5 quotes means each quote repeats 2 or 3 times a day, whatever the order. The number of reminders a day should be limited by the library's size.
- Catalog quotes in reminders and widgets must be cached on the device and keep their verified attribution.
- A "Save" button on a notification needs its own action that saves without opening the app.
- App Review requires an in-app way to delete the account (Guideline 5.1.1(v)).

### Reviewer 3

**1. Strongest: E.** It groups the ten items into four problems, and it is the only response that answers the founder's real complaint. As E puts it, five picks show a taste, not a playlist. E makes catalog quotes mixed into reminders, each with a Save action, the main feature of build 6. Its calls on sound and alerts are coherent: one Notifications section, sound off, a separate Friend activity toggle. C comes second for its realistic effort estimates and order of work. But C pushes shuffle to build 6 and Sign in with Apple to after launch, which is risky when usernames are permanent.

**2. Biggest blind spot: D.** It adds work a solo founder can't absorb before launch: buying a domain plus universal links, a custom chime, a conversation-style Shared thread, iPad and Mac groundwork, and replanning in background refresh. It also makes "Mix in new quotes" an optional setting, when that is the very thing the founder asked for.

**3. What all five missed:**
- **"Adding quote doesn't work."** The founder reported this as a bug. It may be why the library is stuck at 5 quotes, so it should be fixed first.
- **A better shuffle can't fix this alone.** Five quotes at 12 reminders a day means each quote repeats about 2.4 times daily. A, B and C treat reshuffling as the answer. Only new quotes fix it.
- **Catalog text has to be on the phone in advance.** Local notifications carry their text, so catalog quotes must be cached on the device before reminders are scheduled. The same goes for the widget.
- **Nobody questioned the default of 12 reminders a day.**

### Reviewer 4

1. **Strongest: E.** It is the only response that separates the shuffle order (item 7) from the founder's real complaint. The founder chose five quotes to set a genre, not a playlist. Reshuffling those five still plays the same five. E makes catalog quotes from the themes of those picks, about one in three reminders and each with a Save action, the main feature of build 6. It also groups the ten items into four problems and folds the sent record (5) into friend profiles (10). B has the sharpest single point: usernames are permanent and accounts die on reinstall, so a reinstall uses up a username for good. That makes account durability more urgent than C's "later" allows.

2. **Biggest blind spot: A, with B close behind.** A quotes the "same 5 quotes" complaint and then answers it only with reshuffling, which reorders the same five. A also offers "one free rename" without weighing B's point that a released name lets someone else pose as the old owner. Next is C, which defers Sign in with Apple until after launch while usernames stay permanent.

3. **What all five missed:**
- **App Review requirements.** Once accounts exist, the app needs in-app account deletion (guideline 5.1.1(v)), and adding Sign in with Apple means revoking the Apple token on deletion. Friend requests by username between strangers likely need block and report (1.2).
- **Widgets.** They probably draw from the same set of quotes, so they repeat too.
- **"Adding quote doesn't work."** No one checked whether this is a bug or just friction.

### Reviewer 5

**1. Strongest: E.** It is the only response that groups the ten items into four underlying problems. It is also the only one that treats the founder's real complaint as a discovery problem, not a shuffle bug: "five picks show a taste, not a playlist." Its answer is to mix in about one catalog quote in three, each with Save, and to make that the main feature of build 6. B adds the sharpest technical points:
- A reinstall permanently burns the username, because names never come back.
- iOS keeps at most 64 pending notifications, and reminders and friend alerts compete for them.
- Linking should only happen when the anonymous account is empty, with no merging.

C has the best order of work and effort estimates, but it pushes the shuffle fix to build 6, and that fix is the founder's own complaint.

**2. Biggest blind spot: D.** For a solo founder before launch it piles on new scope with no effort estimates: a custom chime, buying a domain plus universal links, sent-quote threads, background replanning and timed prompts. C has a smaller one. It delays Sign in with Apple until after launch without seeing B's point that usernames are permanent, so every reinstall costs the name for good.

**3. What all five missed:**
- The founder also reported that adding a quote does not work. A broken core action comes before all ten items.
- App Store guideline 1.2 asks apps with user content (usernames and shared quotes here) to offer report, block and a contact. Without them the app risks rejection.
- None checked that account deletion exists in the app, which Apple requires.
