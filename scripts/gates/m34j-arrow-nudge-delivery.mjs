#!/usr/bin/env node
// m34-j — THE ARROW NUDGES SURVIVE LOSING SwiftUI FOCUS.
//
// ⚠️ Staging (17695) only. 17600 is the user's live app and is never contacted.
//
// ═══ WHAT THIS PINS, AND WHY IT IS NOT WHAT THE ITEM PREDICTED ═══
//
// m34-j predicted the arrow nudges were "intermittently dead after a clip
// switch, roughly half the time", riding the focus pair m23-al measured
// alternating 6-true/6-false. THAT PREMISE IS REFUTED, MEASURED
// (`_m34j-arrow-nudge-repro.mjs`): 36/36 posted arrows entered their mount and
// moved the clip across 12 clip switches per leg, WHILE `pianoRollEditorFocused`
// alternated exactly `101010101010` — the antecedent was present and the arrows
// did not care. The item conflated TWO DIFFERENT FLAGS: `pianoRollEditorFocused`
// alternates; `ArrangeDeleteKey.focused` — the one the arrow mounts actually
// hang off — read TRUE 12/12 through the same switches.
//
// ⭐⭐ BUT THE DEFECT CLASS IS REAL, WITH A DIFFERENT AND MORE ORDINARY DOOR,
// FOUND BY `_m34j-arrow-dead-state-hunt.mjs` AND CHARACTERISED BY
// `_m34j-focus-loss-characterise.mjs`: **dismissing any text field drops
// `ArrangeDeleteKey.focused` 1 → 0 and never restores it.** Measured before the
// fix — latched (3 consecutive presses dead), both axes, all three dismissal
// routes (Return / Escape / unmount), recovered ONLY by clicking a clip again.
// A non-text modal opened and closed the same way left focus ALIVE, so it is the
// field editor specifically and not "any overlay".
//
// ⭐ AND THAT IS EXACTLY THE ITEM'S HEADLINE AFTER ALL: ⌫ was rescued from this
// route at m23-cf-3 and the arrows were left behind. Measured side by side in
// the SAME dead state (`_m34j-monitor-viability.mjs`): ⌫ reached the monitor,
// was accepted, and deleted the clip; the arrow reached nothing.
//
// ═══ THE LEGS ═══
//
//   A  BASELINE — an arrow moves the clip in the ordinary state. Without it a
//      red B could be a broken fixture rather than the bug.
//   B  ⭐ THE FIX — rename → dismiss → arrow STILL moves the clip. RED BEFORE
//      THE FIX AND MEASURED SO; this leg is the whole item.
//   C  BOTH AXES — ↑/↓ in the same dead state.
//   D  LATCHED — a SECOND press in the dead state also works.
//   E  ⭐⭐ THE CARET PIN — with the field OPEN, an arrow must NOT move the
//      user's clips. This is the regression the fix most plausibly introduces,
//      and it is asserted against the LIVE `text-editing` refusal, not inferred.
//   F  AUTO-REPEAT — a held arrow still walks the clip (`isRepeat:true`).
//      Deliberately the OPPOSITE of the delete monitor's `.keyRepeat` refusal.
//   G  MIX — an arrow in the Mix console moves nothing.
//   H  MODAL — an arrow with a modal up moves nothing.
//   I  ROLL SHIELD — with notes selected the roll's guard still holds.
//   J  NEGATIVE CONTROL — a non-text modal open+close leaves the arrows alive.
//
// ⚠️⚠️ EVERY LEG READS **CLIP MOVEMENT**, NEVER `KeyPressProbe`'s mount
// counters. Once the monitor swallows an owned arrow, SwiftUI never sees it and
// those counters stop moving for real keys — exactly the transition ⌫ went
// through at m23-cf-3 ("A BARE ⌦ CANNOT ANSWER THIS ANY MORE"). A gate written
// against the counters would go green-by-going-blind.
//
// ⚠️ HONEST LIMIT, STATED RATHER THAN GLOSSED: no gate in this tree can press a
// physical key. `NSApp.postEvent` through the real queue is the strongest
// instrument available and is stronger than a `debug.*` seam — but a human must
// confirm once at a real keyboard.
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep, verdict,
} from "./_staging.mjs";

