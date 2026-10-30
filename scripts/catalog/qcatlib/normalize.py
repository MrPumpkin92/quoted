"""Matching form of a text, with a map back to the original.

`orig` is the text as pinned (a stripped Gutenberg body or extracted Wikisource text, LF line
endings). Every stored offset is a code point offset into `orig`. Matching compares word tokens of
a folded form built from `orig` character by character:

- deleted: soft hyphens, zero-width characters, the BOM, `_` (Gutenberg italics) and editorial
  apparatus ([1], [Footnote …], [Pg 12], {12}, [Illustration …], superscript digits);
- dashes and hyphens (`--`, —, –, -, …) separate words;
- curly and straight quotes fold to one form;
- each character is NFKD-decomposed, combining marks dropped, æ/œ spelled out, then casefolded
  (long s, ligatures, NBSP and … fold through NFKD).

Not folded: spelling and compound variants (labour/labor, to-morrow/tomorrow, Iland/island). They
come out as near-miss diffs. Bump NORMALISER_VERSION whenever these rules change.
"""

import re
import unicodedata
from array import array
from bisect import bisect_right

NORMALISER_VERSION = 2

SINGLE_QUOTES = "‘’‚‛′ʼ`´'"
DOUBLE_QUOTES = "“”„‟″«»\""
DASHES = "-‐‑‒–—―−⸺⸻"
INVISIBLE = "­​‌‍⁠﻿"

# Editorial apparatus, removed before folding. Superscript digits go here too: NFKD would turn
# ¹ into 1.
APPARATUS = re.compile(
    r"\[(?:\d{1,3}|[A-Z]|Footnote[^\]]*|Pg\.? ?[0-9ivxlc]+|Illustration[^\]]*|Sidenote[^\]]*)\]"
    r"|\{\d{1,4}\}"
    r"|[¹²³⁰⁴-⁹]+"
    r"|(?m:[ \t]{2,}_?\d{1,4}(?=[ \t]*$))"  # a verse line number at the end of a line ("  75", "  _75")
)

TOKEN = re.compile(r"[0-9a-z]+(?:'[0-9a-z]+)*")

_fold_cache = {}


def fold_char(c):
    """The folded form of one character (possibly empty or several characters)."""
    out = _fold_cache.get(c)
    if out is not None:
        return out
    if c in INVISIBLE or c == "_":
        out = ""
    elif c in SINGLE_QUOTES:
        out = "'"
    elif c in DOUBLE_QUOTES:
        out = '"'
    elif c in DASHES:
        out = " "
    elif c in "æÆ":
        out = "ae"
    elif c in "œŒ":
        out = "oe"
    else:
        d = unicodedata.normalize("NFKD", c)
        out = "".join(ch for ch in d if not unicodedata.combining(ch)).casefold()
    _fold_cache[c] = out
    return out


def apparatus_spans(text):
    return [(m.start(), m.end()) for m in APPARATUS.finditer(text)]


class Tokens:
    """Word tokens of a text, each with its code point span in the original."""

    __slots__ = ("words", "starts", "ends", "joined", "joined_pos")

    def __init__(self, words, starts, ends):
        self.words = words
        self.starts = starts
        self.ends = ends
        # " w1 w2 … " and each token's position in it, for C-speed exact search.
        parts = []
        pos = array("i")
        cursor = 1
        for w in words:
            pos.append(cursor)
            parts.append(w)
            cursor += len(w) + 1
        self.joined = " " + " ".join(parts) + " "
        self.joined_pos = pos

    def __len__(self):
        return len(self.words)

    def token_at(self, joined_index):
        """The token index that starts at a position in `joined`."""
        i = bisect_right(self.joined_pos, joined_index) - 1
        return i

    def find_all(self, seq):
        """Every token index where the token sequence `seq` occurs."""
        if not seq:
            return []
        needle = " " + " ".join(seq) + " "
        hits = []
        start = 0
        while True:
            j = self.joined.find(needle, start)
            if j < 0:
                return hits
            hits.append(self.token_at(j + 1))
            start = j + 1


def tokenize(orig):
    """Tokens of `orig`. Token text drops inner apostrophes ("isn’t" → "isnt")."""
    removed = apparatus_spans(orig)
    folded = []
    origin = array("i")
    ri = 0
    n = len(orig)
    i = 0
    while i < n:
        if ri < len(removed) and i == removed[ri][0]:
            # A removed span acts as a word separator.
            folded.append(" ")
            origin.append(i)
            i = removed[ri][1]
            ri += 1
            continue
        out = fold_char(orig[i])
        for ch in out:
            folded.append(ch)
            origin.append(i)
        i += 1
    folded = "".join(folded)
    words, starts, ends = [], array("i"), array("i")
    for m in TOKEN.finditer(folded):
        words.append(m.group().replace("'", ""))
        starts.append(origin[m.start()])
        # Map the end from the last included character, not the position after it, so trailing
        # apparatus or markup is never swallowed.
        ends.append(origin[m.end() - 1] + 1)
    return Tokens(words, starts, ends)


def words(text):
    """Just the token words of a short string (a lead or a body)."""
    return tokenize(text).words
