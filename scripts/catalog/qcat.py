"""qcat: the Quoted catalog verifier and batch tools. Run through scripts/catalog.sh.

Commands:
  version                         the verifier version (git tree id of scripts/catalog)
  registry check                  check authors.jsonl and works.jsonl (and against pg_catalog.csv)
  registry allowlist              the translators who pass the strict rule (D5)
  corpus fetch --pg-catalog | --gutenberg ID,… | --wikisource TITLE | --wikiquote-dump | --list-only ID
  corpus lock                     pin every downloaded text in supabase/catalog/corpus.lock.jsonl
  corpus status                   what is pinned, missing or drifted
  wikiquote import                build the reject list from the Wikiquote dump (stays in build/)
  verify --leads FILE             verify leads (JSONL) and write results under build/catalog/runs/
  acceptance [--live-rejects]     the gate (plan section 5); exit 4 on failure
  selftest                        the offline tier: unit checks and starters against committed excerpts
  excerpts                        write the committed excerpt fixtures from the pinned corpus
  review build --run DIR          the static review page
  generate batch NNN | generate check
  generate repin --quote ID --reason TEXT
                                  re-pin live quotes to their works' new pins (same body, author, source)
  sources-doc                     write docs/catalog-sources.md
Exit codes: 0 ok, 1 error, 2 usage, 3 drift, 4 gate failure.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from qcatlib import cli  # noqa: E402

if __name__ == "__main__":
    sys.exit(cli.main(sys.argv[1:]))
