#!/usr/bin/env node
// m34-j CHARACTERISATION — THE DEAD STATE THE HUNT FOUND, PINNED DOWN.
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only.
//
// ═══ WHAT THE FIRST TWO PROBES ESTABLISHED ═══
//
// `_m34j-arrow-nudge-repro.mjs`: the item's STATED antecedent — "dead after a
// clip switch, roughly half the time" — is REFUTED. 36/36 posted arrows entered
// their mount and moved the clip while `pianoRollEditorFocused` alternated
// exactly 6/12. The arrow mount's own `@FocusState` read TRUE 12/12: it is a
// DIFFERENT flag from the one that alternates, and it does not alternate.
//
// `_m34j-arrow-dead-state-hunt.mjs`: but the DEFECT CLASS IS REAL, with a
// different antecedent. Leg H2 — a marker rename field opened and then
// CANCELLED — left the arrow DEAD ON DELIVERY (`entered=n`) in a state where
// every guard was clear: textEditing=false, workspace=arrange, modal=false,
// note selection empty, a clip still selected. The same probe's H3 (Mix
// console) also read `entered=n`, which is CORRECT there — the mount is scoped
// inside the arrange workspace and does not exist in Mix — and that makes H3
// the positive control: the instrument CAN read a dead mount.
//
// ═══ WHAT THIS ONE ASKS, BECAUSE THE ANSWERS CHANGE THE FIX ═══
//
//   Q1  IS IT LATCHED? Does a SECOND arrow press also die, or was the first one
//       swallowed by a settling responder chain? A latched dead state is a
//       session-killer; a one-press hiccup is a nuisance.
//   Q2  WHAT RECOVERS IT? Clicking the clip bumps `arrangeKeyFocusNonce`, which
//       re-asserts focus. If that revives the arrows, the user's escape hatch is
//       "click the clip again" and the bug is annoying rather than fatal.
//   Q3  IS IT THE CANCEL, OR ANY DISMISSAL? Commit (Return) is the common
//       gesture; cancel (Escape) is the rare one. If only cancel breaks it, the
//       blast radius is small.
//   Q4  BOTH AXES? ↑/↓ ride the same `@FocusState`, so they should die together.
//       If they do not, the diagnosis is wrong.
//   Q5  DOES THE POLICY STILL GRANT? Drive `act:"nudge"` in the dead state. If
//       the handler grants where the key did nothing, DELIVERY is the confirmed
//       failure — not the handler, not a guard.
//   Q6  IS IT THE TEXT FIELD AT ALL? Open the rename and CLEAR it via the seam's
//       own `{clear:true}`, which unmounts the field by a different route. Two
//       routes into the same dead state is mechanism; one is a coincidence.
//
//   node scripts/gates/_m34j-focus-loss-characterise.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m34jchar";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34jchar";
const PIDFILE = "/tmp/m34jchar-staging.pid";
const SETTLE = 450;

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
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

