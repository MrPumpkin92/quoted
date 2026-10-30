"""The gate (plan section 5). Nothing the verifier produces is trusted until this is green.

1. All 60 starters render byte-identical to the shipped bodies against their pinned sources, with
   the exact class and edits their fixture expects. A row that is not a plain PASS_EXACT carries a
   wording judgement; a wording judgement on a plain PASS_EXACT fails ("no longer needed").
   The strict public-domain verdicts in pd_cases.jsonl hold (#4, #27, #42, #50 fail today; #42
   clears on 2027-01-01).
2. None of the 21 known misattributions passes or would be sealed under its false attribution.
3. The 7 verified-but-cut lines pass the wording check; Shaw fails the strict rule until 2031.
4. The two paraphrases never pass (Marcus: a low near miss; Tolstoy: not found).
5. The negatives behave as specified, and nothing among rejects and negatives auto-passes.
6. No starter hits the reject list for its own author.
7. Precision and recall are reported.
"""

import datetime
import json
import os

from . import config, corpus, pd, registry, starters as starters_mod, verify
from .rejects import RejectList

WORDING_JUDGEMENTS = {"close_period", "elision", "trim", "trim_undocumented"}
GATE_AS_OF = "2026-10-28"


def _fixtures(name):
    return registry.read_jsonl(os.path.join(config.data_dir(), "fixtures", name))


def run(live_rejects=False, out_dir=None, quiet=False):
    reg = registry.Registry.load()
    lock = corpus.load_lock()
    rejects = RejectList.load(live=live_rejects)
    shipped = {q["id"]: q for q in starters_mod.load()}
    failures = []
    rows = []

    def fail(section, key, msg):
        failures.append("%s %s: %s" % (section, key, msg))

    # ---- 1. starters
    should_pass = passed = 0
    for fx in _fixtures("starters.jsonl"):
        q = shipped[fx["id"]]
        w = reg.works[fx["work_id"]]
        key = "#%d" % fx["id"]
        if w["citation"] != q["source"]:
            fail("starter", key, "registry citation %r is not the shipped source %r" % (w["citation"], q["source"]))
        try:
            credited = reg.author(q["author"])
        except KeyError:
            fail("starter", key, "author %r is not in the registry" % q["author"])
            continue
        lead = {"lead_id": "starter-%d" % fx["id"], "text": q["body"], "author": q["author"], "work": w["id"],
                "speaker": fx.get("speaker"), "speaker_ok": fx.get("speaker_ok", False)}
        r = verify.verify(lead, reg, lock, GATE_AS_OF, rejects)
        rows.append({"section": "starter", "key": key, **_slim(r)})
        should_pass += 1
        exp = fx["expect"]
        ok = True
        if r["cls"] != exp["cls"]:
            fail("starter", key, "class %s, expected %s (%s)" % (r["cls"], exp["cls"], r.get("detail") or r.get("inline") or ""))
            ok = False
        if r.get("body") is not None and r["body"] != q["body"]:
            fail("starter", key, "rendered %r, shipped %r" % (r["body"], q["body"]))
            ok = False
        if r.get("edits") is not None and r["edits"] != exp["edits"]:
            fail("starter", key, "edits %s, expected %s" % (r["edits"], exp["edits"]))
            ok = False
        wording = [j for j in fx.get("judgements", []) if j["kind"] in WORDING_JUDGEMENTS]
        plain = r["cls"] == "PASS_EXACT" and not r.get("edits")
        if not plain and not wording:
            fail("starter", key, "%s with edits %s needs a wording judgement in the fixture" % (r["cls"], r.get("edits")))
            ok = False
        if plain and wording:
            fail("starter", key, "judgement no longer needed (it now passes plainly): update the fixture")
            ok = False
        if "NEEDS_SPEAKER" in r["flags"]:
            fail("starter", key, "needs a speaker the fixture doesn't give (%s)" % r.get("speaker", {}).get("evidence"))
            ok = False
        if r.get("rejected_as"):
            fail("starter", key, "hits the reject list for its own author: %s" % r.get("reject_hit"))
            ok = False
        passed += ok

    for case in _fixtures("pd_cases.jsonl"):
        w = reg.works[case["starter"]]
        q = shipped[case["starter"]]
        v = pd.verdict(w, reg.author(q["author"]), reg.author(w["author_id"]), case["as_of"])
        if v["strict"] != case["strict"]:
            fail("pd", "#%d@%s" % (case["starter"], case["as_of"]), "strict is %s, expected %s (%s)" % (
                v["strict"], case["strict"], "; ".join(v["blocking"])))

    # ---- 2. the 21 known misattributions
    should_block = blocked = 0
    autopassed = []
    for fx in _fixtures("rejects.jsonl"):
        key = "#%d %s" % (fx["n"], fx["author"])
        r = verify.verify({"lead_id": "reject-%d" % fx["n"], "text": fx["text"], "author": fx["author"], "work": None},
                          reg, lock, GATE_AS_OF, rejects)
        final = verify.final_class(r)
        rows.append({"section": "reject", "key": key, "final": final, **_slim(r)})
        should_block += 1
        if final in verify.PASSING:
            fail("reject", key, "passes as %s under its false attribution" % final)
            autopassed.append(key)
        elif final not in fx["expect_any_of"] and r["cls"] not in fx["expect_any_of"]:
            fail("reject", key, "came back %s (%s), expected one of %s" % (final, r["cls"], fx["expect_any_of"]))
        else:
            blocked += 1

    # ---- 3. the 7 verified-but-cut lines
    for fx in _fixtures("cutlines.jsonl"):
        a = reg.author(fx["author"])
        w = reg.work_by_citation(a["id"], fx["citation"])
        r = verify.verify({"lead_id": "cut-" + fx["key"], "text": fx["text"], "author": fx["author"], "work": w["id"]},
                          reg, lock, GATE_AS_OF, rejects)
        rows.append({"section": "cutline", "key": fx["key"], "final": verify.final_class(r), **_slim(r)})
        should_pass += 1
        ok = r["cls"] in verify.PASSING
        if not ok:
            fail("cutline", fx["key"], "wording class %s (%s)" % (r["cls"], r.get("detail") or r.get("inline") or ""))
        elif r["pd"]["ok"] != fx["pd_ok"]:
            fail("cutline", fx["key"], "public-domain verdict %s, expected %s" % (r["pd"]["ok"], fx["pd_ok"]))
            ok = False
        elif fx.get("clears_on"):
            got = pd.clears_on(w, a, reg.author(w["author_id"]))
            if got != fx["clears_on"]:
                fail("cutline", fx["key"], "clears on %s, expected %s" % (got, fx["clears_on"]))
                ok = False
            elif verify.final_class(r) != "REJECT_PD":
                fail("cutline", fx["key"], "should be REJECT_PD until %s" % fx["clears_on"])
                ok = False
        passed += ok

    # ---- 4 and 5. paraphrases and negatives
    for fx in _fixtures("negatives.jsonl"):
        a = reg.author(fx["author"])
        w = reg.work_by_citation(a["id"], fx["citation"])
        text = shipped[fx["starter_body"]]["body"] if fx.get("starter_body") else fx["text"]
        r = verify.verify({"lead_id": "neg-" + fx["key"], "text": text, "author": fx["author"], "work": w["id"]},
                          reg, lock, GATE_AS_OF, rejects)
        rows.append({"section": "negative", "key": fx["key"], "final": verify.final_class(r), **_slim(r)})
        should_block += 1
        exp = fx["expect"]
        ok = True
        if "renders_starter" in exp and (r.get("body") == text) != exp["renders_starter"]:
            fail("negative", fx["key"], "renders the shipped body: %r" % r.get("body"))
            ok = False
        if "cls" in exp and r["cls"] != exp["cls"]:
            fail("negative", fx["key"], "class %s (ratio %s), expected %s" % (r["cls"], r.get("ratio") or r.get("best_ratio"), exp["cls"]))
            ok = False
        if "near" in exp and r.get("near") != exp["near"]:
            fail("negative", fx["key"], "near miss %s (ratio %s), expected %s" % (r.get("near"), r.get("ratio"), exp["near"]))
            ok = False
        if "flag" in exp and exp["flag"] not in r["flags"]:
            fail("negative", fx["key"], "lacks flag %s (flags %s)" % (exp["flag"], r["flags"]))
            ok = False
        if verify.auto_pass(r):
            fail("negative", fx["key"], "auto-passes")
            autopassed.append(fx["key"])
            ok = False
        blocked += ok

    # ---- 7. report
    precision = (passed / (passed + len(autopassed))) if passed + len(autopassed) else 0.0
    recall = passed / should_pass if should_pass else 0.0
    summary = {
        "as_of": GATE_AS_OF,
        "starters_ok": sum(1 for r in rows if r["section"] == "starter") and passed,
        "should_pass": should_pass, "passed": passed,
        "should_block": should_block, "blocked": blocked,
        "auto_passes_among_blocked": len(autopassed),
        "precision": round(precision, 4), "recall": round(recall, 4),
        "failures": failures,
        "reject_list_entries": len(rejects),
        "verifier": verify.VERIFIER_SEMVER,
    }
    out_dir = out_dir or os.path.join(config.build_dir(), "runs",
                                      "acceptance-" + datetime.datetime.now().strftime("%Y%m%dT%H%M%S"))
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "results.jsonl"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write(report_md(summary, rows))
    summary["out_dir"] = out_dir
    return summary


