"""Verifying one lead: find it in the cited work, render the body from the source, classify it,
apply the public-domain rule and the reject list, and note who speaks it.

A lead is a dict:
  text      the claimed wording (optional; a lookup key only, never stored), or
  span      [{"from": "first words", "to": "last words"}, …] lookup keys for a passage
  author    author slug or exact name (the claimed author)
  work      work id (the claimed work), or None to search the author's works
  verse     True/False to override the work's form
  speaker   the speaker, when the reviewer already knows it

Result classes (plan section 4.4): PASS_EXACT, PASS_TYPOGRAPHIC, PASS_ELIDED, NEAR_MISS,
FOUND_ELSEWHERE, NOT_FOUND, REJECT_PD, REJECT_MISATTRIBUTED, CITED_WORK_MISSING; flags on top.
Only PASS_EXACT and PASS_TYPOGRAPHIC with no blocking flag skip the diff review, and every kept
line still needs the founder's decision.
"""

import re

from . import corpus, match, pd, render
from .normalize import tokenize, NORMALISER_VERSION
from . import config

VERIFIER_SEMVER = "1.1.0"
PASSING = ("PASS_EXACT", "PASS_TYPOGRAPHIC", "PASS_ELIDED")
BLOCKING_FLAGS = {"REJECT_LENGTH", "NEEDS_SPEAKER", "punctuation_differs", "end_punct_differs", "matches_variant",
                  "occurrences>1", "typography_ambiguous", "stanza_break", "gap_has_negation",
                  "straight_quote", "also_misattributed_to", "disputed_variant", "earlier_elsewhere", "quoting_someone"}
DRAMA_LABEL = re.compile(r"^\s*([A-Z][A-Z .'’&-]{1,40}(?: and [A-Z][A-Z .'’&-]+)*)\.(?:\s|$)")
DRAMA_HEAD = re.compile(r"^\s*(ACT|SCENE) [IVXLC]+", re.M)
QUOTING = re.compile(r"\b(?:as \w+ (?:says|said|wrote|has said)|says \w+|in the words of|it has been said|the poet (?:says|said|sings|tells us))\b", re.I)


def _norm_text(s):
    return " ".join(tokenize(s).words)


def is_verse(work, text, span):
    """The work's form, or for drama whether the span's source lines look like verse."""
    form = work.get("form", "prose")
    if form in ("verse", "lines"):
        return form
    if form != "drama":
        return False
    tok = text.tokens
    a, b = tok.starts[span.start], tok.ends[span.end - 1]
    ls = text.body.rfind("\n", 0, a) + 1
    le = text.body.find("\n", b)
    lines = text.body[ls: le if le >= 0 else len(text.body)].split("\n")
    if len(lines) < 2:
        return False
    return all(len(ln.strip()) <= 62 for ln in lines[:-1]) and all(
        (ln.strip()[:1].isupper() or not ln.strip()) for ln in lines[1:])


def speaker_of(work, text, span):
    """Who speaks the matched words: {"kind": author|character|drama|quoted_other, "name", "evidence"}."""
    body = text.body
    a = text.tokens.starts[span.start]
    kind = work.get("kind", "")
    if work.get("form") == "drama":
        i = a
        for _ in range(400):
            ls = body.rfind("\n", 0, i)
            line = body[ls + 1: i if i != a else body.find("\n", a)]
            if DRAMA_HEAD.match(line or ""):
                break
            m = DRAMA_LABEL.match(line or "")
            if m and m.group(1).strip() not in ("I", "A", "O"):
                return {"kind": "drama", "name": m.group(1).strip().title(), "evidence": line.strip()[:80]}
            if ls < 0:
                break
            i = ls
        return {"kind": "drama", "name": None, "evidence": "no speaker label found"}
    # Inside quotation marks in its paragraph?
    ps = body.rfind("\n\n", 0, a) + 2
    para = body[max(ps, 0):a]
    opened = para.count("“") - para.count("”")
    straight = para.count('"') % 2 == 1
    if opened > 0 or straight:
        before = para[-160:]
        if kind in ("essay", "speech", "sayings", "letters") or work.get("default_voice") == "author":
            return {"kind": "quoted_other", "name": None, "evidence": "inside quotation marks in an %s" % (kind or "essay")}
        return {"kind": "character", "name": None, "evidence": "inside quotation marks: …" + before[-60:]}
    window = body[max(0, a - 120):a]
    if QUOTING.search(window):
        return {"kind": "quoted_other", "name": None, "evidence": window.strip()[-80:]}
    after = body[text.tokens.ends[span.end - 1]: text.tokens.ends[span.end - 1] + 200]
    m = re.match(r"[^\n]*\n\s*(?:--|—)\s*\S", after)
    if m and kind in ("essay", "prose", "novel", "speech", ""):
        return {"kind": "quoted_other", "name": None, "evidence": "followed by an attribution line"}
    return {"kind": "author", "name": None, "evidence": ""}


