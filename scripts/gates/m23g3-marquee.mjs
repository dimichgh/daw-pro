// m23-g3 GATE — the arrange RUBBER BAND (marquee), against a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves, end to end through the app's own handlers: horizontal correctness
//   (a band includes two clips and excludes a third); THE VERTICAL
//   DISCRIMINATOR — with track 0's automation row expanded, a band computed
//   from the RESOLVED ladder lands on the right track while the uniform-pitch
//   reading lands on a different one (the gate computes BOTH and refuses to run
//   the leg unless the two id sets differ); the shift/union chord; that the
//   band is POSITIVELY VISIBLE mid-drag — asserted twice, once on the reported
//   rect and once in PIXELS (a capture with the band standing differs from the
//   capture at rest, and the capture after release returns to it); negative
//   extents; a zero-area band; and that click-to-seek (m17-c) and
//   double-click-create (m23-e) still work AFTER a marquee, including through
//   the real tap-THEN-drag ordering that a staged seam would otherwise never
//   produce.
//
//   DOES NOT PROVE — stated plainly, because a green leg here looks like proof
//   and is not: that SwiftUI's real gesture ARBITRATION still routes a physical
//   mouse tap to the two `onTapGesture` handlers now that a
//   `.simultaneousGesture(DragGesture)` shares the surface. The staged pointer
//   seam calls `handleEmptyClick`/`handleDoubleClick` DIRECTLY, so every leg
//   below proves the handlers are reachable and correct, not that a real click
//   reaches them. A real mouse drag is not injectable either (`DragGesture.Value`
//   has no public initializer, and the unbundled staging binary has no
//   Accessibility grant — the m17-b measurement). Leg R4 attempts the strongest
//   available substitute (a synthesized NSEvent through the real responder
//   chain, the `keyDelete` precedent) and reports its outcome honestly either
//   way. This is a STATED COVERAGE GAP, not a passing leg.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW —
// derive it from values the gate controls or READS, never discover it by trial):
//   The ladder is NOT a constant. `rowHeight` is user-adjustable (beta m10-d)
//   and an expanded automation row adds 64 pt, so EVERY y below is derived from
//   `debug.arrangeMarquee {}`'s echoed `laneTops` + `rowHeight`. The uniform
//   PITCH the rejected implementation would use is likewise MEASURED, from the
//   ladder BEFORE anything is expanded (where tops[1]-tops[0] == rowHeight +
//   laneSpacing by construction).
//   Every x is `beats * ppb` with `ppb` read from the same echo.
//   Clips (all length 2 or 4 beats, none overlapping, so `clip.addMIDI` never
//   trims one on the way in — the m23-g1 lesson):
//     T0: A0 @0 len4          T1: B0 @0 len2, B4 @4 len2, B10 @10 len2
//     T2: C0 @0 len4          T3: D0 @0 len4
//   Horizontal band: beats [3, 11.5] — begins in the GAP between B0 and B4
//   (empty space, as a real press must be), overlaps B4 [4,6) and B10 [10,12),
//   and stops 1 beat clear of B0 [0,2).
//   Ladder band: beats [1, 6] on track 2's row — C0 is [0,4), so 1 < 4 hits.
//   Empty band (the pixel leg): beats [30, 40] on track 2's row — past every
//   clip, so it touches nothing and the ONLY thing that changes on screen is
//   the band itself.
//
// Setup: none — run it.
//
//   swift build && node scripts/gates/m23g3-marquee.mjs
import fs from "fs";
import crypto from "crypto";
import { spawn } from "child_process";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23G3_OUT || "/tmp/m23g3";
const PIDFILE = process.env.M23G3_PIDFILE || "/tmp/m23g3-staging.pid";
const BINARY = process.env.M23G3_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23G3_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE_MS = 250;

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

