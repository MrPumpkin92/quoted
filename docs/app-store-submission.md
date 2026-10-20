# Quoted: from this repo to the App Store

The founder's checklist for the first release, in order. Each step says where in the repo the matching setting lives. Steps that need your own accounts (Apple, Supabase, an email provider, a website) cannot be done by an agent. Do TestFlight (step 11) before you submit for review.

Related: `docs/system-design.md` §7 (the daily report check) and §10 (founder steps), and `scripts/deploy-backend.sh`, which prints the Supabase dashboard checklist with direct links.

## 0. Accounts you need

- An Apple Developer Program membership (paid), signed in under Xcode > Settings > Accounts.
- The hosted Supabase project (`Config/Hosted.xcconfig` points at it).
- A domain you control, for the support address and the sending address of account email.
- An email provider that can send from that domain (Resend, Postmark or Amazon SES).
- Somewhere public to host the Privacy Policy and the support page. GitHub Pages is free (step 4).

## 1. Deploy the backend

1. Run `scripts/deploy-backend.sh`. It logs in, links the project, shows a dry run of the pending migrations, pushes them (it asks for the database password), deploys the `delete-account` Edge Function and runs the security advisors. At the end it prints the dashboard checklist.
   Push the migrations before any build from this tree reaches testers: the app writes the reminder order through `public.set_rotation` (migration `20261019070000_set_rotation`), and against a database without it every reminder add, remove or reorder fails.
2. Work through that checklist in the Supabase dashboard:
   1. **Custom SMTP (required).** Supabase's built-in email only reaches members of your Supabase team, about 2 messages an hour. Without custom SMTP, nobody else gets a confirmation link or a password-reset link ("Email address not authorized"). Verify your sending domain with the provider (SPF and DKIM records), then fill in host, port, user, password, sender name (`Quoted`) and sender address (for example `no-reply@yourdomain`) under Authentication > SMTP Settings.
   2. **Rate limit.** Custom SMTP starts at 30 emails an hour. Raise it under Authentication > Rate Limits.
   3. **Templates.** Reword "Confirm sign up" and "Reset password" so they name Quoted. Keep `{{ .ConfirmationURL }}` in both.
   4. **Redirect URL.** Authentication > URL Configuration > Redirect URLs: add `quoted://auth-callback`. Email confirmation and password reset both come back through it. A reset link opens the app on "Choose a new password".
   5. **"Confirm email".** Recommended on for release, and only after 1–4 work. Then test sign-up, the confirmation link, "Forgot password?" and the new-password screen end to end, with an address that is not on your Supabase team.
   6. **Security Advisor** shows no findings.
   7. **Publishable key.** If the project's publishable key changed, copy it into `Config/Hosted.xcconfig` (`SUPABASE_PUBLISHABLE_KEY`). Never put a secret key in the app.
3. Start the daily report check now (see step 12). The app tells users that reports are reviewed every day and acted on within 24 hours where possible.

## 2. Team, bundle ID and App Group

1. Open `Quoted.xcodeproj`. Under Signing & Capabilities, choose your Team for both the `Quoted` and `QuotedWidgets` targets (or set `DEVELOPMENT_TEAM` in `Config/Shared.xcconfig`). Signing is automatic.
2. Bundle IDs are `com.hwei.quoted` (app) and `com.hwei.quoted.widgets` (widget). The App Group is `group.com.hwei.quoted`. If `com.hwei` is not yours, change all of them together:
   - `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER` for all three targets), then run `xcodegen generate`.
   - `App/Quoted.entitlements` and `Widgets/QuotedWidgets.entitlements` (the App Group).
   - `Packages/QuotedKit/Sources/QuotedCore/Widget/AppGroupStore.swift` (`identifier`).
   - Optionally the background task ID `com.hwei.quoted.refresh`, in `App/Info.plist` (`BGTaskSchedulerPermittedIdentifiers`) and `App/Services/BackgroundRefresh.swift`. The two must match.
3. In the Apple Developer portal, Xcode's automatic signing registers the App IDs and the App Group on the first device build or archive.

## 3. Support address

The Release build carries a support address in Info.plist (`SupportEmail = $(SUPPORT_EMAIL)`). It drives Account > Contact support and the contact line at the end of the Privacy Policy, the Terms and the Community Guidelines (`TextPageView` fills in `{{SUPPORT_EMAIL}}`).

1. The support address is `hanningwei92@gmail.com`, set as `SUPPORT_EMAIL` in `Config/Shared.xcconfig`, so every configuration uses it. To ship a different address in the App Store build only, override it in `Config/Release.xcconfig`.
2. Use the same address in App Store Connect and on the hosted Support page (step 4).
3. The `Check release settings` build phase (`project.yml`, `preBuildScripts`) fails any Release build or archive while `SUPPORT_EMAIL` is empty or not an address, with "Set SUPPORT_EMAIL in Config/Release.xcconfig before archiving". It also fails if a legal page still carries a "Draft - review" banner. Debug builds skip it; with no address they hide the Contact support row and drop the contact sentences.
4. Answer support mail. Users write there to ask about their data, to appeal a block or ban, and to report something outside the app.

