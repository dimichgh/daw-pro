// m23-x GATE — ARROW-KEY NUDGE for arrange clips, against a REAL app on staging
// (port 17695 ONLY; 17600 is the user's LIVE app and is never touched. Staging is
// killed PIDFILE-EXACT, never pkill/pgrep — at start AND at exit).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY (the m23-w/m23-p2 pattern), so the thing
// under test has KNOWN PROVENANCE. A gate that drives whatever instance happens
// to be on the port can pass against code that is minutes or days old, and it
// cannot tell you that it did (m23-ac).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves, end to end through the app's own handler: that all FIVE guards
//   refuse a nudge, each as a CONTROLLED PAIR (guard inactive -> the clips move;
//   guard active -> the SAME call refuses AND names which guard) — a
//   refusal-only leg passes against a handler that always returns false, so
//   every refusal here is bracketed by a press that works. Also: that a 3-clip
//   nudge is ONE `edit.history` step; that 5 presses inside the coalescing
//   window are ONE step and that all five ACTUALLY LANDED (`editSeq`, not depth
//   alone — see the vacuity note at N4); that relative offsets survive a nudge
//   into the beat-0 clamp; that the step follows the grid and both modifiers;
//   that an off-grid clip TRANSLATES rather than snapping to a gridline.
//   `debug.arrangeSelection {act:"nudge"}` runs the SAME
//   `AppModel.handleArrangeNudgeKey` the ←/→ key press runs, guards included,
//   so the seam cannot drift from the key.
//   Every geometric assertion reads `project.overview` — the STORE's own state —
//   never the seam's echo. Undo depth comes from `edit.history`.
//
//   Does NOT prove: that SwiftUI delivers a real ←/→ `KeyPress` with
//   `.modifiers` populated. g1 MEASURED that an unbundled staging binary does
//   not route real key events (`keyDelete` -> `delivered:false`), so no seam
//   here can reach that link. Recorded as a SKIP below, never as a pass. This is
//   also why the whole modifier POLICY lives in `ArrangeNudge.step` and the seam
//   passes the chord EXPLICITLY: everything except the final delivery hop is
//   proven, headlessly and here.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW —
// derive it from values the gate controls, never discover it by trial):
//   snap = bar, 4/4  =>  a bare press steps 4 beats. LEN = 2, so:
//     N1  clips at 0 / 4 / 9.5  -> [0,2) [4,6) [9.5,11.5), and after +4
//         [4,6) [8,10) [13.5,15.5) — disjoint before AND after, so no assertion
//         is quietly reading the overlap resolver's output.
//     N6  clips at 2 / 6 / 9.5, one press LEFT: requested -4, leftmost start 2,
//         so the WHOLE-GROUP clamp gives max(-4,-2) = -2 and they land on
//         0 / 4 / 7.5 with the 4 and 3.5 gaps intact.
//     N7  clips at 0 and 2.5 (deliberately off the bar grid), one press right:
//         4 and 6.5. A snap-to-gridline nudge would send BOTH to 4.
//   snap = sixteenth => bare 0.0625, ⌥ 0.03125, ⇧ 4 — three distinguishable
//   numbers, which is why the modifier legs switch the grid first.
//
// Setup: none — run it.
//
//   node scripts/gates/m23x-arrow-nudge.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23x";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23X_OUT || "/tmp/m23x";
const PIDFILE = process.env.M23X_PIDFILE || "/tmp/m23x-staging.pid";
const BINARY = process.env.M23X_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23X_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const LEN = 2;             // clip length in beats
const BAR = 4;             // bar grid in 4/4 — one bare press under `.bar`
const SETTLE_MS = 250;
// `UndoJournal.coalescingWindow` is 800 ms and `moveClipsKey` does NOT
// distinguish keyboard from gesture, so two logically separate nudges of the
// SAME selection inside it fold into ONE entry — correct behaviour, and a trap
// for a gate that then counts entries. Anywhere this gate wants two countable
// entries it either changes the selection (which changes the key) or waits this
// out. Asserted deliberately at N4, never discovered as a failure.
const COALESCE_MS = 900;

// ── build FIRST: a gate that tests the previous binary proves nothing ───────
// The lifecycle (build / launch / pidfile-exact kill) lives in `_staging.mjs`
// (m23-ac-1). This gate keeps its OWN `connect()` below, because that function
// is its request plumbing (`{ws, req}`), not part of the lifecycle.
buildOrAbort({ root: REPO });

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
const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const near = (a, b, eps = 1e-9) => typeof a === "number" && Math.abs(a - b) < eps;

