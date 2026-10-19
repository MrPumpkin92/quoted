# Decision: web search opens Google in an in-app browser (2026-10-19)

## Decision (founder, 2026-10-19)

The Search tab's last row, "Search the web for '<term>' quotes", opens the Google results page **inside Quoted** in an `SFSafariViewController` (`SafariView`, presented as `SheetRoute.safari(URL)`). The caption reads "Opens Google. Copy a quote, then tap Paste in Add." The tap is logged (`web_search_tap`, no term and no user stored). The `PasteButton` in Add brings the copied quote back without a paste prompt.

This keeps the flow from `2026-10-18-in-app-search-council.md` (Option A).

## Alternative considered and rejected

The engineering review (`docs/reviews/2026-10-19-engineering-review.json`, `appstore-age-rating-unrestricted-web`) pointed out a problem. An in-app browser on Google with no domain limits lets the user reach any site without leaving Quoted, and App Store Connect's age-rating questionnaire treats that as **Unrestricted Web Access**. The fix agents briefly switched the row to open the Safari app instead (`openURL`), which avoids that answer.

The founder chose to keep the in-app browser for the smoother flow: no app switch, and copy, close, paste. The fix was reverted.

## Consequences

- **App Store Connect age rating:** answer **Unrestricted Web Access = Yes**. This gives Quoted the highest age rating in the questionnaire. Answering "No" would risk a 2.3.6 rejection (inaccurate age rating). Also answer **User-Generated Content = Yes** and **Messaging = Yes** (friend sharing with notes). See `docs/app-store-submission.md` §7.
- **Terms of Use:** they state a minimum age of 13. The store rating describes content, not legal capacity, so this is not a contradiction. Review the wording with the legal pass anyway.
- **Reversal:** to switch to the Safari app later, replace `router.present(.safari(url))` in `SearchView.searchWeb` with `openURL(url)`, change the caption, and re-answer the questionnaire with Unrestricted Web Access = No.
