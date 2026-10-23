# Decision: v1 accounts, onboarding, cleanup and inbox alerts (2026-10-21)

## Decision (LLM Council, 2026-10-21; carried out the same day)

The full-repository audit left four product questions open. The council (five advisors, anonymous peer review, chairman) answered them as follows.

1. **Account durability.** The council's answer is **Sign in with Apple**, as both a way to sign in and a way to link an anonymous account (`linkIdentityWithIdToken`). It rejected syncing the anonymous session through iCloud Keychain: two phones would race on refresh-token rotation, and reuse detection would revoke the only credential. It also rejected library export alone. **Not built yet: the founder's call.** It brings sign-in back two days after the founder removed it "for now". It needs the founder's Apple Developer key and the Supabase dashboard setup (Apple provider with manual linking). Deleting an account must also revoke the Apple tokens. Until it ships, the app says plainly in Account, the Privacy Policy and the Terms that the account lives only on this iPhone.
2. **Abandoned anonymous accounts.** One daily `pg_cron` job, `private.purge_inactive_anonymous` (migration `20261021090000_abuse_limits_privacy_cleanup`), deletes only anonymous users:
   - **Rule A:** no username 7 days after creation. These accounts hold no data.
   - **Rule B:** `profiles.last_active_at` older than 12 months.
   - **Safeguards:** `profiles.purge_exempt` (for the App Review helper and demo accounts), a per-run cap that deletes nothing when exceeded, and a log table, `private.purge_runs`.
   - **Activity:** the app records it with `public.touch_activity()` from the foreground and from background refresh, throttled both on the server and in the app. `last_sign_in_at` is never used.
   - **Policy:** both rules are stated in the Privacy Policy and the Terms.
3. **First launch.** The Welcome screen comes back as `WelcomeView`, showing the wordmark, the promise, the Shelley quote, Get started and the Terms consent line.
   - Get started creates the account (`SessionStore.startAccount()`); nothing reaches the network before that.
   - A failure shows an inline error, and Get started can be tapped again.
   - Deleting the account, or losing it (`signedOutNotice`), returns to Welcome.
4. **New shares and friend requests.** No push in v1. Background refresh posts at most one local alert for items no earlier alert covered (`InboxAlerts`), and the app icon badge follows the Friends badge.
   - Alerts never show quote text.
   - A friend request never names the sender.
   - Items seen in the app don't alert later.

The council also flagged the reminder cliff. Reminders used to stop silently once the 60-slot queue ran out. Now one more notification, "Open Quoted to keep your reminders coming.", comes a day after the last planned reminder and opens Reminders (`NotificationScheduler.reschedule`).

## Alternatives considered and rejected

- **iCloud Keychain sync of the anonymous session** (see 1).
- **Creating the account at launch** (the 2026-10-20 behaviour). It creates accounts for people who open the app and leave, it stores data before the Terms are shown, and an offline first launch had no screen to explain itself.
- **Real push for shares** (APNs plus a server function). It adds new infrastructure and secrets for v1; a late local alert is enough for quotes.
- **Friends' shared quotes in the widget.** That would put unmoderated content from other people on the Lock Screen.

## Consequences

- **Welcome is the signed-out screen** while `AccountMode.current == .anonymous`. The 2026-10-20 record's notes on automatic account creation and the "started a new account" toast no longer apply.
- **Founder steps before launch:**
  - Turn on anonymous sign-ins on the hosted project.
  - Push migration `20261021090000_abuse_limits_privacy_cleanup` and confirm `pg_cron` is enabled.
  - Set `purge_exempt` on the App Review helper account.
  - Decide on Sign in with Apple (1).
  - Set up a scheduled logical backup: the free tier makes none, and the purge and Delete account are final.
- **Server limits** (same migration):
  - 5000 quotes per account (`QR002`).
  - 20 friend requests a day and 50 outgoing pending (`QR001`).
  - 100 shares a day (`QR001`).
  - 20 reports a day (`QR001`); a duplicate report counts as one.
  - The app maps both codes to plain messages.
- **Profiles are private:** a profile is readable only by people connected through a friendship, share or block. Exact-username lookup goes through `public.find_profile`, which hides blocked pairs and yourself; availability goes through `public.is_username_available`.
- **Reversal:**
  - Without the cleanup job: unschedule the `pg_cron` job.
  - Without Welcome: set `AccountMode.current = .emailPassword`, which brings back the email screens, or restore the 2026-10-20 launch behaviour in `SessionStore`.