// ── launch staging (pidfile-exact teardown of any previous run) ─────────────
if (fs.existsSync(PIDFILE)) {
  const oldPid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  if (Number.isFinite(oldPid) && oldPid > 1) {
    try { process.kill(oldPid); } catch {}      // pidfile-EXACT; never pkill/pgrep
    await sleep(1500);
  }
}
const log = fs.openSync(`${OUT}/staging.log`, "a");
const child = spawn(BINARY, [], {
  cwd: REPO, detached: true, stdio: ["ignore", log, log],
  env: { ...process.env, DAW_CONTROL_PORT: PORT },
});
child.unref();
fs.writeFileSync(PIDFILE, String(child.pid));
console.log(`staging pid ${child.pid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;
const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const sortIds = (a) => [...a].sort();

const mq = (p = {}) => req("debug.arrangeMarquee", p);
const sel = (p = {}) => req("debug.arrangeSelection", p);
const ptr = (p = {}) => req("debug.arrangePointer", p);
const shaOf = (path) => crypto.createHash("sha256").update(fs.readFileSync(path)).digest("hex").slice(0, 16);
async function capture(tag) {
  const p = `${OUT}/${tag}.png`;
  const r = await req("debug.captureUI", { path: p });
  return { sha: shaOf(p), dims: `${r.width}x${r.height}` };
}

/** The gate's OWN independent band→ids implementation. Never the app's. */
function expectHits(tops, rowHeight, ppb, band, clipsByLane) {
  const out = [];
  const y0 = Math.min(band.y0, band.y1), y1 = Math.max(band.y0, band.y1);
  const b0 = Math.min(band.b0, band.b1), b1 = Math.max(band.b0, band.b1);
  if (y1 - y0 <= 0 || b1 - b0 <= 0) return [];
  for (let i = 0; i < tops.length; i++) {
    if (!(y0 < tops[i] + rowHeight && tops[i] < y1)) continue;
    for (const c of clipsByLane[i] ?? []) {
      if (b0 * ppb < (c.start + c.len) * ppb && c.start * ppb < b1 * ppb) out.push(c.id);
    }
  }
  return sortIds(out);
}

/** Runs a full begin→changed→end marquee in CONTENT points. Returns the echoes. */
async function sweep(band, { additive = false } = {}) {
  const begin = await mq({ act: "begin", x: band.x0, y: band.y0, shift: additive });
  const mid = await mq({ act: "changed", x: band.x1, y: band.y1 });
  const end = await mq({ act: "end", x: band.x1, y: band.y1 });
  return { begin, mid, end };
}

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await req("debug.arrangeZoom", { reset: true });
  const T = [];
  for (const n of ["G3a", "G3b", "G3c", "G3d"]) {
    T.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  const add = async (t, beat, len) => (await req("clip.addMIDI", {
    trackId: T[t], atBeat: beat, lengthBeats: len,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const A0 = await add(0, 0, 4);
  const B0 = await add(1, 0, 2), B4 = await add(1, 4, 2), B10 = await add(1, 10, 2);
  const C0 = await add(2, 0, 4);
  const D0 = await add(3, 0, 4);
  await sleep(SETTLE_MS);

  // ── The BARE read: the m11-a law, and the only legal source of the ladder.
  const flat = await mq({});
  check("F1 a BARE debug.arrangeMarquee is read-only and answers the LADDER",
        Array.isArray(flat.laneTops) && flat.laneTops.length === 4
          && flat.rowHeight > 0 && flat.ppb > 0 && flat.bandRect === null,
        `laneTops=${JSON.stringify(flat.laneTops)} rowHeight=${flat.rowHeight} ppb=${flat.ppb} band=${flat.bandRect}`);

  const ROW = flat.rowHeight, PPB = flat.ppb;
  // The uniform PITCH the rejected implementation would use, MEASURED from the
  // unexpanded ladder (where it is exactly rowHeight + laneSpacing).
  const PITCH = flat.laneTops[1] - flat.laneTops[0];
  check("F2 the UNEXPANDED ladder is a clean arithmetic progression (pitch measured, not assumed)",
        flat.laneTops.every((t, i) => near(t, flat.laneTops[0] + i * PITCH)) && PITCH > ROW,
        `pitch=${PITCH} rowHeight=${ROW} tops=${JSON.stringify(flat.laneTops)}`);

  const ov0 = await req("project.overview", {});
  const beats = new Map();
  for (const t of ov0.tracks) for (const c of t.clips) beats.set(c.id, [c.startBeat, c.lengthBeats]);
  check("F3 all six clips landed at the exact beats the arithmetic assumes",
        near(beats.get(A0)[0], 0) && near(beats.get(A0)[1], 4)
          && near(beats.get(B0)[0], 0) && near(beats.get(B4)[0], 4) && near(beats.get(B10)[0], 10)
          && near(beats.get(B0)[1], 2) && near(beats.get(B4)[1], 2) && near(beats.get(B10)[1], 2)
          && near(beats.get(C0)[0], 0) && near(beats.get(D0)[0], 0),
        [...beats.values()].map((v) => v.join("/")).join(" "));
  check("F4 nothing is selected yet (non-vacuity)",
        (await sel({})).count === 0, "count=0");

  const CLIPS = [
    [{ id: A0, start: 0, len: 4 }],
    [{ id: B0, start: 0, len: 2 }, { id: B4, start: 4, len: 2 }, { id: B10, start: 10, len: 2 }],
    [{ id: C0, start: 0, len: 4 }],
    [{ id: D0, start: 0, len: 4 }],
  ];
  /** A band in BEATS × lane index → the content points the seam takes. */
  const bandOn = (lane, tops, b0, b1, { pad = Math.min(6, ROW / 4) } = {}) => ({
    x0: b0 * PPB, x1: b1 * PPB,
    y0: tops[lane] + pad, y1: tops[lane] + ROW - pad,
    b0, b1, lane,
  });

  // ══ H  HORIZONTAL CORRECTNESS ════════════════════════════════════════════
  {
    const tops = (await mq({})).laneTops;
    const band = bandOn(1, tops, 3, 11.5);
    const want = expectHits(tops, ROW, PPB, band, CLIPS);
    check("H0 fixture: the band is computed to include exactly two of three clips",
          want.length === 2 && want.includes(B4) && want.includes(B10) && !want.includes(B0),
          `want=${want.map((i) => i.slice(0, 4)).join(",")}`);
    const r = await sweep(band);
    check("H1 a band across empty space selects exactly the clips it touches",
          same(sortIds(r.end.selectedIds), want),
          `got=${sortIds(r.end.selectedIds).map((i) => i.slice(0, 4)).join(",")} want=${want.map((i) => i.slice(0, 4)).join(",")}`);
    check("H2 the excluded clip is genuinely excluded — B0 sits 1 beat clear of the band",
          !r.end.selectedIds.includes(B0), `B0=${B0.slice(0, 4)} not selected`);
    check("H3 hitIds and selectedIds agree on a PLAIN band (no base to union)",
          same(sortIds(r.end.hitIds), want), `hitIds=${sortIds(r.end.hitIds).length}`);
    check("H4 a marquee does NOT open the note editor (selecting is not opening)",
          r.end.focusId === null && r.end.editorClipId === null,
          `focusId=${r.end.focusId} editorClipId=${r.end.editorClipId}`);
  }

  // ══ V  THE VERTICAL DISCRIMINATOR — the non-uniform ladder ════════════════
  {
    await req("ui.showAutomation", { trackId: T[0] });
    await sleep(SETTLE_MS);
    const g = await mq({});
    const tops = g.laneTops;
    check("V0 the automation row actually expanded — the ladder is now NON-UNIFORM",
          !near(tops[1] - tops[0], tops[2] - tops[1]) && tops[1] - tops[0] > PITCH,
          `tops=${JSON.stringify(tops)} gaps=${tops.slice(1).map((t, i) => t - tops[i]).join(",")}`);

    const band = bandOn(2, tops, 1, 6);
    const uniformTops = tops.map((_, i) => tops[0] + i * PITCH);
    const wantReal = expectHits(tops, ROW, PPB, band, CLIPS);
    const wantUniform = expectHits(uniformTops, ROW, PPB, band, CLIPS);
    check("V1 VALIDITY: the fixture can tell the real ladder from the uniform one",
          wantReal.length > 0 && wantUniform.length > 0 && !same(wantReal, wantUniform),
          `real=${wantReal.map((i) => i.slice(0, 4)).join(",")} uniform=${wantUniform.map((i) => i.slice(0, 4)).join(",")} `
          + `uniformTops=${JSON.stringify(uniformTops)}`);
    check("V2 VALIDITY: the fixture's expectation is track 2's clip, not track 3's",
          same(wantReal, [C0]) && same(wantUniform, [D0]),
          `real=${wantReal[0] === C0 ? "C0" : wantReal[0]} uniform=${wantUniform[0] === D0 ? "D0" : wantUniform[0]}`);

    const r = await sweep(band);
    check("V3 THE DISCRIMINATOR: the band lands on the lane the RESOLVED ladder puts there",
          same(sortIds(r.end.selectedIds), wantReal),
          `got=${sortIds(r.end.selectedIds).map((i) => i.slice(0, 4)).join(",")} realWant=${wantReal.map((i) => i.slice(0, 4)).join(",")}`);
    check("V4 …and NOT where a uniform y/pitch reading would have put it",
          !same(sortIds(r.end.selectedIds), wantUniform),
          `uniformWant=${wantUniform.map((i) => i.slice(0, 4)).join(",")}`);

    // A band spanning the expanded row: track 0's clips + track 1's, nothing
    // else. Beats [1,3]: A0 [0,4) hits, B0 [0,2) hits, B4 [4,6) does NOT
    // (3 < 4), B10 [10,12) does not.
    const spanning = { x0: 1 * PPB, x1: 3 * PPB, y0: tops[0] + 4, y1: tops[1] + 4, b0: 1, b1: 3, lane: 0 };
    const wantSpan = expectHits(tops, ROW, PPB, spanning, CLIPS);
    const uniSpan = expectHits(uniformTops, ROW, PPB, spanning, CLIPS);
    check("V5 VALIDITY: a band crossing the 64 pt automation row also discriminates",
          !same(wantSpan, uniSpan) && same(wantSpan, sortIds([A0, B0])),
          `want=${wantSpan.map((i) => i.slice(0, 4)).join(",")} uniform=${uniSpan.map((i) => i.slice(0, 4)).join(",")}`);
    const rs = await sweep(spanning);
    check("V6 a band crossing an expanded automation row lands on BOTH clip lanes and nothing else",
          same(sortIds(rs.end.selectedIds), wantSpan),
          `got=${sortIds(rs.end.selectedIds).map((i) => i.slice(0, 4)).join(",")}`);
    // NOTE the seam's LIVENESS is already proven: V0 read a DIFFERENT ladder
    // from the same command after the expansion. `ui.showAutomation` has no
    // collapse parameter, so the reverse transition is not drivable and the
    // rest of this gate runs with track 0 expanded — which is why every leg
    // below re-reads `laneTops` instead of caching them.
  }

  // ══ S  THE SHIFT CHORD ═══════════════════════════════════════════════════
  {
    const tops = (await mq({})).laneTops;
    const band = bandOn(1, tops, 3, 11.5);
    const want = expectHits(tops, ROW, PPB, band, CLIPS);

    await sel({ act: "click", clipId: A0 });
    const before = await sel({});
    check("S0 fixture: a single pre-drag selection with a FOCUS exists (non-vacuity)",
          before.count === 1 && before.focusClipId === A0,
          `count=${before.count} focus=${before.focusClipId === A0 ? "A0" : before.focusClipId}`);

    const r = await sweep(band, { additive: true });
    check("S1 a SHIFT band UNIONS onto the pre-drag selection",
          same(sortIds(r.end.selectedIds), sortIds([A0, ...want])),
          `got=${sortIds(r.end.selectedIds).length} want=${want.length + 1}`);
    check("S2 the pre-drag FOCUS survives a shift band (never stolen, never flickered)",
          r.end.focusId === A0, `focusId=${r.end.focusId === A0 ? "A0" : r.end.focusId}`);
    check("S3 hitIds is DISTINCT from selectedIds under the chord — the union is observable",
          same(sortIds(r.end.hitIds), want) && r.end.selectedIds.length === want.length + 1,
          `hits=${r.end.hitIds.length} selected=${r.end.selectedIds.length}`);

    // …and the PLAIN band over the same region replaces instead.
    const p = await sweep(band);
    check("S4 the same band WITHOUT the chord replaces — A0 is dropped",
          same(sortIds(p.end.selectedIds), want) && !p.end.selectedIds.includes(A0),
          `got=${sortIds(p.end.selectedIds).length}`);

    // A shift band that shrinks must give a clip back (base is frozen, not live).
    await sel({ act: "clear" });
    await sel({ act: "click", clipId: A0 });
    await mq({ act: "begin", x: band.x0, y: band.y0, shift: true });
    await mq({ act: "changed", x: band.x1, y: band.y1 });
    const wide = await mq({});
    // Shrink so only B4 [4,6) is covered: beats [3, 7].
    await mq({ act: "changed", x: 7 * PPB, y: band.y1 });
    const narrow = await mq({ act: "end", x: 7 * PPB, y: band.y1 });
    check("S5 a SHRINKING shift band gives a clip back (it re-decides from the frozen base)",
          wide.selectedIds.length === 3 && same(sortIds(narrow.selectedIds), sortIds([A0, B4])),
          `wide=${wide.selectedIds.length} narrow=${sortIds(narrow.selectedIds).map((i) => i.slice(0, 4)).join(",")}`);
  }

  // ══ N  NEGATIVE EXTENTS ══════════════════════════════════════════════════
  {
    const tops = (await mq({})).laneTops;
    const fwd = bandOn(1, tops, 3, 11.5);
    const want = expectHits(tops, ROW, PPB, fwd, CLIPS);
    await sel({ act: "clear" });
    const rf = await sweep(fwd);

    // Right-to-left AND bottom-to-top: the same two corners, swept backwards.
    await sel({ act: "clear" });
    const rev = { x0: fwd.x1, y0: fwd.y1, x1: fwd.x0, y1: fwd.y0 };
    const begin = await mq({ act: "begin", x: rev.x0, y: rev.y0 });
    const mid = await mq({ act: "changed", x: rev.x1, y: rev.y1 });
    const end = await mq({ act: "end", x: rev.x1, y: rev.y1 });
    check("N1 a band dragged RIGHT-TO-LEFT and BOTTOM-TO-TOP selects the same clips",
          same(sortIds(end.selectedIds), want) && same(sortIds(end.selectedIds), sortIds(rf.end.selectedIds)),
          `reverse=${sortIds(end.selectedIds).map((i) => i.slice(0, 4)).join(",")}`);
    check("N2 the reported rect is NORMALIZED — positive extents, origin at the min corner",
          mid.bandRect && mid.bandRect.width > 0 && mid.bandRect.height > 0
            && near(mid.bandRect.x, Math.min(rev.x0, rev.x1))
            && near(mid.bandRect.y, Math.min(rev.y0, rev.y1))
            && near(mid.bandRect.width, Math.abs(rev.x1 - rev.x0))
            && near(mid.bandRect.height, Math.abs(rev.y1 - rev.y0)),
          `rect=${JSON.stringify(mid.bandRect)}`);
    check("N3 the band at BEGIN is degenerate (the seam really is phased, not one-shot)",
          begin.bandRect && near(begin.bandRect.width, 0) && near(begin.bandRect.height, 0),
          `beginRect=${JSON.stringify(begin.bandRect)}`);
  }

  // ══ Z  ZERO-AREA BAND ════════════════════════════════════════════════════
  {
    const tops = (await mq({})).laneTops;
    await sel({ act: "clear" });
    await sel({ act: "click", clipId: B4 });
    check("Z0 fixture: something IS selected, so a clear is observable (non-vacuity)",
          (await sel({})).count === 1, "count=1");
    const x = 5 * PPB, y = tops[1] + ROW / 2;    // squarely INSIDE clip B4
    await mq({ act: "begin", x, y });
    const mid = await mq({ act: "changed", x, y });
    const end = await mq({ act: "end", x, y });
    check("Z1 a zero-area band selects NOTHING, even with its point inside a clip",
          end.selectedIds.length === 0 && end.hitIds.length === 0,
          `selected=${end.selectedIds.length} hits=${end.hitIds.length}`);
    check("Z2 …and its reported rect has zero extent throughout",
          mid.bandRect && near(mid.bandRect.width, 0) && near(mid.bandRect.height, 0),
          `rect=${JSON.stringify(mid.bandRect)}`);
  }

  // ══ B  THE BAND IS VISIBLE MID-DRAG — reported AND in pixels ═════════════
  {
    const tops = (await mq({})).laneTops;
    await sel({ act: "clear" });
    // A band over EMPTY space, past every clip: it touches nothing, so the ONLY
    // thing that can change on screen between the captures is the band itself.
    const band = bandOn(2, tops, 30, 40);
    check("B0 fixture: this band touches NO clip, so the pixel legs isolate the band alone",
          expectHits(tops, ROW, PPB, band, CLIPS).length === 0
            && (await sel({})).count === 0,
          "hits=0 selected=0");

    // A STABLE resting image is the control the whole pixel argument rests on.
    // It is retried, because the window is not perfectly static (the transport
    // meters redraw continuously) and a single unlucky pair used to make the
    // pixel legs SKIP — which is how an early calibration run passed a build
    // whose band was never drawn at all. A skip here is therefore NOT allowed:
    // if no stable image can be established, B2 FAILS, because the
    // band-is-DRAWN claim would otherwise rest on the reported rect alone, and
    // calibration proved the reported rect survives deleting the visual.
    let rest = await capture("B-rest0");
    let stable = false, tries = 0;
    for (tries = 1; tries <= 8; tries++) {
      await sleep(120);
      const again = await capture(`B-rest${tries}`);
      if (again.sha === rest.sha) { stable = true; break; }
      rest = again;
    }
    if (!stable) {
      check("B2 PIXELS: a stable resting image could be established", false,
            `8 consecutive capture pairs all differed — the band-is-DRAWN claim CANNOT be `
            + "proven in pixels, and the reported rect alone does not prove it (a build with "
            + "the visual deleted still reports the rect). Treat this as unproven, not passed.");
    }

    await mq({ act: "begin", x: band.x0, y: band.y0 });
    const mid = await mq({ act: "changed", x: band.x1, y: band.y1 });
    check("B1 the band is POSITIVELY reported mid-drag, with the expected geometry",
          mid.bandRect
            && near(mid.bandRect.x, Math.min(band.x0, band.x1))
            && near(mid.bandRect.y, Math.min(band.y0, band.y1))
            && near(mid.bandRect.width, Math.abs(band.x1 - band.x0))
            && near(mid.bandRect.height, Math.abs(band.y1 - band.y0)),
          `rect=${JSON.stringify(mid.bandRect)} expected=`
          + `${Math.min(band.x0, band.x1)},${Math.min(band.y0, band.y1)},`
          + `${Math.abs(band.x1 - band.x0)},${Math.abs(band.y1 - band.y0)}`);

    let drawn = null;
    if (stable) {
      // The band image must ALSO be stable, and that is not pedantry: without
      // it "differs from rest" could be explained by the window's own jitter
      // rather than by the band. Two consecutive identical captures that both
      // differ from a twice-confirmed resting image cannot be jitter.
      drawn = await capture("B-band0");
      let bandStable = false;
      for (let i = 1; i <= 8; i++) {
        await sleep(120);
        const again = await capture(`B-band${i}`);
        if (again.sha === drawn.sha) { bandStable = true; break; }
        drawn = again;
      }
      check("B2 PIXELS: the window with the band standing is STABLE and DIFFERS from the resting image",
            bandStable && drawn.sha !== rest.sha && drawn.dims === rest.dims,
            `rest=${rest.sha} band=${drawn.sha} stable=${bandStable} dims=${drawn.dims}`);
    }

    const end = await mq({ act: "end", x: band.x1, y: band.y1 });
    check("B3 the band is GONE after release, and the selection is unchanged",
          end.bandRect === null && end.selectedIds.length === 0,
          `band=${end.bandRect} selected=${end.selectedIds.length}`);
    if (stable) {
      let after = await capture("B-after0"), matched = after.sha === rest.sha;
      for (let i = 1; !matched && i <= 8; i++) {
        await sleep(120);
        after = await capture(`B-after${i}`);
        matched = after.sha === rest.sha;
      }
      check("B4 PIXELS: the window after release returns EXACTLY to the resting image",
            matched, `rest=${rest.sha} after=${after.sha} (band capture was ${drawn.sha})`);
    }
  }

  // ══ R  THE REGRESSIONS THIS CHANGE ACTUALLY THREATENS ════════════════════
  {
    const tops = (await mq({})).laneTops;
    const y = tops[2] + ROW / 2;

    // R1 — click-to-seek (m17-c #3), AFTER a marquee has run on this surface.
    await req("transport.seek", { beats: 0 });
    const before = await ptr({});
    const seekX = 12 * PPB;                       // beat 12 is on the bar grid
    const clicked = await ptr({ act: "click", x: seekX, y });
    check("R1 click-to-seek still works after the marquee landed",
          near(before.playheadBeat, 0) && near(clicked.playheadBeat, 12),
          `before=${before.playheadBeat} after=${clicked.playheadBeat}`);

    // R2 — double-click-create (m23-e), likewise after a marquee.
    const dbl = await ptr({ act: "doubleClick", x: 20 * PPB, y });
    check("R2 double-click-create still works after the marquee landed",
          typeof dbl.createdClipId === "string" && dbl.createdClipId.length > 0
            && dbl.editorClipId === dbl.createdClipId && dbl.refusal === null,
          `created=${dbl.createdClipId} editor=${dbl.editorClipId} refusal=${dbl.refusal}`);

    // R3 — THE ORDERING LEG (STAGED-GATE LAW). A real double-click's first tap
    // SEEKS the playhead onto the point, which flips that point's zone to
    // `.playheadGrab` (the m23-e defect class). Reproduce that ordering: click
    // FIRST, then start a band from the very same point. A marquee carrying a
    // zone guard would be refused here and pass every other leg in this file.
    // gx MUST be on the bar grid: `handleEmptyClick` seeks to the SNAPPED beat,
    // so a click at beat 6 lands the playhead on 8 and the band's origin would
    // NOT be at the playhead — the trap would never arm and the leg would pass
    // vacuously. Beat 8 snaps to itself.
    // …and the band must sweep real AREA: an earlier draft dragged to the same
    // y, producing a zero-HEIGHT band that correctly selected nothing and made
    // the leg fail for the gate's arithmetic rather than the app's behaviour
    // (FIXTURE LAW, caught by running it).
    await sel({ act: "clear" });
    const gx = 8 * PPB, gy = tops[2] + 6, gyEnd = tops[2] + ROW - 6;
    const seeked = await ptr({ act: "click", x: gx, y: gy });
    const zone = await ptr({ act: "hover", x: gx, y: gy });
    await mq({ act: "begin", x: gx, y: gy });
    const gmid = await mq({ act: "changed", x: 1 * PPB, y: gyEnd });
    const gend = await mq({ act: "end", x: 1 * PPB, y: gyEnd });
    check("R3a fixture: the click really did move the playhead ONTO the band's origin",
          near(seeked.playheadBeat, 8), `playhead=${seeked.playheadBeat}`);
    check("R3b fixture: that point now classifies as playhead-grab (the m23-e trap is ARMED)",
          zone.zone === "playhead-grab",
          `zone=${zone.zone} — if this is not "playhead-grab" the leg is VACUOUS`);
    check("R3c a band started on a just-seeked point still arms and selects (no zone guard)",
          gmid.bandRect !== null && gend.selectedIds.includes(C0),
          `midRect=${JSON.stringify(gmid.bandRect)} selected=${gend.selectedIds.length}`);
  }

  // ══ summary ══════════════════════════════════════════════════════════════
  const bad = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - bad.length}/${checks.length} legs passed`
    + (skips.length ? `, ${skips.length} skipped` : ""));
  for (const s of skips) console.log(`  SKIP ${s.name}: ${s.why}`);
  if (bad.length) { for (const b of bad) console.log(`  FAIL ${b.name}: ${b.detail}`); }
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  const pid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  if (Number.isFinite(pid) && pid > 1) { try { process.kill(pid); } catch {} }
  process.exit(bad.length ? 1 : 0);
} catch (e) {
  console.error("GATE ERROR", e);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips, error: String(e) }, null, 2));
  clearTimeout(killer);
  try { ws.close(); } catch {}
  const pid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  if (Number.isFinite(pid) && pid > 1) { try { process.kill(pid); } catch {} }
  process.exit(2);
}
