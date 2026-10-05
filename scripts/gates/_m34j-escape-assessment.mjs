#!/usr/bin/env node
// m34-j — DOES **ESCAPE** RIDE THE SAME DEAD ROUTE THE ARROWS DID?
//
// ⚠️ A PROBE, NOT A GATE, AND DELIBERATELY NOT A FIX. m34-j's scope is the arrow
// nudges; the item asks for an ASSESSMENT of Escape WITH A COST and says not to
// expand scope unilaterally. This measures the assessment instead of asserting
// it, because "it rides the same `@FocusState`, so it must be dead too" is
// exactly the kind of structural inference this tree keeps finding to be half
// right (m34-j's own premise was a structural inference, and it was wrong).
//
// ═══ THE INSTRUMENT ALREADY EXISTS, WHICH IS WHY THIS IS CHEAP ═══
//
// `AppModel.handleEditorEscape` bumps `editorEscapeMountHits` as its FIRST
// statement (m25-b-1), and `debug.panelLayout` echoes both that counter AND
// `editorMaximized`. So the two questions separate exactly as they do for the
// arrows:
//   • hits did NOT climb  → SwiftUI never delivered Escape. The m34-j defect.
//   • hits climbed, `editorMaximized` unchanged → a guard declined it.
//
//   E1  BASELINE — maximize the editor, post Escape, expect it to un-maximize.
//   E2  ⭐ THE SAME KEY IN THE MEASURED DEAD STATE (rename → dismiss).
//   E3  RECOVERY — click the clip, post Escape again, expect it to work.
//
//   node scripts/gates/_m34j-escape-assessment.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m34jesc";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34jesc";
const PIDFILE = "/tmp/m34jesc-staging.pid";
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

buildOrAbort({ label: "building staging binary (m34-j escape assessment)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();
const sel = (p = {}) => req("debug.arrangeSelection", p);
const layout = (p = {}) => req("debug.panelLayout", p);

async function postEscape() {
  const b = await layout({});
  await sel({ act: "postKey", key: "escape" });
  await sleep(SETTLE);
  const a = await layout({});
  return {
    hitsBefore: b.editorEscapeMountHits, hitsAfter: a.editorEscapeMountHits,
    reached: a.editorEscapeMountHits !== b.editorEscapeMountHits,
    maxBefore: b.editorMaximized, maxAfter: a.editorMaximized,
    exited: b.editorMaximized === true && a.editorMaximized === false,
  };
}
const show = (r) => `hits ${r.hitsBefore}->${r.hitsAfter} (reached=${r.reached})`
  + `   editorMaximized ${r.maxBefore}->${r.maxAfter} (exited=${r.exited})`;

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "ESC" })).id;
  const clipId = (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 8, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const markerId = (await req("marker.add", { beat: 0, name: "RenameMe" })).id;

  async function reset() {
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(350);
  }

  // ── E1 — BASELINE ────────────────────────────────────────────────────────
  await reset();
  await layout({ editorMaximized: true });
  await sleep(350);
  const e1 = await postEscape();
  console.log("\n════ E1 — BASELINE: Escape exits the maximized editor ════");
  console.log(`   ${show(e1)}`);

  // ── E2 — THE DEAD STATE ──────────────────────────────────────────────────
  await reset();
  await layout({ editorMaximized: true });
  await sleep(350);
  await req("debug.markerRename", { markerId });
  await sleep(400);
  const open = await sel({});
  await req("debug.markerRename", { cancel: true });
  await sleep(500);
  const dead = await sel({});
  console.log("\n════ E2 — ⭐ THE SAME KEY IN THE MEASURED DEAD STATE ════");
  console.log(`   control: field was focused = ${open.textEditing};`
    + ` wsFocus now = ${dead.keyPressProbe?.arrangeWorkspaceFocused}`
    + "   (must be false, or this leg is void)");
  const e2 = await postEscape();
  console.log(`   ${show(e2)}`);

  // ── E3 — RECOVERY ────────────────────────────────────────────────────────
  await reset();
  const e3 = await postEscape();
  console.log("\n════ E3 — RECOVERY: click the clip, press Escape again ════");
  console.log(`   ${show(e3)}`);

  console.log("\n════ ASSESSMENT ════");
  if (e1.exited && !e2.reached && e3.exited) {
    console.log("⛔ ESCAPE RIDES THE SAME DEAD ROUTE, MEASURED. It works normally,");
    console.log("   is DEAD ON DELIVERY in the state a dismissed text field leaves,");
    console.log("   and comes back when the clip is re-clicked — the arrows' exact");
    console.log("   signature. So the maximized note editor cannot be exited by the");
    console.log("   keyboard after ANY rename, until the user clicks a clip.");
  } else if (e1.exited && e2.reached) {
    console.log("✅ ESCAPE SURVIVES. It reached the handler in the dead state, so it");
    console.log("   is NOT a rider on this route and needs no rescue. Do not spend the");
    console.log("   Escape work on the strength of the arrows' diagnosis.");
  } else {
    console.log("⚠️ INCONCLUSIVE — read the three lines above. If E1 did not exit, the");
    console.log("   fixture never reached the state under test and E2 proves nothing.");
  }
  console.log("\n⚠️ THE OTHER THREE ESCAPE MOUNTS (PianoRollView, TimelineLanesView,");
  console.log("   TrackListView) ARE NOT MEASURED HERE — only ContentView's backstop");
  console.log("   has an observable counter. Their focus story is plausibly the same");
  console.log("   and is deliberately NOT claimed on this evidence.");
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
