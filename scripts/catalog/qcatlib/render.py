"""Rendering the stored body from the matched source span.

The body is always the source's own words: the text between the first and last matched token,
plus its closing punctuation. Curatorial edits are explicit and recorded:

- capitalise_first: the span starts mid-sentence (the dropped prefix is recorded);
- close_period(was): a trailing , ; : or dash (or none) becomes a period;
- elide(style): ordered segments joined by " … " (prose) or " …" at the end of a kept verse line.

Typography is typographic (’ ‘ “ ” —), prose whitespace collapses, verse keeps one source line per
body line. The result is NFC, because the seal is an exact string match.
"""

import re
import unicodedata

from .normalize import APPARATUS, SINGLE_QUOTES, DOUBLE_QUOTES

OPEN_DOUBLE = "“„«"
CLOSE_DOUBLE = "”»"
STRAIGHT_PUNCT = ".,;:!?"
TERMINAL = ".!?"
ELISION_WORDS = {"tis", "twas", "twere", "twill", "twould", "em", "neath", "gainst", "twixt", "tween",
                 "mid", "midst", "o", "er", "ere"}
NEGATIONS = re.compile(r"\b(?:not|no|never|nor|but|none|nothing)\b", re.I)


class RenderError(Exception):
    pass


def _is_quote_char(c):
    return c in SINGLE_QUOTES or c in DOUBLE_QUOTES


def _sentence_prefix(orig, a, verse):
    """The text between the start of the sentence and a, or '' when a starts the sentence. A verse
    line's capital doesn't start a sentence."""
    i = a - 1
    while i >= 0 and orig[i] in " \t":
        i -= 1
    # A quotation that opens right before the span with a capital starts a sentence ("The Master
    # said, 'The wise …'"); one that reopens after a speech tag in lower case does not.
    if i >= 0 and orig[i] in "“‘\"'" and orig[a:a + 1].isupper():
        return ""
    # Skip opening quotes, brackets and whitespace right before the span.
    while i >= 0 and (orig[i] in " \t" or orig[i] in "“‘\"'(["):
        i -= 1
    if i < 0:
        return ""
    if orig[i] == "\n":
        j = i
        while j >= 0 and orig[j] in "\n \t":
            j -= 1
        if j < 0 or orig[i - 1: i + 1] == "\n\n" or "\n\n" in orig[j: i + 1]:
            return ""
        i = j
    if orig[i] in TERMINAL or (orig[i] in "”’\"')" and i > 0 and orig[i - 1] in TERMINAL):
        return ""
    # Walk back to the sentence start for the record.
    k = i
    while k >= 0:
        if orig[k] in TERMINAL and (k + 1 >= len(orig) or orig[k + 1] in " \n”’\"')"):
            break
        if orig[k: k + 2] == "\n\n":
            break
        k -= 1
    prefix = re.sub(r"\s+", " ", orig[k + 1: a]).lstrip(" ”’\"')")
    # A section or poem number ("6", "XLIII.") is not part of the sentence.
    if re.fullmatch(r"\s*(?:\d+|[IVXLCDM]+)\.?\s*", prefix):
        return ""
    return prefix


def _end_run(orig, b):
    """The punctuation and closing marks right after token end b: (run, end index)."""
    j = b
    while j < len(orig) and (orig[j] in STRAIGHT_PUNCT or orig[j] in "…)]" or _is_quote_char(orig[j])
                             or orig[j] in "—–" or orig[j: j + 2] == "--"):
        if orig[j: j + 2] == "--":
            j += 2
        else:
            j += 1
    return orig[b:j], j


def _balance(text):
    """Unclosed opening (double quotes, single quotes, parentheses) inside text."""
    d = s = p = 0
    for i, c in enumerate(text):
        if c in OPEN_DOUBLE:
            d += 1
        elif c in CLOSE_DOUBLE:
            d -= 1
        elif c == '"':
            d = d - 1 if d > 0 else d + 1
        elif c == "‘":
            s += 1
        elif c == "(":
            p += 1
        elif c == ")":
            p -= 1
    return d, s, p


