#!/usr/bin/env bash
# Signs a simulator into the LOCAL demo account (build/demo-account.txt, written by
# scripts/seed-local-demo.sh) by running the opt-in UI test testSignInForManualQA.
# The password is passed through the environment only and is never printed.
#
#   scripts/sign-in-local-demo.sh [simulator-udid]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${1:-8DDD416E-67E0-4A70-82D2-B6507EBC80E5}"
ACCOUNT="$ROOT/build/demo-account.txt"

if [[ ! -f "$ACCOUNT" ]]; then
  echo "No $ACCOUNT. Run scripts/seed-local-demo.sh first." >&2
  exit 1
fi

email="$(awk -F': ' '/^email:/{print $2}' "$ACCOUNT")"
password="$(awk -F': ' '/^password:/{print $2}' "$ACCOUNT")"

TEST_RUNNER_QUOTED_SIGNIN_EMAIL="$email" \
TEST_RUNNER_QUOTED_SIGNIN_PASSWORD="$password" \
xcodebuild test \
  -project "$ROOT/Quoted.xcodeproj" \
  -scheme "Quoted Local" \
  -configuration Debug-Local \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$ROOT/build/DD-main" \
  -only-testing:QuotedUITests/QuotedUITests/testSignInForManualQA \
  2>&1 | grep -E "Test Case .*(passed|failed|skipped)|TEST (SUCCEEDED|FAILED)" || true

echo "Signed in as $email on $SIM. Launch Quoted in the simulator to continue."
