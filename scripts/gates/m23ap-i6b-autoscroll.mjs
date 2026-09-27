// m23-ap I6b GATE — AUTO-SCROLL WHILE DRAGGING in the pitch (note) editor,
// against a REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE
// app and is never touched; killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES — through the pane's own funnel
// (`PitchEditorView.dragChanged` → `applyEdgeStep` → `PitchEditorModel.edgeStep`
// → `EdgeAutoScroll.push`), reached by staged `debug.pitchEditor {act:"press"/
// "drag"/"release"}` steps (the SAME code a live pointer runs, minus the
// held-repeat clock — the debug-staging banner's own claim, verified here by
// reading `autoscroll.armed`, which must be false on every staged read):
//   • TOP WALL: a note dragged to the pane's top band (content y≈2, deep in
//     the band) GROWS `pitchWindow.high`, never scrolls it — the viewport's
//     offsetY is 0 from the very first tick (no press has scrolled yet), so
//     the top is "at the wall" immediately, growth-only, regardless of
//     whether the pane has REAL scroll room elsewhere (it usually does — see
//     the correction below);
//   • ⭐ MEASURED, not inferred: `viewport.offsetY` stays 0 across the whole
//     top-wall growth (the survey's advisor correction 3 — this line is the
//     instrument that turns "SwiftUI keeps offset.y at 0 while the top grows"
//     from an assumption into a fact);
//   • the dragged note's gap to the pointer (`autoscroll.dragRect.y` minus the
//     pointer's fixed content y) holds CONSTANT across ticks while `high`
//     climbs — not "the pointer is inside the rect": `updatePitchDrag`'s snap
//     clamp insets the landed pitch one row from the true edge
//     (`PitchEditorModel.swift:2458-2463`), so the note sits one row below a
//     pointer parked at the very top on purpose, and a CONSTANT gap is what
//     proves the top-shift correction (`topShift`, same file) is still
//     cancelling the window's growth pointer-for-pointer;
//   • BOTTOM mirror, TWO PHASES — MEASURED, corrected against a first draft
//     that assumed the pane always starts pinned to every wall (it does not:
//     see the correction below). Phase 1 SCROLLS (`pitchWindow.low` unchanged)
//     while `offsetY < contentH − viewportH`; phase 2, once the wall is
//     reached, GROWS `pitchWindow.low` down, with `viewport.offsetY` following
//     the newly grown content (`contentH − viewportH`, `FollowPlayhead
//     .maxOffset`'s own formula) to reveal the new row — the write `edgeStep`
//     makes ONLY at the bottom (`PitchEditorModel.swift`'s "the top needs no
//     write" comment);
//   • BAND (x): a press that promotes to a BAND (empty surface, travelled)
//     dragged into the right edge scrolls `viewport.offsetX` and leaves
//     `autoscroll.lastSide == "right"`, with `autoscroll.grownRows` staying 0
//     for the whole leg — bands never grow (`edgeBehaviour`'s `.band` arm is
//     `(.both, grows: false)`);
//   • CONTROL: a small drag held on the note nearest the VIEWPORT's visible
//     middle (screen-local, not content-space — with real scroll room the two
//     differ; picking by content-space alone was this gate's own first-run
//     bug, landing the "control" inside the real bottom band) changes the
//     window, both offsets and `grownRows` NOT AT ALL — the discriminating
//     negative control every other leg's claim leans on;
//   • RELEASE HEADROOM: once the top-wall drag is released, the window keeps
//     one row above the dragged note for its name
//     (`PitchEditorModel.endPitchDrag`'s widen-only headroom, advisor
//     correction 2 / I6c's measured "no B4" precedent) — `pitchWindow.high`
//     is at least the released note's `playedMidi` (the STORE's drawn centre,
//     matched by id — `notesAsDrawn` itself carries no pitch) plus 1;
//   • `autoscroll.armed` reads false on EVERY staged read (the control leg
//     for the whole gate): a staged drag can reach growth and scroll — the
//     debug-staging banner says so — but it can never arm the LIVE-ONLY
//     held-repeat clock, because the staged seam calls `dragChanged` directly
//     and never touches `liveDragChanged`'s `setEdgeRepeat` (the roll's
//     `applyGesture`-vs-`advanceGesture` precedent, carried over verbatim).
//
// ⭐ CORRECTION, MEASURED ON THE FIRST RUN OF THIS GATE (2026-09-25) AGAINST A
// DRAFT THAT ASSUMED THE SURVEY'S "17 rows in a 17-row pane" EXAMPLE IS THE
// NORMAL CASE. It is not: at the pane's DEFAULT (non-maximized) height, a
// one-octave-plus-padding fixture's FITTED window (≈21 rows) is already
// TALLER than what fits (≈13 rows), so `PitchEditorRange.filled` returns
// `fitted` UNCHANGED — the pane has ~114 pt of REAL vertical scroll room, not
// zero. Only the TOP starts "at the wall" (offsetY is 0 before any drag); the
// BOTTOM must be scrolled to first. This is what a user actually gets with an
// ordinary vocal at the default window size, so the gate keeps this regime
// rather than forcing a docked one.
//
// ⭐ SECOND CORRECTION, SAME RUN: a STAGED drag step's (x, y) is a literal
// CONTENT-space point — unlike a REAL held pointer, it does NOT track the
// scroll (`EdgeAutoScroll.tick`'s "recompute never integrate": a real hold's
// CONTENT position is `local + observedOffset`, recomputed every tick so a
// fixed SCREEN position keeps pushing at full depth all the way to a far
// wall). A staged tick that repeats the SAME fixed content y instead
// converges: as the offset grows, that content point's SCREEN position
// drifts out of the band, `depthFraction` shrinks tick over tick, and the
// scroll asymptotes just inside the band's inner edge — MEASURED at
// offsetY≈45.5 against a 114 pt wall using a fixed y. Every leg with real
// scroll room (BOTTOM, BAND-x) therefore RECOMPUTES its pointer from the
// latest echoed offset before each tick, exactly mirroring `HeldPoint`'s own
// rule; TOP does not need to (offsetY never leaves 0 there).
//
// GROWTH RATE — CONTROLLED, NOT LEFT TO THE WIRE'S OWN JITTER: the S3 lane's
// own report says a staged step's `dt` is capped at `PitchEditorModel
// .maxEdgeStepSeconds` (0.05 s) and a pointer at depth 0.958 earns about
// 0.575 rows/tick (`growthSemitonesPerSecond` × depth × dt = 12×0.958×0.05).
// An UNCONTROLLED back-to-back probe on this gate's first run measured that
// claim FALSE for "3 ticks" taken as fast as the wire allows: 0 rows grown
// after 3 (0, 323, 316 ms gaps — the first tick's dt is the press→drag gap,
// not the cap), 1 row only on a 4th. The MECHANISM is real (dt IS capped, not
// floored, and the first tick's dt is whatever the press→drag round trip
// happened to take) — so this gate now sleeps 60 ms before every tick,
// forcing every `dt` to the 0.05 s cap, and checks the growth THAT PRODUCES
// (deterministic: +1 row by tick 2, +2 by tick 4, both asserted with a tick
// of margin). The uncontrolled measurement is reported as a finding, not
// silently overwritten.
//
// grownRows ARITHMETIC — CORRECTED AGAINST THE CODE, NOT THE BRIEF'S DRAFT
// WORDING: `PitchEditorModel.swift`'s own comment says `edgeGrownRows` is
// "reset at every press's first tick", so the right comparison is
// `autoscroll.grownRows == pitchWindow.high(now) − pitchWindow.high(at this
// press's first read)` — never `high − fittedHigh` (`fitted` is the notes'
// own window, already narrower than the FILLED `laidOut` window every fresh
// press starts from, so that difference is nonzero even with no drag at all).
//
// WHAT THIS DOES NOT PROVE
//   • a REAL trackpad/mouse hold reaching `liveDragChanged`'s held-repeat
//     clock (m23-g1: nothing in this tree drives a real pointer) — the
//     `armed` checks above are the closest a staged gate gets, and they are a
//     CONTROL (always false), not a positive demonstration of the clock;
//   • the clock's own 16 ms tick / 200 ms hold timing — unit-tested only
//     (`PianoRollEdgeRepeatTests`, this feature's own borrowed clock), never
//     exercised end-to-end here.
//
// PROVENANCE — deliberately NOT the i2/i5 shape. Those gates run only
// against MAIN with a build the CALLER already made and `skipBuild:true`
// baked into `launchLook`; this gate also runs against a PLANTED WORKTREE
// (env `I6B_ROOT`), where `launchLook`'s hardcoded root cannot reach, so it
// calls `_staging.mjs`'s `buildOrAbort`/`launchStaging` directly instead of
// importing `launchLook`. On MAIN, three other lanes are saving into
// `Sources/` at the same time this runs, so an `-newer` mtime check would
// refuse a perfectly good second GREEN run on nothing but timing — that
// check is printed as INFORMATION only. The thing that actually proves two
// runs share one binary is `I6B_EXPECT_SHA`: pass the sha this run prints to
// a later run with `I6B_SKIP_BUILD=1`, and a mismatch is a hard ABORT.
//
// LOCKS ARE THE CALLER'S (same rule as i2/i5's "the staging lock is the
// CALLER's; see the w2 brief") — this file never touches
// `scratchpad/locks/*`. A heavy slot for the build, `scratchpad/locks/
// staging.lock` for the launch, and `scratchpad/locks/timing.lock` respected
// before either: all taken and released by whatever invokes this script.
//
//   I6B_ROOT=/path/to/worktree I6B_SKIP_BUILD=1 I6B_EXPECT_SHA=<sha> \
//     node scripts/gates/m23ap-i6b-autoscroll.mjs
//
// Env: I6B_ROOT (default: MAIN, `_staging.mjs`'s `ROOT`), I6B_SKIP_BUILD=1
//      (skip the build; reuses whatever binary is already at I6B_ROOT),
//      I6B_EXPECT_SHA (hard-abort unless the binary's sha256 matches),
//      I6B_OUT (captures/fixture/named project; default /tmp/m23ap-i6b),
//      I6B_EXPECT_PLANT=1 (labels the run only, for a planted build's log).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, verdict, sleep, buildOrAbort, launchStaging, stopStaging } from "./_staging.mjs";
import {
  synthesizeVocalFixture, makeCmd, waitPitchEditorReady, stagePitchEditorStep, captureLook, openTunedClip,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-i6b";
const RUN_ROOT = process.env.I6B_ROOT || ROOT;
const SKIP_BUILD = process.env.I6B_SKIP_BUILD === "1";
const OUT = process.env.I6B_OUT || "/tmp/m23ap-i6b";
mkdirSync(OUT, { recursive: true });
if (process.env.I6B_EXPECT_PLANT === "1") console.log("RUN LABEL: a PLANTED build — RED legs are the point");
console.log(`root: ${RUN_ROOT}${RUN_ROOT === ROOT ? " (MAIN)" : " (NOT main — a planted/other worktree)"}`);

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const r2 = (v) => (typeof v === "number" ? Math.round(v * 100) / 100 : v);

function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopStaging(GATE); } catch { /* best effort */ }
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// BUILD + PROVENANCE (see the header for why this differs from i2/i5's shape)
// ═══════════════════════════════════════════════════════════════════════════
const binaryPath = join(RUN_ROOT, DEFAULT_BINARY);
buildOrAbort({ root: RUN_ROOT, skip: SKIP_BUILD, label: `${SKIP_BUILD ? "build SKIPPED —" : "building"} ${RUN_ROOT} …` });
function sha256(path) {
  const r = spawnSync("shasum", ["-a", "256", path], { encoding: "utf8" });
  if (r.status !== 0) return null;
  return r.stdout.trim().split(/\s+/)[0];
}
const binarySha = sha256(binaryPath);
if (!binarySha) refuseRun(`could not sha256 ${binaryPath} (exists? built?)`);
console.log(`binary: ${binaryPath}\n  sha256 ${binarySha}`);
if (process.env.I6B_EXPECT_SHA) {
  if (binarySha !== process.env.I6B_EXPECT_SHA) {
    refuseRun(`binary sha256 ${binarySha} != I6B_EXPECT_SHA ${process.env.I6B_EXPECT_SHA} — `
      + "this is not the SAME binary as the run that sha came from");
  }
  console.log(`provenance: sha256 MATCHES I6B_EXPECT_SHA — this run and that one share one binary`);
}
{
  // INFORMATION ONLY (see header): other main-tree lanes save into Sources/
  // concurrently, so an mtime refusal here would fail a good second run on
  // nothing but timing. Still printed — it is real signal when the numbers
  // are surprising, just never a hard gate for MAIN.
  const find = (args) => spawnSync("find", args, { cwd: RUN_ROOT, encoding: "utf8" });
  const newer = find(["Sources", "Package.swift", "-newer", binaryPath, "-type", "f"]);
  const olderCtl = find(["Sources", "-type", "f", "!", "-newer", binaryPath]);
  if (newer.status === 0 && olderCtl.status === 0) {
    const newerFiles = newer.stdout.split("\n").filter(Boolean);
    const olderCount = olderCtl.stdout.split("\n").filter(Boolean).length;
    console.log(`provenance (info only): ${newerFiles.length} source file(s) newer than the binary `
      + `(positive control: ${olderCount} are not)`
      + (newerFiles.length ? ` — e.g. ${newerFiles.slice(0, 3).join(", ")}` : ""));
  }
}

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopStaging(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchStaging({ gate: GATE, root: RUN_ROOT, skipBuild: true, settleMs: 1500 });
console.log(`staging pid ${session.pid} (root ${RUN_ROOT}, binary sha256 ${binarySha})`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});

