"""Batches: from the founder's decisions to a generated, append-only migration.

  approve NNN   decisions/NNN.jsonl + the verify run → new rows in supabase/catalog/quotes.jsonl
  generate batch NNN [--timestamp YYYYMMDDHHMMSS]
                freeze the batch's rows into batches/NNN.jsonl, then write
                supabase/migrations/<ts>_catalog_batch_NNN.sql and batches/NNN.md
  generate repin --quote ID [--quote ID ...] --reason TEXT [--timestamp YYYYMMDDHHMMSS]
                re-verify live quotes against their works' current pins in works.jsonl, require the
                same body, freeze old and new provenance into repins/NNN.jsonl, then write
                supabase/migrations/<ts>_catalog_repin_NNN.sql and update quotes.jsonl
  generate check
                every batch and re-pin regenerates byte for byte from its own snapshot, and
                quotes.jsonl and works.jsonl hold exactly what those migrations store

Each batch migration stages rows in temp tables, inserts with `on conflict (id) do nothing`, raises
if anything staged differs from what is stored (insert-or-verify, never update), reseals users'
matching quotes, and drops its temp tables. It never updates or deletes a catalog row.

A re-pin moves only where a live quote was checked (a Gutenberg text for an unscanned Wikisource
page, say): its provenance columns and the work it cites. Id, body, author and source never change
(catalog_quotes_guard), so no seal moves. Each update is compare-and-set: it applies only to a row
that still holds the values it was emitted with, and the migration fails if any row ends up holding
anything but the re-pinned values.
"""

import datetime
import glob
import json
import os
import re
import textwrap

from . import config, pd, registry, version

MAX_ROWS = 100
DEFAULT_ROWS = 50
AUTHOR_COLS = ["id", "slug", "name", "died_year"]
WORK_COLS = ["id", "author_id", "citation", "edition_year", "translator", "reporter",
             "contributors_last_died_year", "gutenberg_id"]
QUOTE_COLS = ["id", "body", "body_format", "author", "source", "source_location", "source_url", "is_starter",
              "author_id", "work_id", "speaker", "themes", "status", "checked_ebook_id", "checked_wikisource_oldid",
              "checked_body_sha256", "checked_start", "checked_end", "match_kind", "checked_at", "verifier_version"]
# Compared by the insert-or-verify block (added_at is the deploy time; themes may change later).
QUOTE_FROZEN = ["body", "body_format", "author", "source", "source_location", "source_url", "is_starter",
                "author_id", "work_id", "speaker", "checked_ebook_id", "checked_wikisource_oldid",
                "checked_body_sha256", "checked_start", "checked_end", "match_kind", "checked_at", "verifier_version"]
# What a re-pin may move. A work keeps its id, author and citation (the seal's source string).
REPIN_QUOTE_COLS = ["source_location", "source_url", "checked_ebook_id", "checked_wikisource_oldid",
                    "checked_body_sha256", "checked_start", "checked_end", "match_kind", "checked_at",
                    "verifier_version"]
REPIN_WORK_COLS = ["edition_year", "translator", "reporter", "contributors_last_died_year", "gutenberg_id"]
PASSING = ("PASS_EXACT", "PASS_TYPOGRAPHIC", "PASS_ELIDED")


class GenerateError(SystemExit):
    pass


def _next_timestamp(timestamp=None):
    """A migration version later than every existing one. Two migrations generated in the same second
    (batches 001 and 002 did) would otherwise share a version, which the CLI refuses."""
    if timestamp:
        return timestamp
    latest = max((os.path.basename(p).split("_", 1)[0] for p in glob.glob(os.path.join(config.migrations_dir(), "*.sql"))),
                 default="0")
    now = datetime.datetime.utcnow().strftime("%Y%m%d%H%M%S")
    return now if now > latest else "%014d" % (int(latest) + 1)


def _data(*parts):
    return os.path.join(config.data_dir(), *parts)


def quotes_rows():
    return registry.read_jsonl(_data("quotes.jsonl"))


# ---- approve ------------------------------------------------------------------------------------

