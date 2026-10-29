# Decision: the social redesign (two LLM Councils, 2026-10-28)

## Status

Decided by council (founder delegated), 2026-10-28. The founder fixed ten decisions and asked to stay hands off. Everything else here is decided and buildable now. As each step lands, `docs/system-design.md` is updated to match.

**What it decides:** the Feed, Inbox, Profile, Settings and Search; who added a quote ("Added by") and how its check status shows; playlists; the Library additions; safety; and the data model and server rules all of these need.

**Inputs:**
- The founder's answers of 2026-10-28 and the working assumptions (`docs/social-redesign-log.md`).
- The competitor report `docs/research/2026-10-28-motivation-competitor.md` ("Motivation - Daily quotes", Monkey Taps).
- Council A, "Social layer: Feed, Inbox, safety, search", and Council B, "Content and identity: created-by, playlists, library, profile, settings". Each had five advisors and five reviewers.
- A marketing positioning check on each verdict, measured against the ownable line: "Every quote in Quoted shows who said it, who added it, and whether anyone checked."

Where a positioning check changed a ruling, the Why column says so. Where the two councils disagreed, the last table in section 2 gives both sides and the ruling.

## 1. The founder's fixed decisions

These are not reopened. This record only decides how they work.

| # | Decision |
|---|---|
| 1 | Tabs: Feed, Library, Inbox, Profile, plus the search-role tab where it is now. |
| 2 | Feed: people send and post quotes. |
| 3 | Library stays as it is. It holds saved quotes, the verified catalog, playlists and favorites. Every quote shows who it quotes, who added it and whether it is verified. |
| 4 | Inbox: friends send each other quotes, text and playlists. Friends live here too. |
| 5 | Profile: playlists, favorites and how my added quotes appear, each with a hide choice. Settings are tucked away here. |
| 6 | Audience: friends by default. Each post or playlist can be made public (opt-in). |
| 7 | No push for messages or shares yet. In-app badges only. |
| 8 | When a quote travels, the next person always sees the original creator's username. Quotes made by people read as unverified with a hollow label. Catalog quotes keep the filled seal. |
| 9 | Long quotes shrink so the whole quote fits on screen, down to a readable minimum. |
| 10 | The server lets only the two participants read or send in a conversation. Tests prove it. |

## 2. Final decisions

### Build order

Each step goes to TestFlight before the next one starts.

