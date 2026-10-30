#!/usr/bin/env bash
# The catalog verifier and batch tools (stdlib Python only). See scripts/catalog/qcat.py --help and
# docs/catalog-population-plan.md. -I keeps a planted module in a data folder from being imported;
# -B keeps bytecode out of the repo.
#
#   scripts/catalog.sh selftest                  # offline: committed excerpts
#   scripts/catalog.sh acceptance                # the gate, on the downloaded corpus
#   scripts/catalog.sh generate check            # every batch regenerates byte for byte
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 -I -B "$ROOT/scripts/catalog/qcat.py" "$@"
