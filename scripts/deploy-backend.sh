#!/usr/bin/env bash
# Deploy the Quoted backend to the hosted Supabase project.
#
# FOUNDER ONLY. Run this yourself from a terminal; agents never run it.
# It talks to the hosted project, applies migrations and deploys functions.
#
#   1. Checks the Supabase CLI and logs you in if needed (browser flow).
#   2. Links this repo to project yyajndbishiyugtbpzmk.
#   3. Shows the pending migrations and what to check before applying them,
#      asks you to confirm, then runs `supabase db push` (your database
#      password is asked for interactively and only passed to the CLI through
#      its environment, never stored).
#   4. Deploys the delete-account Edge Function (verify_jwt from config.toml).
#   5. Runs the security advisors against the hosted database (read only).
#   6. Prints the release checklist of dashboard steps the CLI cannot do:
#      custom SMTP (required: the built-in email only reaches your own
#      Supabase team), email rate limit and templates, the redirect URL,
#      "Confirm email", the App Review demo account and the daily report
#      check. The same list is in docs/system-design.md section 10.
#
# Usage:
#   scripts/deploy-backend.sh
#   SUPABASE_ACCESS_TOKEN=sbp_... scripts/deploy-backend.sh   # scoped token instead of browser login
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
trap 'unset SUPABASE_DB_PASSWORD' EXIT

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
  - Pushing changes the database only. Auth email (SMTP), redirect URLs and
    the App Review demo account are dashboard steps; that checklist prints
    when the deploy is done.
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
  echo "Could not run the advisors from the CLI. Check them in the dashboard (step 8 below)."
fi

# ---- 6. Release checklist ----------------------------------------------------
DASHBOARD="https://supabase.com/dashboard/project/$PROJECT_REF"
cat <<CHECKLIST

==> Backend deployed. Before release, finish these steps in the dashboard
    (the same list is in docs/system-design.md section 10):

  1. Custom SMTP. REQUIRED before anyone outside your team signs up.
     Supabase's built-in email only delivers to members of your Supabase
     team, about 2 emails an hour, so sign-up confirmation and "Forgot
     password?" fail for everyone else ("Email address not authorized").
     Create an account with an email provider (Resend, Postmark or Amazon
     SES), verify your sending domain (its SPF and DKIM records), then fill
     in host, port, username, password, sender name (Quoted) and sender
     address (no-reply@<your domain>) under Authentication > SMTP Settings.
     ($DASHBOARD/auth/smtp)

  2. Email rate limit. With custom SMTP the limit starts at 30 emails an
     hour; raise it to what you expect at launch under Authentication >
     Rate Limits. ($DASHBOARD/auth/rate-limits)

  3. Email templates. Reword "Confirm sign up" and "Reset password" so they
     name Quoted, and keep {{ .ConfirmationURL }} in both.
     ($DASHBOARD/auth/templates)

  4. Redirect URL. Authentication > URL Configuration > Redirect URLs: add
       quoted://auth-callback
     ($DASHBOARD/auth/url-configuration)

  5. "Confirm email". Decide under Authentication > Sign In / Providers >
     Email. Recommended: on for release, and only after steps 1-4 work.
     Then test sign-up and "Forgot password?" end to end with an address
     that is NOT on your Supabase team.
     ($DASHBOARD/auth/providers)

  6. App Review demo account. Authentication > Users > Add user, with
     "Auto Confirm User" ticked, an address you control and a strong
     password. Sign in on a device, pick a username, add a few quotes, and
     have a second account befriend it and share a quote, so the reviewer
     can reach Friends, Shared with you, Report and Block. Enter the email
     and password in App Store Connect > App Review Information; never
     commit them.
     ($DASHBOARD/auth/users)

  7. Daily report check (the app promises review within 24 hours).
     In the SQL editor ($DASHBOARD/sql):
       select * from private.reports_to_review;
     Act on each report (delete the content, or the account under
     Authentication > Users), then mark it done:
       update public.reports set reviewed_at = now() where id = '<id>';
     Optional alert: Integrations > Database Webhooks, on INSERT into
     public.reports, POST to an endpoint you control (for example an email
     or Slack workflow). The payload carries the whole report row, content
     included, so send it only somewhere you trust.
     ($DASHBOARD/integrations/webhooks/overview)

  8. Advisors > Security Advisor should show no findings.
     ($DASHBOARD/advisors/security)

  9. Settings > API Keys: copy the publishable key (sb_publishable_...) into
     the app's hosted config. Never put a secret key in the app.
     ($DASHBOARD/settings/api-keys)

CHECKLIST
