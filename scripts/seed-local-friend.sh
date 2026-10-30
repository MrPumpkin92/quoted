#!/usr/bin/env bash
# Seed a second LOCAL account that befriends a test user and sends them a quote, so the Friends tab
# and "Shared with you" can be exercised against the local Supabase stack. The friend accepts the
# Terms of Use (a friend request and sending need them), and the quote goes as a quote message in
# their conversation (open_conversation, then a message made from a quote in the friend's library).
#
# LOCAL STACK ONLY. It uses the local demo secret key and refuses any URL that is not
# http://127.0.0.1 or http://localhost. Never point it at the hosted project.
#
# Usage:
#   scripts/seed-local-friend.sh <their-username> [options]
#
#   --friend <username>   the seeded friend's username (default: maya)
#   --name <name>         the friend's display name (default: "Maya Reyes")
#   --accept              accept the request at once with the local secret key, instead of
#                         tapping Accept in the app
#   --wait <seconds>      wait up to this long for the request to be accepted in the app (default 0)
#   --no-share            only send the friend request
#   --quote <text>        the sent quote's body (default: a Jane Austen line)
#   --author <name>       its author (default: Jane Austen)
#   --source <title>      its source (default: Pride and Prejudice)
#   --note <text>         an optional note (default: "Thought of you")
#   --remove              delete the friend's account instead (cascades friendships, conversations
#                         and messages)
#
# Re-running is safe: an existing friend account is reused (its password is reset to a new random
# one that is never printed), an existing request is reused, the quote is reused from the friend's
# library, and it is sent only once the friendship is accepted (each run sends it again). Without
# --accept or --wait, run it again after accepting in the app.
#
# Environment:
#   SUPABASE_URL       default http://127.0.0.1:54321
#   LOCAL_SECRET_KEY   default: the local stack's demo secret key
#   LOCAL_PUBLISHABLE_KEY  default: the local stack's demo publishable key
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_SECRET_KEY="${LOCAL_SECRET_KEY:-sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz}"
LOCAL_PUBLISHABLE_KEY="${LOCAL_PUBLISHABLE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# --- Safety: local stack only -------------------------------------------------------------------
case "$SUPABASE_URL" in
  http://127.0.0.1:* | http://127.0.0.1 | http://localhost:* | http://localhost) ;;
  *) die "refusing to run against '$SUPABASE_URL': this script only talks to the local stack (http://127.0.0.1)." ;;
esac
[[ "$LOCAL_SECRET_KEY" == sb_secret_* ]] || die "LOCAL_SECRET_KEY must be the local stack's sb_secret_ key."
command -v jq >/dev/null || die "jq is required (brew install jq)."
command -v openssl >/dev/null || die "openssl is required."

# --- Arguments ----------------------------------------------------------------------------------
TARGET=""
FRIEND="maya"
NAME="Maya Reyes"
ACCEPT=0
WAIT=0
SHARE=1
REMOVE=0
QUOTE_BODY="There is a stubbornness about me that never can bear to be frightened at the will of others. My courage always rises at every attempt to intimidate me."
QUOTE_AUTHOR="Jane Austen"
QUOTE_SOURCE="Pride and Prejudice"
NOTE="Thought of you"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --friend) FRIEND="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --accept) ACCEPT=1; shift ;;
    --wait) WAIT="${2:?}"; shift 2 ;;
    --no-share) SHARE=0; shift ;;
    --quote) QUOTE_BODY="${2:?}"; shift 2 ;;
    --author) QUOTE_AUTHOR="${2:?}"; shift 2 ;;
    --source) QUOTE_SOURCE="${2:?}"; shift 2 ;;
    --note) NOTE="${2-}"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h | --help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [[ -z "$TARGET" ]] || die "only one username, please"; TARGET="${1#@}"; shift ;;
  esac
done

FRIEND="${FRIEND#@}"
[[ "$FRIEND" =~ ^[a-z0-9_.]{3,20}$ ]] || die "invalid friend username '$FRIEND'"
[[ "$WAIT" =~ ^[0-9]+$ ]] || die "--wait takes whole seconds"
FRIEND_EMAIL="${FRIEND//./-}@quoted.local"

# --- HTTP helpers -------------------------------------------------------------------------------
# admin METHOD PATH [JSON]: secret-key request (auth admin API or PostgREST, bypasses RLS).
admin() {
  local method="$1" path="$2" body="${3-}"
  curl --silent --show-error --fail-with-body --max-time 15 -X "$method" "$SUPABASE_URL$path" \
    -H "apikey: $LOCAL_SECRET_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=representation" ${body:+--data "$body"}
}

# as_friend METHOD PATH [JSON]: PostgREST as the friend (RLS applies). Prints the body, a newline
# and the HTTP status.
as_friend() {
  local method="$1" path="$2" body="${3-}"
  curl --silent --show-error --max-time 15 -X "$method" "$SUPABASE_URL$path" \
    -H "apikey: $LOCAL_PUBLISHABLE_KEY" -H "Authorization: Bearer $FRIEND_TOKEN" \
    -H "Content-Type: application/json" -H "Prefer: return=representation" \
    -w '\n%{http_code}' ${body:+--data "$body"}
}

