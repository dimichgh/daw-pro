// m23-cf-3 PROBE — does a REAL DELETE key event reach a SwiftUI
// `.onKeyPress(.delete)`, or only AppKit?
//
// ⚠️ A PROBE, NOT A GATE: it MEASURES and prints; it asserts a verdict but its
// purpose is the three numbers, not a pass/fail. Staging (17695) only.
//
// ═══ WHY ═══
// The user tested a FRESH bundle (2026-08-10) and reported three results:
//   ① piano-roll note selected + DELETE  → does not work
//   ② arrange clip selected + DELETE     → does not work
//   ③ rename text field + DELETE         → WORKS (deletes text)
// ③ is load-bearing: the AppKit field editor consumed the key, so the key IS
// delivered to the app, to the key window, and to the focused responder.
// Delivery is not the problem. ①② are both SwiftUI `.onKeyPress(.delete)`
// surfaces and both are dead.
//
// This probe reproduces all three HEADLESSLY, on the real event queue:
//   E1 = ③  post DELETE with a rename field focused → does `fieldText` shrink?
//   E2 = ①② post DELETE with a clip selected, no text focus → does
//           `deleteKeyFunnelSeq` (bumped at the TOP of `handleDeleteKey`, which
//           every `.onKeyPress(.delete)` closure calls) move?
//   E3 = ⭐ THE CONTROL. Post a SPACE in E2's exact state. Space rides
//           `spaceKeyMonitor` (an `NSEvent` local monitor,
//           `DAWProApp.swift:2285`) which BYPASSES SwiftUI focus. If the
//           transport toggles, `NSApp.postEvent` works and E2's silence is the
//           app's, not the injection's. WITHOUT E3, E2 PROVES NOTHING.
//
//   node scripts/gates/_m23cf3-onkeypress-probe.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m23cf3probe";
const PORT = STAGING_PORT;
const OUT = "/tmp/m23cf3probe";
const PIDFILE = "/tmp/m23cf3probe-staging.pid";

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

