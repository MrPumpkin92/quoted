# Decision: practice, streak and quote book (LLM Council, 2026-10-26)

## Status

Recommended by the council, not yet approved by the founder. The research it rests on is `docs/research/2026-10-26-practice-streak-quote-book.md`. The implementation plan that applies it is `docs/practice-and-quote-book-plan.md`.

**Correction by the author:** the verdict below says to "ship the uncommitted catalog-mix work as build 5". That is wrong:

- build 5 is already on TestFlight;

- the uncommitted work is build 5.1, the Add-quotes dead-end fixes;

- the catalog mix ("new quotes in Reminders", `docs/new-quotes-in-reminders.md`) is designed but not built.

The plan uses the real sequence.

---

## Chairman verdict

## Where the Council Agrees

- **This is a feature set inside Quoted, not a new platform or business.** The realistic outcome is a small, durable indie app. The base case is low thousands to low tens of thousands of dollars a year. The limit is distribution, not demand: about 83% of new subscription apps never reach $1K a month.
- **No streak tab.** All five advisors took the streak off its own tab. The Contrarian and the First Principles Thinker cut it. The Expansionist and the Outsider replaced it with a "by heart" count. The Executor reduced it to a counter on the Practice screen.
- **Practice is the piece to bet on.** It has the strongest evidence: retrieval beats rereading, and feedback after each attempt roughly doubles the effect. Nobody owns it for secular quotes.
- **Gather is already built.** It stays free forever, along with Reminders, widgets and sharing.
- **The quote book starts as an on-device PDF.** Print is cut for now. It brings copyright, vendor and privacy risk for users who don't exist yet.
- **Every line carries a label, "Verified" or "Yours".** Practice never edits a quote.
- **Test before writing code, and add no analytics SDK.**

## Where the Council Clashes

1. **Build now, or only after strangers commit?** The Executor runs the friendly test, then builds on a 7-week calendar. The Contrarian builds nothing until strangers reserve. **The Contrarian wins on the gate:** 8 friendly testers reporting on themselves during a novelty week cannot fail the test. **The Executor wins on housekeeping:** finish the uncommitted catalog-mix work already in the tree, ship it as build 5, and freeze features. It fixes the only complaint testers actually made.
2. **What role does the book play?** The Expansionist calls it the growth engine and wants it to lead. The Outsider and the reviewers say a book means nothing with 3 quotes and only matters around day 60. **Ruling:** Practice comes first, because it builds the library the book needs. The book is tested now, on Day 8. If it pulls harder than Practice, it leads. The two link up through the Expansionist's loop: a line you know by heart earns a place in the book's "Known by heart" section.
3. **What counts as a streak day?** The Executor says one practice. The Contrarian says that is the Duolingo change that moved nothing [83]. **Ruling:** the question goes away because v1 has no streak that can break. Note also that [83] showed no effect on daily users, not harm. The evidence of harm is about broken streaks and nagging.
4. **Set a price now or later?** **Ruling:** name a price ($34.99 a year) for the reservation test, because a reservation without a price measures nothing. Do no StoreKit work until the gates pass. Measuring trial conversion does not need an SDK: App Store Connect's subscription reports cover it.
5. **Keep the streak arm in the test?** **Ruling:** drop it. Eight testers split two ways leaves 4 per arm, which proves nothing.
6. **Who is the beachhead?** The research and the Executor say Stoic readers. The Contrarian says Stoics conflict with the verified seal. The Outsider says whoever reacts to "finish the line". **Ruling:** define the segment by what people do: they have saved 10 or more lines and tried to learn one by heart in the past year. Recruit in Stoic communities, but test English-literature and poetry readers alongside them. Their lines are in the original English, so the seal holds without a translation caveat.

## Blind Spots the Council Caught