def classify_text(lead_text, rendered):
    """PASS_EXACT when the rendered body is the lead; PASS_TYPOGRAPHIC when only quote, dash,
    space or case styles differ; else PASS_TYPOGRAPHIC with punctuation_differs (shown with a diff)."""
    if lead_text is None:
        return "PASS_EXACT", []
    if rendered == lead_text:
        return "PASS_EXACT", []

    def style(s):
        s = re.sub(r"[‘’'`]", "'", s)
        s = re.sub(r"[“”\"]", '"', s)
        s = re.sub(r"(?:--|—|–)", "-", s)
        return re.sub(r"\s+", " ", s).strip().lower()
    if style(rendered) == style(lead_text):
        return "PASS_TYPOGRAPHIC", []
    return "PASS_TYPOGRAPHIC", ["punctuation_differs"]


def locate(lead, text):
    """(chains, lead_words, kind) where kind is 'text' or 'span'."""
    if lead.get("span"):
        chains = []
        keys = lead["span"]
        for seg in keys:
            if not seg.get("from") or not seg.get("to"):
                raise ValueError("a span key needs from and to")
        # Each key is a (from … to) passage; consecutive keys are elided segments.
        froms = [tokenize(s["from"]).words for s in keys]
        tos = [tokenize(s["to"]).words for s in keys]
        tok = text.tokens
        first_hits = tok.find_all(froms[0])
        for h in first_hits:
            segs = []
            pos = h
            ok = True
            for k in range(len(keys)):
                start = pos if k == 0 else None
                if k > 0:
                    nxt = [x for x in tok.find_all(froms[k]) if x >= pos][:1]
                    if not nxt or nxt[0] - pos > config.THRESHOLDS["elision_max_gap_tokens"]:
                        ok = False
                        break
                    start = nxt[0]
                ends = [x for x in tok.find_all(tos[k]) if x >= start][:1]
                if not ends or ends[0] - start > 200:
                    ok = False
                    break
                end = ends[0] + len(tos[k])
                segs.append((start, end))
                pos = end
            if ok:
                chains.append(match.Span(segs))
        # Two starts that reach the same end (verses that open alike): keep the shortest span.
        best = {}
        for c in chains:
            if c.end not in best or c.start > best[c.end].start:
                best[c.end] = c
        chains = sorted(best.values(), key=lambda c: c.start)
        return chains, None, "span"
    segs, _ = match.parse_lead(lead["text"])
    sw = match.lead_words(segs)
    return match.find_chains(text.tokens, sw), sw, "text"


