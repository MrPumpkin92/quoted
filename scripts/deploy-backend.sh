#!/usr/bin/env bash
# Deploy the Quoted backend to the hosted Supabase project.
#
# FOUNDER ONLY. Run this yourself from a terminal; agents never run it.
# It talks to the hosted project, applies migrations and deploys functions.
#
#   1. Checks the Supabase CLI, refuses to deploy uncommitted changes under
#      supabase/ (FORCE_DIRTY=1 overrides) and logs you in if needed (browser
#      flow).
#   2. Links this repo to project yyajndbishiyugtbpzmk for this run only: on
#      exit, even a failed or cancelled one, `supabase unlink` removes the link,
#      so a later `supabase db push` or `migration list` can't reach production
#      by default. Unlink deletes supabase/.temp (the link files and the CLI's
#      local cache, which `supabase start` recreates) and any database
#      password the CLI saved in the keychain.
#   3. Shows the pending migrations and what to check before applying them,
#      asks you to confirm, then runs `supabase db push` (your database
#      password is asked for interactively and only passed to the CLI through
#      its environment, never stored).
#   4. Deploys the delete-account Edge Function (verify_jwt from config.toml).
#   5. Runs the security advisors against the hosted database (read only).
#   6. Prints the release checklist of dashboard steps the CLI cannot do:
#      anonymous sign-ins (required: the app creates every account this way)
#      and their rate limit; the email steps, needed only when email sign-in
#      returns (custom SMTP, email rate limit and templates, the Site URL and
#      redirect URL, "Confirm email"); the App Review helper account; and the
#      daily report check. The same list is in docs/system-design.md section 10.
#
# Usage:
#   scripts/deploy-backend.sh
#   SUPABASE_ACCESS_TOKEN=sbp_... scripts/deploy-backend.sh   # scoped token instead of browser login
#   FORCE_DIRTY=1 scripts/deploy-backend.sh   # deploy uncommitted supabase/ changes (git won't record them)
#
# Commit supabase/ first, after `supabase test db` (or scripts/test.sh) passes on the local stack, so
# git records exactly what production runs.
set -euo pipefail

PROJECT_REF="yyajndbishiyugtbpzmk"
FUNCTION_NAME="delete-account"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- 1. CLI and login -------------------------------------------------------
step "Checking the Supabase CLI"
command -v supabase >/dev/null 2>&1 || die "the Supabase CLI is not installed. Install it with: brew install supabase/tap/supabase"
supabase --version
[[ -f supabase/config.toml ]] || die "run this from the Quoted repo (supabase/config.toml not found)"

# db push and functions deploy read migrations, the function and config.toml (verify_jwt) from the
# working tree. Deploy only what git records, so the next migration or a rollback starts from a
# known schema.
step "Checking that supabase/ is committed"
command -v git >/dev/null 2>&1 || die "git is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT is not a git checkout"
dirty="$(git status --porcelain --untracked-files=all -- supabase)" || die "git status failed"
if [[ -n "$dirty" ]]; then
  printf '%s\n' "$dirty"
  if [[ "${FORCE_DIRTY:-0}" == "1" ]]; then
    echo "FORCE_DIRTY=1: deploying these uncommitted changes. Git will not record what production runs."
  else
    die "supabase/ has uncommitted changes (above). Commit them once supabase test db passes, or rerun with FORCE_DIRTY=1."
  fi
fi
DEPLOYED_FROM="commit $(git rev-parse --short HEAD)"
[[ -z "$dirty" ]] || DEPLOYED_FROM+=" plus uncommitted changes"
echo "Deploying $DEPLOYED_FROM: $(git log -1 --format=%s)"

step "Checking that you are logged in"
if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "Using SUPABASE_ACCESS_TOKEN from the environment."
elif supabase projects list >/dev/null 2>&1; then
  echo "Already logged in."
else
  echo "Not logged in. Opening the browser login (creates a token with full account access;"
  echo "for CI prefer a scoped personal access token in SUPABASE_ACCESS_TOKEN)."
  supabase login
fi

# ---- 2. Link -----------------------------------------------------------------
# The database password is needed by link and db push. Read it once, silently.
if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  step "Database password"
  echo "Find or reset it in the dashboard: Project Settings > Database."
  read -r -s -p "Database password for $PROJECT_REF: " SUPABASE_DB_PASSWORD
  echo
  [[ -n "$SUPABASE_DB_PASSWORD" ]] || die "no password entered"
fi
export SUPABASE_DB_PASSWORD

