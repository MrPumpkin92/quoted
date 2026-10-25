# Quoted: from this repo to the App Store

The founder's checklist for the first release, in order. Each step says where in the repo the matching setting lives. Steps that need your own accounts (Apple, Supabase, a website, and an email provider once email sign-in returns) cannot be done by an agent. Do TestFlight (step 11) before you submit for review.

Related: `docs/system-design.md` §7 (the daily report check) and §10 (founder steps), and `scripts/deploy-backend.sh`, which prints the Supabase dashboard checklist with direct links.

## 0. Accounts you need

- An Apple Developer Program membership (paid), signed in under Xcode > Settings > Accounts.
- The hosted Supabase project (`Config/Hosted.xcconfig` points at it).
- A support mailbox you read (step 3).
- A domain and an email provider are optional for now. Accounts are anonymous (`docs/decisions/2026-10-20-anonymous-accounts.md`), so the app sends no account email; a domain is only useful for a support address on it. When email sign-in returns you need both: a domain you control for the sending address, and a provider that can send from it (Resend, Postmark or Amazon SES).
- Somewhere public to host the Privacy Policy and the support page. GitHub Pages is free (step 4).

## 1. Deploy the backend

1. Run `scripts/deploy-backend.sh`. It logs in, links the project, shows a dry run of the pending migrations, pushes them (it asks for the database password), deploys the `delete-account` Edge Function and runs the security advisors. At the end it prints the dashboard checklist.
   Push the migrations before any build from this tree reaches testers: the app writes the reminder order through `public.set_rotation` (migration `20261019070000_set_rotation`), and against a database without it every reminder add, remove or reorder fails.
2. Work through that checklist in the Supabase dashboard:
   1. **Anonymous sign-ins (required).** Authentication > Sign In / Providers: turn on **Allow anonymous sign-ins**. The app creates every account this way; without it each new install stops on the launch screen with "Quoted can't create your account right now: anonymous sign-ins are turned off on the server." Then check the limit for anonymous sign-ins under Authentication > Rate Limits: 30 an hour per IP by default, shared by every tester on one network.

   Steps 2–6 are only needed when email sign-in returns (`AccountMode.emailPassword`). Skip them while accounts are anonymous.

   2. **Custom SMTP (only when email sign-in returns; then required).** Supabase's built-in email only reaches members of your Supabase team, about 2 messages an hour. Without custom SMTP, nobody else gets a confirmation link or a password-reset link ("Email address not authorized"). Verify your sending domain with the provider (SPF and DKIM records), then fill in host, port, user, password, sender name (`Quoted`) and sender address (for example `no-reply@yourdomain`) under Authentication > SMTP Settings.
   3. **Rate limit for email (only when email sign-in returns).** Custom SMTP starts at 30 emails an hour. Raise it under Authentication > Rate Limits.
   4. **Templates (only when email sign-in returns).** Reword "Confirm sign up" and "Reset password" so they name Quoted. Keep `{{ .ConfirmationURL }}` in both.
   5. **URL Configuration (only when email sign-in returns).** Authentication > URL Configuration: set Site URL to `quoted://auth-callback` (it starts as `http://localhost:3000`), and under Redirect URLs add `quoted://auth-callback`, exactly as written. Email confirmation and password reset both come back through it. A reset link opens the app on "Choose a new password". If either setting is missing, Auth replaces the app's redirect with the Site URL and the links open localhost. To check, request a new email, long-press its button in Mail and copy the link: it must end in `redirect_to=quoted://auth-callback`. Links in emails sent before the change still show the old redirect, so check a new one.
   6. **"Confirm email" (only when email sign-in returns).** Recommended on for release, and only after 2–5 work. Then test sign-up, the confirmation link, "Forgot password?" and the new-password screen end to end, with an address that is not on your Supabase team. Open each link within 5 minutes of requesting it: after that the app can't finish the sign-in from the link (a confirmed sign-up can still sign in with its password).
   7. **Security Advisor** (Advisors > Security Advisor). Once anonymous sign-ins are on, it lists the INFO entry "Anonymous sign-ins enabled" (`0012_auth_allow_anonymous_sign_ins`), because the policies deliberately don't check `is_anonymous`. That entry is expected and accepted: `supabase/tests/database/10_anonymous_user.test.sql` proves an anonymous user gets exactly the access of an email user. Don't add `is_anonymous` checks or turn anonymous sign-ins off to clear it. Fix any other finding.
   8. **Publishable key.** If the project's publishable key changed, copy it into `Config/Hosted.xcconfig` (`SUPABASE_PUBLISHABLE_KEY`). Never put a secret key in the app.