def verify(lead, reg, lock, as_of=None, rejects=None, corpus_refs=None):
    out = {"lead_id": lead.get("lead_id"), "flags": [], "verifier": VERIFIER_SEMVER,
           "normaliser": NORMALISER_VERSION, "thresholds": config.THRESHOLDS_SHA}
    try:
        credited = reg.author(lead["author"])
    except KeyError:
        out.update(cls="CITED_WORK_MISSING", detail="unknown author %r" % lead.get("author"))
        return out
    out["author"] = credited["name"]
    works = [reg.work(lead["work"])] if lead.get("work") is not None else reg.works_by(credited["id"])
    if not works:
        out.update(cls="CITED_WORK_MISSING", detail="no work by %s in the registry" % credited["name"])
        return _reject_check(out, lead, credited, rejects)
    found = None
    near = None
    missing = []
    for w in works:
        try:
            text = corpus.load(w["ref"], lock)
        except corpus.CorpusError as e:
            missing.append(str(e))
            continue
        chains, lw, kind = locate(lead, text)
        if chains:
            found = (w, text, chains, kind)
            break
        if lw:
            flat = [x for s in lw for x in s]
            r = match.best_near(text.tokens, flat)
            if r and (near is None or r[0] > near[0][0]):
                near = (r, w, text, flat)
    if found is None and missing and near is None and len(missing) == len(works):
        out.update(cls="CITED_WORK_MISSING", detail="; ".join(missing))
        return _reject_check(out, lead, credited, rejects)

    if found:
        w, text, chains, kind = found
        span = chains[0]
        verse = lead.get("verse") if lead.get("verse") is not None else is_verse(w, text, span)
        r = render.render(text, span, verse=verse, lead=lead.get("text"), end=lead.get("end", "close"))
        if len(chains) > 1:
            out["flags"].append("occurrences>1")
        out["flags"].extend(r["flags"])
        if len(span.segments) > 1:
            cls = "PASS_ELIDED"
            if lead.get("text") is not None and r["body"] != lead["text"]:
                out["flags"].append("punctuation_differs")
        else:
            cls, extra = classify_text(lead.get("text"), r["body"])
            out["flags"].extend(extra)
        sp = lead.get("speaker_info") or speaker_of(w, text, span)
        if lead.get("speaker"):
            sp = dict(sp, name=lead["speaker"], resolved=True)
        out["speaker"] = sp
        if lead.get("speaker_ok"):
            sp = dict(sp, resolved=True)
        elif sp["kind"] == "quoted_other":
            out["flags"].append("NEEDS_SPEAKER")
        elif sp["kind"] in ("character", "drama") and not sp.get("name"):
            out["flags"].append("NEEDS_SPEAKER")
        out.update(cls=cls, work_id=w["id"], source=w["citation"], ref=w["ref"],
                   body=r["body"], edits=r["edits"], prefix_dropped=r["prefix_dropped"],
                   start=r["start"], end=r["end"], body_sha256=text.body_sha256, verse=r["verse"],
                   source_text=text.body[r["start"]: r["end"]],
                   context_before=text.body[max(0, r["start"] - 400): r["start"]],
                   context_after=text.body[r["end"]: r["end"] + 400],
                   gaps=r["gaps"], segments=[[text.tokens.starts[s], text.tokens.ends[e - 1]] for s, e in span.segments])
        work_author = reg.author(w["author_id"])
        out["pd"] = pd.verdict(w, credited, work_author, as_of)
        if not out["pd"]["ok"]:
            out["pd_class"] = "REJECT_PD"
    elif near:
        r, w, text, flat = near
        nc = match.near_class(r)
        ratio, coverage, longest, a0, a1, ops, span_words = r
        if nc:
            diff = match.diff_ops(flat, span_words, ops)
            out.update(cls="NEAR_MISS", near=nc, ratio=round(ratio, 3), coverage=round(coverage, 3),
                       work_id=w["id"], source=w["citation"], ref=w["ref"],
                       diff=diff, inline=match.inline_diff(flat, span_words, ops),
                       source_text=re.sub(r"\s+", " ", text.body[text.tokens.starts[a0]: text.tokens.ends[a1 - 1]]))
            if diff and all(d["kind"] in ("join_split", "spelling") for d in diff):
                out["flags"].append("orthographic_only")
        else:
            out.update(cls="NOT_FOUND", best_ratio=round(ratio, 3), work_id=w["id"])
    else:
        out.update(cls="NOT_FOUND", best_ratio=0.0)

    if out["cls"] in ("NOT_FOUND",) or (out["cls"] == "NEAR_MISS" and out.get("near") == "low"):
        el = elsewhere(lead, reg, lock, exclude_author=None, corpus_refs=corpus_refs, skip_refs={w["ref"] for w in works})
        if el:
            out["elsewhere"] = el
            if out["cls"] == "NOT_FOUND" and el[0]["ratio"] >= config.THRESHOLDS["near_low_ratio"]:
                out["cls"] = "FOUND_ELSEWHERE"
    if not lead.get("text") and out.get("body") is None:
        pass
    return _reject_check(out, lead, credited, rejects)