# The link lasts only while this script runs (see the header). `exit` on a signal makes the EXIT
# trap run after Ctrl-C too.
cleanup() {
  unset SUPABASE_DB_PASSWORD
  if [[ -f supabase/.temp/project-ref ]]; then
    if supabase unlink >/dev/null 2>&1; then
      echo "Unlinked this repo from $PROJECT_REF."
    else
      echo "warning: supabase unlink failed. Run it yourself so later commands don't target $PROJECT_REF." >&2
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

step "Linking to project $PROJECT_REF"
supabase link --project-ref "$PROJECT_REF"

# ---- 3. Migrations -----------------------------------------------------------
step "Pending migrations (dry run)"
if ! dry_run="$(supabase db push --linked --dry-run 2>&1)"; then
  printf '%s\n' "$dry_run"
  die "the dry run failed; nothing was pushed"
fi
printf '%s\n' "$dry_run"

step "Before you apply"
cat <<'CHECKS'
  - Check the list above is what you expect. Each migration runs once, in
    order, inside its own transaction; a failure rolls that migration back.
  - Pushing changes the database only. Anonymous sign-ins, the Auth email
    settings and the App Review helper account are dashboard steps; that
    checklist prints when the deploy is done.
CHECKS
if grep -q '20261019060000_hardening' <<<"$dry_run"; then
  cat <<'CHECKS'
  - 20261019060000_hardening:
      * drops events.user_id: existing "Search the web" tap rows become
        anonymous (only the event name and the hour stay);
      * keeps reports when the reporter or the reported user deletes their
        account (the id becomes null; the snapshot and username stay);
      * clears blank display names, notes, authors and sources, and resets
        invalid body_format values to [] before adding the new checks;
      * fails if a quote or share body is only whitespace. The error names
        the constraint (quotes_body_not_blank or shares_body_not_blank): fix
        or delete those rows in the SQL editor, then run this script again.
CHECKS
fi
if grep -q '_catalog_corpus' <<<"$dry_run"; then
  cat <<'CHECKS'
  - 20261028120000_catalog_corpus (the verified catalog, M1):
      * renames starter_quotes to catalog_quotes and leaves a starter_quotes
        view of the 60 live starters, so builds up to 6 keep onboarding as
        before. PostgREST reloads its schema at the end; an app open at that
        moment may retry onboarding once;
      * widens the catalog ids to integer, which rewrites the quotes and shares
        tables under a brief lock: every read and write waits for it. Deploy at
        a quiet hour;
      * adds no new quotes. Batches come later, each in its own migration.
CHECKS
fi
if grep -q '_catalog_batch_' <<<"$dry_run"; then
  cat <<'CHECKS'
  - catalog batches (*_catalog_batch_NNN): new verified quotes.
      * Deploy only after a TestFlight build with the catalog client is up:
        on builds up to 6, a newly sealed quote's Verified sheet has no
        location or link.
      * Each batch fails as a whole if any of its ids is already stored with
        different text (insert-or-verify, never update), then reseals users'
        matching quotes and shares. App writes to quotes wait for the reseal
        (seconds). The report to read is supabase/catalog/batches/NNN.md.
CHECKS
fi
if grep -q '_catalog_withdraw_' <<<"$dry_run"; then
  cat <<'CHECKS'
  - catalog withdrawals (*_catalog_withdraw_<id>): the seal comes off that
    quote in every user's library and inbox at their next refresh, and it
    leaves onboarding if it was a starter. The evidence belongs in
    docs/catalog-sources.md before you push.
CHECKS
fi

read -r -p "Apply these migrations to $PROJECT_REF? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || die "cancelled; nothing was pushed"

step "Applying migrations"
supabase db push --linked

# ---- 4. Edge Function --------------------------------------------------------
step "Deploying the $FUNCTION_NAME Edge Function"
supabase functions deploy "$FUNCTION_NAME" --project-ref "$PROJECT_REF"

# ---- 5. Security advisors ----------------------------------------------------
step "Security advisors (hosted, read only)"
if ! supabase db advisors --linked --type security; then
  echo "Could not run the advisors from the CLI. Check them in the dashboard (the Security Advisor step of the checklist below)."
fi

# ---- 6. Release checklist ----------------------------------------------------
DASHBOARD="https://supabase.com/dashboard/project/$PROJECT_REF"
cat <<CHECKLIST

==> Backend deployed from $DEPLOYED_FROM. Before release, finish these steps in the dashboard
    (the same list is in docs/system-design.md section 10):

  1. Anonymous sign-ins. REQUIRED: the app creates every account this way.
     Under Authentication > Sign In / Providers, turn on
       Allow anonymous sign-ins
     Without it every new install stops on the launch screen with "Quoted
     can't create your account right now: anonymous sign-ins are turned off
     on the server." ($DASHBOARD/auth/providers)
     Then check the limit for anonymous sign-ins under Authentication >
     Rate Limits: 30 an hour per IP by default, shared by everyone on one
     network (testers in one office, for example).
     ($DASHBOARD/auth/rate-limits)

  Steps 2-6 are needed only when email sign-in returns
  (AccountMode.emailPassword in App/Stores/SessionStore.swift). Skip them
  while accounts are anonymous.

  2. Custom SMTP (only when email sign-in returns; then REQUIRED before
     anyone outside your team signs up).
     Supabase's built-in email only delivers to members of your Supabase
     team, about 2 emails an hour, so sign-up confirmation and "Forgot
     password?" fail for everyone else ("Email address not authorized").
     Create an account with an email provider (Resend, Postmark or Amazon
     SES), verify your sending domain (its SPF and DKIM records), then fill
     in host, port, username, password, sender name (Quoted) and sender
     address (no-reply@<your domain>) under Authentication > SMTP Settings.
     ($DASHBOARD/auth/smtp)

  3. Email rate limit (only when email sign-in returns). With custom SMTP
     the limit starts at 30 emails an hour; raise it to what you expect at
     launch under Authentication > Rate Limits.
     ($DASHBOARD/auth/rate-limits)

  4. Email templates (only when email sign-in returns). Reword "Confirm
     sign up" and "Reset password" so they name Quoted, and keep
     {{ .ConfirmationURL }} in both.
     ($DASHBOARD/auth/templates)

  5. URL Configuration (only when email sign-in returns). Under
     Authentication > URL Configuration set
       Site URL:       quoted://auth-callback
       Redirect URLs:  add quoted://auth-callback (exactly: lowercase, no
                       trailing slash, no spaces)
     The app asks Auth to send email links back to quoted://auth-callback.
     Auth accepts that only if it is on the Redirect URLs list; otherwise it
     silently uses the Site URL, which starts as http://localhost:3000. That
     is why an unconfigured project sends confirmation links to localhost.
     Check: request a new email (old ones keep the redirect they were sent
     with), long-press the button in Mail and copy the link. It must end in
     redirect_to=quoted://auth-callback. Set these here, never with
     \`supabase config push\`: that copies the local site_url to hosted.
     ($DASHBOARD/auth/url-configuration)

  6. "Confirm email" (only when email sign-in returns). Decide under
     Authentication > Sign In / Providers > Email. Recommended: on for
     release, and only after steps 2-5 work. Then test sign-up and "Forgot
     password?" end to end with an address that is NOT on your Supabase
     team. Open each link within 5 minutes of requesting it: after that the
     app cannot finish signing in from the link (a confirmed sign-up can
     still sign in with its password).
     ($DASHBOARD/auth/providers)

  7. App Review helper account. There is no login, so there is no demo
     account: in App Store Connect > App Review Information, untick
     "Sign-in required". Report and Block need another person, so install
     the TestFlight build on an iPhone you keep, choose a username (for
     example quotedhelper), add a few quotes and leave the app installed
     (deleting it loses the account). The reviewer adds that username from
     Friends. Review notes: docs/app-store-submission.md section 8.

  8. Daily report check (the app promises review within 24 hours).
     In the SQL editor ($DASHBOARD/sql):
       select * from private.reports_to_review;
     Act on each report (delete the content, or the account under
     Authentication > Users), then mark it done:
       update public.reports set reviewed_at = now() where id = '<id>';
     While accounts are anonymous, a person whose account you delete can
     reinstall the app and get a new account, with a new username that no
     earlier block covers.
     Optional alert: Integrations > Database Webhooks, on INSERT into
     public.reports, POST to an endpoint you control (for example an email
     or Slack workflow). The payload carries the whole report row, content
     included, so send it only somewhere you trust.
     ($DASHBOARD/integrations/webhooks/overview)

  9. Security Advisor. Under Advisors > Security Advisor, once anonymous
     sign-ins are on, expect the INFO entry "Anonymous sign-ins enabled"
     (0012_auth_allow_anonymous_sign_ins). The policies deliberately don't
     check is_anonymous, so anonymous users get exactly the access of any
     other user; supabase/tests/database/10_anonymous_user.test.sql proves
     it. That entry is expected and accepted: don't add is_anonymous checks
     or turn anonymous sign-ins off to clear it. Fix any other finding.
     ($DASHBOARD/advisors/security)

  10. Settings > API Keys: copy the publishable key (sb_publishable_...)
      into the app's hosted config. Never put a secret key in the app.
      ($DASHBOARD/settings/api-keys)

CHECKLIST
