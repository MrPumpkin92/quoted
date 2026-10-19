# Decision: in-app quote search (LLM Council, 2026-10-18)

## Founder decision

- **Search:** Option A. A `.searchable` bar over the user's library and quotes shared by friends. The last row is "Search the web for '<term>' quotes", which opens Google in `SFSafariViewController`. A `PasteButton` in the Add sheet brings the copied quote back. Taps on the web row are logged as a demand signal.
- **Starter pack:** yes. 50-100 public-domain, attribution-checked quotes, picked during onboarding.
- **Deferred:** a Share Extension (v1.1). A structured quote API behind an Edge Function, only if the logs show demand. No SERP APIs.
- **Context:** Google Custom Search JSON API is closed to new customers and shuts down 2027-01-01 (https://developers.google.com/custom-search/v1/overview).

---

## Chairman verdict

## Where the Council Agrees

- **Google search is not an option.** All five advisors accept it. The Custom Search JSON API is closed to new customers and shuts down on 1 Jan 2027. Anything sold as "Google search" would be a different feature using the same name.
- **No web SERP APIs (SerpApi, Brave), in any release.** They return snippets, not `{quote, author}` records. You would have to write and maintain an extractor, and you would still serve misattributed quotes under your own brand. Nobody argued for them.
- **The real problem is the empty first launch.** The Contrarian, First Principles, Outsider and Expansionist all reached this on their own. A new user has no quotes, so the widget is blank, notifications have nothing to send, and there is nothing to share. Search was standing in for a cold-start fix.
- **A starter pack is the cheapest cold-start fix.** Four advisors suggested it in some form: 50 to 100 public-domain quotes stored as Supabase seed rows. During onboarding the user picks a few, so the core loop works in the first minute.
- **A Share Extension is the honest version of "search the internet."** Four of five advisors said so. The user searches real Google in Safari, selects text, taps Share, and the Add form opens already filled in. There is no API, no per-query cost and no shutdown risk, and the user picks the source.
- **Any search lives inside a screen that already exists.** No new tab, no new button. This fits the "few buttons" brief.
- **If a third-party quote API is ever used, its key stays server-side** behind a Supabase Edge Function, and results must be structured quote records.

## Where the Council Clashes

- **Should v1.0 let users discover quotes they don't already have?**
  - *Yes (Expansionist, Outsider):* an app where you type every quote by hand feels like homework, and "an empty widget is an ad for deleting the app." People install a quotes app to get good quotes.
  - *No (Contrarian, First Principles, Executor):* every external source breaks somewhere specific. ZenQuotes rate-limits per IP, which collapses to one shared budget behind Edge Function egress. Quotable has had outages, and a dead endpoint during review risks a Guideline 2.1 rejection. Wikiquote is a parsing project with CC BY-SA obligations.
  - *Why both sides are reasonable:* the Yes side is optimising the first 60 seconds. The No side is optimising time to ship and reliability. The starter pack settles most of this, because it fills the first 60 seconds without any search.
- **Where discovery data comes from, if it exists at all.**
  - Expansionist: your own Postgres corpus (Wikiquote plus Quotable), with full-text and trigram search.
  - Executor: in v1.1, an Edge Function calling API Ninjas or Quotable, cached in Postgres.
  - Contrarian and First Principles: nothing until users ask for it.
- **When to ship the Share Extension.**
  - First Principles: MVP.
  - Contrarian and Expansionist: v1.1.
  - Executor: v1.2, because it needs an App Group to share the Supabase session.
  - Peer review weakened the Executor's argument: the widgets already need an App Group.
- **The Executor's "search your own library" bar.** Only the Executor proposed it. Every reviewer endorsed it as an easy add-on, about half a day with `.searchable`, and none objected.

## Blind Spots the Council Caught

- **Literal Google search can ship in v1.0 with no API.** Three of five reviewers raised this. A search field opens `SFSafariViewController` on Google with "<term> quotes". When the user comes back, a SwiftUI `PasteButton` fills in the editor without a paste permission prompt. That is real Google, with no key, no cost and no 2027 risk, in about an hour of work. No advisor saw it.
- **That same button is a demand test.** One reviewer noted that nobody had proposed a cheap way to check whether users want search before building it. Logging taps on the web-search row answers that for free.
- **The Expansionist's corpus idea has a privacy problem.** All five reviewers named it the biggest blind spot. Putting users' saved quotes into a shared corpus exposes private data that Row Level Security protects, without consent. That is a Guideline 5.1 and privacy-label problem. The "Sourced" badge also promises accuracy Wikiquote can't guarantee.
- **The real App Store risk is in friends and sharing, not search.**
  - Guideline 1.2 requires report, block and filter tools for user-generated content.
  - Guideline 5.1.1(v) requires in-app account deletion, because the app has login.
  - Neither is in scope yet.
- **The notification loop has limits.**
  - iOS keeps at most 64 pending local notifications per app, so a cycling playlist needs a rescheduling strategy.
  - Notification bodies are plain text, so bold, italic and underline never show on the main surface. Store a plain-text copy alongside the formatted text.
- **Starter pack attributions still need checking.** A misattributed quote in the pack is just as damaging.
- **Usability points from the Outsider that nobody contested:**
  - "Playlist" sounds like music.
  - The bold/italic/underline toolbar should stay out of the way until the user wants it.
  - Friends will be empty on day one, so make sharing work through an iMessage link first.

## The Recommendation

**Ship a search bar in v1.0, with no internet search API behind it.** Concretely:

- **v1.0**
  - **Library search:** `.searchable` on the library, matching text and author, covering your own quotes and ones friends shared with you. This is the search bar.
  - **Literal Google fallback:** while the user types, the last row reads "Search the web for '<term>' quotes". It opens `SFSafariViewController` on Google. A `PasteButton` in the Add sheet brings the copied quote back. Log taps on this row.
  - **Starter pack:** 50 to 100 public-domain, attribution-checked quotes as seed rows, picked during onboarding, so widgets and notifications have content on day one.
  - **In MVP scope regardless of search:** report, block and filter for shared quotes; in-app account deletion; a plan for the 64-notification limit.
- **v1.1:** the Share Extension, reusing the App Group the widgets already need.
- **v1.2 or later, only if the tap logs show real demand for discovery:** a "Discover" source behind the same field. It would be one `search-quotes` Edge Function calling a structured quote API (API Ninjas with the key stored server-side, results cached in Postgres), or a curated corpus you own. Never a SERP API. Never other users' private quotes.

**Your options, side by side:**

| Option | What v1.0 gets | Cost and risk |
|---|---|---|
| **A. Recommended** | Library search, a Google button through Safari, starter pack | About 1 to 2 days. $0 recurring. No vendor. Low review risk. |
| **B. Expansionist** | Discovery over your own ingested corpus | Weeks of parsing. CC BY-SA obligations. Privacy and consent exposure. Delays submission. |
| **C. Contrarian** | No search bar at all, starter pack only | Fastest. Drops the founder's stated wish with nothing in its place. |
| **D. Executor as written** | Library search only; API "Discover" in v1.1 | Cheap. Leaves the "Google" wish unmet until v1.2. |

Option A gives the founder a working search bar that really reaches Google, fixes the empty first launch, costs nothing per query, and produces the data that decides whether paid discovery is worth building.

## The One Thing to Do First

Write the Supabase seed migration for the starter pack: 50 to 100 public-domain quotes, each attribution checked against a primary source, plus the onboarding screen where the user picks them. Every option the council considered needs this, so it can start before the founder decides on search.

---

## Advisor responses

### The Contrarian

**The fatal flaw:** the feature the founder asked for can't be built. "Search via Google" is closed to new apps. Every remaining option is a different, weaker feature with the same name, and each one breaks somewhere specific.

**ZenQuotes:** it rate-limits by IP. A Supabase Edge Function sends every user's request out through a small pool of shared egress IPs. That means your whole user base could share one budget of 5 requests per 30 seconds. Ten people searching at once and it fails. Keyword search also needs a paid key anyway.

**Quotable:** about 1,500 quotes and a history of outages. If an App Store reviewer hits a dead endpoint, that's a Guideline 2.1 rejection.

**SERP APIs:** they return snippets, not quotes. You'd have to write a parser that pulls out quote text and attribution. That is a product of its own, not a feature.

**Wikiquote:** CC BY-SA means the attribution and ShareAlike terms follow every quote you push into widgets, notifications and friend shares. Is the schema storing license data for each quote? It isn't.

On top of that, misattribution. You'd be serving fake "Einstein said..." quotes under your own brand, and sending copyrighted modern text into notifications.

**The question nobody is asking:** what problem is search really solving? I think it's the empty state. A new user has zero quotes, so notifications and widgets have nothing to show and the core loop never starts. Search is an expensive, fragile fix for that. The cheap fix is to bundle 50 to 100 public-domain quotes as a starter pack. It works offline and costs nothing in API fees.

The founder's real habit, "I find quotes on the web," is better served by a Share Extension in v1.1. You select text in Safari, which already uses real Google, tap Share, and it opens the add-quote form already filled in. No API, no cost, no extra button in the app.

**Verdict:** no search bar in the MVP. Not a stub, not "coming soon." Ship the starter pack now and the Share Extension next. Only look at API search again if users ask for it.

### The First Principles Thinker

**You're asking the wrong question.** "Should we have a search bar?" assumes search is how quotes get into the app. Start from what users actually do.

Nobody opens a quotes app and thinks of a quote they've never seen. They come across one somewhere else: a Kindle highlight, an Instagram post, a podcast, a friend's text, a Safari tab. The quote matters because they found it. The app's real job is to make **saving that moment easy**, then bring the quote back through notifications and widgets, then let them share it. Search turns that around into "browse quotes you have no connection to." BrainyQuote already does that, and it would dilute the "few buttons" brief.

So the problem is how hard it is to save a quote, and search doesn't solve that. These do:

1. **iOS Share Extension.** The user selects text anywhere (Safari, Kindle, Notes), taps Share, picks the app, and the text and source URL arrive pre-filled. This is the Google search the founder asked for: the user searches Google in Safari, for free, with no API, no vendor risk and no Jan 2027 shutdown. The user picks the source, so misattribution isn't the app's problem.
2. **Paste detection plus Live Text / camera scan** for physical books. This is VisionKit and runs on the device. It costs $0 per query.

The founder may want search for a second reason: a new user has zero quotes, so the notifications and widgets have nothing to show on day one. That's a cold-start problem, and it has a cheaper fix. Ship a **curated starter pack** of 50-100 public-domain quotes, stored as seed rows in Supabase. The user picks a few during onboarding and the loop works immediately.

**Verdict:** Leave search out of the MVP. Build the Share Extension and the starter pack instead. Revisit later only if analytics show users browsing to find quotes. Even then, search your own curated and user-shared collection, not the open web. A web search that scrapes snippets brings recurring cost, vendor risk and attribution liability, and it doesn't help the core loop.

### The Expansionist

**Yes, ship search in the MVP. Build it as your own quote index, not as Google.**

Search is how a new user gets started. An app where you type in every quote by hand opens empty, and an empty playlist means no notifications, a blank widget and nothing to share with friends. Search lets someone fill a 10-quote playlist in 60 seconds, so the collect, resurface and share loop runs on day one.

Don't rent Google. Put Wikiquote (CC BY-SA, huge and free) plus Quotable's set into Postgres, and serve search with full-text and trigram matching through one Edge Function. That means no cost per query, no vendor to lose, and structured `{quote, author, source}` records from the start.

The bigger upside is three things others will miss:

1. **Every quote a user saves goes into your corpus.** Six months in, you own a database of quotes people actually care about, which Google doesn't have. Search results get ranked by how many people saved and shared each quote.
2. **Misattribution can be your edge.** Show a "Sourced" badge that links to Wikiquote's citation. "The quote app that's actually right" is a positioning line, and it also covers your attribution obligations.
3. **Search queries show demand.** They tell you which topic playlists to curate ("Stoic mornings", "Grief", "Founders"), and those curated playlists are your first paid tier.

**Keep it to almost no UI:** one search field at the top of the "Add" sheet. Typing filters the corpus, and tapping a result fills in the editor, where users can still apply bold, italic and underline. If nothing matches, they're already in manual entry. That adds no new tab and no new button.

**Plan for v1.1:** a Share Extension and Live Text capture (screenshot a quote from a book, Safari or Instagram, and it lands in your library). That is the real version of "search the internet": catching quotes wherever the user already is.

Web SERP APIs stay out of the plan entirely.

### The Outsider

**The Outsider's take: an empty quotes app gets deleted.**

Picture me downloading this. I sign up and land on a blank screen that says "Add a quote." I don't have quotes memorized. I downloaded the app because I want good quotes, and I'm not here to type them in from memory. The founder clearly has a notebook of favorites already, so manual entry feels like the core of the app to them. For everyone else it's homework.

My answer is yes, the MVP needs a way to find quotes. But I don't care whether it's "the internet" or "Google." I want to type "courage" or "Maya Angelou," see clean quotes with names attached, and tap once to save. If I get messy web snippets, cut-off sentences or "Einstein" on a line he never said, the app looks broken. I won't blame the API; I'll blame the app.

So:
- **Call it "Find quotes."** Don't call it "Search the web." Put the field at the top of the Add screen so I get one place to add, either by typing or by finding. Don't give it a new tab or button.
- **Back it with structured quote data.** That means a quote-and-author source, not general web search results.
- **Show something before I search.** Put a few suggested topics or a starter set on first launch, so my widget and notifications have something in them on day one. An empty widget on my home screen is an ad for deleting the app.

Other things that will confuse ordinary people:
- **"Playlist"** sounds like music. "Daily rotation" or just "Remind me" is clearer.
- **Bold, italic and underline** on a quote I'm saving is something I'd never think to do. Hide it behind a long-press, or I'll see a toolbar and feel like I'm in Word.
- **Friends** will be empty on day one too. Make sharing work through a normal iMessage link first.

What matters is the user's first 60 seconds, more than search for its own sake.

### The Executor

**No web search in v1.0.** The Google option doesn't exist for us: the Custom Search JSON API is closed to new customers and shuts down on 1 Jan 2027. A SERP API like SerpApi or Brave only returns snippets, so we would still have to pull the quote and author out of them and deal with misattribution. That could eat a week and nobody can name a clear first step, so it's out.

**What to do Monday morning:**

1. **Put a search bar in v1.0 that searches the user's own quotes.** Add SwiftUI `.searchable` to the library list, filter on text and author, and include quotes friends have shared. It takes half a day, needs no API, no cost and no review risk. It also keeps the "few buttons" brief, because search sits inside an existing screen rather than taking a new tab.

2. **Ship v1.0 with the core loop only:** add a quote, put it in the playlist, see it in notifications and widgets, share it with friends. Search is not part of that loop, and a solo founder who adds it now pushes the submission back.

3. **v1.1, about two days of work:** add a "Discover" sheet behind the same search field. The app calls one Supabase Edge Function, `search-quotes`. The function calls API Ninjas, with the key stored as a server-side secret, or Quotable as a fallback. It returns `{text, author, source}` and caches results in a Postgres table so repeat searches cost nothing. Each result gets one "Add" button that drops it into the add-quote form already filled in. That reuses screens we're building anyway, so there's no new UI to design.

4. **v1.2 or later, and only if people ask for it:** a Share Extension. The user highlights text in Safari, taps Share, then "Save Quote". That gives the founder's "search via Google" wish with zero API cost, because they're using real Google in Safari. It needs an App Group to share the Supabase session, so it waits until after launch.

**Skip Wikiquote parsing entirely.** It returns whole pages, not individual quotes, so it's a parsing project.

**Decision: v1.0 searches your own collection. v1.1 adds Discover through one Edge Function. Web SERP never.**

---

## Peer reviews (anonymized; Response A = The Executor; Response B = The Contrarian; Response C = The Outsider; Response D = The First Principles Thinker; Response E = The Expansionist)

### Reviewer 1

**1. Strongest: D.** D asks how people actually come across quotes. It turns the founder's "Google" wish into a Share Extension: the user searches Google in Safari, so there is no per-query cost, no vendor to depend on and no exposure to the Jan 2027 shutdown. It also treats the cold-start problem as a separate issue and fixes it with a seeded starter pack. A is the easiest to act on (a half-day `.searchable` over the user's own library) and pairs well with D.

