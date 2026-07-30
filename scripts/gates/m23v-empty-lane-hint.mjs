// m23-v GATE — the empty-instrument-lane hint, against a REAL app on staging
// (port 17695 ONLY; 17600 is the user's LIVE app and is never touched; staging
// is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT EACH CLASS OF LEG PROVES — and why BOTH classes are required
//
//   E-legs (the `debug.arrangePointer` echo) prove the RULE in the running app:
//   which lanes claim a hint, that a clip silences it and removing that clip
//   brings it back, that audio/bus lanes never claim one, and that the words on
//   the lane are the pinned string. They CANNOT prove anything is drawn.
//
//   P-legs (`debug.captureUI` + the m23-g1 box probe) prove the PIXELS: that the
//   ink exists, that it is brighter than the lane it sits on (dim, but actually
//   visible), and that it VANISHES when the lane gains a clip. m23-m3b measured
//   why this split is mandatory — a mutant that broke a `DAWApp`-only binding
//   left the entire Swift suite green at 3979 tests / 405 suites, because no test
//   target reaches that module. A green DAWAppKitTests run plus a green echo is
//   NOT evidence the feature exists.
//
// THE MEASUREMENT, computed before any assertion was written (the m23-c2 law):
//   ppb 16 (default), rowStep large -> rowHeight 50, laneSpacing 6, `.lanes`
//   content so rulerInset = 0 and laneTop(i) = i * 56:
//     lane 0  Lead   (instrument, empty)  laneTop   0   -> HINT
//     lane 1  Vox    (audio,      empty)  laneTop  56   -> never
//     lane 2  Reverb (bus,        empty)  laneTop 112   -> never
//     lane 3  Pad    (instrument, empty)  laneTop 168   -> HINT
//   The hint's label is 11 pt SF Pro at content x = 10, its frame top at
//   laneTop + (50 - 11)/2 - 2 = laneTop + 17.5, so glyphs occupy roughly
//   y in [laneTop+17.5, laneTop+30.5] and x in [10, ~156].
//
// THE COORDINATE SPACE IS MEASURED FROM THE IMAGE, NOT ASSUMED — and the first
// run of this gate is why. `debug.explainFrames` gives the `arrangePlayhead`
// frame, whose X is exactly content x = 0 (verified: the label's first glyph
// lands 10 pt in, its designed inset) but whose Y sits ~34.5 pt ABOVE the lanes'
// content origin IN THE CAPTURE'S PIXEL SPACE. The two debug seams do not share
// an origin: `debug.captureUI` rasterizes `contentView.bounds`
// (`DAWProApp.swift:7373-7380`), while `.explainable` reports
// `geo.frame(in: .named(ExplainCoordinateSpace.name))` (`Explain.swift:172`) and
// that space is declared further IN, at `ContentView.swift:220`. Filed as m23-ag.
// ⚠️ Do NOT "explain" the offset with `.offset(y: rulerInset)`
// (`TimelineLanesView.swift:1446-1447`): this gate drives `.lanes` content, where
// `rulerInset == 0` (`:378`), so that cannot be the cause — an earlier revision of
// this header asserted it and was wrong. Four boxes placed off that y measured the
// RULER and never moved when the hint was suppressed: a false negative that looked
// like "the hint is not drawn".
//
// So the Y is DERIVED, in two steps, and never assumed:
//
//   STEP 1 — LOCATE, by differencing ONE window across TWO FRAMES (P5). The gate
//   captures the resting state, adds a clip at beat 200 (x = 3200 pt, far outside
//   the 1152 pt lanes viewport), captures again, and subtracts the two row
//   profiles of the SAME x window. Every static pixel cancels because it is
//   literally the same pixel — the ruler's bar numbers included, which is what
//   forced this design: a same-frame comparison reads those numbers as ink (they
//   genuinely differ between two x windows) and reported three spurious bands.
//   Exactly ONE band may survive, and it is the hint. This is simultaneously the
//   is-it-drawn proof and the does-it-go-away proof.
//
//   STEP 2 — MEASURE, same-frame, over rows the located origin resolves to a lane
//   band (P8/P10/P15):
//     * LABEL window   x in [4, 180)   — contains the whole label
//     * CONTROL window x in [196, 372) — the same lane, past the label
//   Both start at x ≡ 4 (mod 64), so each spans exactly the same 2 bar lines and
//   11 beat hairlines; subtracting them ROW BY ROW cancels the grid AND any
//   per-lane background shading. What is left is INK. That is the m23-p2 law: a
//   comparison control must be structurally identical or you measure the
//   structure. Sweeping lane by lane then states the whole rule in pixels —
//   instrument lanes inked, audio and bus lanes not.
//
//   Expected signal, computed not discovered: `textFaint` is #767E90 (Rec.601
//   luma 125.7) over a lane background near luma 13, so ~112 per fully-inked
//   pixel. Across a glyph row the label covers on the order of a quarter of the
//   176 pt window, so the per-row delta peaks around 25-30 (MEASURED: 42.6).
//   RUN_THRESH is 3.0 (above any antialiasing residue, far below the
//   expectation) and the peak must clear PEAK_MIN 12 — so a HALVED-opacity label
//   still passes while a deleted, zero-opacity or background-coloured one fails
//   hard.
//
// Usage:
//   swiftc -O -o /tmp/m23v-probe scripts/probes/m23g1-clip-box-probe.swift
//   M23V_PROBE=/tmp/m23v-probe M23V_OUT=/tmp/m23v \
//     node scripts/gates/m23v-empty-lane-hint.mjs
// Env: M23V_SKIP_BUILD=1 to reuse .build/debug/DAWApp (only safe when you just
// built it — A-GATE-THAT-LAUNCHES-A-PREBUILT-BINARY-TESTS-THE-PREVIOUS-BUILD).
import fs from "fs";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23v";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23V_OUT || "/tmp/m23v";
const PIDFILE = process.env.M23V_PIDFILE || "/tmp/m23v-staging.pid";
const BINARY = process.env.M23V_BINARY || ".build/debug/DAWApp";
const PROBE = process.env.M23V_PROBE || "/tmp/m23v-probe";
const REPO = process.env.M23V_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 900_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const COPY = "Double-click to add a clip";     // pinned literal, NOT read from source
const PPB = 16;
const ROW_H = 50;                              // rowStep "large"
const LANE_SPACING = 6;
const LANE_PITCH = ROW_H + LANE_SPACING;       // 56 pt from one clip lane to the next
const WIN_W = 1400, WIN_H = 1000;
// The two x windows the row profile differences (CONTENT points). Equal width,
// both at x ≡ 4 (mod 64), so the grid cancels row by row.
const LABEL_X = 4, CTRL_X = 196, WIN_PT = 176;
// The profile's vertical sweep, in content points below the reported explain
// frame's y. Generous on both sides because that y is NOT the content origin —
// see the header. It must contain all four lanes at any plausible offset.
const SWEEP_Y0 = -8, SWEEP_H = 320;
const RUN_THRESH = 3.0;                        // per-row delta that counts as ink
const PEAK_MIN = 12.0;                         // dim, but unmistakably present
const RUN_MIN_PX = 8, RUN_MAX_PX = 44;         // an 11 pt glyph band at 1x or 2x
const SETTLE_MS = 450;

