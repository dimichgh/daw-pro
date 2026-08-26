#!/usr/bin/env node
// ⚠️ CORRECTED 2026-08-10 (m23-fh, at the m23-cf close). THE CLAIM BELOW IS WRONG.
// `keyDelete -> delivered:false` was NEVER a staging/tooling limitation. It was the
// app HONESTLY REPORTING THAT NOTHING HANDLED THE KEY: `firstResponder` read `none`
// with a clip selected, so no SwiftUI focus existed for `.onKeyPress` to attach to.
// A REAL APP DEFECT wearing the costume of a harness limit — m23-cf fixed it with a
// window-level NSEvent monitor and its gate now passes 27/27 with redden legs, so
// key-event gating on staging is DEMONSTRABLY POSSIBLE. Do not quote the text below
// as a reason not to write one. Root cause still open as m23-fi.
// m23-bw sub-task ① — DOES A BUNDLED STAGING APP MAKE `delivered=true` REACHABLE?
//
// The whole class of items blocked on "SwiftUI key arbitration is unobservable
// in this tree" hangs on this one empirical question. m23-bw's own text:
//   "① decide whether a bundled staging app (a real key window, via
//    scripts/bundle.sh --output to a scratch path) makes `delivered=true`
//    reachable, since that single change would unblock the whole class."
//
// METHOD: identical fixture, identical probe, TWO binaries — the unbundled
// `.build/debug/DAWApp` (the CONTROL, expected delivered=false) and a bundled
// scratch .app (the TREATMENT). A bare `true` from the bundle would prove
// nothing on its own; the discriminator is that the two DISAGREE at identical
// geometry. If BOTH report the same value, the bundle is not the mechanism and
// m23-bw ① is answered NO — which is just as useful an answer.
//
// Port 17695 only. Pidfile-exact teardown. 17600 is never contacted.

// NOTE: no `ws` import — every gate in this corpus uses Node's BUILT-IN global
// WebSocket (Node 22+). Importing "ws" fails: it is not installed at the repo root.
import { startStaging, stopStaging, buildOrAbort } from "./_staging.mjs";

const REPO = "/Users/dsemenov/Views/daw-pro";
const PORT = 17695;
const SCRATCH = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/66353ad9-08c6-4e23-b92b-f8d1a7521dc8/scratchpad";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

/** One arm: launch `binary`, build the fixture, fire the real key, report. */
async function arm(label, binary, gate) {
  console.log(`\n── ${label}\n   binary: ${binary}`);
  const { pid } = startStaging({ gate, root: REPO, port: PORT, binary, pidfile: `/tmp/${gate}.pid` });
  try {
    const { ws, req } = await connect();
    await req("project.new", { discardChanges: true });
    const track = await req("track.add", { name: "KeyProbe", kind: "instrument" });
    const trackId = track.id ?? track.track?.id;
    const clip = await req("clip.addMIDI", {
      trackId, atBeat: 0, lengthBeats: 4,
      notes: [{ pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 }],
    });
    const clipId = clip.id ?? clip.clip?.id;

    // Select it through the seam, so the fixture is identical in both arms.
    console.log(`   RAW track.add    = ${JSON.stringify(track).slice(0, 160)}`);
    console.log(`   RAW clip.addMIDI = ${JSON.stringify(clip).slice(0, 160)}`);
    const sel = await req("debug.arrangeSelection", { act: "click", clipId });
    console.log(`   RAW click echo   = ${JSON.stringify(sel).slice(0, 240)}`);
    const selIds = sel.arrangeSelection ?? sel.selectedIds ?? sel.ids ?? [];
    const selectedBefore = selIds.length;
    if (selectedBefore === 0) {
      throw new Error(
        "FIXTURE DID NOT ARM: nothing is selected, so `delivered` (which is "
        + "`selection changed?`) is FALSE for a reason that has nothing to do with key "
        + "delivery. Any verdict from this run would be VACUOUS.");
    }

    // THE MEASUREMENT: a real NSEvent through NSApp.sendEvent.
    const key = await req("debug.arrangeSelection", { act: "keyDelete" });
    console.log(`   RAW key echo     = ${JSON.stringify(key).slice(0, 240)}`);
    const after = (key.arrangeSelection ?? key.selectedIds ?? key.ids ?? []).length;

    console.log(`   selected before = ${selectedBefore}`);
    console.log(`   delivered       = ${JSON.stringify(key.delivered)}`);
    console.log(`   selection after = ${after}`);
    ws.close();
    return { delivered: key.delivered, selectedBefore, after };
  } finally {
    stopStaging(gate, `/tmp/${gate}.pid`);
    await sleep(1200);
  }
}

const results = {};
buildOrAbort({ root: REPO });
results.unbundled = await arm("CONTROL — unbundled binary", `${REPO}/.build/debug/DAWApp`, "m23bw-unbundled");
results.bundled = await arm("TREATMENT — bundled .app", `${SCRATCH}/KeyProbe.app/Contents/MacOS/DAWApp`, "m23bw-bundled");

console.log("\n════════ m23-bw ① VERDICT ════════");
console.log(`unbundled delivered = ${JSON.stringify(results.unbundled.delivered)}`);
console.log(`bundled   delivered = ${JSON.stringify(results.bundled.delivered)}`);
if (results.bundled.delivered === true && results.unbundled.delivered !== true) {
  console.log("YES — bundling makes real key delivery reachable. The whole m23-bw class is unblocked.");
} else if (results.bundled.delivered === results.unbundled.delivered) {
  console.log("NO — the two arms AGREE, so bundling is NOT the mechanism.");
  console.log("     m23-bw ① is answered NO; the blocker is something else and must be re-scoped.");
} else {
  console.log("UNEXPECTED — read the arms above before concluding anything.");
}
