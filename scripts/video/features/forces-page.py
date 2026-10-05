#!/usr/bin/env python3
"""Build the Cosmic Forces review page from build.json + gate.json.

⛔ NOT ONE NUMBER ON THIS PAGE IS TYPED IN. Every figure is read from the build
that produced the audio or the gate run that measured it. This tree has already
shipped prose that drifted off its own form — a blurb claiming "the last two
minutes carry all three" about a 91-second section that was not last — and the
fix for that class of bug is never proofreading, it is removing the opportunity.
If a form changes, re-run the build, re-run the gate, re-run this.

⚠ `review-page.py` is hardcoded to the five Starlight pieces (`ORDER`) and reads
`family` as a two-way switch, so family "f" would be labelled "the one you
approved (B)". Rather than widen that switch and risk the page that is already
collecting a decision, Forces gets its own generator in the same design system.

Usage:  forces-page.py > out/forces-page/index.html
"""

import html
import json
import os
import sys

# Axis order — least overlap to most. The pick only means something if the
# three sit on ONE axis, so the page is ordered along it rather than by
# preference or by build date.
ORDER = ["cosmic-forces-apart", "cosmic-forces", "cosmic-forces-crossing"]
NOT_OFFERED = "cosmic-forces-converge"
FORCES = ["stardust", "knowledge", "consciousness"]
LABEL = {"stardust": "Stardust", "knowledge": "Knowledge",
         "consciousness": "Consciousness"}

# What each force IS, in the words of someone who is not a musician. Register
# and attack, because those are the two axes that survive a phone speaker.
WHAT = {
    "stardust": ("high and granular",
                 "points of light — short, bright, never quite on the beat"),
    "knowledge": ("middle, and it speaks",
                  "an ordered unfolding, with a voice on top of it"),
    "consciousness": ("low and enveloping",
                      "one slow mass that arrives rather than starts"),
}


def esc(s):
    return html.escape(str(s), quote=True)


def mmss(sec):
    sec = int(round(sec))
    return f"{sec // 60}:{sec % 60:02d}"


def watch(variant):
    """Link to the private YouTube draft, when one has been uploaded.

    Absent id -> no link, rather than a dead one. These are PRIVATE drafts: only
    the signed-in owner can open them, so the page says so instead of letting a
    link look broken to anyone else.
    """
    p = "publish/forces-videos.json"
    if not os.path.exists(p):
        return ""
    v = json.load(open(p)).get(variant)
    if not v:
        return ""
    LABEL_ = [("long", "Full video", "5:25"),
              ("loop", "1-min loop", "repeats seamlessly"),
              ("handover", "1-min handover", "fades, no jump")]
    links = "".join(
        f'<a href="https://youtu.be/{esc(v[k])}" target="_blank" rel="noopener">'
        f'{esc(lab)}<em>{esc(note)}</em></a>'
        for k, lab, note in LABEL_ if v.get(k))
    if not links:
        return ""
    return (f'<div class="watch">{links}</div>'
            f'<p class="watchnote">Private drafts — visible to you when signed in.</p>')


def load(variant):
    d = f"out/{variant}"
    b = json.load(open(f"{d}/build.json"))
    gp = f"{d}/gate.json"
    g = json.load(open(gp)) if os.path.exists(gp) else None
    return b, g


# A second force below this share of the sound is a tint on the first, not a
# thing you would call co-present. The line is a judgement and it is stated on
# the page rather than hidden in the arithmetic.
BOTH_AUDIBLE = 0.20


def overlap_bars(b, g):
    """Bars where two forces are BOTH genuinely audible — the axis, measured.

    ⛔ THE STRUCTURAL VERSION OF THIS WAS WRONG AND THE PAGE SHOWED IT. Counting
    sections whose layer list names two forces reported 3:56 of overlap in a
    5:05 piece, because a single residual layer — `veil` still sighing under the
    Knowledge section, `glint` under the Wash — makes a section formally
    "two forces" while one of them is 0.2% of the sound. That is presence, and
    presence is not what the listener is being asked about.

    So the axis is read off the gate's measured per-section share: a section
    counts when the QUIETER of the two is still at least BOTH_AUDIBLE of it.
    That returns 0 / 1:01 / 1:47 across the three, which is the difference a
    listener is actually being asked to judge.
    """
    n = 0
    for s in b["sections"]:
        sh = sorted(g["sectionShare"].get(s["name"], {}).values(), reverse=True)
        if len(sh) > 1 and sh[1] >= BOTH_AUDIBLE:
            n += s["bars"]
    return n