- **The translation conflict is real, and the repo confirms it.** `docs/starter-pack-sources.md` uses George Long's translation for Marcus Aurelius and Epictetus ("If thou art pained…") and Gummere's for Seneca. It also records that popular paraphrases were swapped for the translation's real wording. Word-for-word practice would show a Hays reader that gap every day.
  - **Fix:** the seal means "checked against the named edition", and the edition is shown on every line. The Outsider is right that the citation is the proof.
  - Users' own lines are practised exactly as they saved them. Quoted never "corrects" them toward the catalog version.
- **Nobody said how a recall attempt is graded.** **Decision:** the user types only the first letter of each word, which is the Bible Memory App method. It is fast and objective, and it ignores punctuation, capitals and translation spacing. A wrong letter shows the right word in place. No speech grading, which is the most complained-about mechanic in Verses.
- **Widgets cannot take typed input.** The widget and the notification show the first-letter cue, and a tap opens the card in the app.
- **Empty libraries (the cold start).** This is partly solved already: onboarding adds starter-pack lines, and the catalog mix adds more verified lines. Scanning a book page with Apple's Live Text adds no dependency (check the VisionKit API in the SDK before using it). Build it only if test libraries stay small.
- **Anonymous accounts.** Today an account lives on one iPhone (`docs/decisions/2026-10-21-v1-launch-decisions.md`). A by-heart count and a book raise what a user loses with a lost phone. Sign in with Apple should ship before Practice reaches the App Store.
- **A proposal for this already exists.** Section 5.2 of `docs/quote-game.md` already specifies Recall:
  - Leitner boxes at 1, 3, 7, 14 and 30 days.
  - "Known by heart" for a line that clears the last box.
  - An opt-in "Finish the line" widget.
  - Its section 13 says to ship Recall first if content is slow.

  Practice is Recall, cut down. The Verbatim Daily needs 2,190 puzzle slots a year and stays parked. Its rule carries over: "Nothing is for sale: no loot boxes, no paid hints, no paid streak repairs."
- **"User feedback … for me" means one person.** If a tester wrote it, call them for 30 minutes. If it is the founder, the founder is one data point and is left out of the test results.
- **Readwise is the incumbent.** Don't fight it on highlights. Quoted's job is knowing lines word for word. Pasting a plain-text Kindle or Readwise export can come later.

## The Recommendation

**Verdict:** viable as a feature set, aimed at a small, durable indie outcome. It is not viable as a new platform. The beachhead is people who save lines and have tried to learn one by heart in the past year: Stoic readers first, with English-literature and poetry readers tested alongside them.

**The four pieces**

| Piece | Decision | One-line spec |
|---|---|---|
| Practice | Build first | Recall from `quote-game.md` §5.2 cut to one mode: at most 3 due lines a day; type the first letter of each word in 3 stages (text shown, first letters only, from memory); the full line shown after every attempt; Leitner boxes at 1/3/7/14/30 days; opened from a "3 lines due" card pinned in Library and from the widget, with no new tab. |
| Gather | Keep, free | Ship the catalog mix (build 5) now. Add page-scan capture only if test libraries stay under about 10 lines. |
| Streak tab | Cut | Inside Practice, show a "By heart" count that only goes up and a row of dots for this week. Nothing resets, and nothing sends a notification. |
| Quote book | Build third | An on-device PDF of saved lines, designed as a gift: title page, dedication, a "Known by heart" section, each line with its source and its Verified or Yours label, and a small "Made with Quoted" colophon. Print and group books are parked. |

**Order:**
0. Ship build 5, then freeze features.
1. Run the test below.
2. Build Practice with the by-heart count.
3. Ship Sign in with Apple before Practice goes public.
4. Build the PDF book.
5. Add StoreKit.

Parked: print, group books, a public quote-checker page, the Verbatim Daily, and a Practice tab.

**Rules against homework and streak shame**
1. Each session takes under a minute and covers at most 3 lines. Overdue lines roll forward under the cap, so they never pile up.
2. The correct line appears after every attempt. A miss reads "Not yet", never "Wrong".
3. Lines from Reminders are offered first. The user can leave any line out.
4. Nothing on screen can be lost or reset. If a breakable streak ever ships with the Verbatim Daily, it uses the proposal's Bookmarks (streak freezes) and counts days finished, not days won.
5. No notification ever mentions a streak or a missed day. Recall cards appear in Reminders only through an opt-in "Quiz me sometimes".
6. The UI says "know it by heart", not "practice" or "study".
7. Hints, repairs and progress are never for sale.

