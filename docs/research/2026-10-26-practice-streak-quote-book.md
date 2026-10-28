# Quoted: market research synthesis for Practice, Gather, Streak and Quote Book

Research date: 2026-10-26. This is desk research only. No users have been interviewed yet.

**How to read this document**
- A number in brackets, such as [12], points to a source URL in section 12.
- The 12 fact-checked claims were re-verified against primary sources on 2026-10-26. Where a check corrected a figure, this document uses the corrected figure.
- **†** marks a figure that comes from one research report with a cited source but was not re-verified in the fact-check round.
- **est.** marks a third-party model estimate (AppGoblin, Adapty, Screensdesign). None of these publish their method.
- **[Q]** marks a fact about Quoted that comes from the project brief.
- Sophistication scores, segment fit ratings and test thresholds are judgment calls, and they are labelled as such.
- Copyright limits allow one direct quote. All other user voices are close paraphrases. Follow the link to read the exact words.

---

## 1. Bottom line

- **A market exists, but the part that pays is small.**
  - Passive quote feeds are huge and paid for mostly by ads. Motivation has about 82.7M installs and I am about 54.8M. Each is estimated at $200K to $499K a month, with 71% to 72% of that from ads (AppGoblin est., crawled 2026-10-26) [1][2][3].
  - Apps for memorizing short text get real installs but each earns under $10K a month (est.) [41][44][45][48].
  - The best proof that people will pay to practise text they saved themselves is Readwise. It has been bootstrapped since 2018 and charges $67 to $120 a year [30][32][34].
- **Who to target first:**
  - Self-improvement and Stoic readers who already save lines from their reading. They are the one segment that wants all four pieces.
  - Commonplace-book keepers are the fastest-growing group next to them: r/commonplacebook has 89K members, up 164.1% in a year [55].
  - This is a hypothesis. The interviews need to test it.
- **What wins:**
  - Verified wording plus practice on *your own* quotes. The practice runs first letters, then blanks, then the full line. It shows the correct text after every attempt and spreads reviews over days.
  - A forgiving streak.
  - A quote book that is a finished object.
  - No general quote app we found does all four. The Bible Memory App does all four for scripture [40].
- **What kills it:**
  - Distribution, not the product. About 83% of new subscription apps never reach $1K a month within 2 years, and the median app earns about $72 a month one year after launch [62].
  - Practice that feels like homework.
  - Streak nagging.
  - Billing distrust. It is the top theme in low-star reviews of both Motivation and I am [9][10].
- **Verdict: go, with conditions, as a feature set rather than a new business.**
  - Build Practice and a humane streak on top of the existing Library. That fixes retention and the "same quotes" complaint.
  - Treat the quote book as the piece people give away, and possibly pay for.
  - Run the 2-week validation test in section 11 before writing code.
  - Realistic outcome: a small, durable indie business. The base case is low thousands to low tens of thousands of dollars a year, not venture scale.

---

## 2. Research context