3. Start the daily report check now (see step 12). The app tells users that reports are reviewed every day and acted on within 24 hours where possible.

## 2. Team, bundle ID and App Group

1. Open `Quoted.xcodeproj`. Under Signing & Capabilities, choose your Team for both the `Quoted` and `QuotedWidgets` targets (or set `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`, a gitignored copy of `Config/Signing.xcconfig.example`). Signing is automatic.
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
4. Answer support mail. Users write there to ask about their data, to appeal a block or ban, and to report something outside the app. Don't delete an anonymous account because someone emails its username: nothing shows the account is theirs. Point them to Account > Delete account on the iPhone that holds it.

## 4. Legal pages: review, then publish

The bundled pages are `App/Resources/Legal/privacy.md`, `terms.md` and `community-guidelines.md`. They were rewritten on 2026-10-19 to match what the app and backend actually do: what is stored, the anonymous "Search the web" count (event name and hour, no account ID), what account deletion removes, how reports are kept, and the daily moderation check. They have not had a legal review. Since 2026-10-20 accounts are anonymous, but `privacy.md` and `terms.md` still describe email and password sign-in. `docs/decisions/2026-10-20-anonymous-accounts.md` (Consequences) lists the lines and suggested wording; decide and update them before release.

**Before release:** have them reviewed (ideally by a lawyer for the countries you launch in). Whenever you change them, update the "Last updated" line in the file and in the hosted copy.

App Store Connect needs a public **Privacy Policy URL** (App Information) and a **Support URL** (each version). The hosted policy must match the one in the app. With GitHub Pages:

1. Create a new public repository, for example `quoted-site`. Do not publish this app repository.
2. Copy the three legal files into it with the support address filled in:
   ```sh
   for f in privacy terms community-guidelines; do
     sed "s/{{SUPPORT_EMAIL}}/support@yourdomain/g" App/Resources/Legal/$f.md > ../quoted-site/$f.md
   done
   ```
3. Add `support.md`: how to reach you (the support address), how to delete your account (Account > Delete account), how to report or block someone (the quote's "…" menu, press and hold a request or friend, or the "…" menu on a friend's profile), and that reports are reviewed daily.
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
| Contact Info > Email Address | Sign-in email. **Not collected while accounts are anonymous**; see below | App Functionality | Yes | No |
| Contact Info > Name | Optional display name, shown to other users | App Functionality | Yes | No |
| Contacts | The friends list, requests and blocks (the social graph) | App Functionality | Yes | No |
| User Content > Other User Content | Quotes, notes on shares, shared quotes, reports | App Functionality | Yes | No |
| Identifiers > User ID | Account ID and username | App Functionality | Yes | No |
| Usage Data > Product Interaction | Count of "Search the web" taps (event name and hour only) | Analytics | **No** | No |

Not collected: location, photos (saving a quote image to Photos is add-only and never leaves the iPhone), contacts from the address book, search terms, diagnostics, purchases, device IDs, advertising data. Reminder settings stay on the device. Support email arrives outside the app.

**Email Address while accounts are anonymous: the founder decides.** Quoted now collects no email address, but `App/PrivacyInfo.xcprivacy` still declares `NSPrivacyCollectedDataTypeEmailAddress` and this table still lists it. Before you submit, either remove it from both (and add it back when email sign-in returns), or keep both if email sign-in will return soon. The manifest, the label and the Privacy Policy must agree.

If any of this changes (a crash reporter, new analytics, a new field), update the manifest, the policy and this label together.

## 7. Age rating

Answer the questionnaire as follows:

- Content descriptions (violence, sexual content, profanity, drugs, horror, mature themes, medical, gambling, contests): **None**. The app ships no such content; quotes come from users and the public-domain starter pack.
- **Unrestricted web access: Yes.** "Search the web" opens Google in an in-app browser (`SFSafariViewController`), from which any site is reachable. Apple maps this capability to **16+** (Age ratings values and definitions, checked 2026-10-19). It is the founder's deliberate choice (`docs/decisions/2026-10-19-web-search-browser.md`). To lower the rating, switch the row to open the Safari app and answer No.
- **User-generated content: Yes.** Users write quotes and notes, pick a display name and share with friends. Report and Block exist on every shared quote, request and friend, and on a friend's profile (which shows their favorites).
- **Messaging and chat: Yes.** A shared quote can carry a short note to an accepted friend.
- **Social media: No.** Apple defines it as a feed or discovery method that spreads content to many users (that would mean 13+). Quoted only sends a quote to chosen, accepted friends; there is no feed.
- **Expected result: 16+**, driven only by unrestricted web access. User-generated content and messaging do not raise the rating.
- Advertising, gambling, loot boxes, parental controls, age assurance: No.

