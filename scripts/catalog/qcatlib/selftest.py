"""The offline tier: unit checks plus every starter re-rendered from committed excerpts of its pinned
source (supabase/catalog/fixtures/excerpts/), so it runs without the downloaded corpus. The full
gate (`acceptance`) runs on the corpus itself."""

import json
import os
import re

from . import config, corpus, match, normalize, pd, registry, render, sqlgen, starters as starters_mod, verify
from .rejects import RejectList

EXCERPTS = os.path.join(config.data_dir(), "fixtures", "excerpts")
# Characters of source kept on each side of a starter (at most two paragraphs): enough for the
# verse, drama and sentence-start checks, small enough to commit.
EXCERPT_CONTEXT = 700


def _check(failures, cond, msg):
    if not cond:
        failures.append(msg)


def unit(failures):
    # Normaliser: apparatus, ligatures, superscripts, invisible characters, æ/œ, quotes and dashes.
    t = normalize.tokenize("The ﬁre[1] of Cæsar’s soul¹—to-morrow, isn­t it? _Yes._")
    _check(failures, t.words == ["the", "fire", "of", "caesars", "soul", "to", "morrow", "isnt", "it", "yes"],
           "normaliser tokens: %s" % t.words)
    _check(failures, normalize.tokenize("what ignorance of pain?        _75\nAnd pine  80").words
           == ["what", "ignorance", "of", "pain", "and", "pine"], "verse line numbers are not apparatus")
    s = "The ﬁre[1] burns."
    tk = normalize.tokenize(s)
    _check(failures, s[tk.starts[1]:tk.ends[1]] == "ﬁre", "offset map swallowed apparatus: %r" % s[tk.starts[1]:tk.ends[1]])
    # Typography.
    out, _ = render.typography("\"Don't,\" she said--'tis true.")
    _check(failures, out == "“Don’t,” she said—’tis true.", "typography: %r" % out)
    # Public-domain cutoffs.
    _check(failures, pd.cutoffs("2026-10-28")["strict"] == 1945 and pd.cutoffs("2027-01-01")["strict"] == 1946
           and pd.cutoffs("2053-01-01")["strict"] == 1952 and pd.cutoffs("2026-10-28")["us"] == 1930,
           "cutoffs: %s" % pd.cutoffs("2026-10-28"))
    # Lead parsing.
    segs, flags = match.parse_lead("“No one is useless in this world … who lightens the burden…”")
    _check(failures, segs == ["No one is useless in this world", "who lightens the burden"] and "truncated_end" in flags,
           "parse_lead: %s %s" % (segs, flags))
    # The SQL generator is deterministic and quotes safely.
    snap = {"meta": {"batch": "999", "generated_with": "0" * 40}, "authors": [{"id": 1, "slug": "a", "name": "A", "died_year": 1800}],
            "works": [{"id": 1, "author_id": 1, "citation": "W", "edition_year": 1850, "translator": None, "reporter": None,
                       "contributors_last_died_year": None, "gutenberg_id": 5}],
            "quotes": [{"id": 61, "body": "It costs $q$ nothing.", "body_format": [], "author": "A", "source": "W",
                        "source_location": "Ch. 1", "source_url": "https://www.gutenberg.org/ebooks/5", "is_starter": False,
                        "author_id": 1, "work_id": 1, "speaker": None, "themes": ["calm"], "status": "live",
                        "checked_ebook_id": 5, "checked_wikisource_oldid": None, "checked_body_sha256": "a" * 64,
                        "checked_start": 0, "checked_end": 20, "match_kind": "exact", "checked_at": "2026-10-28T00:00:00Z",
                        "verifier_version": "abcdef1"}]}
    a, b = sqlgen.render_sql(snap), sqlgen.render_sql(snap)
    _check(failures, a == b and "$q1$It costs $q$ nothing.$q1$" in a and "update " not in a.lower().replace("-- ", ""),
           "render_sql is not deterministic or quotes unsafely")
    # A re-pin sets only provenance, from the exact emitted values, and never the seal's key.
    old = {c: snap["quotes"][0][c] for c in sqlgen.REPIN_QUOTE_COLS}
    rp = {"meta": {"repin": "999", "ids": [61], "reason": "A scan-backed witness.", "generated_with": "0" * 40},
          "works": [{"id": 1, "from": {c: snap["works"][0][c] for c in sqlgen.REPIN_WORK_COLS},
                     "to": dict({c: snap["works"][0][c] for c in sqlgen.REPIN_WORK_COLS}, edition_year=1902, gutenberg_id=6)}],
          "quotes": [{"id": 61, "from_ref": "pg5", "to_ref": "pg6", "from": old,
                      "to": dict(old, checked_ebook_id=6, checked_start=40, checked_end=60)}]}
    sql = sqlgen.render_repin_sql(rp)
    sets = re.findall(r"(?ms)^set (.*?)^where", sql)
    _check(failures, sql == sqlgen.render_repin_sql(rp) and len(sets) == 2
           and not re.search(r"\b(body|author|source|citation|author_id|work_id|id) =", " ".join(sets))
           and "checked_start = 40" in sets[1] and "checked_end = 60" in sets[1] and "source_url" not in sets[1]
           and sql.count("is not distinct from") == 4 and not re.search(r"(?im)^\s*(insert|delete)\b", sql),
           "render_repin_sql must set only the changed provenance, compare-and-set: %s" % sets)
    # A Disputed entry in other words holds a line found in the author's own work; the same words reject.
    who = {"name": "A", "slug": "a", "aliases": []}
    rl = RejectList([{"text": "Let us endeavor to live so that we die well", "kind": "disputed", "author": "A"}])
    held = verify._reject_check({"cls": "PASS_EXACT", "body": "Let us endeavor so to live that we die well.", "flags": []},
                                {}, who, rl)
    same = verify._reject_check({"cls": "PASS_EXACT", "body": "Let us endeavor to live so that we die well.", "flags": []},
                                {}, who, rl)
    _check(failures, "disputed_variant" in held["flags"] and not held.get("rejected_as")
           and same.get("rejected_as") == "REJECT_MISATTRIBUTED", "disputed variant: %s / %s" % (held, same))