## 4. Legal pages: review, then publish

The bundled pages are `App/Resources/Legal/privacy.md`, `terms.md` and `community-guidelines.md`. They were rewritten on 2026-10-19 to match what the app and backend actually do: what is stored, the anonymous "Search the web" count (event name and hour, no account ID), what account deletion removes, how reports are kept, and the daily moderation check. They have not had a legal review.

**Before release:** have them reviewed (ideally by a lawyer for the countries you launch in). Whenever you change them, update the "Last updated" line in the file and in the hosted copy.

App Store Connect needs a public **Privacy Policy URL** (App Information) and a **Support URL** (each version). The hosted policy must match the one in the app. With GitHub Pages:

1. Create a new public repository, for example `quoted-site`. Do not publish this app repository.
2. Copy the three legal files into it with the support address filled in:
   ```sh
   for f in privacy terms community-guidelines; do
     sed "s/{{SUPPORT_EMAIL}}/support@yourdomain/g" App/Resources/Legal/$f.md > ../quoted-site/$f.md
   done
   ```
3. Add `support.md`: how to reach you (the support address), how to delete your account (Account > Delete account), how to report or block someone (the quote's "…" menu, or press and hold a request or friend), and that reports are reviewed daily.
4. Add an `index.md` that links to the four pages.
5. In the repository's Settings > Pages, deploy from the `main` branch, root folder. The pages appear at `https://<you>.github.io/quoted-site/privacy` and so on (a custom domain also works).
6. Use `…/privacy` as the Privacy Policy URL and `…/support` as the Support URL.

## 5. Create the app in App Store Connect

My Apps > + > New App: platform iOS, name "Quoted" (or what is free), primary language English (U.S.), bundle ID from step 2, a SKU of your choice, full access.

- **Category:** Lifestyle (matches `LSApplicationCategoryType` in `App/Info.plist`).
- **Content rights:** the app shows third-party content (quotes). The starter pack is public domain; every quote and its source is listed in `docs/starter-pack-sources.md`. Everything else is entered by users.
- **License agreement:** keep Apple's standard EULA. The in-app Terms say it applies.

## 6. App Privacy (the nutrition label)

Answer "Yes, we collect data". The label must match `App/PrivacyInfo.xcprivacy` (the widget's own manifest declares no collection). No data is used for tracking, and nothing is shared with data brokers or advertisers.

| App Store Connect type | What it is in Quoted | Purpose | Linked to the user | Tracking |
|---|---|---|---|---|
| Contact Info > Email Address | Sign-in email | App Functionality | Yes | No |
| Contact Info > Name | Optional display name, shown to other users | App Functionality | Yes | No |
| Contacts | The friends list, requests and blocks (the social graph) | App Functionality | Yes | No |
| User Content > Other User Content | Quotes, notes on shares, shared quotes, reports | App Functionality | Yes | No |
| Identifiers > User ID | Account ID and username | App Functionality | Yes | No |
| Usage Data > Product Interaction | Count of "Search the web" taps (event name and hour only) | Analytics | **No** | No |

Not collected: location, photos (saving a quote image to Photos is add-only and never leaves the iPhone), contacts from the address book, search terms, diagnostics, purchases, device IDs, advertising data. Reminder settings stay on the device. Support email arrives outside the app.

If any of this changes (a crash reporter, new analytics, a new field), update the manifest, the policy and this label together.

## 7. Age rating

Answer the questionnaire as follows:

- Content descriptions (violence, sexual content, profanity, drugs, horror, mature themes, medical, gambling, contests): **None**. The app ships no such content; quotes come from users and the public-domain starter pack.
- **Unrestricted web access: Yes.** "Search the web" opens Google in an in-app browser (`SFSafariViewController`), from which any site is reachable. Apple maps this capability to **16+** (Age ratings values and definitions, checked 2026-10-19). It is the founder's deliberate choice (`docs/decisions/2026-10-19-web-search-browser.md`). To lower the rating, switch the row to open the Safari app and answer No.
- **User-generated content: Yes.** Users write quotes and notes, pick a display name and share with friends. Report and Block exist on every shared quote, request and friend.
- **Messaging and chat: Yes.** A shared quote can carry a short note to an accepted friend.
- **Social media: No.** Apple defines it as a feed or discovery method that spreads content to many users (that would mean 13+). Quoted only sends a quote to chosen, accepted friends; there is no feed.
- **Expected result: 16+**, driven only by unrestricted web access. User-generated content and messaging do not raise the rating.
- Advertising, gambling, loot boxes, parental controls, age assurance: No.

The Terms require users to be at least 13, which fits the 16+ rating. If you later switch web search to the Safari app, the rating drops to 4+; then raise it to 13+ where App Store Connect lets you set a higher rating, to match the Terms.

## 8. Demo accounts for App Review

Everything in Quoted sits behind sign-in, and Report and Block only appear with friends and shares, so App Review needs a prepared account. The local seed scripts refuse the hosted project on purpose, so do this by hand with a TestFlight or Release build pointed at the hosted backend:

1. In the dashboard, Authentication > Users > Add user > Create new user: `review@yourdomain` with a strong password, "Auto Confirm User" ticked. Create a second one the same way, `review-friend@yourdomain`, and a third, `review-stranger@yourdomain`.
2. Sign in as `review@…`: pick the username `appreview`, add a few quotes from the starter pack and keep some in reminders.
3. Sign in as `review-friend@…`: pick a username and a display name, send a friend request to `appreview`. Sign back in as `review@…` and accept it. Sign in as the friend again and send `appreview` two quotes, one with a note.
4. Sign in as `review-stranger@…`, pick a username and send `appreview` a friend request. Leave it pending, so the reviewer sees a request they can report or block.
5. Sign in as `review@…` once more, check Friends shows the friend, the pending request and two shared quotes, then sign out.

App Store Connect > the version > App Review Information: sign-in required, user `review@yourdomain` and its password (never commit them), your contact details, and notes along these lines:

> Quoted keeps quotes the user saves and shows them as reminders and in widgets. An account is needed to sync the library and to share quotes with friends; it uses email and password only, with no third-party sign-in.
>
> Moderation (Guideline 1.2): in Friends > Shared with you, each quote's "…" menu has Report and Block, and swiping a quote left shows Delete, Block and Report. Press and hold a friend request or a friend for Report and Block. Blocked people are listed in Account > Blocked users. Reports are reviewed daily. The Terms and Community Guidelines are in Account > About and linked from Create account.
>
> Account deletion (5.1.1(v)): Account > Delete account. Please test it with a new account you create in the app rather than the demo account, which we need for future reviews.

If a reviewer deletes the demo account anyway, recreate it before the next submission.

## 9. Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` in `App/Info.plist`, so App Store Connect does not ask per build. Quoted uses only the encryption built into iOS (HTTPS, the Keychain) and no proprietary or non-standard cryptography, which is exempt.

## 10. Version, screenshots and listing

- **Version and build:** `MARKETING_VERSION` (1.0.0) and `CURRENT_PROJECT_VERSION` (1) in `Config/Shared.xcconfig`. Every upload needs a higher build number; bump the version for each release. Commit the change.
- **Screenshots:** iPhone 6.9" display is the one required size (1320 × 2868 portrait, from an iPhone 17 Pro Max simulator; App Store Connect scales them for smaller iPhones). The app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad screenshots. Debug builds launched with `-QuotedDemo` show consistent sample data with no backend: `xcrun simctl launch <udid> com.hwei.quoted -QuotedDemo`, then `xcrun simctl io <udid> screenshot shot.png`. Good subjects: the Library with the reminders card, a quote in the detail pager, Reminders, the Home Screen widget, Friends with Shared with you, and the share sheet. Use light mode and sample data only.
- **Listing:** description, keywords, promotional text, support URL and Privacy Policy URL (step 4), copyright, and "What's New" for later versions.

## 11. Archive, upload and TestFlight first

1. Check: Team set (step 2), `SUPPORT_EMAIL` set (step 3), version and build bumped (step 10), legal pages reviewed (step 4).
2. In Xcode choose the `Quoted` scheme and "Any iOS Device (arm64)", then Product > Archive. Archive always uses the Release configuration and the hosted backend. If the build stops with "Set SUPPORT_EMAIL in Config/Release.xcconfig before archiving", do step 3.
   From the command line instead: `xcodebuild -project Quoted.xcodeproj -scheme Quoted -configuration Release -destination 'generic/platform=iOS' -archivePath build/Quoted.xcarchive archive`, then upload the archive from Xcode's Organizer.
3. Organizer > the archive > Validate App, then Distribute App > App Store Connect > Upload.
4. **TestFlight first.** When the build finishes processing, add yourself as an internal tester and install it on a real iPhone. Check, against the hosted backend:
   - Create an account with an address that is not on your Supabase team: the confirmation email arrives (custom SMTP) and its link opens the app.
   - "Forgot password?": the email arrives, its link opens "Choose a new password", and the new password works.
   - Reminders arrive, the widget shows the latest reminder's quote, and Share as image offers Save Image (it asks for photo access once, add-only).
   - Friends: request, accept, share with a note, Save, Report, Block and swipe to delete in Shared with you.
   - Account shows Contact support with your address; the legal pages end with it too.
   - Delete account on a throwaway account.
5. Optional: external TestFlight testers (needs Beta App Review, which uses the same demo account and notes).

## 12. Submit, then keep it running

1. On the version page, pick the build, fill in the listing, App Privacy, age rating and App Review Information, and choose a release option (manual release is safest for 1.0). Submit for Review.
2. **Every day:** run the report check in the SQL editor (`select * from private.reports_to_review;`), act on each report, and mark it reviewed (`docs/system-design.md` §7). The app promises a daily review and action within 24 hours where possible. Consider the optional Database Webhook alert described there.
3. Read the support mailbox regularly.
4. Before each later release: bump the build (and version), repeat TestFlight, update the legal pages and the label if data use changed, and check the demo accounts still exist.
