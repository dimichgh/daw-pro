// m25-j GATE — `debug.explainFrames` REPORTS WHERE A CLIP IS DRAWN, against a
// REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE app and is never
// touched. Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY, so the thing under test has known
// provenance (m23-ac: a gate that drives whatever happens to be on the port can
// pass against code that is days old and cannot tell you that it did).
//
// ══ THE DEFECT ═════════════════════════════════════════════════════════════
// `.explainable` measures with a `GeometryReader` in a `.background`, which sees
// LAYOUT. Timeline clips are placed with `.offset(x: startBeat·ppb, y: laneTop)`,
// which is a RENDER transform — it moves the drawing and leaves the layout at the
// ZStack's top-leading corner. So every clip in the arrangement reported the SAME
// rectangle. MEASURED on staging before the fix, three clips on three tracks at
// beats 0/8/20:
//
//     {x:298, y:163, w:64, h:34}   {x:298, y:163, …}   {x:298, y:163, …}
//
// Widths and heights were CORRECT, which is what made it dangerous: the
// instrument returned a plausible rectangle instead of an error, so a harness
// that cropped a screenshot at a reported origin measured an empty neighbouring
// lane with total confidence. It broke the m25-e visual harness exactly that way
// (caught only because a positive control demanded a non-zero delta and got
// exactly zero) and it made m25-l-2's cross-track drag ghost — which lives
// entirely in `.offset(y:)` — unmeasurable in principle.
//
// ══ THE DISCRIMINATOR, and why it is the right shape ═══════════════════════
// TWO THINGS THAT MUST DIFFER READING THE SAME is a stronger signal than any one
// value looking wrong. D1 below is that check. But "the values differ" is the
// WEAK form — a fix that offset the frames by anything at all would pass it — so
// D2/D3 pin the actual numbers against instruments that are NOT the thing under
// test:
//   • horizontally, the app's OWN reported `ppb` (`debug.arrangeZoom`) times the
//     STORE's own start beat;
//   • vertically, the SIDEBAR's own `trackRowIdentity` rects, which are laid out
//     by a real VStack and were never affected by this defect. That also asserts
//     the sidebar/lane alignment law as a side effect.
// Neither instrument shares a code path with `clipBlock`'s placement, and neither
// is a constant copied out of the view.
//
// ══ WHAT ELSE IT PROVES ════════════════════════════════════════════════════
//   • Z: the reported x tracks a ZOOM change — the report is live geometry, not a
//     one-time snapshot taken at mount.
//   • G: during a STAGED DRAG (`phase:"move"`) the reported rect follows the
//     GHOST while the store's start beat does not move. That is the m25-l-2
//     verification route this defect was blocking, demonstrated rather than
//     asserted.
//
// ══ HOW TO REDDEN IT (do this before believing it) ═════════════════════════
// In `Sources/DAWApp/Components/Explain.swift`, drop the `renderOffset:` term
// from `ExplainGeometry.drawnFrame(…)` inside `ExplainableModifier` — i.e. report
// the raw `geo.frame(in:)` again. D1/D2/D3/Z/G all go RED and the origins collapse
// back to one rectangle. (`cp` the file aside and `cmp` it back — never `git
// stash`, this tree carries uncommitted work.)
//
// Setup: none — run it.
//
//   node scripts/gates/m25j-clip-frames.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, verdict } from "./_staging.mjs";

const GATE = "m25j";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M25J_OUT || "/tmp/m25j";
const PIDFILE = process.env.M25J_PIDFILE || "/tmp/m25j-staging.pid";
const BINARY = process.env.M25J_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M25J_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const STARTS = [0, 8, 20];   // beats — DIFFERENT, and none is a multiple of another's row
const LEN = 4;               // beats
const EPS = 0.6;             // points; frames are floats and rows land on .5 boundaries

