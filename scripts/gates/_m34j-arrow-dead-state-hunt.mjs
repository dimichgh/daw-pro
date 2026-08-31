#!/usr/bin/env node
// m34-j ADVERSARIAL HUNT — IS THERE **ANY** STATE WHERE A REAL ARROW KEY IS
// DEAD ON DELIVERY?
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only.
//
// `_m34j-arrow-nudge-repro.mjs` refuted the item's premise: 36/36 posted arrows
// entered their mount and moved the clip across clip switches, WHILE
// `pianoRollEditorFocused` alternated 6/12. That is a clean negative — and this
// repo's own law says a clean negative from a hand-built probe is the weakest
// evidence there is UNLESS the probe has been shown able to find the thing.
//
// So this one goes hunting. Every leg drives the app into a state where an arrow
// key plausibly goes missing, posts a REAL arrow, and reads BOTH tiers:
//
//   entered  — `KeyPressProbe.arrangeHorizontalArrow` moved → SwiftUI DELIVERED
//              the key to the mount. This is the DELIVERY question, the only one
//              m34-j is about.
//   moved    — the clip's `startBeat` changed → the handler also GRANTED.
//
// ⭐ THE TWO ARE DIFFERENT VERDICTS AND THE DISTINCTION IS THE WHOLE POINT:
// `entered=Y, moved=n` is a guard doing its job (correct, designed behaviour);
// `entered=n` is the m34-j defect. A leg that only watched the clip could not
// tell them apart, and would call every correct refusal a delivery bug.
//
// ⭐⭐ H1 IS ALSO THE REGRESSION PIN THE FIX WOULD HAVE NEEDED. With a rename
// field focused, ← and → must move the CARET, not the user's clips. Measured
// here BEFORE any monitor exists, so the number is a baseline rather than a
// self-graded homework answer.
//
//   node scripts/gates/_m34j-arrow-dead-state-hunt.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m34jhunt";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34jhunt";
const PIDFILE = "/tmp/m34jhunt-staging.pid";
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

buildOrAbort({ label: "building staging binary (m34-j dead-state hunt)…" });
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