def approve(batch, run_name):
    """Turn the founder's keep decisions into catalog rows (dense new ids, never reused)."""
    reg = registry.Registry.load()
    results = {r["lead_id"]: r for r in registry.read_jsonl(os.path.join(config.build_dir(), "runs", run_name, "results.jsonl"))}
    decisions = {}
    for d in registry.read_jsonl(_data("decisions", "%s.jsonl" % batch)):
        decisions[d["lead_id"]] = d  # the last decision per lead wins
    rows = quotes_rows()
    have = {r["lead_id"] for r in rows if r.get("lead_id")}
    next_id = max([60] + [r["id"] for r in rows]) + 1
    added = 0
    for lead_id, d in sorted(decisions.items(), key=lambda kv: kv[1].get("order", 0)):
        if d["decision"] != "keep" or lead_id in have:
            continue
        r = results.get(lead_id)
        if r is None or r.get("final") not in PASSING:
            raise GenerateError("%s: kept but its verify result is %s" % (lead_id, r and r.get("final")))
        w = reg.works[r["work_id"]]
        a = reg.author(r["author"])
        lock_ref = r["ref"]
        row = {
            "id": next_id, "batch": batch, "lead_id": lead_id, "status": "live",
            "body": r["body"], "author": a["name"], "source": w["citation"],
            "author_id": a["id"], "work_id": w["id"],
            "source_location": d.get("location") or r["lead"].get("location"),
            "source_url": w["source_url"], "speaker": d.get("speaker", r["lead"].get("speaker")),
            "themes": d["themes"], "mood": d.get("mood"),
            "rubric": r.get("rubric"), "score": r.get("score"), "edits": r.get("edits"),
            "prefix_dropped": r.get("prefix_dropped"), "gaps": r.get("gaps"),
            "checked": {
                "ebook_id": w["gutenberg_id"] if lock_ref.startswith("pg") else None,
                "wikisource_oldid": r.get("wikisource_oldid") if lock_ref.startswith("ws:") else None,
                "ref": lock_ref, "body_sha256": r["body_sha256"], "start": r["start"], "end": r["end"],
                "match_kind": "elided" if r["final"] == "PASS_ELIDED" else "exact",
                "checked_at": r["checked_at"], "verifier_version": r["verifier_version"],
            },
            "pd": r.get("pd"),
            "context_before": r.get("context_before", "")[-300:], "context_after": r.get("context_after", "")[:300],
        }
        rows.append(row)
        next_id += 1
        added += 1
    registry.write_jsonl(_data("quotes.jsonl"), rows)
    print("approved %d new rows (ids up to %d)" % (added, next_id - 1))
    return 0


# ---- snapshot -----------------------------------------------------------------------------------

def _db_quote(q):
    c = q["checked"]
    return {
        "id": q["id"], "body": q["body"], "body_format": [], "author": q["author"], "source": q["source"],
        "source_location": q["source_location"], "source_url": q["source_url"], "is_starter": False,
        "author_id": q["author_id"], "work_id": q["work_id"], "speaker": q.get("speaker"),
        "themes": q["themes"], "status": "live",
        "checked_ebook_id": c.get("ebook_id"), "checked_wikisource_oldid": c.get("wikisource_oldid"),
        "checked_body_sha256": c["body_sha256"], "checked_start": c["start"], "checked_end": c["end"],
        "match_kind": c["match_kind"], "checked_at": c["checked_at"], "verifier_version": c["verifier_version"],
    }


def _db_author(a):
    return {k: a.get(k) for k in AUTHOR_COLS}


def _db_work(w):
    return {"id": w["id"], "author_id": w["author_id"], "citation": w["citation"], "edition_year": w["edition_year"],
            "translator": w.get("translator"), "reporter": w.get("reporter"),
            "contributors_last_died_year": registry.contributors_last_died_year(w),
            "gutenberg_id": w.get("gutenberg_id")}


