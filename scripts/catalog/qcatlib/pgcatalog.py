"""Cross-checking the registry against Project Gutenberg's catalog feed (pg_catalog.csv): each pinned
ebook exists, names the work's author and, for a translation, the translator; and the death years
it records agree with the registry's."""

import re
import unicodedata

PERSON = re.compile(r"\s*(?P<name>[^;\[]+?)(?:,\s*(?P<born>-?\d{1,4}\??|BCE?\s*\d+|\d+\s*BCE?)?\s*-\s*(?P<died>-?\d{1,4}\??|\d+\s*BCE?)?)?\s*(?:\[(?P<role>[^\]]+)\])?\s*$")


def _fold(s):
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


def people(field):
    """[(name, born, died, role)] from an Authors field such as
    "Long, George, 1800-1879 [Translator]; Marcus Aurelius, Emperor of Rome, 121-180"."""
    out = []
    for part in (field or "").split(";"):
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^(?P<name>.*?)(?:,\s*(?P<years>(?:\d+\s*BCE?\??|-?\d{1,4}\??)?\s*-\s*(?:\d+\s*BCE?\??|-?\d{1,4}\??)?))?\s*(?:\[(?P<role>[^\]]+)\])?$", part)
        name = (m.group("name") if m else part).strip()
        years = m.group("years") if m else None
        role = (m.group("role") or "Author") if m else "Author"
        died = None
        if years and "-" in years:
            d = years.split("-", 1)[1].strip().rstrip("?")
            if d:
                bce = "BC" in d
                d = re.sub(r"[^\d]", "", d)
                if d:
                    died = -int(d) if bce else int(d)
        out.append((name, died, role))
    return out


def check(reg, cat):
    problems = []
    for w in sorted(reg.works.values(), key=lambda w: w["id"]):
        gid = w.get("gutenberg_id")
        if not gid:
            continue
        row = cat.get(gid)
        if row is None:
            problems.append("work %d (%s): pg%d is not in pg_catalog.csv" % (w["id"], w["citation"], gid))
            continue
        ppl = people(row.get("Authors", ""))
        a = reg.authors[w["author_id"]]
        surname = _fold(a["name"].replace("(", " ").split()[-1].strip(")"))
        authors = [p for p in ppl if p[2] in ("Author", "Creator", "Contributor", "Compiler")] or ppl
        match = [p for p in authors if surname in _fold(p[0])]
        if not match and not w.get("pg_author_note"):
            problems.append("work %d (%s): pg%d authors %r don't name %s" % (w["id"], w["citation"], gid, row.get("Authors"), a["name"]))
        elif match and match[0][1] is not None and a.get("died_year") is not None and match[0][1] != a["died_year"] \
                and not a.get("died_year_note"):
            problems.append("author %s: registry died %s, pg_catalog %s (pg%d)" % (a["name"], a["died_year"], match[0][1], gid))
        if w.get("translator"):
            trs = [p for p in ppl if "Translator" in p[2]]
            first = _fold(w["translator"].split(" and ")[-1].split()[-1])
            tm = [p for p in trs if first in _fold(p[0])]
            if not tm and not w.get("pg_translator_note"):
                problems.append("work %d (%s): pg%d lists no translator %s (%r)" % (w["id"], w["citation"], gid, w["translator"], row.get("Authors")))
            elif tm and tm[0][1] is not None and w.get("translator_died_year") is not None and \
                    max(p[1] or 0 for p in tm) != w["translator_died_year"] and " and " not in w["translator"]:
                problems.append("translator %s: registry died %s, pg_catalog %s (pg%d)" % (w["translator"], w["translator_died_year"], tm[0][1], gid))
    return problems