buildOrAbort({ root: REPO, skip: process.env.M25J_SKIP_BUILD === "1" });

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
      const raw = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve) => {
          pending.set(id, { resolve, reject: (e) => resolve({ __error: e.message }), command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); resolve({ __error: `timeout ${command}` }); }
          }, 25000);
        });
      };
      const req = async (c, p) => {
        const r = await raw(c, p);
        if (r && r.__error) throw new Error(r.__error);
        return r;
      };
      return { ws, req, raw };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

const { ws, req, raw } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };

const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

const frames = async (ids) => (await req("debug.explainFrames", { ids })).frames ?? {};

try {
  // ══ FIXTURE ════════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  const tracks = [];
  for (let i = 0; i < STARTS.length; i++) {
    tracks.push((await req("track.add", { kind: "instrument", name: `M25J-${i}` })).id);
  }
  const clipIDs = [];
  for (let i = 0; i < STARTS.length; i++) {
    // ⚠️ `atBeat`, NOT `startBeat` — the standing trap.
    clipIDs.push((await req("clip.addMIDI",
      { trackId: tracks[i], atBeat: STARTS[i], lengthBeats: LEN })).id);
  }
  await req("debug.explainMode", { on: true });
  await sleep(700);

  const zoom = await req("debug.arrangeZoom", {});
  const ppb = zoom.ppb;
  const f = await frames(["clipBlock", "trackRowIdentity"]);
  const rects = f.clipBlock ?? [];
  const rows = f.trackRowIdentity ?? [];

  // ══ P — the instrument is actually reading ═════════════════════════════════
  console.log("\n── P: frames are flowing, and they are the clip blocks ──");
  check("P1 one clipBlock rect per clip (an empty dict would fake every leg below)",
        rects.length === STARTS.length,
        `rects=${rects.length} clips=${STARTS.length}`);
  check("P2 …and they really are clip blocks: width == LEN·ppb for all of them",
        rects.length > 0 && rects.every((r) => Math.abs(r.width - LEN * ppb) < EPS),
        `ppb=${ppb} expected=${LEN * ppb} widths=[${rects.map((r) => r.width).join(",")}]`);
  check("P3 the SIDEBAR instrument is reading too — one trackRowIdentity per track",
        rows.length === tracks.length,
        `rows=${rows.length} tracks=${tracks.length}`);

  // ══ D — THE DISCRIMINATOR ══════════════════════════════════════════════════
  console.log("\n── D: two things that must differ, do — and by the right amounts ──");
  const origins = new Set(rects.map((r) => `${r.x},${r.y}`));
  check("D1 every clip reports a DISTINCT origin (pre-fix: all three were identical)",
        origins.size === rects.length,
        `distinct=${origins.size}/${rects.length} origins=${JSON.stringify(rects)}`);
  const dx = rects.map((r) => r.x - rects[0].x);
  const wantDX = STARTS.map((b) => (b - STARTS[0]) * ppb);
  check("D2 x tracks the STORE's start beat times the APP's own ppb, exactly",
        dx.every((v, i) => Math.abs(v - wantDX[i]) < EPS),
        `ppb=${ppb} Δx=[${dx.join(",")}] expected=[${wantDX.join(",")}]`);
  const dy = rects.map((r) => r.y - rects[0].y);
  const wantDY = rows.map((r) => r.y - rows[0].y);
  check("D3 y tracks the SIDEBAR's own row pitch — an instrument this defect never touched",
        rows.length === rects.length && dy.every((v, i) => Math.abs(v - wantDY[i]) < EPS),
        `Δy=[${dy.join(",")}] sidebar Δy=[${wantDY.join(",")}]`);
  check("D4 …and the pitch is not zero — D3 would be vacuous on a one-row ladder",
        wantDY.length > 1 && Math.abs(wantDY[wantDY.length - 1]) > 1,
        `sidebar Δy=[${wantDY.join(",")}] rowHeight=${zoom.rowHeight}`);

  // ══ Z — live geometry, not a mount-time snapshot ═══════════════════════════
  console.log("\n── Z: the report follows a zoom change ──");
  await req("debug.arrangeZoom", { ppb: 32 });
  await sleep(500);
  const z2 = await req("debug.arrangeZoom", {});
  const rects2 = (await frames(["clipBlock"])).clipBlock ?? [];
  const dx2 = rects2.map((r) => r.x - rects2[0].x);
  const wantDX2 = STARTS.map((b) => (b - STARTS[0]) * z2.ppb);
  check("Z1 at a new zoom the x offsets are re-derived from the NEW ppb",
        rects2.length === rects.length && dx2.every((v, i) => Math.abs(v - wantDX2[i]) < EPS),
        `ppb ${ppb} -> ${z2.ppb}  Δx=[${dx2.join(",")}] expected=[${wantDX2.join(",")}]`);
  check("Z2 …and the zoom really changed (Z1 is vacuous if ppb did not move)",
        z2.ppb !== ppb,
        `ppb ${ppb} -> ${z2.ppb}`);
  await req("debug.arrangeZoom", { reset: true });
  await sleep(400);

  // ══ G — THE DRAG GHOST, which is what m25-l-2 needs ════════════════════════
  console.log("\n── G: mid-drag the rect follows the GHOST, while the store stays put ──");
  const z3 = await req("debug.arrangeZoom", {});
  const before = (await frames(["clipBlock"])).clipBlock ?? [];
  await req("debug.arrangeSelection", { act: "click", clipId: clipIDs[0] });
  const GHOST_BEATS = 4;
  const drag = await req("debug.arrangeDrag",
    { clipId: clipIDs[0], deltaBeats: GHOST_BEATS, phase: "move", snap: "bar" });
  await sleep(400);
  const during = (await frames(["clipBlock"])).clipBlock ?? [];
  const storeStart = drag.starts?.[clipIDs[0]];
  check("G1 the store has NOT moved the clip (the ghost is a preview, m25-k)",
        Math.abs((storeStart ?? -1) - STARTS[0]) < 1e-9,
        `store startBeat=${storeStart} expected=${STARTS[0]}`);
  check("G2 …but the reported rect moved by exactly the ghost distance",
        during.length === before.length
          && Math.abs((during[0].x - before[0].x) - GHOST_BEATS * z3.ppb) < EPS,
        `Δx=${during.length ? during[0].x - before[0].x : "n/a"} `
        + `expected=${GHOST_BEATS * z3.ppb} (ppb=${z3.ppb})`);
  check("G3 …and the clips NOT being dragged did not move",
        during.length === before.length
          && during.slice(1).every((r, i) => Math.abs(r.x - before[i + 1].x) < EPS),
        `others Δx=[${during.slice(1).map((r, i) => r.x - before[i + 1].x).join(",")}]`);
  // Put the fixture back so nothing downstream reads a half-dragged arrangement.
  await raw("debug.arrangeDrag", { clipId: clipIDs[0], deltaBeats: 0, phase: "end" });
  await req("debug.explainMode", { on: false });

  skip("that the VERTICAL half of the m25-l-2 ghost follows too",
       "`debug.arrangeDrag` takes only `deltaBeats` — the cross-track row delta is "
       + "computed in the view from the pointer's content Y and has no wire input. "
       + "D3 proves the vertical AXIS is now measured correctly (against the "
       + "sidebar's own pitch), so the ghost's y is now READABLE; whether a "
       + "cross-track drag moves it is m25-l-2's own gate to write.");
  skip("whether the `.crossfade` badge's rect is right",
       "It is placed with `.position` (a real layout modifier) but tagged OUTSIDE "
       + "it, so its `.explainable` may be measuring the parent-filling positioned "
       + "container rather than the badge. Different mechanism, not measured here — "
       + "it needs an overlapping-audio-clip fixture. Filed as a follow-up.");

  verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
} finally {
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
}