**Money**
- **Free forever:** Gather, Reminders, widgets, friends, the starter pack, and Practice on up to 5 lines with the full mechanism.
- **Paid tier:** unlimited Practice lines, extra book layouts, and future verified catalog packs.
  - $34.99 a year with a 14-day trial and an in-app reminder 2 days before the trial ends.
  - A lifetime option at about $79.99, offered as a trust signal and tested.
- **Build:** StoreKit 2 directly. RevenueCat would be a second dependency, which needs the founder's approval. The server verifies purchases through App Store Server Notifications sent to an Edge Function.

**Validation test: 2 weeks, no new code.** Write the thresholds into `docs/decisions/` before Day 0.

- **Before Day 0**
  - Collect 20 Stoic lines that strangers post and note which translation each uses.
  - The founder runs the practice cards on themselves, and those results are left out.
- **Track A: strangers (this track can fail)**
  - **5-second test.** Show 10 strangers three sets of App Store screenshots. Pass: 6 or more explain the first-letter idea back. Fail: 3 or fewer.
  - **Reservation page.** Post it to r/Stoicism, r/commonplacebook and one poetry or literature community, within each one's self-promotion rules. It shows the finish-the-line card and offers to reserve at $34.99 a year with no charge. Count visits from server logs, with no tracking script.
    - Pass: 3% or more of at least 300 unique visitors reserve.
    - Stop: under 1%.
    - Under 300 visitors in 2 weeks means there is no channel yet. Fix distribution before building features.
- **Track B: behaviour**
  - At least 8 people finish, including at least 3 strangers recruited through Track A.
  - Each tester gets 3 first-letter practice cards in Reminders, plus 1 control line that stays in normal Reminders.
  - They practise daily in week 1. In week 2, a line drops to every other day once it has been recalled perfectly twice.
  - Daily check-in: practised (yes or no), seconds spent, and "felt like homework" on a 1 to 5 scale.
  - Score words recalled from memory on Day 0 and Day 14.
  - Pass:
    - Half or more practise on 5 or more of 7 days in week 1.
    - For most testers, practised lines gain 25 or more percentage points over the control line.
    - No more than 1 in 4 rate homework at 4 or 5.
  - Fail: fewer than a third practise on 5 or more days, or practised lines gain no more than the control.
- **Track C: the book**
  - On Day 8, send each tester a hand-made PDF built from a list they send.
  - On Day 12, ask "Who would you make one for?" and offer a no-payment reservation.
  - Pass: a third or more share it, ask for edits, or name a recipient and reserve. Fail: none do.
- **Decisions**
  - A and B pass: build in the order above.
  - B fails and C passes: the book leads, and Practice shrinks to a reveal card on the widget.
  - A fails: build no new features, whatever B and C show. Spend the next month finding a channel.
  - Half or more of the 20 Stoic lines are in-copyright translations: lead the Stoic pitch with "know your lines by heart", not "verified".

## The One Thing to Do First

This week, before any code: show 10 strangers a lock-screen mockup of the first-letter card ("T a a: t t o s b t", with "Finish the line" under it) for 5 seconds, and ask them what the app does. It costs an afternoon and it can fail. It also decides whether Practice is the headline, or whether the book or the catalog should lead.

---

## Advisor responses

### The Contrarian

**Fatal flaw: the verified brand and the Stoic beachhead work against each other.** Most Stoic readers know Marcus Aurelius from Hays, Waterfield or The Daily Stoic, and all of those translations are still in copyright. The seal rests on public-domain translations such as Long and Gummere. Verbatim practice shows that mismatch in every session. Users either drill wording that isn't the line they love, or drill their own Hays line, where the seal means nothing. Before anything else, collect 20 Stoic lines that strangers actually quote and check which translation they use.

