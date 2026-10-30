"""Downloads, within each site's policy. Every download needs the founder's approval first (D10).

- Gutenberg ebooks: rsync from the gutenberg.pglaf.org::gutenberg-epub mirror module, only the
  listed ids (--files-from). Never the gutenberg.org website.
- Gutenberg catalog feed (pg_catalog.csv.gz): one GET with a descriptive User-Agent.
- Wikisource: one request at a time, at least a second apart, with a descriptive User-Agent. A
  page's own revision (oldid) does not pin text transcluded from Page: pages, so every Page:
  revision (title, rev id, sha1, proofreading quality) is pinned too.
- The Wikiquote dump: one GET from dumps.wikimedia.org.
"""

import datetime
import gzip
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

from . import config, corpus

RSYNC_MODULE = "gutenberg.pglaf.org::gutenberg-epub"
PG_CATALOG_URL = "https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv.gz"
WIKIQUOTE_DUMP_URL = "https://dumps.wikimedia.org/enwikiquote/latest/enwikiquote-latest-pages-articles.xml.bz2"
WS_API = "https://en.wikisource.org/w/api.php"
WS_REST = "https://en.wikisource.org/api/rest_v1/page/html/"
QUALITY = re.compile(r'<pagequality\s+level="(\d)"')

_last_request = [0.0]


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _get(url, accept=None, min_interval=1.0):
    wait = _last_request[0] + min_interval - time.time()
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": config.user_agent(), **({"Accept": accept} if accept else {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
            headers = dict(r.headers)
    finally:
        _last_request[0] = time.time()
    return data, headers


def rsync_list(gid):
    """List one ebook directory on the mirror (to confirm the module layout)."""
    return subprocess.run(["rsync", "--list-only", "%s/%d/" % (RSYNC_MODULE, gid)],
                          capture_output=True, text=True, timeout=120)


def rsync_gutenberg(ids):
    """Fetch pg<id>.txt for each id into build/catalog/mirror/gutenberg-epub/."""
    dest = os.path.join(config.build_dir(), "mirror", "gutenberg-epub")
    os.makedirs(dest, exist_ok=True)
    listing = os.path.join(config.build_dir(), "mirror", "files-from.txt")
    with open(listing, "w") as f:
        for gid in sorted(set(ids)):
            f.write("%d/pg%d.txt\n" % (gid, gid))
    p = subprocess.run(["rsync", "-t", "--files-from=" + listing, RSYNC_MODULE + "/", dest + "/"],
                       capture_output=True, text=True, timeout=1800)
    return p


def fetch_pg_catalog():
    dest_dir = os.path.join(config.build_dir(), "feeds")
    os.makedirs(dest_dir, exist_ok=True)
    data, _ = _get(PG_CATALOG_URL, min_interval=2.0)
    path = os.path.join(dest_dir, "pg_catalog.csv.gz")
    with open(path, "wb") as f:
        f.write(data)
    return path


def fetch_wikiquote_dump():
    dest_dir = os.path.join(config.build_dir(), "wikiquote")
    os.makedirs(dest_dir, exist_ok=True)
    path = os.path.join(dest_dir, "enwikiquote-latest-pages-articles.xml.bz2")
    req = urllib.request.Request(WIKIQUOTE_DUMP_URL, headers={"User-Agent": config.user_agent()})
    with urllib.request.urlopen(req, timeout=120) as r, open(path + ".part", "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(path + ".part", path)
    return path


def _api(params):
    q = dict(params, format="json", formatversion="2")
    data, _ = _get(WS_API + "?" + urllib.parse.urlencode(q))
    return json.loads(data)


def fetch_wikisource(title):
    """Fetch and pin one Wikisource mainspace page. Returns its lock row."""
    info = _api({"action": "query", "prop": "revisions|templates", "titles": title, "redirects": "1",
                 "rvprop": "ids|sha1|timestamp", "tlnamespace": "104", "tllimit": "500"})
    page = info["query"]["pages"][0]
    if page.get("missing"):
        raise RuntimeError("no Wikisource page %r" % title)
    title = page["title"]
    rev = page["revisions"][0]
    oldid = rev["revid"]
    page_titles = [t["title"] for t in page.get("templates", [])]
    pages = []
    for i in range(0, len(page_titles), 50):
        batch = page_titles[i:i + 50]
        r = _api({"action": "query", "prop": "revisions", "titles": "|".join(batch),
                  "rvprop": "ids|sha1|content", "rvslots": "main"})
        for p in r["query"]["pages"]:
            if p.get("missing"):
                continue
            pr = p["revisions"][0]
            content = pr["slots"]["main"].get("content", "")
            m = QUALITY.search(content)
            pages.append({"title": p["title"], "revid": pr["revid"], "sha1": pr.get("sha1"),
                          "quality": int(m.group(1)) if m else None})
    pages.sort(key=lambda p: _page_sort(p["title"]))
    html_bytes, headers = _get(WS_REST + urllib.parse.quote(title.replace(" ", "_"), safe="") + "/%d" % oldid,
                               accept="text/html; charset=utf-8")
    page_html = html_bytes.decode("utf-8")
    path = corpus.wikisource_file(title, oldid)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(page_html)
    body = corpus.extract_wikisource(page_html)
    return {
        "ref": "ws:" + title,
        "kind": "wikisource",
        "title": title,
        "oldid": oldid,
        "url": "https://en.wikisource.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"), safe="/(),'"),
        "rev_timestamp": rev.get("timestamp"),
        "pages": pages,
        "min_quality": min((p["quality"] for p in pages if p["quality"] is not None), default=None),
        "scan_backed": bool(pages),
        "html_sha256": corpus.hashlib.sha256(html_bytes).hexdigest(),
        "extractor_version": corpus.EXTRACTOR_VERSION,
        "body_sha256": corpus.sha256(body),
        "body_chars": len(body),
        "fetched_at": now(),
    }


def _page_sort(title):
    m = re.search(r"/(\d+)$", title)
    return (title.rsplit("/", 1)[0], int(m.group(1)) if m else 0)


def read_pg_catalog():
    """{ebook id: row} from build/catalog/feeds/pg_catalog.csv.gz."""
    import csv
    import io
    path = os.path.join(config.build_dir(), "feeds", "pg_catalog.csv.gz")
    if not os.path.exists(path):
        return None
    with gzip.open(path, "rt", encoding="utf-8", newline="") as f:
        return {int(r["Text#"]): r for r in csv.DictReader(f) if r.get("Text#", "").isdigit()}