def check_rules(quotes, reg, as_of):
    """The batch rules the generator enforces (plan sections 3 and 4.6)."""
    errors = []
    if len(quotes) > MAX_ROWS:
        errors.append("%d rows: at most %d per batch" % (len(quotes), MAX_ROWS))
    per_author, per_work = {}, {}
    impactful = archaic = 0
    for q in quotes:
        per_author[q["author_id"]] = per_author.get(q["author_id"], 0) + 1
        per_work[q["work_id"]] = per_work.get(q["work_id"], 0) + 1
        if len(q["body"]) > 280:
            errors.append("#%d is %d characters (280 at most)" % (q["id"], len(q["body"])))
        if not (1 <= len(q["themes"]) <= 3) or set(q["themes"]) - set(config.THEMES):
            errors.append("#%d themes %s: 1-3 of %s" % (q["id"], q["themes"], config.THEMES))
        if re.search(r"['\"]", q["body"] + q["author"] + q["source"]):
            errors.append("#%d has a straight quote" % q["id"])
        w = reg.works[q["work_id"]]
        v = pd.verdict(w, reg.authors[q["author_id"]], reg.authors[w["author_id"]], as_of)
        if not v["ok"]:
            errors.append("#%d fails the public-domain rule at %s: %s" % (q["id"], v["as_of"], "; ".join(v["blocking"])))
        r = q.get("rubric") or {}
        if r.get("stands_alone", 0) < 2:
            errors.append("#%d is not meaningful (stands alone scores %s)" % (q["id"], r.get("stands_alone")))
        if r.get("charge", 0) >= 2 and r.get("turn", 0) >= 2:
            impactful += 1
        if "archaic" in (q.get("flags") or []) or r.get("readability", 3) <= 1:
            archaic += 1
    for aid, n in per_author.items():
        if n > 3:
            errors.append("%s has %d rows (3 per batch)" % (reg.authors[aid]["name"], n))
    for wid, n in per_work.items():
        if n > 2:
            errors.append("%s has %d rows (2 per batch)" % (reg.works[wid]["citation"], n))
    if quotes and impactful < 0.7 * len(quotes):
        errors.append("only %d of %d rows are impactful (70%% needed)" % (impactful, len(quotes)))
    if quotes and archaic > 0.15 * len(quotes):
        errors.append("%d of %d rows are archaic (15%% at most)" % (archaic, len(quotes)))
    return errors


def generate_batch(number, timestamp=None):
    if number is None:
        raise GenerateError("usage: generate batch NNN")
    batch = "%03d" % number
    reg = registry.Registry.load()
    quotes = sorted([q for q in quotes_rows() if q.get("batch") == batch], key=lambda q: q["id"])
    if not quotes:
        raise GenerateError("no rows for batch %s in supabase/catalog/quotes.jsonl" % batch)
    if not os.path.exists(os.path.join(config.migrations_dir(), "20261028120000_catalog_corpus.sql")):
        raise GenerateError("the corpus migration (M1) is missing: batches need catalog_quotes")
    errors = check_rules(quotes, reg, None)
    if errors:
        raise GenerateError("batch %s breaks the rules:\n  " % batch + "\n  ".join(errors))
    author_ids = sorted({q["author_id"] for q in quotes} | {reg.works[q["work_id"]]["author_id"] for q in quotes})
    work_ids = sorted({q["work_id"] for q in quotes})
    snap = {"kind": "meta", "batch": batch, "ids": [quotes[0]["id"], quotes[-1]["id"]], "count": len(quotes),
            "generated_with": version.tree_id()}
    path = _data("batches", "%s.jsonl" % batch)
    if os.path.exists(path):
        raise GenerateError("batches/%s.jsonl exists: an emitted batch is frozen (fix forward with a new batch "
                            "or a withdrawal)" % batch)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(snap, ensure_ascii=False, sort_keys=True) + "\n")
        for a in author_ids:
            f.write(json.dumps(dict(kind="author", **_db_author(reg.authors[a])), ensure_ascii=False, sort_keys=True) + "\n")
        for w in work_ids:
            f.write(json.dumps(dict(kind="work", **_db_work(reg.works[w])), ensure_ascii=False, sort_keys=True) + "\n")
        for q in quotes:
            f.write(json.dumps(dict(kind="quote", **_db_quote(q)), ensure_ascii=False, sort_keys=True) + "\n")
    ts = _next_timestamp(timestamp)
    for old in glob.glob(os.path.join(config.migrations_dir(), "*_catalog_batch_%s.sql" % batch)):
        os.remove(old)
    mig = os.path.join(config.migrations_dir(), "%s_catalog_batch_%s.sql" % (ts, batch))
    with open(mig, "w", encoding="utf-8") as f:
        f.write(render_sql(read_snapshot(path)))
    with open(_data("batches", "%s.md" % batch), "w", encoding="utf-8") as f:
        f.write(report_md(batch, quotes, reg))
    print("wrote", os.path.relpath(mig, config.REPO))
    return 0