**The research argues against its own "go".** The base case is $2.4K to $14.5K a year, 83% of apps never reach $1K MRR, and no channel is named. Four new features don't fix distribution. The honest verdict is: no build until a channel brings in strangers.

**The streak copies the pattern Duolingo found had no effect.** "Under a minute, and one practice counts as a day" is the trivial daily unit that moved DAU zero [83]. Cut the streak tab. At most, show a weekly count inside Practice.

**Practice has a cold-start problem.** It only runs on quotes users typed in themselves. Capture takes about 30 minutes a book (P4), and there is no import. Testers complained about seeing the same 5 quotes, which points to tiny libraries and a wish for variety. That is a passive want, not a wish to recall. The headline mechanism, first-letter cueing for verbatim text, also has no controlled study behind it.

**Anonymous accounts undercut "a lasting home".** If the streak and the book vanish on reinstall, that is the P6 data-loss complaint built in from day one.

**The validation test can't fail.** It uses friendly testers, about 8 people, self-reporting, during a novelty week, with the founder scoring by hand. Add a test that strangers can fail: a landing page posted to r/Stoicism and r/commonplacebook that offers Practice with a reservation at $34.99 a year. If under 1% of 500+ visitors reserve, stop.

**Order:**
1. Fix variety in Reminders first. It is the only complaint testers actually made.
2. Build Practice only if strangers reserve.
3. Ship the PDF book as the sharing loop.
4. Cut the streak tab and print.

**Pricing:** don't set a price until you can measure trial conversion. With no analytics, you can't.

### The First Principles Thinker

The founder listed four features, but underneath them is one job: when you need a line you saved, you have it word for word. Gather already does the saving. Judge every other piece by whether it turns a saved line into a line you know.

**The question is partly wrong.** Desk research cannot answer "is this viable for this market". About 83% of new subscription apps never reach $1K a month in two years, and distribution is usually why, not lack of demand. The real unknown is narrower: will one person outside your circle practise recall instead of rereading for 7 days? Pick the beachhead by what people do, not who they say they are: people who tried to learn a line by heart in the past year.

**Reframes:**
- Testers complain that the same 5 quotes repeat. That is only a flaw in a passive feed. In practice, repetition is how you learn. Practice turns the complaint into the product.
- Exact wording matters more when you memorize a line than when you only read it. Practising a misquote fixes the error in memory. Mark quotes users add as "yours" and practise them as typed.
- A streak counts days, but the result that matters is lines known. Cut the streak tab. Show a "lines you know by heart" count that only goes up, plus a quiet week view. Nothing resets, so there is nothing to feel bad about.
- "My own quote book" has two possible meanings: a book of lines you saved, or lines you wrote yourself. Ask which. If it is lines you wrote, it does not fit "verified" and should be cut.
- The book is the only piece that leaves the phone. Treat it as a way to reach new users first and a way to earn money second.

**Order:** Build Practice first: first letters, then blanks, then the full line, with the correct text shown after every attempt, a capped daily set, and the known-lines count inside it. Then a PDF book. Cut the streak tab, print, the "platform" framing and any further social features.

**Money:** Gathering quotes stays free. Charge for what costs you work or produces an object: practice beyond a few lines, verified catalog packs, and the book. Set the price after the test, not before.

**Test:** Drop the streak arm, because 8 testers split two ways leaves 4 per arm. Run it for one week: 3 first-letter reminder cards plus 1 control quote, recall scored on day 0 and day 7, and practice days counted. On day 8, send each tester a PDF book and count shares. Those two numbers decide the build.

### The Expansionist

**The upside: the quote book is how Quoted gets found. Treat it as more than the fourth feature.**

The research says distribution is the biggest risk, then puts the book third in the build order. Flip that. People send a finished book on purpose: for a graduation, a wedding, a eulogy or a father's birthday. Day One shows people pay for print. Nobody owns "a curated book of lines for someone you love." A PDF with a line on the last page reading "Made with Quoted, every catalog line verified" is the cheapest way a solo founder will ever get new users.

