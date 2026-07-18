// m18-i gate — piano-roll editor reseed across undo/split, mutation paths
// the m18-e/m18-i relight gate does NOT cover. That gate proves trim
// extend/shorten reseeds the open editor; this gate drives the SAME seam
// through two different production paths, editor open the whole time, ZERO
// reselects after the initial open:
//   U-leg: wire clip.trim shorten (13->4) then edit.undo — the journal
//          restore must re-light the editor back to the 13-beat truth.
//   S-leg: clip.split at beat 2 — the selected clip keeps its identity but
//          shortens to [0,2); the editor must drop everything past beat 2.
// Ground truth from the STORE via project.overview; editor truth is captured
// for a human/agent's pixel read afterward (this gate's analytic legs are
// automated; the editor-repaint claim is NOT machine-verified — read the
// u1-after-undo.png / s1-after-split.png captures under OUT).
//
// Provenance: filed m18-i (editor reseed seam), written as an orchestrator
// disjoint gate 2026-07-16, promoted into scripts/gates/ 2026-07-16 (m19-h
// hygiene sweep).
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m18i-undo-split.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m18i-undo-split
import fs from "fs";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.argv[2] || "/tmp/daw-gate-out/m18i-undo-split";
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 120_000);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 30; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(`ws://127.0.0.1:${PORT}`);
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(800); }
  }
  throw new Error(`no connect to ${PORT}`);
}
const ws = await connect();
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `us_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 15000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h);
      if (m.ok === false || m.error) rej(new Error(`${command}: ${m.error}`));
      else res(m.result ?? m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
function check(name, ok, detail = "") {
  if (ok) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.log(`FAIL ${name} :: ${detail}`); }
}

await cmd("project.new", { discardChanges: true });
await sleep(300);
const track = await cmd("track.add", { kind: "instrument", name: "UndoSplit" });
const clip = await cmd("clip.addMIDI", {
  trackId: track.id, name: "US Probe", atBeat: 0, lengthBeats: 13,
  notes: [
    { pitch: 60, startBeat: 0, lengthBeats: 0.5, velocity: 100 },
    { pitch: 76, startBeat: 4, lengthBeats: 1.5, velocity: 96 },
  ],
});
await cmd("clip.setControllerLane", {
  clipId: clip.id, type: "cc", controller: 1,
  points: [
    { beat: 0, value: 20 }, { beat: 2, value: 44 }, { beat: 3.5, value: 96 },
    { beat: 6, value: 70 }, { beat: 8, value: 84 }, { beat: 10, value: 64 },
    { beat: 12, value: 30 },
  ],
});
await sleep(300);
// Open the editor ONCE. Everything after this happens with no reselect.
await cmd("debug.captureUI", { selectClip: clip.id, path: `${OUT}/u0-open.png` });
await sleep(400);
await cmd("debug.captureUI", { selectClip: clip.id, path: `${OUT}/u0-open.png` });

// -- U-leg: shorten, then undo -------------------------------------------------
await cmd("clip.trim", { trackId: track.id, clipId: clip.id, newStartBeat: 0, newLengthBeats: 4 });
await sleep(400);
await cmd("edit.undo", {});
await sleep(400);
const afterUndo = await cmd("project.overview", {});
const cUndo = afterUndo.tracks?.flatMap(t => t.clips ?? []).find(c => c.id === clip.id);
check("U store: undo restored 13 beats", cUndo && cUndo.lengthBeats === 13, JSON.stringify(cUndo ?? {}));
// NO reselect: plain capture (no selectClip param).
await cmd("debug.captureUI", { path: `${OUT}/u1-after-undo.png` });
await sleep(400);
await cmd("debug.captureUI", { path: `${OUT}/u1-after-undo.png` });
console.log("U-leg captured (editor must show 13-beat truth, 7 CC points, note at beat 4 back)");

// -- S-leg: split at beat 2 ------------------------------------------------------
await cmd("clip.split", { trackId: track.id, clipId: clip.id, atBeat: 2 });
await sleep(400);
const afterSplit = await cmd("project.overview", {});
const clips = afterSplit.tracks?.flatMap(t => t.clips ?? []) ?? [];
const kept = clips.find(c => c.id === clip.id);
check("S store: original id kept and shortened to 2", kept && kept.lengthBeats === 2, JSON.stringify(kept ?? {}));
check("S store: two clips exist after split", clips.length === 2, JSON.stringify(clips.map(c => c.lengthBeats)));
await cmd("debug.captureUI", { path: `${OUT}/s1-after-split.png` });
await sleep(400);
await cmd("debug.captureUI", { path: `${OUT}/s1-after-split.png` });
console.log("S-leg captured (editor must show ONLY [0,2): 1 note, 2 CC points, boundary at 2)");

// -- Normalize -------------------------------------------------------------------
await cmd("project.new", { discardChanges: true });
console.log(`M18I_UNDO_SPLIT pass=${pass} fail=${fail}`);
clearTimeout(killer);
ws.close();
process.exit(fail === 0 ? 0 : 1);
