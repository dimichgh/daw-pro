#!/usr/bin/env node
// m34-d REPRODUCTION PROBE — is ⌘A's first press really refused by the POLICY,
// or is it a delivery problem?
//
// ⚠️ RUN THIS BEFORE ANY EDIT. The item's brief assumed ⌘A was like ⌫ (no
// working delivery route, needs an NSEvent monitor). The source says otherwise:
// ⌘A rides the AppKit responder chain (`ClipboardResponder.selectAll(_:)` +
// `validateMenuItem` → `SelectAllMenuPolicy`), and the user reports it works
// after one click in the roll. If that is right, the ONLY defect is the policy's
// first guard — which reads the ENGAGEMENT verdict (`activeEditorSurface`) and
// therefore answers `.arrange` for a roll that is open but not yet clicked in.
//
// METHOD, and the control is the whole point:
//
//   A. Open the roll by CLICKING THE CLIP IN THE ARRANGE (the user's gesture).
//      Read `activeEditorSurfaceReason`. Expect "engagedArrange".
//   B. Post a REAL ⌘A NSEvent through `NSApp.postEvent` — the real queue, real
//      `NSApplication.sendEvent`, real main-menu key-equivalent dispatch.
//      Expect the roll's note selection to STAY EMPTY. That is the bug.
//   C. ⭐ THE POSITIVE CONTROL: engage the roll (`act:"engage"`), post the SAME
//      ⌘A again. Expect the selection to fill. Without C, B's "nothing
//      happened" could be the injection failing rather than the app refusing —
//      the `_m23cf3-onkeypress-probe` E3 lesson, applied to this key.
//
// Staging 17695 only. 17600 is the user's live app and is never contacted.
import { buildOrAbort, startStaging, stopStaging, sleep } from "./_staging.mjs";

const GATE = "m34d-select-all-probe";
const PORT = 17695;

buildOrAbort({ label: "building staging binary (m34-d probe)…" });
startStaging({ gate: GATE, port: PORT });

async function connect() {
  for (let i = 0; i < 40; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => {
        ws.onopen = res;
        ws.onerror = () => rej(new Error("x"));
      });
      let nextId = 1;
      const pending = new Map();
      ws.onmessage = (ev) => {
        let m;
        try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id);
        if (!e) return;
        pending.delete(m.id);
        if (m.ok === false || m.error) {
          e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        } else {
          e.resolve(m.result ?? m);
        }
      };
      const req = (command, params = {}) => new Promise((resolve, reject) => {
        const id = String(nextId++);
        pending.set(id, { resolve, reject, command });
        ws.send(JSON.stringify({ id, command, params }));
        setTimeout(() => {
          if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
        }, 25000);
      });
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

// A REAL ⌘A: kVK_ANSI_A is 0, and the menu system matches key equivalents on
// `charactersIgnoringModifiers` ("a"), so both overrides are load-bearing.
// `key:"escape"` only picks the ProbeKey the seam requires; every field that
// matters is overridden.
const CMD_A = { act: "postKey", key: "escape", keyCode: 0, charCode: 97, command: true };

let ws;
try {
  const c = await connect();
  ws = c.ws;
  const req = c.req;

  await req("project.new", { discardChanges: true });
  const track = await req("track.add", { name: "Keys", kind: "instrument" });
  const trackId = track.id ?? track.track?.id;
  const clip = await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: 4,
    notes: [
      { pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 },
      { pitch: 64, velocity: 100, startBeat: 1, lengthBeats: 1 },
      { pitch: 67, velocity: 100, startBeat: 2, lengthBeats: 1 },
    ],
  });
  const clipId = clip.id ?? clip.clip?.id;
  console.log(`fixture: track=${trackId} clip=${clipId}`);

  // ── A: open the roll the way the user does — click the clip in the arrange ──
  const opened = await req("debug.arrangeSelection", { act: "click", clipId });
  console.log(`\nA. after clicking the clip in the arrange:`);
  console.log(`   editorClipId              = ${JSON.stringify(opened.editorClipId)}`);
  console.log(`   activeEditorSurface       = ${JSON.stringify(opened.activeEditorSurface)}`);
  console.log(`   activeEditorSurfaceReason = ${JSON.stringify(opened.activeEditorSurfaceReason)}`);
  console.log(`   lastEngagedSurface        = ${JSON.stringify(opened.lastEngagedSurface)}`);
  console.log(`   pianoRollNoteSelection    = ${JSON.stringify(opened.pianoRollNoteSelection)}`);

  // ── B: THE BUG — a real ⌘A on the first press ──────────────────────────────
  await req("debug.arrangeSelection", CMD_A);
  await sleep(600);
  const afterFirst = await req("debug.arrangeSelection", {});
  console.log(`\nB. after a REAL ⌘A (first press, roll open, arrange engaged):`);
  console.log(`   pianoRollNoteSelection    = ${JSON.stringify(afterFirst.pianoRollNoteSelection)}`);
  console.log(`   activeEditorSurfaceReason = ${JSON.stringify(afterFirst.activeEditorSurfaceReason)}`);

  // ── C: THE POSITIVE CONTROL — engage the roll, same key again ──────────────
  await req("debug.arrangeSelection", { act: "engage", surface: "pianoRoll" });
  const engaged = await req("debug.arrangeSelection", {});
  console.log(`\nC. after engaging the roll:`);
  console.log(`   activeEditorSurfaceReason = ${JSON.stringify(engaged.activeEditorSurfaceReason)}`);
  await req("debug.arrangeSelection", CMD_A);
  await sleep(600);
  const afterSecond = await req("debug.arrangeSelection", {});
  console.log(`   after the SAME real ⌘A:`);
  console.log(`   pianoRollNoteSelection    = ${JSON.stringify(afterSecond.pianoRollNoteSelection)}`);

  console.log(`\n─── READING ───`);
  const bugReproduced = opened.activeEditorSurfaceReason === "engagedArrange"
    && afterFirst.pianoRollNoteSelection === false;
  const controlHeld = afterSecond.pianoRollNoteSelection === true;
  console.log(`bug reproduced (A engagedArrange + B no selection) = ${bugReproduced}`);
  console.log(`positive control held  (C selects via the SAME key) = ${controlHeld}`);
  if (bugReproduced && controlHeld) {
    console.log(`\n⭐ DIAGNOSIS CONFIRMED: ⌘A is DELIVERED on the first press — the real`);
    console.log(`   event reaches the real menu — and the POLICY refuses it because the`);
    console.log(`   engagement verdict is "engagedArrange". Fix the gate, not the delivery.`);
  } else if (!controlHeld) {
    console.log(`\n⛔ THE CONTROL DID NOT HOLD — B proves nothing. Either the posted ⌘A`);
    console.log(`   never reaches the menu, or the roll's report is not observable here.`);
    console.log(`   STOP AND RE-DIAGNOSE before editing anything.`);
  } else {
    console.log(`\n⛔ A did not read "engagedArrange" — the premise of the fix is wrong.`);
    console.log(`   STOP AND RE-DIAGNOSE.`);
  }
} finally {
  try { ws?.close(); } catch {}
  stopStaging(GATE);
}