1. **Viable?** Yes. If the book travels, the ceiling is higher than "a feature set." Start with Stoic readers. Watch for a second segment that may be more ready to pay: people buying a gift, who may never practise.
2. **Build order**
   - Practice comes first, because it keeps users coming back.
   - Replace the streak tab with a **Repertoire** tab: the lines you know by heart, a count that can only grow. Keep a forgiving weekly rhythm underneath it.
   - Second: the book as an on-device PDF, designed as a gift from the start.
   - Third: print, limited to public-domain verified lines. That keeps the copyright risk low and fits the brand.
   - Later bet: group books, where wedding guests or a class each add a line. Every contributor is a likely install.
3. **No homework:** practice should feel like collecting, not studying. A line earns its place in the book once you know it by heart. You learn it, it goes in the book, and the book goes to someone. That links Practice and the book into one loop.
4. **Money:**
   - Freemium at $34.99 a year for deeper Practice and more book layouts.
   - Print and gift copies as one-off purchases. They avoid the subscription billing that dominates complaints in this category.
   - A lifetime tier as a trust signal.
5. **Validation:** keep the 2-week test and add a gift arm. On Day 12, ask "who would you make this for?" and offer to reserve a gift copy. Count named recipients and reservations. If gift intent beats buying for themselves, the book leads the roadmap and the launch story.

**Park, don't build:** a public "is this quote real?" checker built on the verified catalog. Misattribution is a steady complaint. A checker page would get shared, rank in search and strengthen the seal.

### The Outsider

On the App Store, Quoted sits between Motivation, I am and a handful of Stoic apps with flame icons. If the first screenshot says "daily quotes and streaks," I scroll past. I already have that and I'm tired of it. A lock screen showing "T a a: t t o s b t" with "Finish the line" underneath would make me stop. I've never seen that. It's a puzzle, it's about me, and I understand it in two seconds. That first-letter card is the product, so lead with it.

What a stranger won't get:
- **"Verified."** I don't know misattribution is a problem, so a seal looks like a blue checkmark. Show the source instead: "Hamlet, Act 1, Scene 3." The citation is the proof.
- **"Practice."** It sounds like homework. Say "know it by heart."
- **Four tabs on first launch.** I have zero quotes. Give me the starter pack and one card to try.
- **A streak tab.** My phone already has six flames. Put a quiet count on the practice screen, with no tab of its own.
- **A quote book.** With three quotes, a book means nothing to me. It matters around day 60, and it matters most to the person who receives it. A friend's shared book is how I'd find you, so treat it as your ad, not a tab.

**Build order, as an outsider sees it:**
1. The first-letter card on the widget and lock screen.
2. Tap the card to practise.
3. A book export people can send.

**Pricing:** if a paywall appears before I've finished one line, I'll assume this is another Monkey Taps app and delete it. Keep saving, reminders and a taste of practice free. Charge for deeper practice and the book, and state the renewal date plainly.

**Beachhead:** whoever reacts to "finish the line." My guess is Stoic readers, but the screenshots will tell you.

**Test before coding:** show 10 strangers (not testers) three sets of App Store screenshots: "verified daily quotes," "know your lines by heart" with the first-letter widget, and "your quote book." Give them 5 seconds per set, then ask what the app does and whether they'd download it. If they can't explain the first-letter idea back to you, the practice pitch has failed, and you haven't written any code yet.

### The Executor

**Monday morning: write no new code.** Two weeks of feature work are still uncommitted in the tree (Library, Reminders, Search, Route). That catalog-mix work is the fix for the "same 5 quotes" complaint. Finish it, ship it as build 5, then freeze the feature list until the test results are in.

**1. Viability.** Viable as a feature set, not as a new business. The first users to target are Stoic and self-improvement readers. Distribution is what kills apps like this, so pick one channel this week (r/Stoicism or r/commonplacebook) and recruit 2 or more testers from outside your circle there. If you can't find 8 people to finish the test, you've learned the most important thing for free.