**2. Biggest blind spot: E.** E calls ingesting Wikiquote cheap, but A shows it is a parsing project. As B notes, CC BY-SA ShareAlike terms follow each quote into widgets and friend shares. "Every saved quote goes into your corpus" makes users' private quotes shared data without their consent, which is a privacy-policy and privacy-label problem. E also adds the most MVP scope.

**3. What all five missed:**
- Friend sharing is user-generated content. Guideline 1.2 requires reporting, blocking and filtering. A's plan to search friends' shared quotes makes that requirement bigger.
- Because the app has login, Guideline 5.1.1(v) requires account deletion inside the app.
- iOS allows at most 64 pending local notifications, so a cycling playlist needs a plan for rescheduling.
- Notifications show plain text, so bold, italic and underline won't appear there.
- Nobody proposed a cheap way to test whether users want search before building it.

### Reviewer 2

1. **Strongest: D.** It changes the question from "how do we search" to "how do quotes get into the app." It answers with two zero-cost fixes. A Share Extension lets users search real Google in Safari and save from there. A seeded starter pack fixes the empty first screen. Search stays on the list, but only if analytics show demand. B reaches the same verdict and makes the sharpest technical catch: ZenQuotes limits by IP, so every user would share the Edge Function's few outgoing IPs. D is easier to act on.

