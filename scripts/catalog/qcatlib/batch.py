"""Verifying a batch of leads: supabase/catalog/leads/<batch>.jsonl → build/catalog/runs/<batch>/.

A lead row (committed; lookup keys only, never the stored wording):
  {"lead_id", "lead_source": "canon"|"wishlist"|…, "author": slug, "work": work id,
   "span": [{"from": "…", "to": "…"}] or "text": "…", "verse": optional, "speaker": optional,
   "speaker_ok": optional, "location": "Book IV, §17", "themes": [...], "mood": "...",
   "rubric": {"stands_alone": 0-3, "turn": 0-3, "image": 0-3, "charge": 0-3, "readability": 0-3,
              "fame": 0-3}, "recommend": "keep"|"skip", "why": "…", "flags": [...]}
"""

import json
import os

from . import config, corpus, registry, verify
from .rejects import RejectList

# Plan section 4.6 weights; brevity is computed from the length (the starters' median is 91.5).
WEIGHTS = {"fame": 20, "stands_alone": 15, "turn": 20, "image": 10, "charge": 15, "brevity": 10, "readability": 10}


def brevity(n):
    if n <= 100:
        return 3
    if n <= 160:
        return 2
    if n <= 220:
        return 1
    return 0


def score(rubric, body_len):
    r = dict(rubric or {})
    r["brevity"] = brevity(body_len)
    total = sum(WEIGHTS[k] * r.get(k, 0) / 3.0 for k in WEIGHTS)
    if r.get("stands_alone", 0) == 0 or r.get("readability", 0) == 0:
        total = 0.0
    return round(total, 1), r


def run_dir(name):
    d = os.path.join(config.build_dir(), "runs", name)
    os.makedirs(d, exist_ok=True)
    return d


def verify_leads(leads_path, run_name, as_of=None):
    reg = registry.Registry.load()
    lock = corpus.load_lock()
    rejects = RejectList.load(live=True)
    leads = registry.read_jsonl(leads_path)
    out = []
    counts = {}
    from . import fetch, version
    checked_at = fetch.now()
    tree = version.tree_id()
    for lead in leads:
        r = verify.verify(lead, reg, lock, as_of, rejects)
        r["checked_at"] = checked_at
        r["verifier_version"] = tree
        if r.get("ref", "").startswith("ws:"):
            r["wikisource_oldid"] = lock[r["ref"]]["oldid"]
        r["final"] = verify.final_class(r)
        r["auto_pass"] = verify.auto_pass(r)
        if r.get("body"):
            r["score"], r["rubric"] = score(lead.get("rubric"), len(r["body"]))
        for k in ("location", "themes", "mood", "recommend", "why", "lead_source", "author", "work"):
            if k in lead:
                r.setdefault("lead_" + k, lead[k])
        r["lead"] = lead
        counts[r["final"]] = counts.get(r["final"], 0) + 1
        out.append(r)
    d = run_dir(run_name)
    with open(os.path.join(d, "results.jsonl"), "w", encoding="utf-8") as f:
        for r in out:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
    print(json.dumps(counts, sort_keys=True))
    print("results:", os.path.join(d, "results.jsonl"))
    return 0