def write_excerpts():
    """Write excerpts of each starter's pinned source: the matched paragraph and one either side."""
    reg = registry.Registry.load()
    lock = corpus.load_lock()
    shipped = {q["id"]: q for q in starters_mod.load()}
    os.makedirs(EXCERPTS, exist_ok=True)
    n = 0
    for fx in registry.read_jsonl(os.path.join(config.data_dir(), "fixtures", "starters.jsonl")):
        q = shipped[fx["id"]]
        w = reg.works[fx["work_id"]]
        text = corpus.load(w["ref"], lock)
        chains, _, _ = verify.locate({"text": q["body"]}, text)
        if not chains:
            raise SystemExit("starter %d not found in %s" % (fx["id"], w["ref"]))
        a = text.tokens.starts[chains[0].start]
        b = text.tokens.ends[chains[0].end - 1]
        body = text.body
        s = a
        for _ in range(2):
            s = body.rfind("\n\n", 0, max(0, s - 1))
            if s < 0:
                s = 0
                break
        s = max(s, a - EXCERPT_CONTEXT)
        s = body.rfind("\n", 0, s) + 1 if s > 0 else 0
        e = b
        for _ in range(2):
            k = body.find("\n\n", e + 1)
            e = len(body) if k < 0 else k
        e = min(e, b + EXCERPT_CONTEXT)
        k = body.find("\n", e)
        e = len(body) if k < 0 else k + 1
        excerpt = body[s:e]
        with open(os.path.join(EXCERPTS, "%02d.txt" % fx["id"]), "w", encoding="utf-8") as f:
            f.write(excerpt)
        with open(os.path.join(EXCERPTS, "%02d.json" % fx["id"]), "w", encoding="utf-8") as f:
            json.dump({"starter": fx["id"], "ref": w["ref"], "body_sha256": text.body_sha256, "offset": s,
                       "excerpt_sha256": corpus.sha256(excerpt), "credit": "Project Gutenberg" if w["ref"].startswith("pg") else "Wikisource"},
                      f, ensure_ascii=False, sort_keys=True)
            f.write("\n")
        n += 1
    print("wrote %d excerpts to %s" % (n, os.path.relpath(EXCERPTS, config.REPO)))
    return 0


def run():
    failures = []
    unit(failures)
    reg = registry.Registry.load()
    rejects = RejectList.load(live=False)
    shipped = {q["id"]: q for q in starters_mod.load()}
    fixtures = registry.read_jsonl(os.path.join(config.data_dir(), "fixtures", "starters.jsonl"))
    have = 0
    corpus._cache.clear()
    for fx in fixtures:
        p = os.path.join(EXCERPTS, "%02d.txt" % fx["id"])
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            excerpt = f.read()
        with open(p[:-4] + ".json", encoding="utf-8") as f:
            meta = json.load(f)
        if corpus.sha256(excerpt) != meta["excerpt_sha256"]:
            failures.append("excerpt %02d changed on disk" % fx["id"])
            continue
        corpus._cache[meta["ref"]] = corpus.Text(meta["ref"], excerpt, {"body_sha256": meta["body_sha256"]})
        have += 1
    if have < len(fixtures):
        failures.append("only %d of %d starter excerpts are committed (run `qcat excerpts` on the pinned corpus)" % (have, len(fixtures)))
    for fx in fixtures:
        q = shipped[fx["id"]]
        w = reg.works[fx["work_id"]]
        if w["ref"] not in corpus._cache:
            continue
        r = verify.verify({"text": q["body"], "author": q["author"], "work": w["id"], "speaker": fx.get("speaker"),
                           "speaker_ok": fx.get("speaker_ok", False)}, reg, {}, "2026-10-28", rejects)
        if r.get("body") != q["body"] or r["cls"] != fx["expect"]["cls"] or r.get("edits") != fx["expect"]["edits"]:
            failures.append("starter %d: %s %r edits %s" % (fx["id"], r["cls"], r.get("body"), r.get("edits")))
        if r.get("rejected_as"):
            failures.append("starter %d hits the frozen reject list for its own author" % fx["id"])
    # Every frozen reject hits the list under its own author.
    for fx in registry.read_jsonl(os.path.join(config.data_dir(), "fixtures", "rejects.jsonl")):
        if "REJECT_MISATTRIBUTED" in fx["expect_any_of"]:
            hits = rejects.lookup(fx["text"])
            if not any(h["author"] == fx["author"] for h in hits):
                failures.append("reject %d (%s) is not on the frozen list under its author" % (fx["n"], fx["author"]))
    corpus._cache.clear()
    for f in failures:
        print("FAIL", f)
    print("selftest %s: %d starters from excerpts, %d failures" % ("ok" if not failures else "FAILED", have, len(failures)))
    return 4 if failures else 0
