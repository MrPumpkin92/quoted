#!/usr/bin/env bash
# Build the Debug-Local app (local Supabase stack), then boot a simulator,
# install the app and launch it.
#
# Usage:
#   scripts/run-sim.sh                                        # iPhone 17 Pro
#   scripts/run-sim.sh 8DDD416E-67E0-4A70-82D2-B6507EBC80E5   # simulator UDID
#   scripts/run-sim.sh "iPhone 18 Pro"                        # or a device name
#   CONSOLE=1 scripts/run-sim.sh      # stay attached and stream the app's stdout/stderr
#   HEADLESS=1 scripts/run-sim.sh     # do not open Simulator.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
CONFIGURATION="Debug-Local"
BUNDLE_ID="com.hwei.quoted"
SIMULATOR="${1:-${SIMULATOR:-iPhone 17 Pro}}"

# Resolve a device name to a UDID. Prefers a booted device, then the newest runtime.
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

UDID="$(resolve_udid "$SIMULATOR")"
echo "==> Simulator: $SIMULATOR ($UDID)"

cd "$ROOT"
CONFIGURATION="$CONFIGURATION" DESTINATION="platform=iOS Simulator,id=$UDID" "$ROOT/scripts/build.sh"
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/Quoted.app"

# `boot` fails if the device is already booted; that is fine.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
if [[ "${HEADLESS:-0}" != "1" ]]; then
  open -a Simulator --args -CurrentDeviceUDID "$UDID"
fi

echo "==> Installing $APP"
xcrun simctl install "$UDID" "$APP"

echo "==> Launching $BUNDLE_ID"
if [[ "${CONSOLE:-0}" == "1" ]]; then
  exec xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID"
else
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID"
fi