The Terms require users to be at least 13, which fits the 16+ rating. If you later switch web search to the Safari app, the rating drops to 4+; then raise it to 13+ where App Store Connect lets you set a higher rating, to match the Terms.

## 8. App Review: no login, and a helper account

Quoted has no sign-in while accounts are anonymous (`docs/decisions/2026-10-20-anonymous-accounts.md`). The reviewer opens the app, gets a fresh account for that device and lands on Choose a username. So there is no demo account and no password to hand over.

App Store Connect > the version > App Review Information: untick **Sign-in required**, and leave the user name and password empty.

Report and Block only appear with another person (a friend request, a friend or a shared quote), so prepare a helper account the reviewer can add. The local seed scripts refuse the hosted project on purpose, so do this by hand with a TestFlight build:

1. Install the TestFlight build on an iPhone you keep for this (a spare one, or your own if you don't use Quoted on it). One install holds one account, and deleting the app loses it.
2. Choose the username `quotedhelper` (or another you put in the notes), a display name, and a few quotes from the starter pack.
3. Keep that install for every review. Don't delete the account.
4. While a review runs, open the helper iPhone at least once a day: accept the reviewer's friend request and send them a quote with a note, so Shared with you shows Report and Block on a quote too.

Notes along these lines:

> Quoted keeps quotes the user saves and shows them as reminders and in widgets. There is no sign-in: on first launch the app creates an account for this device and asks for a username. In our backend this is called an "anonymous" account, which only means it has no email or password. Usernames are visible to other users, and quotes are shared only between people who have accepted each other as friends.
>
> Moderation (Guideline 1.2): in Friends, add the username `quotedhelper`. Press and hold the pending request for Report and Block. We accept requests to that account within a day during review and send a quote back; then in Friends > Shared with you each quote's "…" menu has Report and Block, and swiping a quote left shows Delete, Block and Report. Blocked people are listed in Account > Blocked users. Reports are reviewed daily. The Terms and Community Guidelines are in Account > About and linked from Choose a username.
>
> Account deletion (5.1.1(v)): Account > Delete account. It is safe to test: it deletes the account the app created on your device, and the app then starts a new, empty one.

Reports the reviewer files against the helper show up in the daily check; mark them reviewed. A block the reviewer sets belongs to the reviewer's account, so the helper still works for the next review.

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
   - A fresh install opens on Choose a username with no sign-in (needs the anonymous sign-ins switch from step 1). Pick a username, then the starter pack, then the Library.
   - Account shows no email and no Sign out, and its footer reads "Your account belongs to this iPhone and has no email or password. If you delete the app, it can't be recovered."
   - Reminders arrive, the widget shows the latest reminder's quote, and Share as image offers Save Image (it asks for photo access once, add-only).
   - Friends (with a second iPhone, or with the helper account from step 8): request, accept, share with a note, Save, Report, Block and swipe to delete in Shared with you.
   - Account shows Contact support with your address; the legal pages end with it too.
   - Delete account: the app returns to Choose a username with a new, empty account.
   - Delete the app and install it again: it opens on Choose a username with a new, empty account and no "Your session ended" toast. The old account stays on the server, unreachable, and its username stays taken.
5. Optional: external TestFlight testers (needs Beta App Review). In TestFlight's Test Information, untick sign-in required too, and reuse the notes and the helper account from step 8.

## 12. Submit, then keep it running

1. On the version page, pick the build, fill in the listing, App Privacy, age rating and App Review Information, and choose a release option (manual release is safest for 1.0). Submit for Review.
2. **Every day:** run the report check in the SQL editor (`select * from private.reports_to_review;`), act on each report, and mark it reviewed (`docs/system-design.md` §7). The app promises a daily review and action within 24 hours where possible. Consider the optional Database Webhook alert described there.
3. Read the support mailbox regularly.
4. Before each later release: bump the build (and version), repeat TestFlight, update the legal pages and the label if data use changed, and check the helper account still exists (its username still finds it in Friends).