def _clean(text):
    text = APPARATUS.sub("", text)
    return text.replace("_", "").replace("­", "").replace("​", "").replace("﻿", "")


def _indent(line):
    return len(line) - len(line.lstrip(" \t\u2003\u2002"))


def _whitespace(text, verse):
    if not verse:
        return re.sub(r"\s+", " ", text).strip(), False
    if verse == "lines":
        # Each paragraph is one line; the transcriber's wraps inside it are spaces.
        paras = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n[ \t]*\n", text)]
        return "\n".join(p for p in paras if p), False
    raw = text.split("\n")
    stanza_break = any(not ln.strip() for ln in raw[1:-1])
    lines = []
    prev_indent = None
    for ln in raw:
        if not ln.strip():
            continue
        body = re.sub(r"[ \t\u2003\u2002]+", " ", ln.strip())
        # A long verse line the transcriber wrapped: the rest is indented deeper and starts in
        # lower case. It joins the line before.
        if lines and prev_indent is not None and _indent(ln) > prev_indent and body[:1].islower():
            lines[-1] += " " + body
            continue
        lines.append(body)
        prev_indent = _indent(ln)
    return "\n".join(lines), stanza_break


def typography(text):
    """Straight quotes and double hyphens to typographic marks. Returns (text, ambiguous)."""
    ambiguous = False
    text = re.sub(r"-{2,}", "—", text)
    out = []
    n = len(text)
    for i, c in enumerate(text):
        prev = text[i - 1] if i > 0 else ""
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "'":
            if prev.isalnum() or prev in STRAIGHT_PUNCT or prev in "”’)]—" and not nxt.isalnum():
                out.append("’")
            elif nxt.isalnum():
                word = re.match(r"[A-Za-z]+", text[i + 1:])
                if word and word.group().lower() in ELISION_WORDS:
                    out.append("’")
                else:
                    out.append("‘")
                    ambiguous = ambiguous or prev not in ("", " ", "\n", "“", "(", "—")
            else:
                out.append("’")
        elif c == '"':
            if prev in ("", " ", "\n", "(", "[", "—", "‘") or (not prev.isalnum() and nxt.isalnum() and prev not in STRAIGHT_PUNCT):
                out.append("“")
            else:
                out.append("”")
        else:
            out.append(c)
    return "".join(out), ambiguous


def lead_shape(lead):
    """What a lead asks for at its ends: (starts with a capital, trailing punctuation)."""
    first = next((c for c in lead if c.isalpha()), "")
    m = re.search(r"[.,;:!?…]*[)”’\"']*$", lead.rstrip())
    tail = m.group() if m else ""
    tail_punct = "".join(c for c in tail if c in STRAIGHT_PUNCT)
    return first.isupper(), tail_punct