// ── build, so the gate cannot test the previous build ─────────────────────
// The lifecycle (build / launch / pidfile-exact kill) lives in `_staging.mjs`
// (m23-ac-1). This gate keeps its OWN `connect()`: that is its request
// plumbing (`{ws, req}`), not part of the lifecycle.
buildOrAbort({ root: REPO, skip: !!process.env.M23V_SKIP_BUILD });
if (!fs.existsSync(PROBE)) {
  console.log("compiling the box probe…");
  execFileSync("swiftc", ["-O", "-o", PROBE, "scripts/probes/m23g1-clip-box-probe.swift"],
               { cwd: REPO, stdio: "inherit" });
}

// ── launch staging (pidfile-EXACT teardown of any previous run) ───────────
const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4000);

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const pointer = () => req("debug.arrangePointer", {});
const hintsOf = (e) => e.emptyLaneHints ?? [];
const idsOf = (e) => hintsOf(e).map((h) => h.trackId);

/// Waits (bounded) for the lanes to RE-REPORT after a store change, using the
/// seam's own render counter instead of sleeping and hoping.
async function awaitHintRender(seqBefore, ms = 3000) {
  const deadline = Date.now() + ms;
  let e = await pointer();
  while (e.emptyLaneHintSeq === seqBefore && Date.now() < deadline) {
    await sleep(50);
    e = await pointer();
  }
  return e;
}