| Step | Ships | Done when |
|---|---|---|
| 1 | Provenance migration (section 3), share snapshots built by the server, the seal and "Added by" lines, and the shrink-to-fit quote view. | pgTAP proves a forged creator or body is ignored or refused. |
| 2 | Tab shell: Feed (empty-state placeholder), Library (three new rows), Inbox (today's shares plus Friends), Profile (Settings behind the gear). | UI smoke test passes on the new tabs. |
| 3 | Conversations and messages in one release: shares move in, block hides instead of deletes, terms, word filter, wider reports, suspension, polling. | pgTAP proves a non-participant cannot read or send. |
| 4 | Friends-only posts and the Feed. | pgTAP proves strangers get zero posts. |
| 5 | Playlists, then playlist messages. | pgTAP proves a non-friend gets zero rows. |
| 6 | Public ("Anyone with your username"). Built hidden in steps 4 and 5, switched on only after the founder to-do items 6 to 8. | Sign in with Apple linking and the age check work. |

### Created-by and verification

| Decision | Detail | Why |
|---|---|---|
| The server owns the creator | The creator is the account that brought this wording into Quoted, by lineage. You, for anything you type or paste. The source's creator, when the server copies a row through a message, post, playlist or favorite. Never found by matching text across private libraries. No client can write it. | Both councils. A creator the client can write lets anyone put hate speech under @alice. Text matching would reveal who privately keeps a line. |
| Label words | "Added by @alice", "Added by you", or "Added by a person" when the creator is unknown or deleted. Never "Created by", "by @x" or "from @x". An empty author shows "Unknown author". | Outsider's copy rule, adopted by both. "Created" reads as authorship. Council B wanted "a former member"; that is false for old shares whose creator still has an account. |
| Unverified glyph | Hollow `seal` (no check mark) in `.secondary`. | Founder decision 8 asks for a hollow label. Positioning A: a check mark on unchecked text says "checked". Positioning B: a person glyph breaks the filled and hollow seal pair. |
| Verified glyph | Filled accent `checkmark.seal.fill` with "Quoted Catalog". The Library "+" menu item switches from hollow `checkmark.seal` to the filled seal. | Decision 3 needs a creator line on every quote. "Added by Quoted" misstates what Quoted did. The "+" item was the one hollow check in the app (positioning A). |
| Rows (your Library, Search) | One footnote line under the attribution: glyph plus "Added by you", "Added by @alice", "Added by a person" or "Quoted Catalog". Your own rows never say "Not checked". | Council A wanted the seal alone on rows. Both positioning checks changed it: rows must say who added it, and your library must not read as a list of failures. |
| Cards from other people | Feed posts, messages, playlist views and friend favorites read "Added by @alice · Not checked" or "Quoted Catalog · Checked". | Positioning B: trust matters most here, and a glyph alone drops "whether anyone checked". |
| Single-quote screen | Under the author and source, past a divider. Verified: filled seal, "Quoted Catalog", then "Checked word for word against Meditations, Book 4", linked to `source_url`. Unverified: hollow seal, "Added by @alice" as a button, "Edited from @bob" when set, then "Not checked against a source". It wraps, keeps its height and never shrinks. | Positioning B swapped the bare "Checked word for word" for the edition, which `starter_quotes` already stores. "Against a source" answers positioning risk 1: it describes sources, not a grandparent's honesty. |
| Provenance sheet | Tapping that block opens one sheet, extended from `VerifiedQuoteSheet`: who added it, edited from, the check status in one sentence, "View @alice's profile", and Report ("Wrong wording" on catalog quotes). | Positioning B: the tap answers a trust question before a social one. |
| Editing someone else's wording | Allowed in place. If you are not the creator and you change the body, author or source, you become the creator and the previous creator becomes "edited from" (none if the old row was verified). Formatting-only edits change nothing. The editor says: "Changing the words makes this your version. @alice stays as edited from." | Council B over Council A's "Edit a copy" lock. One row, no duplicate in the Library. Bob's words never sit under Alice's name, and Alice stays visible (decision 8). |
| VoiceOver | "Added by alice, not checked", "Added by you, not checked", "Quoted Catalog, checked word for word". | Council B. |
| Widgets and notifications | No added-by text. Glyph at most. | Council B. No room, and Reminders are private. |
| Long quotes | The single-quote screen steps the serif body down through fixed sizes with `ViewThatFits`, from the display size to the user's Dynamic Type `.body` size. If it still does not fit, the page scrolls. It never truncates. Only the quote body shrinks. | Decision 9. A floor at `.body` stays readable at every Dynamic Type size. |

### Feed

| Decision | Detail | Why |
|---|---|---|
| What a post is | One quote snapshot plus an optional caption of up to 280 characters. Source: any quote in your Library or the Quoted Catalog. "New quote" in the composer saves to your Library first, then posts. The server copies text, author, source, creator, edited from and seal at post time. | Council A. What friends saw is exactly what gets reported. |
| Editing | Neither text nor caption can be edited. "Who can see this" can change any time. Delete removes the post for everyone. Copies other people saved stay, still credited to the creator. | Council A, all but the Expansionist. |
| Card order | Quote, then attribution and provenance line, then a sans footer: "@bob · 2h" and the caption. The caption never sits inside or above the quote. | Positioning A changed Council A's tweet layout. The poster must not outrank the creator. |
| Who sees it | You and your accepted friends. Choices: "Friends" (default) or "Anyone with your username" (step 6). Strangers never appear in your Feed. | Decision 6. No global feed (both councils). |
| Order and refresh | Newest first, 30 per page, no ranking. Refreshes on return to the app when more than 60 seconds stale, and on pull to refresh. No Feed badge. | The research lists ranking and push per post under "avoid". |
| Actions | Every post: "Save to Library" and "Send". Your own: "Who can see this", Delete. Others': Report, "Report and Block". No reactions, comments, reshare button, counts or list of who saved. To repost, save it and post from Library; the creator stays credited. | Council A. Reactions are counts by another name. Comments are a moderation surface a solo founder cannot staff. |
| Launch tab | Library until the user has one accepted friend, then Feed. | A new user's first job is building a library. |
| Empty Feed | Titled "Checked against the source": one catalog quote picked on the phone by day number, with its edition line and filled seal. One filled button: "Add a friend" with no friends, "Post a quote" with friends but no posts. No suggested people or filler. | Council A ruling. Positioning A retitled "Today from the Quoted library", which sounded like Motivation's daily quote. |

### Inbox

| Decision | Detail | Why |
|---|---|---|
| Conversations | 1:1 only, started only between accepted friends. No groups. No photos. | Groups double the RLS tests and the moderation load. |
| Message kinds | Text up to 1,000 characters. A quote (server snapshot) with an optional note up to 280. A playlist: a live link plus a copy of its title, which reads "This playlist is no longer available" once access ends. | Council A, ruling 4. No photos keeps image moderation out of v1. |
| Send sheet footnote | Your own quote: "Your username stays with this quote." Someone else's: "Added by @alice stays with this quote." | Council B: senders were never told a name travels. |
| Today's shares | Move into conversations in one migration. "Shared with you" is retired. | Copy rule: one place for what friends send. |
| Unsend | The sender, any message, any time, gone for both. The server keeps a hidden copy 30 days for moderation. | Council A. A report still works after an unsend. |
| Delete for me | "Delete Conversation" only. It hides everything up to that moment, for you. | Council A ruling 5: one column instead of a table of hidden messages. |
| Read state | Each person has a private last-read time that drives their own badge. Nobody sees "Seen" or "Saved". "In your library" is worked out on the recipient's phone. | Council A ruling 8. A saved flag the sender could read would be a receipt, so messages carry no saved column. |
| Texts off | "Friends can text me", on by default, in Profile › Settings › Privacy. Off stops text only; quotes and playlists still arrive. The sender's composer then reads "@alice receives quotes only". | Council A ruling 9. Sending quotes is the core. Unfriend or block already give silence. |
| Unfriend | The conversation stays, read-only for both. A new accepted friendship reopens it. | Council A. |
| Friends | A `person.2` button in the Inbox toolbar opens Friends: add by exact username, "Share my username", requests, list, Blocked users. Pending requests also show as the Inbox's top row. | Decision 4. Both councils move Friends out of Settings. |
| Delivery | No push, no Realtime. The app checks every 10 seconds while a conversation is open, and refreshes when the Inbox appears, on return to the foreground and on pull to refresh. Background refresh stops posting local alerts for shares and requests. | Decision 7. Polling keeps one access path for the decision 10 tests. |
| Badge | The Inbox tab only: unread conversations plus pending incoming requests. The app icon badge is cleared and never set again. | Positioning A cut Council A's icon badge. It reads as nagging and needs notification permission. |

### Safety

| Decision | Detail | Why |
|---|---|---|
| Word filter | Server only, a short list: slurs, explicit sexual terms, threats. Checked on every text another person can see: captions, message text and notes, quote snapshots in posts and messages (catalog quotes exempt), playlist titles, display names and new usernames. Live views (playlists, friend favorites) skip unverified items that match, at read time. The private Library is never filtered. Error QR003: "Quoted doesn't allow some words in posts and messages." | Council A ruling 2. A list inside the app exposes it and is a second copy to keep in sync. The read-time check covers live edits, which a write check misses. |
| Reports | On posts, messages, playlists, profiles and catalog quotes. Reasons: spam, harassment, inappropriate, copyright, wrong wording (catalog only), other. The server copies the content at report time. The item disappears for the reporter at once. Every report alerts the founder, who acts within 24 hours. | Guideline 1.2 covers friends-only content too (Council B). Positioning B added "wrong wording". |
| Auto-hold | Two different reporters on one post or playlist hide it from everyone but its owner until the founder clears or removes it. | Council A applied this to public items only. Holding all items covers the 24-hour promise when the founder is late. |
| Block | "Report and Block" stays one action. Block ends the friendship and any pending request and closes the conversation. The blocked person loses the conversation and the blocker's posts, playlists, favorites and profile. The blocker keeps the conversation read-only, to report from it. Nothing is deleted. Unblock does not reopen it; a new friendship does. | Council A ruling 1. Today's trigger deletes shares both ways and destroys the evidence a report needs. |
| Terms | A versioned sheet at the first social action: friend request, accept, post, message, or a playlist visible to others. Zero-tolerance wording. | Guideline 1.2. |
| Friend cap | 150 accepted friends. Error: "Quoted keeps circles to 150 friends." | Positioning A changed Council A's 500, which read as a generic social network. |
| Suspension and bans | The founder suspends an account from the SQL editor. It stops every social write and holds all their posts and playlists. Bans attach to a hashed Apple identity, so they survive a reinstall once the account is linked. | Council A blind spot: bans don't stick on anonymous accounts. |
| Anonymous accounts | Everything social works on anonymous accounts. Only "Anyone with your username" needs a linked Sign in with Apple account. | Council A ruling 3. Every account is anonymous today (system design F1). |
| Age | The rating stays 16+, already set by the in-app browser. Apple's Declared Age Range check runs at the first social action. Anyone declared under 18 cannot use Public. The server cannot verify the answer, so it gates only Public. Verify the API in the iOS 26 SDK before building. | Council A. Messaging and user content are already answered Yes. |
| Copyright | A "Copyright" reason now. A published contact email and a registered DMCA agent before Public ships. | Blind spot in both councils. |

### Search

| Decision | Detail | Why |
|---|---|---|
| Place | The same search-role tab, bottom right, one field. | Decision 1. |
| Groups, in order | Your Library (on the phone: quotes, your playlists by title, favorites). Inbox (on the phone: loaded messages). Friends' posts (server, only posts already in your Feed, 20 results). Quoted Catalog. People (exact username only, at most one). "Search the web" stays last. | Council A ruling 7: it finds only what you can already reach. |
| Tokens | Native search tokens "Checked" and "Added by people", plus "Added by @name" offered when the query starts with @ and matches you or a friend. | Positioning A: search missed the seal entirely. |
| Never searchable | Strangers' public items, partial usernames, other people's playlists. | Both councils. Each would let someone list usernames. |

### Playlists

| Decision | Detail | Why |
|---|---|---|
| What it is | A named, ordered list of quotes from your own Library. Adding a catalog quote saves it to your Library first. Title of 1 to 60 characters. | Council B ruling 3: one foreign key, one RLS path, one place for provenance. |
| Who can see it | "Who can see this": Only me, Friends (default), Anyone with your username (step 6). A playlist can be public only if every item is verified, or added by you with no "edited from". | Council B. The rule stops other people's usernames reaching strangers without their opt-in. |
| Sending | Sends a playlist card to a conversation. Sending an Only me playlist asks to switch it to Friends. The friend gets a live, read-only view with one filled action, "Save a Copy", plus Save on each quote. A copy lands in their Playlists and Library, each quote keeping its creator. | Councils A (ruling 4) and B. It answers "send folders to friends" from the competitor's reviews. |
| Owner changes | An edited quote shows live, under the edit rule. A deleted quote leaves the view; saved copies stay. A deleted or narrowed playlist, an unfriend or a block turns the card into "This playlist is no longer available". | Council B. |
| Reminders | A playlist never means Reminders. No live link. Your own playlist's "…" menu has "Add All to Reminders", a one-time add. Empty state: "A playlist is a list you can share. To get quotes on your Lock Screen, use Reminders." No music glyphs. | Council A wanted the action; Council B rejected a live feed into Reminders. A one-time add satisfies both. |
| Limits | 100 playlists, 200 items each, 20 new per 24 hours. | Council A's daily limit over B's 50. Nobody needs more on day one. |

### Library

| Decision | Detail | Why |
|---|---|---|
| Root | Today's list, rows, swipes and Reminders stay. One section on top with three stock `NavigationLink` rows: Favorites (heart), Playlists, Quoted Catalog (filled seal). | Decision 3. Apple Music pattern, stock controls (Council B). |
| One name | The verified catalog is "Quoted Catalog" everywhere: the Library row, the search group, the provenance line and the "+" menu ("From the Quoted Catalog"). Never "public library". | Council B: "public" now means an audience. Council A's "Quoted library" clashes with the Library tab. |
| Catalog screen | Opens with the promise: "Every quote here was checked word for word against a public-domain edition." No count. | Positioning B: "catalog" hints at volume. |
| Rows | Gain the provenance footnote line. | Decision 3. |
| "Shared with you" | The row leaves Library. What friends send lives in the Inbox. | Copy rule. |

### Profile

| Decision | Detail | Why |
|---|---|---|
| Header | Display name and @username. No counts, bio or avatar upload. | The research lists follower counts under "avoid". |
| Sections, in order | 1. "How your quotes appear": a preview card of one of your quotes as friends see it ("Added by @you · Not checked"). 2. Posts. 3. Playlists. 4. Favorites. | Positioning B: it answers decision 5 literally and shows that your username travels. |
| Hiding | One control per item, "Who can see this". Posts: Friends or Anyone with your username; remove one by deleting it. Playlists: Only me, Friends or Anyone. Favorites: Only me (default) or Friends, never Anyone, because favorites hold other people's quotes. | Council B. The Expansionist's extra "Show on profile" toggle is rejected. "Favourites playlists" and "favourite quotes" are read as one Favorites section (four of five advisors). |
| Your added quotes | They show on your Profile only through Posts. No switch that opens your typed Library. | Council B ruling 4. Quotes stay private to their owner, and posting stays the one deliberate act. |
| View as | A toolbar menu previews the profile as Friends, and as Anyone (after step 6). | Council B. |
| Someone else's profile | Opens from any @username: the provenance sheet, conversation headers, post footers, playlist owner lines, friend rows. A friend sees Friends and Public items. Others see Public items or "@alice hasn't shared anything publicly". Blocked by them: "This profile isn't available". You blocked them: "You blocked @alice" with Unblock. Filled action: Message (friend) or Accept (they asked). Strangers get no filled action; Add Friend, Report and Block sit in the "…" menu. | Council B, changed by positioning B: a stranger's page must not be an empty "Add Friend" page. |

### Settings

| Decision | Detail | Why |
|---|---|---|
| Where | A `gearshape` button on your Profile pushes a Settings `Form`. The Account and "Your profile" screens go away. | Decision 5. |
| Rows | Account: Display name, Username (read only, "You can't change this"), Back up with Apple (once it ships). Reminders. Privacy: Friends can text me, Blocked users. About: Community guidelines, Terms of use, Privacy policy, Contact support. Then Sign out (only when allowed) and Delete account. Version footer. | Council B. Terms and contact stay one tap from the profile (Guideline 1.2). |
| Copy rules | "Post" means the Feed. "Send" means to a friend. "Share" means only the iOS share sheet. "Added by", never "Created by". "Playlist" never means Reminders, and "Rotation" never appears. | Outsider's rules, both councils. |

### Where the two councils disagreed

| Topic | Council A | Council B | Ruling |
|---|---|---|---|
| Unverified glyph | Hollow `checkmark.seal` | `person` | Hollow `seal`, per both positioning checks and decision 8. |
| Unknown creator | "Added by a person" | "Added by a former member" | "Added by a person". It is true for old shares too. |
| Editing another's quote | Lock; "Edit a copy" | Edit in place, creator moves, "edited from" kept | Council B. |
| Column names | `created_by_*` | `creator_*`, `based_on_*` | `creator_*` and `edited_from_*`, matching the UI words. |
| Public label | "Anyone with your username" | "Everyone" | Council A. Plain words stop people reading it as the whole internet. |
| Catalog name | "Quoted library" | "Quoted catalog" | "Quoted Catalog". |
| Verified detail line | "Checked against the source" | "Quoted catalog · Checked word for word" | "Quoted Catalog" plus "Checked word for word against [source, location]" (positioning B). |
| Rows | Seal only | "Added by" line | Glyph plus "Added by" line (both positioning checks). |
| Playlists and Reminders | "Add to Reminders" on every playlist | No link | One-time "Add All to Reminders", no live link. |
| Playlist limits | 20 per day | 50 per day, 100 total, 200 items | 20 per day, 100 total, 200 items. |
| Report shape | One nullable FK column per target | `(target_type, target_id)` | FK columns. They keep `on delete set null` and follow `share_id`. |
| Stranger reads | `profile_public_items(username)` | `profile_view(user_id)` | One `profile_view(username)`, exact match like `find_profile`. |
| Who builds snapshots | BEFORE INSERT triggers plus column grants | DEFINER RPCs (`send_quote`) | Triggers for posts and messages. DEFINER functions only for saves into `quotes`. |
| Searching playlists | Yes, on the phone | No | Your own only. |

## 3. Data model and server rules

Facts the backend must enforce. Names are proposals; the behavior is the decision.

**Changed tables**

| Table | Change and access |
|---|---|
| `quotes` | Add `creator_id`, `creator_username`, `edited_from_id`, `edited_from_username`. Each pair is a composite FK to `profiles (id, username)`, `on delete set null`, so deleting an account clears both. Read and write stay owner only; no SELECT policy is ever added. The table-wide UPDATE grant becomes `body, body_format, author, source, rotation_position, is_favorite`. On a direct insert the server sets the creator to the caller and accepts `origin` manual or pasted only. Only the server's save functions set another creator. The edit rule runs on update. Server-owned: creator, edited from, `origin`, plus today's list. |
| `profiles` | Add `unique (id, username)`, `accepts_text_messages` (default true), `favorites_visibility` (private or friends, replaces `shows_favorites`), `terms_version`, `terms_accepted_at`, `age_gate` (unknown, under_18, adult). The table SELECT grant becomes a column grant: `id, username, display_name, accepts_text_messages`. Own-only fields (`last_active_at`, `purge_exempt`, favorites visibility, terms, age gate) come only from `my_account()`. Terms are set only through `accept_terms(version)`. Display names pass the word filter. |
| `shares` | Step 1: gains the creator and edited-from columns, and the server builds the whole snapshot from `quote_id` or a catalog id. Step 3: moved into `messages`, then dropped. |
| `friendships` | Accepted friends are capped at 150 (QR002). Deleting an accepted friendship closes the pair's conversation. A new acceptance reopens it unless a block exists. |
| `blocks` | The after-insert trigger deletes the friendship and pending requests and closes the conversation. It no longer deletes any message or share. |
| `reports` | Add `post_id`, `message_id`, `playlist_id`, `starter_quote_id`, each `on delete set null`. `share_id` becomes `message_id`. Reasons add `copyright` and `wrong_wording`. Exactly one target is set, or none for a profile report. The reporter must be able to see the target. The server copies the content at insert, following `reports_snapshot_share`. Each insert alerts the founder through a Database Webhook and an Edge Function; the email key lives only in Edge Function env. |

**New tables**

| Table | Holds | Who may read and write |
|---|---|---|
| `posts` | `author_id`, `source_quote_id` (set null), `starter_quote_id`, `caption` (280), the snapshot (body, format, author, source, creator pair, edited-from pair, `verified_starter_id`), `audience` (friends or public, default friends), `held_at`, `created_at`. Index `(author_id, created_at desc, id)`. | Read: the author, and accepted friends with no block either way and not held. No RLS path for strangers. Insert: only `id, source_quote_id, starter_quote_id, caption, audience`; the server overwrites every snapshot column from the caller's own quote or the catalog row and refuses anything else. Update: `audience` only. Public needs `private.can_publish()` and an eligible quote. Delete: the author. |
| `conversations` | `user_a`, `user_b` (unique pair), `created_at`, `last_message_at`, `closed_at`. | Read: the two members, unless the reader was blocked by the other. Created only by `open_conversation(friend_id)`. No client update or delete. |
| `conversation_members` | `conversation_id`, `user_id`, `last_read_at`, `cleared_at`. | Each person reads and updates only their own row, and only those two columns. Nobody reads the other person's row. |
| `messages` | `conversation_id`, `sender_id`, `kind` (text, quote, playlist), `text` (1,000), `note` (280), quote snapshot with creator and edited-from, `source_quote_id`, `starter_quote_id`, `playlist_id` (set null), `playlist_title`, `created_at`. No seen or saved column. | Read: a member, for messages newer than their own `cleared_at`, and not blocked by the other member. Insert: a member and accepted friend, no block, conversation open, terms accepted, not suspended; text needs the recipient's `accepts_text_messages`. The server builds the snapshot from the sender's own quote or the catalog. No update. Delete: the sender only (unsend), which first copies the row to `private.message_tombstones`. |
| `playlists` | `owner_id`, `title` (1 to 60), `visibility` (private, friends, public; default friends), `held_at`, timestamps. | Owner only. Everyone else reads through `playlist_view(id)` and `profile_view`. |
| `playlist_items` | `playlist_id`, `quote_id` (cascade), `position`, `added_at`; key `(playlist_id, quote_id)`. | Owner only, and the quote must be the owner's. Public eligibility is checked on insert and on a visibility change. |
| `private.*` | `message_tombstones` (purged after 30 days by pg_cron), `blocked_terms`, `suspensions`, `banned_apple_subjects` (hashed), `retired_usernames`. | No client access. `is_reserved_username` also checks `retired_usernames`. |

**Server functions** (DEFINER in `private`, reached through INVOKER wrappers, as today)

| Function | Rule |
|---|---|
| `open_conversation(friend_id)` | Returns the pair's conversation, creating it for accepted friends only. |
| `save_from_post`, `save_from_message`, `save_from_favorite`, `add_catalog_quote`, `save_playlist_copy` | Check the caller can see the source, then insert quotes the caller owns, copying the snapshot, creator and edited-from. Catalog saves have no creator. Playlist copies skip quotes already held (same text and author). |
| `playlist_view(id)` | Owner; accepted friend with no block for Friends; anyone with no block for Public. Never held items. Returns snapshot fields only, and `creator_username` only for unverified items. |
| `profile_view(username)` | Exact username. Returns id, username, display name, the relationship and the visible posts, playlists and favorites, 30 per page. Nothing when the other side blocked you. Never `last_active_at`. |
| `friend_favorites(friend_id)` | Reads `favorites_visibility` instead of `shows_favorites`, and returns the creator username for unverified items. |
| `private.can_publish()` | Apple identity linked, terms accepted, not suspended, not declared under 18. |
| `private.suspend_user(id, reason)` | Founder only. Holds all of that person's posts and playlists. |
| `private.has_blocked_term(text)` | Used by the QR003 triggers and the live-view reads. |

**Limits**

| Write | Limit |
|---|---|
| Posts | 20 per 24 hours (QR001) |
| Messages | 300 per 24 hours (QR001) |
| Playlists | 20 new per 24 hours (QR001), 100 total and 200 items each (QR002) |
| Friend requests | 20 per 24 hours and 50 pending (unchanged) |
| Friends | 150 accepted (QR002) |
| Reports | 20 per 24 hours (unchanged) |
| Quotes | 5,000 total (unchanged) |
| Filtered text | QR003 on any blocked term |

**Events**

| Event | What the server does |
|---|---|
| Block | Ends the friendship and pending requests, closes the conversation. The blocked person loses read access to the conversation and the blocker's posts, playlists, favorites and profile. Nothing is deleted. |
| Unfriend | Closes the conversation for both. Posts and Friends playlists stop showing both ways. Playlist cards read "no longer available". |
| Account deletion | Cascades the person's quotes, posts, playlists, items, conversations and all messages in them (both sides lose that history), and their tombstones. Quotes others saved keep their text and lose the creator ("Added by a person"). Reports keep their snapshots with the ids set to null. The username is retired for good. `purge_inactive_anonymous` does the same. |
| Suspension | Every social insert is refused; public and friends items are held. |

**Existing data**

| Data | Becomes |
|---|---|
| `quotes` with origin manual or pasted | Creator = owner. |
| `quotes` with origin starter, still verified | No creator ("Quoted Catalog"). |
| `quotes` with origin starter, no longer verified | Creator = owner. |
| `quotes` with origin shared | No creator ("Added by a person"). |
| `shares` (step 3) | Each becomes a quote message with its `created_at` and note, in one conversation per pair (closed if they are no longer friends). The recipient's `last_read_at` is their latest `seen_at`. Creator: the step 1 snapshot columns; for older rows, the sender only if `quote_id` still points to the sender's manual or pasted quote, otherwise none. `reports.share_id` becomes `message_id`. `saved_at` is dropped. |
| `shows_favorites` | false becomes private, true becomes friends. |

**pgTAP must prove:** a forged creator on insert or update is overwritten; a forged share, post or message body is refused; a save carries the creator, not the sender; a wording edit moves the creator; deleting an account clears both columns; a retired username cannot be claimed; no client reads `last_active_at`; a non-participant cannot select, insert, update or delete messages, conversations or member rows; a blocked person cannot read; a non-friend cannot open a conversation; texts off refuses text but not quotes; strangers get zero posts and playlists through the API; a held item is hidden; an ineligible item is refused on a public playlist; QR003 fires on each filtered field and never on a Library insert; each limit fires at its number.

## 4. UI per tab

| Screen | Shows | Empty state | One filled action |
|---|---|---|---|
| Feed | Posts by you and friends, newest first. Card: quote, attribution and provenance, sans footer "@bob · 2h" and caption, plain "Save to Library" and "Send". Toolbar: compose (`square.and.pencil`). | "Checked against the source" with the daily catalog quote and its edition. | "Add a friend" (no friends) or "Post a quote" (no posts). None once posts exist. |
| Post composer (sheet) | Pick from Library or Quoted Catalog, or "New quote". Caption (sans, 280). "Who can see this", Friends. The username footnote. | Not applicable. | "Post" |
| Library | Today's list. Top section: Favorites, Playlists, Quoted Catalog. Rows gain the provenance line. "+" menu item "From the Quoted Catalog" with the filled seal. | As today. | As today. |
| Single quote | Shrink-to-fit card, provenance block, Reminders toggle. Toolbar: Favorite, Edit, "…" (Share Image…, Add to Playlist, Delete). | Not applicable. | "Send". A bordered "Post" sits beside it. |
| Inbox | Requests row on top when pending. Conversations by latest message: name, preview, time, unread dot. Toolbar: Friends (`person.2`), New Message. Swipes: Delete Conversation, Report, Block. | "No messages yet. Quotes your friends send land here." | "Add a friend" (no friends) or "Send a quote". None once conversations exist. |
| Conversation | Text bubbles; quote cards with note, provenance and "Save to Library" or "In your library"; playlist cards with Open. Long press: Save, Copy, Unsend (own), Report (theirs). Closed: a read-only banner with Report. | "Send @alice a quote." | Send (`arrow.up.circle.fill`). |
| Friends (from Inbox) | Add by exact username with "Share my username", requests, friends, Blocked users. | "No friends yet." | "Add" on the username field. |
| Your Profile | Header, How your quotes appear, Posts, Playlists, Favorites. Toolbar: Settings (`gearshape`), View as. | One quiet line per section. | None. |
| Others' Profile | As in section 2. | "@alice hasn't shared anything publicly." | Message or Accept. None for strangers. |
| Playlist | Yours: ordered rows, Edit order, "…" (Send, Who can see this, Add All to Reminders, Rename, Delete). A friend's: live and read only. | "A playlist is a list you can share…" | Yours: "Add Quotes". A friend's: "Save a Copy". |
| Search | Grouped results and tokens. Recent searches and suggestions as today. | "No matches" then "Search the web". | None. |

## 5. Out of scope for this build

| Deferred | Why |
|---|---|
| Push and Realtime for messages | Decision 7, and one access path keeps the participant tests simple. |
| Group conversations | Double the RLS tests and moderation load. |
| Reactions, comments, reshare button, any counts | Counts are status; comments need staffing. |
| A global or "Everyone" feed, public search, web pages, Universal Links | Each turns Public into a broadcast the founder cannot watch. |
| Read receipts and "Seen" | Fans value Quoted for not being social media. |
| Caption edits and per-message "delete for me" | Snapshots must match what was reported; one column is enough. |
| Subscribable playlists, live playlists in Reminders, paid playlists | Moderation load and paywall pressure. |
| "Kept by N", crowd verification | Popularity metrics. |
| "Request a check" | The best growth idea; first in line after launch. |
| Fuzzy people search, suggested people, contact upload, invite nagging | Each lists or pressures users. |
| Avatar upload and bios | New moderation surface for little gain. |
| Username rename | A freed name invites impersonation. |
| Photos in messages | Image moderation the founder cannot staff. |

## 6. Founder to-do

Only things the founder must do personally.

1. After each step passes locally, run `scripts/deploy-backend.sh` against the hosted project, then upload the build.
2. After step 1 is live, expire older TestFlight builds. Their starter-pack and save-from-friend inserts are refused by the new provenance rules.
3. Before step 3: review the drafted blocked-terms list and approve it.
4. Before step 3: review and approve the Terms of use and Community guidelines, including the zero-tolerance wording.
5. Before step 3: choose the address that receives report alerts and set its email key as an Edge Function secret. From then on, review every report within 24 hours and suspend accounts with `private.suspend_user` in the hosted SQL editor.
6. In App Store Connect: answer the age rating questions again (stays 16+, user content and messaging Yes), update App Privacy for messages and posts, and describe the filter, report, block and contact in the App Review notes.
7. Before step 6: publish a support email on your own domain and register a DMCA agent with the US Copyright Office.
8. Before step 6: set up Sign in with Apple in the Apple Developer portal and enable the Apple provider and manual identity linking in Supabase Auth.
9. Keep the first App Store screenshot on the seal on a quote, not the Feed or Inbox.

## 7. Council record

**Council A (social layer).** All five advisors agreed: posts are frozen snapshots, there is no global feed, the Feed has two actions and newest-first order, conversations are 1:1 between friends, and filtering, reports, terms, limits and a friend cap are needed. Three advisors and every reviewer said the server must stamp the creator before any social screen ships. The council clashed on what block does (ruled: hide, never delete), filter scope (every visible text, server only), anonymous accounts (only Public needs Apple), playlist sending (live link plus title), "delete for me" (per conversation), cold start (Library until the first friend), friends' posts in search (included), read receipts (none), the messages switch (text only) and the friend cap (500, cut to 150 by the positioning check). The Chairman caught that every account is anonymous, that the rating is already 16+, that an RLS public read builds a global feed, and that client-written share snapshots let anyone fake the creator.

**Council B (content and identity).** All five advisors agreed: the creator must be a server fact, playlists are named lists defaulting to Friends with a live view and "Save a Copy", the Library root stays, the profile has no counts, settings sit behind a gear, and hiding is enforced by the server. All five reviewers rated the Executor strongest. The council clashed on edits (ruled: the creator moves, "edited from" stays), verified quotes ("Quoted catalog"), catalog quotes in playlists (save first), how added quotes show on a profile (Posts only, the minority view), live playlist reads (a definer function), creator usernames (a snapshot) and when Public ships (built now, hidden). The reviewers caught that "first to add" cannot be built without matching private libraries, that public collections leak other people's usernames, and that reports could only point at shares.
