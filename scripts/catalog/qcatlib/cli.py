"""Command-line entry points (see qcat.py for the list)."""

import argparse
import json
import os
import sys

from . import config, corpus, registry


def _print(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=1))


def cmd_version(args):
    from . import version
    print(version.tree_id() + (" (uncommitted)" if version.dirty() else ""))
    return 0


def cmd_registry(args):
    reg = registry.Registry.load()
    if args.action == "check":
        problems = reg.check()
        from . import fetch
        cat = fetch.read_pg_catalog()
        if cat is None:
            print("note: pg_catalog.csv.gz not downloaded; death years and ebook ids are unchecked")
        else:
            from . import pgcatalog
            problems += pgcatalog.check(reg, cat)
        for p in problems:
            print("-", p)
        print("%d authors, %d works, %d problems" % (len(reg.authors), len(reg.works), len(problems)))
        return 1 if problems else 0
    if args.action == "allowlist":
        from . import pd
        names = {}
        for w in reg.works.values():
            if w.get("translator"):
                names.setdefault(w["translator"], w.get("translator_died_year"))
        c = pd.cutoffs(args.as_of)
        for n, d in sorted(names.items()):
            print("%s\t%s\t%s" % ("ok" if d is not None and d <= c["strict"] else "WAIT", d, n))
        return 0
    return 2


def cmd_corpus(args):
    from . import fetch
    lock = corpus.load_lock()
    if args.action == "fetch":
        if args.list_only:
            p = fetch.rsync_list(int(args.list_only))
            print(p.stdout or p.stderr)
            return p.returncode
        if args.pg_catalog:
            print(fetch.fetch_pg_catalog())
        if args.wikiquote_dump:
            print(fetch.fetch_wikiquote_dump())
        if args.gutenberg:
            ids = [int(x) for x in args.gutenberg.split(",") if x.strip()]
            p = fetch.rsync_gutenberg(ids)
            sys.stdout.write(p.stdout)
            sys.stderr.write(p.stderr)
            if p.returncode:
                return p.returncode
            for gid in ids:
                if os.path.exists(corpus.gutenberg_file(gid)):
                    lock["pg%d" % gid] = corpus.lock_gutenberg(gid, fetch.now())
                else:
                    print("missing after rsync: pg%d" % gid)
            corpus.write_lock(lock)
        for title in args.wikisource or []:
            row = fetch.fetch_wikisource(title)
            lock[row["ref"]] = row
            corpus.write_lock(lock)
            print(row["ref"], row["oldid"], "pages:", len(row["pages"]), "min quality:", row["min_quality"])
        return 0
    if args.action == "status":
        bad = 0
        for ref in sorted(lock, key=corpus._ref_sort_key):
            try:
                corpus.load(ref, lock)
                state = "ok"
            except corpus.CorpusError as e:
                state = str(e)
                bad += 1
            print("%-12s %s" % (ref, state))
        reg = registry.Registry.load()
        for w in sorted(reg.works.values(), key=lambda w: w["id"]):
            if w["ref"] not in lock:
                print("%-12s not pinned (work %d, %s)" % (w["ref"], w["id"], w["citation"]))
                bad += 1
        return 3 if bad else 0
    if args.action == "lock":
        from . import fetch as f
        root = os.path.join(config.build_dir(), "mirror", "gutenberg-epub")
        n = 0
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            if d.isdigit() and os.path.exists(corpus.gutenberg_file(int(d))):
                ref = "pg" + d
                row = corpus.lock_gutenberg(int(d), lock.get(ref, {}).get("fetched_at") or f.now())
                if ref in lock and lock[ref]["body_sha256"] != row["body_sha256"] and not args.accept_drift:
                    print("DRIFT %s: body changed since it was pinned (rerun with --accept-drift after review)" % ref)
                    continue
                lock[ref] = row
                n += 1
        corpus.write_lock(lock)
        print("pinned %d Gutenberg texts" % n)
        return 0
    return 2