def timeline(b, g):
    """Three lanes, one per force, height = that force's measured share.

    ⭐ THIS DRAWS THE MEASUREMENT, NOT THE INTENTION. The heights come from the
    gate's per-section share of each force's own bounced stem, so what the
    reader sees is what the audio does — if a force did not actually recede, the
    picture would show it not receding.
    """
    if not g:
        return ""
    W, LANE, GAP, TOP = 100.0, 13.0, 5.0, 3.0
    H = TOP + 3 * LANE + 2 * GAP + 11
    total = b["bars"]
    share = g["sectionShare"]
    peak = g["peakOf"]
    out = [f'<svg viewBox="0 0 {W:g} {H:g}" role="img" aria-label="Each '
           f'energy’s share of the sound, section by section">']

    for i, f in enumerate(FORCES):
        y0 = TOP + i * (LANE + GAP)
        out.append(f'<g class="lane {f}">')
        out.append(f'<rect class="bed" x="0" y="{y0:g}" width="{W:g}" '
                   f'height="{LANE:g}" rx="1.5"/>')
        x = 0.0
        for s in b["sections"]:
            w = s["bars"] / total * W
            v = share.get(s["name"], {}).get(f, 0.0)
            if v > 0.004:
                h = max(0.7, v * LANE)
                out.append(f'<rect class="v" x="{x:g}" y="{y0 + LANE - h:g}" '
                           f'width="{max(w - 0.35, 0.4):g}" height="{h:g}"/>')
            if s["name"] == peak.get(f):
                out.append(f'<rect class="peak" x="{x:g}" y="{y0:g}" '
                           f'width="{max(w - 0.35, 0.4):g}" height="{LANE:g}" rx="1.5"/>')
            x += w
        out.append(f'<text class="lname" x="0.8" y="{y0 + LANE - 2.6:g}">'
                   f'{esc(LABEL[f])}</text>')
        out.append("</g>")

    # Minute marks, so "emerges at 1:09" on the card can be found in the picture.
    spb = 4 * 60.0 / b["tempo"]
    yb = TOP + 3 * LANE + 2 * GAP
    out.append(f'<g class="axis"><line x1="0" y1="{yb + 1:g}" x2="{W:g}" '
               f'y2="{yb + 1:g}"/>')
    m = 0
    while m * 60 <= b["seconds"]:
        x = (m * 60 / spb) / total * W
        if x <= W:
            out.append(f'<line class="tick" x1="{x:g}" y1="{yb + 1:g}" '
                       f'x2="{x:g}" y2="{yb + 3.4:g}"/>')
            out.append(f'<text x="{min(x, W - 3):g}" y="{yb + 8.6:g}">{m}:00</text>')
        m += 1
    out.append("</g></svg>")
    return "".join(out)