def read_snapshot(path):
    snap = {"authors": [], "works": [], "quotes": []}
    for r in registry.read_jsonl(path):
        k = r.pop("kind")
        if k == "meta":
            snap["meta"] = r
        else:
            snap[k + "s"].append(r)
    return snap


# ---- SQL ------------------------------------------------------------------------------------------

def _tag(values):
    blob = "\n".join(v for v in values if isinstance(v, str))
    for t in ["q"] + ["q%d" % i for i in range(1, 100)]:
        if "$%s$" % t not in blob:
            return t
    raise GenerateError("no free dollar-quote tag")


def _lit(v, tag, kind=None):
    if v is None:
        return "null"
    if kind == "jsonb":
        return "'%s'::jsonb" % json.dumps(v, separators=(",", ":"))
    if kind == "text[]":
        return "array[%s]::text[]" % ", ".join("$%s$%s$%s$" % (tag, x, tag) for x in v)
    if kind == "timestamptz":
        return "'%s'::timestamptz" % v
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return "$%s$%s$%s$" % (tag, v, tag)


KINDS = {"body_format": "jsonb", "themes": "text[]", "checked_at": "timestamptz"}


def _values(rows, cols, tag):
    out = []
    for r in rows:
        out.append("  (" + ", ".join(_lit(r[c], tag, KINDS.get(c)) for c in cols) + ")")
    return ",\n".join(out)


def render_sql(snap):
    meta = snap["meta"]
    batch = meta["batch"]
    quotes = snap["quotes"]
    tag = _tag([str(v) for r in snap["authors"] + snap["works"] + quotes for v in r.values()])
    ids = [q["id"] for q in quotes]
    authors = ", ".join(sorted({q["author"] for q in quotes}))
    lines = [
        "-- GENERATED by `scripts/catalog.sh generate batch %d`. Do not edit: change supabase/catalog/ and" % int(batch),
        "-- regenerate (`generate check` fails on any hand edit).",
        "--",
        "-- Catalog batch %s: %d verified public-domain quotes, ids %d-%d." % (batch, len(quotes), ids[0], ids[-1]),
        "-- Authors: %s." % authors,
        "-- Report to read instead of this SQL: supabase/catalog/batches/%s.md. Rows: batches/%s.jsonl." % (batch, batch),
        "-- Generated with verifier %s. Deploy only after the TestFlight build with the catalog client." % meta["generated_with"][:12],
        "--",
        "-- Insert-or-verify: a row already stored with different values fails the whole migration;",
        "-- nothing here updates or deletes a catalog row.",
        "",
        "create temp table batch_authors (like public.catalog_authors);",
        "insert into batch_authors (%s) values" % ", ".join(AUTHOR_COLS),
        _values(snap["authors"], AUTHOR_COLS, tag) + ";",
        "",
        "create temp table batch_works (like public.catalog_works);",
        "insert into batch_works (%s) values" % ", ".join(WORK_COLS),
        _values(snap["works"], WORK_COLS, tag) + ";",
        "",
        "create temp table batch_quotes (like public.catalog_quotes including defaults);",
        "insert into batch_quotes (%s) values" % ", ".join(QUOTE_COLS),
        _values(quotes, QUOTE_COLS, tag) + ";",
        "",
        "insert into public.catalog_authors (%s)" % ", ".join(AUTHOR_COLS),
        "  select %s from batch_authors on conflict (id) do nothing;" % ", ".join(AUTHOR_COLS),
        "insert into public.catalog_works (%s)" % ", ".join(WORK_COLS),
        "  select %s from batch_works on conflict (id) do nothing;" % ", ".join(WORK_COLS),
        "insert into public.catalog_quotes (%s)" % ", ".join(QUOTE_COLS),
        "  select %s from batch_quotes on conflict (id) do nothing;" % ", ".join(QUOTE_COLS),
        "",
        "do $$",
        "begin",
        "  if exists (select 1 from batch_authors b left join public.catalog_authors a on a.id = b.id",
        "             where a.id is null or (%s) is distinct from (%s)) then" % (
            ", ".join("a." + c for c in AUTHOR_COLS[1:]), ", ".join("b." + c for c in AUTHOR_COLS[1:])),
        "    raise exception 'catalog batch %s: an author is already stored with different values';" % batch,
        "  end if;",
        "  if exists (select 1 from batch_works b left join public.catalog_works w on w.id = b.id",
        "             where w.id is null or (%s) is distinct from (%s)) then" % (
            ", ".join("w." + c for c in WORK_COLS[1:]), ", ".join("b." + c for c in WORK_COLS[1:])),
        "    raise exception 'catalog batch %s: a work is already stored with different values';" % batch,
        "  end if;",
        "  if exists (select 1 from batch_quotes b left join public.catalog_quotes q on q.id = b.id",
        "             where q.id is null or (%s) is distinct from (%s)) then" % (
            ", ".join("q." + c for c in QUOTE_FROZEN), ", ".join("b." + c for c in QUOTE_FROZEN)),
        "    raise exception 'catalog batch %s: a quote id is already stored with different text or provenance';" % batch,
        "  end if;",
        "end",
        "$$;",
        "",
        "-- Users' quotes and shares that already match a new row gain the seal now.",
        "select * from private.catalog_reseal(array[%s]);" % ", ".join(str(i) for i in ids),
        "",
        "drop table batch_quotes, batch_works, batch_authors;",
        "",
    ]
    return "\n".join(lines)