| Item | Detail |
|---|---|
| Product | Quoted: a native iOS 26 app (SwiftUI + Supabase) by a solo founder [Q] |
| What exists today | Library (text, author, source). Reminders sent as local notifications several times a day and shown on Home and Lock Screen widgets. A starter pack of 60 public-domain quotes, each checked word for word against a full text (the "verified" seal). Sharing to a friend's inbox. Hearted favorites shown on a friend profile. Anonymous accounts, no ads, no analytics SDKs [Q] |
| In progress | Mixing new verified catalog quotes into Reminders, because testers said the same 5 quotes repeat [Q]. The unapproved "Verbatim" proposal: a daily quote puzzle plus "Recall", spaced finish-the-line practice on your own quotes [Q] |
| New idea (founder's words) | "a platform for me to practice and gather my favourite quotes plus a tab for a streak and my own quote book" |
| The four pieces | 1. Practice (active recall). 2. Gather (collecting, already the core). 3. Streak tab (daily habit). 4. My quote book (curated, shareable, possibly printable) |
| Ideal customer (hypothesis) | Self-improvement and Stoic readers who save lines from books and want them ready in hard moments. Runner-up: commonplace-book keepers |
| Competitor groups | Passive feeds (Motivation, I am, Stoic apps). Highlight review (Readwise, Glasp, Kindle). Journals (Day One). Scripture memory (Bible Memory App, Verses, Remember Me). Text memorizers (Memorize By Heart, Anki). Small quote journals (MyQuotes, Quotemarks, Commonplace Quote). Quote games |
| Stage | Pre-launch on TestFlight. No revenue, no pricing, no analytics |
| Research limits | Reddit could not be read. No interviews yet. All install, MAU and revenue figures are third-party estimates |

---

## 3. Module 0: Competitor landscape

**Sharpest insight:** the category splits in two. One side is a huge passive feed business. The other is a small active-practice niche that is almost entirely scripture. Nobody sits in between with verified, personal quotes that you actually learn.

### 3.1 Landscape map

Sophistication is a judgment score on Schwartz's 1 to 5 scale:
- 1: the first simple claim
- 2: a bigger claim
- 3: a new mechanism
- 4: an improved mechanism
- 5: identity and experience

| Competitor | Core promise | Mechanism | Target | Soph. | Positioning gap left for Quoted |
|---|---|---|---|---|---|
| Motivation (Monkey Taps) [1][4] | Daily motivation | Feed, reminders, widgets, favorites, share images | Mass self-improvement | 2 | No practice, no accuracy check. Billing dominates its low-star reviews [9] |
| I am (Monkey Taps) [2][5] | Daily affirmations | Reminders, widgets, your own affirmations. Streak with freezes (seen in reviews) [10] | Mass wellness | 3 | Streak-loss warnings arrive after the user has already opened the app that day [10]. Billing complaints |
| Stoic (Stoic app inc.) [12][13] | Journal and mental health | Prompts, a quotes section, habit streaks, an AI tier † | Self-improvement journalers | 4 | Quotes are secondary. No recall practice |
| New Stoic quote apps (2026) [14] | Daily Stoic wisdom | Feed plus streak | Stoic readers | 2 | The same feed with a streak added. A crowded corner |
| Readwise [30][32][39] | Remember what you read | Daily Review (spaced resurfacing), Mastery flashcards, streak with a 7-day recovery window [37] | Heavy readers | 4 | No quote book. Built around readers, not quotes. No wording check |
| Glasp [20][21] | Social web highlighting | Public highlights, following people | Web readers | 3 | No practice, no streak |
| Kindle Notebook [22][23] | Your Kindle highlights | Notebook, flashcards † | Kindle readers | 1 | Locked to Kindle. Export capped by publishers |
| Goodreads quotes [15][16] | Find and like quotes | Community database, tags | Readers | 1 | Says its quotes are community-added and not verified by Goodreads [15] |
| Day One [17][18][19] | A private journal for life | Entries, templates, streaks, printed books | Journalers | 5 | No practice. Its book is a dated journal, not a curated quote book |
| Small quote journals (MyQuotes, Quotemarks, Commonplace Quote) [26][27][28] | A private quote journal | Capture, resurfacing. MyQuotes has a spaced-repetition quiz [27] | Commonplace keepers | 2 to 3 | Tiny (MyQuotes 9 ratings, Quotemarks 53) [27][28] |
| Bible Memory App [40][41] | Memorize scripture | Type the first letter of each word, 3 stages, spaced repetition, your own collections, streak, printed verse cards | Christians | 4 | Scripture only |
| Verses [43][44] | Memorize scripture through games | 6 games, "memory health", daily and weekly streaks † | Christians | 4 | Scripture only. No App Store update since Mar 2020 [44] |
| Remember Me [46] | Free scripture memory | Flashcards, spaced repetition, first-letter hints † | Christians | 3 | Free nonprofit, which caps what anyone can charge in scripture |
| Memorize By Heart [47][48] | Learn any text | Fading, first letter, typing, recitation, gamification you can turn down † | Actors, speakers, students | 3 | A general text tool. Low use (3.9K MAU est.) [48] |
| Anki, Brainscape [52][53] | Remember anything | Self-graded flashcards, spaced repetition † | Students | 3 | Dense, not built for quotes, no collection or book |
| Quote games (Cryptogram, Decodex) [24][25] | Puzzles made from quotes | Decoding, daily puzzle, streak (Decodex) † | Puzzle fans | 2 | Decoding is not recalling your own quotes |
| Paper commonplace book | Keep quotes by hand | A notebook | Commonplace keepers | 1 | No recall, no search, slow to fill |

### 3.2 Saturated claims (they no longer set anyone apart)

| Claim type | Who makes it | Why it is spent |
|---|---|---|
| Daily quotes or inspiration on your Home Screen | Motivation, I am, Stoic apps, widget apps [4][5][14] | Two leaders already have more than 130M installs combined (est.) [1][2] |
| Build a habit with streaks | I am, Stoic, Day One, Readwise, Verses [10][12][18][37][43] | Every habit and journal app has one |
| Thousands of quotes in every category | Motivation, Goodreads [4][15] | Abundance is free. Users say the quotes feel generic or repeat [9] |
| AI insights or themes | Stoic AI tier, Commonplace Quote † [12][26] | Already common in 2026 listings |
| Never lose your highlights | Readwise, Glasp, Kindle [20][22][30] | Owned by reader tools with existing sources |

### 3.3 Gap analysis

**Overcrowded angles**
- A passive daily feed with widgets. It is ad-funded, and the leaders are at massive scale [1][2].
- Stoic feed plus streak. Several new apps launched in 2026 [14].
- Scripture memory. The leading app has 1.9M installs (est.) [41], and a free nonprofit claims 2.2M+ downloads (self-reported) [46].

**Underserved desires**

| Desire | Evidence | Who serves it today |
|---|---|---|
| Know *my own* secular favourite quotes by heart | No quote-only memorization app at scale. Memorise has 0 ratings and no update since 2019. Poems By Heart is withdrawn [49][50] | Nobody at scale. Memorize By Heart is a general text tool with 3.9K MAU (est.) [48] |
| Trust that the words are exact | Goodreads disclaimer [15]. Goodreads librarians keep threads on misattribution [16] | No quote app found. PastWisdom labels attribution on the web, and we could not confirm it has an iOS app [29] |
| A quote book as a finished object you can give | Day One prints journals: $19.99 for the first 50 colour pages, then $0.10 a page [17]. Bible Memory App sells printed verse cards (May 2025) [40] | Nobody for curated secular quotes |
| A streak that does not nag | I am reviewers complain about streak-loss warnings after they have already used the app [10] | Partly: Readwise's 7-day recovery [37], Verses' weekly streak † [43] |
| Billing people can trust | About 77 of 111 one- and two-star I am reviews are about subscription, price, trial or charges [10]. About 92 of 400 recent Motivation reviews mention billing [9] | No clear owner |

**Three open positioning territories**

| Territory | The promise | Proof Quoted can show | Who could take it |
|---|---|---|---|
| A. "Know your favourite lines by heart" | Secular verbatim practice on the collection you chose, in under a minute a day | The behaviour is proven in scripture (Bible Memory App 1.9M installs est.) [41]. Retrieval research (section 9) | Readwise (adding quotes), Bible Memory App (going secular) |
| B. "Every word checked" | A verified commonplace book | 60 verified starter quotes [Q]. Goodreads' own disclaimer [15] | Hard to copy, because verification is manual work |
| C. "A quote book worth giving" | A curated, designed book or page made from your verified lines | Day One proves people pay for print [17]. Paper commonplace books start blank | Day One (adding templates) |

**Most underserved sophistication level: stage 3, a new mechanism.**
- Secular quote lovers have never been told *how* they will remember their quotes. Feeds sell exposure (stage 2). Readwise sells a mechanism, but only to readers with highlights.
- A plain claim backed by a named mechanism is open. For example: "know your lines by heart; first letters, then blanks, one minute a day."
- For the Stoic beachhead, add stage 5 identity language: being the person who has the line ready when it matters.

### 3.4 Differentiation pressure test

| Claim | Can a competitor say it today? | Proof Quoted has now | Does it survive? |
|---|---|---|---|
| Every quote checked word for word against the full text | No quote app found [15][29] | 60 verified starter quotes [Q] | **Yes, for the catalog only.** Quotes users add are not verified, so the app needs a clear "verified" vs "yours" label |
| Learn your favourite quotes by heart | Readwise (highlights) [39], Memorize By Heart (any text) [47], MyQuotes (9 ratings) [27] | Nothing built. Recall is still a proposal [Q] | **Only if shipped and quote-specific** (fast, first-letter, under a minute) |
| Practice, collection, streak and book in one | Bible Memory App, for scripture only, and it makes cards rather than a book [40] | Gather only | **Yes for general quotes, but copyable** |
| A streak that never guilt-trips you | Readwise (7-day recovery) [37], I am (has freezes) [10], Verses (weekly) † [43] | Nothing built | **Weak as a headline.** Use it as a trust signal |
| No ads, no tracking, honest billing | Remember Me (free, no ads) [46] | No ads, no analytics SDKs, anonymous accounts [Q] | **A real advantage against the Monkey Taps apps' complaints.** It does not drive purchases by itself |
| Share lines with friends | Glasp [20], Motivation share images [4] | Inbox sharing, profiles [Q] | **Secondary** |

### 3.5 Competitor comparison

| Product | Practice | Gather | Streak | Quote book | Verified words | Ads | US price | US rating |
|---|---|---|---|---|---|---|---|---|
| Motivation | No | Partial | Not on listing | No (share images) | No [4] | Yes, 72% of revenue (est.) [1] | IAP $3.99 to $47.99 † [4] | 4.82 (1,076,819) [11] |
| I am | No | Partial | Yes, with freezes [10] | No | n/a (affirmations) | Yes, 71% (est.) [2] | $14.99/mo, $59.99/yr, $149.99 lifetime † [5] | 4.8 (737K) † [5] |
| Readwise | Yes | Yes (highlights) | Yes, 7-day recovery [37] | No [39] | No | No | $66.99 to $119.99/yr (App Store); web $5.59 to $9.99/mo billed yearly [30][32] | 4.8 (1,513) [32] |
| Day One | No | Yes | Yes [18] | Yes, print from $19.99 for 50 pages [17] | No | not found | Silver $49.99/yr † [19] | 4.8 (119K) † [19] |
| Bible Memory App | Yes | Yes (collections) | Yes (Aug 2025) | Partial (verse cards) | Yes (published translations) [40] | 0% (est.) [41] | PRO $9.99; Unlimited $49.99/yr † [40] | 4.80 (33,017) [42] |
| Verses | Yes | No | Yes, daily and weekly † | No | Yes (translations) | not found | $4.99 or $9.99/yr † [43] | 4.7 (3.9K) † [43] |
| Memorize By Heart | Yes | Partial (any text) | Yes † | No | No | not found | $19.99/yr, $49.99 lifetime † [47] | 4.77 (3.5K) [48] |
| MyQuotes | Yes (spaced quiz) | Yes | Partial (30-day dashboard) | No | No | not found | not found | 9 ratings [27] |
| Goodreads quotes | No | Partial (web) | No | Partial (public list) | No [15] | not found | Free | 4.8 (760K, whole app) † |
| **Quoted today** | No | Yes | No | No (favorites profile) | Yes, 60 starter quotes [Q] | No [Q] | Not priced | TestFlight |
| **Quoted proposed** | Yes | Yes | Yes, forgiving | Yes | Yes for catalog quotes; user quotes labelled | No | To be tested (section 8) | n/a |

---

## 4. Coverage matrix: competitors x the four pieces

**Sharpest insight:** three products cover three of the four pieces, and each misses a different one. Readwise has no book. Day One has no practice. The Bible Memory App is scripture only and makes cards, not a book.

| Competitor | Practice | Gather | Streak | Quote book | Full pieces |
|---|---|---|---|---|---|
| Readwise [37][39] | Yes | Yes | Yes | No | 3 |
| Day One [17][18] | No | Yes | Yes | Yes | 3 |
| Bible Memory App [40] | Yes | Yes (scripture) | Yes | Partial (cards) | 3 |
| MyQuotes [27] | Yes | Yes | Partial | No | 2 |
| Verses † [43] | Yes | No | Yes | No | 2 |
| Memorize By Heart † [47] | Yes | Partial | Yes | No | 2 |
| Paper commonplace book | No | Yes | No | Yes | 2 |
| I am [10] | No | Partial | Yes | No | 1 |
| Stoic † [12] | No | No | Yes | Partial (export) | 1 |
| Glasp [20] | No | Yes | No | Partial | 1 |
| Quote games † [24][25] | Partial (decoding) | Partial | Yes (Decodex) | No | 1 |
| Quotemarks [28] | No | Yes | No | Partial (CSV export) | 1 |
| Motivation [4] | No | Partial | No | No | 0 |
| Kindle Notebook † [22] | Partial | Partial | No | No | 0 |
| Goodreads quotes [15] | No | Partial | No | Partial | 0 |
| **Quoted today** | No | Yes | No | No | 1 |
| **Quoted proposed** | Yes | Yes | Yes | Yes | 4 |

"No" means we did not find the feature in the listing or docs. The claim that "no general quote app has all four" holds only as far as we searched.

---

## 5. Module 2: Avatar

**Sharpest insight:** these users already collect. What they lack is a way to keep their quotes alive. Their main pain is not "I need more quotes". It is "I saved it, and it is gone when I need it."

### 5.1 Six core desires

| # | Desire | In their words (close paraphrase) | Source |
|---|---|---|---|
| D1 | One lasting home for lines I love | Saving quotes feels like putting away favourite things to enjoy later. Another has collected wisdom for years from famous people, friends and his son | [89], [90] |
| D2 | Lines come back without effort | It feels good to run into a highlight you once saved. A feature request asks for a random highlight shown like a quote of the day | [91], [92] |
| D3 | Know it by heart when it matters | A Stoic forum member learns a lesson, then forgets to apply it in the moment. A reviewer always wanted to recite verses from memory | [93], [40] |
| D4 | My own quotes, not a canned feed | A reviewer would give a quote widget 10 stars if he could add his own quotes | [94] |
| D5 | A record of who I was, for later or for someone else | A writer wants her daughter to have a record of what made her feel alive | [95] |
| D6 | Practice that feels like play | A user who dreaded memorizing verses says the app makes it easy and fun | [43] |

### 5.2 Six core problems

| # | Problem | In their words | Source |
|---|---|---|---|
| P1 | I collect, then never go back | Writes a few things, then forgets the book exists. Another never revisits her entries | [96], [89] |
| P2 | Rereading does not create recall | **Direct quote**, Panashe Fundira: "I'm skeptical of the value of Readwise, because it is so passive." | [97] |
| P3 | I can't find the quote again | What is the point of a quote book if you must read all of it to find one line | [95] |
| P4 | Capturing takes too long | About 30 minutes per book to copy quotes over | [95] |
| P5 | A streak turns the habit into a chore | An I am reviewer (2 stars, 23 Oct 2026) says streak reminders create anxiety about something that should not matter [10]. A Substack writer says keeping the streak came to matter more than learning Spanish [100] (found through search, not opened) | [10], [100] |
| P6 | Reviews pile up, or the data can't be trusted | About 10 verses fall due on the same day. Reviewers lost all their verses once and say sync fails | [102] |

Also heard: misattributed quotes are a steady complaint among Goodreads librarians [16]. The "same quotes again" complaint is real but small in competitor reviews: 6 of 400 recent Motivation reviews and 1 of 217 Readwise reviews [9][38]. Quoted's own testers did raise it [Q].

### 5.3 Primary conflict

> **"I want my favourite lines to come back to me without effort, but knowing them by heart takes effort, and rereading feels like it is working when it isn't."**

- In Roediger and Karpicke (2006), people who reread predicted better memory a week later: 4.8 on a 7-point scale, against 4.0 for people who were tested. One week later the rereaders recalled 40% and the tested group 61% [73].
- A second, smaller conflict: users want a nudge but hate a nag [10][84].

### 5.4 Master avatar

Composite avatar: "the reader who saves lines". This is a Stoic-leaning self-improvement reader with a quote habit. The See and Hear rows are inferred from desk research, and interviews must confirm them.

| Dimension | Avatar |
|---|---|
| **Hell** (now) | Hundreds of saved lines scattered across screenshots, Kindle, notes and paper, rarely revisited [89][96]. In a hard moment the line is gone [93]. The quote app repeats the same few lines [Q][9]. Not sure the attribution is real [16]. Surprised by an annual charge after a trial [9][10] |
| **Heaven** (wants) | The right line arrives word for word when it matters [93]. One home for every line, findable by author or theme [95]. A book of "my lines" to hand to a child or friend [95] |
| **Pains** | P1 to P6. Billing surprises. Streak guilt. Doubt about attribution |
| **Gains** | Feeling steadier under stress [103]. Being someone who reads and remembers. Pride in what they know by heart (one reviewer calls memorized verses among their most precious possessions) [102]. Sending a friend the right line |
| **See** | Daily quote widgets and feeds [4]. Stoic apps with streaks [14]. Streak counters in habit apps. Goodreads quote pages with misattribution threads [16]. Readwise daily review [37] |
| **Say** (paraphrased) | *I learn the lesson, then forget it when it counts* [93]. *I write a few things down, then forget the book exists* [96]. *Let me add my own quotes* [94] |
| **Hear** | Advice to keep a commonplace book [89][104]. Stoic advice to keep your principles ready to hand [103]. Stories about streak anxiety [100][101] |
| **Do** | Screenshot, highlight in Kindle, type into Notes, copy into a paper notebook (about 30 minutes a book for one writer [95]). Keep streaks in other apps. Send lines to friends |

---

## 6. Segments and the beachhead

**Sharpest insight:** the segment that needs practice most (scripture) is already well served by a free app. The segment that collects most (commonplace keepers) may reject streaks. The overlap that wants all four is the Stoic and self-improvement reader.

Fit ratings are judgments from the voice-of-customer evidence. H = high, M = medium, L = low.

| Segment | Practice | Gather | Streak | Book | Size and growth signal | Willingness-to-pay signal | Competition |
|---|---|---|---|---|---|---|---|
| Stoic and self-improvement readers | H | H | H | M to H | r/Stoicism 835K, +9.7% a year [57] | Stoic app has premium and AI tiers † [12] | Crowded with feed-plus-streak apps [14] |
| Commonplace-book keepers | L to M | H | L | H | r/commonplacebook 89K, +164.1% [55] | Readwise $67 to $120/yr for readers [30]. Day One print [17] | Weak: only tiny apps [27][28] |
| Scripture memorizers | H | L | H | L | Bible Memory App 1.9M installs (est.) [41] | Low: Verses about $9K to $10K/mo (est.) [45]. Remember Me is free [46] | Strong, including free |
| Poetry lovers | H | M | M | M | Poems By Heart withdrawn [50]. RANKA Poems 1.1K installs (est.) [51] | not found | None, but tiny |
| Students, actors, speakers | H | L | M | L | Memorize By Heart 177K installs, 3.9K MAU (est.) [48] | Under $10K/mo (est.) [48] | Moderate. Use is deadline-driven |
| Inspiration seekers (feed users) | L | M | M | L | Motivation 1,076,819 ratings [11]. r/GetMotivated 24.1M, +0.4% [59] | Ad-funded [1] | Dominant incumbents |

GummySearch counts are tool-derived and were updated Oct 1 to 25, 2026. Reddit no longer shows member counts publicly, and GummySearch shuts down on Dec 1, 2026 [60][61].

### Beachhead: Stoic and self-improvement readers who already save quotes

| Reason | Evidence |
|---|---|
| They feel all four pieces | They need lines to come back automatically under stress [103]. They already accept streaks [14]. The guided-journal format shows they value a personal book [12] |
| Their content fits the verified seal | Marcus Aurelius, Seneca and Epictetus are public domain and can be checked against full texts, which is how the 60-quote starter pack was built [Q] |
| They are reachable | r/Stoicism has 835K members and is still growing [57] |
| The pain is acute | "Learn it, then forget it in the moment" is their exact complaint [93] |
| Risk | The Stoic app corner is crowded. Quoted must win on practice and verification, not on another feed |

- **Runner-up to test:** commonplace keepers. They are fastest-growing and most hurt by P1, P3 and P4. If interviews show they reject streaks, keep the streak opt-in and lead with Gather and the book.
- **Founder bias check:** the idea started as "a platform for me". The founder is one data point in the target group, not evidence for it.

---

## 7. Module 3: Market awareness and sophistication

**Sharpest insight:** most target users are problem-aware ("I forget what I save") but have no secular solution in mind. Lead with the problem and a named mechanism, not with "more quotes".

### 7.1 Awareness

| Level | Who | What they believe | What to say | Channel (hypothesis) |
|---|---|---|---|---|
| Unaware | Feed users | Seeing a quote a day is enough | Do not target first | n/a |
| Problem aware | Commonplace keepers, Stoic readers | "I save lines and never use them" [96][93] | "Your favourite lines, ready when you need them, word for word" | Commonplace and Stoic communities [55][57] |
| Solution aware | Anki and Readwise users, Stoics who practise reminding themselves [103] | Spaced review works, but for highlights or flashcards, not quotes | "One minute a day: first letters, then blanks, then the full line" | Reading and learning communities [56] |
| Product aware | People who know Bible Memory App or Readwise | Good tools, wrong content or wrong price for them | "The Bible-memory method for the lines you chose. Every catalog quote verified" | Comparison content |
| Most aware | Quoted TestFlight testers | Already like Quoted | The offer: Practice + streak + book, plus price | In-app, TestFlight notes |

### 7.2 Sophistication by sub-market (judgment)

| Sub-market | Stage | Evidence | Implication |
|---|---|---|---|
| Passive quote and affirmation feeds | 4 | Feeds, widgets, categories, AI and streaks all claimed. Users call the content generic [9] | Do not compete here |
| Stoic apps | 4 | Journal + quotes + streaks + AI tiers [12][14] | Enter with a mechanism and proof, not a feed |
| Highlight review (Readwise) | 3 | Spaced review of your own highlights [39] | Shows the mechanism sells to readers |
| Scripture memory | 4 | Games, first-letter typing, memory health, groups [40][43] | The mechanisms are proven. Borrow them |
| Secular quote practice | 1 to 2 | Only tiny apps (MyQuotes 9 ratings) [27] | An almost empty field |
| Commonplace apps | 2 | Capture plus resurfacing [26][28] | Weak incumbents |

### 7.3 Primary sophistication target

Target **stage 3**. Make a direct claim ("know your favourite quotes by heart") and back it with a named mechanism (one-minute first-letter recall, spaced over days) and a proof element (the verified seal). Users from neighbouring markets (Readwise, Stoic apps, scripture) are already at stage 3 to 4, so a bare claim at stage 1 to 2 will not be believed.

---

## 8. Market size and indie revenue expectations

**Sharpest insight:** the ceiling is set by distribution, not by market size. Even the conservative SAM is far larger than anything a solo founder reaches without a channel.

### 8.1 TAM, SAM, SOM (model output, not data)

| Layer | How it is built | Result | Assumption status |
|---|---|---|---|
| TAM (quote apps) | 6.4M MAU on the two leading quote and affirmation apps (3.9M + 2.5M, est.) [1][2] x $25/yr as if every user paid | About $160M/yr, theoretical | MAU is an estimate. $25 is an assumption close to the all-app median yearly price of $34.80 [62] |
| SAM | 6.4M x 50% on iOS x 50% in English-speaking markets x 10% to 20% who want to curate and practise = 160K to 320K people, x $25/yr | About $4M to $8M/yr | All three cuts are **assumptions**. It is unclear whether AppGoblin's figures for these iOS listings are already iOS-only. If they are, the 50% iOS cut is double-counted and SAM doubles |
| SOM (year 3) | 0.5% to 2% of SAM people paying = 800 to 6,400 payers, x about $21 net/yr (after Apple's 15% small-business commission) | About $17K to $134K/yr | Assumptions. Internally consistent [62] |

### 8.2 Revenue scenarios for a solo indie app

Year-1 downloads of 5K to 30K, organic only, are an **assumption** with no source.

| Scenario | Year 1 (gross) | Year 3 run rate | Basis |
|---|---|---|---|
| Downside (typical) | Under $1K | Under $1K MRR | About 83% of new apps never reach $1K MRR within 2 years. The median app earns about $72/mo at one year [62] |
| Base | About $2.4K to $14.5K | $1K to $5K MRR | 5K to 30K downloads x 2.1% (freemium download-to-paid by day 35) x $23 (global median value per payer, year 1) [62]. Only 17.3% of apps reach $1K MRR within 2 years [62] |
| Upside | About $22.7K | $10K MRR | 30K x 2.9% (Health and Fitness median) x $26.07 (North American *users*, corrected from $32, which applies to North American *developers*) [62]. Only 4.6% reach $10K MRR within 2 years [62]. HabitKit's developer reached $10K MRR about 25 months after launch † [72] |

Both success rates are falling. The $1K rate went from 19% to about 17%, and the $10K rate from 5.3% to 4.6%. New subscription apps per month grew from about 2,000 to almost 15,000 over three years [65][66].

### 8.3 Pricing implications

| Question | Evidence | Working hypothesis |
|---|---|---|
| Price point | All-app median yearly price $34.80 (up from $31.60). Education median $44.99/yr [62][64]. Readwise $66.99 to $119.99/yr [32]. Scripture memory $4.99 to $9.99/yr † [43] | $34.99 to $44.99 a year. Test in section 11 |
| Trial length | Trials of 17 to 32 days convert at 42.5%, against 25.5% for 4 days or less [62] | 7 days or longer |
| Freemium or hard paywall | Hard paywall 10.7% vs freemium 2.1% download-to-paid by day 35 [62]. Revenue per install at day 60 is $3.09 vs $0.38 [63]. These are medians across apps that chose each model, not a controlled test | Freemium fits Quoted, because Gather and friend sharing are the growth loop. Gate Practice depth and the book, not collecting |
| Billing trust | Billing is the main low-star theme for Motivation and I am [9][10] | Clear trial-end reminders as a deliberate brand choice |

---

## 9. Evidence on practice and streaks

**Sharpest insight:** Practice is the best-supported piece, and the streak is the riskiest. Retrieval beats rereading by a moderate margin after a day or more. Streaks help only when they forgive.

### 9.1 Practice: what works

| Finding | Effect | Source |
|---|---|---|
| Testing beats restudy (meta-analysis, 159 effect sizes, 61 studies) | g = 0.50 (95% CI 0.42 to 0.58) | Rowland 2014 [74] |
| ...at retention of 1 day or more | g = 0.69 (vs 0.41 under 1 day) | [74] |
| ...for prose | g = 0.58 | [74] |
| ...with feedback after each attempt | g = 0.73 (vs 0.39 without) | [74] |
| ...when the practice test is cued recall | g = 0.61 (vs 0.29 for free recall) | [74] |
| Prose, one week later: study once then test three times, vs study four times | 61% vs 40% recalled. On a 5-minute test, rereading won, 83% vs 71% | Roediger and Karpicke 2006 [73] |
| Spaced vs massed retrieval practice | g = 0.74 (secondhand) | Latimier 2021 [75] |
| Expanding vs fixed review intervals | g = 0.034, no real difference (secondhand) | [75] |
| First-letter cueing as a training method for verbatim text | **No controlled study found.** Nearest: first-letter prompts at test helped recall of passages already learned (Rubin 1977) and a word-list study (Nelson and Archer 1972) | [76][77] |
| Learners misjudge spacing | 90% did better with spacing; 72% believed massing worked better † | Kornell 2009 [79] |

**Design read:**
- Cued formats come first: first letters, then blanks.
- Always show the correct line after each attempt, since feedback roughly doubles the effect.
- Use simple fixed spacing over days.
- Expect users to underrate practice at first, so show their progress.

### 9.2 Streaks: what works

| Change | Result | Source |
|---|---|---|
| One lesson extends the streak (tested about late 2019, reported Nov 2020) | +3.3% D14 retention, +1% daily active learners, +10.5% learners on a streak within 20 days (all relative) | Duolingo [80] |
| Allow 2 streak freezes at once | +0.38% daily active learners. Three freezes were no better than two | [81][83] |
| Reaching a 7-day streak | 3.6x more likely to finish the course (correlation, no method given) | [81] |
| Scale | About 43M DAU on a 7+ day streak and about 15M on 365+ days as of Dec 31, 2025, against a Q4 2025 average of 52.7M DAU | Duolingo 10-K [82] |
| Weekly skip reserve vs strict 7-of-7 goal | Next-day goal hit after a miss: 55% (weekly reserve) vs 48% (monthly) vs 44% (easy 5 of 7) vs 37% (strict). 273 people randomized. The gain appeared only when people used a skip | Sharif and Shu 2021 [85] |
| Repairing a broken streak | Reduces the drop in engagement after a break | Silverman and Barasch 2023, 7 studies [84] |
| Recovery window | Readwise counts a missed Daily Review if it is done within 7 days | [37] |

### 9.3 What backfires

| Pattern | Evidence | Source |
|---|---|---|
| Making the daily unit trivial | A single exercise as a streak day produced no DAU movement at all | Lenny's Podcast transcript, Dec 2024 [83] |
| Strict streaks | 37% next-day rebound vs 55% with a weekly reserve | [85] |
| Showing a broken streak | Lower later engagement than an intact log, even for the same behaviour. Worse when people blame themselves | [84] |
| Warnings sent after the user already practised | Several I am streak complaints are about false "you will lose your streak" notifications | [10] |
| Short trials | 4 days or less: 25.5% trial-to-paid. 55.4% of 3-day trial *cancellations* happen on day 0 | [62] |
| Overdue review piles | About 10 verses due on one day. Bible Memory App shipped fixes for verses wrongly shown as overdue † | [102][40] |
| Speech recognition grading | The most-complained-about mechanic in Verses (Speak Out) † | [43] |

Evidence limits:
- The Duolingo data are company A/B tests and correlations, not peer-reviewed.
- The one replication of Sharif and Shu that we found had 28 participants and found no effect, which is weak evidence either way [87].
- I found no peer-reviewed measure of streak anxiety in learning apps.
- In I am's 450 most recent US reviews, 14 mention streaks and 4 of those are 1 or 2 stars [10].

### 9.4 Benchmarks

| Metric | Value | Source and date |
|---|---|---|
| D30 retention, Education | 8.02% (OneSignal) vs 2.7% iOS (AppsFlyer via Business of Apps) | OneSignal 2024 [68]. Braze 2026 [69] |
| D30 retention, Lifestyle | 5.94% (D1 25%, D7 13.13%) | OneSignal 2024 [68] |
| D30 retention, all apps | 7.88% (OneSignal) vs 3.10% iOS (Pushwoosh) | [68]. Pushwoosh 2025 [70] |
| D7 retention, all apps, iOS | 6.89% | Pushwoosh 2025 [70] |
| **Planning baseline** | **D30 about 3% to 8%** | Sources differ by 2 to 3x |
| iOS push opt-in | Education 37.1%, Lifestyle 34% (OneSignal). All apps 56% (Batch, Jul 2024 to Jul 2025) | [68][71] |
| Implication for Reminders | About 45% to 65% of iOS users may not opt in, so Practice must work from the widget and the app, not only from notifications | [68][71] |
| Download to paid, day 35 | 2.0% global. 2.9% Health and Fitness. 2.1% freemium, 10.7% hard paywall | RevenueCat SOSA 2026 [62] |
| Trial to paid, Health and Fitness | 37.7% median (top quartile above 51.4%) | [62] |
| Trial to paid, Education or Lifestyle | Not published | [62][64] |
| Trial to paid by length | 17 to 32 days 42.5%. 4 days or less 25.5% | [62] |
| Revenue per install, day 60 | $0.34 all apps. $0.66 Health and Fitness | [62] |
| Value per payer, year 1 | $23 global. $26.07 North American users | [62] |
| Median yearly price | $34.80 all apps. $44.99 Education | [62][64] |
| Yearly-subscriber retention, year 1 | About 27% hard paywall, 28% freemium | [63] |

RevenueCat's data covers 2025, more than 115,000 apps that use RevenueCat, and more than $16B in revenue, across iOS, Android and web [62].

---

## 10. Risks and unknowns

**Sharpest insight:** the biggest risk is not that the idea is wrong. It is that a solo founder ships four features and nobody hears about them.

| Risk | Evidence | Severity (judgment) | How to reduce or test |
|---|---|---|---|
| No distribution channel | About 83% of apps never reach $1K MRR within 2 years [62] | High | Pick one community channel for the beachhead before building. Use the quote book as a shareable artifact |
| Practice feels like homework | Rereaders feel more confident while remembering less [73]. Verses users dreaded memorizing until it felt like a game [43] | High | Keep sessions under a minute, opt-in per quote, and show progress. Validation test, week 1 |
| Streak backlash | [10][84][85] | Medium | One real practice counts as a day. Weekly reserve, repair, no shame copy, can be turned off. Validation test arm |
| The verified seal does not cover user quotes | Only 60 quotes are verified so far [Q] | Medium | Label "verified" vs "yours". Grow the catalog in the beachhead's authors first |
| Notification opt-in caps Reminders | 34% to 56% iOS opt-in [68][71] | Medium | Make Practice reachable from the widget and the tab, not only from notifications |
| Copyright on a printed or shared quote book | **Not researched.** Quotes from in-copyright books, printed and sold, may raise copyright issues | Unknown, possibly high | Get a legal check before offering print. Public-domain verified quotes are the safe first scope |
| Print partner and privacy | A print service would receive users' quote text. This clashes with the no-tracking brand if handled carelessly | Medium | Start with an on-device PDF export. Add print later |
| Billing distrust in the category | [9][10] | Medium | Trial-end reminder, plain pricing |
| Competitors copy | Readwise could add a book. Bible Memory App could go secular | Medium | Verification is the moat that is slowest to copy |
| Solo-founder scope | Four pieces plus the in-progress catalog work [Q] | High | Build order: Practice + streak first, book export second, print last |
| Data quality | AppGoblin and Adapty publish no method. Adapty's Readwise and Motivation pages contradict themselves [6][33]. GummySearch closes Dec 1, 2026 [60]. Reddit was unreadable | Medium | Treat estimates as orders of magnitude |

**Unknowns (not found)**
- Readwise's revenue and user count [33].
- Trial-to-paid rates for Education and Lifestyle [62].
- Google Trends, TikTok and YouTube interest in commonplace books.
- Whether AppGoblin's MAU figures are iOS-only.
- The number of Quoted TestFlight testers and their current retention. There are no analytics SDKs [Q].
- Whether any controlled study supports first-letter cueing for verbatim text [76][77].

---

## 11. User research plan

**Sharpest insight:** Quoted can test Practice and Streak without writing code. A Reminder whose text is only the first letter of each word is already a recall card.

### 11.1 Research questions

1. Do people who save quotes want to *know* them, or just *see* them?
2. Will they practise most days if it takes under a minute?
3. Does a streak count help them or stress them?
4. Does a finished quote book create pull (sharing, printing, paying)?
5. Does verified wording matter to them, and when?
6. Which segment feels all four pieces: Stoic readers or commonplace keepers?

### 11.2 Screener (TestFlight and outside recruits)

| # | Question | Use |
|---|---|---|
| 1 | In the last 3 months, how did you save quotes you liked? (screenshots, notes app, Kindle or book highlights, paper notebook, a quote app, I didn't) | **Screen out "I didn't"** |
| 2 | Roughly how many quotes have you saved in total? (under 10, 10 to 50, 50 to 200, over 200) | Prefer 10 or more |
| 3 | Have you ever learned a quote, verse, poem or lines by heart on purpose? When was the last time? | Record for segment quotas |
| 4 | Which describes you best? (Stoic or self-improvement reader; faith or scripture; commonplace or journal keeper; poetry lover; student, speaker or performer; I just like inspiring quotes) | Segment quotas |
| 5 | Do you keep a daily streak in any app now? Which one? Have you ever lost a long streak? | Streak attitude |
| 6 | Which apps or books about quotes, journaling or learning have you paid for in the last year? Roughly how much? | Past spending, not hypothetical spending |
| 7 | How many days last week did you open Quoted? (TestFlight testers only) | Activity |
| 8 | Willing to do a 35-minute video call and a 2-week test this month? (yes or no) | Required |

**Quotas for 5 or 6 interviews:** 2 Stoic or self-improvement readers, 1 or 2 commonplace keepers, 1 scripture or poetry memorizer, 1 casual collector as a control. At least 2 people must come from outside the founder's circle.

### 11.3 Interview guide (35 minutes)

Rules: ask about past behaviour, not hypotheticals. Do not pitch. Let silences run.

| Block | Time | Questions |
|---|---|---|
| Warm-up | 3 min | What are you reading now? When did a line from a book or a person last stay with you? |
| Context | 8 min | Walk me through the last time you saved a quote. Where did it go? When did you last look at it? What do you use today, and what annoys you about it? |
| Deep dive: practice | 4 min | Is there a line you know by heart? How did you learn it? When did you last use it? Have you ever tried to memorize on purpose? What happened, and why did you stop? |
| Deep dive: streak | 3 min | Have you kept a streak in any app? Broken one? How did that feel, and what did you do the next day? |
| Deep dive: book and trust | 3 min | Have you ever made, given or wanted a book of collected quotes? Have you ever found out a quote was misattributed? How did that feel? |
| Concept cards | 10 min | Show 4 plain cards one at a time: Practice, Gather, Streak, My quote book. For each: "When last week would you have used this?" and "What would make you turn it off?" Then have them rank the four and explain the top and bottom card. Probe: does verified exact wording matter to you? When? |
| Wrap-up | 4 min | If Quoted kept only one of these, which should it be? What is missing? Who else should I talk to? |

### 11.4 Two-week validation test (before building)

> **Superseded.** The LLM Council revised this test: it dropped the streak arm, added a stranger track that can fail, and added a reservation page. The version to run is in `docs/practice-and-quote-book-plan.md` §7. This one is kept for the record.

Goal: decide whether to build Practice, the Streak tab and the Quote book, using only features that exist today. Analytics SDKs stay out. Every measure is self-reported or counted by hand.

| When | What testers do | What the founder does |
|---|---|---|
| Day 0 (about 30 min) | Pick 5 quotes from their Library of similar length: **3 to practise, 2 as controls** that stay in normal Reminders. Write all 5 from memory (baseline) | Score the share of words correct for each quote. Randomly split testers into a **streak arm** and a **no-streak arm** |
| Day 0 setup | For each practice quote, add a "practice card" to the Library whose text is the first letter of each word. Schedule it in Reminders once a day. Do not heart it | Send a one-page how-to. Cards get deleted after the test |
| Days 1 to 7 | When the card arrives, say or type the full line, then open the real quote to check it. Send a 3-question check-in: practised (yes or no), words missed, seconds spent | Streak arm: reply with the day count, allow 1 free skip per week, never send warnings. No-streak arm: reply "thanks" only |
| Days 8 to 14 | Keep practising. Drop a quote to every other day once it is recalled perfectly twice (fixed spacing) | On Day 8, send each tester a designed PDF "quote book" made from a quote list *they send* (do not pull private data from the hosted database). Do not ask for anything. On Day 12, offer "reserve a printed copy at $X" with no payment taken |
| Day 14 | Write all 5 quotes from memory again. 15-minute exit call: rank the four pieces, describe how the streak felt, say what they would turn off and what they would pay | Score delayed recall. Count shares, reservations and edit requests on the book |

**Decision thresholds.** These are the founder's go or no-go lines, set by judgment. They are not benchmarks. The results are directional only.

| Question | Measure | Go if | Rethink if |
|---|---|---|---|
| Will they practise? | Share of testers who practise on 5+ of 7 days in week 1 | Half or more | Under a third |
| Does practice beat Reminders alone? | Day 14 minus Day 0 word accuracy, practised vs control quotes | Practised quotes gain clearly more for most testers | No difference |
| Does the streak help? | Check-in days and a "felt pressured" rating, by arm | Streak arm practises as much or more, and no more than 1 in 4 feel pressured | Streak arm feels pressured or shows no lift. Then make the streak opt-in and weekly |
| Does the book create pull? | Share who share the PDF, ask for edits, or reserve a print | A third or more do at least one | Nobody shares or reserves |
| Which piece matters? | Most common first-ranked card | Practice or Book | Gather or Reminders. Then focus on catalog freshness (already in design [Q]) |
| Price | Reservations at the stated price, plus stated acceptable range | Some reservations at $34.99 to $44.99 a year equivalent | Only "free" is acceptable |

**Caveats**
- Expect a small sample and friendly testers.
- Novelty will inflate week 1.
- Self-reports overstate practice.
- With at least 8 people finishing, the results can guide the build order. They cannot predict revenue.

**If the test says go, build in this order:**
1. A Practice tab on your own quotes: first letters, then blanks, then the full line, with the correct text shown after every attempt, a capped daily set, and under a minute per quote.
2. A streak where one real practice counts as a day, with a weekly reserve, repair, no shame copy and an off switch.
3. A quote book exported as an on-device PDF.
4. Print, but only after a copyright check.

---

## 12. Sources

**Quoted**
- [Q] Quoted project brief and repo context, 2026-10-26.

**Quote, feed and journal apps**
1. AppGoblin, Motivation: https://www.appgoblin.info/apps/876080126
2. AppGoblin, I am: https://www.appgoblin.info/apps/874656917
3. AppGoblin revenue-bucket code: https://github.com/appgoblin-dev/appgoblin/blob/main/frontend/src/lib/utils/formatNumber.ts
4. Motivation, App Store US: https://apps.apple.com/us/app/motivation-daily-quotes/id876080126
5. I am, App Store US: https://apps.apple.com/us/app/i-am-daily-affirmations/id874656917
6. Adapty, Motivation: https://adapty.io/paywall-library/motivation/
7. Screensdesign, Motivation: https://screensdesign.com/showcase/motivation-daily-quotes
8. AppMasters ($600K claim, now returns 404, unverifiable): https://appmasters.com/blog/motivation-app-makes-600000-month
9. Motivation US review feed: https://itunes.apple.com/us/rss/customerreviews/id=876080126/sortBy=mostRecent/json
10. I am US review feed: https://itunes.apple.com/us/rss/customerreviews/page=1/id=874656917/sortBy=mostRecent/json
11. iTunes Lookup, Motivation: https://itunes.apple.com/lookup?id=876080126&country=us
12. Stoic, App Store US: https://apps.apple.com/us/app/stoic-journal-mental-health/id1312926037
13. AppGoblin, Stoic: https://www.appgoblin.info/apps/1312926037
14. The Stoic Year listing: https://mwm.ai/apps/the-stoic-year/6779704933 ; Stoic Quotes: https://apps.apple.com/us/app/-/id6760383702
15. Goodreads quotes: https://www.goodreads.com/quotes
16. Goodreads Librarians, misattributed quotes: https://www.goodreads.com/topic/show/22037811-quotes-attributed-to-the-wrong-author
17. Day One book printing: https://dayoneapp.com/guides/tips-and-tutorials/book-printing
18. Day One streaks: https://dayoneapp.com/guides/tips-and-tutorials/journal-streaks/
19. Day One, App Store US: https://apps.apple.com/us/app/day-one-journal-private-diary/id1044867788
20. Glasp, App Store: https://apps.apple.com/us/app/id1645763435
21. Glasp, JETRO interview 2024: https://www.jetro.go.jp/en/jgc/interviews/2024/86f67b89f9736ed5.html
22. Kindle, App Store US: https://apps.apple.com/us/app/amazon-kindle/id302584613
23. Readwise docs, Kindle import limits: https://docs.readwise.io/readwise/docs/importing-highlights/kindle
24. Cryptogram, App Store: https://apps.apple.com/us/app/id380210791
25. Decodex, Product Hunt: https://www.producthunt.com/products/decodex
26. Commonplace Quote, App Store: https://apps.apple.com/app/id6758316134
27. MyQuotes, iTunes Lookup: https://itunes.apple.com/lookup?id=6737528555&country=us
28. Quotemarks, App Store: https://apps.apple.com/app/id1327090189
29. PastWisdom, Product Hunt: https://www.producthunt.com/p/pastwisdom/pastwisdom-quote-verification

**Readwise**
30. Pricing: https://readwise.io/pricing
31. Subscription FAQ: https://docs.readwise.io/faqs/subscription
32. App Store US: https://apps.apple.com/us/app/readwise/id1476885528
33. Adapty (self-contradicting estimate): https://adapty.io/paywall-library/readwise/
34. startups.fm: https://startups.fm/startups/readwise
35. Caplight: https://www.caplight.com/company/readwise
36. Why we're bootstrapping (2018): https://blog.readwise.io/why-were-bootstrapping-readwise/
37. Changelog, stats and streak recovery: https://readwise.io/changelog/stats
38. US review feed: https://itunes.apple.com/us/rss/customerreviews/id=1476885528/sortBy=mostRecent/json
39. Reviewing highlights docs: https://docs.readwise.io/readwise/docs/faqs/reviewing-highlights

**Memorization apps**
40. Bible Memory App, App Store US: https://apps.apple.com/us/app/bible-memory-scripture-typer/id496790833
41. AppGoblin, Bible Memory App: https://appgoblin.info/apps/496790833
42. iTunes Lookup, Bible Memory App: https://itunes.apple.com/lookup?id=496790833&country=us
43. Verses, App Store US: https://apps.apple.com/us/app/id939461663
44. AppGoblin, Verses: https://appgoblin.info/apps/939461663
45. Adapty, Verses: https://adapty.io/paywall-library/verses-bible-memory/
46. Remember Me press page (self-reported): https://doc.remem.me/docs/press/
47. Memorize By Heart, App Store US: https://apps.apple.com/us/app/memorize-by-heart-learn-texts/id1436935583
48. AppGoblin, Memorize By Heart: https://appgoblin.info/apps/1436935583
49. AppGoblin, Memorise: https://appgoblin.info/apps/1464877607
50. Poems By Heart (inkle): https://www.inklestudios.com/poemsbyheart/
51. AppGoblin, Poems (RANKA): https://appgoblin.info/apps/1509333489
52. AnkiMobile, App Store US: https://apps.apple.com/us/app/ankimobile-flashcards/id373493387
53. Brainscape, App Store US: https://apps.apple.com/us/app/brainscape-study-flashcards/id442415567
54. Poimena comparison page (self-published): https://doc.remem.me/best-bible-memory-apps/

**Communities**
55. GummySearch r/commonplacebook: https://gummysearch.com/r/commonplacebook/
56. GummySearch r/Anki: https://gummysearch.com/r/Anki/
57. GummySearch r/Stoicism: https://gummysearch.com/r/Stoicism/
58. GummySearch r/quotes: https://gummysearch.com/r/quotes/
59. GummySearch r/GetMotivated: https://gummysearch.com/r/GetMotivated/
60. GummySearch closing notice: https://gummysearch.com/final-chapter
61. Reddit member-count change: https://www.socialsamosa.com/news-2/reddit-member-count-new-engagement-metrics-10067678

**Benchmarks**
62. RevenueCat, State of Subscription Apps 2026: https://www.revenuecat.com/state-of-subscription-apps
63. RevenueCat blog, 2026 benchmarks: https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026
64. RevenueCat, Education breakout: https://www.revenuecat.com/state-of-subscription-apps-2026-education
65. ppc.land on RevenueCat 2026: https://ppc.land/the-app-middle-class-is-dying-and-revenuecats-data-shows-exactly-how-fast/
66. 9to5Mac on RevenueCat 2026: https://9to5mac.com/?p=1042212
67. SaaStr summary: https://www.saastr.com/the-top-10-learnings-from-revenuecats-state-of-subscription-apps/
68. OneSignal benchmarks 2024: https://onesignal.com/mobile-app-benchmarks-2024
69. Braze (AppsFlyer via Business of Apps, 2026): https://www.braze.com/resources/articles/mobile-app-retention
70. Pushwoosh retention article (2025): https://www.pushwoosh.com/blog/increase-user-retention-rate
71. Batch push benchmark: https://batch.com/blog/case-studies/benchmark-notifications-push-crm-mobile
72. HabitKit year in review †: https://sebastianroehl.substack.com/p/2024-my-indie-app-business-year-in

**Learning science**
73. Roediger and Karpicke 2006: https://psychology.ecu.edu/wp-content/pv-uploads/sites/216/2019/03/Roediger-Karpicke-2006.pdf
74. Rowland 2014: https://courseware.epfl.ch/assets/courseware/v1/fdde2f0aa590bf3b1324077a6bf1540c/asset-v1%3AEPFL%2BDEMO%2B2020%2Btype%40asset%2Bblock/Rowland2014-meta-analysis.pdf
75. Latimier et al. 2021 (secondhand): https://ifp.nyu.edu/?p=1511228 ; primary: https://link.springer.com/article/10.1007/s10648-020-09572-8
76. Rubin 1977: https://fds.duke.edu/db/aas/pn/faculty/david.rubin/publications/253706
77. Nelson and Archer 1972: https://www.researchgate.net/publication/232418525_The_first_letter_mnemonic
78. KU first-letter mnemonic brief (lists, not verbatim text): https://sim.ku.edu/sites/sim/files/files/Research/Research%20Brief-%20First%20Letter%20Mneumonic%20Strat.pdf
79. Kornell 2009 †: https://cir.nii.ac.jp/crid/1361699994055985152

**Streaks**
80. Duolingo, Improving the streak (2020): https://blog.duolingo.com/improving-the-streak
81. Duolingo, How the streak builds habit (2022): https://blog.duolingo.com/how-duolingo-streak-builds-habit
82. Duolingo FY2025 10-K: https://www.sec.gov/Archives/edgar/data/1562088/000162828026012494/duol-20251231.htm
83. Lenny's Podcast, Duolingo streaks (Dec 2024), transcript: https://github.com/ChatPRD/lennys-podcast-transcripts/blob/main/episodes/jackson-shuttleworth/transcript.md ; video: https://www.youtube.com/watch?v=_CCwoQZH5hI
84. Silverman and Barasch 2023: https://academic.oup.com/jcr/article-abstract/49/6/1095/6623414 ; https://udspace.udel.edu/handle/19716/34160
85. Sharif and Shu 2021: https://anderson-review.ucla.edu/wp-content/uploads/2021/03/Sharif-Shu_EmergencyReserveFailure_OBHDP2019.pdf ; https://ideas.repec.org/a/eee/jobhdp/v163y2021icp17-29.html
86. UCLA Anderson Review summary: https://anderson-review.ucla.edu/emergency-reserves/
87. Heidt 2023 thesis (n = 28): https://studenttheses.uu.nl/handle/20.500.12932/44466
88. Duolingo Q2 2026 earnings call †: https://allmind.ai/earnings/event/2940676

**Voice of customer**
89. Substack comments, starting a commonplace book: https://ayushithakkar.substack.com/p/how-to-start-a-commonplace-book-and/comments
90. Lickability, Quotebook 3 reviews: https://lickability.com/blog/quotebook-3-the-reviews-are-in
91. Readwise reviews, Product Hunt: https://www.producthunt.com/products/readwise/reviews
92. BookFusion feature request: https://bookfusion.featureos.app/p/display-a-random-highlight-like-a-quote-of-the-day-for-memory-retention
93. Art of Memory forum, Stoicism: https://forum.artofmemory.com/t/stoicism/58502
94. Quote of the Day Widget, App Store: https://apps.apple.com/app/id885162566
95. Petya, Issue 107: Commonplace journaling: https://petya.substack.com/p/issue-107-commonplace-journaling
96. Tildes, Keeping a commonplace book: https://tildes.net/~creative/1cc3/keeping_a_commonplace_book
97. GreaterWrong comment on Readwise: https://greaterwrong.com/posts/b988iuyNQNZJMwoDP/do-you-trust-the-research-on-handwriting-vs-typing-for-notes/comment/xgiaKpN8wX4iwCiSf
98. John Piper Q&A: https://en.gospeltranslations.org/wiki/How_do_you_avoid_forgetting_Scripture_that_you%27ve_memorized%3F
99. Reading Revisited comments: https://readingrevisited.substack.com/p/crossing-to-safety/comments
100. The End of the Streak (found through search, not opened): https://theconversationstarter.substack.com/p/the-end-of-the-streak
101. Gulf Today column (found through search, not opened): https://gulftoday.ae/Opinion/2023/11/06/The-language-app-you-just-cant-put-down
102. Remember Me reviews (aggregator): https://justuseapp.com/en/app/1600128209/remember-me-bible-memory-joy/reviews
103. How to remind yourself like Marcus Aurelius: https://whatisstoicism.com/?p=2817
104. Book Riot, On Memorizing Poetry: https://bookriot.com/on-memorizing-poetry/
105. My English Literature GCSE (AppFollow): https://appfollow.io/ios/my-english-literature-gcse/1335737542?country=us

---

## Appendix A: fact-check of the decision-critical claims (2026-10-26)

Each claim below was extracted from the five research reports, then re-checked by an independent agent against primary sources.

| # | Status | Claim as checked |
|---|---|---|
| 1 | confirmed | Every figure in the claim matches the AppGoblin pages crawled 2026-10-26. Two refinements: (a) Per AppGoblin's source code, "$200K+" is the bucket from $200,000 to $499,999 a month, not an open-ended floor. (b) Motivation's install trend is labelled "Steady" (+326K/month). Only I am is labelled "Declining" (+242K/month). Install counts, MAU, revenue and the ad/IAP splits are all AppGoblin model estimates; Apple publishes no install data. The "$600K/month in 2020" figure is still unverifiable: the AppMasters page returns 404 and cited no primary source. Other current third-party estimates for Motivation contradict each other, from $250K to $600K/month (Adapty, Screensdesign). Source: https://www.appgoblin.info/apps/876080126 ; https://www.appgoblin.info/apps/874656917 ; https://github.com/appgoblin-dev/appgoblin/blob/main/frontend/src/lib/utils/formatNumber.ts ; https://apps.apple.com/us/app/motivation-daily-quotes/id876080126 ; https://apps.apple.com/us/app/i-am-daily-affirmations/id874656917 ; https://adapty.io/paywall-library/motivation/ ; https://screensdesign.com/showcase/motivation-daily-quotes |
| 2 | corrected | Apps for memorizing short text word for word get real use but earn little. These figures are third-party estimates as of October 2026, and AppGoblin's "<$10K" is a bucket, not a point figure.  - The Bible Memory App: about 1.9M cumulative iOS installs, about 138K MAU and under $10K a month (AppGoblin, crawled 2026-10-26). - Verses: about $9K to $10K a month (Adapty, updated 2026-10-23), with 211K installs and about 14K MAU (AppGoblin, crawled 2026-10-25). It has not had an App Store update since March 2020. - Remember Me: free, no ads, and self-reports 2.2M+ downloads across Google Play and the App Store (press page, April 2026). This figure is not verified. - The largest secular word-for-word text memorizer found is Memorize By Heart, a general app for speeches, poems and quotes rather than quotes alone. It has about 177K installs but only about 3.9K MAU and under $10K a month (AppGoblin, crawled 2026-10-25). - No quote-only memorization app at meaningful scale was found:   - Memorise (Hayden Do) has 0 ratings and has not been updated since 2019.   - Poems - Learn poetry by heart has about 1.1K installs.   - Penguin and inkle's Poems By Heart is "no longer available to buy". Source: https://appgoblin.info/apps/496790833 ; https://appgoblin.info/apps/939461663 ; https://adapty.io/paywall-library/verses-bible-memory/ ; https://doc.remem.me/docs/press/ ; https://appgoblin.info/apps/1436935583 ; https://appgoblin.info/apps/1464877607 ; https://www.inklestudios.com/poemsbyheart/ |
| 3 | corrected | Readwise is a bootstrapped company. In an App Store developer reply it calls itself "a bootstrapped (ie not VC-backed) startup". Its 2018 blog post explains the choice not to raise VC. It was founded in 2018 (some secondary sites say 2017). Staff estimates are 10 to 50 (startups.fm), with Caplight showing growth from 25 to 30 on 2026-01-21. Its daily review uses spaced repetition on each user's own saved highlights. Readwise's own docs say there is no free plan after the 30-day trial. Current US list prices run about $67 to $120 a year. On the web that is Highlights Lite at $5.59/mo and Full at $9.99/mo, both billed yearly ($67.08 and $119.88). The US App Store yearly in-app purchases are $66.99 (Lite) and $119.99 (Full). The same US App Store page also still lists older prices ($52.99 and $94.99 yearly, $4.99 and $8.99 monthly), which explains why secondary reports disagree. The duplicate prices are old and current tiers in the same US store, not regional prices. Readwise does not publish regional or PPP pricing. It gives 50% discounts on request to students, academics and people in developing countries, applied only to subscriptions bought on its website. Adapty's paywall library page (updated 2026-10-24) is an unsourced app-only estimate that contradicts itself: $10K vs about $20K monthly revenue and <5K vs <1K monthly downloads. The idea that most billing happens on the web is an inference, not a reported fact. Company revenue and current user counts were not found. Source: https://readwise.io/pricing ; https://docs.readwise.io/faqs/subscription ; https://apps.apple.com/us/app/readwise/id1476885528 ; https://adapty.io/paywall-library/readwise/ ; https://startups.fm/startups/readwise ; https://www.caplight.com/company/readwise ; https://blog.readwise.io/why-were-bootstrapping-readwise/ |
| 4 | corrected | Per GummySearch subreddit pages updated October 1 to 25, 2026 (yearly growth, third-party estimates, not verifiable against Reddit, which no longer shows member counts publicly), r/commonplacebook has 89K members, up 164.1% in a year (+55K). r/Anki has 209K members, up 19.8% (+35K). r/Stoicism has 835K, up 9.7% (+74K). r/quotes has 526K, up 7.1% (+35K). r/GetMotivated has 24.1M, up 0.4%, though it still added more members in absolute terms (+93K) than r/commonplacebook. The commonplace-book community is growing fastest in percentage terms but is small. Stoicism and quotes grew at similar rates. GummySearch stopped taking new customers in November 2025 and shuts down fully on December 1, 2026, so these pages may soon disappear. Source: https://gummysearch.com/r/commonplacebook/ ; https://gummysearch.com/r/GetMotivated/ ; https://gummysearch.com/r/Stoicism/ ; https://gummysearch.com/r/Anki/ ; https://gummysearch.com/r/quotes/ ; https://gummysearch.com/final-chapter |
| 5 | confirmed | The claim is correct as stated. One precision: RevenueCat gives the top-10% threshold as $2,574 a month (rounded to $2,500+ in its own takeaway). The median at one year is about $72 a month. The report's Part 1 was released March 12, 2026. The data comes only from apps that use RevenueCat. The SOM range is an internal model estimate, not a sourced figure. Source: https://www.revenuecat.com/state-of-subscription-apps |
| 6 | confirmed | From RevenueCat State of Subscription Apps 2026 (data mostly from 2025; companion blog dated March 19, 2026). Download to paid by day 35: 2.0% global median, 2.9% for Health and Fitness. By access method: 2.1% for freemium vs 10.7% for hard paywall, about 5x, with much wider variance. Median value per payer after one year: $23 globally. It is $32 for apps by North American developers and $26.07 for North American users (by user geography). Median revenue per install at day 60: $0.34 for all apps, $0.66 for Health and Fitness. By access method it is $3.09 for hard paywall vs $0.38 for freemium. Source: https://www.revenuecat.com/state-of-subscription-apps |
| 7 | corrected | Pricing and trial benchmarks from RevenueCat State of Subscription Apps 2026 (2025 data, more than 115,000 apps, iOS, Android and web, published about March 2026). The median yearly price is $34.80, up from $31.60. Education has the highest yearly median at $44.99 and is tied for the highest monthly median at $9.99. Median trial-to-paid in Health and Fitness is 37.7%, with the top quartile above 51.4%. Trials of 17 to 32 days convert at a 42.5% median (top quartile above 59.4%), against 25.5% for trials of 4 days or less (top quartile above 38.5%). Of all cancellations of 3-day trials, 55.4% happen on Day 0. This is the share of cancellations, not of all 3-day trials. Trial-to-paid medians for Education and Lifestyle are not published in the public pages, including the Education category breakout. Source: https://www.revenuecat.com/state-of-subscription-apps/ |
| 8 | confirmed | Retention benchmarks vary 2 to 3x between sources. - OneSignal's 2024 benchmarks (page published 2024-09-17, apps using OneSignal, no sample or period stated) put D30 at 8.02% for Education, 5.94% for Lifestyle and 7.88% for all apps. - AppsFlyer data via Business of Apps (2026, as reproduced by Braze on 2026-07-24) puts Education D30 at 2.7% on iOS and 2.2% on Android. - The Pushwoosh Benchmarks Study 2025 (cited in a Pushwoosh article dated 2025-11-20) puts the iOS all-app D30 average at 3.10%, and Android at 2.82%. - OneSignal gives iOS push opt-in of 37.1% for Education and 34% for Lifestyle. Batch's July 2024 to July 2025 benchmark gives 56% for iOS across all apps.  Planning baseline: about 3% to 8% D30, and somewhere around 45% to 65% of iOS users not opting in to notifications. Source: https://onesignal.com/mobile-app-benchmarks-2024 |
| 9 | corrected | Retrieval practice beats rereading most clearly on delayed tests. In Roediger and Karpicke (2006, Psychological Science 17(3), Experiment 2), one week after studying a prose passage, the group that studied once and then took three recall tests (STTT) recalled 61% of idea units. The group given four 5-minute study periods (SSSS, about 14 readings in total) recalled 40%. On a 5-minute test the restudy group won, 83% to 71%. The SSSS group also predicted better 1-week memory: 4.8 on a 7-point scale, against 4.2 (SSST) and 4.0 (STTT). Rowland (2014, Psychological Bulletin 140(6)) pooled 159 effect sizes from 61 studies and found testing beats restudy with g = 0.50 (95% CI 0.42 to 0.58). The benefit was smaller at retention intervals under 1 day (g = 0.41, k = 103) than at 1 day or longer (g = 0.69, k = 56). So "only on a delayed test" holds for the 5-minute test in Roediger and Karpicke, not as a general rule. For prose specifically, g = 0.58 (k = 23). With feedback, g = 0.73; without it, g = 0.39. Latimier, Peyre and Ramus (2021, Educational Psychology Review 33, 959 to 987) report g = 0.74 from 29 studies (39 effect sizes, secondhand) for SPACED versus MASSED retrieval practice. That is not spaced retrieval versus restudy, so it cannot be set against Rowland's 0.50. In the same paper, expanding intervals did no better than uniform ones (g = 0.034, secondhand). No controlled training study was found of first-letter cueing for learning verbatim text. The nearest evidence is Rubin (1977), where first-letter prompts at test raised recall of passages people had already learned. The other is Nelson and Archer (1972), on word lists, not prose. Many verse-memory apps offer a first-letter mode (for example, the Bible Memory App's type-the-first-letter mode). Calling it "the most common" mechanic is unsourced. Source: https://psychology.ecu.edu/wp-content/pv-uploads/sites/216/2019/03/Roediger-Karpicke-2006.pdf ; https://courseware.epfl.ch/assets/courseware/v1/fdde2f0aa590bf3b1324077a6bf1540c/asset-v1%3AEPFL%2BDEMO%2B2020%2Btype%40asset%2Bblock/Rowland2014-meta-analysis.pdf ; https://ifp.nyu.edu/?p=1511228 ; https://link.springer.com/article/10.1007/s10648-020-09572-8 ; https://www.frontiersin.org/articles/10.3389/fpsyg.2018.02412/full ; https://sim.ku.edu/sites/sim/files/files/Research/Research%20Brief-%20First%20Letter%20Mneumonic%20Strat.pdf ; https://fds.duke.edu/db/aas/pn/faculty/david.rubin/publications/253706 ; https://www.researchgate.net/publication/232418525_The_first_letter_mnemonic ; https://apps.apple.com/us/app/bible-memory-scripture-typer/id496790833 |
| 10 | corrected | Duolingo's streak evidence comes from company A/B tests and correlations in blog posts, a podcast and an SEC filing. None of it is peer-reviewed. The one-lesson streak change was made around late 2019 and reported on November 19, 2020. Its effects were relative changes: Day 14 retention up 3.3%, daily active learners up 1%, and the share of daily learners on a streak up 10.5% within 20 days (19% among new learners). Letting learners equip up to two Streak Freezes at once raised daily active learners by 0.38% (blog post, January 31, 2022). In Shuttleworth's podcast account, three freezes did no better than two. The same 2022 post says learners who reach a 7-day streak are 3.6 times more likely to complete their course. This is a correlation, and the post gives no method or baseline. The FY2025 10-K reports about 43 million DAUs on a 7+ day streak and about 15 million on a 365+ day streak as of December 31, 2025. These are point-in-time counts, while the 52.7 million is the average DAU for Q4 2025. Lowering the bar to a single exercise "moved not one bit" in DAUs, according to Duolingo's Jackson Shuttleworth on Lenny's Podcast (December 15, 2024). This comes from the transcript itself, not only a secondhand summary. Source: https://blog.duolingo.com/improving-the-streak ; https://blog.duolingo.com/how-duolingo-streak-builds-habit ; https://www.sec.gov/Archives/edgar/data/1562088/000162828026012494/duol-20251231.htm ; https://github.com/ChatPRD/lennys-podcast-transcripts/blob/main/episodes/jackson-shuttleworth/transcript.md ; https://www.youtube.com/watch?v=_CCwoQZH5hI |
| 11 | corrected | Strict streaks can backfire, and forgiving ones help. Silverman and Barasch (Journal of Consumer Research, vol. 49 no. 6, April 2023, online June 2022, 7 studies) found that a log showing an intact streak drives more later engagement than one showing a broken streak, even when the person's actual behavior was the same. The effect is weaker when people can repair a broken streak. Sharif and Shu (OBHDP vol. 163, 2021, online 2019) ran a step-goal field study with 273 people randomized. On the day after a missed goal, people hit their goal 55% of the time with 2 weekly skip days, 48% with 8 monthly skip days, 44% with an easy 5-of-7 goal and 37% with a strict 7-of-7 goal. The UCLA Anderson Review summary says 47% for the monthly group, but the paper says 0.48. The monthly group did not differ significantly from the easy goal. The gain appeared only when people actually used a skip. A 2023 Utrecht student thesis (Heidt) tried to replicate Sharif and Shu with a daily vegetarian-meal goal and found no significant effect, but it had only 28 participants (8, 9 and 11 per group), so it is weak evidence either way. The I am affirmations app does have a 2-star review (23 Oct 2026) that says "By reminding you to keep your streak, it gives you anxiety over something that ought not to matter." Streak anxiety is not the app's main App Store complaint, though. In the 450 most recent US reviews (10 May to 25 Oct 2026), 14 mention streaks and 4 of those are 1 or 2 stars. About 77 of the 111 one- and two-star reviews are about subscription, price, trial, charges or refunds. I am already offers streak freezes. Its streak complaints are mostly about false "you will lose your streak" notifications sent after the user had already opened the app that day. Source: https://anderson-review.ucla.edu/wp-content/uploads/2021/03/Sharif-Shu_EmergencyReserveFailure_OBHDP2019.pdf ; https://academic.oup.com/jcr/article-abstract/49/6/1095/6623414 ; https://udspace.udel.edu/handle/19716/34160 ; https://anderson-review.ucla.edu/emergency-reserves/ ; https://ideas.repec.org/a/eee/jobhdp/v163y2021icp17-29.html ; https://studenttheses.uu.nl/handle/20.500.12932/44466 ; https://itunes.apple.com/us/rss/customerreviews/page=1/id=874656917/sortBy=mostRecent/json |
| 12 | corrected | I found no general quote app that combines practice, gathering, a streak and a printed quote book, and none that verifies wording. That is not true of every app, though. The Bible Memory App (33,017 US ratings) already has all four in the scripture niche: spaced-repetition practice, custom verse collections, a streak (Insights screen, Aug 2025) and printed verse cards (May 2025). Its wording is exact because it comes from published translations.  Readwise has practice, gathering and a streak, but no printed book. Day One has gathering, a streak and a printed book ($19.99 for the first 50 color pages, then $0.10 a page), but no practice. Goodreads says its quotes "are added by the Goodreads community and are not verified by Goodreads."  Repeated quotes are a real complaint but a minor one: - Motivation: 6 of its 400 most recent US reviews (Apr to Oct 2026). The top complaint is billing, with about 92 reviews. - Readwise: 1 of 217 US reviews (Nov 2024).  Motivation has 1,076,819 US ratings and The Bible Memory App has 33,017, about 33x (iTunes Lookup API, 2026-10-26). That is one pair from different categories, so it only roughly suggests that active memorization is a smaller market. Source: https://apps.apple.com/us/app/bible-memory-scripture-typer/id496790833 |