2. **Biggest blind spot: E.** It calls Wikiquote "free" but ignores that pulling quotes out of whole pages is a project of its own (A). It also ignores that the license terms would follow each quote into widgets and shares (B). Worst, "every quote a user saves goes into your corpus" quietly turns private libraries into shared data. That raises consent, privacy-label and copyright problems, and it is not an MVP plan.

3. **What all five missed:** the founder's literal request can ship in v1.0 for almost nothing. The search field opens an in-app Safari view (SFSafariViewController) on Google with the user's term plus "quotes." When the user comes back, a SwiftUI Paste button fills in the Add form. That is real Google, with no API, no key and no shutdown risk. Also, widgets already need an App Group, so the Share Extension costs less than A suggests.

### Reviewer 3

1. **Strongest: D.** It asks what search is actually for and answers both real needs. A starter pack in seed rows fixes the empty first launch. A Share Extension covers the founder's "Google" habit, because users search real Google in Safari for $0 with no vendor or shutdown risk. A is a close second: `.searchable` over the user's own library is a search bar that takes half a day.

2. **Biggest blind spot: E.** It treats loading Wikiquote as an MVP task. It ignores A's point that this means parsing whole pages and B's point that the CC BY-SA ShareAlike terms follow every quote. Its "Sourced" badge also promises accuracy that Wikiquote can't guarantee. Putting users' saved quotes into a public corpus raises privacy and consent problems (Guideline 5.1).

