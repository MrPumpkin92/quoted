"""Finding a lead in a pinned text: exact token matches, ordered elided segments, and near misses
from word 4-gram anchors aligned with difflib."""

import difflib
import re

from . import config
from .normalize import tokenize

ELLIPSIS_SPLIT = re.compile(r"\s*(?:…|\.\.\.|\. \. \.|\* \* \*)\s*")
ENCLOSING = "\"'“”‘’«»"


def parse_lead(text):
    """(segments, flags) of a lead's text. A middle ellipsis splits it into ordered segments; a
    leading or trailing one only means it was truncated."""
    t = text.strip().strip(ENCLOSING).strip()
    t = t.replace(" / ", "\n")
    flags = []
    if re.match(r"^(?:…|\.\.\.)", t):
        flags.append("truncated_start")
        t = re.sub(r"^(?:…|\.\.\.)\s*", "", t)
    if re.search(r"(?:…|\.\.\.)$", t):
        flags.append("truncated_end")
        t = re.sub(r"\s*(?:…|\.\.\.)$", "", t)
    segs = [s for s in ELLIPSIS_SPLIT.split(t) if s.strip()]
    return segs, flags


class Span:
    """Token spans [start, end) of one match, in order."""

    def __init__(self, segments):
        self.segments = segments

    @property
    def start(self):
        return self.segments[0][0]

    @property
    def end(self):
        return self.segments[-1][1]


def find_chains(tokens, seg_words, max_gap=None):
    """Every way the segments occur in order, each starting within max_gap tokens of the last."""
    max_gap = config.THRESHOLDS["elision_max_gap_tokens"] if max_gap is None else max_gap
    first = seg_words[0]
    chains = []
    for s in tokens.find_all(first):
        chain = [(s, s + len(first))]
        ok = True
        for w in seg_words[1:]:
            pos = chain[-1][1]
            window_end = pos + max_gap + len(w)
            hit = None
            for h in _find_from(tokens, w, pos):
                if h > window_end:
                    break
                hit = h
                break
            if hit is None:
                ok = False
                break
            chain.append((hit, hit + len(w)))
        if ok:
            chains.append(Span(chain))
    return chains


def _find_from(tokens, seq, from_tok):
    needle = " " + " ".join(seq) + " "
    start = tokens.joined_pos[from_tok] - 1 if from_tok < len(tokens) else len(tokens.joined)
    while True:
        j = tokens.joined.find(needle, start)
        if j < 0:
            return
        yield tokens.token_at(j + 1)
        start = j + 1


def anchors(tokens, lead, n=4):
    """Candidate start tokens for a near-miss alignment, by n-gram votes."""
    maxhits = config.THRESHOLDS["anchor_max_hits"]
    need = 1 if len(lead) < 8 else 2
    votes = {}
    # 4-grams first; shorter n-grams add votes only while no passage has enough (2-grams only
    # when rare), so a paraphrase that shares just "a happy life" and "very little" still aligns.
    for size, cap in ((n, maxhits), (3, maxhits), (2, 50)):
        if len(lead) < size:
            continue
        for k in range(len(lead) - size + 1):
            hits = tokens.find_all(lead[k:k + size])
            if not hits or len(hits) > cap:
                continue
            for p in hits:
                key = (p - k) // max(4, len(lead) // 2)
                votes.setdefault(key, []).append(p - k)
        if any(len(g) >= need for g in votes.values()):
            break
    ranked = sorted(votes.values(), key=len, reverse=True)
    starts = []
    for group in ranked[:5]:
        if len(group) >= need or len(ranked) == 1:
            group.sort()
            starts.append(group[len(group) // 2])
    return starts


def align(tokens, lead, start):
    """Best alignment of the lead's words around a start token: (ratio, coverage, longest block,
    span start, span end, opcodes)."""
    lo = max(0, start - 10)
    hi = min(len(tokens), start + int(1.3 * len(lead)) + 10)
    window = tokens.words[lo:hi]
    sm = difflib.SequenceMatcher(None, lead, window, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size]
    if not blocks:
        return None
    # Extend the span to cover lead words before the first block and after the last one.
    a0 = max(lo + blocks[0].b - blocks[0].a, lo)
    b_last = blocks[-1]
    a1 = lo + b_last.b + b_last.size + (len(lead) - (b_last.a + b_last.size))
    a1 = min(a1, hi)
    span = tokens.words[a0:a1]
    sm2 = difflib.SequenceMatcher(None, lead, span, autojunk=False)
    m = sum(b.size for b in sm2.get_matching_blocks())
    longest = max((b.size for b in sm2.get_matching_blocks()), default=0)
    ratio = 2.0 * m / (len(lead) + len(span)) if (lead or span) else 0.0
    coverage = m / len(lead) if lead else 0.0
    return ratio, coverage, longest, a0, a1, sm2.get_opcodes(), span


def best_near(tokens, lead):
    best = None
    for s in anchors(tokens, lead):
        r = align(tokens, lead, s)
        if r and (best is None or r[0] > best[0]):
            best = r
    return best


def op_kind(a_words, b_words):
    """join_split ("it selfe" / "itself", "to-morrow" / "tomorrow"), spelling (labour / labor,
    peece / piece) or lexical (a different word)."""
    ja, jb = "".join(a_words), "".join(b_words)
    if ja == jb:
        return "join_split"
    if len(a_words) != len(b_words) and a_words and b_words and difflib.SequenceMatcher(None, ja, jb).ratio() >= 0.85:
        return "join_split"
    if len(a_words) == len(b_words) and all(
            difflib.SequenceMatcher(None, x, y).ratio() >= 0.75 for x, y in zip(a_words, b_words)):
        return "spelling"
    return "lexical"


def near_class(r):
    """'high', 'low' or None for an alignment result."""
    if r is None:
        return None
    ratio, coverage, longest = r[0], r[1], r[2]
    th = config.THRESHOLDS
    if ratio >= th["near_high_ratio"] and coverage >= th["near_high_coverage"]:
        return "high"
    if ratio >= th["near_low_ratio"] and coverage >= th["near_low_coverage"] and longest >= th["near_low_block"]:
        return "low"
    return None


def diff_ops(lead, span, opcodes):
    out = []
    for tag, i1, i2, j1, j2 in opcodes:
        if tag == "equal":
            continue
        a, b = lead[i1:i2], span[j1:j2]
        out.append({"op": tag, "lead": " ".join(a), "source": " ".join(b), "kind": op_kind(a, b)})
    return out


def inline_diff(lead, span, opcodes):
    parts = []
    for tag, i1, i2, j1, j2 in opcodes:
        if tag == "equal":
            parts.append(" ".join(lead[i1:i2]))
        else:
            if i2 > i1:
                parts.append("[-" + " ".join(lead[i1:i2]) + "-]")
            if j2 > j1:
                parts.append("{+" + " ".join(span[j1:j2]) + "+}")
    return " ".join(parts)


def lead_words(segments):
    return [tokenize(s).words for s in segments]