let capSeq = 0;
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, width: r.width, height: r.height };
}

/// A STABLE capture: two consecutive byte-identical frames. The window is not
/// perfectly static (meters redraw), and m23-g3 measured that a single unlucky
/// pair can make a pixel leg meaningless. A gate that cannot stabilise FAILS —
/// it never skips.
async function stableCapture(tag) {
  let prev = await capture(tag);
  let prevSha = shaOf(prev.path);
  for (let i = 0; i < 10; i++) {
    await sleep(150);
    const next = await capture(tag);
    const sha = shaOf(next.path);
    if (sha === prevSha) return next;
    prev = next; prevSha = sha;
  }
  return null;
}
function shaOf(p) {
  return execFileSync("/usr/bin/shasum", ["-a", "256", p]).toString().split(" ")[0];
}

/// Per-row mean luma over an x window, through the m23-g1 probe's `rows` mode —
/// the lane-band finder that mode exists for. Returns a Map of capture-row -> luma.
/// The probe DIES on an out-of-bounds window, so a silently-failed sweep (the
/// m23-c1 false-negative mode) is impossible.
function rowProfile(png, x, w, y0, h) {
  const raw = execFileSync(PROBE, ["rows", png, String(x), String(w), String(y0), String(h)])
    .toString().trim().split("\n");
  const out = new Map();
  for (const line of raw) {
    const [y, luma] = line.split(" ");
    out.set(Number(y), Number(luma));
  }
  if (out.size !== h) throw new Error(`row profile returned ${out.size} rows, expected ${h}`);
  return out;
}

/// The label window's own profile — used for the ACROSS-FRAME difference.
function labelProfile(png, originX, scale, y0, h) {
  return rowProfile(png, Math.round((originX + LABEL_X) * scale), WIN_PT * scale, y0, h);
}

/// Difference of the same window between TWO frames. Everything static — the
/// ruler's bar numbers, the beat grid, the lane tones, the panel chrome —
/// cancels exactly, because it is literally the same pixels. What is left is
/// what CHANGED, which is the whole locating trick: the hint is the only thing
/// this gate changes between the two frames it compares.
function frameDelta(pngA, pngB, originX, scale, y0, h) {
  const a = labelProfile(pngA, originX, scale, y0, h);
  const b = labelProfile(pngB, originX, scale, y0, h);
  const delta = [];
  for (const [y, v] of a) delta.push({ y, d: v - (b.get(y) ?? 0) });
  delta.sort((x, y) => x.y - y.y);
  return delta;
}

/// The SAME-FRAME ink profile: label window minus control window, row by row.
/// Anything the two windows share — the beat/bar grid, the lane's own background
/// tone, the panel gradient — subtracts out; what survives is the label's ink.
/// Used only over rows the locating step has already resolved to a lane band,
/// never over the ruler (whose bar numbers legitimately differ between the two
/// x windows and would read as ink).
function inkProfile(png, originX, scale, y0, h) {
  const label = labelProfile(png, originX, scale, y0, h);
  const ctrl = rowProfile(png, Math.round((originX + CTRL_X) * scale), WIN_PT * scale, y0, h);
  const delta = [];
  for (const [y, v] of label) delta.push({ y, d: v - (ctrl.get(y) ?? 0) });
  delta.sort((x, y) => x.y - y.y);
  return delta;
}

/// Peak same-frame ink over ONE lane's glyph band. The band is
/// [laneTop + 8, laneTop + 40) — inside the 50 pt row, straddling the label's
/// designed [17.5, 30.5].
function laneInkPeak(png, originX, scale, inkOriginY, lane) {
  const y0 = inkOriginY + Math.round((lane * LANE_PITCH + 8) * scale);
  const d = inkProfile(png, originX, scale, y0, Math.round(32 * scale));
  return Math.max(...d.map((r) => r.d));
}

