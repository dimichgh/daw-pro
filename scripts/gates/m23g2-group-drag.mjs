// m23-g2 GATE — group DRAG preserving relative offsets, against a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves, end to end through the app's own handler: that a group drag snaps
//   ONCE on the anchor and translates rigidly (the sub-grid-phase leg, which a
//   per-clip-snap implementation fails); that the beat-0 clamp is WHOLE-GROUP;
//   that a NON-CONTIGUOUS selection leaves the innocent clip between the movers
//   untouched (the data-loss hazard); that the grab rule collapses onto an
//   unselected clip; that a group move is ONE undo step. `debug.arrangeDrag`
//   runs the SAME `AppModel.dragArrangeClips` the ClipBlock body drag runs, so
//   the seam cannot drift from the gesture.
//   Every geometric assertion reads `project.overview` — the STORE's own state
//   — never the seam's echo. Undo depth comes from `edit.history`.
//   Does NOT prove: that SwiftUI delivers a real `DragGesture` translation
//   correctly (no seam can — `DragGesture.Value` has no public initializer);
//   that a comp-member refusal surfaces (a take group needs ≥2 OVERLAPPING
//   clips, which `clip.addMIDI` cannot build because it routes through
//   `resolvingOverlaps` — the m23-g1 unbuildable-fixture law; covered by
//   `ClipGroupMoveTests` leg 18 instead, and recorded below as a SKIP).
//
// FIXTURE ARITHMETIC, computed before any assertion was written (FIXTURE LAW —
// derive it from values the gate controls, never discover it by trial):
//   snap = bar, 4/4  =>  grid 4 beats,  snap(b) = max(0, round(b/4)*4)
//   anchor at 0, raw delta r  =>  snapped = round(r/4)*4, which is 4 for
//   r in [2, 6). RAW = 3.4 is used everywhere a +4 move is wanted; 1.6 would
//   snap to 0 and make every downstream check vacuously true.
//   Clips are 2 beats long so a pair at 0 and 2.5 does NOT overlap on add
//   ([0,2) and [2.5,4.5)) and therefore is not trimmed before the drag.
//
// Setup: none — run it.
//
//   node scripts/gates/m23g2-group-drag.mjs
//
// (m23-ac-2a) This line used to read `swift build && node …`. A usage comment
// is not a build step, and the original m23-ac filing read exactly this comment
// as evidence the gate built first. `buildOrAbort()` below does the real thing.
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23g2";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23G2_OUT || "/tmp/m23g2";
const PIDFILE = process.env.M23G2_PIDFILE || "/tmp/m23g2-staging.pid";
const BINARY = process.env.M23G2_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23G2_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const GRID = 4;            // bar grid in 4/4
const RAW_PLUS4 = 3.4;     // snaps to +4 (see arithmetic above)
const LEN = 2;             // clip length in beats
const SETTLE_MS = 250;
// The undo journal's same-key coalescing window is 800 ms. Two logically
// SEPARATE drags of the SAME selection inside it fold into one entry — correct
// behaviour, and a trap for a gate that then counts entries. Anywhere this gate
// wants two countable entries it either changes the selection (which changes
// the key) or waits this out.
const COALESCE_MS = 900;

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

// ── launch staging through the ONE home (m23-ac-2a) ─────────────────────────
// `buildOrAbort` is the half this gate never had: before this it ran whatever
// was compiled last. `startStaging` keeps the pidfile-exact teardown of a
// previous run and refuses port 17600 in ONE place. Every M23G2_* override is
// preserved — they let the gate be pointed at a bundle, which is deliberate.
buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const notes = [];
const note = (name, detail) => { notes.push({ name, detail }); console.log(`  ..  ${name}\n        ${detail}`); };
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const near = (a, b, eps = 1e-9) => typeof a === "number" && Math.abs(a - b) < eps;

