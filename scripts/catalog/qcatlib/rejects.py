"""The reject list: wordings known to be misattributed or disputed, keyed on normalised text plus the
wrongly credited author.

Two layers: a frozen list committed as a test fixture (supabase/catalog/fixtures/
reject_list.frozen.jsonl, the rejects already named in docs/starter-pack-sources.md), and the list
built from the Wikiquote dump (build/catalog/wikiquote/rejects.jsonl, never committed or shown,
because Wikiquote's text is CC BY-SA). A hit under the claimed author rejects the lead; a hit under
someone else is only a flag, because a true author's line can sit on another person's
Misattributed list.
"""

import difflib
import json
import os

from . import config
from .normalize import tokenize


def _tokens(text):
    return tokenize(text).words


class RejectList:
    def __init__(self, entries):
        self.entries = []
        self.index = {}
        for e in entries:
            toks = _tokens(e["text"])
            if len(toks) < 3:
                continue
            e = dict(e, tokens=toks)
            self.entries.append(e)
            k = len(self.entries) - 1
            for i in range(len(toks) - 2):
                self.index.setdefault(tuple(toks[i:i + 3]), set()).add(k)

    def __len__(self):
        return len(self.entries)

    @classmethod
    def load(cls, live=True):
        entries = []
        frozen = os.path.join(config.data_dir(), "fixtures", "reject_list.frozen.jsonl")
        for path, origin in ((frozen, "frozen"),
                             (os.path.join(config.build_dir(), "wikiquote", "rejects.jsonl"), "wikiquote")):
            if origin == "wikiquote" and not live:
                continue
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    for line in f:
                        if line.strip():
                            entries.append(dict(json.loads(line), origin=origin))
        return cls(entries)

    def lookup(self, text):
        """Entries whose wording matches text: ratio 0.8 or more, or 0.9 of a truncated entry's words
        in order, or a 6-word run in common with a short entry."""
        probe = _tokens(text)
        if len(probe) < 3:
            return []
        cands = {}
        for i in range(len(probe) - 2):
            for k in self.index.get(tuple(probe[i:i + 3]), ()):
                cands[k] = cands.get(k, 0) + 1
        hits = []
        for k, votes in sorted(cands.items(), key=lambda kv: -kv[1])[:50]:
            e = self.entries[k]
            sm = difflib.SequenceMatcher(None, e["tokens"], probe, autojunk=False)
            m = sum(b.size for b in sm.get_matching_blocks())
            ratio = 2.0 * m / (len(e["tokens"]) + len(probe))
            coverage = m / len(e["tokens"])
            short = len(e["tokens"]) < 6
            if ratio >= (0.9 if short else 0.8) or (e.get("truncated") and coverage >= 0.9) \
                    or (not short and coverage >= 0.9 and len(probe) >= len(e["tokens"])):
                hits.append({"author": e["author"], "author_slug": e.get("author_slug"), "page": e.get("page"),
                             "section": e.get("section"), "kind": e.get("kind"), "origin": e.get("origin"),
                             "ratio": round(ratio, 3), "coverage": round(coverage, 3),
                             "same_words": e["tokens"] == probe})
        hits.sort(key=lambda h: -h["ratio"])
        return hits