3. **What all five missed:** the outbound half of "search via Google." In v1.0, one button can open `SFSafariViewController` on a Google search. Back in the app, a `PasteButton`/`UIPasteControl` takes the copied text without a permission prompt. That gives literal Google search in about an hour, with no Share Extension, App Group or API. None of them noticed that local notification bodies are plain text either, so bold, italic and underline never show up there.

### Reviewer 4

1. **Strongest: D.** It looks at how people actually come across quotes. It also splits search's two jobs apart: saving quotes found elsewhere, and filling the empty app on day one. It answers each job with a cheap fix: a Share Extension for saving and a starter pack for day one. That covers the founder's Google wish at $0, since users already search Google in Safari. A comes a close second. Its `.searchable` filter over the user's own library takes half a day, and adding it to D's plan keeps a literal search bar in v1.0.

2. **Biggest blind spot: E.** It calls ingesting Wikiquote and Quotable "no cost," but:
   - Wikiquote returns whole pages that have to be parsed (A's point).
   - CC BY-SA ShareAlike terms follow every quote into widgets and shares (B's point).
   - Feeding users' saved quotes into a shared corpus raises privacy and consent problems.

   That is weeks of work presented as an MVP feature.

3. **What all five missed:**
   - **A cheap literal option.** A search field could open Google results for "<query> quotes" in SFSafariViewController. That is real Google with no API and no shutdown risk, and the Share Extension brings the quotes back into the app.
   - **Where the real App Store risk is.** It is in friends and sharing, not search. Guideline 1.2 requires report, block and filter tools for user-generated content. Guideline 5.1.1(v) requires account deletion inside the app. Neither is in scope yet.
   - **The starter pack's attributions** still need checking.

### Reviewer 5

**1. Strongest: D.** D starts from how people actually find quotes: in Safari, Kindle, Instagram or a friend's text. That turns the founder's "Google search" wish into a Share Extension, which costs $0 per query, carries no vendor risk and isn't affected by Google's 2027 shutdown. D also saw that search was really standing in for the cold-start problem, and it fixes that cheaply with a seeded starter pack. A comes a close second: its `.searchable` filter over the user's own library gives the founder a real search bar at almost no cost. But A never addresses the empty first launch that B, C and D all flag.

**2. Biggest blind spot: E.** E wants to put every saved quote into a shared corpus. That publishes users' private, RLS-protected data unless they explicitly agree to it. E also treats importing Wikiquote as easy, when it's a parsing project (A), and it ignores the CC BY-SA ShareAlike terms that would follow each quote into widgets and shares (B). Its "Sourced" badge promises verification the app can't do.

**3. What all five missed:** the resurfacing loop itself has limits.
- iOS keeps only 64 pending local notifications per app, so cycling the playlist needs a rescheduling plan.
- Notification bodies are plain text, so bold, italic and underline disappear on the main surface.
- Widgets and any extension need an App Group to share data and the Supabase session.
- Because the app creates accounts, App Store rules require an in-app account-deletion option.