**2. Order and cuts.** Gather already exists. Build in this order:
- Practice: fixed intervals of 1, 2, 4, 7 and 14 days. No SRS algorithm. Plain text only, so it never touches `body_format` runs.
- Streak: a counter on the Practice screen, not its own tab. One new tab at most.
- Quote book: an on-device PDF made with `ImageRenderer`.

Cut print entirely: it needs a copyright check, a print vendor and a privacy review, and is weeks of risk for nobody yet. Practice state goes in one new table with RLS and a pgTAP test, and the server works out the streak from it.

**3. Avoiding homework and shame.** Each session takes under a minute and covers at most 3 quotes. Show the correct line after every attempt. One real practice counts as a day, and each week includes one skip. In v1 the streak sends no notifications at all. That removes the false "you'll lose your streak" bug before it can exist. Practice never edits a quote. Every card shows either a "Verified" or a "Yours" label.

**4. Money.** No StoreKit work until the test says go. After that:
- Use StoreKit 2 directly. RevenueCat would be a second dependency, which the project rules don't allow without asking.
- Keep Gather and sharing free. Charge for Practice beyond 3 quotes and for the PDF book.
- Price at $34.99 a year with a 14-day trial, and send a reminder before the trial ends.

**5. Validation.** Run section 11.4 as written. Practice cards are first-letter Reminders. Split testers into a streak arm and a no-streak arm, send the PDF book on Day 8, and on Day 12 ask people to reserve a printed copy without taking payment. Commit the go/no-go thresholds in `docs/decisions/` before Day 0 so you can't move them later.

**Calendar:**
- Mon: build 5 ships and the screener goes out.
- Wed: Day 0 of the test.
- Week 3: decide.
- Weeks 3 to 5: Practice.
- Week 6: streak.
- Week 7: PDF book.

## Peer reviews (anonymized; Response A = The First Principles Thinker; Response B = The Executor; Response C = The Expansionist; Response D = The Contrarian; Response E = The Outsider)

### Reviewer 1

1. **Strongest: D.** It is the only response that finds a flaw that could sink the plan. Stoic readers mostly quote copyrighted translations such as Hays, but the seal rests on public-domain ones. Every verbatim practice session would expose that mismatch. D also catches the cold-start problem: practice needs a library, and capture is slow. And it replaces a test that cannot fail with one strangers can fail. E's 5-second screenshot test pairs well with it. It is the cheapest stranger test available and needs no code.

2. **Biggest blind spot: C.** It makes the book the growth engine but ignores what E points out: a book means nothing with 3 quotes, and the value comes around day 60. C also wants print and group books, which brings in the copyright and vendor risk D and B flagged. Its gift buyers "who may never practise" break its own learn-then-book loop. B commits to a 7-week calendar and a $34.99 price before any data, which is a smaller version of the same mistake.

3. **What all five missed: how recall gets checked.** Typing a line word for word is homework. Self-grading turns "lines known" (A, C) into a vanity number. iOS widgets cannot take text input, so E's lock-screen "finish the line" can only reveal the answer. Also, the founder said "for me". Nobody suggested the founder use Practice daily for a week first.

### Reviewer 2

**1. Strongest: D.** It is the only response that finds a flaw that could sink the plan before any code is written. The verified seal rests on public-domain translations (Long, Gummere). Most Stoic readers know the copyrighted ones (Hays, Waterfield, The Daily Stoic). Word-for-word practice would show that mismatch in every session. D also shows the proposed test cannot fail: about 8 friendly testers, self-reported results, a novelty week and founder scoring. It replaces it with a stranger-facing test that has a kill threshold. Runner-up is E. Its 5-second screenshot test with strangers is the cheapest test that can actually fail, and "show the citation, not a seal" is the sharpest positioning idea.