# ---- re-pin -----------------------------------------------------------------------------------------

def _events():
    """Every emitted batch and re-pin in migration order, as (version, kind, number, snapshot, migrations)."""
    out = []
    for kind, folder in (("batch", "batches"), ("repin", "repins")):
        for path in glob.glob(_data(folder, "*.jsonl")):
            number = os.path.basename(path)[:-6]
            migs = glob.glob(os.path.join(config.migrations_dir(), "*_catalog_%s_%s.sql" % (kind, number)))
            version_ = os.path.basename(migs[0]).split("_", 1)[0] if len(migs) == 1 else ""
            out.append((version_, kind, number, path, migs))
    return sorted(out)


def read_repin(path):
    snap = {"works": [], "quotes": []}
    for r in registry.read_jsonl(path):
        k = r.pop("kind")
        if k == "meta":
            snap["meta"] = r
        else:
            snap[k + "s"].append(r)
    return snap


def effective_state(problems=None, events=None):
    """What the catalog migrations leave in the database, replayed in order: each batch inserts its
    rows, each re-pin then moves provenance. Returns ({quote id: row}, {work id: row}) and adds to
    `problems` anything the database would refuse."""
    quotes, works = {}, {}
    note = problems.append if problems is not None else (lambda _: None)
    for _, kind, number, path, _ in events if events is not None else _events():
        if kind == "batch":
            snap = read_snapshot(path)
            for w in snap["works"]:
                if w["id"] in works and works[w["id"]] != w:
                    note("batch %s: work %d differs from what an earlier migration stored" % (number, w["id"]))
                works.setdefault(w["id"], dict(w))
            for q in snap["quotes"]:
                if q["id"] in quotes:
                    note("batch %s: id %d is used by an earlier batch" % (number, q["id"]))
                quotes[q["id"]] = dict(q)
            continue
        snap = read_repin(path)
        for table, rows in ((works, snap["works"]), (quotes, snap["quotes"])):
            for r in rows:
                cur = table.get(r["id"])
                if cur is None or any(cur[k] != v for k, v in r["from"].items()):
                    note("re-pin %s: %s %d does not hold the values it re-pins from" % (
                        number, "work" if table is works else "quote", r["id"]))
                if cur is not None:
                    cur.update(r["to"])
    return quotes, works


