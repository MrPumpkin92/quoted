"""Pinned source texts: Gutenberg bodies and Wikisource pages.

A text is pinned by the SHA-256 of its stripped body, never the file: Gutenberg regenerates its
pg<id>.txt files every month. Bodies are UTF-8 with LF line endings; offsets are code points.
"""

import hashlib
import html
import json
import os
import re
from html.parser import HTMLParser

from . import config

EXTRACTOR_VERSION = 1

START = re.compile(r"^\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG E-?BOOK[^\n]*\*\*\*[ \t]*$", re.I | re.M)
END = re.compile(r"^\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG E-?BOOK[^\n]*\*\*\*[ \t]*$", re.I | re.M)
HEADER_FIELD = re.compile(r"^\s*(Title|Author|Translator|Editor|Release date|Most recently updated|Language|Original publication):\s*(.+?)\s*$", re.M)


class CorpusError(Exception):
    pass


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def decode(raw):
    text = raw.decode("utf-8-sig")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def strip_gutenberg(text):
    """(body, header) of a Gutenberg plain-text file. The body runs from the line after the START
    marker to the start of the END marker line."""
    m = START.search(text)
    e = END.search(text)
    if not m or not e or e.start() < m.end():
        raise CorpusError("HEADER_UNPARSED: no Project Gutenberg START/END markers")
    head = text[: m.start()]
    header = {}
    for k, v in HEADER_FIELD.findall(head):
        header.setdefault(k.lower().replace(" ", "_"), v)
    body_start = m.end() + 1 if text[m.end(): m.end() + 1] == "\n" else m.end()
    return text[body_start: e.start()], header, {"start_marker": m.group().strip()}


# ---- Wikisource -------------------------------------------------------------------------------

class _WikisourceText(HTMLParser):
    """Plain text of a Wikisource (Parsoid) page: poem lines on their own lines, stanzas and
    paragraphs separated by blank lines; footnote markers, page numbers, headers and edit links
    dropped."""

    BLOCK = {"p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt", "table",
             "blockquote", "section", "center"}
    SKIP_CLASSES = ("reference", "mw-ref", "ws-pagenum", "pagenum", "noprint", "ws-noexport",
                    "mw-editsection", "references", "wst-header", "ws-header", "mw-cite-backlink",
                    "mw-empty-elt")

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.stack = []  # (tag, skipping)
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get("class") or ""
        skipping = tag in ("style", "script") or any(k in cls.split() or k in cls for k in self.SKIP_CLASSES) \
            or (tag == "sup" and ("reference" in cls or a.get("typeof", "").startswith("mw:Extension/ref")))
        if tag in ("br",):
            if not self.skip:
                self.out.append("\n")
            return
        if tag in ("img", "meta", "link", "hr", "wbr"):
            return
        self.stack.append((tag, skipping))
        if skipping:
            self.skip += 1
        if not self.skip and tag in self.BLOCK:
            self.out.append("\n\n")

    def handle_endtag(self, tag):
        # Pop to the matching tag (Parsoid output is well formed).
        while self.stack:
            t, skipping = self.stack.pop()
            if skipping:
                self.skip -= 1
            if t == tag:
                break
        if not self.skip and tag in self.BLOCK:
            self.out.append("\n\n")

    def handle_data(self, data):
        # HTML whitespace (including newlines in the markup) is one space; only <br> and blocks
        # break lines.
        if not self.skip:
            self.out.append(re.sub(r"[ \t\r\n]+", " ", data))


def extract_wikisource(page_html):
    p = _WikisourceText()
    p.feed(page_html)
    p.close()
    text = "".join(p.out).replace(" ", " ")
    lines = [ln.rstrip() for ln in text.split("\n")]
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text).strip("\n") + "\n"
    return text


# ---- the lock ---------------------------------------------------------------------------------

def load_lock():
    rows = {}
    path = config.lock_path()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    rows[r["ref"]] = r
    return rows


def write_lock(rows):
    path = config.lock_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for ref in sorted(rows, key=_ref_sort_key):
            f.write(json.dumps(rows[ref], ensure_ascii=False, sort_keys=True) + "\n")


def _ref_sort_key(ref):
    if ref.startswith("pg"):
        return (0, int(ref[2:]), "")
    return (1, 0, ref)


def gutenberg_file(gid):
    return os.path.join(config.build_dir(), "mirror", "gutenberg-epub", str(gid), "pg%d.txt" % gid)


def wikisource_file(title, revid):
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", title)[:150]
    return os.path.join(config.build_dir(), "wikisource", safe, "%d.html" % revid)


class Text:
    """One pinned text, with its tokens computed on first use."""

    def __init__(self, ref, body, meta):
        self.ref = ref
        self.body = body
        self.meta = meta
        self._tokens = None

    @property
    def tokens(self):
        if self._tokens is None:
            from .normalize import tokenize
            self._tokens = tokenize(self.body)
        return self._tokens

    @property
    def body_sha256(self):
        return self.meta["body_sha256"]


_cache = {}


def load(ref, lock=None, check=True):
    """The pinned text for a ref ("pg1342" or "ws:Title@revid"). Raises CorpusError when the file
    is missing or its body no longer matches the lock (drift)."""
    if ref in _cache:
        return _cache[ref]
    lock = lock if lock is not None else load_lock()
    meta = lock.get(ref)
    if meta is None:
        raise CorpusError("CITED_WORK_MISSING: %s is not in corpus.lock.jsonl" % ref)
    if meta["kind"] == "gutenberg":
        path = gutenberg_file(meta["gutenberg_id"])
        if not os.path.exists(path):
            raise CorpusError("CITED_WORK_MISSING: %s not downloaded (%s)" % (ref, path))
        with open(path, "rb") as f:
            body, _, _ = strip_gutenberg(decode(f.read()))
    elif meta["kind"] == "wikisource":
        path = wikisource_file(meta["title"], meta["oldid"])
        if not os.path.exists(path):
            raise CorpusError("CITED_WORK_MISSING: %s not downloaded (%s)" % (ref, path))
        with open(path, encoding="utf-8") as f:
            body = extract_wikisource(f.read())
    else:
        raise CorpusError("unknown source kind %r" % meta["kind"])
    if check and sha256(body) != meta["body_sha256"]:
        raise CorpusError("DRIFT: %s body no longer matches its pinned sha256" % ref)
    t = Text(ref, body, meta)
    _cache[ref] = t
    return t


def lock_gutenberg(gid, fetched_at):
    """A lock row for a downloaded Gutenberg ebook."""
    path = gutenberg_file(gid)
    with open(path, "rb") as f:
        raw = f.read()
    text = decode(raw)
    body, header, marks = strip_gutenberg(text)
    row = {
        "ref": "pg%d" % gid,
        "kind": "gutenberg",
        "gutenberg_id": gid,
        "mirror": "gutenberg.pglaf.org::gutenberg-epub",
        "path": "%d/pg%d.txt" % (gid, gid),
        "file_sha256": hashlib.sha256(raw).hexdigest(),
        "file_bytes": len(raw),
        "body_sha256": sha256(body),
        "body_chars": len(body),
        "start_marker": marks["start_marker"],
        "title": header.get("title"),
        "author": header.get("author"),
        "translator": header.get("translator"),
        "release_date": header.get("release_date"),
        "last_updated": header.get("most_recently_updated"),
        "fetched_at": fetched_at,
    }
    return row
