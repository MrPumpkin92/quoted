# Quoted

Quoted is an iPhone app for keeping the quotes that move you. It shows them again through reminders and a Home Screen widget, and lets you share them with friends. It is built with SwiftUI on iOS 26 with a Supabase backend.

## What's in the MVP
- No sign-in: the first launch creates an account for this iPhone (a Supabase anonymous account), asks for a username and offers a 60-quote public-domain starter pack (`docs/decisions/2026-10-20-anonymous-accounts.md`). Every attribution was checked against its source text; see `docs/starter-pack-sources.md`.
- Add and edit quotes with **bold**, *italic* and <u>underline</u>, plus a Paste button that splits "quote — Author, Work".
- **Reminders** (the playlist): local notifications cycle through your chosen quotes N times a day, inside a time window, on chosen days, in order or shuffled.
- A Home Screen and Lock Screen widget that always matches your latest reminder.
- Friends (add by username), quote sharing with notes, a "Shared with you" inbox, and report and block.
- Search across your library and shared quotes. The last row opens Google in an in-app browser; copy a quote, then tap Paste in Add.
- Account screen: delete account (the app then starts a new, empty one), blocked users, legal pages and support contact. There is no Sign out in this build (it comes back only with email sign-in), not even for the local demo account.

## Run it in the simulator (local backend, no accounts needed)
Requirements: Xcode 27, Docker running, `brew install supabase/tap/supabase xcodegen`.

The app creates an anonymous account on first launch, so the local stack needs `enable_anonymous_sign_ins = true` (set in `supabase/config.toml`). Auth reads that file only when it starts: if your stack was running before the change, restart it with `supabase stop && supabase start`.

```bash
supabase start
```

```bash
scripts/seed-local-demo.sh
```

```bash
scripts/sign-in-local-demo.sh
```

`scripts/sign-in-local-demo.sh` uses an iPhone 17 Pro simulator; pass another device name or a simulator UDID as its argument.

Then open `Quoted.xcodeproj`, pick the **Quoted Local** scheme and an iPhone simulator, and press Run. The demo account (@alex) has 6 quotes in reminders, a friend (@maya) and one shared quote. Its password is in `build/demo-account.txt`, which is gitignored. The app has no sign-in screen, so `scripts/sign-in-local-demo.sh` reaches the demo account through a DEBUG-only hook: with the local stack, the launch-environment variables `QUOTED_DEBUG_SIGNIN_EMAIL` and `QUOTED_DEBUG_SIGNIN_PASSWORD` sign in with a password instead of creating an anonymous account.

To start fresh, delete the app from the simulator, or launch it with `-UITestReset` (DEBUG builds: `xcrun simctl launch <udid> com.hwei.quoted -UITestReset`). Either way the app creates a new anonymous account and opens on "Choose a username". This is also how you leave the demo account, since the app has no Sign out.

## Run it against your Supabase project
The **Quoted** scheme (Debug and Release) uses `https://yyajndbishiyugtbpzmk.supabase.co`. Deploy the schema and function first; this needs your Supabase login and database password. Then turn on Authentication > Sign In / Providers > "Allow anonymous sign-ins" in the dashboard (the "Anonymous sign-ins" step of the checklist the script prints), or every new install stops on the launch screen:

```bash
scripts/deploy-backend.sh
```

The script deploys only what git records: it stops while `supabase/` has uncommitted changes (`FORCE_DIRTY=1` overrides that). It links the repo to the hosted project for the run only and unlinks it when it ends, so later `supabase` commands keep targeting the local stack.

## Tests
```bash
scripts/test.sh
```

The script runs the three suites in order, with the local stack running (`supabase start`), and stops at the first one that fails:

- **Swift package:** QuotedCore and QuotedKit tests (`swift test`). The integration tests against the local stack run only with `QUOTED_LOCAL_SUPABASE=1 swift test` in `Packages/QuotedKit`; the script doesn't set it.
- **Database:** the pgTAP tests in `supabase/tests` (`supabase test db --local`): RLS on every table, grants, triggers and RPCs. Each file rolls back, so the stack keeps its data. `SKIP_DB_TESTS=1` skips them. `SUPABASE_WORKDIR=<dir>` runs them on another local stack, `<dir>` being the directory that holds its `supabase/` folder.
- **UI:** the XCUITest happy path on the simulator.

## Tooling
- **Project file:** `Quoted.xcodeproj` is generated from `project.yml`. After editing the spec, run `xcodegen generate --no-env` and commit the result; the scripts regenerate it the same way before they build. Without `--no-env`, XcodeGen writes environment variables such as `CONFIGURATION` into the build phases, and with `CONFIGURATION` set that turns off the Release check.
- **Signing:** device builds and archives take your team ID from `Config/Signing.xcconfig` (gitignored; copy `Config/Signing.xcconfig.example`). Simulator builds don't need it. The project doesn't list that file, so it never changes the committed project.
- **Packages:** supabase-swift is pinned to an exact version in `Packages/QuotedKit/Package.swift`, and two committed `Package.resolved` files pin it and its dependencies: `Packages/QuotedKit/Package.resolved` for `swift test`, and `Quoted.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` for the app (Xcode, archives, and the scripts, which build only those versions). The two files are identical. To upgrade, change the version in `Package.swift`, run `swift package update` in `Packages/QuotedKit`, copy its `Package.resolved` over the app's, check it with `xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile -project Quoted.xcodeproj -scheme Quoted`, then run `scripts/test.sh` and commit both files.

## Ship it
Follow `docs/app-store-submission.md`. It covers deploy (including turning on anonymous sign-ins in the dashboard), support email, legal pages, privacy label, age rating, the App Review helper account, archive, TestFlight and submit. Release archives fail on purpose while `SUPPORT_EMAIL` (set in `Config/Shared.xcconfig`) is empty.

## Layout
| Path | What |
|---|---|
| `App/` | SwiftUI app: `Stores/` (state), `Features/` (screens), `Design/` (tokens and components), `Navigation/`, `Services/` (notifications, widget bridge, background refresh) |
| `Widgets/` | WidgetKit extension (links QuotedCore only) |
| `Packages/QuotedKit` | `QuotedCore` (models, rich text, reminder planner, search, widget snapshot) and `QuotedKit` (Supabase repositories) |
| `supabase/` | Migrations (schema, RLS, starter pack, hardening), pgTAP tests, `delete-account` Edge Function |
| `docs/` | `system-design.md`, `ui-spec.md`, `app-architecture.md`, decisions (council verdicts), reviews (engineering review and fixes) |
| `design/` | The three mockup directions (canvas sources and renders) |
| `project.yml` | XcodeGen spec. Edit it, then run `xcodegen generate --no-env` |
