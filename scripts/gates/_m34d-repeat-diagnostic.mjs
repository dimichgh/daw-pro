#!/usr/bin/env node
// m34-d DIAGNOSTIC — WHY DOES A POSTED ⌘A SOMETIMES NOT DISPATCH?
//
// ⭐⭐ THIS PROBE'S ANSWER IS WHY `m34d-select-all-editor-open.mjs` HAS TWO
// TIERS. The gate's repeatability leg was red twice in a row and green in a
// probe running the same code, which is the shape of an environment variable
// nobody had named. Three runs of this probe, reading `appActive` and the new
// `pianoRollSelectAllNonce` alongside the policy's own verdict, correlate
// EXACTLY:
//
//   run 1  appActive=true   selectAllNonce 0→1→2→3→4→5   every ⌘A dispatched
//   run 2  appActive=true   selectAllNonce 0→1→2→3→4→5   every ⌘A dispatched
//   run 3  appActive=false  selectAllNonce 0→1 then FROZEN — every later ⌘A
//                           did nothing, while the POLICY read
//                           "piano-roll-notes" throughout
//
// MECHANISM: AppKit dispatches a posted MENU KEY EQUIVALENT only while the app
// is ACTIVE — an inactive app has no `keyWindow`, so `NSApp.target(forAction:)`
// finds no target and the item is never validated or fired. Staging
// DELIBERATELY never calls `NSApp.activate` (it must not steal the user's system
// focus), so it can run inactive. This is the m23-fi law already recorded on
// `debug.keySpace`'s `appActive` field, reaching a second feature.
//
// ⚠️ IT IS A HARNESS CONDITION, NOT A PRODUCT DEFECT: a real user pressing ⌘A is
// by definition in the active app. The gate therefore SKIPS its real-key legs
// when `appActive` is false rather than reddening — a red there would be a false
// negative about the product.
//
// Also the origin of the gate's `pianoRollSelectAllNonce` + `selectAllMenuItem`
// echo fields: with only `pianoRollNoteSelection`, "the menu was never invoked"
// and "it was invoked and the roll ignored it" are the same reading.
import { buildOrAbort, startStaging, stopStaging, sleep } from "./_staging.mjs";

const GATE = "m34d-repeat-diagnostic";
const PORT = 17695;
buildOrAbort({ label: "building (m34-d diagnostic)…" });
startStaging({ gate: GATE, port: PORT });

async function connect() {
  for (let i = 0; i < 40; i++) {
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
      const req = (command, params = {}) => new Promise((resolve, reject) => {
        const id = String(nextId++);
        pending.set(id, { resolve, reject, command });
        ws.send(JSON.stringify({ id, command, params }));
        setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
      });
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const CMD_A = { act: "postKey", key: "escape", keyCode: 0, charCode: 97, command: true };
let ws;
try {
  const c = await connect(); ws = c.ws; const req = c.req;
  const sel = (p = {}) => req("debug.arrangeSelection", p);
  const dump = async (label) => {
    const s = await sel({});
    const k = await req("debug.keySpace", {});
    console.log(`${label.padEnd(28)} notes=${String(s.pianoRollNoteSelection).padEnd(5)} nonce=${s.pianoRollSelectAllNonce} policy=${s.selectAllMenuItem?.surface ?? s.selectAllMenuItem?.refusedBy}/n${s.selectAllMenuItem?.rollNoteCount} `
      + `editorClip=${s.editorClipId ? "yes" : "NULL"} count=${s.count} `
      + `ws=${s.workspaceMode} textEditing=${s.textEditing} `
      + `appActive=${k.appActive} keyWin=${k.windowRole} resp=${k.firstResponder}`);
    return s;
  };

  await req("project.new", { discardChanges: true });
  const track = await req("track.add", { name: "Keys", kind: "instrument" });
  const trackId = track.id ?? track.track?.id;
  const mk = (b) => req("clip.addMIDI", {
    trackId, atBeat: b, lengthBeats: 4,
    notes: [0, 1, 2].map((i) => ({ pitch: 60 + i, velocity: 100, startBeat: b + i, lengthBeats: 1 })),
  });
  const clipA = (await mk(0)).id;
  await mk(8);

  await sel({ act: "click", clipId: clipA });
  await sleep(700);
  await dump("F0 fixture");
  await sel(CMD_A); await sleep(700);
  await dump("A1 after 1st ⌘A");

  // B1 space control
  await req("debug.keySpace", { press: true, post: true }); await sleep(700);
  await req("transport.stop", {});
  await sel({ act: "pianoRollNotes", select: false }); await sleep(700);
  await sel({ act: "postKey", key: "escape", keyCode: 0, charCode: 97 }); await sleep(700);
  await dump("B2 after bare a");

  // ⭐ CHECKPOINT 1: does ⌘A still work HERE (before any marker/mixer step)?
  await sel(CMD_A); await sleep(900);
  await dump("X1 ⌘A after B legs");

  // C legs — marker rename
  await req("marker.add", { beat: 8, name: "RenameMe" });
  await req("debug.markerRename", {}); await sleep(700);
  await dump("C0 field focused");
  await sel({ act: "pianoRollNotes", select: false }); await sleep(700);
  await sel(CMD_A); await sleep(700);
  await dump("C1 ⌘A into field");
  await sel({ act: "keyDelete", post: true }); await sleep(700);
  await dump("C2 after ⌫");
  await req("debug.markerRename", { clear: true }); await sleep(700);
  await dump("C3 focus cleared");

  // ⭐ CHECKPOINT 2: does ⌘A work right after the marker legs?
  await sel(CMD_A); await sleep(900);
  await dump("X2 ⌘A after C legs");

  // D1 — clear
  await sel({ act: "clear" }); await sleep(700);
  await sel(CMD_A); await sleep(700);
  await dump("D1 ⌘A with no roll");

  // ⭐ MIRRORS THE GATE EXACTLY from here (no extra checkpoint), so the
  // failing E1 is reproduced rather than stepped around.
  await sel({ act: "click", clipId: clipA }); await sleep(700);
  await sel({ act: "pianoRollNotes", select: false });
  await req("ui.showMixer", { show: true }); await sleep(700);
  await dump("D2 in mixer");
  await sel(CMD_A); await sleep(700);
  await dump("D2 after mixer CMD_A");
  await req("ui.showMixer", { show: false }); await sleep(700);
  await dump("D2 back in arrange");

  // E — arm the non-trivial way, then the failing press.
  await sel({ act: "pianoRollNotes", select: true }); await sleep(700);
  await dump("E0 staged true");
  await sel({ act: "pianoRollNotes", select: false }); await sleep(700);
  await dump("E0 staged false");
  await sel(CMD_A); await sleep(900);
  await dump("E1 after CMD_A");
  await sel(CMD_A); await sleep(1500);
  await dump("E1 after 2nd CMD_A");
} finally {
  try { ws?.close(); } catch {}
  stopStaging(GATE);
}