buildOrAbort({ label: "building staging binary (m34-j characterisation)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

const sel = (p = {}) => req("debug.arrangeSelection", p);

async function clipState(clipId) {
  const tracks = (await req("project.snapshot", {})).tracks ?? [];
  for (const t of tracks) {
    const c = (t.clips ?? []).find((x) => x.id === clipId);
    if (c) return { trackId: t.id, startBeat: c.startBeat };
  }
  return null;
}

/** Post one real arrow; report DELIVERY (mount entered) and EFFECT separately. */
async function press(key, clipId) {
  const counter = key === "left" || key === "right"
    ? "arrangeHorizontalArrow" : "arrangeVerticalArrow";
  const before = await sel({});
  const b = await clipState(clipId);
  await sel({ act: "postKey", key });
  await sleep(SETTLE);
  const after = await sel({});
  const a = await clipState(clipId);
  return {
    entered: after.keyPressProbe[counter] !== before.keyPressProbe[counter],
    moved: key === "left" || key === "right"
      ? b?.startBeat !== a?.startBeat : b?.trackId !== a?.trackId,
    wsFocus: before.keyPressProbe.arrangeWorkspaceFocused,
    textEditing: before.textEditing,
    count: before.count,
    from: b?.startBeat, to: a?.startBeat,
  };
}
const fmt = (r) => `entered=${r.entered ? "Y" : "n"} moved=${r.moved ? "Y" : "n"}`
  + ` wsFocus=${r.wsFocus ? 1 : 0} textEditing=${r.textEditing} selCount=${r.count}`
  + ` startBeat ${r.from}->${r.to}`;

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "CHAR A" })).id;
  await req("track.add", { kind: "instrument", name: "CHAR B" });
  const clipId = (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 16, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const markerId = (await req("marker.add", { beat: 0, name: "RenameMe" })).id;

  /** Put the app back in the known-good state: clip clicked, no note selection. */
  async function reset() {
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(350);
  }

  await reset();
  console.log("\n════ BASELINE ════");
  console.log(`   →  ${fmt(await press("right", clipId))}`);

  // ── Q1 + Q2 + Q4 + Q5 — cancel, then FOUR probes without re-clicking ──────
  console.log("\n════ Q1/Q4/Q5 — RENAME → CANCEL, THEN PRESS REPEATEDLY ════");
  {
    await req("debug.markerRename", { markerId });
    await sleep(400);
    const during = await sel({});
    console.log(`   control: field open, textEditing=${during.textEditing}`);
    await req("debug.markerRename", { cancel: true });
    await sleep(500);

    const p1 = await press("right", clipId);
    console.log(`   press 1 →  ${fmt(p1)}`);
    const p2 = await press("right", clipId);
    console.log(`   press 2 →  ${fmt(p2)}`);
    const p3 = await press("right", clipId);
    console.log(`   press 3 →  ${fmt(p3)}`);
    const v1 = await press("down", clipId);
    console.log(`   press 4 ↓  entered=${v1.entered ? "Y" : "n"} movedTrack=${v1.moved ? "Y" : "n"}`
      + `  (Q4: the OTHER axis, same @FocusState)`);

    // Q5 — the POLICY, through the seam, in the dead state.
    const seam = await sel({ act: "nudge", direction: "right" });
    const afterSeam = await clipState(clipId);
    console.log(`   Q5 seam act:"nudge" right → handled=${seam.nudge?.handled}`
      + ` refusedBy=${seam.nudge?.refusedBy ?? "null"} startBeat->${afterSeam?.startBeat}`);
    console.log("      (a GRANT here with the key dead = DELIVERY is the failure)");

    // Q2 — does re-clicking the clip revive it?
    await reset();
    const p5 = await press("right", clipId);
    console.log(`   Q2 after RE-CLICKING the clip →  ${fmt(p5)}`);
  }

  // ── Q3 — is it the CANCEL specifically, or any dismissal? ─────────────────
  console.log("\n════ Q3 — COMMIT (Return) instead of cancel ════");
  {
    await reset();
    await req("debug.markerRename", { markerId });
    await sleep(400);
    await req("debug.markerRename", { commit: true });
    await sleep(500);
    console.log(`   after COMMIT →  ${fmt(await press("right", clipId))}`);
    await reset();
  }

  // ── Q6 — a THIRD dismissal route: the seam's own {clear:true} ─────────────
  console.log("\n════ Q6 — {clear:true} (unmounts the field by a different route) ════");
  {
    await reset();
    await req("debug.markerRename", { markerId });
    await sleep(400);
    await req("debug.markerRename", { clear: true });
    await sleep(500);
    console.log(`   after CLEAR →  ${fmt(await press("right", clipId))}`);
    await reset();
  }

  // ── NEGATIVE CONTROL — a NON-text overlay opened and closed the same way ──
  console.log("\n════ NEGATIVE CONTROL — open+close a MODAL that has no text field ════");
  {
    await reset();
    await req("debug.undoHistory", { open: true });
    await sleep(400);
    await req("debug.undoHistory", { close: true });
    await sleep(500);
    console.log(`   after modal open+close →  ${fmt(await press("right", clipId))}`);
    console.log("      (if this is ALIVE while the rename legs are DEAD, the text field");
    console.log("       — not 'any overlay' — is the mechanism.)");
  }

  console.log("\n════ READ THE TABLE ABOVE ════");
  console.log("   entered=n with every guard clear IS the m34-j defect: the key never");
  console.log("   reached SwiftUI. entered=Y moved=n is a named guard doing its job.");
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