def generate_repin(quote_ids, reason, timestamp=None):
    """Re-pin live quotes to their works' current pins in works.jsonl (change the work's ref there
    first): the same body, author and source, checked against another edition."""
    from . import corpus, fetch, verify
    from .rejects import RejectList
    reason = re.sub(r"\s+", " ", reason or "").strip()
    if not quote_ids or not reason:
        raise GenerateError("usage: generate repin --quote ID [--quote ID ...] --reason TEXT")
    problems = []
    state_quotes, state_works = effective_state(problems)
    if problems:
        raise GenerateError("the emitted migrations don't replay (run generate check):\n  " + "\n  ".join(problems))
    reg = registry.Registry.load()
    lock = corpus.load_lock()
    rejects = RejectList.load(live=True)
    rows = quotes_rows()
    by_id = {q["id"]: q for q in rows}
    ids = sorted(set(quote_ids))
    # A work whose stored values no longer match works.jsonl moves with this re-pin, and so must every
    # emitted quote that cites it: no quote may name a pin its work doesn't.
    changed_works = sorted(wid for wid, w in state_works.items() if _db_work(reg.works[wid]) != w)
    work_events = []
    for wid in changed_works:
        now = _db_work(reg.works[wid])
        if (now["author_id"], now["citation"]) != (state_works[wid]["author_id"], state_works[wid]["citation"]):
            raise GenerateError("work %d: author and citation are the seal's source and never change" % wid)
        missing = sorted(qid for qid, q in state_quotes.items() if q["work_id"] == wid and qid not in ids)
        if missing:
            raise GenerateError("work %d changed in works.jsonl: re-pin %s with it" % (
                wid, ", ".join("--quote %d" % i for i in missing)))
        work_events.append({"kind": "work", "id": wid, "from": {k: state_works[wid][k] for k in REPIN_WORK_COLS},
                            "to": {k: now[k] for k in REPIN_WORK_COLS}})
    tree = version.tree_id()
    checked_at = fetch.now()
    quote_events = []
    for qid in ids:
        q, stored = by_id.get(qid), state_quotes.get(qid)
        if q is None or stored is None or stored["status"] != "live":
            raise GenerateError("#%d is not a live emitted catalog quote" % qid)
        if any(_db_quote(q)[k] != stored[k] for k in QUOTE_FROZEN):
            raise GenerateError("#%d in quotes.jsonl differs from what the migrations store (run generate check)" % qid)
        w = reg.works[q["work_id"]]
        ref, old_ref = w["ref"], q["checked"]["ref"]
        if ref == old_ref:
            raise GenerateError("#%d is already checked against %s: change work %d's pin in works.jsonl first" % (
                qid, ref, w["id"]))
        r = verify.verify({"lead_id": "repin-%d" % qid, "text": q["body"], "author": q["author"], "work": w["id"],
                           "speaker": q.get("speaker"), "speaker_ok": q.get("speaker") is not None},
                          reg, lock, None, rejects)
        final = verify.final_class(r)
        if final not in PASSING or r.get("body") != q["body"]:
            raise GenerateError("#%d: %s gives %s %r, not the stored body. Another wording is a withdrawal and a "
                                "new row, never a re-pin." % (qid, ref, final, r.get("body")))
        if not r["pd"]["ok"]:
            raise GenerateError("#%d fails the public-domain rule against %s: %s" % (qid, ref, "; ".join(r["pd"]["blocking"])))
        q.update({
            "source_url": w["source_url"], "pd": r["pd"], "edits": r.get("edits"),
            "prefix_dropped": r.get("prefix_dropped"), "gaps": r.get("gaps"),
            "context_before": r.get("context_before", "")[-300:], "context_after": r.get("context_after", "")[:300],
            "checked": {
                "ebook_id": w["gutenberg_id"] if ref.startswith("pg") else None,
                "wikisource_oldid": lock[ref]["oldid"] if ref.startswith("ws:") else None,
                "ref": ref, "body_sha256": r["body_sha256"], "start": r["start"], "end": r["end"],
                "match_kind": "elided" if final == "PASS_ELIDED" else "exact",
                "checked_at": checked_at, "verifier_version": tree,
            },
        })
        new = _db_quote(q)
        quote_events.append({"kind": "quote", "id": qid, "from_ref": old_ref, "to_ref": ref,
                             "from": {k: stored[k] for k in REPIN_QUOTE_COLS},
                             "to": {k: new[k] for k in REPIN_QUOTE_COLS}})
        print("#%d: %s → %s, %s, flags %s" % (qid, old_ref, ref, final, r["flags"]))
    number = "%03d" % (1 + max([0] + [int(os.path.basename(p)[:-6]) for p in glob.glob(_data("repins", "*.jsonl"))]))
    path = _data("repins", "%s.jsonl" % number)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        meta = {"kind": "meta", "repin": number, "ids": ids, "reason": reason, "generated_with": tree}
        for r in [meta] + work_events + quote_events:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
    mig = os.path.join(config.migrations_dir(), "%s_catalog_repin_%s.sql" % (_next_timestamp(timestamp), number))
    with open(mig, "w", encoding="utf-8") as f:
        f.write(render_repin_sql(read_repin(path)))
    registry.write_jsonl(_data("quotes.jsonl"), rows)
    print("wrote", os.path.relpath(path, config.REPO), "and", os.path.relpath(mig, config.REPO))
    return 0


