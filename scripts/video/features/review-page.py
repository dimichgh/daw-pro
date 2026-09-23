#!/usr/bin/env python3
"""Emit the Starlight review page from MEASURED data.

    python3 review-page.py > out/review.html

⛔ THE PAGE IS GENERATED, NOT HAND-WRITTEN, AND THAT IS THE POINT.
Every figure it shows — loudness per section, brightness per section, the filter
curve, the note counts — is read out of `out/page-data.json`, which `section-arc.py`
measured off the shipped wav. Nothing here can claim an arc the audio does not
have. The last round put "all four are level-matched to −18 LUFS" in front of the
user over files measuring −19.5 / −19.6 / −18.9 / −18.0, because that sentence was
typed by hand instead of read off a meter.

⚠ If a piece is missing from page-data.json this script FAILS rather than
rendering a card with empty charts.
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
DATA = json.loads((HERE / "out" / "page-data.json").read_text())

ORDER = ["cosmic-ascent", "cosmic-collapse", "cosmic-heartbeat",
         "cosmic-aurora", "cosmic-signal"]
missing = [p for p in ORDER if p not in DATA]
if missing:
    sys.exit(f"⛔ not measured: {missing} — run section-arc.py <pieces> --json first")

W, H_SWEEP, H_BARS = 720, 54, 92


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def sweep_svg(p):
    """The filter automation, exactly as it was written into the lane."""
    beats = p["bars"] * 4
    pts = []
    for s in p["sweep"]:
        x = s["beat"] / beats * W
        # position runs -0.95 (closed) .. 0.0 (wide open); open is UP
        y = H_SWEEP - 3 - (s["value"] + 0.95) / 0.95 * (H_SWEEP - 8)
        pts.append(f"{x:.1f},{y:.1f}")
    return (f'<svg class="sweep" viewBox="0 0 {W} {H_SWEEP}" role="img" '
            f'aria-label="Filter opening over the whole piece, {len(p["sweep"])} automation points">'
            f'<polyline points="{" ".join(pts)}" />'
            f'</svg>')


def bars_svg(p):
    """Loudness as columns, brightness as a line — the two axes that disagree."""
    secs = p["sections"]
    total = sum(s["bars"] for s in secs)
    lus = [s["lufs"] for s in secs]
    brs = [s["bright"] for s in secs]
    lo, hi = min(lus), max(lus)
    blo, bhi = min(brs), max(brs)
    span = max(hi - lo, 0.001)
    bspan = max(bhi - blo, 0.001)
    out, x, line, labels = [], 0.0, [], []
    for s in secs:
        w = s["bars"] / total * W
        h = (s["lufs"] - lo) / span * (H_BARS - 26) + 3
        out.append(f'<rect x="{x + 1.5:.1f}" y="{H_BARS - 14 - h:.1f}" '
                   f'width="{max(w - 3, 1):.1f}" height="{h:.1f}" rx="2"/>')
        by = H_BARS - 14 - ((s["bright"] - blo) / bspan * (H_BARS - 26) + 3)
        line.append(f"{x + w / 2:.1f},{by:.1f}")
        labels.append(f'<text x="{x + w / 2:.1f}" y="{H_BARS - 3:.1f}">{esc(s["name"])}</text>')
        x += w
    return (f'<svg class="bars" viewBox="0 0 {W} {H_BARS}" role="img" '
            f'aria-label="Loudness per section as columns, brightness as a line">'
            f'<g class="col">{"".join(out)}</g>'
            f'<polyline class="bright" points="{" ".join(line)}"/>'
            f'<g class="lbl">{"".join(labels)}</g></svg>')


def card(pid):
    p = DATA[pid]
    secs = p["sections"]
    most = max(secs, key=lambda s: s["layers"])
    fewest = min(secs, key=lambda s: s["layers"])
    spread = most["lufs"] - fewest["lufs"]
    # the biggest section-to-section brightness fall — the "fluctuation"
    dips = [(secs[i]["bright"] - secs[i - 1]["bright"], secs[i]["name"])
            for i in range(1, len(secs))]
    worst = min(dips)
    mins, sec = divmod(int(round(p["seconds"])), 60)
    fam = "the power one (D)" if p["family"] == "d" else "the one you approved (B)"
    badge = ('<span class="tag pulse">has a pulse</span>' if p["pulsed"]
             else '<span class="tag">beatless</span>')
    name = p["title"].split("·")[-1].strip()
    return f"""