# Prints the auth user ID for an email, or nothing.
user_id_for_email() {
  admin GET "/auth/v1/admin/users?per_page=1000" |
    jq -r --arg email "$1" '.users[] | select(.email == $email) | .id' | head -n 1
}

curl --silent --fail --max-time 5 "$SUPABASE_URL/auth/v1/health" -H "apikey: $LOCAL_PUBLISHABLE_KEY" >/dev/null ||
  die "the local stack is not reachable at $SUPABASE_URL (run 'supabase start')."

# --- Remove -------------------------------------------------------------------------------------
if [[ $REMOVE -eq 1 ]]; then
  FRIEND_ID="$(user_id_for_email "$FRIEND_EMAIL")"
  if [[ -z "$FRIEND_ID" ]]; then
    log "No local account for @$FRIEND ($FRIEND_EMAIL); nothing to remove."
  else
    admin DELETE "/auth/v1/admin/users/$FRIEND_ID" >/dev/null
    log "Deleted @$FRIEND ($FRIEND_EMAIL) and everything it owned."
  fi
  exit 0
fi

[[ -n "$TARGET" ]] || die "usage: scripts/seed-local-friend.sh <their-username> [options] (see --help)"
[[ "$TARGET" =~ ^[a-z0-9_.]{3,20}$ ]] || die "invalid username '$TARGET'"
[[ "$TARGET" != "$FRIEND" ]] || die "the friend can't befriend themselves; pick another --friend"

# --- Target -------------------------------------------------------------------------------------
TARGET_ID="$(admin GET "/rest/v1/profiles?username=eq.$TARGET&select=id" | jq -r '.[0].id // empty')"
[[ -n "$TARGET_ID" ]] || die "no local profile named @$TARGET (finish the Username step in the app first)."

# --- Friend account (created or reused, with a fresh random password) ---------------------------
FRIEND_PASSWORD="$(openssl rand -base64 18)"
FRIEND_ID="$(user_id_for_email "$FRIEND_EMAIL")"
if [[ -z "$FRIEND_ID" ]]; then
  FRIEND_ID="$(admin POST /auth/v1/admin/users \
    "$(jq -n --arg e "$FRIEND_EMAIL" --arg p "$FRIEND_PASSWORD" '{email: $e, password: $p, email_confirm: true}')" |
    jq -r '.id')"
  log "Created @$FRIEND ($FRIEND_EMAIL)."
else
  admin PUT "/auth/v1/admin/users/$FRIEND_ID" "$(jq -n --arg p "$FRIEND_PASSWORD" '{password: $p}')" >/dev/null
  log "Reusing @$FRIEND ($FRIEND_EMAIL)."
fi

FRIEND_TOKEN="$(curl --silent --show-error --fail-with-body --max-time 15 \
  -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $LOCAL_PUBLISHABLE_KEY" -H "Content-Type: application/json" \
  --data "$(jq -n --arg e "$FRIEND_EMAIL" --arg p "$FRIEND_PASSWORD" '{email: $e, password: $p}')" |
  jq -r '.access_token')"
[[ -n "$FRIEND_TOKEN" && "$FRIEND_TOKEN" != "null" ]] || die "could not sign in as @$FRIEND"

# Profile (insert own row; reuse when it exists).
EXISTING_PROFILE="$(admin GET "/rest/v1/profiles?id=eq.$FRIEND_ID&select=username" | jq -r '.[0].username // empty')"
if [[ -z "$EXISTING_PROFILE" ]]; then
  response="$(as_friend POST "/rest/v1/profiles?select=id" \
    "$(jq -n --arg id "$FRIEND_ID" --arg u "$FRIEND" --arg n "$NAME" '{id: $id, username: $u, display_name: $n}')")"
  [[ "${response##*$'\n'}" == 201 ]] || die "could not create the @$FRIEND profile: ${response%$'\n'*}"
elif [[ "$EXISTING_PROFILE" != "$FRIEND" ]]; then
  die "$FRIEND_EMAIL already has the username @$EXISTING_PROFILE"
fi

# --- Terms of Use (friend requests and messages need the current version) -----------------------
response="$(as_friend POST /rest/v1/rpc/my_account '{}')"
[[ "${response##*$'\n'}" == 200 ]] || die "could not read @$FRIEND's account: ${response%$'\n'*}"
ACCOUNT="${response%$'\n'*}"
CURRENT_TERMS="$(jq -r '.[0].current_terms_version' <<<"$ACCOUNT")"
if [[ "$(jq -r '.[0].terms_version // 0' <<<"$ACCOUNT")" != "$CURRENT_TERMS" ]]; then
  response="$(as_friend POST /rest/v1/rpc/accept_terms "$(jq -n --argjson v "$CURRENT_TERMS" '{p_version: $v}')")"
  [[ "${response##*$'\n'}" =~ ^20[04]$ ]] || die "could not accept the terms as @$FRIEND: ${response%$'\n'*}"
  log "@$FRIEND accepted the Terms of Use (version $CURRENT_TERMS)."