def _set_and_match(table, row, cols, tag):
    changed = [c for c in cols if row["from"][c] != row["to"][c]]
    return [
        "update public.%s" % table,
        "set " + ",\n    ".join("%s = %s" % (c, _lit(row["to"][c], tag, KINDS.get(c))) for c in changed),
        "where id = %d" % row["id"],
        "  and (%s)" % ", ".join(cols),
        "      is not distinct from (%s);" % ", ".join(_lit(row["from"][c], tag, KINDS.get(c)) for c in cols),
        "",
    ]


def _holds(table, row, cols, tag):
    return "not exists (select 1 from public.%s where id = %d and (%s) is not distinct from (%s))" % (
        table, row["id"], ", ".join(cols), ", ".join(_lit(row["to"][c], tag, KINDS.get(c)) for c in cols))


def render_repin_sql(snap):
    meta = snap["meta"]
    number = meta["repin"]
    tag = _tag([str(v) for r in snap["works"] + snap["quotes"] for side in ("from", "to") for v in r[side].values()])
    why = textwrap.wrap("Why: " + meta["reason"], 96)
    lines = [
        "-- GENERATED by `scripts/catalog.sh generate repin`. Do not edit: change supabase/catalog/ and",
        "-- regenerate (`generate check` fails on any hand edit).",
        "--",
        "-- Catalog re-pin %s: %s now checked against another pinned edition." % (
            number, ", ".join("#%d" % q["id"] for q in snap["quotes"])),
    ] + ["-- " + w for w in why] + [
        "-- Record: supabase/catalog/repins/%s.jsonl and docs/catalog-sources.md. Generated with verifier %s." % (
            number, meta["generated_with"][:12]),
        "--",
    ] + ["-- #%d: %s -> %s" % (q["id"], q["from_ref"], q["to_ref"]) for q in snap["quotes"]] + [
        "--",
        "-- Body, author and source never change (catalog_quotes_guard), so no seal moves and nothing is",
        "-- resealed; only where the text was checked does. Compare-and-set: each update applies only to a",
        "-- row that still holds the values it was emitted with, and the check at the end fails the",
        "-- migration if any row holds anything but the re-pinned values.",
        "",
    ]
    for w in snap["works"]:
        lines += _set_and_match("catalog_works", w, REPIN_WORK_COLS, tag)
    for q in snap["quotes"]:
        lines += _set_and_match("catalog_quotes", q, REPIN_QUOTE_COLS, tag)
    lines += ["do $$", "begin"]
    for kind, table, rows, cols in (("work", "catalog_works", snap["works"], REPIN_WORK_COLS),
                                    ("quote", "catalog_quotes", snap["quotes"], REPIN_QUOTE_COLS)):
        for r in rows:
            lines += ["  if %s then" % _holds(table, r, cols, tag),
                      "    raise exception 'catalog re-pin %s: %s %d holds neither its emitted values nor the re-pinned ones';" % (
                          number, kind, r["id"]),
                      "  end if;"]
    lines += ["end", "$$;", ""]
    return "\n".join(lines)


