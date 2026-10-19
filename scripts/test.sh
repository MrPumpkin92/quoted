#!/usr/bin/env bash
# Run the test suites:
#   1. Package tests (QuotedCoreTests, QuotedKitTests) with `swift test` on macOS.
#   2. UI tests (QuotedUITests) on an iOS Simulator with the Debug-Local
#      configuration, which talks to the local Supabase stack (`supabase start`).
#
# Usage:
#   scripts/test.sh                              # iPhone 17 Pro simulator
#   SIMULATOR=8DDD416E-67E0-4A70-82D2-B6507EBC80E5 scripts/test.sh   # UDID or device name
#   SKIP_PACKAGE_TESTS=1 scripts/test.sh
#   SKIP_UI_TESTS=1 scripts/test.sh
#   KEEP_APP=1 scripts/test.sh          # don't uninstall Quoted first (skips notification priming)
#   CLEAN_TEST_USERS=1 scripts/test.sh  # delete the uitest-* accounts from the local stack afterwards
#   VERBOSE=1 scripts/test.sh
#
# The UI test signs up a throwaway uitest-<time>@quoted.local account on the local stack. The app is
# uninstalled first so the notification permission is undecided and the priming screen shows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
LOCAL_SUPABASE_URL="${LOCAL_SUPABASE_URL:-http://127.0.0.1:54321}"

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

cd "$ROOT"

if [[ "${SKIP_PACKAGE_TESTS:-0}" != "1" ]]; then
  echo "==> swift test (Packages/QuotedKit)"
  (cd Packages/QuotedKit && swift test)
fi

if [[ "${SKIP_UI_TESTS:-0}" != "1" ]]; then
  UDID="$(resolve_udid "$SIMULATOR")"
  DESTINATION="platform=iOS Simulator,id=$UDID"

  if ! curl --silent --output /dev/null --max-time 3 "$LOCAL_SUPABASE_URL/auth/v1/health"; then
    echo "warning: local Supabase is not reachable at $LOCAL_SUPABASE_URL; run 'supabase start' first." >&2
  fi

  xcodegen generate --spec project.yml

  if [[ "${KEEP_APP:-0}" != "1" ]]; then
    xcrun simctl uninstall "$UDID" com.hwei.quoted 2>/dev/null || true
  fi

  RESULT_BUNDLE="$ROOT/build/TestResults/UITests-$(date +%Y%m%d-%H%M%S).xcresult"
  mkdir -p "$(dirname "$RESULT_BUNDLE")"

  echo "==> UI tests: scheme 'Quoted Local' (Debug-Local) on $SIMULATOR ($UDID)"
  status=0
  xcodebuild \
    -project Quoted.xcodeproj \
    -scheme "Quoted Local" \
    -configuration Debug-Local \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${QUIET[@]+"${QUIET[@]}"} \
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
    "$ROOT/scripts/clean-local-test-users.sh" || true
  fi
  [[ $status -eq 0 ]] || exit "$status"
fi

echo "==> All tests passed"
