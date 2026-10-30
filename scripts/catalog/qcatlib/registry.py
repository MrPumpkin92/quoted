"""The works registry: supabase/catalog/authors.jsonl and works.jsonl.

authors.jsonl: id, slug, name (the exact author string, part of the seal key), died_year (negative
for BCE; the latest plausible year when uncertain), born_year, mort_pour_la_france, woman, region,
died_source.

works.jsonl: id, author_id (the work's author), citation (the exact source string, part of the seal
key, frozen), title, first_published, edition_year (the text actually used), translator,
translator_died_year, reporter, reporter_died_year, ref (the pinned text: "pg<id>" or
"ws:<title>"), gutenberg_id, source_url, form (prose, verse or drama), kind, notes.

Ids are dense and never reused. A work row is one edition or translation, so several rows can
share one ebook (Emerson's essays) and one ebook can be cited for one work only once per author.
"""

import json
import os
import re

from . import config


def _path(name):
    return os.path.join(config.data_dir(), name)


def read_jsonl(path):
    rows = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if line.strip():
                    try:
                        rows.append(json.loads(line))
                    except ValueError as e:
                        raise SystemExit("%s:%d: %s" % (path, n, e))
    return rows


def write_jsonl(path, rows, key="id"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in sorted(rows, key=lambda r: r[key]):
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")


def slugify(name):
    s = name.lower()
    s = re.sub(r"[’'.]", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:80]


class Registry:
    def __init__(self, authors, works):
        self.authors = {a["id"]: a for a in authors}
        self.works = {w["id"]: w for w in works}
        self.by_slug = {a["slug"]: a for a in authors}
        self.by_name = {}
        for a in authors:
            self.by_name.setdefault(a["name"], a)
            for alias in a.get("aliases", []):
                self.by_name.setdefault(alias, a)

    @classmethod
    def load(cls):
        return cls(read_jsonl(_path("authors.jsonl")), read_jsonl(_path("works.jsonl")))

    def save(self):
        write_jsonl(_path("authors.jsonl"), list(self.authors.values()))
        write_jsonl(_path("works.jsonl"), list(self.works.values()))

    def author(self, key):
        if isinstance(key, int):
            return self.authors[key]
        if key in self.by_slug:
            return self.by_slug[key]
        if key in self.by_name:
            return self.by_name[key]
        raise KeyError("unknown author %r" % key)

    def work(self, key):
        if isinstance(key, int):
            return self.works[key]
        for w in self.works.values():
            if w.get("key") == key:
                return w
        raise KeyError("unknown work %r" % key)

    def works_by(self, author_id):
        """Works by an author, or credited to them (Socrates in Plato's Apology)."""
        return [w for w in self.works.values()
                if w["author_id"] == author_id or w.get("credited_author_id") == author_id]

    def work_by_citation(self, author_id, citation):
        for w in self.works_by(author_id):
            if w["citation"] == citation:
                return w
        raise KeyError("no work %r by author %d" % (citation, author_id))

    def next_author_id(self):
        return max(self.authors, default=0) + 1

    def next_work_id(self):
        return max(self.works, default=0) + 1

    def check(self):
        """Problems with the registry: duplicate names or citations, a translator with two death
        years, missing death years."""
        problems = []
        names = {}
        for a in self.authors.values():
            if a["name"] in names:
                problems.append("author name %r is used twice (%d, %d)" % (a["name"], names[a["name"]], a["id"]))
            names[a["name"]] = a["id"]
            if a.get("died_year") is None:
                problems.append("author %s has no death year (fails the public-domain rule)" % a["name"])
        cites = {}
        tr = {}
        for w in self.works.values():
            if w["author_id"] not in self.authors:
                problems.append("work %d names unknown author %d" % (w["id"], w["author_id"]))
            k = (w["author_id"], w["citation"])
            if k in cites:
                problems.append("citation %r is used twice for one author (%d, %d)" % (w["citation"], cites[k], w["id"]))
            cites[k] = w["id"]
            if w.get("translator"):
                d = w.get("translator_died_year")
                if w["translator"] in tr and tr[w["translator"]] != d:
                    problems.append("translator %s has two death years" % w["translator"])
                tr[w["translator"]] = d
                if d is None:
                    problems.append("work %d: translator %s has no death year" % (w["id"], w["translator"]))
            if w.get("reporter") and w.get("reporter_died_year") is None:
                problems.append("work %d: reporter %s has no death year" % (w["id"], w["reporter"]))
            if not re.match(r"^(pg\d+|ws:.+)$", w.get("ref") or ""):
                problems.append("work %d has no pinned text ref" % w["id"])
        return problems


def contributors_last_died_year(work):
    years = [y for y in (work.get("translator_died_year") if work.get("translator") else None,
                         work.get("reporter_died_year") if work.get("reporter") else None) if y is not None]
    return max(years) if years else None
