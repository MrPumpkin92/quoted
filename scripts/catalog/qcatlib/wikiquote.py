"""The reject list from the English Wikiquote dump (research: wikiquote.md).

- A section's status comes from its heading text, inherited down the heading stack, the most
  restrictive winning: Misattributed > Disputed > "Quotes about" > Attributed. Templates such as
  {{misattributed begin}} are ignored (Attributed sections are wrapped in {{disputed begin}} too).
- Rejects: the top-level bullets of Misattributed and Disputed sections, and anywhere the
  Variant, Misquote and "often quoted as" sub-bullets.
- Each entry is keyed on its text and the page's subject (the wrongly credited person). It stays in
  build/catalog/wikiquote/rejects.jsonl: Wikiquote's text is CC BY-SA and is never committed or
  shown.
"""

import bz2
import html
import json
import os
import re
import xml.etree.ElementTree as ET

from . import config

HEADING = re.compile(r"^(={2,6})\s*(.*?)\s*\1\s*$")
BULLET = re.compile(r"^(\*+)\s*(.*)$")
VARIANT = re.compile(r"^(?:'''|'')?\s*(variants?|misquot(?:e|ed)(?: as)?|often (?:mis)?quoted as|also (?:quoted|rendered) as|paraphrased as|popularly(?: quoted)? as)\b\s*[:.,-]?\s*(?:'''|'')?\s*(.*)$", re.I)
RANK = {"misattributed": 4, "disputed": 3, "about": 2, "attributed": 1, "sourced": 0}


def heading_status(text):
    t = text.lower()
    if "misattributed" in t or "misquoted" in t or "falsely attributed" in t:
        return "misattributed"
    if "disputed" in t or "dubious" in t or "unverified" in t:
        return "disputed"
    if t.startswith("quotes about") or t.startswith("about ") or t.startswith("quotations about"):
        return "about"
    if "attributed" in t or "unsourced" in t:
        return "attributed"
    return "sourced"


def _strip_templates(s):
    out, depth, i = [], 0, 0
    while i < len(s):
        if s.startswith("{{", i):
            depth += 1
            i += 2
        elif s.startswith("}}", i) and depth:
            depth -= 1
            i += 2
        else:
            if not depth:
                out.append(s[i])
            i += 1
    return "".join(out)


def clean(text):
    s = re.sub(r"<ref[^>/]*/>", "", text)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    s = _strip_templates(s)
    s = re.sub(r"\[\[(?:File|Image|Category):[^\]]*\]\]", "", s, flags=re.I)
    s = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"\[https?://\S+\s+([^\]]*)\]", r"\1", s)
    s = re.sub(r"<br\s*/?>", " ", s, flags=re.I)
    s = re.sub(r"</?[a-z][^>]*>", "", s, flags=re.I)
    s = s.replace("'''", "").replace("''", "")
    s = html.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


def page_entries(title, text, revid=None):
    entries = []
    stack = []  # (level, status)
    pending_variant = None
    for raw in text.split("\n"):
        line = raw.rstrip()
        h = HEADING.match(line)
        if h:
            level = len(h.group(1))
            while stack and stack[-1][0] >= level:
                stack.pop()
            parent = stack[-1][1] if stack else "sourced"
            st = heading_status(clean(h.group(2)))
            stack.append((level, st if RANK[st] >= RANK[parent] else parent))
            pending_variant = None
            continue
        b = BULLET.match(line)
        if not b:
            continue
        depth = len(b.group(1))
        body = b.group(2)
        status = stack[-1][1] if stack else "sourced"
        v = VARIANT.match(clean(body))
        if depth >= 2 and v:
            rest = v.group(2).strip()
            if len(rest.split()) >= 3:
                entries.append({"text": rest, "kind": v.group(1).lower(), "section": status})
                pending_variant = None
            else:
                pending_variant = depth  # the variant text is the next, deeper bullet
            continue
        if pending_variant is not None and depth > pending_variant:
            t = clean(body)
            if len(t.split()) >= 3:
                entries.append({"text": t, "kind": "variant", "section": status})
            continue
        pending_variant = None
        if depth == 1 and status in ("misattributed", "disputed"):
            t = clean(body)
            if len(t.split()) >= 3 and not t.lower().startswith(("see also", "main article")):
                entries.append({"text": t, "kind": status, "section": status})
    for e in entries:
        e.update(author=title, page=title, revid=revid)
    return entries


def build_rejects(dump_path):
    if not os.path.exists(dump_path):
        raise SystemExit("no dump at %s (download it with `corpus fetch --wikiquote-dump`)" % dump_path)
    out_path = os.path.join(config.build_dir(), "wikiquote", "rejects.jsonl")
    pages = rejects = 0
    with bz2.open(dump_path, "rb") as f, open(out_path + ".part", "w", encoding="utf-8") as out:
        title = ns = revid = text = None
        redirect = False
        for event, el in ET.iterparse(f, events=("end",)):
            tag = el.tag.rsplit("}", 1)[-1]
            if tag == "title":
                title = el.text
            elif tag == "ns":
                ns = el.text
            elif tag == "redirect":
                redirect = True
            elif tag == "id" and revid is None and text is None and ns is not None:
                pass
            elif tag == "text":
                text = el.text or ""
            elif tag == "revision":
                rid = el.find("{*}id")
                revid = int(rid.text) if rid is not None and rid.text else None
            elif tag == "page":
                if ns == "0" and not redirect and text:
                    pages += 1
                    for e in page_entries(title, text, revid):
                        out.write(json.dumps(e, ensure_ascii=False) + "\n")
                        rejects += 1
                title = ns = revid = text = None
                redirect = False
                el.clear()
    os.replace(out_path + ".part", out_path)
    return {"pages": pages, "rejects": rejects, "out": out_path}
