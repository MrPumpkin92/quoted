#!/usr/bin/env bash
# Run the test suites:
#   1. Package tests (QuotedCoreTests, QuotedKitTests) with `swift test` on macOS.
#   2. Database tests: the pgTAP files in supabase/tests (RLS, grants, triggers, RPCs) with
#      `supabase test db --local`, against the running local stack's database. Each file runs in a
#      transaction that it rolls back, so the stack keeps its data.
#   3. Catalog checks, offline: `scripts/catalog.sh selftest` (the verifier on committed excerpts) and
#      `scripts/catalog.sh generate check` (every catalog batch migration regenerates byte for byte).
#      The full verifier gate (`scripts/catalog.sh acceptance`) needs the downloaded corpus; run it by
#      hand after a verifier change and before each batch.
#   4. UI tests (QuotedUITests) on an iOS Simulator with the Debug-Local
#      configuration, which talks to the local Supabase stack (`supabase start`).
#      Anonymous sign-ins must be on there (`enable_anonymous_sign_ins = true` in
#      supabase/config.toml, then `supabase stop && supabase start`); the script checks first.
#
# Usage:
#   scripts/test.sh                              # iPhone 17 Pro simulator
#   SIMULATOR=8DDD416E-67E0-4A70-82D2-B6507EBC80E5 scripts/test.sh   # UDID or device name
#   SKIP_PACKAGE_TESTS=1 scripts/test.sh
#   SKIP_DB_TESTS=1 scripts/test.sh
#   SKIP_CATALOG_TESTS=1 scripts/test.sh
#   SKIP_UI_TESTS=1 scripts/test.sh
#   KEEP_APP=1 scripts/test.sh          # don't uninstall Quoted first (skips notification priming)
#   CLEAN_TEST_USERS=1 scripts/test.sh  # delete the UI test accounts from the local stack afterwards
#   LOCAL_SUPABASE_URL=http://127.0.0.1:55321 scripts/test.sh  # another local stack
#   SUPABASE_WORKDIR=build/anonstack scripts/test.sh  # database tests on another local stack
#   VERBOSE=1 scripts/test.sh
#
# The app has no sign-in: the UI test gets a new anonymous account on the local stack and names it
# ui<time>. The app is uninstalled first so the notification permission is undecided and the priming
# screen shows.
#
# LOCAL_SUPABASE_URL (default http://127.0.0.1:54321, local hosts only) is built into the app in
# place of Config/Local.xcconfig's URL and passed to the tests, which read their quotes back with
# LOCAL_SECRET_KEY (default: the local stack's demo secret key) as TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL
# and TEST_RUNNER_QUOTED_LOCAL_SECRET_KEY.
#
# SUPABASE_WORKDIR (default: this repo) is the directory holding the supabase/ folder whose
# config.toml names the stack for the database tests; the UI tests' stack is LOCAL_SUPABASE_URL, so
# set both to move everything to another stack. The test files always come from this repo's
# supabase/tests, so that stack must run this repo's migrations.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
LOCAL_SUPABASE_URL="${LOCAL_SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_PUBLISHABLE_KEY="${LOCAL_PUBLISHABLE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}"
LOCAL_SECRET_KEY="${LOCAL_SECRET_KEY:-sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz}"
SUPABASE_WORKDIR="${SUPABASE_WORKDIR:-$ROOT}"

QUIET=(-quiet)
[[ "${VERBOSE:-0}" == "1" ]] && QUIET=()