def _slim(r):
    keep = ("cls", "flags", "edits", "body", "ratio", "best_ratio", "near", "inline", "ref", "work_id", "detail",
            "rejected_as", "reject_hit", "elsewhere", "speaker", "prefix_dropped", "start", "end", "body_sha256")
    out = {k: r[k] for k in keep if k in r}
    if "pd" in r:
        out["pd"] = {k: r["pd"][k] for k in ("us", "life70", "strict", "ok", "blocking")}
    return out


def report_md(summary, rows):
    lines = ["# Verifier gate (%s)" % ("GREEN" if not summary["failures"] else "RED"), "",
             "As of %s. Verifier %s, reject list %d entries." % (summary["as_of"], summary["verifier"], summary["reject_list_entries"]), "",
             "| Should pass | Passed | Should be blocked | Blocked | Auto-passes among blocked | Precision | Recall |",
             "|---:|---:|---:|---:|---:|---:|---:|",
             "| %d | %d | %d | %d | %d | %.3f | %.3f |" % (summary["should_pass"], summary["passed"], summary["should_block"],
                                                       summary["blocked"], summary["auto_passes_among_blocked"],
                                                       summary["precision"], summary["recall"]), ""]
    if summary["failures"]:
        lines += ["## Failures", ""] + ["- " + f for f in summary["failures"]] + [""]
    lines += ["## Rows", "", "| Section | Key | Class | Final | Flags | Edits |", "|---|---|---|---|---|---|"]
    for r in rows:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (r["section"], r["key"], r.get("cls"), r.get("final", r.get("cls")),
                                                         ", ".join(r.get("flags", [])),
                                                         ", ".join(e["kind"] for e in r.get("edits") or [])))
    return "\n".join(lines) + "\n"