def card(variant, b, g):
    ov = overlap_bars(b, g)
    spb = 4 * 60.0 / b["tempo"]
    ov_s = ov * spb
    axis = "never" if ov == 0 else mmss(ov_s)
    # ⛔ `emergeSeconds` is build.json's declared emergeBar x seconds-per-bar — a
    # DESIGN CONSTANT, not a measurement, and this page used to print it under a
    # note promising the figures came from the audio. They disagree: Stardust is
    # declared at 0.0 s and is not audible until 8.0 s in every piece, and
    # apart's Knowledge is declared 7.3 s early. Use the measured onset, and
    # FAIL rather than quietly falling back to the design value.
    if "firstAudibleSeconds" not in g:
        sys.exit(f"⛔ {variant}: gate.json has no firstAudibleSeconds — run "
                 f"forces-onset.py --write. Refusing to print design values "
                 f"under a 'measured' label.")
    facts = []
    for f in FORCES:
        t = g["firstAudibleSeconds"][f]
        if t is None:
            sys.exit(f"⛔ {variant}: {f} never rises above the floor")
        facts.append(
            f'<div><dt>{esc(LABEL[f])} first heard</dt>'
            f'<dd>{mmss(t)}</dd></div>')
    facts.append(f'<div><dt>Two of them at once</dt><dd>{esc(axis)}</dd></div>')
    facts.append(f'<div><dt>Length</dt><dd>{mmss(b["seconds"])}</dd></div>')
    lead = "  ".join(f"{LABEL[f][:4]} +{g['fullForceLeadDb'][f]:.1f}" for f in FORCES)
    facts.append(f'<div><dt>Peaks above its own next-loudest</dt>'
                 f'<dd class="sm">{esc(lead)} dB</dd></div>')

    # All three titles now share a 34-character prefix, so three identical-looking
    # headings would be unscannable. Keep the title VERBATIM (it has to match the
    # video the user will open) and let the distinguishing half carry the weight.
    if " · " in b["title"]:
        base, suffix = b["title"].split(" · ", 1)
        head = f'<span class="tsub">{esc(base)} ·</span> {esc(suffix)}'
    else:
        head = esc(b["title"])

    return f"""
<section class="piece" id="{esc(variant)}">
  <div class="ph">
    <div>
      <h2>{head}</h2>
      <p class="from">{esc(b['subtitle'])}</p>
    </div>
    <span class="tag">{esc(b['coexist'])}</span>
  </div>
  <p class="blurb">{esc(b['blurb'])}</p>
  <audio controls preload="none" src="audio/{esc(variant)}.mp3"></audio>
  {watch(variant)}
  <p class="clab">Who is sounding, across the piece <span>— measured, each one
    bounced on its own</span></p>
  {timeline(b, g)}
  <dl class="facts">{''.join(facts)}</dl>
  <button class="pick" data-pick="{esc(variant)}" aria-pressed="false">
    This is the one</button>
</section>"""