def elsewhere(lead, reg, lock, exclude_author=None, corpus_refs=None, skip_refs=()):
    """Alignments of the lead in every other pinned text (compilations excluded), best first."""
    if not lead.get("text"):
        return []
    segs, _ = match.parse_lead(lead["text"])
    flat = [w for s in match.lead_words(segs) for w in s]
    hits = []
    refs = corpus_refs if corpus_refs is not None else sorted(lock)
    by_ref = {}
    for w in reg.works.values():
        by_ref.setdefault(w["ref"], w)
    for ref in refs:
        if ref in skip_refs:
            continue
        w = by_ref.get(ref)
        if w is not None and w.get("kind") == "compilation":
            continue
        try:
            text = corpus.load(ref, lock)
        except corpus.CorpusError:
            continue
        exact = text.tokens.find_all(flat)
        if exact:
            hits.append({"ref": ref, "work_id": w["id"] if w else None, "ratio": 1.0,
                         "author": reg.author(w["author_id"])["name"] if w else None})
            continue
        r = match.best_near(text.tokens, flat)
        if r and r[0] >= config.THRESHOLDS["near_low_ratio"] and match.near_class(r):
            hits.append({"ref": ref, "work_id": w["id"] if w else None, "ratio": round(r[0], 3),
                         "author": reg.author(w["author_id"])["name"] if w else None})
    hits.sort(key=lambda h: -h["ratio"])
    return hits[:3]


def _reject_check(out, lead, credited, rejects):
    """REJECT_MISATTRIBUTED when the wording sits on the claimed author's own Misattributed or
    Disputed list; only a flag when it sits on someone else's."""
    if not rejects:
        return out
    probe = out.get("body") or lead.get("text")
    if not probe:
        return out
    hit = rejects.lookup(probe)
    if not hit:
        return out
    names = {credited["name"], credited.get("wikiquote")} | set(credited.get("aliases", []))
    mine = [h for h in hit if h["author"] in names or h.get("author_slug") == credited["slug"]]
    # Misattributed and Disputed entries reject; a Variant or Misquote entry only says the line
    # circulates in another wording, which the body (rendered from the source) is not.
    mine_rejects = [h for h in mine if h.get("kind") in ("misattributed", "disputed", "rejected")]
    # An entry in other words, when the body itself was found in the credited author's own pinned
    # work, disputes a variant (Twain's "endeavor to live so" against Pudd'nhead Wilson's "endeavor
    # so to live"). It holds the line for review; the exact wording still rejects.
    if mine_rejects and out.get("cls") in ("PASS_EXACT", "PASS_TYPOGRAPHIC") and \
            not any(h["same_words"] for h in mine_rejects):
        out["flags"].append("disputed_variant")
        out["variant_hit"] = mine_rejects[0]
    elif mine_rejects:
        out["reject_hit"] = mine_rejects[0]
        out["rejected_as"] = "REJECT_MISATTRIBUTED"
    elif mine:
        out["flags"].append("matches_variant")
        out["variant_hit"] = mine[0]
    others = [h for h in hit if h not in mine and h.get("kind") in ("misattributed", "disputed", "rejected")]
    if others:
        out["flags"].append("also_misattributed_to")
        out["reject_other"] = others[0]
    return out


def final_class(out):
    """The class shown first: the public-domain and misattribution rejects outrank the match."""
    if out.get("rejected_as"):
        return out["rejected_as"]
    if out.get("pd_class") and out["cls"] in PASSING:
        return out["pd_class"]
    return out["cls"]


def auto_pass(out):
    return final_class(out) in ("PASS_EXACT", "PASS_TYPOGRAPHIC") and not (set(out["flags"]) & BLOCKING_FLAGS)
