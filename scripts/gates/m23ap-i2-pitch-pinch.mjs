// m23-ap I2-5 GATE — PINCH TO ZOOM TIME in the pitch (note) editor, against a
// REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE app and is
// never touched. Staging is stopped PIDFILE-EXACT through `_pitch-editor-look
// .mjs`'s `stopLook`, never pkill/pgrep).
//
// WHAT THIS PROVES
//   Through the pane's OWN pinch functions (`PitchEditorView.pinchChanged` /
//   `pinchEnded`, reached by the staged `debug.pitchEditor {act:"pinch"}` step,
//   the same two functions the `MagnifyGesture` callbacks call):
//     (a) THE POINTER HOLDS — across six ticks in AND out, the content point the
//         pinch started on stays at the same screen x (within 1 pt), measured
//         from the pane's own readers (`viewport.offsetX`) at the scale the
//         store holds (`zoom.pixelsPerBeat`) — never from what was asked for;
//     (b) CAPTURED ONCE — `pinch {ppb, offset, screenX}` is identical on every
//         tick of one pinch;
//     (c) `pinch.live` is false after `pinchEnd`.
//   DISCRIMINATING NEGATIVE CONTROL: the SAME scale sequence driven through
//   `debug.panelLayout {pitchEditorPPB}` (the buttons' path: no pointer, so the
//   playhead-or-centre anchor) must move that same content point by > 20 pt.
//   Without it, (a) could pass on a pane whose every zoom happens to hold that
//   x — this is the leg that shows the POINTER path, not the centre path,
//   produced (a).
//   INVARIANCE: `zoom.rowHeight` and `viewport.offsetY` never move (time only);
//   `interaction.commitCount` never moves (a pinch never commits); the STORED
//   note table (`clip.getPitchEdits`, the second instrument) is byte-identical
//   before and after.
//   REFUSALS: a pinch while a press is in flight, a magnification of 0 and of
//   −1, a moved start mid-pinch, and a `pinchEnd` with no pinch live each come
//   back `ok:false` — never a plausible no-op.
//
// WHAT THIS DOES NOT PROVE — stated plainly, because a green run looks like it:
//   • that a REAL trackpad pinch reaches the pane's `MagnifyGesture` in its
//     nesting (vertical ScrollView → horizontal ScrollView → `.gesture(drag)` +
//     `.simultaneousGesture(pinch)`). Nothing in this tree can drive a real
//     pointer (m23-g1). It is INFERRED from the roll, whose nesting matches, and
//     is a user-hands check on the handoff page.
//   • the `MagnifyGesture.Value → pinchChanged` line itself (two forwarding
//     lines, pinned only by source shape in `PitchEditorInteractionSiteTests`).
//
// FIXTURE ARITHMETIC — DERIVED FROM THE ECHO BEFORE THE FIRST PINCH, NEVER
// DISCOVERED BY TRIAL. With start scale p0, content width C0 = L·p0, viewport W,
// the pinch's content x s and its screen x a (= s − offset0), every tick at
// magnification m asks for the offset s·m − a. The anchor can only HOLD if that
// offset is inside [0, C0·m − W] for EVERY m in the sweep — the 0 floor on the
// left and the new-content end clamp on the right both make it give way
// (`PitchEditorViewport.timeZoomOffset`'s doc). A fixture where a clamp engages
// cannot tell a broken anchor from a clamped one, so it is REFUSED (exit 2,
// "this run proves nothing") rather than failed. The pinch point is also held
// >= 200 pt from the viewport centre (the negative control's anchor: the
// transport sits at beat 0, off-screen once scrolled, so `timeZoomAnchor`
// falls back to the centre) — a pinch AT the centre would make the control
// indistinguishable from the pointer path.
//
// PROVENANCE. This gate launches the EXISTING `.build/debug/DAWApp` with
// `skipBuild` (the look harness pins it: this machine's other lanes measure
// timings). A skipped build certifies an instance of unknown provenance, so the
// gate proves the binary is newer than every file under `Sources/` and
// `Package.swift` FIRST, with a positive control on the same `find` shape, and
// refuses (exit 2) otherwise. Rebuild under a heavy slot and re-run.
//
// Setup: none — run it (the staging lock is the CALLER's; see the w2 brief).
//
//   node scripts/gates/m23ap-i2-pitch-pinch.mjs
//
// Env: M23AP_I2_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-i2).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, verdict, sleep } from "./_staging.mjs";
import {
  synthesizeVocalFixture, launchLook, stopLook, makeCmd, openTunedClip,
  waitPitchEditorReady, stagePitchEditorStep, captureLook, getStoredPitchEdits,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-i2";
const OUT = process.env.M23AP_I2_OUT || "/tmp/m23ap-i2";
mkdirSync(OUT, { recursive: true });

// The pinch's sweep, IN and OUT (I2-5): cumulative magnifications since the
// pinch began, each one tick.
const SWEEP = [1.25, 1.6, 2.0, 1.4, 0.8, 0.6];
// The start scale. Chosen so the WHOLE sweep (p0 × 0.6 … p0 × 2.0 = 38.4 …
// 128) stays inside the slot's 4…200 clamp, so no tick is a clamped repeat.
const P0 = 64;
const HOLD_TOLERANCE_PT = 1;
const CONTROL_MIN_DRIFT_PT = 20;
const CENTRE_CLEARANCE_PT = 200;

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const r2 = (v) => (typeof v === "number" ? Math.round(v * 100) / 100 : v);
/** Canonical JSON: object keys SORTED, recursively. The app's `JSONValue.object`
 * is a Swift dictionary and serializes in HASH order — MEASURED on the first
 * run of this gate: two reads of the same unchanged note table came back as
 * 9057 bytes each, with the keys in different orders, so a raw
 * `JSON.stringify` comparison failed on identical content. "Byte-identical"
 * here therefore means identical under this canonical form. */
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));