fi

# --- Friend request -----------------------------------------------------------------------------
pair_filter="or=(and(requester_id.eq.$FRIEND_ID,addressee_id.eq.$TARGET_ID),and(requester_id.eq.$TARGET_ID,addressee_id.eq.$FRIEND_ID))"
friendship() { admin GET "/rest/v1/friendships?$pair_filter&select=id,status"; }

FRIENDSHIP="$(friendship)"
if [[ "$(jq 'length' <<<"$FRIENDSHIP")" == 0 ]]; then
  response="$(as_friend POST "/rest/v1/friendships?select=id" "$(jq -n --arg a "$TARGET_ID" '{addressee_id: $a}')")"
  [[ "${response##*$'\n'}" == 201 ]] || die "could not send the friend request: ${response%$'\n'*}"
  FRIENDSHIP="$(friendship)"
  log "@$FRIEND sent @$TARGET a friend request."
fi
FRIENDSHIP_ID="$(jq -r '.[0].id' <<<"$FRIENDSHIP")"
STATUS="$(jq -r '.[0].status' <<<"$FRIENDSHIP")"

if [[ "$STATUS" != accepted && $ACCEPT -eq 1 ]]; then
  admin PATCH "/rest/v1/friendships?id=eq.$FRIENDSHIP_ID" '{"status":"accepted"}' >/dev/null
  STATUS=accepted
  log "Accepted the request with the local secret key."
fi

if [[ "$STATUS" != accepted && $WAIT -gt 0 ]]; then
  log "Waiting up to ${WAIT}s for @$TARGET to accept in the app..."
  deadline=$((SECONDS + WAIT))
  while [[ $SECONDS -lt $deadline ]]; do
    STATUS="$(friendship | jq -r '.[0].status // "gone"')"
    [[ "$STATUS" == pending ]] || break
    sleep 2
  done
fi

case "$STATUS" in
  accepted) log "@$FRIEND and @$TARGET are friends." ;;
  pending)
    if [[ $SHARE -eq 1 ]]; then
      log "The request is pending. Accept it in Quoted (Friends tab), then run this again to share a quote."
    else
      log "The request is pending; accept or decline it in Quoted (Friends tab)."
    fi
    exit 0 ;;
  *) die "the request was declined or removed." ;;
esac

# --- Send a quote -------------------------------------------------------------------------------
if [[ $SHARE -eq 1 ]]; then
  # The quote, from the friend's library (added once; the server makes the friend its creator).
  response="$(as_friend GET "/rest/v1/quotes?select=id,body,author,source")"
  [[ "${response##*$'\n'}" == 200 ]] || die "could not read @$FRIEND's library: ${response%$'\n'*}"
  QUOTE_ID="$(jq -r --arg b "$QUOTE_BODY" --arg a "$QUOTE_AUTHOR" --arg s "$QUOTE_SOURCE" \
    'def opt: if . == "" then null else . end;
     [.[] | select(.body == $b and .author == ($a | opt) and .source == ($s | opt))][0].id // empty' <<<"${response%$'\n'*}")"
  if [[ -z "$QUOTE_ID" ]]; then
    payload="$(jq -n --arg b "$QUOTE_BODY" --arg a "$QUOTE_AUTHOR" --arg s "$QUOTE_SOURCE" \
      'def opt: if . == "" then null else . end;
       {body: $b, body_format: [], author: ($a | opt), source: ($s | opt), origin: "manual"}')"
    response="$(as_friend POST "/rest/v1/quotes?select=id" "$payload")"
    [[ "${response##*$'\n'}" == 201 ]] || die "could not add the quote to @$FRIEND's library: ${response%$'\n'*}"
    QUOTE_ID="$(jq -r '.[0].id' <<<"${response%$'\n'*}")"
  fi

  # Their conversation (made, or reopened, for accepted friends), then the quote message.
  response="$(as_friend POST "/rest/v1/rpc/open_conversation?select=id" "$(jq -n --arg f "$TARGET_ID" '{p_friend: $f}')")"
  [[ "${response##*$'\n'}" == 200 ]] || die "could not open the conversation: ${response%$'\n'*}"
  CONVERSATION_ID="$(jq -r 'if type == "array" then .[0].id else .id end' <<<"${response%$'\n'*}")"
  payload="$(jq -n --arg c "$CONVERSATION_ID" --arg q "$QUOTE_ID" --arg n "$NOTE" \
    'def opt: if . == "" then null else . end;
     {conversation_id: $c, kind: "quote", source_quote_id: $q} + (if ($n | opt) == null then {} else {note: $n} end)')"
  response="$(as_friend POST "/rest/v1/messages?select=id" "$payload")"
  [[ "${response##*$'\n'}" == 201 ]] || die "could not send the quote: ${response%$'\n'*}"
  log "@$FRIEND sent @$TARGET a quote."
fi
