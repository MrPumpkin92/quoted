"""The 60 starter quotes as they shipped, read from the migrations (never copied)."""

import os
import re

from . import config

STARTER_ROW = re.compile(
    r"\(\s*(\d+),\s*\$q\$(.*?)\$q\$,\s*'\[\]'::jsonb,\s*\$q\$(.*?)\$q\$,\s*\$q\$(.*?)\$q\$,\s*(\d+)\)", re.S)
LOCATION_ROW = re.compile(r"\(\s*(\d+),\s*\$q\$(.*?)\$q\$,\s*\$q\$(https://[^$]+)\$q\$\)", re.S)


def load():
    mig = config.migrations_dir()
    with open(os.path.join(mig, "20261019040100_starter_pack.sql"), encoding="utf-8") as f:
        pack = f.read()
    with open(os.path.join(mig, "20261024090000_verified_quotes.sql"), encoding="utf-8") as f:
        verified = f.read()
    rows = {}
    for qid, body, author, source, sort in STARTER_ROW.findall(pack):
        rows[int(qid)] = {"id": int(qid), "body": body, "author": author, "source": source, "sort_order": int(sort)}
    if len(rows) != 60:
        raise SystemExit("expected 60 starter rows in 20261019040100_starter_pack.sql, found %d" % len(rows))
    for qid, location, url in LOCATION_ROW.findall(verified):
        if int(qid) in rows:
            rows[int(qid)].update(source_location=location, source_url=url)
    missing = [q for q in rows.values() if "source_url" not in q]
    if missing:
        raise SystemExit("starters without a location: %s" % [q["id"] for q in missing])
    return [rows[k] for k in sorted(rows)]