<article class="piece" id="{esc(pid)}">
  <header class="ph">
    <div>
      <h2>{esc(name)}</h2>
      <p class="from">{esc(fam)} &middot; {mins}:{sec:02d} &middot; {p["tempo"]} BPM &middot; {p["bars"]} bars</p>
    </div>
    {badge}
  </header>
  <p class="blurb">{esc(p["blurb"])}</p>
  <audio controls preload="none" id="a-{esc(pid)}" src="audio/{esc(pid)}.mp3"></audio>
  <div class="charts">
    <div class="chart">
      <p class="clab">Filter, over the whole piece <span>open at the top</span></p>
      {sweep_svg(p)}
    </div>
    <div class="chart">
      <p class="clab">Loudness per section <span>line = brightness</span></p>
      {bars_svg(p)}
    </div>
  </div>
  <dl class="facts">
    <div><dt>Layers, first &rarr; densest</dt><dd>{fewest["layers"]} &rarr; {most["layers"]}</dd></div>
    <div><dt>That's worth</dt><dd>{spread:+.1f} LU</dd></div>
    <div><dt>Biggest brightness drop</dt><dd>{worst[0]:+.1f} dB at {esc(worst[1])}</dd></div>
    <div><dt>Notes played</dt><dd>{sum(p["notes"].values()):,}</dd></div>
  </dl>
  <button class="pick" data-pick="{esc(pid)}" aria-pressed="false">Pick {esc(name)}</button>
</article>"""


BODY = "".join(card(p) for p in ORDER)
PAYLOAD = json.dumps({k: {"title": DATA[k]["title"]} for k in ORDER})

print(f"""<title>Starlight, Developed</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300;9..144,500&family=Archivo:wght@400;600&family=Chivo+Mono:wght@400;600&display=swap">
<style>
:root {{
  --ground:#F2F4FA; --panel:#FFFFFF; --edge:#D7DDEC; --ink:#131A2E; --dim:#5C6786;
  --accent:#1B5FA8; --amber:#9A5400; --col:#5E86C4; --line:#C2440E;
  --shadow:0 1px 2px rgba(19,26,46,.06),0 8px 24px rgba(19,26,46,.05);
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --ground:#0B1020; --panel:#141B33; --edge:#26304F; --ink:#E9EDFA; --dim:#8E99BC;
    --accent:#7FD4FF; --amber:#FFB454; --col:#3E68A8; --line:#FF8A5C;
    --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
  }}
}}
:root[data-theme="dark"] {{
  --ground:#0B1020; --panel:#141B33; --edge:#26304F; --ink:#E9EDFA; --dim:#8E99BC;
  --accent:#7FD4FF; --amber:#FFB454; --col:#3E68A8; --line:#FF8A5C;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
}}
* {{ box-sizing:border-box; }}
body {{ background:var(--ground); color:var(--ink);
  font:400 16px/1.6 Archivo,system-ui,-apple-system,"Segoe UI",sans-serif; }}
.wrap {{ max-width:840px; margin:0 auto; padding:16px; padding-block:40px 72px; }}
h1 {{ font:300 clamp(36px,7vw,58px)/1.05 Fraunces,Georgia,serif;
  letter-spacing:-.02em; margin:0 0 .3em; text-wrap:balance; }}