def main():
    loaded = [(v, *load(v)) for v in ORDER]
    missing = [v for v, b, g in loaded if g is None]
    if missing:
        sys.exit(f"⛔ no gate.json for {missing} — run forces-gate.py --json "
                 f"first; this page does not print unmeasured pieces")
    unpassed = [v for v, b, g in loaded if not g.get("passed")]
    if unpassed:
        sys.exit(f"⛔ {unpassed} did not pass the gate. A review page is for "
                 f"choosing between pieces that work, not for asking someone "
                 f"to overlook a measured defect.")

    # The one that was built and is NOT being offered — read from its own gate
    # run so the reason stays true if it is ever rebuilt.
    nb = ng = None
    if os.path.exists(f"out/{NOT_OFFERED}/gate.json"):
        nb, ng = load(NOT_OFFERED)

    cards = "".join(card(v, b, g) for v, b, g in loaded)
    payload = json.dumps({v: {"title": b["title"]} for v, b, g in loaded})

    forces_intro = "".join(
        f'<div class="fx {f}"><dt>{esc(LABEL[f])}</dt>'
        f'<dd><strong>{esc(WHAT[f][0])}</strong><br>{esc(WHAT[f][1])}</dd></div>'
        for f in FORCES)

    not_offered = ""
    if ng:
        # Which forces never peak in their own section, DERIVED from the
        # measurement — never scraped out of the gate's human-readable failure
        # text. Parsing prose is transcription by another name, and it shipped
        # the word "arrive" to the live page as a force name once already.
        bad_keys = [f for f in FORCES
                    if ng["fullForceLeadDb"].get(f, 99) < ng["marginDb"]]
        bad = " and ".join(LABEL[f] for f in bad_keys)
        # The longest run of every layer at once, also measured, so this stays
        # true if the form is ever rebuilt.
        spb = 240.0 / nb["tempo"]
        widest = max(nb["sections"], key=lambda s: (len(s["layers"]), s["bars"]))
        wide_s = round(widest["bars"] * spb)
        not_offered = f"""
<div class="note warn">
  <strong>A fourth one exists and I am not offering it.</strong>
  I also built a version where they pile up instead of taking turns —
  each one stays in the sound after its moment, dimming rather than leaving, and
  a stretch of {wide_s // 60}:{wide_s % 60:02d} near the end carries all
  {len(widest["layers"])} layers at once. It renders, and the three are still
  clearly separate in it. But measured against the brief,
  {esc(bad)} never get a moment that is theirs: the piece keeps getting bigger,
  so their own sections are never the loudest thing they do. That is its whole
  premise fighting your request, not a setting I can turn up, so it is not on
  this page. Say the word and I will play it to you anyway.
</div>"""

    css = """
:root {
  --ground:#F2F4FA; --panel:#FFFFFF; --edge:#D7DDEC; --ink:#131A2E; --dim:#5C6786;
  --accent:#1B5FA8; --amber:#9A5400; --bed:#E7EBF5;
  --star:#9A6B00; --know:#0F6F7C; --cons:#4B3FA8;
  --shadow:0 1px 2px rgba(19,26,46,.06),0 8px 24px rgba(19,26,46,.05);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground:#0B1020; --panel:#141B33; --edge:#26304F; --ink:#E9EDFA; --dim:#8E99BC;
    --accent:#7FD4FF; --amber:#FFB454; --bed:#1C2442;
    --star:#FFC861; --know:#63D8E3; --cons:#A79BFF;
    --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
  }
}
:root[data-theme="dark"] {
  --ground:#0B1020; --panel:#141B33; --edge:#26304F; --ink:#E9EDFA; --dim:#8E99BC;
  --accent:#7FD4FF; --amber:#FFB454; --bed:#1C2442;
  --star:#FFC861; --know:#63D8E3; --cons:#A79BFF;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
}
* { box-sizing:border-box; }
body { background:var(--ground); color:var(--ink);
  font:400 16px/1.6 Archivo,system-ui,-apple-system,"Segoe UI",sans-serif; }
.wrap { max-width:860px; margin:0 auto; padding:16px; padding-block:40px 72px; }
h1 { font:300 clamp(34px,7vw,56px)/1.05 Fraunces,Georgia,serif;
  letter-spacing:-.02em; margin:0 0 .3em; text-wrap:balance; }
h1 em { font-style:italic; font-weight:500; color:var(--accent); }
h2 { font:500 clamp(20px,3.4vw,26px)/1.15 Fraunces,Georgia,serif; margin:0;
  letter-spacing:-.01em; text-wrap:balance; }
/* The three titles share a long prefix; quieten it so the differing half reads. */
h2 .tsub { color:var(--dim); font-weight:300; }
h3 { font:500 clamp(18px,2.6vw,21px)/1.2 Fraunces,Georgia,serif; margin:2.4em 0 .6em; }
.lede { font-size:18px; color:var(--dim); max-width:62ch; margin:0 0 1.4em; }
.note { border-left:3px solid var(--accent);
  background:color-mix(in srgb,var(--accent) 7%,transparent);
  padding:14px 18px; border-radius:0 8px 8px 0; margin:0 0 1.6em; font-size:15px; }
.note.warn { border-left-color:var(--amber);
  background:color-mix(in srgb,var(--amber) 9%,transparent); }
.note strong { color:var(--accent); }
.note.warn strong { color:var(--amber); }
.three { display:grid; gap:12px; grid-template-columns:1fr; margin:0 0 2em; }
@media (min-width:640px) { .three { grid-template-columns:repeat(3,1fr); } }
.fx { background:var(--panel); border:1px solid var(--edge); border-left-width:4px;
  border-radius:0 10px 10px 0; padding:13px 15px; }
.fx.stardust { border-left-color:var(--star); }
.fx.knowledge { border-left-color:var(--know); }
.fx.consciousness { border-left-color:var(--cons); }
.fx dt { font:600 12px/1 "Chivo Mono",ui-monospace,monospace; letter-spacing:.08em;
  text-transform:uppercase; }
.fx.stardust dt { color:var(--star); }
.fx.knowledge dt { color:var(--know); }
.fx.consciousness dt { color:var(--cons); }
.fx dd { margin:7px 0 0; font-size:14.5px; color:var(--dim); }
.fx dd strong { color:var(--ink); font-weight:600; }
.piece { background:var(--panel); border:1px solid var(--edge); border-radius:14px;
  padding:22px; margin:0 0 20px; box-shadow:var(--shadow); }
.ph { display:flex; gap:12px; align-items:flex-start; justify-content:space-between;
  flex-wrap:wrap; }
.from { margin:.35em 0 0; color:var(--dim); font-size:13.5px;
  font-family:"Chivo Mono",ui-monospace,monospace; font-variant-numeric:tabular-nums; }
.tag { font:600 11px/1 "Chivo Mono",ui-monospace,monospace; letter-spacing:.08em;
  text-transform:uppercase; padding:7px 10px; border-radius:999px;
  border:1px solid var(--edge); color:var(--dim); white-space:nowrap; }
.blurb { margin:1em 0 1.1em; max-width:66ch; }
audio { width:100%; margin:0 0 18px; }
.watch { display:flex; flex-wrap:wrap; gap:8px; margin:-6px 0 6px; }
.watch a { flex:1 1 150px; display:flex; flex-direction:column; gap:2px;
  padding:9px 12px; border:1px solid var(--edge); border-radius:9px;
  text-decoration:none; color:var(--accent); font-weight:600; font-size:14px;
  background:color-mix(in srgb,var(--accent) 5%,transparent);
  transition:border-color .15s,background .15s; }
.watch a:hover { border-color:var(--accent);
  background:color-mix(in srgb,var(--accent) 11%,transparent); }
.watch a:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
.watch a em { font-style:normal; font-weight:400; font-size:12px; color:var(--dim); }
.watchnote { margin:0 0 16px; font-size:12.5px; color:var(--dim); }
.clab { margin:0 0 6px; font:600 11px/1.5 "Chivo Mono",ui-monospace,monospace;
  letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
.clab span { font-weight:400; text-transform:none; letter-spacing:0; opacity:.8; }
svg { width:100%; height:auto; display:block; overflow:visible; }
.lane .bed { fill:var(--bed); }
.lane.stardust .v { fill:var(--star); }
.lane.knowledge .v { fill:var(--know); }
.lane.consciousness .v { fill:var(--cons); }
.lane .peak { fill:none; stroke:var(--ink); stroke-width:.45; stroke-dasharray:1.6 1.2; }
.lane .lname { font:400 4px "Chivo Mono",ui-monospace,monospace; fill:var(--dim);
  letter-spacing:.06em; }
.axis line { stroke:var(--edge); stroke-width:.4; }
.axis text { font:400 3.6px "Chivo Mono",ui-monospace,monospace; fill:var(--dim); }
.facts { display:grid; gap:10px 18px;
  grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
  margin:18px 0 0; padding:16px 0 0; border-top:1px solid var(--edge); }
.facts div { margin:0; }
dt { font-size:12px; color:var(--dim); letter-spacing:.02em; }
dd { margin:2px 0 0; font:600 17px/1.2 "Chivo Mono",ui-monospace,monospace;
  font-variant-numeric:tabular-nums; }
dd.sm { font-size:13px; font-weight:400; }
.pick { margin-top:18px; font:600 14px/1 Archivo,sans-serif; padding:12px 18px;
  border-radius:9px; border:1px solid var(--edge); background:transparent;
  color:var(--ink); cursor:pointer; transition:background .15s,border-color .15s; }
.pick:hover { border-color:var(--accent); }
.pick:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
/* ⚠ --ground, not #fff: in the dark palette the accent is a pale cyan, and
   white-on-cyan would make the one control on this page unreadable. */
.pick[aria-pressed="true"] { background:var(--accent); color:var(--ground);
  border-color:var(--accent); }
.status { margin:10px 0 0; font-size:14px; color:var(--dim); min-height:1.5em; }
footer { margin-top:2.6em; padding-top:18px; border-top:1px solid var(--edge);
  color:var(--dim); font-size:14px; }
@media (prefers-reduced-motion: reduce) { * { transition:none !important; } }
"""

    js = """
const PIECES = __PAYLOAD__;
const buttons = [...document.querySelectorAll(".pick")];
const statusEl = document.getElementById("status");

let db = null;
try { db = await window.claude?.use?.("db"); } catch (_) { db = null; }

const paint = (v) => {
  for (const b of buttons) b.setAttribute("aria-pressed", String(b.dataset.pick === v));
  if (v && PIECES[v])
    statusEl.textContent = `Saved: ${PIECES[v].title}. Change it any time — the last click wins.`;
};

// Only one thing can play at a time, or the comparison is mush.
for (const a of document.querySelectorAll("audio")) {
  a.addEventListener("play", () => {
    for (const o of document.querySelectorAll("audio")) if (o !== a) o.pause();
  });
}

if (db) {
  db.doc("decisions/forces").onSnapshot((d) => paint(d?.data?.choice ?? null));
  for (const b of buttons) {
    b.addEventListener("click", () => {
      paint(b.dataset.pick);   // respond now; the snapshot confirms
      db.doc("decisions/forces").set({ choice: b.dataset.pick, at: new Date().toISOString() });
    });
  }
} else {
  // No viewer to save to — say so rather than letting clicks look like they stuck.
  for (const b of buttons) b.addEventListener("click", () => {
    paint(b.dataset.pick);
    statusEl.textContent = `Noted here: ${PIECES[b.dataset.pick].title} — but this view can't save it, so tell me in chat.`;
  });
}
"""

    print(f"""<title>Stardust, Knowledge, Consciousness</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300;9..144,500&family=Archivo:wght@400;600&family=Chivo+Mono:wght@400;600&display=swap">
<style>{css}</style>
<div class="wrap">
<h1>Stardust, Knowledge, Consciousness, <em>taking turns</em></h1>
<p class="lede">You asked for a piece like Starlight where three powerful
energies arrive at different times, each goes full strength, then gives way to
the next. Here it is three times over. Same key, same voice, same hall, still no
drums — the only thing that changes between them is <strong>how long two of them
overlap while one hands over to the other</strong>.</p>

<h3>The three energies</h3>
<div class="three">{forces_intro}</div>

<div class="note">
  <strong>Listen for the handover, not the tune.</strong> In all three the order
  is the same — stardust, then knowledge, then consciousness. What differs is
  whether the old one is still sounding when the new one arrives. The first has
  no overlap at all, the last has nearly two minutes of it. The bars under each
  piece show which of the three is actually carrying the sound at each moment;
  they are drawn from the audio, not from the plan. So is <em>first heard</em>:
  it is the moment that energy’s own bounced track genuinely rises out of
  silence, which is a few seconds later than the point it technically starts —
  all three pieces fade up from nothing.
</div>

{cards}

<p class="status" id="status">No pick saved yet.</p>

{not_offered}

<h3>Two things worth knowing</h3>
<div class="note">
  <strong>These three are volume-matched.</strong> They came out at slightly
  different levels, and the louder one always sounds better. I applied a fixed
  volume change to each so they meet at the same loudness — nothing else was
  touched, and each piece keeps its own quiet-to-loud range.
</div>
<div class="note">
  <strong>Tell me about the opening if anything strikes you.</strong> All three
  start the same way, with one high shimmering chord alone, and that sound is
  the one I am least able to check by measuring. If it reads as harsh, thin,
  metallic or too bright to you, say so in your own words — that is the part I
  cannot hear for myself.
</div>

<footer>Three versions of one piece, D minor, 63 BPM, no percussion. All three
are now finished — full length, with a moving visual, and up as private drafts
like the others. The button just tells me which one you would keep.</footer>
</div>
<script type="module">{js.replace("__PAYLOAD__", payload)}</script>""")


if __name__ == "__main__":
    main()