let exitCode = null;
const captures = {};
try {
  // ═══════════════════════════════════════════════════════════════════════
  // FIXTURE + SETUP — a multi-note vocal, wide enough (at ppb 64) for the
  // BAND-x leg to have real horizontal scroll room (measured in
  // `_pitch-editor-look.mjs`'s own header: 21+ s of legs at this zoom, or a
  // shorter fixture zoomed in — used here instead of a longer fixture).
  // ═══════════════════════════════════════════════════════════════════════
  const SCALE_HZ = [196, 220, 247, 262, 294, 330, 349, 392];
  const LEGS = Array.from({ length: 12 }, (_, i) => ({ hz: SCALE_HZ[i % SCALE_HZ.length], seconds: 1.4 }));
  const fixturePath = synthesizeVocalFixture(OUT, { notes: LEGS });
  const opened = await openTunedClip(cmd, { fixturePath });
  const projectPath = join(OUT, "2026-09-25 I6b Autoscroll Gate.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${opened.clipId.slice(0, 8)}, `
    + `${opened.segmentCount} stored segments`);
  await waitPitchEditorReady(cmd, { timeoutMs: 45_000, intervalMs: 300 });

  // Wait for the tuned clip's render to land (i5's precedent) — these legs
  // are about the window/viewport, not render timing, and a wait that never
  // lands says so rather than let a mid-flight render jitter the geometry.
  {
    const deadline = Date.now() + 45_000;
    let rendering = true;
    while (rendering && Date.now() < deadline) {
      const c = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
        .find((x) => x.id === opened.clipId);
      rendering = c?.stretchRendering === true;
      if (rendering) await sleep(250);
    }
    if (rendering) refuseRun("the tuned clip's render never landed within 45 s");
  }

  const P0 = 64;
  await must("debug.panelLayout", { pitchEditorPPB: P0 });
  await sleep(400);

  /** Poll until two consecutive reads agree on both offsets AND the pitch
   * window (i2's `settled` shape, generalised — MEASURED necessary on this
   * gate's first run: `pitchWindow.high` lagged one body pass behind the tick
   * that earned it, the same `.onChange(of: model.geometry)` → `reportSurface`
   * gap i5's own header calls out for the ruler's offset). Every FINAL
   * assertion in this gate reads through this, never a bare post-tick echo. */
  async function settled(label, { timeoutMs = 3000, intervalMs = 60 } = {}) {
    const t0 = Date.now();
    let prev = await echo();
    while (Date.now() - t0 < timeoutMs) {
      await sleep(intervalMs);
      const next = await echo();
      if (next.viewport.offsetX === prev.viewport.offsetX
          && next.viewport.offsetY === prev.viewport.offsetY
          && next.pitchWindow.low === prev.pitchWindow.low
          && next.pitchWindow.high === prev.pitchWindow.high) {
        return next;
      }
      prev = next;
    }
    throw new Error(`${label}: viewport/window never settled within ${timeoutMs} ms `
      + `(last x=${prev.viewport.offsetX} y=${prev.viewport.offsetY} `
      + `window=[${prev.pitchWindow.low},${prev.pitchWindow.high}])`);
  }
  /** Every leg starts from a KNOWN, reset scroll position — MEASURED
   * necessary: a leftover offset from a prior leg (e.g. BAND inheriting
   * BOTTOM's still-elevated offsetY) put an "empty" or "middle" point chosen
   * from the wrong reference frame inside a real band. */
  async function resetScroll() {
    await stagePitchEditorStep(cmd, { act: "scroll", x: 0, y: 0 });
    return settled("reset scroll");
  }
  const base = await settled("initial zoom");
  console.log(`geometry: ppb ${base.zoom.pixelsPerBeat}, rowHeight ${base.zoom.rowHeight}, `
    + `viewport ${r2(base.viewport.viewportW)}x${r2(base.viewport.viewportH)}, `
    + `content ${r2(base.viewport.contentW)}x${r2(base.viewport.contentH)}, `
    + `window [${base.pitchWindow.low}, ${base.pitchWindow.high}] (${base.pitchWindow.rows} rows), `
    + `${base.notesAsDrawn.length} notes drawn`);
  if (base.viewport.contentW <= base.viewport.viewportW) {
    refuseRun(`contentW ${r2(base.viewport.contentW)} <= viewportW ${r2(base.viewport.viewportW)} at ppb ${P0} — `
      + "the BAND-x leg needs real horizontal scroll room");
  }
  if (base.notesAsDrawn.length < 2) refuseRun(`only ${base.notesAsDrawn.length} note(s) drawn — need at least 2`);
  if (base.autoscroll.armed !== false) refuseRun(`autoscroll.armed is ${base.autoscroll.armed} before any drag — control leg broken already`);

  const rowHeight = base.zoom.rowHeight;

  /** The drawn note farthest from the SCREEN edge named — `"bottom"` (largest
   * centre y, for the TOP-WALL leg: the most travel before the pointer reaches
   * y≈2) or `"top"` (smallest centre y, for the BOTTOM-WALL leg). Starting far
   * from the target band also keeps the press well clear of the router's slop,
   * so the very first big jump reliably promotes to a note drag. */
  function extremeNote(e, farthestFromScreenEdge) {
    const withCentre = e.notesAsDrawn.map((n) => ({ ...n, cy: n.y + n.height / 2 }));
    return farthestFromScreenEdge === "bottom"
      ? withCentre.reduce((a, b) => (b.cy > a.cy ? b : a))
      : withCentre.reduce((a, b) => (b.cy < a.cy ? b : a));
  }
  // The edge band's own width (`EdgeAutoScroll.edgeBand`, capped at half the
  // viewport — never true at this pane's size) plus an 8 pt safety margin: a
  // "safe" y is clear of BOTH the top and bottom band, so nothing pushes on
  // either axis, wherever the current offsetY happens to sit.
  const BAND_W = 48, MARGIN = 8;
  const viewportH = base.viewport.viewportH;
  if (viewportH < 2 * (BAND_W + MARGIN) + 20) {
    refuseRun(`viewportH ${r2(viewportH)} leaves no safe (off-band) vertical zone at BAND_W ${BAND_W}`);
  }
  /** A CONTENT-space y that is clear of both vertical bands, GIVEN the
   * current offsetY (screen-local y = content y − offsetY must sit in
   * `[BAND_W+MARGIN, viewportH−BAND_W−MARGIN]`) — MEASURED necessary on this
   * gate's first run: a "safe" point picked from content-space alone landed
   * inside a real band whenever a prior leg had left offsetY nonzero. */
  function safeLocalRange(offsetY) { return [offsetY + BAND_W + MARGIN, offsetY + viewportH - BAND_W - MARGIN]; }
  /** An empty content point in the safe zone — clear of every drawn note by a
   * slop margin (i2/i5's `clearOf` shape) — for the BAND leg's press. */
  function emptySafePoint(e, x) {
    const [lo, hi] = safeLocalRange(e.viewport.offsetY);
    const clear = (y) => e.notesAsDrawn.every((n) =>
      x < n.x - 10 || x > n.x + n.width + 10 || y < n.y - 16 || y > n.y + n.height + 16);
    for (let y = lo; y < hi; y += 4) if (clear(y)) return y;
    return null;
  }
  /** The drawn note nearest the viewport's visible middle, screen-local (not
   * content-space — with real scroll room the two differ), and REFUSED
   * unless it sits in the safe zone: this gate's own first-run bug picked a
   * content-space "middle" that was inside the real bottom band. */
  function middleSafeNote(e) {
    const [lo, hi] = safeLocalRange(e.viewport.offsetY);
    const mid = e.viewport.offsetY + viewportH / 2;
    const candidates = e.notesAsDrawn.map((n) => ({ ...n, cy: n.y + n.height / 2 }))
      .filter((n) => n.cy >= lo && n.cy <= hi)
      .sort((a, b) => Math.abs(a.cy - mid) - Math.abs(b.cy - mid));
    return candidates[0] ?? null;
  }
  /** The dragged note's STORE record (`notes`, not `notesAsDrawn` — which
   * carries no pitch) by id, for the release-headroom check. */
  function storeNote(e, id) { return e.notes.find((n) => n.id === id) ?? null; }

  // ═══════════════════════════════════════════════════════════════════════
  // CONTROL — a small drag held on the note nearest the viewport's SAFE
  // middle (off both bands): the window, both offsets and grownRows change
  // NOT AT ALL. This is the discriminating negative control the other legs
  // lean on.
  // ═══════════════════════════════════════════════════════════════════════
  {
    const e0 = await resetScroll();
    const note = middleSafeNote(e0);
    if (!note) refuseRun("no drawn note sits in the safe (off-band) middle zone for the CONTROL leg");
    const px = note.x + note.width / 2, py = note.cy;
    const before = { low: e0.pitchWindow.low, high: e0.pitchWindow.high,
      offsetX: e0.viewport.offsetX, offsetY: e0.viewport.offsetY, grownRows: e0.autoscroll.grownRows };
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    const armedAtPress = (await echo()).autoscroll.armed;
    await stagePitchEditorStep(cmd, { act: "drag", x: px, y: py - 6 });
    const mid = await echo();
    await stagePitchEditorStep(cmd, { act: "release", x: px, y: py - 6 });
    const after = await settled("after control");
    check("CONTROL: autoscroll.armed reads false on every staged read (a staged step can never arm the live clock)",
      armedAtPress === false && mid.autoscroll.armed === false && after.autoscroll.armed === false,
      `armed at press=${armedAtPress}, mid=${mid.autoscroll.armed}, after=${after.autoscroll.armed}`);
    check("CONTROL: a drag held in the safe middle moves the window not at all",
      after.pitchWindow.low === before.low && after.pitchWindow.high === before.high,
      `window [${before.low},${before.high}] → [${after.pitchWindow.low},${after.pitchWindow.high}]`);
    check("CONTROL: a drag held in the safe middle moves neither viewport offset",
      after.viewport.offsetX === before.offsetX && after.viewport.offsetY === before.offsetY,
      `offset (${r2(before.offsetX)},${r2(before.offsetY)}) → (${r2(after.viewport.offsetX)},${r2(after.viewport.offsetY)}); `
      + `note centre y ${r2(py)}, safe zone ${safeLocalRange(before.offsetY).map(r2)}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // TOP WALL — drag the bottom-most drawn note up into the top band
  // (content y≈2, depth≈0.958 — the S3 lane's own numbers). offsetY is 0
  // before any drag, so this is "at the wall" from tick one — growth, never
  // scroll — with NO RECOMPUTE needed (unlike BOTTOM/BAND below): offsetY
  // never leaves 0 here, so a fixed content y IS what a held screen-pointer
  // would be too.
  // ═══════════════════════════════════════════════════════════════════════
  let topResult = null;
  {
    const e0 = await resetScroll();
    const note = extremeNote(e0, "bottom");
    const px = note.x + note.width / 2, py = note.y + note.height / 2;
    const highAtPress = e0.pitchWindow.high;
    const POINTER_Y = 2; // deep in the top band; fixed content y (offsetY stays 0 throughout)
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    // EVERY tick recorded (not just the first 3): with the snap clamp's +1
    // inset, a dropped top-shift term only separates from correct code once
    // >=2 rows have grown (k=1 lands both at the same row) — plant 1 needs
    // the run-on ticks to ever go RED. dt is CONTROLLED (60 ms sleep before
    // every tick forces the 0.05 s cap) — see the header's correction.
    const ticks = [];
    for (let i = 1; i <= 12; i++) {
      await sleep(60);
      const stage = (await stagePitchEditorStep(cmd, { act: "drag", x: px, y: POINTER_Y })).stage;
      const e = await echo();
      ticks.push({ i, high: e.pitchWindow.high, grownRows: e.autoscroll.grownRows,
        dragY: e.autoscroll.dragRect?.y ?? null, lastSide: e.autoscroll.lastSide,
        offsetY: e.viewport.offsetY, armed: e.autoscroll.armed, stage });
      if (i === 5) captures.topMidGrowth = (await captureLook(cmd, join(OUT, "i6b-1-top-mid-growth.png"))).path;
      if (i >= 5 && e.pitchWindow.high - highAtPress >= 2) break;
    }
    const last = ticks[ticks.length - 1];
    console.log(`  top-wall ticks (60ms-controlled dt): ${ticks.map((t) => `#${t.i} high=${t.high}`).join(" ")}`);

    const monotone = ticks.every((t, i) => i === 0 || t.high >= ticks[i - 1].high);
    check("TOP WALL: pitchWindow.high never decreases across ticks",
      monotone, ticks.map((t) => t.high).join(" -> "));
    check("TOP WALL: pitchWindow.high is at least 1 higher after 3 ticks, dt CONTROLLED at the 0.05s cap "
      + "(S3's own claim — an UNCONTROLLED back-to-back probe on this gate's first run measured it FALSE "
      + "at exactly 3 ticks: 0, 323, 316 ms gaps, 0 rows grown; see the header)",
      ticks[2].high - highAtPress >= 1,
      `high at press ${highAtPress}, after 3 ticks ${ticks[2].high} (Δ ${ticks[2].high - highAtPress})`);
    check("TOP WALL: pitchWindow.high is at least 2 higher after 5 ticks (dt controlled)",
      ticks.length >= 5 && ticks[4].high - highAtPress >= 2,
      ticks.length >= 5 ? `after 5 ticks ${ticks[4].high} (Δ ${ticks[4].high - highAtPress})`
        : `only ${ticks.length} tick(s) recorded before the loop ended`);
    check("TOP WALL: viewport.offsetY stays 0 on EVERY recorded tick while the top grows — MEASURED, not inferred",
      ticks.every((t) => t.offsetY === 0), ticks.map((t) => t.offsetY).join(","));
    check("TOP WALL: autoscroll.dragRect stays inside the top band on every tick (y within the band's own width from 0)",
      ticks.every((t) => t.dragY !== null && t.dragY < 60),
      ticks.map((t) => r2(t.dragY)).join(", "));
    check("TOP WALL: autoscroll.grownRows == high(now) − high(at this press's first read) — "
      + "NOT high−fittedHigh (grownRows resets per press; fitted is a different, narrower window)",
      last.grownRows === last.high - highAtPress,
      `grownRows ${last.grownRows}, high(now)-high(atPress) = ${last.high - highAtPress}`);
    check("TOP WALL: autoscroll.lastSide == \"top\" (final tick)", last.lastSide === "top",
      `lastSide ${JSON.stringify(last.lastSide)}`);
    check("TOP WALL: autoscroll.armed is false on EVERY recorded tick (the control leg for the clock)",
      ticks.every((t) => t.armed === false), ticks.map((t) => t.armed).join(","));
    // The hazard the S2 arithmetic fixes: the note's gap to the fixed pointer
    // holds CONSTANT across EVERY recorded tick (not just the first 3) while
    // the window grows underneath it — not "the pointer is inside the rect":
    // the snap clamp insets the note one row from the true edge, so a
    // constant OFFSET is the right invariant (see the header).
    const gaps = ticks.filter((t) => t.dragY !== null).map((t) => t.dragY - POINTER_Y);
    const gapSpread = Math.max(...gaps) - Math.min(...gaps);
    check("TOP WALL: the dragged note's gap to the pointer holds constant across ALL recorded ticks (< half a row)",
      gapSpread < rowHeight / 2,
      `gaps ${gaps.map(r2).join(", ")} (spread ${r2(gapSpread)}, half a row = ${r2(rowHeight / 2)})`);

    await stagePitchEditorStep(cmd, { act: "release", x: px, y: POINTER_Y });
    const afterRelease = await settled("after top-wall release");
    const releasedNote = storeNote(afterRelease, note.id);
    topResult = { highAtPress, highFinal: last.high, releasedNote };
    check("RELEASE HEADROOM: after release, pitchWindow.high is at least the released note's pitch + 1 "
      + "(one row kept for its name label — I6c's measured 'no B4' precedent)",
      releasedNote !== null && afterRelease.pitchWindow.high >= releasedNote.playedMidi + 1,
      releasedNote === null ? `note id ${note.id} not found in the STORE (notes) after release`
        : `pitchWindow.high ${afterRelease.pitchWindow.high}, released note playedMidi ${r2(releasedNote.playedMidi)}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BOTTOM MIRROR — drag the top-most drawn note down into the bottom band,
  // RECOMPUTING the pointer's content y from the LATEST echoed offsetY
  // before every tick (mirroring `EdgeAutoScroll.tick`'s "recompute never
  // integrate" — a FIXED content y converges just inside the band instead of
  // reaching the far wall; the header's second correction, MEASURED on this
  // gate's first run at offsetY≈45.5 against a 114 pt wall). TWO PHASES:
  // phase 1 SCROLLS (low unchanged) until offsetY reaches the wall; phase 2
  // GROWS (low decreases), with offsetY following the new content height.
  // ═══════════════════════════════════════════════════════════════════════
  {
    const e0 = await resetScroll();
    const note = extremeNote(e0, "top");
    const px = note.x + note.width / 2, py = note.y + note.height / 2;
    const lowAtPress = e0.pitchWindow.low;
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    const wallOf = (e) => e.viewport.contentH - e.viewport.viewportH;

    const phase1 = [];
    let e = await echo();
    for (let i = 1; i <= 10 && e.viewport.offsetY < wallOf(e) - 1; i++) {
      await sleep(60);
      const y = e.viewport.offsetY + (viewportH - 2); // RECOMPUTED every tick
      await stagePitchEditorStep(cmd, { act: "drag", x: px, y });
      e = await echo();
      phase1.push({ i, offsetY: e.viewport.offsetY, low: e.pitchWindow.low, wall: wallOf(e) });
    }
    console.log(`  bottom-wall phase 1 (scroll, recomputed pointer): `
      + `${phase1.map((t) => `#${t.i} offsetY=${r2(t.offsetY)}/${r2(t.wall)}`).join(" ")}`);
    check("BOTTOM PHASE 1: pitchWindow.low is UNCHANGED for every SCROLL tick, before the wall is reached "
      + "(scroll-before-grow — a check a docked/zero-room pane could never offer)",
      phase1.every((t) => t.low === lowAtPress),
      phase1.map((t) => `#${t.i} low=${t.low}`).join("; "));

    const phase2 = [];
    for (let i = 1; i <= 10 && lowAtPress - e.pitchWindow.low < 1; i++) {
      await sleep(60);
      const y = e.viewport.offsetY + (viewportH - 2); // still recomputed
      await stagePitchEditorStep(cmd, { act: "drag", x: px, y });
      e = await settled("bottom-wall phase 2 tick"); // the bottom's reveal write lands on a second clock
      phase2.push({ i, offsetY: e.viewport.offsetY, low: e.pitchWindow.low });
    }
    console.log(`  bottom-wall phase 2 (grow): ${phase2.map((t) => `#${t.i} low=${t.low}`).join(" ")} `
      + `(${phase1.length + phase2.length} tick(s) total)`);
    const settledAfter = await settled("after bottom-wall growth");
    check("BOTTOM MIRROR: pitchWindow.low never increases across phase-2 ticks",
      phase2.length > 0 && phase2.every((t, i) => i === 0 || t.low <= phase2[i - 1].low),
      phase2.map((t) => t.low).join(" -> "));
    check("BOTTOM MIRROR: pitchWindow.low is at least 1 lower after growth",
      lowAtPress - settledAfter.pitchWindow.low >= 1,
      `low at press ${lowAtPress}, now ${settledAfter.pitchWindow.low}`);
    check("BOTTOM MIRROR: autoscroll.lastSide == \"bottom\"", settledAfter.autoscroll.lastSide === "bottom",
      `lastSide ${JSON.stringify(settledAfter.autoscroll.lastSide)}`);
    check("BOTTOM MIRROR: viewport.offsetY follows contentH − viewportH (the newly grown row is revealed)",
      settledAfter.viewport.offsetY > 0 && Math.abs(settledAfter.viewport.offsetY - wallOf(settledAfter)) < 1,
      `offsetY ${r2(settledAfter.viewport.offsetY)}, contentH-viewportH ${r2(wallOf(settledAfter))}`);
    await stagePitchEditorStep(cmd, { act: "release", x: px, y: e.viewport.offsetY + (viewportH - 2) });
    await settled("after bottom-wall release");
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BAND (x) — press EMPTY surface (in the safe vertical zone), drag into
  // the right edge, RECOMPUTING x from the latest echoed offsetX before
  // every tick (same convergence reason as BOTTOM). y is held at a FIXED
  // SAFE value throughout — since no vertical push should ever fire there,
  // that is now a real invariance check, not an assumption baked into the
  // choice of point.
  // ═══════════════════════════════════════════════════════════════════════
  {
    const e0 = await resetScroll();
    const px0 = e0.viewport.offsetX + 80;
    const py = emptySafePoint(e0, px0) ?? emptySafePoint(e0, e0.viewport.offsetX + e0.viewport.viewportW / 2);
    if (py === null) refuseRun("no empty, safe (off-band) content point found for the BAND leg's press");
    const before = { offsetX: e0.viewport.offsetX, offsetY: e0.viewport.offsetY,
      low: e0.pitchWindow.low, high: e0.pitchWindow.high, grownRows: e0.autoscroll.grownRows };
    await stagePitchEditorStep(cmd, { act: "press", x: px0, y: py });
    let e = await echo();
    for (let i = 1; i <= 8; i++) {
      const wallX = e.viewport.contentW - e.viewport.viewportW;
      if (e.viewport.offsetX >= wallX - 1) break;
      await sleep(60);
      const x = e.viewport.offsetX + (e.viewport.viewportW - 2); // RECOMPUTED every tick
      await stagePitchEditorStep(cmd, { act: "drag", x, y: py });
      e = await echo();
    }
    const settledAfter = await settled("after band scroll");
    check("BAND: pressing empty surface and dragging promotes to a band (press.kind == \"band\")",
      settledAfter.press.kind === "band", `press.kind ${JSON.stringify(settledAfter.press.kind)}`);
    check("BAND: dragging into the right edge scrolls viewport.offsetX substantially (recomputed pointer)",
      settledAfter.viewport.offsetX > before.offsetX + 40,
      `offsetX ${r2(before.offsetX)} → ${r2(settledAfter.viewport.offsetX)}`);
    check("BAND: autoscroll.lastSide == \"right\"", settledAfter.autoscroll.lastSide === "right",
      `lastSide ${JSON.stringify(settledAfter.autoscroll.lastSide)}`);
    check("BAND: a band never grows the window — grownRows stays 0 for the whole leg",
      settledAfter.autoscroll.grownRows === 0
        && settledAfter.pitchWindow.low === before.low && settledAfter.pitchWindow.high === before.high,
      `grownRows ${settledAfter.autoscroll.grownRows}; window [${before.low},${before.high}] → `
      + `[${settledAfter.pitchWindow.low},${settledAfter.pitchWindow.high}]`);
    check("BAND: no vertical push fired (y held fixed in the safe zone, off both bands) — offsetY unmoved",
      settledAfter.viewport.offsetY === before.offsetY,
      `offsetY ${r2(before.offsetY)} → ${r2(settledAfter.viewport.offsetY)} (y held at ${r2(py)})`);
    // CORNER — still in flight, with y now ALSO in the top band (offsetY is
    // still 0 here, so this is "at the wall" on y too): `edgeBehaviour`'s
    // `.band` arm is `(.both, grows: false)`, so the ELSE-IF-GROWS branch is
    // reached and must do nothing. This is the leg a `.band` grows-flag flip
    // actually exercises — the fixed-safe-y checks above do not, because
    // `pushes.vertical` is nil there and `grows` is never consulted.
    //
    // dt CONTROLLED here too (5 × 60ms-throttled ticks, not one bare tick):
    // MEASURED necessary on this gate's own development — a single untimed
    // corner tick's dt is whatever the last horizontal tick's round trip left
    // (a few ms), which earns a growthRemainder contribution far under one
    // whole row even with BOTH of the product's guards defeated by hand,
    // and reads as a false "still nothing grew". Five capped ticks earn
    // ~2.9 rows if the `.band` grows=false arm is not actually held.
    const beforeCorner = await echo();
    const cornerX = beforeCorner.viewport.offsetX + (beforeCorner.viewport.viewportW - 2);
    for (let i = 0; i < 5; i++) {
      await sleep(60);
      await stagePitchEditorStep(cmd, { act: "drag", x: cornerX, y: 2 });
    }
    const cornerSettled = await settled("after band corner (y into the top band)");
    check("BAND CORNER: y also at the top wall still grows nothing over 5 dt-controlled ticks "
      + "(the .band grows=false arm)",
      cornerSettled.autoscroll.grownRows === 0
        && cornerSettled.pitchWindow.low === beforeCorner.pitchWindow.low
        && cornerSettled.pitchWindow.high === beforeCorner.pitchWindow.high,
      `grownRows ${cornerSettled.autoscroll.grownRows}; window [${beforeCorner.pitchWindow.low},`
      + `${beforeCorner.pitchWindow.high}] → [${cornerSettled.pitchWindow.low},${cornerSettled.pitchWindow.high}]`);
    await stagePitchEditorStep(cmd, { act: "release", x: cornerX, y: 2 });
    await settled("after band release");
  }

  writeFileSync(join(OUT, "i6b-report.json"), JSON.stringify({
    root: RUN_ROOT, binarySha, topResult: topResult && {
      highAtPress: topResult.highAtPress, highFinal: topResult.highFinal,
      releasedNotePlayedMidi: topResult.releasedNote?.playedMidi ?? null,
    },
  }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { await cmd("transport.stop", {}); } catch { /* best effort */ }
  try { session.ws.close(); } catch { /* ignore */ }
  stopStaging(GATE);
  console.log("staging stopped (pidfile-exact)");
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
