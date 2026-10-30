"""The static review page for a batch: build/catalog/review/<run>.html.

Each card shows the body as the app will show it, the author, work and location, the source passage
around it, the verifier class and flags, the public-domain verdict, proposed themes and mood, and the
recommendation, ranked by score. The founder marks Keep or Skip (keys: a / x; 1-7 themes; q w e r t y
mood; j / k to move). Decisions are kept in the browser and exported as decisions/<batch>.jsonl; when
the page is opened as a claude.ai artifact with the db capability, they are saved there instead.
"""

import html
import json
import os

from . import config, registry

THEME_KEYS = list(zip("1234567", config.THEMES))
MOOD_KEYS = list(zip("qwerty", config.MOODS))


def _card(r, reg, rank):
    w = reg.works.get(r.get("work_id"))
    a = reg.author(r["author"]) if r.get("author") else None
    lead = r.get("lead", {})
    deaths = []
    if a:
        deaths.append("%s d. %s" % (a["name"], _year(a.get("died_year"))))
    if w and w["author_id"] != (a or {}).get("id"):
        wa = reg.authors[w["author_id"]]
        deaths.append("%s d. %s" % (wa["name"], _year(wa.get("died_year"))))
    if w and w.get("translator"):
        deaths.append("trans. %s d. %s" % (w["translator"], _year(w.get("translator_died_year"))))
    if w and w.get("reporter"):
        deaths.append("reported by %s d. %s" % (w["reporter"], _year(w.get("reporter_died_year"))))
    return {
        "id": r["lead_id"], "rank": rank, "score": r.get("score"), "rubric": r.get("rubric"),
        "body": r.get("body"), "author": r.get("author"), "source": r.get("source"),
        "location": lead.get("location"), "speaker": lead.get("speaker"),
        "cls": r.get("final"), "flags": r.get("flags", []), "edits": r.get("edits") or [],
        "prefix": (r.get("prefix_dropped") or "").strip(), "gaps": r.get("gaps") or [],
        "pd": {"us": (r.get("pd") or {}).get("us"), "strict": (r.get("pd") or {}).get("strict"),
               "blocking": (r.get("pd") or {}).get("blocking", []), "edition": w and w.get("edition_year"),
               "deaths": deaths},
        "before": (r.get("context_before") or "")[-320:], "span": r.get("source_text") or "",
        "after": (r.get("context_after") or "")[:320],
        "themes": lead.get("themes", []), "mood": lead.get("mood"), "recommend": lead.get("recommend"),
        "why": lead.get("why"), "authorId": a and a["id"], "workId": w and w["id"],
        "woman": bool(a and a.get("woman")), "region": a and a.get("region"),
        "verse": "\n" in (r.get("body") or ""), "url": w and w.get("source_url"), "ref": r.get("ref"),
        "leadFlags": lead.get("flags", []),
    }


def _year(y):
    if y is None:
        return "?"
    return "%d BCE" % -y if y < 0 else str(y)


def build(run_name):
    reg = registry.Registry.load()
    path = os.path.join(config.build_dir(), "runs", run_name, "results.jsonl")
    rows = registry.read_jsonl(path)
    cards = [r for r in rows if r.get("body")]
    cards.sort(key=lambda r: (0 if r.get("lead", {}).get("recommend") == "keep" else 1, -(r.get("score") or 0)))
    data = [_card(r, reg, i + 1) for i, r in enumerate(cards)]
    batch = run_name.split("-")[1] if run_name.startswith("batch-") else run_name
    out_dir = os.path.join(config.build_dir(), "review")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "%s.html" % run_name)
    page = PAGE.replace("__BATCH__", html.escape(batch)).replace(
        "__DATA__", json.dumps({"batch": batch, "cards": data, "themes": config.THEMES, "moods": config.MOODS},
                               ensure_ascii=False).replace("</", "<\\/"))
    # The local file is a whole document; <run>.artifact.html is the same page for publishing as a
    # claude.ai artifact (the publisher adds the document skeleton there).
    with open(out, "w", encoding="utf-8") as f:
        f.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body>'
                + page + "</body></html>\n")
    with open(out[:-5] + ".artifact.html", "w", encoding="utf-8") as f:
        f.write(page)
    print("review page:", out, "(%d cards)" % len(data))
    return 0


