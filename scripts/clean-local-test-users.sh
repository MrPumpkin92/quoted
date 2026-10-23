#!/usr/bin/env bash
# Delete the throwaway accounts the UI tests leave on the LOCAL Supabase stack:
#   - anonymous accounts whose username is ui<digits> (testHappyPath, one per run);
#   - uitest-<time>@quoted.local email accounts (from runs before the app dropped sign-in);
#   - with --anonymous-orphans, also anonymous accounts that never chose a username: a run that
#     stopped before Username, the new account after the QA flow's Delete account, or any app reset.
#     This includes a simulator sitting on "Choose a username" right now. That app keeps using its
#     unexpired access token (jwt_expiry is 1 hour locally), so Continue fails until the token's
#     refresh fails and the app starts over with a new account. Reset that simulator instead of
#     waiting: uninstall the app, or launch it with -UITestReset.
# Deleting an auth user cascades to its profile, quotes, friendships and shares. Reports outlive
# account deletion by design (their user ids become null, for moderation), so on the local stack the
# script then deletes every report that lost its reporter or its reported user: test leftovers, from
# these accounts or from other test runs that deleted their users.
#
# LOCAL STACK ONLY: refuses any URL that is not http://127.0.0.1 or http://localhost.
#
# Usage:
#   scripts/clean-local-test-users.sh                      # delete the UI test accounts
#   scripts/clean-local-test-users.sh --dry-run            # list them only
#   scripts/clean-local-test-users.sh --anonymous-orphans  # also anonymous accounts with no username
#
# Environment: SUPABASE_URL (default http://127.0.0.1:54321), LOCAL_SECRET_KEY (default: the local
# stack's demo secret key).
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_SECRET_KEY="${LOCAL_SECRET_KEY:-sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz}"
EMAIL_PATTERN='^uitest-[0-9]+@quoted\.local$'
USERNAME_PATTERN='^ui[0-9]+$'
PAGE=1000

die() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
ORPHANS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --anonymous-orphans) ORPHANS=1 ;;
    *) die "unknown option '$arg' (use --dry-run and/or --anonymous-orphans)." ;;
  esac
done

case "$SUPABASE_URL" in
  http://127.0.0.1:* | http://127.0.0.1 | http://localhost:* | http://localhost) ;;
  *) die "refusing to run against '$SUPABASE_URL': this script only talks to the local stack (http://127.0.0.1)." ;;
esac
[[ "$LOCAL_SECRET_KEY" == sb_secret_* ]] || die "LOCAL_SECRET_KEY must be the local stack's sb_secret_ key."
command -v jq >/dev/null || die "jq is required (brew install jq)."

# GET with the secret key (it bypasses RLS).
get() {
  curl --silent --show-error --fail-with-body --max-time 15 "$SUPABASE_URL$1" -H "apikey: $LOCAL_SECRET_KEY"
}

# Every auth user as a JSON array of {id, email, is_anonymous}; the admin API returns them a page at
# a time. (`|| exit 1`: set -e does not reach inside a command substitution.)
list_users() {
  local page=1 batch
  while :; do
    batch="$(get "/auth/v1/admin/users?page=$page&per_page=$PAGE")" || exit 1
    jq -c '.users[] | {id, email, is_anonymous}' <<<"$batch" || exit 1
    (($(jq '.users | length' <<<"$batch") < PAGE)) && break
    page=$((page + 1))
  done | jq -s '.'
}

# Every profile as a JSON array of {id, username}, a page at a time (PostgREST's max_rows is 1000).
list_profiles() {
  local offset=0 batch
  while :; do
    batch="$(get "/rest/v1/profiles?select=id,username&order=id&limit=$PAGE&offset=$offset")" || exit 1
    jq -c '.[]' <<<"$batch" || exit 1
    (($(jq 'length' <<<"$batch") < PAGE)) && break
    offset=$((offset + PAGE))
  done | jq -s '.'
}

users="$(list_users)" || die "could not list the auth users on $SUPABASE_URL."
profiles="$(list_profiles)" || die "could not list the profiles on $SUPABASE_URL."

# One line per account: "<id> <kind> <label>", kind being test (always deleted) or orphan (an
# anonymous account with no profile, deleted only with --anonymous-orphans).
accounts="$(printf '%s\n%s\n' "$users" "$profiles" | jq -rs --arg email "$EMAIL_PATTERN" --arg username "$USERNAME_PATTERN" '
  (.[1] | map({key: .id, value: .username}) | from_entries) as $names
  | .[0][]
  | $names[.id] as $name
  | if ((.email // "") | test($email)) then "\(.id) test \(.email)"
    elif .is_anonymous != true then empty
    elif $name == null then "\(.id) orphan anonymous \(.id) (no username)"
    elif ($name | test($username)) then "\(.id) test anonymous @\($name)"
    else empty end')"

count=0
skipped=0
while read -r id kind label; do
  [[ -n "$id" ]] || continue
  if [[ "$kind" == orphan && $ORPHANS -eq 0 ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "would delete $label"
  else
    curl --silent --show-error --fail-with-body --max-time 15 -X DELETE \
      "$SUPABASE_URL/auth/v1/admin/users/$id" -H "apikey: $LOCAL_SECRET_KEY" >/dev/null
    echo "deleted $label"
  fi
  count=$((count + 1))
done <<<"$accounts"

if [[ $count -eq 0 ]]; then
  echo "==> No UI test accounts on the local stack."
else
  echo "==> $count account(s) $([[ $DRY_RUN -eq 1 ]] && echo found || echo deleted)."
fi
if [[ $skipped -gt 0 ]]; then
  echo "==> $skipped anonymous account(s) with no username kept; --anonymous-orphans deletes them."
fi

# Reports whose reporter or reported user was deleted (secret key: bypasses RLS).
orphans_filter='or=(reporter_id.is.null,reported_user_id.is.null)'
if [[ $DRY_RUN -eq 1 ]]; then
  orphans="$(curl --silent --show-error --fail-with-body --max-time 15 \
    "$SUPABASE_URL/rest/v1/reports?$orphans_filter&select=id" -H "apikey: $LOCAL_SECRET_KEY" | jq 'length')"
  echo "==> $orphans report(s) left by deleted accounts would be deleted."
else
  orphans="$(curl --silent --show-error --fail-with-body --max-time 15 -X DELETE \
    "$SUPABASE_URL/rest/v1/reports?$orphans_filter" -H "apikey: $LOCAL_SECRET_KEY" \
    -H "Prefer: return=representation" | jq 'length')"
  echo "==> $orphans report(s) left by deleted accounts deleted."
fi