# Resolve a device name to a UDID. Prefers a booted device, then the newest runtime.
# (xcodebuild's name= alone means "latest OS", which misses devices on older runtimes.)
resolve_udid() {
  local query="$1"
  if [[ "$query" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "$query"
    return
  fi
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(n) for n in re.findall(r"\d+", runtime.rsplit(".", 1)[-1])]
matches = [(d["state"] == "Booted", version(rt), d["udid"])
           for rt, ds in devices.items() if "iOS" in rt
           for d in ds if d["name"] == name]
if not matches:
    sys.exit(f"error: no available iOS simulator named {name!r}")
print(max(matches)[2])
' "$query"
}

# Resolved before the cd below, so a relative SUPABASE_WORKDIR means the caller's directory.
if [[ "${SKIP_DB_TESTS:-0}" != "1" ]]; then
  if ! SUPABASE_WORKDIR="$(cd "$SUPABASE_WORKDIR" 2>/dev/null && pwd)" ||
    [[ ! -f "$SUPABASE_WORKDIR/supabase/config.toml" ]]; then
    echo "error: SUPABASE_WORKDIR must be a directory holding supabase/config.toml." >&2
    exit 1
  fi
fi

cd "$ROOT"

if [[ "${SKIP_PACKAGE_TESTS:-0}" != "1" ]]; then
  echo "==> swift test (Packages/QuotedKit)"
  (cd Packages/QuotedKit && swift test)
fi

if [[ "${SKIP_DB_TESTS:-0}" != "1" ]]; then
  echo "==> supabase test db (supabase/tests) on the stack in $SUPABASE_WORKDIR"
  command -v supabase >/dev/null || { echo "error: the Supabase CLI is required (brew install supabase/tap/supabase)." >&2; exit 1; }
  # --local: never the linked (hosted) project, even while deploy-backend.sh has the repo linked.
  if ! supabase test db --local --workdir "$SUPABASE_WORKDIR" "$ROOT/supabase/tests"; then
    echo "error: the database tests failed, or that stack's database is not running ('supabase start')." >&2
    exit 1
  fi
fi

if [[ "${SKIP_CATALOG_TESTS:-0}" != "1" ]]; then
  echo "==> catalog: selftest and generate check"
  "$ROOT/scripts/catalog.sh" selftest
  "$ROOT/scripts/catalog.sh" generate check
fi

if [[ "${SKIP_UI_TESTS:-0}" != "1" ]]; then
  UDID="$(resolve_udid "$SIMULATOR")"
  DESTINATION="platform=iOS Simulator,id=$UDID"

  case "$LOCAL_SUPABASE_URL" in
    http://127.0.0.1:* | http://127.0.0.1 | http://localhost:* | http://localhost) ;;
    *) echo "error: LOCAL_SUPABASE_URL must be the local stack (http://127.0.0.1), not '$LOCAL_SUPABASE_URL'." >&2; exit 1 ;;
  esac
  command -v jq >/dev/null || { echo "error: jq is required (brew install jq)." >&2; exit 1; }
  if ! curl --silent --output /dev/null --max-time 3 "$LOCAL_SUPABASE_URL/auth/v1/health"; then
    echo "error: local Supabase is not reachable at $LOCAL_SUPABASE_URL; run 'supabase start' first." >&2
    exit 1
  fi
  # The app creates an anonymous account on launch, so the UI tests need anonymous sign-ins.
  if ! curl --silent --fail --max-time 5 "$LOCAL_SUPABASE_URL/auth/v1/settings" -H "apikey: $LOCAL_PUBLISHABLE_KEY" |
    jq -e '.external.anonymous_users == true' >/dev/null; then
    echo "error: anonymous sign-ins are off on $LOCAL_SUPABASE_URL. Turn on enable_anonymous_sign_ins in supabase/config.toml and restart the local stack (supabase stop && supabase start)." >&2
    exit 1
  fi

  # --no-env keeps project.yml's ${CONFIGURATION} and friends as written (see build.sh).
  xcodegen generate --no-env --spec project.yml

  if [[ "${KEEP_APP:-0}" != "1" ]]; then
    xcrun simctl uninstall "$UDID" com.hwei.quoted 2>/dev/null || true
  fi

  RESULT_BUNDLE="$ROOT/build/TestResults/UITests-$(date +%Y%m%d-%H%M%S).xcresult"
  mkdir -p "$(dirname "$RESULT_BUNDLE")"

  echo "==> UI tests: scheme 'Quoted Local' (Debug-Local) on $SIMULATOR ($UDID)"
  status=0
  TEST_RUNNER_QUOTED_LOCAL_SUPABASE_URL="$LOCAL_SUPABASE_URL" \
  TEST_RUNNER_QUOTED_LOCAL_SECRET_KEY="$LOCAL_SECRET_KEY" \
  xcodebuild \
    -project Quoted.xcodeproj \
    -scheme "Quoted Local" \
    -configuration Debug-Local \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -onlyUsePackageVersionsFromResolvedFile \
    ${QUIET[@]+"${QUIET[@]}"} \
    SUPABASE_URL="$LOCAL_SUPABASE_URL" \
    test || status=$?

  if [[ -d "$RESULT_BUNDLE" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
result, passed = d.get("result"), d.get("passedTests", 0)
failed, skipped = d.get("failedTests", 0), d.get("skippedTests", 0)
print(f"==> UI tests {result}: {passed} passed, {failed} failed, {skipped} skipped")
for failure in d.get("testFailures", []):
    name, text = failure.get("testIdentifierString"), failure.get("failureText")
    print(f"    FAILED {name}: {text}")
' || true
    echo "    Result bundle: $RESULT_BUNDLE"
  fi
  if [[ "${CLEAN_TEST_USERS:-0}" == "1" ]]; then
    SUPABASE_URL="$LOCAL_SUPABASE_URL" LOCAL_SECRET_KEY="$LOCAL_SECRET_KEY" \
      "$ROOT/scripts/clean-local-test-users.sh" || true
  fi
  [[ $status -eq 0 ]] || exit "$status"
fi

echo "==> All tests passed"