PAGE = r"""<title>Catalog Batch __BATCH__</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,600;1,6..72,400&family=Atkinson+Hyperlegible:wght@400;700&display=swap">
<style>
/* Layout: one reading column of quote cards under a sticky tally bar; the quote is the hero of each card. */
:root {
  --ground: #F8F8F6; --surface: #FFFFFF; --ink: #1B1C20; --muted: #62646E; --hairline: #E6E4DF;
  --accent: #2B44C9; --accent-soft: rgba(43,68,201,.10); --on-accent: #FFFFFF;
  --good: #1E7A4C; --good-soft: rgba(30,122,76,.12); --warn: #9A5B00; --warn-soft: rgba(154,91,0,.12);
  --bad: #B3261E; --bad-soft: rgba(179,38,30,.10); --mark: rgba(43,68,201,.16);
  --quote: "Newsreader", "Iowan Old Style", "Palatino", Georgia, serif;
  --ui: "Atkinson Hyperlegible", -apple-system, "Segoe UI", system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --ground: #0C0C0E; --surface: #161619; --ink: #ECECEF; --muted: #A2A3AD; --hairline: rgba(255,255,255,.08);
  --accent: #8B98FF; --accent-soft: rgba(139,152,255,.18); --on-accent: #0C0C0E;
  --good: #6FD39C; --good-soft: rgba(111,211,156,.14); --warn: #F0B35A; --warn-soft: rgba(240,179,90,.14);
  --bad: #FF8A80; --bad-soft: rgba(255,138,128,.14); --mark: rgba(139,152,255,.26); color-scheme: dark } }
:root[data-theme="dark"] {
  --ground: #0C0C0E; --surface: #161619; --ink: #ECECEF; --muted: #A2A3AD; --hairline: rgba(255,255,255,.08);
  --accent: #8B98FF; --accent-soft: rgba(139,152,255,.18); --on-accent: #0C0C0E;
  --good: #6FD39C; --good-soft: rgba(111,211,156,.14); --warn: #F0B35A; --warn-soft: rgba(240,179,90,.14);
  --bad: #FF8A80; --bad-soft: rgba(255,138,128,.14); --mark: rgba(139,152,255,.26); color-scheme: dark }
* { box-sizing: border-box }
body { background: var(--ground); color: var(--ink); font: 15px/1.5 var(--ui); margin: 0 }
body::before { content: ""; position: fixed; inset: 0 0 auto; height: env(safe-area-inset-top, 0px); z-index: 10; background: var(--ground) }
.wrap { max-width: 760px; margin: 0 auto; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); padding-block: 24px 80px }
header.intro { display: grid; gap: 6px; margin-bottom: 18px }
h1 { font: 600 28px/1.15 var(--quote); margin: 0; text-wrap: balance }
.lede { color: var(--muted); margin: 0; max-width: 62ch }
.bar { position: sticky; top: env(safe-area-inset-top, 0px); z-index: 5; background: var(--ground); border-bottom: 1px solid var(--hairline); padding-block: 10px; margin-bottom: 18px; display: grid; gap: 8px }
.tally { display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: baseline; font-variant-numeric: tabular-nums; font-size: 13px; color: var(--muted) }
.tally strong { color: var(--ink); font-size: 15px }
.tally .over { color: var(--bad); font-weight: 700 }
.controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center }
.seg { display: inline-flex; border: 1px solid var(--hairline); border-radius: 999px; overflow: hidden; background: var(--surface) }
.seg button { border: 0; background: none; color: var(--muted); font: 13px var(--ui); padding: 6px 12px; cursor: pointer }
.seg button[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); font-weight: 700 }
.btn { border: 1px solid var(--hairline); background: var(--surface); color: var(--ink); font: 13px var(--ui); padding: 7px 12px; border-radius: 999px; cursor: pointer }
.btn.primary { background: var(--accent); color: var(--on-accent); border-color: var(--accent); font-weight: 700 }
.save { font-size: 12px; color: var(--muted); margin-left: auto }
button:focus-visible, .card:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px }
.list { display: grid; gap: 14px }
.card { background: var(--surface); border: 1px solid var(--hairline); border-radius: 14px; padding: 16px 18px; display: grid; gap: 10px; scroll-margin-top: 120px }
.card.kept { border-color: var(--good); box-shadow: inset 3px 0 0 var(--good) }
.card.skipped { opacity: .62 }
.top { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; font-size: 12px }
.rank { font: 600 13px var(--mono); color: var(--muted); margin-right: 4px }
.chip { border-radius: 999px; padding: 2px 9px; background: var(--accent-soft); color: var(--accent); white-space: nowrap }
.chip.good { background: var(--good-soft); color: var(--good) }
.chip.warn { background: var(--warn-soft); color: var(--warn) }
.chip.bad { background: var(--bad-soft); color: var(--bad) }
.chip.plain { background: none; border: 1px solid var(--hairline); color: var(--muted) }
blockquote { margin: 0; font: 400 21px/1.42 var(--quote); white-space: pre-line; text-wrap: pretty }
.attr { color: var(--muted); font-size: 14px }
.attr b { color: var(--ink); font-weight: 700 }
.attr i { font-family: var(--quote); font-size: 15px }
.why { font-size: 14px; margin: 0 }
.why .rec { font-weight: 700 }
.why .rec.keep { color: var(--good) } .why .rec.skip { color: var(--muted) }
details { font-size: 13px; color: var(--muted) }
summary { cursor: pointer; width: fit-content }
.ctx { margin-top: 8px; font: 13px/1.55 var(--quote); color: var(--muted); white-space: pre-wrap; background: var(--ground); border-radius: 10px; padding: 10px 12px; overflow-wrap: anywhere }
.ctx mark { background: var(--mark); color: var(--ink); border-radius: 3px }
.meta { display: grid; gap: 2px; margin-top: 8px; font-size: 12.5px }
.pick { display: flex; flex-wrap: wrap; gap: 6px; align-items: center }
.pick .lbl { font-size: 11px; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); width: 52px }
.pick button { border: 1px solid var(--hairline); background: none; color: var(--muted); font: 12.5px var(--ui); padding: 4px 10px; border-radius: 999px; cursor: pointer }
.pick button[aria-pressed="true"] { border-color: var(--accent); background: var(--accent-soft); color: var(--accent); font-weight: 700 }
.pick kbd { font: 10px var(--mono); opacity: .6; margin-left: 4px }
.decide { display: flex; gap: 8px; flex-wrap: wrap }
.decide button { flex: 1 1 120px; border: 1px solid var(--hairline); background: var(--ground); color: var(--ink); font: 700 14px var(--ui); padding: 10px; border-radius: 10px; cursor: pointer }
.decide .keep[aria-pressed="true"] { background: var(--good); border-color: var(--good); color: var(--surface) }
.decide .skip[aria-pressed="true"] { background: var(--muted); border-color: var(--muted); color: var(--surface) }
.note { width: 100%; font: 13px var(--ui); color: var(--ink); background: var(--ground); border: 1px solid var(--hairline); border-radius: 8px; padding: 7px 9px }
.empty { color: var(--muted); padding: 30px 0; text-align: center }
.keys { font-size: 12px; color: var(--muted) }
@media (prefers-reduced-motion: no-preference) { .card { transition: border-color .15s, opacity .15s } }
</style>

<div class="wrap">
  <header class="intro">
    <h1>Catalog batch __BATCH__: your review</h1>
    <p class="lede">Each line below was found in its pinned public-domain edition and rendered from that text. Keep the ones worth knowing by heart, check the themes and mood, and skip the rest. The batch takes at most 50, with at most 3 per author and 2 per work.</p>
    <p class="keys">Keys: <b>a</b> keep · <b>x</b> skip · <b>1–7</b> themes · <b>q w e r t y</b> mood · <b>j / k</b> next and previous.</p>
  </header>
  <div class="bar" role="region" aria-label="Batch tally">
    <div class="tally" id="tally"></div>
    <div class="controls">
      <div class="seg" role="group" aria-label="Show">
        <button id="f-all" aria-pressed="true" data-f="all">All</button>
        <button id="f-rec" aria-pressed="false" data-f="rec">Recommended</button>
        <button id="f-open" aria-pressed="false" data-f="open">Undecided</button>
        <button id="f-kept" aria-pressed="false" data-f="kept">Kept</button>
      </div>
      <button class="btn" id="accept-recs">Accept my recommendations</button>
      <button class="btn primary" id="export" hidden>Export decisions</button>
      <span class="save" id="save" aria-live="polite">Saved in this browser</span>
    </div>
  </div>
  <main class="list" id="list"><p class="empty">Loading the batch…</p></main>
</div>

<script type="application/json" id="data">__DATA__</script>
<script>
(() => {
  const D = JSON.parse(document.getElementById("data").textContent);
  const KEY = "qcat-review-" + D.batch;
  const THEMES = D.themes, MOODS = D.moods, TK = "1234567", MK = "qwerty";
  let state = {};
  try { state = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { state = {}; }
  let filter = "all", focusIdx = 0, db = null, lastMark = performance.now();
  const shown = {};

  function dec(id) {
    const c = D.cards.find(c => c.id === id);
    if (!state[id]) state[id] = { decision: null, themes: c.themes.slice(), mood: c.mood, note: "" };
    return state[id];
  }
  function persist(id) {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {}
    const s = state[id];
    if (db && s) {
      setSave("Saving…");
      db.collection("decisions").doc(id).set({ lead_id: id, decision: s.decision, themes: s.themes, mood: s.mood,
        note: s.note || "", ms: s.ms || 0, decided_at: s.at || null, order: s.order || 0 })
        .then(() => setSave("Saved for Claude to read")).catch(() => setSave("Couldn’t save to the batch; kept in this browser"));
    } else setSave("Saved in this browser");
  }
  function setSave(t) { document.getElementById("save").textContent = t; }

  function chip(text, cls) { const s = document.createElement("span"); s.className = "chip " + (cls || ""); s.textContent = text; return s; }
  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  function editText(c) {
    const out = [];
    for (const e of c.edits) {
      if (e.kind === "trim_start") out.push(c.prefix ? "starts mid-sentence (drops “" + c.prefix + "”)" : "starts mid-sentence");
      else if (e.kind === "capitalise_first") out.push("first letter capitalised");
      else if (e.kind === "close_period") out.push(e.was ? "“" + e.was + "” at the cut closed with a period" : "period added at the cut");
      else if (e.kind === "drop_end_punct") out.push("“" + e.was + "” after the sentence dropped");
      else if (e.kind === "elide") out.push("words left out (" + c.gaps.map(g => "“" + g.replace(/\s+/g, " ").trim() + "”").join(", ") + ")");
    }
    return out;
  }

  function card(c) {
    const s = dec(c.id);
    const a = el("article", "card"); a.tabIndex = 0; a.id = "card-" + c.id; a.dataset.id = c.id;
    const top = el("div", "top");
    top.append(el("span", "rank", "#" + c.rank));
    top.append(chip("score " + Math.round(c.score || 0), "plain"));
    top.append(chip(c.recommend === "keep" ? "Recommended" : "Not recommended", c.recommend === "keep" ? "good" : "plain"));
    top.append(chip(c.cls.replace("PASS_", "").toLowerCase() + " match", c.cls.startsWith("PASS") ? "good" : "bad"));
    top.append(chip("US " + (c.pd.us ? "✓" : "✗") + " · strict " + (c.pd.strict ? "✓" : "✗"), c.pd.us && c.pd.strict ? "good" : "bad"));
    for (const f of c.flags.concat(c.leadFlags)) top.append(chip(f.replace(/_/g, " "), "warn"));
    a.append(top);
    a.append(el("blockquote", null, c.body));
    const attr = el("div", "attr");
    const b = el("b", null, c.author); const i = el("i", null, c.source);
    attr.append(b, document.createTextNode(", "), i, document.createTextNode(c.location ? ". " + c.location : ""));
    if (c.speaker) attr.append(document.createTextNode(". Spoken by " + c.speaker));
    a.append(attr);
    const why = el("p", "why");
    why.append(el("span", "rec " + c.recommend, c.recommend === "keep" ? "Keep: " : "Skip: "), document.createTextNode(c.why || ""));
    a.append(why);
    const det = el("details"); det.append(el("summary", null, "Source passage and checks"));
    const ctx = el("div", "ctx");
    ctx.append(document.createTextNode("…" + c.before)); const m = el("mark", null, c.span); ctx.append(m, document.createTextNode(c.after + "…"));
    det.append(ctx);
    const meta = el("div", "meta");
    const edits = editText(c);
    meta.append(el("div", null, "Rendered from " + (c.ref || "") + ". " + (edits.length ? "Edits: " + edits.join("; ") + "." : "No edits.")));
    meta.append(el("div", null, "Public domain: edition " + (c.pd.edition < 0 ? -c.pd.edition + " BCE" : c.pd.edition) + "; " + c.pd.deaths.join("; ") + "." + (c.pd.blocking.length ? " Blocked: " + c.pd.blocking.join("; ") : "")));
    const rb = c.rubric || {};
    meta.append(el("div", null, "Rubric (0–3): fame " + rb.fame + ", stands alone " + rb.stands_alone + ", turn " + rb.turn + ", image " + rb.image + ", charge " + rb.charge + ", brevity " + rb.brevity + ", readability " + rb.readability + "."));
    det.append(meta); a.append(det);
    const th = el("div", "pick"); th.append(el("span", "lbl", "Themes"));
    THEMES.forEach((t, k) => { const bt = el("button", null, t); bt.append(el("kbd", null, TK[k])); bt.setAttribute("aria-pressed", s.themes.includes(t)); bt.onclick = () => toggleTheme(c.id, t); th.append(bt); });
    a.append(th);
    const mo = el("div", "pick"); mo.append(el("span", "lbl", "Mood"));
    MOODS.forEach((t, k) => { const bt = el("button", null, t); bt.append(el("kbd", null, MK[k])); bt.setAttribute("aria-pressed", s.mood === t); bt.onclick = () => setMood(c.id, t); mo.append(bt); });
    a.append(mo);
    const dd = el("div", "decide");
    const keep = el("button", "keep", "Keep"); keep.setAttribute("aria-pressed", s.decision === "keep"); keep.onclick = () => decide(c.id, "keep");
    const skip = el("button", "skip", "Skip"); skip.setAttribute("aria-pressed", s.decision === "skip"); skip.onclick = () => decide(c.id, "skip");
    dd.append(keep, skip); a.append(dd);
    const note = el("input", "note"); note.id = "note-" + c.id; note.placeholder = "Note (optional)"; note.value = s.note || "";
    note.onchange = () => { dec(c.id).note = note.value; persist(c.id); };
    a.append(note);
    a.classList.toggle("kept", s.decision === "keep"); a.classList.toggle("skipped", s.decision === "skip");
    a.onfocus = () => { focusIdx = visible().findIndex(x => x.id === c.id); };
    return a;
  }

  function visible() {
    return D.cards.filter(c => {
      const s = state[c.id];
      if (filter === "rec") return c.recommend === "keep";
      if (filter === "open") return !s || !s.decision;
      if (filter === "kept") return s && s.decision === "keep";
      return true;
    });
  }
  function render() {
    const list = document.getElementById("list"); list.textContent = "";
    const v = visible();
    if (!v.length) list.append(el("p", "empty", filter === "kept" ? "Nothing kept yet. Press Keep on a card, or accept the recommendations." : "Nothing to show here."));
    for (const c of v) list.append(card(c));
    tally();
  }
  function rerenderCard(id) {
    const old = document.getElementById("card-" + id); if (!old) return;
    const c = D.cards.find(c => c.id === id); const n = card(c); old.replaceWith(n); n.focus({ preventScroll: true }); tally();
  }
  function decide(id, d) {
    const s = dec(id); const now = performance.now();
    s.decision = s.decision === d ? null : d; s.ms = Math.round(Math.min(now - lastMark, 300000)); lastMark = now;
    s.at = new Date().toISOString(); s.order = Object.values(state).filter(x => x.decision).length;
    persist(id); rerenderCard(id);
  }
  function toggleTheme(id, t) {
    const s = dec(id); const i = s.themes.indexOf(t);
    if (i >= 0) s.themes.splice(i, 1); else if (s.themes.length < 3) s.themes.push(t);
    persist(id); rerenderCard(id);
  }
  function setMood(id, m) { dec(id).mood = m; persist(id); rerenderCard(id); }

  function tally() {
    const kept = D.cards.filter(c => state[c.id] && state[c.id].decision === "keep");
    const decided = D.cards.filter(c => state[c.id] && state[c.id].decision).length;
    const per = (k) => { const m = {}; kept.forEach(c => { m[c[k]] = (m[c[k]] || 0) + 1; }); return m; };
    const overA = Object.entries(per("authorId")).filter(([, n]) => n > 3).length;
    const overW = Object.entries(per("workId")).filter(([, n]) => n > 2).length;
    const pct = (n) => kept.length ? Math.round(100 * n / kept.length) + "%" : "–";
    const women = kept.filter(c => c.woman).length, verse = kept.filter(c => c.verse).length;
    const outside = kept.filter(c => !["uk", "us"].includes(c.region)).length;
    const moods = {}; kept.forEach(c => { const m = state[c.id].mood || "?"; moods[m] = (moods[m] || 0) + 1; });
    const motiv = (moods.rousing || 0) + (moods.steadying || 0), deep = (moods.reflective || 0) + (moods.consoling || 0), tender = (moods.tender || 0) + (moods.delight || 0);
    const noTheme = kept.filter(c => !state[c.id].themes.length).length;
    const t = document.getElementById("tally"); t.textContent = "";
    const add = (label, value, bad) => { const s = el("span"); const st = el("strong", bad ? "over" : null, value); s.append(st, document.createTextNode(" " + label)); t.append(s); };
    add("kept of 50", String(kept.length), kept.length > 50);
    add("decided of " + D.cards.length, String(decided));
    add("authors over 3", String(overA), overA > 0);
    add("works over 2", String(overW), overW > 0);
    add("women", pct(women)); add("outside UK and US", pct(outside)); add("verse", pct(verse));
    add("motivational · deep · tender", pct(motiv) + " · " + pct(deep) + " · " + pct(tender));
    if (noTheme) add("kept without a theme", String(noTheme), true);
  }

  function exportLines() {
    return D.cards.filter(c => state[c.id] && state[c.id].decision).map(c => {
      const s = state[c.id];
      return JSON.stringify({ lead_id: c.id, decision: s.decision, themes: s.themes, mood: s.mood, note: s.note || "", ms: s.ms || 0, decided_at: s.at || null, order: s.order || 0 });
    }).join("\n") + "\n";
  }
  document.getElementById("export").onclick = () => {
    const blob = new Blob([exportLines()], { type: "application/x-ndjson" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = D.batch + ".jsonl"; a.click();
    setSave("Exported " + D.batch + ".jsonl: put it in supabase/catalog/decisions/");
  };
  document.getElementById("accept-recs").onclick = () => {
    for (const c of D.cards) { const s = dec(c.id); if (!s.decision) { s.decision = c.recommend === "keep" ? "keep" : "skip"; s.at = new Date().toISOString(); s.order = Object.values(state).filter(x => x.decision).length; persist(c.id); } }
    render();
  };
  document.querySelectorAll(".seg button").forEach(b => b.onclick = () => {
    filter = b.dataset.f; document.querySelectorAll(".seg button").forEach(x => x.setAttribute("aria-pressed", x === b)); render();
  });
  document.addEventListener("keydown", (e) => {
    if (e.target.tagName === "INPUT" || e.metaKey || e.ctrlKey || e.altKey) return;
    const v = visible(); if (!v.length) return;
    const c = v[Math.max(0, Math.min(focusIdx, v.length - 1))];
    const k = e.key.toLowerCase();
    if (k === "j" || k === "k") { focusIdx = Math.max(0, Math.min(v.length - 1, focusIdx + (k === "j" ? 1 : -1))); const n = document.getElementById("card-" + v[focusIdx].id); n && n.focus(); n && n.scrollIntoView({ block: "start" }); e.preventDefault(); }
    else if (k === "a") { decide(c.id, "keep"); }
    else if (k === "x") { decide(c.id, "skip"); }
    else if (TK.includes(k)) { toggleTheme(c.id, THEMES[TK.indexOf(k)]); }
    else if (MK.includes(k)) { setMood(c.id, MOODS[MK.indexOf(k)]); }
  });

  render();
  const isFile = location.protocol === "file:";
  if (isFile) document.getElementById("export").hidden = false;
  if (window.claude && window.claude.use) {
    window.claude.use("db").then((x) => {
      if (!x) { document.getElementById("export").hidden = false; return; }
      db = x; setSave("Saved for Claude to read");
      db.collection("decisions").onSnapshot((snap) => {
        for (const d of snap.docs) { const v = d.data(); if (v && v.lead_id) state[v.lead_id] = Object.assign(dec(v.lead_id), { decision: v.decision, themes: v.themes || [], mood: v.mood, note: v.note || "", ms: v.ms, at: v.decided_at, order: v.order }); }
        render();
      }, () => setSave("Couldn’t reach the saved decisions; keeping them in this browser"));
    }).catch(() => { document.getElementById("export").hidden = false; });
  } else if (!isFile) document.getElementById("export").hidden = false;
})();
</script>
"""
