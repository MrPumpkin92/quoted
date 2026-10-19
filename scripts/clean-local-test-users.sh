#!/usr/bin/env bash
# Delete the throwaway accounts the UI tests create on the LOCAL Supabase stack
# (uitest-<time>@quoted.local). Deleting an auth user cascades to its profile, quotes,
# friendships and shares. Reports outlive account deletion by design (their user ids become
# null, for moderation), so on the local stack the script then deletes every report that lost
# its reporter or its reported user: test leftovers, from these accounts or from other test
# runs that deleted their users.
#
# LOCAL STACK ONLY: refuses any URL that is not http://127.0.0.1 or http://localhost.
#
# Usage:
#   scripts/clean-local-test-users.sh            # delete every uitest-*@quoted.local account
#   scripts/clean-local-test-users.sh --dry-run  # list them only
#
# Environment: SUPABASE_URL (default http://127.0.0.1:54321), LOCAL_SECRET_KEY (default: the local
# stack's demo secret key).
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
LOCAL_SECRET_KEY="${LOCAL_SECRET_KEY:-sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz}"
PATTERN='^uitest-[0-9]+@quoted\.local$'
DRY_RUN=0
[[ "${1-}" == "--dry-run" ]] && DRY_RUN=1

die() { echo "error: $*" >&2; exit 1; }
case "$SUPABASE_URL" in
  http://127.0.0.1:* | http://127.0.0.1 | http://localhost:* | http://localhost) ;;
  *) die "refusing to run against '$SUPABASE_URL': this script only talks to the local stack (http://127.0.0.1)." ;;
esac
[[ "$LOCAL_SECRET_KEY" == sb_secret_* ]] || die "LOCAL_SECRET_KEY must be the local stack's sb_secret_ key."
command -v jq >/dev/null || die "jq is required (brew install jq)."

users="$(curl --silent --show-error --fail-with-body --max-time 15 \
  "$SUPABASE_URL/auth/v1/admin/users?per_page=1000" -H "apikey: $LOCAL_SECRET_KEY" |
  jq -r --arg pattern "$PATTERN" '.users[] | select(.email != null and (.email | test($pattern))) | "\(.id) \(.email)"')"

if [[ -z "$users" ]]; then
  echo "==> No UI test accounts on the local stack."
else
  count=0
  while read -r id email; do
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "would delete $email"
    else
      curl --silent --show-error --fail-with-body --max-time 15 -X DELETE \
        "$SUPABASE_URL/auth/v1/admin/users/$id" -H "apikey: $LOCAL_SECRET_KEY" >/dev/null
      echo "deleted $email"
    fi
    count=$((count + 1))
  done <<<"$users"
  echo "==> $count UI test account(s) $([[ $DRY_RUN -eq 1 ]] && echo found || echo deleted)."
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
