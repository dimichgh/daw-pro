#!/usr/bin/env node
// m34-j — IS THE `NSEvent` MONITOR ROUTE ALIVE IN THE EXACT STATE WHERE SwiftUI
// FOCUS IS DEAD?
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only.
//
// The characterisation probe pinned the defect: dismissing a text field drops
// `ArrangeDeleteKey`'s `@FocusState` (`wsFocus` 1 → 0) and never restores it, so
// every `.onKeyPress` mount on that view — both arrow axes AND the Escape
// backstop — is dead until the user clicks a clip again.
//
// THE FIX CHOICE TURNS ON ONE FACT THIS PROBE MEASURES, AND ON NOTHING ELSE:
// the proposed remedy is the shipped ⌫/space pattern — a headless predicate plus
// the existing app-wide `NSEvent` monitor. That remedy is only viable if the
// MONITOR still sees keys in the dead state. It might not: the monitor's own
// `transportKeyWindow` guard requires the event to target the content window,
// and whatever swallowed SwiftUI's focus might have moved the responder too.
//
//   L1  Reach the dead state (rename → cancel) and CONFIRM it (`wsFocus` 0).
//   L2  Post ⌫ there. `deleteKeyMonitorSeq` must move — that is the monitor
//       SEEING the key — and `deleteKeyMonitorRefusedBy` must be null, which is
//       the monitor ACCEPTING it. Both, not either.
//   L3  Did the clip actually get deleted? The end-to-end proof that the monitor
//       route works while the SwiftUI route is dead.
//   L4  NEGATIVE CONTROL: the same ⌫ with the rename field OPEN must be refused
//       `.textEditing`. Without L4, L2's "accepted" could be a monitor that
//       accepts everything, and the caret-safety argument would be unfounded.
//
//   node scripts/gates/_m34j-monitor-viability.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m34jviab";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34jviab";
const PIDFILE = "/tmp/m34jviab-staging.pid";
const SETTLE = 500;

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

buildOrAbort({ label: "building staging binary (m34-j monitor viability)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();
const sel = (p = {}) => req("debug.arrangeSelection", p);

const clipCount = async () => {
  const tracks = (await req("project.snapshot", {})).tracks ?? [];
  return tracks.reduce((n, t) => n + (t.clips?.length ?? 0), 0);
};

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "VIAB" })).id;
  const markerId = (await req("marker.add", { beat: 0, name: "RenameMe" })).id;
  const mkClip = async () => (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 16, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;

  // ── L1 — reach the dead state and CONFIRM it ─────────────────────────────
  let clipId = await mkClip();
  await sel({ act: "click", clipId });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(350);
  await req("debug.markerRename", { markerId });
  await sleep(400);
  await req("debug.markerRename", { cancel: true });
  await sleep(500);

  const dead = await sel({});
  console.log("\n════ L1 — THE DEAD STATE, CONFIRMED ════");
  console.log(`   wsFocus(@FocusState) = ${dead.keyPressProbe.arrangeWorkspaceFocused}`
    + `   textEditing = ${dead.textEditing}   selCount = ${dead.count}`);
  const arrowBefore = dead.keyPressProbe.arrangeHorizontalArrow;
  await sel({ act: "postKey", key: "right" });
  await sleep(SETTLE);
  const stillDead = await sel({});
  console.log(`   → posted: arrow mount entered = `
    + `${stillDead.keyPressProbe.arrangeHorizontalArrow !== arrowBefore}`
    + `   (false = the SwiftUI route is dead here, as characterised)`);

  // ── L2 + L3 — the MONITOR route in that same state ───────────────────────
  console.log("\n════ L2/L3 — THE `NSEvent` MONITOR IN THE SAME DEAD STATE ════");
  const b = await sel({});
  const nBefore = await clipCount();
  await sel({ act: "keyDelete", post: true });
  await sleep(SETTLE);
  const a = await sel({});
  const nAfter = await clipCount();
  const monitorSaw = a.deleteKeyMonitorSeq !== b.deleteKeyMonitorSeq;
  console.log(`   deleteKeyMonitorSeq  ${b.deleteKeyMonitorSeq} -> ${a.deleteKeyMonitorSeq}`
    + `   saw the key = ${monitorSaw}`);
  console.log(`   refusedBy            ${JSON.stringify(a.deleteKeyMonitorRefusedBy)}`
    + `   (null = ACCEPTED)`);
  console.log(`   clips                ${nBefore} -> ${nAfter}`
    + `   deleted = ${nAfter === nBefore - 1}`);

  // ── L4 — NEGATIVE CONTROL: the monitor must REFUSE with a field open ─────
  console.log("\n════ L4 — NEGATIVE CONTROL: same key, rename field OPEN ════");
  clipId = await mkClip();
  await sel({ act: "click", clipId });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(350);
  await req("debug.markerRename", { markerId });
  await sleep(450);
  const cb = await sel({});
  const cn = await clipCount();
  console.log(`   control: textEditing = ${cb.textEditing} (must be true, or this leg is void)`);
  await sel({ act: "keyDelete", post: true });
  await sleep(SETTLE);
  const ca = await sel({});
  const cn2 = await clipCount();
  console.log(`   deleteKeyMonitorSeq  ${cb.deleteKeyMonitorSeq} -> ${ca.deleteKeyMonitorSeq}`);
  console.log(`   refusedBy            ${JSON.stringify(ca.deleteKeyMonitorRefusedBy)}`
    + `   (want "text-editing")`);
  console.log(`   clips                ${cn} -> ${cn2}   (must be UNCHANGED)`);
  await req("debug.markerRename", { cancel: true });

  console.log("\n════ WHAT THIS DECIDES ════");
  if (monitorSaw && a.deleteKeyMonitorRefusedBy === null) {
    console.log("THE MONITOR ROUTE IS ALIVE where the SwiftUI route is dead, AND it");
    console.log("refuses on a focused text field. So the shipped ⌫/space pattern is");
    console.log("viable for the arrows, and the responder classifier is the");
    console.log("caret-safety guarantee the brief asked to be named.");
  } else {
    console.log("⚠️ THE MONITOR ROUTE IS *NOT* CLEANLY ALIVE HERE. A monitor backstop");
    console.log("would inherit the same failure, and the fix must instead RESTORE the");
    console.log("focus the text field took.");
  }
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