// Self-control on `canon` itself: it must equate a reordering and must still
// SEPARATE different content (a comparator that equates everything would turn
// both identity checks below into constants).
if (canon({ a: 1, b: { c: 2, d: 3 } }) !== canon({ b: { d: 3, c: 2 }, a: 1 })
    || canon({ a: 1, b: { c: 2 } }) === canon({ a: 1, b: { c: 3 } })) {
  console.log("ABORT (proves nothing): canon() self-control failed");
  process.exit(2);
}

/** Exit 2 = "this run proves nothing" (the `_staging.mjs` ABORT family). */
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// PROVENANCE — the skipped build must be the tree's own build.
// ═══════════════════════════════════════════════════════════════════════════
{
  const binary = join(ROOT, DEFAULT_BINARY);
  const find = (args) => spawnSync("find", args, { cwd: ROOT, encoding: "utf8" });
  const newer = find(["Sources", "Package.swift", "-newer", binary, "-type", "f"]);
  const older = find(["Sources", "-type", "f", "!", "-newer", binary]);
  if (newer.status !== 0 || older.status !== 0) {
    refuseRun(`find failed (status ${newer.status}/${older.status}) — `
      + `${newer.stderr || older.stderr}`.trim());
  }
  const newerFiles = newer.stdout.split("\n").filter(Boolean);
  const olderCount = older.stdout.split("\n").filter(Boolean).length;
  // POSITIVE CONTROL: the same find shape CAN return files. A find that never
  // looked and one that looked and saw nothing print the same empty output.
  if (olderCount === 0) refuseRun("provenance control: `! -newer` matched no file — the find shape is broken");
  if (newerFiles.length > 0) {
    refuseRun(`${newerFiles.length} source file(s) are NEWER than ${DEFAULT_BINARY} `
      + `(${newerFiles.slice(0, 4).join(", ")}${newerFiles.length > 4 ? ", …" : ""}) — `
      + "the staging binary is not this tree's build. Rebuild under a heavy slot and re-run.");
  }
  console.log(`provenance: ${DEFAULT_BINARY} is newer than all ${olderCount} files under Sources/ `
    + "and Package.swift (positive control: the same find shape returned them)");
}

