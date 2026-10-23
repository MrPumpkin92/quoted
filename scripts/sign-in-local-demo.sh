#!/usr/bin/env bash
# Signs a simulator into the LOCAL demo account (build/demo-account.txt, written by
# scripts/seed-local-demo.sh) by running the opt-in UI test testSignInForManualQA. The app has no
# sign-in screen: the test launches it with -UITestReset and the account in the launch environment
# (QUOTED_DEBUG_SIGNIN_EMAIL and QUOTED_DEBUG_SIGNIN_PASSWORD), and the Debug-Local build signs in
# with it instead of creating an anonymous account. The session then stays in the simulator's
# keychain, so launching Quoted normally opens the demo account.
# The password is passed through the environment only and is never printed.
#
#   scripts/sign-in-local-demo.sh                   # iPhone 17 Pro
#   scripts/sign-in-local-demo.sh "iPhone 18 Pro"   # a device name, or a simulator UDID
#
# It regenerates Quoted.xcodeproj first and builds into build/DerivedData, like scripts/test.sh.
# Exits with xcodebuild's status when the build or the sign-in fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
SIMULATOR="${1:-${SIMULATOR:-iPhone 17 Pro}}"
ACCOUNT="$ROOT/build/demo-account.txt"

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

if [[ ! -f "$ACCOUNT" ]]; then
  echo "No $ACCOUNT. Run scripts/seed-local-demo.sh first." >&2
  exit 1
fi

email="$(awk -F': ' '/^email:/{print $2}' "$ACCOUNT")"
password="$(awk -F': ' '/^password:/{print $2}' "$ACCOUNT")"
if [[ -z "$email" || -z "$password" ]]; then
  echo "$ACCOUNT has no email or password line. Run scripts/seed-local-demo.sh again." >&2
  exit 1
fi

UDID="$(resolve_udid "$SIMULATOR")"
SIM="$SIMULATOR ($UDID)"
[[ "$SIMULATOR" != "$UDID" ]] || SIM="$UDID"

cd "$ROOT"
# --no-env keeps project.yml's ${CONFIGURATION} and friends as written (see build.sh).
xcodegen generate --no-env --spec project.yml

# Only the summary lines and errors are shown. PIPESTATUS keeps xcodebuild's own exit status
# (grep's would hide a failure).
set +e
TEST_RUNNER_QUOTED_SIGNIN_EMAIL="$email" \
TEST_RUNNER_QUOTED_SIGNIN_PASSWORD="$password" \
xcodebuild test \
  -project "$ROOT/Quoted.xcodeproj" \
  -scheme "Quoted Local" \
  -configuration Debug-Local \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:QuotedUITests/QuotedUITests/testSignInForManualQA \
  2>&1 | grep -E "error:|Test Case .*(passed|failed|skipped)|\*\* [A-Z ]+ (SUCCEEDED|FAILED) \*\*"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo "Sign-in failed (xcodebuild exited with $status); $SIM is not signed in as $email." >&2
  exit "$status"
fi
echo "Signed in as $email on $SIM. Launch Quoted in the simulator to continue."