# ---- check ------------------------------------------------------------------------------------------

def check():
    events = _events()
    problems = []
    for _, kind, number, path, migs in events:
        if len(migs) != 1:
            problems.append("%s %s: %d migration files" % (kind, number, len(migs)))
            continue
        sql = render_sql(read_snapshot(path)) if kind == "batch" else render_repin_sql(read_repin(path))
        with open(migs[0], encoding="utf-8") as f:
            if f.read() != sql:
                problems.append("%s %s: %s differs from what its snapshot generates" % (kind, number, os.path.basename(migs[0])))
    state_quotes, state_works = effective_state(problems, events)
    rows = {q["id"]: q for q in quotes_rows()}
    for qid, stored in sorted(state_quotes.items()):
        src = rows.get(qid)
        if src is None:
            problems.append("id %d is no longer in quotes.jsonl" % qid)
            continue
        diff = [k for k in QUOTE_FROZEN if _db_quote(src)[k] != stored[k]]
        if diff:
            problems.append("id %d in quotes.jsonl differs from what the migrations store (%s): an emitted row changes "
                            "only through a re-pin" % (qid, ", ".join(diff)))
    reg = registry.Registry.load()
    for wid, stored in sorted(state_works.items()):
        diff = [k for k, v in _db_work(reg.works[wid]).items() if stored[k] != v]
        if diff:
            problems.append("work %d in works.jsonl differs from what the migrations store (%s): re-pin its quotes "
                            "(generate repin)" % (wid, ", ".join(diff)))
    for kind, folder in (("batch", "batches"), ("repin", "repins")):
        for m in glob.glob(os.path.join(config.migrations_dir(), "*_catalog_%s_*.sql" % kind)):
            n = re.search(r"_catalog_%s_(\d+)\.sql$" % kind, m).group(1)
            if not os.path.exists(_data(folder, n + ".jsonl")):
                problems.append("%s has no snapshot in supabase/catalog/%s/" % (os.path.basename(m), folder))
    for p in problems:
        print("-", p)
    print("generate check: %d batches, %d re-pins, %d problems" % (
        sum(1 for e in events if e[1] == "batch"), sum(1 for e in events if e[1] == "repin"), len(problems)))
    return 1 if problems else 0


def report_md(batch, quotes, reg):
    moods = {}
    for q in quotes:
        moods[q.get("mood")] = moods.get(q.get("mood"), 0) + 1
    women = sum(1 for q in quotes if reg.authors[q["author_id"]].get("woman"))
    verse = sum(1 for q in quotes if "\n" in q["body"])
    lines = ["# Catalog batch %s" % batch, "",
             "%d quotes, ids %d-%d. Women: %d. Verse: %d. Moods: %s." % (
                 len(quotes), quotes[0]["id"], quotes[-1]["id"], women, verse,
                 ", ".join("%s %d" % (k, v) for k, v in sorted(moods.items(), key=lambda kv: str(kv[0])))),
             "", "Every body is rendered from the pinned source span (provenance in batches/%s.jsonl)." % batch, ""]
    for q in quotes:
        c = q["checked"]
        lines += ["## %d. %s, *%s*" % (q["id"], q["author"], q["source"]), "",
                  "> " + q["body"].replace("\n", "  \n> "), "",
                  "- Where: %s%s" % (q["source_location"], ("; spoken by " + q["speaker"]) if q.get("speaker") else ""),
                  "- Checked: %s, %s, code points %d-%d of body %s…" % (c["ref"], c["match_kind"], c["start"], c["end"], c["body_sha256"][:12]),
                  "- Themes: %s; mood: %s" % (", ".join(q["themes"]), q.get("mood")),
                  ]
        if q.get("edits"):
            lines.append("- Edits: %s%s" % (", ".join(e["kind"] for e in q["edits"]),
                                            ("; dropped “%s”" % q["prefix_dropped"].strip()) if q.get("prefix_dropped") else ""))
        if q.get("gaps"):
            lines.append("- Left out: " + " | ".join("“%s”" % re.sub(r"\s+", " ", g).strip() for g in q["gaps"]))
        lines.append("")
    return "\n".join(lines)