// ═══════════════════════════════════════════════════════════════════════════
// FIXTURE — a sung-like vocal of 30 s or more (I2-5), 22 distinct notes.
// ═══════════════════════════════════════════════════════════════════════════
const SCALE_HZ = [196, 220, 247, 262, 294, 330, 349, 392];
const LEGS = Array.from({ length: 22 }, (_, i) => ({ hz: SCALE_HZ[i % SCALE_HZ.length], seconds: 1.4 }));
const fixturePath = synthesizeVocalFixture(OUT, { notes: LEGS });
const fixtureSeconds = 0.12 + LEGS.reduce((sum, leg) => sum + leg.seconds, 0);
console.log(`fixture: ${fixturePath} (${LEGS.length} notes, ${r2(fixtureSeconds)} s)`);
if (fixtureSeconds < 30) refuseRun(`fixture is ${fixtureSeconds} s — I2-5 asks for 30 s or more`);

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchLook({ gate: GATE, settleMs: 1500 });
console.log(`staging pid ${session.pid} (skipBuild — provenance proved above)`);
const cmd = makeCmd(session.ws);
/** Unwrap or throw — for SETUP only. Assertions use the raw envelope. */
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});

let exitCode = null;
try {
  // ── the round trip, then NAME the project (the house rule: own test work
  //    lives in a named project, so cleanup is never a question for the user)
  const opened = await openTunedClip(cmd, { fixturePath });
  const projectPath = join(OUT, "2026-09-25 I2 Pinch Gate.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${opened.clipId.slice(0, 8)}, `
    + `${opened.segmentCount} stored segments`);
  await waitPitchEditorReady(cmd, { timeoutMs: 45_000, intervalMs: 300 });

  /** Poll `debug.pitchEditor {}` until two CONSECUTIVE reads agree on
   * `viewport.offsetX` and on the scale (bounded). The debug handler's own
   * pinch wait covers its re-pin; `debug.panelLayout` has no landing wait at
   * all, so both arms settle the same way here. Returns the settled echo and
   * how long it took. */
  async function settled(label, { timeoutMs = 3000, intervalMs = 60 } = {}) {
    const t0 = Date.now();
    let prev = await echo();
    while (Date.now() - t0 < timeoutMs) {
      await sleep(intervalMs);
      const next = await echo();
      if (next.viewport.offsetX === prev.viewport.offsetX
          && next.zoom.pixelsPerBeat === prev.zoom.pixelsPerBeat) {
        return { e: next, ms: Date.now() - t0 };
      }
      prev = next;
    }
    throw new Error(`${label}: viewport.offsetX never settled within ${timeoutMs} ms `
      + `(last ${prev.viewport.offsetX})`);
  }

  // ── the start scale, and a transport parked at beat 0 (so the negative
  //    control's anchor is the CENTRE once the view is scrolled past it)
  await must("transport.stop", {});
  await must("transport.seek", { beats: 0 });
  await must("debug.panelLayout", { pitchEditorPPB: P0 });
  let { e: base } = await settled("start scale");
  if (base.zoom.pixelsPerBeat !== P0) refuseRun(`start scale read back ${base.zoom.pixelsPerBeat}, not ${P0}`);
  const W = base.viewport.viewportW;
  const C0 = base.viewport.contentW;
  console.log(`geometry: ppb ${P0}, viewportW ${r2(W)}, contentW ${r2(C0)}, `
    + `${base.notesAsDrawn.length} notes drawn`);

  // ── FIXTURE ARITHMETIC (header): the feasible band for the pinch's content
  //    x `s`, given its screen x `a`, over EVERY tick of the sweep.
  const a0 = Math.round(W / 2 - 320);   // 320 pt left of the centre (>= 200 clearance)
  const feasible = (s, a) => SWEEP.every((m) => {
    const want = s * m - a;
    return want >= 0 && want <= C0 * m - W;
  }) && s - a >= 0 && s - a <= C0 - W;
  let lo = -Infinity, hi = Infinity;
  for (const m of SWEEP) {
    lo = Math.max(lo, a0 / m);                 // the 0 floor
    hi = Math.min(hi, (C0 * m - W + a0) / m);  // the new-content end clamp
  }
  lo = Math.max(lo, a0); hi = Math.min(hi, C0 - W + a0);
  if (!(hi > lo)) refuseRun(`no feasible pinch x: band [${r2(lo)}, ${r2(hi)}] is empty for `
    + `W=${r2(W)}, C0=${r2(C0)} — the clip is too short for this sweep at ppb ${P0}`);
  // Pinch ON a note (so the captures have a note to hold), the note whose
  // centre is nearest the middle of the feasible band.
  const mid = (lo + hi) / 2;
  const target = [...base.notesAsDrawn]
    .map((n) => ({ ...n, cx: n.x + n.width / 2, cy: n.y + n.height / 2 }))
    .filter((n) => n.cx > lo + 5 && n.cx < hi - 5)
    .sort((p, q) => Math.abs(p.cx - mid) - Math.abs(q.cx - mid))[0];
  if (!target) refuseRun(`no drawn note has its centre inside the feasible band [${r2(lo)}, ${r2(hi)}]`);
  const S = { x: r2(target.cx), y: r2(target.cy) };
  // Scroll so that note sits at screen x a0, then MEASURE where it landed.
  await stagePitchEditorStep(cmd, { act: "scroll", x: S.x - a0 });
  ({ e: base } = await settled("initial scroll"));
  const offset0 = base.viewport.offsetX;
  const A = S.x - offset0;   // the pinch's screen x, as MEASURED
  console.log(`pinch point: content (${S.x}, ${S.y}) on note ${target.id.slice(0, 8)}; `
    + `offset ${r2(offset0)} → screen x ${r2(A)} (feasible s ∈ [${r2(lo)}, ${r2(hi)}])`);
  if (!feasible(S.x, A)) {
    refuseRun(`the measured start (s=${S.x}, a=${r2(A)}, offset ${r2(offset0)}) leaves the `
      + "feasible band — a clamp would engage somewhere in the sweep");
  }
  if (Math.abs(A - W / 2) < CENTRE_CLEARANCE_PT) {
    refuseRun(`pinch screen x ${r2(A)} is within ${CENTRE_CLEARANCE_PT} pt of the centre ${r2(W / 2)}`);
  }
  const playheadScreenX = 0 * P0 - offset0;   // transport at beat 0, clip at beat 0
  if (Math.abs(A - playheadScreenX) < CENTRE_CLEARANCE_PT) {
    refuseRun(`pinch screen x ${r2(A)} is within ${CENTRE_CLEARANCE_PT} pt of the playhead ${r2(playheadScreenX)}`);
  }
  /** Where the pinch's content point is on screen NOW, from what the pane
   * MEASURED (its offset) at the scale the store holds. */
  const pointerScreenX = (e) => S.x * (e.zoom.pixelsPerBeat / P0) - e.viewport.offsetX;

  // ── INVARIANTS, before anything pinches
  const before = {
    rowHeight: base.zoom.rowHeight,
    offsetY: base.viewport.offsetY,
    commitCount: base.interaction.commitCount,
    storedJSON: canon(await getStoredPitchEdits(cmd, opened.clipId)),
  };
  if (base.pinch.live !== false) refuseRun(`a pinch is already live before the gate began: ${JSON.stringify(base.pinch)}`);
  const capBefore = await captureLook(cmd, join(OUT, "i2-1-before.png"));

  // ═════════════════════════════════════════════════════════════════════════
  // THE PINCH — six ticks, in and out, each settled before it is read.
  // ═════════════════════════════════════════════════════════════════════════
  const ticks = [];
  let capMid = null;
  for (const [i, m] of SWEEP.entries()) {
    const t0 = Date.now();
    const stage = (await stagePitchEditorStep(cmd, { act: "pinch", x: S.x, y: S.y, magnification: m })).stage;
    const { e, ms } = await settled(`tick ${i + 1}`);
    ticks.push({ m, stage, e, landMs: Date.now() - t0, settleMs: ms });
    // A MOVED start mid-pinch is refused (one gesture has one start).
    if (i === 1) {
      const moved = await cmd("debug.pitchEditor", { act: "pinch", x: S.x + 50, y: S.y, magnification: 1.7 });
      check("REFUSAL: a pinch tick with a moved start is refused mid-pinch",
        moved.ok === false, `ok=${moved.ok} error=${JSON.stringify(moved.error)}`);
    }
    if (m === 2.0) capMid = await captureLook(cmd, join(OUT, "i2-2-mid-x2.png"));
  }
  const afterSweep = ticks[ticks.length - 1].e;
  const endStage = (await stagePitchEditorStep(cmd, { act: "pinchEnd" })).stage;
  const { e: ended } = await settled("pinchEnd");
  const capAfter = await captureLook(cmd, join(OUT, "i2-3-after-x0.6.png"));

  // (a) THE POINTER HOLDS
  for (const [i, t] of ticks.entries()) {
    const want = r2(P0 * t.m);
    const x = pointerScreenX(t.e);
    check(`tick ${i + 1} (m=${t.m}): the scale is the start scale × m`,
      Math.abs(t.e.zoom.pixelsPerBeat - P0 * t.m) < 1e-6,
      `zoom.pixelsPerBeat ${r2(t.e.zoom.pixelsPerBeat)}, want ${want}; `
      + `stage scaleChanged=${t.stage.scaleChanged} offsetMoved=${t.stage.offsetMoved}`);
    check(`tick ${i + 1} (m=${t.m}): the pinch's content point holds its screen x (±${HOLD_TOLERANCE_PT} pt)`,
      Math.abs(x - A) <= HOLD_TOLERANCE_PT,
      `screen x ${r2(x)} vs start ${r2(A)} (Δ ${r2(x - A)}); offsetX ${r2(t.e.viewport.offsetX)}; `
      + `landed in ${t.landMs} ms (settle ${t.settleMs} ms)`);
  }
  // (b) CAPTURED ONCE
  const first = ticks[0].e.pinch;
  check("the first tick captured the anchor at the start scale, offset and screen x",
    first.live === true && first.ppb === P0 && Math.abs(first.offset - offset0) < 1e-6
      && Math.abs(first.screenX - A) < 1e-6,
    `pinch ${JSON.stringify(first)}; want ppb ${P0}, offset ${r2(offset0)}, screenX ${r2(A)}`);
  const drifted = ticks.filter((t) => canon(t.e.pinch) !== canon(first));
  check("CAPTURED ONCE: pinch {ppb, offset, screenX} is identical on every tick",
    drifted.length === 0,
    drifted.length === 0 ? `all ${ticks.length} ticks: ${canon(first)}`
      : `ticks ${drifted.map((t) => SWEEP.indexOf(t.m) + 1).join(",")} differ: `
        + drifted.map((t) => canon(t.e.pinch)).join(" "));
  // (c) OVER
  check("after pinchEnd, pinch.live is false and the anchor is gone",
    ended.pinch.live === false && ended.pinch.ppb === null,
    `stage ${JSON.stringify(endStage)}; pinch ${JSON.stringify(ended.pinch)}`);
  check("pinchEnd moved nothing (the scale and the offset stand where the last tick left them)",
    ended.zoom.pixelsPerBeat === afterSweep.zoom.pixelsPerBeat
      && ended.viewport.offsetX === afterSweep.viewport.offsetX,
    `ppb ${afterSweep.zoom.pixelsPerBeat}→${ended.zoom.pixelsPerBeat}, `
    + `offsetX ${r2(afterSweep.viewport.offsetX)}→${r2(ended.viewport.offsetX)}`);

  // INVARIANCE — time only, never a commit, never a stored byte
  const rowsMoved = ticks.filter((t) => t.e.zoom.rowHeight !== before.rowHeight
    || t.e.viewport.offsetY !== before.offsetY);
  check("INVARIANCE: rowHeight and offsetY never moved on any tick (a pinch zooms TIME only)",
    rowsMoved.length === 0,
    `rowHeight ${before.rowHeight}, offsetY ${before.offsetY}; ${rowsMoved.length} tick(s) differed`);
  check("INVARIANCE: interaction.commitCount unchanged (a pinch never commits)",
    ended.interaction.commitCount === before.commitCount,
    `${before.commitCount} → ${ended.interaction.commitCount}`);
  const storedAfter = canon(await getStoredPitchEdits(cmd, opened.clipId));
  check("INVARIANCE: clip.getPitchEdits is identical (canonical JSON) before and after the pinch",
    storedAfter === before.storedJSON,
    `${before.storedJSON.length} bytes before, ${storedAfter.length} after`);

  // ═════════════════════════════════════════════════════════════════════════
  // DISCRIMINATING NEGATIVE CONTROL — the same scales, no pointer.
  // ═════════════════════════════════════════════════════════════════════════
  await must("debug.panelLayout", { pitchEditorPPB: P0 });
  await settled("control: back to the start scale");
  await stagePitchEditorStep(cmd, { act: "scroll", x: offset0 });
  const { e: controlBase } = await settled("control: back to the start offset");
  const controlStartOk = controlBase.zoom.pixelsPerBeat === P0
    && Math.abs(controlBase.viewport.offsetX - offset0) <= 0.5 && controlBase.pinch.live === false;
  check("control starts where the pinch started (same scale, same offset, no pinch live)",
    controlStartOk,
    `ppb ${controlBase.zoom.pixelsPerBeat} (want ${P0}), offsetX ${r2(controlBase.viewport.offsetX)} `
    + `(want ${r2(offset0)}), pinch.live ${controlBase.pinch.live}`);
  const controlDrift = [];
  for (const m of SWEEP) {
    await must("debug.panelLayout", { pitchEditorPPB: P0 * m });
    const { e } = await settled(`control m=${m}`);
    controlDrift.push({ m, drift: pointerScreenX(e) - A, ppb: e.zoom.pixelsPerBeat });
  }
  const maxDrift = Math.max(...controlDrift.map((c) => Math.abs(c.drift)));
  check(`NEGATIVE CONTROL: the same scale sequence via debug.panelLayout (centre anchor) moves `
      + `the pinch's content point by > ${CONTROL_MIN_DRIFT_PT} pt`,
    controlStartOk && maxDrift > CONTROL_MIN_DRIFT_PT,
    `max |Δ| ${r2(maxDrift)} pt; per tick ${controlDrift.map((c) => `m=${c.m}:${r2(c.drift)}`).join(" ")}`);

  // ═════════════════════════════════════════════════════════════════════════
  // REFUSALS — an error, never a plausible no-op.
  // ═════════════════════════════════════════════════════════════════════════
  const zero = await cmd("debug.pitchEditor", { act: "pinch", x: S.x, y: S.y, magnification: 0 });
  check("REFUSAL: magnification 0", zero.ok === false, `ok=${zero.ok} error=${JSON.stringify(zero.error)}`);
  const negative = await cmd("debug.pitchEditor", { act: "pinch", x: S.x, y: S.y, magnification: -1 });
  check("REFUSAL: magnification −1", negative.ok === false,
    `ok=${negative.ok} error=${JSON.stringify(negative.error)}`);
  const bareEnd = await cmd("debug.pitchEditor", { act: "pinchEnd" });
  check("REFUSAL: pinchEnd with no pinch live", bareEnd.ok === false,
    `ok=${bareEnd.ok} error=${JSON.stringify(bareEnd.error)}`);
  // A pinch while a press is in flight: press EMPTY surface (a band press, which
  // hears nothing and commits nothing), pinch, then release it.
  const now = await echo();
  const px = now.viewport.offsetX + 100;
  const clear = (y) => now.notesAsDrawn.every((n) =>
    px < n.x - 10 || px > n.x + n.width + 10 || y < n.y - 20 || y > n.y + n.height + 20);
  let py = null;
  for (let y = 4; y < now.viewport.contentH - 4; y += 6) { if (clear(y)) { py = y; break; } }
  if (py === null) {
    check("REFUSAL: a pinch while a press is in flight", false,
      `no empty surface point found at content x ${r2(px)} to press on`);
  } else {
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    const midPress = await cmd("debug.pitchEditor", { act: "pinch", x: px, y: py, magnification: 1.5 });
    const released = await stagePitchEditorStep(cmd, { act: "release", x: px, y: py });
    check("REFUSAL: a pinch while a press is in flight",
      midPress.ok === false && released.press.inFlight === false,
      `ok=${midPress.ok} error=${JSON.stringify(midPress.error)}; the press was then released `
      + `(${released.lastRelease?.action}/${released.lastRelease?.click})`);
  }
  const afterRefusals = await echo();
  check("INVARIANCE: the refusals committed nothing and left no pinch live",
    afterRefusals.interaction.commitCount === before.commitCount && afterRefusals.pinch.live === false,
    `commitCount ${afterRefusals.interaction.commitCount} (was ${before.commitCount}), `
    + `pinch.live ${afterRefusals.pinch.live}`);

  // ═════════════════════════════════════════════════════════════════════════
  // LOOK — the drawn hint, at the narrowest window the app allows.
  // ═════════════════════════════════════════════════════════════════════════
  const frame = await must("debug.windowFrame", { width: 1208 });
  await sleep(800);
  const narrow = await echo();
  const capNarrow = await captureLook(cmd, join(OUT, "i2-4-narrow-header.png"));
  check("the zoom cluster DREW the pinch hint (ledger, not a tooltip)",
    narrow.zoom.hintText === "Pinch to zoom time",
    `zoom.hintText ${JSON.stringify(narrow.zoom.hintText)} at window content width ${frame.width} `
    + `(floor ${frame.minWidth})`);

  const report = {
    fixture: { path: fixturePath, seconds: fixtureSeconds, notes: LEGS.length },
    geometry: { p0: P0, viewportW: W, contentW: C0, pinch: S, offset0, screenX: A,
                feasible: [lo, hi] },
    ticks: ticks.map((t) => ({ m: t.m, ppb: t.e.zoom.pixelsPerBeat, offsetX: t.e.viewport.offsetX,
                               screenX: pointerScreenX(t.e), landMs: t.landMs, stage: t.stage,
                               pinch: t.e.pinch })),
    control: controlDrift,
    captures: [capBefore, capMid, capAfter, capNarrow].map((c) => c && c.path),
    narrow: { frame, hintText: narrow.zoom.hintText, clipName: narrow.chrome?.statusText },
  };
  writeFileSync(join(OUT, "i2-report.json"), JSON.stringify(report, null, 2));
  console.log(`captures: ${report.captures.join("  ")}`);
  console.log(`report: ${join(OUT, "i2-report.json")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { session.ws.close(); } catch { /* ignore */ }
  const stopped = stopLook(GATE);
  console.log(`staging stopped: ${JSON.stringify(stopped)}`);
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