const sel = (p = {}) => req("debug.arrangeSelection", p);
const drag = (p = {}) => req("debug.arrangeDrag", p);
const overview = () => req("project.overview", {});
const history = () => req("edit.history", {});
/** START BEAT FROM THE STORE — never from the seam echo. */
async function starts(ids) {
  const ov = await overview();
  const all = new Map();
  for (const t of ov.tracks) for (const c of t.clips) all.set(c.id, c);
  return ids.map((id) => all.get(id));
}

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  const trackIDs = [];
  for (const n of ["G2a", "G2b", "G2c", "G2d"]) {
    trackIDs.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  const add = async (t, beat) => (await req("clip.addMIDI", {
    trackId: trackIDs[t], atBeat: beat, lengthBeats: LEN,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;

  // A: the sub-grid-phase pair (on the grid + deliberately off it).
  const A0 = await add(0, 0), A25 = await add(0, 2.5);
  // B: the non-contiguous trio — the middle one is the innocent bystander.
  const B0 = await add(1, 0), B8 = await add(1, 8), B16 = await add(1, 16);
  // C: the clamp pair.
  const C15 = await add(2, 1.5), C6 = await add(2, 6);
  // D: the grab-rule victim (never selected until it is grabbed).
  const D12 = await add(3, 12);
  await sleep(SETTLE_MS);

  const e0 = await drag({ snap: "bar" });
  check("F1 fixture: the arrange grid in force is BAR (picker AND effective)",
        e0.snap === "bar" && e0.effectiveSnap === "bar",
        `snap=${e0.snap} effectiveSnap=${e0.effectiveSnap}`);
  const f = await starts([A0, A25, B0, B8, B16, C15, C6, D12]);
  check("F2 fixture: all eight clips landed at the exact beats the arithmetic assumes",
        f.every((c) => c && near(c.lengthBeats, LEN))
          && [0, 2.5, 0, 8, 16, 1.5, 6, 12].every((b, i) => near(f[i].startBeat, b)),
        f.map((c) => c && c.startBeat).join(","));
  check("F3 fixture: nothing is selected yet (non-vacuity)",
        (await sel({})).count === 0, "count=0");

  // ══ P1  THE HEADLINE DISCRIMINATOR — sub-grid phase survives ═════════════
  await sel({ act: "click", clipId: A0 });
  let s = await sel({ act: "click", clipId: A25, shift: true });
  check("P1a two clips at DIFFERENT sub-grid phases (0 and 2.5) are selected",
        s.count === 2, JSON.stringify(s.selectedIds.length));

  let depthBefore = (await history()).undo.length;
  let e = await drag({ clipId: A0, deltaBeats: RAW_PLUS4 });
  let a = await starts([A0, A25]);
  check("P1b the ANCHOR snapped to the barline (raw 3.4 -> +4)",
        near(a[0].startBeat, 4) && near(e.effectiveDeltaBeats, 4) && !e.clamped,
        `anchor=${a[0].startBeat} effDelta=${e.effectiveDeltaBeats} clamped=${e.clamped}`);
  check("P1c THE 2.5-BEAT GAP SURVIVED — a per-clip snap would have welded both onto 4",
        near(a[1].startBeat, 6.5) && near(a[1].startBeat - a[0].startBeat, 2.5),
        `starts=${a[0].startBeat},${a[1].startBeat} gap=${a[1].startBeat - a[0].startBeat}`);
  check("P1d neither clip was trimmed or removed by the move",
        e.trimmedIds.length === 0 && e.removedIds.length === 0
          && near(a[0].lengthBeats, LEN) && near(a[1].lengthBeats, LEN),
        `trimmed=${JSON.stringify(e.trimmedIds)} removed=${JSON.stringify(e.removedIds)}`);
  check("P1e a 2-clip move is ONE undo step, labelled countably",
        (await history()).undo.length - depthBefore === 1
          && (await history()).undo[0] === "Move 2 Clips",
        `depth+${(await history()).undo.length - depthBefore} label="${(await history()).undo[0]}"`);
  check("P1f a move does NOT disturb the selection",
        (await sel({})).count === 2, `count=${(await sel({})).count}`);

  // The anchor is the clip UNDER THE POINTER: grabbing the OFF-GRID one snaps
  // IT to the grid and the on-grid one goes off it — the same rigid rule,
  // observed from the other side. (Selection unchanged, so this coalesces with
  // the previous entry; that is asserted, not worked around.)
  // Arithmetic: the pair now sits at 4 and 6.5. Anchoring on 6.5 with raw 3.4
  // gives snap(9.9) = round(2.475)*4 = 8, i.e. a delta of +1.5 — so the ANCHOR
  // lands on the barline and the on-grid one is pushed OFF it. (An earlier
  // draft expected 12/9.5, having forgotten that P1b already moved the pair.)
  e = await drag({ clipId: A25, deltaBeats: RAW_PLUS4 });
  a = await starts([A0, A25]);
  check("P1g anchoring on the OFF-GRID clip snaps THAT one and keeps the gap",
        near(a[1].startBeat, 8) && near(a[0].startBeat, 5.5)
          && near(a[1].startBeat - a[0].startBeat, 2.5) && a[0].startBeat % GRID !== 0,
        `starts=${a[0].startBeat},${a[1].startBeat} gap=${a[1].startBeat - a[0].startBeat}`);

  // ══ P2  NON-CONTIGUOUS DATA-LOSS GUARD ═══════════════════════════════════
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: B0 });
  s = await sel({ act: "click", clipId: B16, shift: true });
  check("P2a the OUTER two of three same-track clips are selected, the middle is not",
        s.count === 2 && s.selectedIds.includes(B0) && s.selectedIds.includes(B16)
          && !s.selectedIds.includes(B8), JSON.stringify(s.selectedIds));

  const innocentBefore = (await starts([B8]))[0];
  e = await drag({ clipId: B0, deltaBeats: RAW_PLUS4 });
  const b = await starts([B0, B8, B16]);
  check("P2b both movers translated by the same +4",
        near(b[0].startBeat, 4) && near(b[2].startBeat, 20),
        `movers=${b[0].startBeat},${b[2].startBeat}`);
  check("P2c THE INNOCENT CLIP BETWEEN THEM IS UNTOUCHED — start, length AND notes",
        near(b[1].startBeat, innocentBefore.startBeat)
          && near(b[1].lengthBeats, innocentBefore.lengthBeats)
          && (b[1].noteCount ?? b[1].notes?.length ?? null)
             === (innocentBefore.noteCount ?? innocentBefore.notes?.length ?? null),
        `before=${JSON.stringify({ s: innocentBefore.startBeat, l: innocentBefore.lengthBeats })} `
        + `after=${JSON.stringify({ s: b[1].startBeat, l: b[1].lengthBeats })}`);
  check("P2d the store reported no trim and no removal for that move",
        e.trimmedIds.length === 0 && e.removedIds.length === 0,
        `trimmed=${JSON.stringify(e.trimmedIds)} removed=${JSON.stringify(e.removedIds)}`);
  // NON-VACUITY: a union window [4, 22) would have covered [8, 10) entirely, so
  // the leg above had a real way to fail.
  check("P2e non-vacuity: the innocent clip DOES lie inside the movers' union window",
        innocentBefore.startBeat > 4 && innocentBefore.startBeat + innocentBefore.lengthBeats < 22,
        `innocent [${innocentBefore.startBeat}, ${innocentBefore.startBeat + innocentBefore.lengthBeats}) `
        + `inside union [4, 22)`);
  // CONTROL PAIR: a mover that DOES land on it trims it, so P2c is the guard
  // working and not the overlap policy being inert on this track.
  await sleep(COALESCE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: B0 });
  e = await drag({ clipId: B0, deltaBeats: RAW_PLUS4 });
  check("P2f CONTROL: a mover that actually lands on the innocent clip DOES trim it",
        e.trimmedIds.includes(B8) || e.removedIds.includes(B8),
        `mover -> ${(await starts([B0]))[0].startBeat}; trimmed=${JSON.stringify(e.trimmedIds)} `
        + `removed=${JSON.stringify(e.removedIds)}`);

  // ══ P3  WHOLE-GROUP BEAT-0 CLAMP ═════════════════════════════════════════
  await sleep(COALESCE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: C15 });
  await sel({ act: "click", clipId: C6, shift: true });
  depthBefore = (await history()).undo.length;
  // Anchor on the RIGHT clip and shove left: snap(6 - 5) = snap(1) = 0, i.e. a
  // requested -6, of which only -1.5 is available before the leftmost hits 0.
  e = await drag({ clipId: C6, deltaBeats: -5 });
  const c = await starts([C15, C6]);
  check("P3a the clamp fired and said so",
        e.clamped === true && near(e.requestedDeltaBeats, -6) && near(e.effectiveDeltaBeats, -1.5),
        `requested=${e.requestedDeltaBeats} effective=${e.effectiveDeltaBeats} clamped=${e.clamped}`);
  check("P3b the LEFTMOST clip lands on exactly 0",
        near(c[0].startBeat, 0), `leftmost=${c[0].startBeat}`);
  check("P3c OFFSETS WIN OVER SNAP — the 4.5-beat gap survives, anchor OFF the bar grid",
        near(c[1].startBeat, 4.5) && near(c[1].startBeat - c[0].startBeat, 4.5)
          && c[1].startBeat % GRID !== 0,
        `starts=${c[0].startBeat},${c[1].startBeat} gap=${c[1].startBeat - c[0].startBeat}`);
  check("P3d a clamped group at the wall refuses to travel further left",
        await (async () => {
          const again = await drag({ clipId: C6, deltaBeats: -5 });
          const d = await starts([C15, C6]);
          return near(again.effectiveDeltaBeats, 0) && near(d[0].startBeat, 0)
            && near(d[1].startBeat, 4.5);
        })(), "second shove moved nothing");
  check("P3e the whole clamped drag is still ONE undo step",
        (await history()).undo.length - depthBefore === 1,
        `depth+${(await history()).undo.length - depthBefore}`);

  // ══ P4  THE GRAB RULE ════════════════════════════════════════════════════
  await sleep(COALESCE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: C15 });
  s = await sel({ act: "click", clipId: C6, shift: true });
  const cBefore = await starts([C15, C6]);
  check("P4a a two-clip selection is standing on a DIFFERENT track from the grab target",
        s.count === 2 && !s.selectedIds.includes(D12), JSON.stringify(s.selectedIds));
  e = await drag({ clipId: D12, deltaBeats: RAW_PLUS4 });
  const cAfter = await starts([C15, C6, D12]);
  check("P4b grabbing an UNSELECTED clip collapses the selection onto it",
        e.movedIds.length === 1 && e.movedIds[0] === D12
          && (await sel({})).count === 1 && (await sel({})).focusClipId === D12,
        `movedIds=${JSON.stringify(e.movedIds)} selection=${JSON.stringify((await sel({})).selectedIds)}`);
  check("P4c the stale selection was NOT dragged along",
        near(cAfter[0].startBeat, cBefore[0].startBeat)
          && near(cAfter[1].startBeat, cBefore[1].startBeat),
        `C stayed at ${cAfter[0].startBeat},${cAfter[1].startBeat}`);
  check("P4d the grabbed clip itself moved by the snapped +4",
        near(cAfter[2].startBeat, 16), `D=${cAfter[2].startBeat}`);
  check("P4e a ONE-clip drag journals moveClip's label verbatim (no regression)",
        (await history()).undo[0] === "Move 1 Clip" || (await history()).undo[0].startsWith("Move Clip '"),
        `label="${(await history()).undo[0]}"`);

  // ══ P5  UNDO ATOMICITY over THREE clips ══════════════════════════════════
  await sleep(COALESCE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: A0 });
  await sel({ act: "click", clipId: A25, shift: true });
  await sel({ act: "click", clipId: D12, command: true });
  const beforeUndo = await starts([A0, A25, D12]);
  depthBefore = (await history()).undo.length;
  await drag({ clipId: A0, deltaBeats: RAW_PLUS4 });
  await drag({ clipId: A0, deltaBeats: RAW_PLUS4 });
  await drag({ clipId: A0, deltaBeats: RAW_PLUS4 });
  const afterDrag = await starts([A0, A25, D12]);
  check("P5a three successive drags of the SAME selection coalesce to ONE entry",
        (await history()).undo.length - depthBefore === 1
          && (await history()).undo[0] === "Move 3 Clips",
        `depth+${(await history()).undo.length - depthBefore} label="${(await history()).undo[0]}"`);
  // Arithmetic: the anchor starts at 5.5 and each STAGED drag re-anchors from
  // rest, so the three steps are snap(5.5+3.4)=8, snap(8+3.4)=12,
  // snap(12+3.4)=16 — not three equal +4s. What matters is that the anchor ends
  // on a barline and EVERY gap is untouched by all three.
  const gapsBefore = [beforeUndo[1].startBeat - beforeUndo[0].startBeat,
                      beforeUndo[2].startBeat - beforeUndo[0].startBeat];
  const gapsAfter = [afterDrag[1].startBeat - afterDrag[0].startBeat,
                     afterDrag[2].startBeat - afterDrag[0].startBeat];
  check("P5b …and they really did move (non-vacuity), keeping every offset",
        near(afterDrag[0].startBeat, 16) && afterDrag[0].startBeat > beforeUndo[0].startBeat
          && near(gapsBefore[0], gapsAfter[0]) && near(gapsBefore[1], gapsAfter[1]),
        `${beforeUndo.map((c) => c.startBeat).join(",")} -> ${afterDrag.map((c) => c.startBeat).join(",")}`
        + ` gaps ${gapsBefore.join("/")} -> ${gapsAfter.join("/")}`);
  await req("edit.undo", {});
  const afterUndo = await starts([A0, A25, D12]);
  check("P5c ONE undo restores all three, offsets and all",
        [0, 1, 2].every((i) => near(afterUndo[i].startBeat, beforeUndo[i].startBeat)),
        `${afterUndo.map((c) => c.startBeat).join(",")} vs ${beforeUndo.map((c) => c.startBeat).join(",")}`);
  check("P5d the undo consumed exactly the one entry",
        (await history()).undo.length === depthBefore,
        `depth=${(await history()).undo.length} expected ${depthBefore}`);

  // ══ P6  SNAP HONESTY (the m23-c2 echo-and-CHECK corollary) ═══════════════
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  let se = await drag({ snap: "sixteenth" });
  check("P6a Simple LOCKS the effective grid to Bar even though the picker says sixteenth",
        se.snap === "sixteenth" && se.effectiveSnap === "bar",
        `snap=${se.snap} effectiveSnap=${se.effectiveSnap}`);
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  se = await drag({});
  check("P6b CONTROL: Pro honours the picker, so P6a is the lock and not a stuck echo",
        se.snap === "sixteenth" && se.effectiveSnap === "sixteenth",
        `snap=${se.snap} effectiveSnap=${se.effectiveSnap}`);
  // …and the grid the ECHO reports is the grid the DRAG actually applies.
  await sleep(COALESCE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: D12 });
  const dBefore = (await starts([D12]))[0].startBeat;
  e = await drag({ clipId: D12, deltaBeats: 0.1 });
  const dAfter = (await starts([D12]))[0].startBeat;
  // Arithmetic: D sits at 16 (a multiple of 1/16), so snap(16.1) on the 0.0625
  // grid is round(16.1/0.0625)*0.0625 = 258*0.0625 = 16.125 — a 0.125 step, not
  // one grid unit. Nearest-grid rounding, not floor.
  check("P6c the drag applies the grid the echo reports (1/16 grid: 16.1 -> 16.125)",
        near(dAfter - dBefore, 0.125) && near(dAfter % 0.0625, 0),
        `${dBefore} -> ${dAfter} (delta ${dAfter - dBefore})`);
  await drag({ snap: "bar" });

  // ══ P7  ECHO-SEAM LIVENESS ═══════════════════════════════════════════════
  await sleep(COALESCE_MS);
  // Put the anchor back ON the bar grid FIRST. A "zero raw delta" is NOT a zero
  // MOVE when the anchor is off-grid: the gesture snaps the anchor's absolute
  // start, so a hair of translation on an off-grid clip pulls the whole group
  // onto the grid. That is the pre-g2 single-clip behaviour preserved (see
  // `ClipEdit.movedStartBeat`), not a group-move defect — but a control leg
  // that ignored it would have been measuring the wrong thing.
  await drag({ clipId: D12, deltaBeats: RAW_PLUS4 });
  const dGridded = (await starts([D12]))[0].startBeat;
  check("P7z the anchor is now ON the bar grid, so a zero-translation drag is a true no-op",
        near(dGridded % GRID, 0), `D=${dGridded}`);
  await sleep(COALESCE_MS);
  const seqIdle = (await drag({})).renderSeq;
  await sleep(200);
  check("P7a CONTROL: the layout render counter is not free-running",
        (await drag({})).renderSeq === seqIdle, `renderSeq stayed ${seqIdle}`);
  const zeroMove = await drag({ clipId: D12, deltaBeats: 0.0 });
  check("P7b CONTROL: a zero-delta drag mutates nothing and re-renders nothing",
        near(zeroMove.effectiveDeltaBeats, 0) && zeroMove.renderSeq === seqIdle,
        `effDelta=${zeroMove.effectiveDeltaBeats} renderSeq=${zeroMove.renderSeq}`);
  const realMove = await drag({ clipId: D12, deltaBeats: RAW_PLUS4 });
  check("P7c a real move waits for the LANES to re-render before it answers",
        realMove.renderSeq > seqIdle && near(realMove.effectiveDeltaBeats, 4),
        `renderSeq ${seqIdle} -> ${realMove.renderSeq} effDelta=${realMove.effectiveDeltaBeats}`);
  check("P7d the echoed starts agree with the store's own",
        near(realMove.starts[D12], (await starts([D12]))[0].startBeat),
        `echo=${realMove.starts[D12]} store=${(await starts([D12]))[0].startBeat}`);

  // ══ P8  "WAS THIS DRAG REDUCED?" — ANCHOR SYMMETRY (m23-g2 round 2) ══════
  // THE REGRESSION THIS PHASE EXISTS FOR, found in independent verification and
  // measured on a live staging app: `clamped` used to be the STORE's flag
  // alone, which made it anchor-dependent. Clips at 4 and 12, both selected,
  // dragged -10 with snap OFF land at 0 and 8 EITHER WAY — but grabbing the
  // leftmost reported clamped=false (the gesture's own beat-0 floor had already
  // absorbed the reduction, so the store was asked for exactly -4 and honestly
  // saw nothing to clamp) while grabbing the rightmost reported clamped=true.
  // Same geometry, same effective delta, opposite report.
  //
  // TWO IDENTICAL FIXTURES ON TWO TRACKS, not one fixture undone and redone:
  // the two runs stay independent, so neither can contaminate the other's
  // starting positions or undo depth.
  await sleep(COALESCE_MS);
  const symTracks = [];
  for (const n of ["G2e", "G2f", "G2g"]) {
    symTracks.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  const addOn = async (t, beat) => (await req("clip.addMIDI", {
    trackId: symTracks[t], atBeat: beat, lengthBeats: LEN,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const E4 = await addOn(0, 4), E12 = await addOn(0, 12);
  const F4 = await addOn(1, 4), F12 = await addOn(1, 12);
  await sleep(SETTLE_MS);

  // Grab the LEFTMOST. Its landing is 4 - 10 = -6, i.e. BELOW beat 0, so the
  // gesture floor fires and the store never learns the drag wanted more.
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: E4 });
  await sel({ act: "click", clipId: E12, shift: true });
  const grabLeft = await drag({ clipId: E4, deltaBeats: -10, snap: "off" });
  const eStarts = (await starts([E4, E12])).map((c) => c.startBeat);

  await sleep(COALESCE_MS);
  // Grab the RIGHTMOST. Its landing is 12 - 10 = 2, safely above the floor, so
  // the whole reduction happens inside `moveClips`.
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: F4 });
  await sel({ act: "click", clipId: F12, shift: true });
  const grabRight = await drag({ clipId: F12, deltaBeats: -10, snap: "off" });
  const fStarts = (await starts([F4, F12])).map((c) => c.startBeat);

  check("P8a CONTROL: both grabs produce IDENTICAL geometry (read from the store)",
        near(eStarts[0], 0) && near(eStarts[1], 8)
        && near(fStarts[0], 0) && near(fStarts[1], 8),
        `leftGrab=[${eStarts}] rightGrab=[${fStarts}]`);
  check("P8b CONTROL: both grabs produce the same effective delta",
        near(grabLeft.effectiveDeltaBeats, -4) && near(grabRight.effectiveDeltaBeats, -4),
        `left=${grabLeft.effectiveDeltaBeats} right=${grabRight.effectiveDeltaBeats}`);
  // THE ASSERTION. Before the fix this was false/true.
  check("P8c `clamped` is the SAME from either grab — the reported defect",
        grabLeft.clamped === true && grabRight.clamped === true,
        `leftGrab.clamped=${grabLeft.clamped} rightGrab.clamped=${grabRight.clamped}`);
  // And the echo says WHICH stage reduced it, so `requested == effective` on
  // the left grab reads as an explanation rather than a contradiction.
  check("P8d the echo attributes the reduction to the right STAGE",
        grabLeft.gestureFlooredAtZero === true && grabLeft.storeClamped === false
        && grabRight.gestureFlooredAtZero === false && grabRight.storeClamped === true,
        `left(floor=${grabLeft.gestureFlooredAtZero},store=${grabLeft.storeClamped}) `
        + `right(floor=${grabRight.gestureFlooredAtZero},store=${grabRight.storeClamped})`);
  check("P8e neither stage flag alone answers the question (each is false in one run)",
        grabLeft.gestureFlooredAtZero !== grabRight.gestureFlooredAtZero
        && grabLeft.storeClamped !== grabRight.storeClamped,
        `floor ${grabLeft.gestureFlooredAtZero}/${grabRight.gestureFlooredAtZero}, `
        + `store ${grabLeft.storeClamped}/${grabRight.storeClamped}`);

  // OVER-CORRECTION GUARD. The tempting broad predicate — "the landing ended up
  // lower than asked" — would report a clamp for any DOWNWARD SNAP. It must not:
  // one clip at 1.5 dragged -0.5 lands at 1.0 (never negative) and the BAR grid
  // pulls it to 0. Nothing was clamped; the grid did it.
  await sleep(COALESCE_MS);
  const G15 = await addOn(2, 1.5);
  await sleep(SETTLE_MS);
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: G15 });
  const snapDown = await drag({ clipId: G15, deltaBeats: -0.5, snap: "bar" });
  const gStart = (await starts([G15]))[0].startBeat;
  check("P8f a downward SNAP to beat 0 is NOT reported as a clamp",
        near(gStart, 0) && snapDown.clamped === false
        && snapDown.gestureFlooredAtZero === false && snapDown.storeClamped === false,
        `start=${gStart} clamped=${snapDown.clamped} `
        + `floor=${snapDown.gestureFlooredAtZero} store=${snapDown.storeClamped}`);

  // AT THE WALL: a drag that moves nothing must still report the refusal. This
  // is the case that no store-side flag can ever see — the zero-delta guard
  // returns before any clamp is computed.
  await sleep(COALESCE_MS);
  const wallSeq = (await drag({})).renderSeq;
  const wall = await drag({ clipId: G15, deltaBeats: -3, snap: "off" });
  const gAfter = (await starts([G15]))[0].startBeat;
  check("P8g at the wall a no-op drag reports the reduction the store cannot see",
        near(gAfter, 0) && near(wall.effectiveDeltaBeats, 0)
        && wall.clamped === true && wall.gestureFlooredAtZero === true
        && wall.storeClamped === false && wall.renderSeq === wallSeq,
        `start=${gAfter} effDelta=${wall.effectiveDeltaBeats} clamped=${wall.clamped} `
        + `store=${wall.storeClamped} renderSeq=${wall.renderSeq}`);

  // ══ Recorded as SKIP, never as a pass ════════════════════════════════════
  skip("comp-member refusal end to end",
       "a take group needs >=2 OVERLAPPING clips, and clip.addMIDI routes through "
       + "resolvingOverlaps, so the fixture is UNBUILDABLE from the wire (m23-g1 law). "
       + "Covered headless by ClipGroupMoveTests leg 18 (validate-first, project untouched).");
  skip("real SwiftUI DragGesture translation",
       "DragGesture.Value has no public initializer; no seam can synthesize one. The "
       + "seam drives AppModel.dragArrangeClips, which is everything downstream of the "
       + "gesture's own translation reading.");

  // ══ SUMMARY ══════════════════════════════════════════════════════════════
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} assertions passed`
    + `  (+${notes.length} measurements, ${skips.length} skipped)`);
  for (const c of failed) console.log(`  FAILED: ${c.name} — ${c.detail}`);
  fs.writeFileSync(`${OUT}/result.json`,
    JSON.stringify({ checks, notes, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  // ⚠️ m23-ac-2a: this gate LEAKED — detached + unref, then exit with no
  // teardown. BOTH exit paths need it.
  stopStaging(GATE, PIDFILE);
  process.exit(failed.length ? 1 : 0);
} catch (err) {
  console.error("GATE ERROR:", err);
  clearTimeout(killer);
  try { ws.close(); } catch {}
  stopStaging(GATE, PIDFILE);
  process.exit(2);
}