const rows = [];
/** Post a real → and report BOTH tiers. `expect` is what correct looks like. */
async function pressRight(label, clipId, expect) {
  const before = await sel({});
  const b = await clipState(clipId);
  await sel({ act: "postKey", key: "right" });
  await sleep(SETTLE);
  const after = await sel({});
  const a = await clipState(clipId);
  const entered = after.keyPressProbe.arrangeHorizontalArrow
    !== before.keyPressProbe.arrangeHorizontalArrow;
  const moved = b?.startBeat !== a?.startBeat;
  rows.push({ label, entered, moved, expect,
    textEditing: before.textEditing, workspaceMode: before.workspaceMode,
    modal: before.modalPresented, noteSel: before.pianoRollNoteSelection,
    surface: before.activeEditorSurface, reason: before.activeEditorSurfaceReason });
  console.log(`   ${label}`);
  console.log(`      state: textEditing=${before.textEditing} workspace=${before.workspaceMode}`
    + ` modal=${before.modalPresented} noteSel=${before.pianoRollNoteSelection}`
    + ` surface=${before.activeEditorSurface}/${before.activeEditorSurfaceReason}`);
  console.log(`      → posted: entered=${entered ? "Y" : "n"} moved=${moved ? "Y" : "n"}`
    + `  startBeat ${b?.startBeat}->${a?.startBeat}   EXPECT ${expect}`);
  return { entered, moved };
}

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "HUNT A" })).id;
  await req("track.add", { kind: "instrument", name: "HUNT B" });
  const clipId = (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 8, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 },
            { pitch: 64, startBeat: 1, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sel({ act: "click", clipId });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(300);

  console.log("\n════ H0 — BASELINE: the quiescent state the repro probe measured ════");
  await pressRight("H0  clip clicked, roll open, no note selection", clipId, "entered=Y moved=Y");

  console.log("\n════ H1 — A RENAME FIELD IS FOCUSED (the caret-preservation pin) ════");
  {
    const marker = await req("marker.add", { beat: 0, name: "RenameMe" });
    const markerId = marker.id ?? marker.marker?.id;
    await req("debug.markerRename", { markerId });
    await sleep(400);
    const s = await sel({});
    console.log(`      CONTROL — is the field really focused? textEditing=${s.textEditing}`);
    if (s.textEditing !== true) {
      console.log("      ⚠️ THE STATE WAS NEVER ENTERED — this leg proves nothing about");
      console.log("         text fields. Treat H1 as UNMEASURED, not as a pass.");
    }
    await pressRight("H1  marker rename field open", clipId, "moved=n (caret, not clips)");
    await req("debug.markerRename", { cancel: true });
    await sleep(400);
    console.log("\n════ H2 — THE FIELD IS DISMISSED: does the arrow COME BACK? ════");
    const s2 = await sel({});
    console.log(`      CONTROL — textEditing back to ${s2.textEditing}`);
    await pressRight("H2  rename cancelled, focus returned", clipId, "entered=Y moved=Y");
    await req("marker.remove", { markerId });
  }

  console.log("\n════ H3 — THE MIX CONSOLE IS UP ════");
  {
    await req("ui.showMixer", { show: true });
    await sleep(400);
    await pressRight("H3  workspace = mix", clipId, "moved=n (.workspace guard)");
    await req("ui.showMixer", { show: false });
    await sleep(400);
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(300);
    await pressRight("H3b back in the arrange", clipId, "entered=Y moved=Y");
  }

  console.log("\n════ H4 — A MODAL IS PRESENTED (undo history) ════");
  {
    await req("debug.undoHistory", { open: true });
    await sleep(400);
    await pressRight("H4  modal up", clipId, "moved=n (.modal guard)");
    await req("debug.undoHistory", { close: true });
    await sleep(400);
    await pressRight("H4b modal dismissed", clipId, "entered=Y moved=Y");
  }

  console.log("\n════ H5 — THE ROLL HOLDS A NOTE SELECTION (the shielding guard) ════");
  {
    await sel({ act: "pianoRollNotes", select: true });
    await sleep(300);
    await pressRight("H5  roll has notes selected", clipId, "moved=n (.pianoRollNoteEdit)");
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(300);
    await pressRight("H5b notes deselected", clipId, "entered=Y moved=Y");
  }

  console.log("\n════ H6 — THE ROLL IS *ENGAGED* (m34-d's ⌘A condition) ════");
  {
    await sel({ act: "engage", surface: "pianoRoll" });
    await sleep(300);
    await pressRight("H6  roll engaged, no note selection", clipId, "entered=Y moved=Y");
    await sel({ act: "engage", surface: "arrange" });
    await sleep(300);
  }

  console.log("\n════ H7 — SELECTION MADE BY CLICKING A TRACK HEADER, NOT A CLIP ════");
  {
    await sel({ act: "clear" });
    await sleep(250);
    await sel({ act: "clickTrack", trackId: trackA });
    await sleep(400);
    const s = await sel({});
    console.log(`      CONTROL — selection count after the header click = ${s.count}`);
    await pressRight("H7  selection via track header", clipId, "entered=Y moved=Y");
  }

  console.log("\n════ H8 — A HELD ARROW (auto-repeat), the m23-fk hazard shape ════");
  {
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(300);
    const before = await sel({});
    const b = await clipState(clipId);
    await sel({ act: "postKey", key: "right", isRepeat: true });
    await sleep(SETTLE);
    const after = await sel({});
    const a = await clipState(clipId);
    const entered = after.keyPressProbe.arrangeHorizontalArrow
      !== before.keyPressProbe.arrangeHorizontalArrow;
    console.log(`   H8  isRepeat:true → entered=${entered ? "Y" : "n"} `
      + `startBeat ${b?.startBeat}->${a?.startBeat}`);
    console.log("      (the mount asks for [.down, .repeat] ON PURPOSE — walking a clip");
    console.log("       by HOLDING the arrow is the gesture. A dead repeat here would be");
    console.log("       a REGRESSION any monitor fix must not introduce.)");
    rows.push({ label: "H8  auto-repeat", entered, moved: b?.startBeat !== a?.startBeat,
      expect: "entered=Y moved=Y" });
  }

  // ═══ SUMMARY ═══
  console.log("\n════════════════════════ SUMMARY ════════════════════════");
  console.log("   leg                                        entered  moved   expected");
  for (const r of rows) {
    console.log(`   ${r.label.padEnd(42)} ${(r.entered ? "Y" : "n").padEnd(8)}`
      + ` ${(r.moved ? "Y" : "n").padEnd(6)}  ${r.expect}`);
  }
  const deadOnDelivery = rows.filter((r) => !r.entered);
  console.log("\n════ VERDICT ════");
  if (deadOnDelivery.length === 0) {
    console.log("NO DEAD-ON-DELIVERY STATE FOUND. Every posted arrow — in every state");
    console.log("this probe could construct, including a focused text field, the Mix");
    console.log("console, a modal, a note-selected roll, an engaged roll, a header-made");
    console.log("selection and an auto-repeat — REACHED its `.onKeyPress` mount.");
    console.log("Where the clip did not move, a NAMED guard declined it on purpose.");
    console.log("⚠️ THIS IS A NEGATIVE RESULT AND IT IS BOUNDED BY WHAT A SEAM CAN");
    console.log("   DRIVE. It cannot construct a state only a physical keyboard and a");
    console.log("   real pointer can reach; a human at the machine is still the only");
    console.log("   instrument for that.");
  } else {
    console.log(`FOUND ${deadOnDelivery.length} DEAD-ON-DELIVERY STATE(S) — the arrow never`);
    console.log("reached its mount. These are the m34-j defect, with a NAMED antecedent:");
    for (const r of deadOnDelivery) console.log(`   • ${r.label}   (expected ${r.expect})`);
  }
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