def render(text, span, verse=False, lead=None, end="close"):
    """Render a match. `span` is a match.Span over text.tokens. Returns a dict with body, edits,
    flags, the code point range [start, end) of the source used, the dropped prefix and the gaps."""
    orig = text.body
    tok = text.tokens
    want_capital, want_tail = (True, None) if lead is None else lead_shape(lead)
    edits, flags = [], []
    segs = span.segments

    # ---- start
    a = tok.starts[segs[0][0]]
    if a > 0 and orig[a - 1] in SINGLE_QUOTES and (a < 2 or not orig[a - 2].isalnum()):
        w = tok.words[segs[0][0]]
        if w in ELISION_WORDS or (lead is not None and lead.lstrip()[:1] in SINGLE_QUOTES):
            a -= 1
    prefix = _sentence_prefix(orig, a, verse)

    # ---- segments
    pieces = []
    gaps = []
    last_end = a
    for k, (s, e) in enumerate(segs):
        sa = a if k == 0 else tok.starts[s]
        sb = tok.ends[e - 1]
        if k > 0:
            gaps.append(orig[last_end:sa])
        if k < len(segs) - 1:
            run, run_end = _end_run(orig, sb)
            line_end = verse and orig[run_end: run_end + 1] == "\n"
            if line_end:
                kept = "".join(c for c in run if c in STRAIGHT_PUNCT)
                pieces.append((orig[sa:sb] + kept, "line"))
            else:
                pieces.append((orig[sa:sb], "inline"))
            last_end = sb
        else:
            pieces.append((orig[sa:sb], None))
            last_end = sb
    b = last_end

    # ---- end
    run, run_end = _end_run(orig, b)
    body_so_far = "".join(p for p, _ in pieces)
    d, s_open, p_open = _balance(body_so_far)
    kept = []
    for c in run:
        if c in CLOSE_DOUBLE or c == '"':
            if d > 0:
                kept.append(c)
                d -= 1
        elif c in "’'":
            if s_open > 0:
                kept.append(c)
                s_open -= 1
        elif c == ")":
            if p_open > 0:
                kept.append(c)
                p_open -= 1
        elif c in STRAIGHT_PUNCT or c == "…":
            kept.append(c)
        elif c in "—–-":
            kept.append(c)
        else:
            break
    tail = "".join(kept)
    bare_tail = tail.rstrip("—–-")
    if bare_tail != tail and "".join(c for c in bare_tail if c in STRAIGHT_PUNCT)[-1:] in tuple(TERMINAL):
        # "wrong!—" or "sorry.--": the sentence ends there; the dash leads into what follows.
        edits.append({"kind": "drop_end_punct", "was": tail[len(bare_tail):]})
        tail = bare_tail
    punct = "".join(c for c in tail if c in STRAIGHT_PUNCT)
    end_index = b + len(run)
    if not tail and end == "as_is":
        final = ""
    elif punct and punct[-1] in TERMINAL and not tail.endswith(("—", "–", "-")):
        # Keep the sentence's own ending (closing marks it opened stay).
        final = tail
        if want_tail is not None and want_tail != punct:
            flags.append("end_punct_differs")
    else:
        was = punct or ("—" if any(c in "—–-" for c in tail) else "")
        bare = "".join(c for c in tail if c not in STRAIGHT_PUNCT and c not in "—–-")
        if want_tail is None or want_tail.endswith("."):
            final = "." + bare
            edits.append({"kind": "close_period", "was": was})
        elif want_tail == "":
            final = bare
            if was:
                edits.append({"kind": "drop_end_punct", "was": was})
        else:
            final = tail
            if want_tail != punct:
                flags.append("end_punct_differs")
    pieces[-1] = (pieces[-1][0] + final, None)

    # ---- assemble, clean, typography
    out = []
    for k, (p, how) in enumerate(pieces):
        txt, stanza = _whitespace(_clean(p), verse)
        if stanza:
            flags.append("stanza_break")
        out.append(txt)
        if k < len(pieces) - 1:
            out.append(" …\n" if how == "line" else " … ")
    if len(pieces) > 1:
        edits.append({"kind": "elide", "style": "verse" if any(h == "line" for _, h in pieces[:-1]) else "prose"})
        if any(NEGATIONS.search(g) for g in gaps):
            flags.append("gap_has_negation")
    body, ambiguous = typography("".join(out))
    if ambiguous:
        flags.append("typography_ambiguous")
    body = unicodedata.normalize("NFC", body).strip()
    first_alpha = next((i for i, c in enumerate(body) if c.isalpha()), None)
    if first_alpha is not None and body[first_alpha].islower() and want_capital:
        body = body[:first_alpha] + body[first_alpha].upper() + body[first_alpha + 1:]
        edits.insert(0, {"kind": "capitalise_first"})
    if prefix:
        # The span starts mid-sentence: record the trim even when no letter changed.
        edits.insert(0, {"kind": "trim_start"})
    if len(body) > 280:
        flags.append("REJECT_LENGTH")
    if re.search(r"['\"]", body):
        flags.append("straight_quote")
    return {
        "body": body,
        "edits": edits,
        "flags": flags,
        "start": a,
        "end": end_index,
        "prefix_dropped": prefix,
        "gaps": gaps,
        "verse": verse,
    }
