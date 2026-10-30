"""The public-domain rule, computed from an as-of date (plan section 3.1). Never hard-code a year.

US: the text used (original, translation or edition) was first published in or before Y - 96.
Strict (every App Store storefront): every contributor died in or before
min(Y - 81, max(1951, Y - 101)) and none is recorded "mort pour la France". An unknown death year
fails. Contributors are the credited author, the work's author, the translator and the reporter.
"""

import datetime


def parse_date(s):
    if s is None:
        return datetime.date.today()
    if isinstance(s, datetime.date):
        return s
    return datetime.date.fromisoformat(s)


def cutoffs(as_of):
    y = parse_date(as_of).year
    return {"us": y - 96, "life70": y - 71, "strict": min(y - 81, max(1951, y - 101)), "mexico": y - 101}


def contributors(work, credited, work_author):
    """[(role, name, died_year, mort_pour_la_france)] for a quote."""
    out = [("author", credited["name"], credited.get("died_year"), credited.get("mort_pour_la_france", False))]
    if work_author["id"] != credited["id"]:
        out.append(("work author", work_author["name"], work_author.get("died_year"),
                    work_author.get("mort_pour_la_france", False)))
    if work.get("translator"):
        out.append(("translator", work["translator"], work.get("translator_died_year"), False))
    if work.get("reporter"):
        out.append(("reporter", work["reporter"], work.get("reporter_died_year"), False))
    return out


def verdict(work, credited, work_author, as_of=None):
    """{"us", "life70", "strict", "as_of", "cutoffs", "blocking": [...]} for a quote."""
    c = cutoffs(as_of)
    blocking = []
    us = work.get("us_federal", False) or (work.get("edition_year") is not None and work["edition_year"] <= c["us"])
    if not us:
        blocking.append("US: the %s text was published in %s (needs %d or earlier)" % (
            work.get("citation"), work.get("edition_year"), c["us"]))
    life70 = strict = True
    for role, name, died, mpf in contributors(work, credited, work_author):
        if died is None:
            life70 = strict = False
            blocking.append("%s %s: death year unknown" % (role, name))
            continue
        if died > c["life70"]:
            life70 = False
        if died > c["strict"] or mpf:
            strict = False
            blocking.append("%s %s died %d (strict needs %d or earlier%s)" % (
                role, name, died, c["strict"], "; mort pour la France" if mpf else ""))
    return {"us": us, "life70": life70, "strict": strict, "ok": us and strict,
            "as_of": parse_date(as_of).isoformat(), "cutoffs": c, "blocking": blocking}


def clears_on(work, credited, work_author):
    """The first 1 January on which the quote passes US and strict, or None when it can't be
    computed (an unknown death year)."""
    year = datetime.date.today().year
    for y in range(year, year + 130):
        v = verdict(work, credited, work_author, datetime.date(y, 1, 1))
        if v["ok"]:
            return datetime.date(y, 1, 1).isoformat()
        if any("unknown" in b for b in v["blocking"]):
            return None
    return None