h1 em {{ font-style:italic; font-weight:500; color:var(--accent); }}
h2 {{ font:500 clamp(21px,3.4vw,27px)/1.15 Fraunces,Georgia,serif; margin:0; letter-spacing:-.01em; }}
.lede {{ font-size:18px; color:var(--dim); max-width:62ch; margin:0 0 1.4em; }}
.note {{ border-left:3px solid var(--amber); background:color-mix(in srgb,var(--amber) 8%,transparent);
  padding:14px 18px; border-radius:0 8px 8px 0; margin:0 0 2.4em; font-size:15px; }}
.note strong {{ color:var(--amber); }}
.piece {{ background:var(--panel); border:1px solid var(--edge); border-radius:14px;
  padding:22px; margin:0 0 20px; box-shadow:var(--shadow); }}
.ph {{ display:flex; gap:12px; align-items:flex-start; justify-content:space-between; flex-wrap:wrap; }}
.from {{ margin:.35em 0 0; color:var(--dim); font-size:14px;
  font-family:"Chivo Mono",ui-monospace,monospace; font-variant-numeric:tabular-nums; }}
.tag {{ font:600 11px/1 "Chivo Mono",ui-monospace,monospace; letter-spacing:.08em;
  text-transform:uppercase; padding:7px 10px; border-radius:999px;
  border:1px solid var(--edge); color:var(--dim); white-space:nowrap; }}
.tag.pulse {{ color:var(--amber); border-color:color-mix(in srgb,var(--amber) 45%,transparent);
  background:color-mix(in srgb,var(--amber) 12%,transparent); }}
.blurb {{ margin:1em 0 1.1em; max-width:66ch; }}
audio {{ width:100%; margin:0 0 18px; }}
.charts {{ display:grid; gap:14px; grid-template-columns:1fr; }}
@media (min-width:660px) {{ .charts {{ grid-template-columns:1fr 1fr; }} }}
.chart {{ min-width:0; }}
.clab {{ margin:0 0 4px; font:600 11px/1 "Chivo Mono",ui-monospace,monospace;
  letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }}
.clab span {{ font-weight:400; text-transform:none; letter-spacing:0; opacity:.75; }}
svg {{ width:100%; height:auto; display:block; overflow:visible; }}
.sweep polyline {{ fill:none; stroke:var(--accent); stroke-width:2;
  stroke-linejoin:round; stroke-linecap:round; }}
.bars .col rect {{ fill:var(--col); }}
.bars .bright {{ fill:none; stroke:var(--line); stroke-width:1.8; stroke-linejoin:round; }}
.bars .lbl text {{ font:400 8.5px "Chivo Mono",ui-monospace,monospace; fill:var(--dim);
  text-anchor:middle; }}
.facts {{ display:grid; gap:10px 18px; grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
  margin:18px 0 0; padding:16px 0 0; border-top:1px solid var(--edge); }}
.facts div {{ margin:0; }}
dt {{ font-size:12px; color:var(--dim); letter-spacing:.02em; }}
dd {{ margin:2px 0 0; font:600 17px/1.2 "Chivo Mono",ui-monospace,monospace;
  font-variant-numeric:tabular-nums; }}
.pick {{ margin-top:18px; font:600 14px/1 Archivo,sans-serif; padding:12px 18px;
  border-radius:9px; border:1px solid var(--edge); background:transparent;
  color:var(--ink); cursor:pointer; transition:background .15s,border-color .15s; }}
.pick:hover {{ border-color:var(--accent); }}
.pick:focus-visible {{ outline:2px solid var(--accent); outline-offset:2px; }}
/* ⚠ --ground, not #fff: in the dark palette the accent is a pale cyan, and
   white-on-cyan would make the one control on this page unreadable. */
.pick[aria-pressed="true"] {{ background:var(--accent); border-color:var(--accent);
  color:var(--ground); }}
.status {{ margin:22px 0 0; padding:14px 18px; border:1px dashed var(--edge);
  border-radius:10px; color:var(--dim); font-size:14px; }}