/// Contiguous runs of rows whose ink delta clears the threshold, with each run's
/// peak. One run per drawn label.
function inkRuns(delta) {
  const runs = [];
  let cur = null;
  for (const { y, d } of delta) {
    if (d > RUN_THRESH) {
      if (!cur) cur = { top: y, bottom: y, peak: d };
      else { cur.bottom = y; cur.peak = Math.max(cur.peak, d); }
    } else if (cur) { runs.push(cur); cur = null; }
  }
  if (cur) runs.push(cur);
  return runs.map((r) => ({ ...r, height: r.bottom - r.top + 1 }));
}

/// Box measurement through the same probe (mean RGB + Rec.601 luma + a sha, with
/// a HARD dims assertion inside the probe). Used only once the row profile has
/// LOCATED the ink, so no box is ever placed on an assumed coordinate.
function boxes(png, specs) {
  const args = ["boxes", png, OUT, ...specs.map((s) => `${s.label}:${s.x},${s.y},${s.w},${s.h}`)];
  const raw = execFileSync(PROBE, args).toString().trim().split("\n");
  const out = {};
  for (const line of raw) {
    const m = line.match(/^(\S+) dims=(\d+)x(\d+) mean=([\d.,]+) luma=([\d.]+) sha=(\w+)$/);
    if (!m) throw new Error(`unparsed probe line: ${line}`);
    out[m[1]] = { dims: `${m[2]}x${m[3]}`, w: +m[2], h: +m[3], luma: +m[5], sha: m[6] };
  }
  return out;
}

