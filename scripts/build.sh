#!/usr/bin/env bash
# Regenerate Quoted.xcodeproj from project.yml and build the app for the iOS Simulator.
#
# Usage:
#   scripts/build.sh                         # Debug-Local (local Supabase stack)
#   CONFIGURATION=Debug scripts/build.sh     # hosted Supabase
#   CONFIGURATION=Release scripts/build.sh
#   DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' scripts/build.sh
#   VERBOSE=1 scripts/build.sh               # full xcodebuild log
#
# Products land in build/DerivedData/Build/Products/<CONFIGURATION>-iphonesimulator/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug-Local}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

case "$CONFIGURATION" in
  Debug-Local) SCHEME="${SCHEME:-Quoted Local}" ;;
  Debug | Release) SCHEME="${SCHEME:-Quoted}" ;;
  *)
    echo "error: unknown CONFIGURATION '$CONFIGURATION' (use Debug, Debug-Local or Release)" >&2
    exit 64
    ;;
esac

QUIET=(-quiet)
[[ "${VERBOSE:-0}" == "1" ]] && QUIET=()

cd "$ROOT"
xcodegen generate --spec project.yml

echo "==> Building scheme '$SCHEME' ($CONFIGURATION) for '$DESTINATION'"
xcodebuild \
  -project Quoted.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  ${QUIET[@]+"${QUIET[@]}"} \
  build

echo "==> Build succeeded: $DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/Quoted.app"