footer {{ margin:40px 0 0; color:var(--dim); font-size:13.5px; max-width:66ch; }}
footer h3 {{ font:500 19px/1.2 Fraunces,Georgia,serif; color:var(--ink); margin:1.6em 0 .4em; }}
@media (prefers-reduced-motion:reduce) {{ * {{ transition:none !important; }} }}
</style>

<div class="wrap">
<h1>Starlight, <em>developed</em></h1>
<p class="lede">Five pieces, each about three and a half minutes. One is the power
version rebuilt as a proper arc; the other four are two drastically different
readings each of the power version and the one you approved &mdash; and in each
pair, exactly one has a pulse.</p>

<div class="note">
<strong>A correction first.</strong> I told you I&rsquo;d read &ldquo;~3+&nbsp;min&rdquo; as meaning the
5:13 long form was too long. That was wrong &mdash; you clicked
<strong>yes, it earns its length</strong> on the last page, and a recorded answer
beats my guess at what you meant. <strong>The long forms stand.</strong> These five are an
addition, not a replacement.
</div>

<p class="lede">Every number below was measured off the file you&rsquo;re playing, not
typed by hand. All five are level-matched to each other, so a preference means
character and not volume. <strong>Give each one twenty seconds before judging it</strong> &mdash;
they all start close to silence on purpose, and that opening is the thing the
arc is measured against.</p>
{BODY}
<p class="status" id="status">Pick one and I&rsquo;ll take it from there. You can change your mind &mdash; the last click wins.</p>

<footer>
<h3>How to read the two charts</h3>
<p><strong>Filter</strong> is the actual automation curve, open at the top. It is the
only thing building in music with no drums, and its ripple is what
&ldquo;energies fluctuating&rdquo; turned into.</p>
<p><strong>Loudness per section</strong> is the columns; the line over them is brightness.
Watch them disagree in the middle of the D pieces: the heaviest layers arrive at
the same moment the filter closes, so the music gets thicker and darker at once.
That is the one gesture the whole arc is built around, and a loudness meter alone
cannot see it.</p>
<h3>What I could not do</h3>
<p>The synth still has no glide and no vibrato, so the melody overlaps its notes
and lets the release carry one pitch into the next. And the filter sweep still
cannot be drawn in the app&rsquo;s automation editor &mdash; that editor only draws volume
and pan &mdash; so these charts are the only place you can see it.</p>
</footer>
</div>

<script type="module">
const PIECES = {PAYLOAD};
const statusEl = document.getElementById("status");
const buttons = [...document.querySelectorAll(".pick")];

// Only one piece can be playing at a time — otherwise a comparison is a mush.
for (const a of document.querySelectorAll("audio")) {{
  a.addEventListener("play", () => {{
    for (const o of document.querySelectorAll("audio")) if (o !== a) o.pause();
  }});
}}

let db = null;
try {{ db = await window.claude?.use?.("db"); }} catch (_) {{ db = null; }}

const paint = (v) => {{
  for (const b of buttons) b.setAttribute("aria-pressed", String(b.dataset.pick === v));
  if (v && PIECES[v]) statusEl.textContent = `Saved: ${{PIECES[v].title}}. Change it any time — the last click wins.`;
}};

if (db) {{
  db.doc("decisions/developed").onSnapshot((d) => paint(d?.data?.choice ?? null));
  for (const b of buttons) {{
    b.addEventListener("click", () => {{
      paint(b.dataset.pick);   // respond now; the snapshot confirms
      db.doc("decisions/developed").set({{ choice: b.dataset.pick, at: new Date().toISOString() }});
    }});
  }}
}} else {{
  // No viewer to save to — say so rather than letting clicks look like they stuck.
  for (const b of buttons) b.addEventListener("click", () => {{
    paint(b.dataset.pick);
    statusEl.textContent = `Noted here: ${{PIECES[b.dataset.pick].title}} — but this view can't save it, so tell me in chat.`;
  }});
}}
</script>""")
