# Quoted

Quoted is an iPhone app for keeping the quotes that move you. It shows them again through reminders and a Home Screen widget, and lets you share them with friends. It is built with SwiftUI on iOS 26 with a Supabase backend.

## What's in the MVP
- Email sign-in, a username, and a 60-quote public-domain starter pack. Every attribution was checked against its source text; see `docs/starter-pack-sources.md`.
- Add and edit quotes with **bold**, *italic* and <u>underline</u>, plus a Paste button that splits "quote — Author, Work".
- **Reminders** (the playlist): local notifications cycle through your chosen quotes N times a day, inside a time window, on chosen days, in order or shuffled.
- A Home Screen and Lock Screen widget that always matches your latest reminder.
- Friends (add by username), quote sharing with notes, a "Shared with you" inbox, and report and block.
- Search across your library and shared quotes. The last row opens Google in an in-app browser; copy a quote, then tap Paste in Add.
- Account screen: sign out, delete account, blocked users, legal pages and support contact.

## Run it in the simulator (local backend, no accounts needed)
Requirements: Xcode 27, Docker running, `brew install supabase/tap/supabase xcodegen`.

```bash
supabase start
```

```bash
scripts/seed-local-demo.sh
```

```bash
scripts/sign-in-local-demo.sh
```

Then open `Quoted.xcodeproj`, pick the **Quoted Local** scheme and an iPhone simulator, and press Run. The demo account (@alex) has 6 quotes in reminders, a friend (@maya) and one shared quote. Its password is in `build/demo-account.txt`, which is gitignored. To start fresh, create an account in the app; the local stack confirms email automatically.

## Run it against your Supabase project
The **Quoted** scheme (Debug and Release) uses `https://yyajndbishiyugtbpzmk.supabase.co`. Deploy the schema and function first; this needs your Supabase login and database password:

```bash
scripts/deploy-backend.sh
```

## Tests
```bash
scripts/test.sh
```

- **Swift package:** QuotedCore and QuotedKit tests (`swift test`); add `QUOTED_LOCAL_SUPABASE=1` for integration tests against the local stack.
- **Database:** pgTAP tests (`supabase test db`).
- **UI:** the XCUITest happy path on the simulator.

## Ship it
Follow `docs/app-store-submission.md`. It covers deploy, SMTP, support email, legal pages, privacy label, age rating, demo accounts, archive, TestFlight and submit. Release archives fail on purpose until `SUPPORT_EMAIL` is set in `Config/Release.xcconfig`.

## Layout
| Path | What |
|---|---|
| `App/` | SwiftUI app: `Stores/` (state), `Features/` (screens), `Design/` (tokens and components), `Navigation/`, `Services/` (notifications, widget bridge, background refresh) |
| `Widgets/` | WidgetKit extension (links QuotedCore only) |
| `Packages/QuotedKit` | `QuotedCore` (models, rich text, reminder planner, search, widget snapshot) and `QuotedKit` (Supabase repositories) |
| `supabase/` | Migrations (schema, RLS, starter pack, hardening), pgTAP tests, `delete-account` Edge Function |
| `docs/` | `system-design.md`, `ui-spec.md`, `app-architecture.md`, decisions (council verdicts), reviews (engineering review and fixes) |
| `design/` | The three mockup directions (canvas sources and renders) |
| `project.yml` | XcodeGen spec. Edit it, then run `xcodegen generate` |