buildOrAbort({ label: "building staging binary (m23cf3 probe)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

const sel = (p = {}) => req("debug.arrangeSelection", p);
const ks = (p = {}) => req("debug.keySpace", p);
const results = {};

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackId = (await req("track.add", { kind: "instrument", name: "PB" })).id;
  const clipId = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: 8,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await req("marker.add", { beat: 16, name: "RenameMe" });
  await sleep(300);

  // ── E1 = the user's ③ — the AppKit field editor ─────────────────────────
  await req("debug.markerRename", {});
  await sleep(400);
  const beforeField = await ks({});
  await sel({ act: "keyDelete", post: true });
  await sleep(700);
  const afterField = await ks({});
  results.E1 = {
    responder: beforeField.firstResponder,
    responderClass: beforeField.responderClass,
    textBefore: beforeField.fieldText,
    textAfter: afterField.fieldText,
    consumed: typeof beforeField.fieldText === "string"
      && typeof afterField.fieldText === "string"
      && afterField.fieldText.length < beforeField.fieldText.length,
  };
  console.log("\nE1 (user's ③ — DELETE into a focused rename field):");
  console.log(`   responder      = ${results.E1.responder} (${results.E1.responderClass})`);
  console.log(`   fieldText      = ${JSON.stringify(results.E1.textBefore)}`
    + ` -> ${JSON.stringify(results.E1.textAfter)}`);
  console.log(`   AppKit CONSUMED the key = ${results.E1.consumed}`);

  await req("debug.markerRename", { clear: true });
  await sleep(400);

  // ── E2 = the user's ①② — a SwiftUI `.onKeyPress(.delete)` surface ───────
  await sel({ act: "click", clipId });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(400);
  const s0 = await sel({});
  const clipsBefore = (await req("debug.editClipboard", {})).clips.length;
  await sel({ act: "keyDelete", post: true });
  await sleep(700);
  const s1 = await sel({});
  const clipsAfter = (await req("debug.editClipboard", {})).clips.length;
  results.E2 = {
    textEditing: s0.textEditing,
    selected: s0.count,
    responder: (await ks({})).firstResponder,
    funnelBefore: s0.deleteKeyFunnelSeq,
    funnelAfter: s1.deleteKeyFunnelSeq,
    monitorSeq: `${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`,
    monitorRefusedBy: s1.deleteKeyMonitorRefusedBy,
    clipsBefore,
    clipsAfter,
    reachedHandler: s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq,
    clipDeleted: clipsAfter === clipsBefore - 1,
  };
  console.log("\nE2 (user's ①② — DELETE with a clip selected, no text focus):");
  console.log(`   textEditing    = ${results.E2.textEditing}, selected = ${results.E2.selected}`);
  console.log(`   firstResponder = ${results.E2.responder}`);
  console.log(`   deleteKeyMonitorSeq = ${results.E2.monitorSeq}`
    + ` refusedBy=${JSON.stringify(results.E2.monitorRefusedBy)}`);
  console.log(`   deleteKeyFunnelSeq  = ${results.E2.funnelBefore} -> ${results.E2.funnelAfter}`);
  console.log(`   the DELETE HANDLER ran = ${results.E2.reachedHandler}`);
  console.log(`   clips ${clipsBefore} -> ${clipsAfter}  (deleted = ${results.E2.clipDeleted})`);

  // ── E3 = ⭐ THE CONTROL — the same queue, a key that bypasses SwiftUI ────
  const t0 = await ks({});
  await ks({ press: true, post: true });
  await sleep(700);
  const t1 = await ks({});
  results.E3 = {
    playingBefore: t0.isPlaying,
    playingAfter: t1.isPlaying,
    monitorInstalled: t1.monitorInstalled,
    queueWorks: t0.isPlaying !== t1.isPlaying,
  };
  console.log("\nE3 (CONTROL — a POSTED SPACE in E2's exact state):");
  console.log(`   spaceKeyMonitor installed = ${results.E3.monitorInstalled}`);
  console.log(`   isPlaying      = ${results.E3.playingBefore} -> ${results.E3.playingAfter}`);
  console.log(`   NSApp.postEvent DELIVERS = ${results.E3.queueWorks}`);
  if (t1.isPlaying) await req("transport.stop");

  // ── VERDICT — TWO-SIDED ─────────────────────────────────────────────────
  //
  // ⚠️ E1 IS THE ANTI-REGRESSION CONTROL, NOT DECORATION. A delete monitor that
  // swallowed unconditionally would make E2 green and would ALSO break every
  // rename field in the app; only E1 can tell those apart. Both must hold.
  console.log("\n════ VERDICT ════");
  if (!results.E3.queueWorks) {
    console.log("INCONCLUSIVE: the CONTROL failed — a posted SPACE did not reach the");
    console.log("monitor either, so E2 says nothing either way. Fix the injection first.");
    process.exit(3);
  }
  if (!results.E1.consumed) {
    console.log("REGRESSION: the rename field NO LONGER consumes DELETE. A delete");
    console.log("monitor that swallows while text is focused has stolen Backspace from");
    console.log("every rename field in the app — the m17-d trap. This is WORSE than the");
    console.log("bug it was meant to fix.");
    process.exit(1);
  }
  if (!results.E2.reachedHandler) {
    console.log("THE BUG, REPRODUCED HEADLESSLY (this was the state on 2026-08-10 before");
    console.log("the m23-cf-3 monitor landed). The queue delivers (E3), AppKit's field");
    console.log("editor consumes DELETE (E1 = the user's ③), and NOTHING routes it to a");
    console.log("delete handler (E2 = the user's ①②).");
    console.log("=> The key reaches AppKit and never reaches SwiftUI `.onKeyPress`. The");
    console.log("   one-funnel routing fix could not have addressed this: no claimant is");
    console.log("   ever ASKED. The fix is an NSEvent monitor, like the space bar's.");
    process.exit(1);
  }
  if (!results.E2.clipDeleted) {
    console.log("PARTIAL: the handler RAN but the clip did not go. The eligibility half");
    console.log("is fixed and the correctness half refused — read deleteKeySurface /");
    console.log("deleteKeyRefusedBy via `debug.arrangeSelection {act:\"deleteKey\"}`.");
    process.exit(1);
  }
  console.log("FIXED, AND WITHOUT THE m17-d TRAP.");
  console.log("  E3 the queue delivers · E1 a rename field STILL eats DELETE (no theft)");
  console.log("  E2 a real DELETE now reaches the handler AND removes the clip");
  console.log("=> The user's ①② are closed at the eligibility tier; ③ is unchanged.");
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
