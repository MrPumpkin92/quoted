# Practice: 5-second-test mockups

These frames are for Track A of the validation test in `docs/practice-and-quote-book-plan.md` §7. They are mockups only: none of this is in the app yet.

The frames use the Margin direction: New York serif for quotes, SF for UI, and the ink-blue accent `#2B44C9`. The test line is Hamlet's "This above all: to thine own self be true.", so its first-letter card reads **T a a: t t o s b t.**

| File | What it shows |
|---|---|
| `renders/01-lock-screen.png` | Lock Screen. A Quoted notification ("Finish the line", then the first letters) and the Lock Screen widget under the clock. |
| `renders/02-home-screen-widget.png` | Home Screen. The medium "Finish the line" widget, with today's Quoted widget beside it. |
| `renders/03-store-know-by-heart.png` | App Store 1, the main test image: "Know your favorite lines by heart." The card is mid-line, with two words typed and the rest still first letters. |
| `renders/04-store-library.png` | App Store 2: "Keep the words that move you." Library with the "3 lines to know by heart" card pinned at the top. |
| `renders/05-store-by-heart-count.png` | App Store 3: "A count that only goes up." The end of a session, with the By heart count, this week's days and today's three lines. |

Each PNG is 1320 × 2868, the App Store 6.9" size.

## Running the 5-second test

1. **Who:** 10 strangers who have never seen Quoted. Friends and family don't count, and your own answers are left out.
2. **Show:** put `03-store-know-by-heart.png` full screen on a phone, not a laptop. Show it for 5 seconds, then put the phone away. Don't explain anything first.
3. **Ask, in this order, and write down their exact words:**
   - "What does this app do?"
   - "Who do you think it's for?"
4. **Then:** show `01-lock-screen.png` for 5 seconds and ask "What is this notification asking you to do?"
5. **Score:** a person explains the idea back if they say the app helps you learn or remember quotes word for word. Any wording counts ("memorize", "learn by heart", "remember lines"). "Saves quotes" on its own does not count.
6. **Read the result** against plan §7: 6 or more out of 10 is a pass, and 3 or fewer is a fail.

Keep the order and the wording the same for every person. Screenshots 2 and 3 are for the reservation page and for later App Store listing tests. They are not part of the 5-second score.

| # | Where you met them | "What does this app do?" (exact words) | Notification answer | Explains the idea (Y/N) |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
| 9 | | | | |
| 10 | | | | |

## Choices the plan leaves open

- **The by-heart marker on a Library row.** Plan §4.3 says only "a small glyph". These mockups use a "By heart" chip, because a stranger can read it in 5 seconds.
- **The end-of-session screen.** Plan §5 puts the By heart count and the week dots "inside Practice" but draws no screen. Screenshot 3 is one way to lay it out: the count, the week, then each line's box and when it comes back.

## Changing the frames

The sources are in `src/`. Each frame is plain HTML at 440 × 956 pt, and `src/shared.css` holds the colors and type from `App/Design/Theme.swift` and `Typography.swift`. After an edit, re-render all five:

```bash
./render.sh
```

It needs Google Chrome on a Mac. The quote serif loads from the macOS system font file, so the font is not copied into the repo.
