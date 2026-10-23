#!/usr/bin/env bash
# Create (or refresh) the founder's demo account on the LOCAL Supabase stack:
#   demo@quoted.local, username @alex ("Alex"), the first 6 starter quotes in reminders, and one
#   friend, @maya, who has shared one quote (via scripts/seed-local-friend.sh).
#
# The password is a fresh `openssl rand -base64 12` on every run. It is written only to
# build/demo-account.txt (build/ is gitignored) and never printed.
#
# LOCAL STACK ONLY: refuses any URL that is not http://127.0.0.1 or http://localhost.
#
# Usage: scripts/seed-local-demo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_SECRET_KEY="${LOCAL_SECRET_KEY:-sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz}"
LOCAL_PUBLISHABLE_KEY="${LOCAL_PUBLISHABLE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}"
EMAIL="demo@quoted.local"
USERNAME="alex"
DISPLAY_NAME="Alex"
STARTER_COUNT=6
CREDENTIALS="$ROOT/build/demo-account.txt"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

case "$SUPABASE_URL" in
  http://127.0.0.1:* | http://127.0.0.1 | http://localhost:* | http://localhost) ;;
  *) die "refusing to run against '$SUPABASE_URL': this script only talks to the local stack (http://127.0.0.1)." ;;
esac
[[ "$LOCAL_SECRET_KEY" == sb_secret_* ]] || die "LOCAL_SECRET_KEY must be the local stack's sb_secret_ key."
command -v jq >/dev/null || die "jq is required (brew install jq)."
curl --silent --fail --max-time 5 "$SUPABASE_URL/auth/v1/health" -H "apikey: $LOCAL_PUBLISHABLE_KEY" >/dev/null ||
  die "the local stack is not reachable at $SUPABASE_URL (run 'supabase start')."

admin() {
  local method="$1" path="$2" body="${3-}"
  curl --silent --show-error --fail-with-body --max-time 15 -X "$method" "$SUPABASE_URL$path" \
    -H "apikey: $LOCAL_SECRET_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=representation" ${body:+--data "$body"}
}

as_demo() {
  local method="$1" path="$2" body="${3-}"
  curl --silent --show-error --fail-with-body --max-time 15 -X "$method" "$SUPABASE_URL$path" \
    -H "apikey: $LOCAL_PUBLISHABLE_KEY" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -H "Prefer: return=representation" ${body:+--data "$body"}
}

# --- Account (created or reused) with a fresh password ------------------------------------------
PASSWORD="$(openssl rand -base64 12)"
USER_ID="$(admin GET "/auth/v1/admin/users?per_page=1000" | jq -r --arg e "$EMAIL" '.users[] | select(.email == $e) | .id' | head -n 1)"
if [[ -z "$USER_ID" ]]; then
  USER_ID="$(admin POST /auth/v1/admin/users \
    "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email: $e, password: $p, email_confirm: true}')" | jq -r '.id')"
  log "Created $EMAIL."
else
  admin PUT "/auth/v1/admin/users/$USER_ID" "$(jq -n --arg p "$PASSWORD" '{password: $p}')" >/dev/null
  log "Reusing $EMAIL (new password)."
fi
mkdir -p "$(dirname "$CREDENTIALS")"
umask 077
printf 'Quoted demo account (LOCAL Supabase stack, Debug-Local build only)\nemail: %s\npassword: %s\nusername: @%s\n' \
  "$EMAIL" "$PASSWORD" "$USERNAME" >"$CREDENTIALS"
log "Credentials written to build/demo-account.txt."

TOKEN="$(curl --silent --show-error --fail-with-body --max-time 15 \
  -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $LOCAL_PUBLISHABLE_KEY" -H "Content-Type: application/json" \
  --data "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email: $e, password: $p}')" | jq -r '.access_token')"
[[ -n "$TOKEN" && "$TOKEN" != null ]] || die "could not sign in as $EMAIL"

# --- Profile ------------------------------------------------------------------------------------
EXISTING="$(admin GET "/rest/v1/profiles?id=eq.$USER_ID&select=username" | jq -r '.[0].username // empty')"
if [[ -z "$EXISTING" ]]; then
  as_demo POST /rest/v1/profiles \
    "$(jq -n --arg id "$USER_ID" --arg u "$USERNAME" --arg n "$DISPLAY_NAME" '{id: $id, username: $u, display_name: $n}')" >/dev/null
  log "Created the profile @$USERNAME."
elif [[ "$EXISTING" != "$USERNAME" ]]; then
  die "$EMAIL already has the username @$EXISTING"
fi

# --- Starter quotes in reminders ----------------------------------------------------------------
QUOTE_COUNT="$(as_demo GET "/rest/v1/quotes?select=id" | jq 'length')"
if [[ "$QUOTE_COUNT" == 0 ]]; then
  starters="$(as_demo GET "/rest/v1/starter_quotes?select=body,body_format,author,source&order=sort_order&limit=$STARTER_COUNT")"
  rows="$(jq '[to_entries[] | .value + {origin: "starter", rotation_position: .key}]' <<<"$starters")"
  as_demo POST /rest/v1/quotes "$rows" >/dev/null
  log "Added $STARTER_COUNT starter quotes to the library and reminders."
else
  log "The library already has $QUOTE_COUNT quotes; left as is."
fi

# --- Friend @maya with one shared quote ---------------------------------------------------------
MAYA_ID="$(admin GET "/rest/v1/profiles?username=eq.maya&select=id" | jq -r '.[0].id // empty')"
SHARES=0
if [[ -n "$MAYA_ID" ]]; then
  SHARES="$(admin GET "/rest/v1/shares?sender_id=eq.$MAYA_ID&recipient_id=eq.$USER_ID&select=id" | jq 'length')"
fi
if [[ "$SHARES" == 0 ]]; then
  # A line that isn't among the six starters, so the share stands out in the library.
  "$ROOT/scripts/seed-local-friend.sh" "$USERNAME" --accept \
    --quote "But screw your courage to the sticking-place, and we’ll not fail." \
    --author "William Shakespeare" --source "Macbeth" --note "This one made me think of you"
else
  "$ROOT/scripts/seed-local-friend.sh" "$USERNAME" --accept --no-share
fi
log "Demo account ready. The app has no sign-in screen: run scripts/sign-in-local-demo.sh to sign a simulator into it."