const GATE = "m34j-arrow-nudge-delivery";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34j-arrow-nudge-delivery";
const PIDFILE = "/tmp/m34j-arrow-nudge-delivery-staging.pid";
const SETTLE = 500;

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok });
  console.log(`   ${ok ? "PASS" : "FAIL"}  ${name}${detail ? `   ${detail}` : ""}`);
}

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

buildOrAbort({ label: "building staging binary (m34-j arrow delivery)…" });
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

/** Post one real arrow and report what the CLIP did. Never reads mount counters. */
async function press(key, clipId, extra = {}) {
  const before = await sel({});
  const b = await clipState(clipId);
  await sel({ act: "postKey", key, ...extra });
  await sleep(SETTLE);
  const after = await sel({});
  const a = await clipState(clipId);
  return {
    movedBeat: b?.startBeat !== a?.startBeat,
    movedTrack: b?.trackId !== a?.trackId,
    from: b?.startBeat, to: a?.startBeat,
    wsFocus: before.keyPressProbe?.arrangeWorkspaceFocused,
    textEditing: before.textEditing,
    monitorSeqDelta: (after.arrowNudgeMonitorSeq ?? 0) - (before.arrowNudgeMonitorSeq ?? 0),
    refusedBy: after.arrowNudgeMonitorRefusedBy,
    hasEcho: after.arrowNudgeMonitorSeq !== undefined,
  };
}

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "M34J A" })).id;
  await req("track.add", { kind: "instrument", name: "M34J B" });
  const clipId = (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 16, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 },
            { pitch: 64, startBeat: 1, lengthBeats: 1, velocity: 100 }],
  })).id;
  const markerId = (await req("marker.add", { beat: 0, name: "RenameMe" })).id;

  /** The known-good state: clip clicked, roll open, no note selection. */
  async function reset() {
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(350);
  }
  /** Drive the app into the measured dead state and PROVE it is the dead state. */
  async function enterFocusLostState(dismiss = { cancel: true }) {
    await reset();
    await req("debug.markerRename", { markerId });
    await sleep(400);
    const open = await sel({});
    await req("debug.markerRename", dismiss);
    await sleep(500);
    const after = await sel({});
    return { fieldWasOpen: open.textEditing === true, after };
  }

  console.log("\n════ A — BASELINE ════");
  {
    await reset();
    const r = await press("right", clipId);
    check("A  an arrow moves the clip in the ordinary state", r.movedBeat,
      `startBeat ${r.from}->${r.to} wsFocus=${r.wsFocus}`);
  }

  console.log("\n════ B — ⭐ THE FIX: an arrow AFTER a rename field is dismissed ════");
  {
    const { fieldWasOpen, after } = await enterFocusLostState();
    check("B0 CONTROL — the rename field really was focused", fieldWasOpen,
      "(if false, B proves nothing about focus loss)");
    check("B1 CONTROL — SwiftUI focus really was lost",
      after.keyPressProbe?.arrangeWorkspaceFocused === false,
      `wsFocus=${after.keyPressProbe?.arrangeWorkspaceFocused}`
      + " (if TRUE the state under test never happened)");
    check("B2 CONTROL — every nudge guard is clear in this state",
      after.textEditing === false && after.workspaceMode === "arrange"
      && after.modalPresented === false && after.pianoRollNoteSelection === false
      && after.count > 0,
      `textEditing=${after.textEditing} workspace=${after.workspaceMode}`
      + ` modal=${after.modalPresented} noteSel=${after.pianoRollNoteSelection}`
      + ` selCount=${after.count}`);
    const r = await press("right", clipId);
    check("B3 ⭐ the arrow STILL moves the clip with SwiftUI focus lost", r.movedBeat,
      `startBeat ${r.from}->${r.to}`);
    // D — latched? A second press, still without re-clicking.
    const r2 = await press("right", clipId);
    check("D  a SECOND press in the same state also moves it", r2.movedBeat,
      `startBeat ${r2.from}->${r2.to}`);
    // C — the other axis, still without re-clicking.
    const r3 = await press("down", clipId);
    check("C  ↓ moves the clip across tracks in the same state", r3.movedTrack,
      `movedTrack=${r3.movedTrack}`);
    await press("up", clipId);
  }

  console.log("\n════ E — ⭐⭐ THE CARET PIN: arrows belong to a focused text field ════");
  {
    await reset();
    await req("debug.markerRename", { markerId });
    await sleep(450);
    const s = await sel({});
    check("E0 CONTROL — the field is focused", s.textEditing === true,
      `textEditing=${s.textEditing} (if false this leg is void)`);
    const r = await press("right", clipId);
    check("E1 ⭐ an arrow does NOT move the user's clips while typing", !r.movedBeat,
      `startBeat ${r.from}->${r.to}`);
    if (r.hasEcho) {
      check("E2 the monitor names WHY it stood down", r.refusedBy === "text-editing",
        `arrowNudgeMonitorRefusedBy=${JSON.stringify(r.refusedBy)}`);
    } else {
      console.log("   SKIP  E2 — no `arrowNudgeMonitorRefusedBy` echo on this binary");
    }
    await req("debug.markerRename", { cancel: true });
    await sleep(400);
  }

  console.log("\n════ F — AUTO-REPEAT: a HELD arrow still walks the clip ════");
  {
    await enterFocusLostState();
    const r = await press("right", clipId, { isRepeat: true });
    check("F  isRepeat:true moves the clip (the OPPOSITE of delete's guard)",
      r.movedBeat, `startBeat ${r.from}->${r.to}`);
  }

  console.log("\n════ G/H/I — THE GUARDS STILL REFUSE ════");
  {
    await reset();
    await req("ui.showMixer", { show: true });
    await sleep(400);
    const g = await press("right", clipId);
    check("G  the Mix console: an arrow moves nothing", !g.movedBeat,
      `startBeat ${g.from}->${g.to}`);
    await req("ui.showMixer", { show: false });
    await sleep(400);

    await reset();
    await req("debug.undoHistory", { open: true });
    await sleep(400);
    const h = await press("right", clipId);
    check("H  a modal is up: an arrow moves nothing", !h.movedBeat,
      `startBeat ${h.from}->${h.to}`);
    await req("debug.undoHistory", { close: true });
    await sleep(400);

    await reset();
    await sel({ act: "pianoRollNotes", select: true });
    await sleep(350);
    const i = await press("right", clipId);
    check("I  the roll holds notes: the shield still holds", !i.movedBeat,
      `startBeat ${i.from}->${i.to}`);
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(300);
  }

  console.log("\n════ J — NEGATIVE CONTROL: a NON-text overlay does not break focus ════");
  {
    await reset();
    await req("debug.undoHistory", { open: true });
    await sleep(400);
    await req("debug.undoHistory", { close: true });
    await sleep(500);
    const s = await sel({});
    check("J0 CONTROL — a non-text modal leaves SwiftUI focus ALIVE",
      s.keyPressProbe?.arrangeWorkspaceFocused === true,
      `wsFocus=${s.keyPressProbe?.arrangeWorkspaceFocused}`
      + " (this is what makes B's dead state specific to TEXT FIELDS)");
    const r = await press("right", clipId);
    check("J1 the arrow works after a non-text modal", r.movedBeat,
      `startBeat ${r.from}->${r.to}`);
  }

  console.log("\n════ RESULT ════");
  const failed = checks.filter((c) => !c.ok);
  if (failed.length) {
    console.log("   failing legs:");
    for (const c of failed) console.log(`     • ${c.name}`);
  }
  verdict({ ran: checks.length, failed: failed.length });
} catch (e) {
  console.error("GATE ERROR", e);
  process.exitCode = 2;
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