const sel = (p = {}) => req("debug.arrangeSelection", p);
const nudgeAct = (p) => sel({ act: "nudge", ...p });
const overview = () => req("project.overview", {});
const history = () => req("edit.history", {});
/**
 * START BEATS FROM THE STORE — never from the seam echo.
 *
 * A clip that no longer EXISTS comes back as NaN rather than `undefined`, on
 * purpose: `near()` is false for NaN, so a destroyed clip FAILS the leg that
 * was asking about it instead of throwing `Cannot read properties of undefined`
 * and aborting the run. A gate that crashes on the very defect it is hunting
 * reports one failure and hides every leg after it — which is exactly what this
 * one did under mutation B until it was hardened.
 */
async function starts(ids) {
  const ov = await overview();
  const all = new Map();
  for (const t of ov.tracks) for (const c of t.clips) all.set(c.id, c);
  return ids.map((id) => all.get(id) ?? { startBeat: NaN, lengthBeats: NaN, missing: true });
}
const depth = async () => (await history()).undo.length;
/** Selects `ids` as a group, replacing whatever was selected. */
async function select(ids) {
  await sel({ act: "clear" });
  for (const [i, id] of ids.entries()) {
    await sel({ act: "click", clipId: id, ...(i === 0 ? {} : { shift: true }) });
  }
}
/** `{errored:true}` when the command was refused by the protocol itself. */
async function expectError(command, params) {
  try { await req(command, params); return { errored: false }; }
  catch (e) { return { errored: true, message: String(e.message ?? e) }; }
}