try {
  // ══ FIXTURE ════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: WIN_W, height: WIN_H });
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  const lead = (await req("track.add", { kind: "instrument", name: "Lead" })).id;
  const vox = (await req("track.add", { kind: "audio", name: "Vox" })).id;
  const bus = (await req("track.add", { kind: "bus", name: "Reverb" })).id;
  const pad = (await req("track.add", { kind: "instrument", name: "Pad" })).id;
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("transport.seek", { beats: 40 });   // playhead x = 640, outside every box
  await req("debug.arrangePointer", { act: "clear" });   // no ghost line in the boxes
  await sleep(SETTLE_MS);

  // PRECONDITIONS — without these the whole gate can pass vacuously.
  const layout = await req("debug.panelLayout", {});
  check(`fixture: ppb ${PPB} and rowHeight ${ROW_H} — the box arithmetic's assumptions`,
        near(zoom.ppb, PPB) && near(layout.rowHeight, ROW_H),
        `ppb=${zoom.ppb} rowHeight=${layout.rowHeight}`);
  const ov0 = await req("project.overview", {});
  check("fixture: four empty tracks in ladder order instrument/audio/bus/instrument",
        ov0.tracks.length === 4
        && ov0.tracks.every((t) => t.clips.length === 0)
        && ov0.tracks.map((t) => t.id).join() === [lead, vox, bus, pad].join(),
        `tracks=${ov0.tracks.length} clips=${ov0.tracks.map((t) => t.clips.length).join()}`);

  // ══ E  THE RULE, IN THE RUNNING APP ════════════════════════════════════
  let e = await pointer();
  check("E1 a bare seam read answers — the hint is resting state, not pointer state "
        + "(no hover was ever staged)",
        Array.isArray(e.emptyLaneHints) && typeof e.emptyLaneHintSeq === "number",
        `hints=${JSON.stringify(hintsOf(e))} seq=${e.emptyLaneHintSeq}`);
  check("E2 both EMPTY INSTRUMENT lanes claim a hint",
        idsOf(e).length === 2 && idsOf(e).includes(lead) && idsOf(e).includes(pad),
        `ids=${JSON.stringify(idsOf(e))} lead=${lead} pad=${pad}`);
  check("E3 the AUDIO and BUS lanes never do — that is where the double-click "
        + "legitimately refuses",
        !idsOf(e).includes(vox) && !idsOf(e).includes(bus),
        `ids=${JSON.stringify(idsOf(e))} vox=${vox} bus=${bus}`);
  check("E4 the reported laneIndex is the LADDER row, not the hint's own position",
        hintsOf(e).map((h) => h.laneIndex).join() === "0,3",
        `laneIndex=${hintsOf(e).map((h) => h.laneIndex).join()}`);
  check("E5 the words on the lane are the pinned copy, verbatim",
        hintsOf(e).every((h) => h.text === COPY),
        `text=${JSON.stringify(hintsOf(e).map((h) => h.text))} expected=${JSON.stringify(COPY)}`);

  // ══ P  THE PIXELS ══════════════════════════════════════════════════════
  // The explain frame supplies the X origin ONLY (verified below by where the
  // ink actually lands); the Y is derived from the ink. Frames flow only while
  // explain mode is on, so it is turned on to read and OFF before every capture
  // — explain chrome must never be in frame.
  await req("debug.explainMode", { on: true });
  await sleep(SETTLE_MS);
  const ef = await req("debug.explainFrames", { ids: ["arrangePlayhead"] });
  await req("debug.explainMode", { on: false });
  await sleep(SETTLE_MS);
  const rects = ef.frames?.arrangePlayhead ?? [];
  check("P0 exactly ONE arrangePlayhead instance is in the tree (the pinned .ruler "
        + "block carries no pointer layer) — so its frame is unambiguously the lanes'",
        ef.explainActive === true && rects.length === 1,
        `explainActive=${ef.explainActive} instances=${rects.length} rect=${JSON.stringify(rects[0])}`);
  const origin = rects[0] ?? { x: 0, y: 0 };

  const shot0 = await stableCapture("A-hint");
  check("P1 a stable resting image could be established — without one no pixel "
        + "claim below can be trusted (m23-g3: a skip here is NOT a pass)",
        shot0 !== null,
        shot0 ? `${shot0.width}x${shot0.height} ${shot0.path}` : "10 consecutive pairs all differed");
  if (!shot0) throw new Error("no stable capture");
  const scale = Math.round(shot0.height / WIN_H);
  check("P2 the capture scale is a sane backing factor, derived from the frame "
        + "rather than assumed",
        scale === 1 || scale === 2,
        `capture ${shot0.width}x${shot0.height} vs window ${WIN_W}x${WIN_H} -> scale ${scale}`);

  const sweepY = Math.round((origin.y + SWEEP_Y0) * scale);
  const sweepH = SWEEP_H * scale;
  const fmt = (rs) => rs.map((r) => `[${r.top}..${r.bottom} h${r.height} peak ${r.peak.toFixed(1)}]`).join(" ");

  // ══ SUPPRESSION — the second frame, which is also the LOCATOR ══════════
  // The clip lands at beat 200 (x = 3200 pt), far outside the ~1150 pt lanes
  // viewport and outside every measurement window, so the ONLY thing that can
  // differ between this frame and the last is lane 0's hint.
  const seqBefore = (await pointer()).emptyLaneHintSeq;
  const clip = await req("clip.addMIDI", { trackId: lead, atBeat: 200, lengthBeats: 4 });
  const clipId = clip.id ?? clip.clip?.id;
  e = await awaitHintRender(seqBefore);
  check("E6 a clip anywhere on the lane silences that lane's hint — and ONLY that "
        + "lane's (the seam re-reported; this was not polled blind)",
        e.emptyLaneHintSeq !== seqBefore
        && idsOf(e).length === 1 && idsOf(e)[0] === pad,
        `seq ${seqBefore} -> ${e.emptyLaneHintSeq} ids=${JSON.stringify(idsOf(e))}`);
  check("P3 the clip really is off-screen, so every pixel difference below is the "
        + "HINT leaving and not a clip block arriving",
        200 * PPB > origin.width, `clip x = ${200 * PPB} pt vs lanes viewport ${origin.width} pt`);

  await sleep(SETTLE_MS);
  const shot1 = await stableCapture("B-silenced");
  check("P4 a stable image could be established for the silenced state", shot1 !== null,
        shot1 ? shot1.path : "no stable pair");
  if (!shot1) throw new Error("no stable capture (silenced)");

  // THE LOCATOR, and the strongest single leg in this gate: difference the SAME
  // window between the two frames. Every static pixel — the ruler's bar numbers,
  // the grid, the lane tones — cancels because it is literally identical, so a
  // surviving band can only be something that changed. Exactly one must.
  const changed = inkRuns(frameDelta(shot0.path, shot1.path, origin.x, scale, sweepY, sweepH));
  check("P5 THE HINT IS DRAWN, AND IT IS WHAT LEAVES: differencing the two frames "
        + "leaves exactly ONE band of pixels — a build that draws nothing has nothing "
        + "to lose here and leaves zero",
        changed.length === 1,
        `bands=${changed.length} ${fmt(changed)} (threshold ${RUN_THRESH})`);
  check("P6 …it is one text line tall, not a fill, a border, or a whole-lane repaint",
        changed.length === 1
        && changed[0].height >= RUN_MIN_PX * scale / 2
        && changed[0].height <= RUN_MAX_PX * scale / 2,
        `${fmt(changed)} allowed h ${RUN_MIN_PX * scale / 2}..${RUN_MAX_PX * scale / 2}`);
  check("P7 DIM BUT ACTUALLY VISIBLE: the ink clears the visibility floor — a "
        + "zero-opacity label, or one tinted to the lane background, cannot reach it",
        changed.length === 1 && changed[0].peak >= PEAK_MIN,
        `peak=${changed.length === 1 ? changed[0].peak.toFixed(2) : "n/a"} floor=${PEAK_MIN}`);
  if (changed.length !== 1) throw new Error("could not locate the hint's ink");

  // With the ink located, the content origin follows: the label's frame top sits
  // at laneTop(0) + 17.5 by construction. Everything below is measured against
  // THIS, never against the explain frame's y (which lands in the ruler).
  const inkOriginY = changed[0].top - Math.round(17.5 * scale);

  // Per-lane, SAME-FRAME ink over the resting (hint) image. The audio and bus
  // lanes are the controls, and they are the never-on-a-refusing-lane rule
  // proven in pixels rather than in the echo alone.
  const peaks0 = [0, 1, 2, 3].map((l) => laneInkPeak(shot0.path, origin.x, scale, inkOriginY, l));
  check("P8 the ink sits on the two INSTRUMENT lanes and on NEITHER the audio nor "
        + "the bus lane — measured lane by lane, in one frame",
        peaks0[0] >= PEAK_MIN && peaks0[3] >= PEAK_MIN
        && peaks0[1] < RUN_THRESH && peaks0[2] < RUN_THRESH,
        `lane peaks = [${peaks0.map((p) => p.toFixed(2)).join(", ")}] `
        + `(instrument >= ${PEAK_MIN}, audio/bus < ${RUN_THRESH})`);
  check("P9 the two inked lanes agree — the hint is per-lane content, not a one-off "
        + "decoration on the first row",
        Math.abs(peaks0[0] - peaks0[3]) < 2.0,
        `lane0=${peaks0[0].toFixed(2)} lane3=${peaks0[3].toFixed(2)}`);

  const peaks1 = [0, 1, 2, 3].map((l) => laneInkPeak(shot1.path, origin.x, scale, inkOriginY, l));
  check("P10 THE INK IS GONE from the lane that gained a clip — and ONLY from it",
        peaks1[0] < RUN_THRESH && peaks1[3] >= PEAK_MIN,
        `lane peaks = [${peaks1.map((p) => p.toFixed(2)).join(", ")}] (was `
        + `[${peaks0.map((p) => p.toFixed(2)).join(", ")}])`);

  // Boxes over the LOCATED labels, for byte-exact comparisons across states.
  const labelBox = (label, lane) => ({
    label,
    x: Math.round((origin.x + LABEL_X) * scale),
    y: inkOriginY + Math.round((lane * LANE_PITCH + 12) * scale),
    w: WIN_PT * scale,
    h: 24 * scale,
  });
  const SPECS = [labelBox("A-hint-lead", 0), labelBox("D-hint-pad", 3)];
  const m0 = boxes(shot0.path, SPECS);
  const m1 = boxes(shot1.path, SPECS);
  check("P11 every crop came back at the requested size — a silently-failed crop is "
        + "the known false-negative mode (m23-c1)",
        SPECS.every((s) => m0[s.label]?.dims === `${s.w}x${s.h}`),
        SPECS.map((s) => `${s.label}=${m0[s.label]?.dims}`).join(" "));
  check("P12 the OTHER instrument lane's crop is byte-identical across the two "
        + "states — the suppression is per-lane in pixels, not a global repaint",
        m1["D-hint-pad"].sha === m0["D-hint-pad"].sha,
        `D sha ${m0["D-hint-pad"].sha} -> ${m1["D-hint-pad"].sha}`);

  // ══ RESTORE — removing the clip brings it back ═════════════════════════
  const seqBefore2 = (await pointer()).emptyLaneHintSeq;
  await req("clip.remove", { clipId });
  e = await awaitHintRender(seqBefore2);
  check("E7 removing that clip brings the hint back — an empty lane is a STATE, "
        + "never a one-shot first-run flag",
        idsOf(e).length === 2 && idsOf(e).includes(lead) && idsOf(e).includes(pad),
        `ids=${JSON.stringify(idsOf(e))}`);
  await sleep(SETTLE_MS);
  const shot2 = await stableCapture("C-restored");
  check("P13 a stable image could be established for the restored state", shot2 !== null,
        shot2 ? shot2.path : "no stable pair");
  if (!shot2) throw new Error("no stable capture (restored)");
  const m2 = boxes(shot2.path, SPECS);
  check("P14 the ink RETURNS, byte-for-byte identical to before the clip existed",
        m2["A-hint-lead"].sha === m0["A-hint-lead"].sha,
        `sha ${m0["A-hint-lead"].sha} -> ${m1["A-hint-lead"].sha} -> ${m2["A-hint-lead"].sha}`);

  // ══ CONTENT-KEYED, NOT TRANSPORT-KEYED ═════════════════════════════════
  // A track added while the transport is ROLLING still has no clips and still
  // looks inert, so it still gets the hint. Stated in the design; measured here
  // so it is not discovered in review.
  await req("transport.play", {});
  await sleep(300);
  const seqBefore3 = (await pointer()).emptyLaneHintSeq;
  const live = (await req("track.add", { kind: "instrument", name: "Added While Rolling" })).id;
  e = await awaitHintRender(seqBefore3);
  const playing = await req("transport.state", {}).catch(() => ({}));
  check("E8 a track added while the TRANSPORT IS ROLLING gets the hint — the rule "
        + "reads lane content and nothing else",
        idsOf(e).includes(live),
        `ids=${JSON.stringify(idsOf(e))} live=${live} transport=${JSON.stringify(playing).slice(0, 80)}`);
  await req("transport.stop", {});
  await sleep(200);

  // ══ DENSITY — the hint is CONTENT, so both modes draw it ═══════════════
  // Simple is the beginner default and the reason this item exists; Pro is where
  // the same double-click also splits a clip. The `ClipMIDIMap` precedent:
  // content renders in both densities, only edit chrome forks.
  const seqBefore4 = (await pointer()).emptyLaneHintSeq;
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await sleep(SETTLE_MS);
  e = await pointer();
  check("E9 the hint survives PRO density (it is lane content, not edit chrome)",
        idsOf(e).includes(lead) && idsOf(e).includes(pad),
        `ids=${JSON.stringify(idsOf(e))} seqBefore=${seqBefore4} seq=${e.emptyLaneHintSeq}`);
  await sleep(SETTLE_MS);
  const shot3 = await stableCapture("D-pro");
  if (shot3) {
    // Five lanes now (E8 added one at index 4); 0, 3 and 4 are empty instrument
    // lanes and must all carry ink, 1 and 2 must still carry none.
    const peaks3 = [0, 1, 2, 3, 4].map((l) => laneInkPeak(shot3.path, origin.x, scale, inkOriginY, l));
    check("P15 …and it is DRAWN in Pro, on EVERY empty instrument lane and on no "
          + "other, not merely reported",
          peaks3[0] >= PEAK_MIN && peaks3[3] >= PEAK_MIN && peaks3[4] >= PEAK_MIN
          && peaks3[1] < RUN_THRESH && peaks3[2] < RUN_THRESH,
          `lane peaks = [${peaks3.map((p) => p.toFixed(2)).join(", ")}]`);
  } else {
    check("P15 …and it is DRAWN in Pro, not merely reported", false,
          "no stable capture in Pro — treat as unproven, not passed");
  }

  // ══ normalize ══════════════════════════════════════════════════════════
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangePointer", { act: "clear" });
  await req("project.new", { discardChanges: true });
} catch (err) {
  check("gate ran to completion", false, String(err && err.stack ? err.stack : err));
}

const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23V ${pass}/${checks.length}`);
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
try { ws.close(); } catch {}
stopStaging(GATE, PIDFILE);   // pidfile-EXACT, one home (m23-ac-1)
clearTimeout(killer);
process.exit(pass === checks.length ? 0 : 1);