def cmd_acceptance(args):
    from . import acceptance
    s = acceptance.run(live_rejects=args.live_rejects)
    print("gate %s: %d/%d should-pass passed, %d/%d blocked, %d auto-passes among blocked; precision %.3f, recall %.3f" % (
        "GREEN" if not s["failures"] else "RED", s["passed"], s["should_pass"], s["blocked"], s["should_block"],
        s["auto_passes_among_blocked"], s["precision"], s["recall"]))
    for f in s["failures"]:
        print("  FAIL", f)
    print("report:", os.path.join(s["out_dir"], "report.md"))
    return 4 if s["failures"] else 0


def cmd_wikiquote(args):
    from . import wikiquote
    path = args.dump or os.path.join(config.build_dir(), "wikiquote", "enwikiquote-latest-pages-articles.xml.bz2")
    stats = wikiquote.build_rejects(path)
    _print(stats)
    return 0


def cmd_verify(args):
    from . import batch
    return batch.verify_leads(args.leads, args.run, as_of=args.as_of)


def cmd_selftest(args):
    from . import selftest
    return selftest.run()


def cmd_excerpts(args):
    from . import selftest
    return selftest.write_excerpts()


def cmd_review(args):
    from . import review
    return review.build(args.run)


def cmd_approve(args):
    from . import sqlgen
    return sqlgen.approve("%03d" % args.number, args.run)


def cmd_generate(args):
    from . import sqlgen
    if args.action == "batch":
        return sqlgen.generate_batch(args.number, timestamp=args.timestamp)
    if args.action == "check":
        return sqlgen.check()
    return 2


def cmd_sources_doc(args):
    from . import sourcesdoc
    return sourcesdoc.write()


def main(argv):
    p = argparse.ArgumentParser(prog="qcat", description=__doc__)
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("version").set_defaults(fn=cmd_version)
    r = sub.add_parser("registry")
    r.add_argument("action", choices=["check", "allowlist"])
    r.add_argument("--as-of")
    r.set_defaults(fn=cmd_registry)
    c = sub.add_parser("corpus")
    c.add_argument("action", choices=["fetch", "lock", "status"])
    c.add_argument("--gutenberg")
    c.add_argument("--wikisource", action="append")
    c.add_argument("--pg-catalog", action="store_true")
    c.add_argument("--wikiquote-dump", action="store_true")
    c.add_argument("--list-only")
    c.add_argument("--accept-drift", action="store_true")
    c.set_defaults(fn=cmd_corpus)
    a = sub.add_parser("acceptance")
    a.add_argument("--live-rejects", action="store_true")
    a.set_defaults(fn=cmd_acceptance)
    w = sub.add_parser("wikiquote")
    w.add_argument("action", choices=["import"])
    w.add_argument("--dump")
    w.set_defaults(fn=cmd_wikiquote)
    v = sub.add_parser("verify")
    v.add_argument("--leads", required=True)
    v.add_argument("--run", required=True)
    v.add_argument("--as-of")
    v.set_defaults(fn=cmd_verify)
    sub.add_parser("selftest").set_defaults(fn=cmd_selftest)
    sub.add_parser("excerpts").set_defaults(fn=cmd_excerpts)
    rv = sub.add_parser("review")
    rv.add_argument("action", choices=["build"])
    rv.add_argument("--run", required=True)
    rv.set_defaults(fn=cmd_review)
    ap = sub.add_parser("approve")
    ap.add_argument("number", type=int)
    ap.add_argument("--run", required=True)
    ap.set_defaults(fn=cmd_approve)
    g = sub.add_parser("generate")
    g.add_argument("action", choices=["batch", "check"])
    g.add_argument("number", nargs="?", type=int)
    g.add_argument("--timestamp")
    g.set_defaults(fn=cmd_generate)
    sub.add_parser("sources-doc").set_defaults(fn=cmd_sources_doc)
    args = p.parse_args(argv)
    if not getattr(args, "fn", None):
        p.print_help()
        return 2
    return args.fn(args)
