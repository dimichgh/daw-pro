// m23-cf-3 PROBE ② — IS THE DELETE HANDLER ENTERED INTERMITTENTLY, OR NEVER?
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only.
//
// ═══ THE QUESTION, AND WHY ONE PRESS CANNOT ANSWER IT ═══
//
// `DAWProApp.swift` records that `pianoRollEditorFocused` alternates 6 true /
// 6 false across 12 CONSECUTIVE CLIP SELECTIONS, strictly alternating, with the
// editor open throughout. If DELETE rode that focus, the handler would be
// entered on HALF the presses — and a single-shot probe would land on one
// parity and report either "always works" or "never works", both wrong.
//
// So this presses DELETE once per selection, TWELVE times, and counts.
//   0/12  → the handler is NEVER entered. Focus alternation is irrelevant to
//           DELETE, because nothing routes the key to a claimant at all.
//   ~6/12 → INTERMITTENT, and the parity string will show the alternation.
//   12/12 → always entered.
//
// ⭐ THE DISCRIMINATION THIS EXISTS FOR: "the handler is never invoked" (a) vs
// "the handler is invoked and decides to do nothing" (b). `deleteKeyFunnelSeq`
// is bumped as the FIRST statement of `handleDeleteKey`, before any guard, so it
// separates them cleanly — (a) is the counter not moving, (b) is the counter
// moving with `deleteKeySurface` null.
//
// ⚠️ RUN IT TWICE to be worth anything: once with the m23-cf-3 NSEvent monitor
// live, and once with the monitor's delete branch disabled (the REDDEN). Only
// the second run measures the SwiftUI `.onKeyPress` path, because the monitor
// swallows the event before SwiftUI sees it.
//
//   node scripts/gates/_m23cf3-alternation-probe.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m23cf3alt";
const PORT = STAGING_PORT;
const OUT = "/tmp/m23cf3alt";
const PIDFILE = "/tmp/m23cf3alt-staging.pid";
const ROUNDS = 12;   // the same 12 the focus measurement used

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

buildOrAbort({ label: "building staging binary (m23cf3 alternation)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

const sel = (p = {}) => req("debug.arrangeSelection", p);
const cb = (p = {}) => req("debug.editClipboard", p);

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackId = (await req("track.add", { kind: "instrument", name: "ALT" })).id;

  const entered = [];   // per round: did `handleDeleteKey` run?
  const deleted = [];   // per round: did the clip actually go?
  const rollFocus = []; // per round: `pianoRollEditorFocused`, the alternating flag

  for (let i = 0; i < ROUNDS; i++) {
    // A FRESH CLIP EACH ROUND, because a successful delete consumes one. Each
    // click is a CLIP SELECTION — the very event the focus flag alternates on.
    const clipId = (await req("clip.addMIDI", {
      trackId, atBeat: 0, lengthBeats: 4,
      notes: [{ pitch: 60 + i, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(250);

    const before = await sel({});
    const clipsBefore = (await cb({})).clips.length;
    await sel({ act: "keyDelete", post: true });
    await sleep(450);
    const after = await sel({});
    const clipsAfter = (await cb({})).clips.length;

    entered.push(after.deleteKeyFunnelSeq !== before.deleteKeyFunnelSeq);
    deleted.push(clipsAfter === clipsBefore - 1);
    rollFocus.push(before.pianoRollEditorFocused);

    // Normalize so the next round starts from one clip, whatever happened.
    if (clipsAfter > 0) {
      const echo = await cb({});
      for (const c of echo.clips) await req("clip.remove", { clipId: c.id });
    }
  }

  const enteredCount = entered.filter(Boolean).length;
  const deletedCount = deleted.filter(Boolean).length;
  const focusTrue = rollFocus.filter(Boolean).length;
  const pattern = (a) => a.map((v) => (v ? "1" : "0")).join("");

  console.log(`\n════ ${ROUNDS} CONSECUTIVE CLIP SELECTIONS, ONE POSTED DELETE EACH ════`);
  console.log(`   handler ENTERED       ${enteredCount}/${ROUNDS}   ${pattern(entered)}`);
  console.log(`   clip actually DELETED ${deletedCount}/${ROUNDS}   ${pattern(deleted)}`);
  console.log(`   pianoRollEditorFocused ${focusTrue}/${ROUNDS}  ${pattern(rollFocus)}`);
  console.log("\n   (1 = yes. The focus row is the flag measured at 6/12 strictly");
  console.log("    alternating; it is printed to see whether DELETE tracks it.)");

  console.log("\n════ VERDICT ════");
  if (enteredCount === 0) {
    console.log(`NEVER ENTERED (0/${ROUNDS}). The discrimination is (a): the delete`);
    console.log("handler is not invoked at all — not invoked-and-declining. Focus");
    console.log("alternation cannot explain this: a coin flip does not land 12 times.");
  } else if (enteredCount === ROUNDS) {
    console.log(`ALWAYS ENTERED (${ROUNDS}/${ROUNDS}). Entry does NOT ride the alternating`);
    console.log("focus flag — which is the point of routing DELETE through an NSEvent");
    console.log("monitor rather than through SwiftUI focus.");
    if (focusTrue > 0 && focusTrue < ROUNDS) {
      console.log(`   ⭐ AND THE FLAG DID ALTERNATE (${focusTrue}/${ROUNDS}) DURING THIS RUN —`);
      console.log("      so this is a live demonstration of independence, not a run in");
      console.log("      which the coin happened to sit still.");
    } else {
      console.log(`   ⚠️ but the focus flag did NOT vary this run (${focusTrue}/${ROUNDS}), so`);
      console.log("      independence is not demonstrated here — only entry is.");
    }
  } else {
    console.log(`INTERMITTENT (${enteredCount}/${ROUNDS}). Compare the two patterns above:`);
    console.log("if `entered` tracks `pianoRollEditorFocused`, DELETE is riding the");
    console.log("focus coin flip and the fix is incomplete.");
  }
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