**2. Biggest blind spot: B.** It schedules Practice, the streak and the book for weeks 3 to 7 and sets a $34.99 price, all on a friendly-tester test. It never questions the Stoic beachhead and recruits only 2 testers from outside the founder's circle. That is careful engineering planning applied to a premise nobody has checked. C has a smaller one: a gift book needs a large library, and D's cold-start point means few users will have one.

**3. What all five missed: how to fill an empty library, and the incumbent.** Practice needs saved lines. Nobody proposed easier capture, such as photographing a book page with Apple's built-in text recognition (no new dependency) or importing Kindle highlights. Nobody asked why a Stoic reader who already uses Readwise, which imports highlights and runs a daily review, would switch to Quoted.

### Reviewer 3

1. Strongest is D. It found the flaw that changes the decision. The seal rests on public-domain translations (Long, Gummere), but Stoic readers quote Hays or The Daily Stoic. Verbatim practice therefore either drills wording they don't recognise or makes the seal irrelevant. D also saw that 8 friendly, self-reporting testers can't fail the test. A comes second: it replaces the streak with "lines known" and asks what "my own quote book" means.

2. The biggest blind spot is C's. It makes the book the growth engine, and possibly the lead of the roadmap. But a book needs a full library, and E says it only matters around day 60. Cold start is also unsolved (D). Gift buyers who never practise pull away from the practice core. D has a smaller blind spot: its stranger test assumes 500+ visitors with no channel, and it uses $34.99 while saying not to set a price yet.

3. All five missed that the request reads as feedback from one user, not a tested plan. The cheapest test is a 30-minute call with that person. Ask what they use now, what "practice" and "streak" mean to them, and whether they would pay. They also missed that widgets can't take typed input. E's lock-screen "finish the line" can only reveal the answer, and the user grades themselves.

### Reviewer 4

1. **Strongest: D.** It is the only response that finds a contradiction inside the plan. Most Stoic readers quote translations that are still in copyright, such as Hays and Waterfield. The seal rests on public-domain translations (Long, Gummere). Verbatim practice would expose that mismatch in every session. D also names the cold-start problem and adds a test that strangers can fail. A comes a close second. It reframes repetition as learning and drops the streak arm, which 8 testers cannot power.

2. **Biggest blind spot: B.** It plans seven weeks of building, a streak and a $34.99 price based on a friendly test with 8 people. There are no analytics to measure trial conversion. Its rule that one practice counts as a day is the trivial daily unit D cites as having no effect at Duolingo. C's gift and print loop is also unproven, but C at least proposes measuring it.

3. **All five missed three things.**
   - **Capture.** Readwise works because highlights arrive automatically. D notes that Quoted has no import, but nobody fixes it. Without one, Practice has nothing to work on. Scanning a book page with VisionKit Live Text, or pasting a Kindle export, needs no new dependency and should come before Practice.
   - **Grading.** No one said how a recall attempt is scored. It is unclear how punctuation, capitals, translation variants or spoken recitation would count.
   - **"For me."** No one asked whether that phrase means the founder is the target user.

### Reviewer 5

**1. Strongest: D.** It is the only response that finds a problem that could sink the plan. Stoic readers love the in-copyright translations (Hays, Waterfield), but the verified seal rests on public-domain ones. Word-for-word practice would show that gap in every session. D also notices the cold-start problem: practice needs a library, and capture is slow. And it swaps a friendly test that can't fail for a reservation test that strangers can fail. E comes second, with the cheapest test and a first-letter widget that reuses code already built.

**2. Biggest blind spot: B.** It fixes $34.99 a year and a 7-week build calendar, streak included, before anyone has run a test that strangers can fail. Its streak rules ("under a minute, and one practice counts as a day") repeat the Duolingo pattern that moved nothing [83].

**3. What all five missed:**
- The prompt is labelled "User feedback" and says "for me". It reads as one tester's wish, not the founder's vision. Interview that person first: they are n=1.
- No response checked against `docs/quote-game.md` (untracked, dated 2026-10-24). That proposal already specifies "Recall": a memory game on your own Library, plus a verified daily puzzle that could solve both cold-start and distribution. The council should reconcile with it, not start over.