let teardownDone = false;
function teardown() {
  if (teardownDone) return;
  teardownDone = true;
  // PIDFILE-EXACT, our OWN child only. Never pkill/pgrep — 17600 is the user's
  // live app and must survive this script by construction. `stopStaging` reads
  // the pid back from this exact pidfile and removes it (m23-ac-1).
  stopStaging(GATE, PIDFILE);
}

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  // Pro density, or `ClipSnap.effective` locks the grid to `.bar` and every
  // modifier leg below (which needs a `sixteenth` grid to discriminate) sweeps
  // a table the app never applied.
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  const trackIDs = [];
  for (const n of ["X1", "X2", "X3"]) {
    trackIDs.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  const add = async (t, beat) => (await req("clip.addMIDI", {
    trackId: trackIDs[t], atBeat: beat, lengthBeats: LEN,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;

  const A0 = await add(0, 0), A4 = await add(0, 4), A95 = await add(0, 9.5);
  const B2 = await add(1, 2), B6 = await add(1, 6), B95 = await add(1, 9.5);
  const C0 = await add(2, 0), C25 = await add(2, 2.5);
  await sleep(SETTLE_MS);

  // The snap PICKER is set through the existing `debug.arrangeDrag` setter (the
  // ONE picker home) and read back through the NUDGE seam — cross-seam
  // agreement, which also proves the nudge echoes the grid it will actually use.
  await req("debug.arrangeDrag", { snap: "bar" });
  const f0 = await sel({});
  check("F1 fixture: the arrange grid in force is BAR (picker AND effective)",
        f0.snap === "bar" && f0.effectiveSnap === "bar",
        `snap=${f0.snap} effectiveSnap=${f0.effectiveSnap}`);
  const f = await starts([A0, A4, A95, B2, B6, B95, C0, C25]);
  check("F2 fixture: all eight clips landed at the exact beats the arithmetic assumes",
        f.every((c) => c && near(c.lengthBeats, LEN))
          && [0, 4, 9.5, 2, 6, 9.5, 0, 2.5].every((b, i) => near(f[i].startBeat, b)),
        f.map((c) => c && c.startBeat).join(","));
  check("F3 fixture: nothing is selected yet (non-vacuity)",
        f0.count === 0, `count=${f0.count}`);

  // ══ N1  A 3-CLIP NUDGE IS ONE STEP, AND THE SELECTION SURVIVES ═══════════
  await select([A0, A4, A95]);
  let s = await sel({});
  check("N1a three clips are selected (the legs below are not vacuous)",
        s.count === 3, `count=${s.count}`);

  let d0 = await depth(), e0 = s.editSeq;
  let n = await nudgeAct({ direction: "right" });
  let a = await starts([A0, A4, A95]);
  check("N1b one press right moved the group by exactly one BAR",
        n.nudged === true && near(n.stepBeats, BAR) && n.stepSource === "grid"
          && near(n.effectiveDeltaBeats, BAR) && n.clamped === false,
        `nudged=${n.nudged} step=${n.stepBeats} source=${n.stepSource} `
        + `eff=${n.effectiveDeltaBeats} clamped=${n.clamped}`);
  check("N1c every clip landed at start+4 and BOTH gaps survived (4 and 5.5)",
        near(a[0].startBeat, 4) && near(a[1].startBeat, 8) && near(a[2].startBeat, 13.5)
          && near(a[1].startBeat - a[0].startBeat, 4)
          && near(a[2].startBeat - a[1].startBeat, 5.5),
        a.map((c) => c.startBeat).join(","));
  check("N1d nothing was trimmed or removed",
        n.trimmedIds.length === 0 && n.removedIds.length === 0
          && a.every((c) => near(c.lengthBeats, LEN)),
        `trimmed=${JSON.stringify(n.trimmedIds)} removed=${JSON.stringify(n.removedIds)}`);
  check("N1e a 3-clip nudge is ONE undo step, labelled countably",
        (await depth()) - d0 === 1 && (await history()).undo[0] === "Move 3 Clips",
        `depth+${(await depth()) - d0} label="${(await history()).undo[0]}"`);
  check("N1f editSeq advanced by exactly 1 (one press, one edit)",
        n.editSeq === e0 + 1, `${e0} -> ${n.editSeq}`);
  check("N1g the SELECTION SURVIVES the nudge — unlike DELETE, you keep nudging",
        n.count === 3, `count=${n.count}`);

  // LEFT is the exact inverse. Waited out, so it is a countable second entry
  // rather than a fold onto N1's (see COALESCE_MS).
  await sleep(COALESCE_MS);
  d0 = await depth();
  n = await nudgeAct({ direction: "left" });
  a = await starts([A0, A4, A95]);
  check("N1h one press LEFT is the exact inverse — the group is back where it started",
        near(n.effectiveDeltaBeats, -BAR) && near(a[0].startBeat, 0)
          && near(a[1].startBeat, 4) && near(a[2].startBeat, 9.5)
          && (await depth()) - d0 === 1,
        `eff=${n.effectiveDeltaBeats} starts=${a.map((c) => c.startBeat).join(",")}`);

  // ══ N2  THE OFF-GRID DISCRIMINATOR — translate, never snap to a gridline ══
  await select([C0, C25]);
  await sleep(COALESCE_MS);
  n = await nudgeAct({ direction: "right" });
  let c = await starts([C0, C25]);
  check("N2a an OFF-GRID clip TRANSLATES: 0 and 2.5 become 4 and 6.5",
        near(c[0].startBeat, 4) && near(c[1].startBeat, 6.5),
        c.map((x) => x.startBeat).join(","));
  check("N2b THE 2.5-BEAT GAP SURVIVED — a snap-to-gridline nudge welds both onto 4",
        near(c[1].startBeat - c[0].startBeat, 2.5)
          && c.every((x) => near(x.lengthBeats, LEN)),
        `gap=${c[1].startBeat - c[0].startBeat} lengths=${c.map((x) => x.lengthBeats).join(",")}`);

  // ══ N3  MODIFIERS — three distinguishable numbers on a 1/16 grid ═════════
  await req("debug.arrangeDrag", { snap: "sixteenth" });
  await select([C0]);
  let g = await sel({});
  check("N3a the grid really switched to 1/16 (the modifier legs are not vacuous)",
        g.snap === "sixteenth" && g.effectiveSnap === "sixteenth",
        `snap=${g.snap} effectiveSnap=${g.effectiveSnap}`);

  let before = (await starts([C0]))[0].startBeat;
  await sleep(COALESCE_MS);
  n = await nudgeAct({ direction: "right" });
  let after = (await starts([C0]))[0].startBeat;
  check("N3b a BARE press steps by the 1/16 grid (0.0625)",
        near(n.stepBeats, 0.0625) && n.stepSource === "grid"
          && near(after - before, 0.0625),
        `step=${n.stepBeats} source=${n.stepSource} moved=${after - before}`);

  before = after;
  n = await nudgeAct({ direction: "right", option: true });
  after = (await starts([C0]))[0].startBeat;
  check("N3c ⌥ is the FINE step (1/32 = 0.03125), finer than any grid the picker offers",
        near(n.stepBeats, 0.03125) && n.stepSource === "fine"
          && near(after - before, 0.03125),
        `step=${n.stepBeats} source=${n.stepSource} moved=${after - before}`);

  before = after;
  n = await nudgeAct({ direction: "right", shift: true });
  after = (await starts([C0]))[0].startBeat;
  check("N3d ⇧ is the COARSE step (one bar = 4), ignoring the 1/16 grid",
        near(n.stepBeats, BAR) && n.stepSource === "bar" && near(after - before, BAR),
        `step=${n.stepBeats} source=${n.stepSource} moved=${after - before}`);

  before = after;
  n = await nudgeAct({ direction: "right", option: true, shift: true });
  after = (await starts([C0]))[0].startBeat;
  check("N3e ⌥ BEATS ⇧ when both are held — the smaller, recoverable move wins",
        near(n.stepBeats, 0.03125) && n.stepSource === "fine"
          && near(after - before, 0.03125),
        `step=${n.stepBeats} source=${n.stepSource} moved=${after - before}`);

  // ⌘ / ⌃ — a CONTROLLED PAIR, because a refusal alone passes against a dead
  // handler. Guard active: refuses and names the reason. Guard inactive (same
  // call, chord dropped): moves.
  before = after;
  let dc = await depth(), sc = (await sel({})).editSeq;
  const cmd = await nudgeAct({ direction: "right", command: true });
  const ctl = await nudgeAct({ direction: "right", control: true });
  after = (await starts([C0]))[0].startBeat;
  check("N3f ⌘ and ⌃ chords PASS THROUGH — nothing moves, nothing is journaled",
        cmd.nudged === false && cmd.refusedBy === "chord"
          && ctl.nudged === false && ctl.refusedBy === "chord"
          && near(after, before) && (await depth()) === dc && ctl.editSeq === sc,
        `cmd=${cmd.nudged}/${cmd.refusedBy} ctl=${ctl.nudged}/${ctl.refusedBy} `
        + `start ${before} -> ${after} depth=${dc}->${await depth()} seq=${sc}->${ctl.editSeq}`);
  n = await nudgeAct({ direction: "right" });
  after = (await starts([C0]))[0].startBeat;
  check("N3g CONTROL: drop the chord and the SAME call moves the clip",
        n.nudged === true && near(after - before, 0.0625),
        `nudged=${n.nudged} moved=${after - before}`);

  // ══ N4  KEY REPEAT — N presses, ONE undo entry, and PROOF all N landed ═══
  await req("debug.arrangeDrag", { snap: "bar" });
  await select([A0, A4]);
  await sleep(COALESCE_MS);
  let base = await starts([A0, A4]);
  d0 = await depth(); e0 = (await sel({})).editSeq;
  n = await nudgeAct({ direction: "right", repeat: 5 });
  a = await starts([A0, A4]);
  check("N4a five presses in one burst are ONE undo entry",
        n.nudgeRepeats === 5 && (await depth()) - d0 === 1,
        `repeats=${n.nudgeRepeats} depth+${(await depth()) - d0}`);
  // THE VACUITY DISCRIMINATOR. Depth alone cannot tell "five presses folded into
  // one entry" from "ONE press landed and four were silently dropped" — both are
  // depth+1. `performEdit` ticks `editEventSeq` for COALESCED edits too, so seq
  // counts presses that actually reached the store; and 5x the step is the
  // geometric witness of the same fact.
  check("N4b editSeq advanced by 5 — all five presses actually LANDED",
        n.editSeq === e0 + 5, `${e0} -> ${n.editSeq} (want +5)`);
  check("N4c and the clips travelled 5 bars, offsets intact",
        near(a[0].startBeat - base[0].startBeat, 5 * BAR)
          && near(a[1].startBeat - base[1].startBeat, 5 * BAR)
          && near(a[1].startBeat - a[0].startBeat, base[1].startBeat - base[0].startBeat),
        `${base.map((x) => x.startBeat).join(",")} -> ${a.map((x) => x.startBeat).join(",")}`);
  const undone = await req("edit.undo", {});
  a = await starts([A0, A4]);
  check("N4d ONE undo restores the whole burst — the point of coalescing",
        near(a[0].startBeat, base[0].startBeat) && near(a[1].startBeat, base[1].startBeat),
        `label="${undone.label ?? undone.undone ?? ""}" starts=${a.map((x) => x.startBeat).join(",")}`);
  // And the window is REAL, not "coalescing always": wait it out and a second
  // press is a second entry.
  await sleep(COALESCE_MS);
  d0 = await depth();
  await nudgeAct({ direction: "right" });
  await sleep(COALESCE_MS);
  await nudgeAct({ direction: "right" });
  check("N4e two presses SEPARATED by more than the 800 ms window are TWO entries",
        (await depth()) - d0 === 2, `depth+${(await depth()) - d0}`);

  // ══ N5  THE FOUR GUARDS, each as a CONTROLLED PAIR ═══════════════════════
  // Idiom throughout (g1's K2b/K2e): arm the guard -> the SAME call must refuse
  // AND name itself AND leave the clips and the journal untouched; disarm it ->
  // the SAME call must move. Without the second half a handler that always
  // returns false passes every one of these.
  await select([A0, A4]);
  await sleep(COALESCE_MS);

  // G1 — WORKSPACE.
  let mark = (await starts([A0]))[0].startBeat;
  d0 = await depth();
  await req("ui.showMixer", { show: true });
  await sleep(SETTLE_MS);
  let refused = await nudgeAct({ direction: "right" });
  check("N5a1 the seam really switched to Mix (the leg is not vacuous)",
        refused.workspaceMode === "mix", `workspaceMode=${refused.workspaceMode}`);
  check("N5a2 GUARD: ← / → in the Mix console does NOT move the arrange selection",
        refused.nudged === false && refused.refusedBy === "workspace"
          && near((await starts([A0]))[0].startBeat, mark) && (await depth()) === d0,
        `nudged=${refused.nudged} by=${refused.refusedBy} `
        + `start=${(await starts([A0]))[0].startBeat} depth=${await depth()}`);
  check("N5a3 the selection SURVIVES the refused key",
        refused.count === 2, `count=${refused.count}`);
  await req("ui.showMixer", { show: false });
  await sleep(SETTLE_MS);
  let allowed = await nudgeAct({ direction: "right" });
  check("N5a4 CONTROL: back in Arrange the SAME call nudges — N5a2 measured the guard",
        allowed.nudged === true && allowed.workspaceMode === "arrange"
          && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} start=${(await starts([A0]))[0].startBeat}`);

  // G2 — MODAL.
  mark = (await starts([A0]))[0].startBeat;
  await sleep(COALESCE_MS);
  d0 = await depth();
  await req("debug.quantizePanel", { clipId: A0 });
  await sleep(SETTLE_MS);
  refused = await nudgeAct({ direction: "right" });
  check("N5b1 the quantize panel really is up (the leg is not vacuous)",
        refused.modalPresented === true, `modalPresented=${refused.modalPresented}`);
  check("N5b2 GUARD: ← / → with a modal open does NOT move the clips behind it",
        refused.nudged === false && refused.refusedBy === "modal"
          && near((await starts([A0]))[0].startBeat, mark) && (await depth()) === d0,
        `nudged=${refused.nudged} by=${refused.refusedBy} `
        + `start=${(await starts([A0]))[0].startBeat} depth=${await depth()}`);
  await req("debug.quantizePanel", { close: true });
  await sleep(SETTLE_MS);
  allowed = await nudgeAct({ direction: "right" });
  check("N5b3 CONTROL: with the panel shut the SAME call nudges (not a permanent latch)",
        allowed.nudged === true && allowed.modalPresented === false
          && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} modal=${allowed.modalPresented} `
        + `start=${(await starts([A0]))[0].startBeat}`);

  // G3 — TEXT EDITING. THE LOAD-BEARING ONE: ← and → are pressed inside text
  // fields constantly, by every user, in every rename. A nudge that fired there
  // would move the user's clips while they were editing a name.
  mark = (await starts([A0]))[0].startBeat;
  await req("marker.add", { beat: 1, name: "RenameMe" });
  const markers = await req("marker.list", {});
  const markerId = (markers.markers ?? markers)[0]?.id;
  await req("debug.markerRename", { markerId });
  await sleep(600);
  // Baseline taken AFTER the marker exists: `marker.add` is itself an undoable
  // edit, and folding it into the baseline would make this read a +1 that has
  // nothing to do with the key.
  d0 = await depth();
  refused = await nudgeAct({ direction: "right" });
  check("N5c1 the rename field really has focus (the leg is not vacuous)",
        refused.textEditing === true,
        `textEditing=${refused.textEditing} — if false, N5c2 proves nothing`);
  check("N5c2 GUARD: → typed into a rename field does NOT move the user's clips",
        refused.nudged === false && refused.refusedBy === "text-editing"
          && near((await starts([A0]))[0].startBeat, mark) && (await depth()) === d0,
        `nudged=${refused.nudged} by=${refused.refusedBy} `
        + `start=${(await starts([A0]))[0].startBeat} depth=${await depth()}`);
  await req("debug.markerRename", { clear: true });
  await sleep(400);
  allowed = await nudgeAct({ direction: "right" });
  check("N5c3 CONTROL: with the field closed the SAME call nudges (not a latch)",
        allowed.nudged === true && allowed.textEditing === false
          && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} textEditing=${allowed.textEditing} `
        + `start=${(await starts([A0]))[0].startBeat}`);

  // G4 — EMPTY SELECTION.
  mark = (await starts([A0]))[0].startBeat;
  await sleep(COALESCE_MS);
  d0 = await depth();
  await sel({ act: "clear" });
  refused = await nudgeAct({ direction: "right" });
  check("N5d1 GUARD: with nothing selected the key is inert (nothing moves at all)",
        refused.nudged === false && refused.refusedBy === "empty-selection"
          && refused.count === 0
          && near((await starts([A0]))[0].startBeat, mark) && (await depth()) === d0,
        `nudged=${refused.nudged} by=${refused.refusedBy} count=${refused.count} `
        + `start=${(await starts([A0]))[0].startBeat}`);
  await select([A0]);
  allowed = await nudgeAct({ direction: "right" });
  check("N5d2 CONTROL: re-select and the SAME call nudges",
        allowed.nudged === true && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} start=${(await starts([A0]))[0].startBeat}`);

  // ══ N6  THE BEAT-0 CLAMP — partial (offsets) then full (inert) ═══════════
  await select([B2, B6, B95]);
  await sleep(COALESCE_MS);
  d0 = await depth(); e0 = (await sel({})).editSeq;
  n = await nudgeAct({ direction: "left" });
  let b = await starts([B2, B6, B95]);
  check("N6a PARTIAL clamp: asked for -4, the WHOLE GROUP moved -2 and stopped at the wall",
        near(n.requestedDeltaBeats, -BAR) && near(n.effectiveDeltaBeats, -2)
          && n.clamped === true && n.nudged === true,
        `requested=${n.requestedDeltaBeats} effective=${n.effectiveDeltaBeats} `
        + `clamped=${n.clamped}`);
  check("N6b RELATIVE OFFSETS SURVIVED the clamp: 0 / 4 / 7.5, gaps still 4 and 3.5",
        near(b[0].startBeat, 0) && near(b[1].startBeat, 4) && near(b[2].startBeat, 7.5)
          && near(b[1].startBeat - b[0].startBeat, 4)
          && near(b[2].startBeat - b[1].startBeat, 3.5),
        b.map((x) => x.startBeat).join(","));
  check("N6c a clamped-but-non-zero nudge is still ONE real edit",
        (await depth()) - d0 === 1 && n.editSeq === e0 + 1,
        `depth+${(await depth()) - d0} seq ${e0} -> ${n.editSeq}`);

  await sleep(COALESCE_MS);
  d0 = await depth(); e0 = (await sel({})).editSeq;
  n = await nudgeAct({ direction: "left" });
  b = await starts([B2, B6, B95]);
  check("N6d FULL clamp AT the wall journals NOTHING — no entry, no editSeq tick",
        near(n.effectiveDeltaBeats, 0) && n.clamped === true
          && (await depth()) === d0 && n.editSeq === e0 && near(b[0].startBeat, 0),
        `eff=${n.effectiveDeltaBeats} clamped=${n.clamped} depth=${await depth()} `
        + `seq ${e0} -> ${n.editSeq}`);
  check("N6e ...but the KEY IS STILL CONSUMED (nudged=true), so ← at the wall cannot "
        + "fall through and scroll the timeline out from under the user",
        n.nudged === true, `nudged=${n.nudged}`);
  n = await nudgeAct({ direction: "right" });
  b = await starts([B2, B6, B95]);
  check("N6f CONTROL: the SAME group then moves right — N6d measured the wall, not a corpse",
        near(b[0].startBeat, BAR) && near(n.effectiveDeltaBeats, BAR),
        b.map((x) => x.startBeat).join(","));

  // ══ N7  SNAP OFF must not kill the key ═══════════════════════════════════
  await req("debug.arrangeDrag", { snap: "off" });
  await select([C0]);
  await sleep(COALESCE_MS);
  before = (await starts([C0]))[0].startBeat;
  n = await nudgeAct({ direction: "right" });
  after = (await starts([C0]))[0].startBeat;
  check("N7a with snapping OFF the arrow still works — a 1-beat fallback, not a dead key",
        n.nudged === true && near(n.stepBeats, 1) && n.stepSource === "grid-off-fallback"
          && near(after - before, 1) && n.effectiveSnap === "off",
        `step=${n.stepBeats} source=${n.stepSource} moved=${after - before} `
        + `effectiveSnap=${n.effectiveSnap}`);

  // ══ N8  THE SEAM REFUSES WHAT THE FEATURE DOES NOT DO ════════════════════
  const noDir = await expectError("debug.arrangeSelection", { act: "nudge" });
  // m23-aj-3 REWROTE N8b, and the rewrite is the record of why. This leg used
  // to send `direction:"up"` and assert it was REFUSED, because a vertical
  // nudge did not exist. It does now (`ArrangeVerticalNudgeDirection`, over
  // `ProjectStore.moveClips(ids:byTracks:)`), so the old assertion was a
  // shipped gate pinning a fact the roadmap deliberately changed — exactly the
  // kind of red that must be found by the item that causes it. The leg keeps
  // its PURPOSE (the seam refuses what the feature does not do) by moving to a
  // direction the app really has no rule for. The ↑/↓ axis itself is owned by
  // `scripts/gates/m23aj-cross-track-move.mjs`.
  const bogusDir = await expectError("debug.arrangeSelection",
                                     { act: "nudge", direction: "sideways" });
  check("N8a a nudge with no direction is an ERROR, not a silent no-op",
        noDir.errored === true, `${noDir.message ?? "accepted!"}`);
  check("N8b an UNRECOGNISED direction is REFUSED EXPLICITLY — the seam says so rather "
        + "than pretending it worked (was: ↑/↓; they became real at m23-aj-3)",
        bogusDir.errored === true, `${bogusDir.message ?? "accepted!"}`);

  // ══ Recorded as SKIP, never as a pass ════════════════════════════════════
  // ══ N9  GUARD 5 — THE PIANO ROLL WOULD HAVE CONSUMED THE KEY ════════════
  // The predicate is focus AND a NOTE SELECTION, and both terms are load
  // bearing. Focus ALONE was implemented and measured: `PianoRollView` does
  // `.onAppear { isFocused = true }` and the roll opens for ANY single selected
  // MIDI clip, so focus is already true in the ordinary "clicked one clip"
  // state — the naive guard refused EVERY single-MIDI-clip nudge (0 -> 0) and
  // reddened 9 legs here, every one of them a CONTROL half. The shipped rule
  // mirrors the roll's own `.onKeyPress(.delete)`: consume only when notes are
  // selected, else fall through and let the arrange act on the clip.
  //
  // A0 is a MIDI clip, so selecting it ALONE opens the roll on it — which is
  // what makes this a controlled pair on ONE variable: the editor is open in
  // both halves and only the note selection moves.
  //
  // THE FIXTURE ASSERTS `editorClipId`, NOT `pianoRollEditorFocused`, and that
  // is the whole finding of this section. The focus flag ALTERNATES on clip
  // switches — measured 6 true / 6 false over 12 consecutive selections, strictly
  // alternating, with the editor open on all twelve and the false readings still
  // false 1.4 s later. An earlier draft of N9a asserted it and went red on
  // exactly half the runs, which is also why the shipped guard does not carry it.
  //
  // SET THE SNAP EXPLICITLY. N7a leaves it OFF, and inheriting that made every
  // control half here travel 1 beat (the documented `.off` fallback) against a
  // `mark + BAR` expectation — three red legs that were measuring the previous
  // leg's leftover state, not this guard.
  await req("debug.arrangeDrag", { snap: "bar" });
  await select([A0]);
  await sleep(COALESCE_MS);
  let rollState = await sel({ act: "pianoRollNotes", select: false });
  check("N9a FIXTURE: one MIDI clip selected => the roll is OPEN on it, with no "
        + "notes selected (without this the pair below is vacuous — it would be "
        + "testing a closed editor, where the guard could never fire anyway)",
        rollState.editorClipId === A0
          && rollState.pianoRollNoteSelection === false,
        `editorClipId=${rollState.editorClipId === A0} `
        + `notes=${rollState.pianoRollNoteSelection} `
        + `(focus=${rollState.pianoRollEditorFocused}, reported but NOT asserted `
        + `— it alternates)`);

  mark = (await starts([A0]))[0].startBeat;
  d0 = await depth();
  allowed = await nudgeAct({ direction: "right" });
  check("N9b CONTROL (guard INACTIVE): roll focused but NO notes selected — the "
        + "arrow still nudges the CLIP. This is the half the naive focus-only "
        + "guard destroyed, so it is the leg that pins the fix",
        allowed.nudged === true && allowed.refusedBy === null
          && allowed.editorClipId === A0
          && allowed.pianoRollNoteSelection === false
          && near((await starts([A0]))[0].startBeat, mark + BAR)
          && (await depth()) === d0 + 1,
        `nudged=${allowed.nudged} by=${allowed.refusedBy} `
        + `editorOpen=${allowed.editorClipId === A0} `
        + `notes=${allowed.pianoRollNoteSelection} `
        + `start=${mark} -> ${(await starts([A0]))[0].startBeat}`);

  mark = (await starts([A0]))[0].startBeat;
  await sleep(COALESCE_MS);
  d0 = await depth();
  e0 = (await sel({})).editSeq;
  rollState = await sel({ act: "pianoRollNotes", select: true });
  check("N9c FIXTURE: the staged note selection actually landed in the roll's "
        + "own model (the seam reaches @State private via the nonce)",
        rollState.pianoRollNoteSelection === true,
        `notes=${rollState.pianoRollNoteSelection}`);

  refused = await nudgeAct({ direction: "right" });
  check("N9d GUARD ACTIVE: with notes selected in the focused roll, ← / → belong "
        + "to the EDITOR — the clip does not slide underneath it, and nothing "
        + "is journaled",
        refused.refusedBy === "piano-roll-note-edit"
          // BOTH terms asserted FROM THE SAME ECHO that carries the outcome, so
          // a focus race reports here as the fixture problem it is rather than
          // masquerading as a guard failure (or, worse, letting a mutation hide
          // behind one).
          && refused.editorClipId === A0
          && refused.pianoRollNoteSelection === true
          && near((await starts([A0]))[0].startBeat, mark)
          && (await depth()) === d0
          && (await sel({})).editSeq === e0,
        `nudged=${refused.nudged} by=${refused.refusedBy} `
        + `editorOpen=${refused.editorClipId === A0} `
        + `notes=${refused.pianoRollNoteSelection} `
        + `start=${mark} -> ${(await starts([A0]))[0].startBeat} `
        + `depth=${await depth()}/${d0} seq=${(await sel({})).editSeq}/${e0}`);

  // N6e's TWIN. Read them together: N6e pins that a fully-clamped nudge at the
  // beat-0 wall is CONSUMED, and this pins the same for the note-edit refusal.
  // Both are "the user pressed an arrow and nothing should visibly happen", and
  // in both the key must be EATEN — `TimelineLanesView`'s ScrollView(.horizontal)
  // answers an `.ignored` arrow by scrolling the timeline sideways, which would
  // trade the surprise this guard removes for a different one. Every OTHER
  // refusal (workspace/modal/textEditing/emptySelection/chord) is genuinely not
  // ours and DOES fall through — N5a2/N5b2/N5c2/N5d1 report nudged=false.
  check("N9i ...and the note-edit refusal CONSUMES the key (nudged=true) — the "
        + "N6e twin: refusing must not hand the arrow to the timeline's "
        + "horizontal ScrollView to scroll with",
        refused.nudged === true,
        `nudged=${refused.nudged} by=${refused.refusedBy}`);

  await sel({ act: "pianoRollNotes", select: false });
  mark = (await starts([A0]))[0].startBeat;
  allowed = await nudgeAct({ direction: "right" });
  check("N9e CONTROL: deselecting the notes gives the key straight back — the "
        + "guard is a live predicate, not a one-way latch",
        allowed.nudged === true && allowed.refusedBy === null
          && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} by=${allowed.refusedBy} `
        + `start=${mark} -> ${(await starts([A0]))[0].startBeat}`);

  // CLOSING THE EDITOR MUST DROP THE CLAIM. `.onDisappear` clears the bridge;
  // if it did not, a stale `true` would kill the arrow keys for the rest of the
  // session with nothing on screen to explain it — worse than the bug the guard
  // fixes, and invisible to every leg above (they all keep the roll open).
  await sel({ act: "pianoRollNotes", select: true });
  await sel({ act: "clear" });
  await sleep(SETTLE_MS * 3);
  rollState = await sel({});
  check("N9f closing the editor DROPS the note-selection claim (no latch)",
        rollState.pianoRollNoteSelection === false
          && rollState.editorClipId === null,
        `notes=${rollState.pianoRollNoteSelection} `
        + `editorClipId=${rollState.editorClipId}`);

  await select([A0]);
  await sleep(COALESCE_MS);
  mark = (await starts([A0]))[0].startBeat;
  allowed = await nudgeAct({ direction: "right" });
  check("N9g ...and the arrows still work afterwards (the latch check above is "
        + "not itself vacuous)",
        allowed.nudged === true
          && near((await starts([A0]))[0].startBeat, mark + BAR),
        `nudged=${allowed.nudged} start=${mark} -> `
        + `${(await starts([A0]))[0].startBeat}`);

  const badNotes = await expectError("debug.arrangeSelection",
                                     { act: "pianoRollNotes" });
  check("N9h the note-staging act refuses a missing 'select' rather than "
        + "silently defaulting (a default would make N9b/N9d agree by accident)",
        badNotes.errored === true,
        badNotes.message ?? "no error");

  skip("real ←/→ key DELIVERY with a live modifier chord",
       "g1 MEASURED that an unbundled staging binary does not route real key events "
       + "(debug.arrangeSelection {act:\"keyDelete\"} -> delivered:false), so SwiftUI's "
       + "onKeyPress(keys:phases:) delivery and KeyPress.modifiers population cannot be "
       + "exercised here. Everything BELOW that hop — the whole modifier policy, all FIVE "
       + "guards (the piano-roll one included: N9), the step rule, the store call — is "
       + "proven above and in ArrangeNudgeTests.");
  skip("comp-member refusal end to end",
       "a take group needs >=2 OVERLAPPING clips and clip.addMIDI routes through "
       + "resolvingOverlaps, so the fixture is UNBUILDABLE from the wire (m23-g1 law). "
       + "The refusal path is ProjectStore.moveClips' own validate-first, covered by "
       + "ClipGroupMoveTests.");

  // ══ SUMMARY ══════════════════════════════════════════════════════════════
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} assertions passed`
    + `  (${skips.length} skipped)`);
  for (const c of failed) console.log(`  FAILED: ${c.name} — ${c.detail}`);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  teardown();
  process.exit(failed.length ? 1 : 0);
} catch (err) {
  console.error("GATE ERROR:", err);
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
  process.exit(2);
}
