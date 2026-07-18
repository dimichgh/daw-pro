// m19-g disjoint gate — clip.setNotes stores out-of-clip notes un-clamped,
// and the m19-g ghost treatment must be honest about them. Latent notes
// created via the OTHER wire route — clip.setNotes on an existing EMPTY
// clip (not clip.trim, which clamps/drops straddling/outside notes) — must:
//   (a) land in the store UN-CLAMPED (analytic leg: snapshot must show all
//       4 injected notes verbatim, clip length unchanged);
//   (b) render per the m19-g ghost law on a binary carrying that change:
//       6-beat clip, 60@0 len2 lit full; 67@2 len6 lit [2,6) + ghost tail
//       [6,8); 64@6 len1 boundary-exact (start == clipLength, strict-<)
//       wholly ghost; 72@7.5 len2 wholly latent ghost; hairline at beat 6;
//       VEL stems: 60+67 lit (onsets fire), 64+72 ghost.
// Leg (a) is fully automated (analytic snapshot comparison). Leg (b) is NOT
// machine-verified — it emits my-setnotes.png under OUT for a human/agent to
// read against the law above.
//
// Provenance: filed m19-g (out-of-clip note ghost treatment), written as an
// orchestrator disjoint gate 2026-07-16 (never in the implementation brief),
// promoted into scripts/gates/ 2026-07-16 (m19-h hygiene sweep).
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m19g-setnotes-ghost.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m19g-setnotes-ghost
import fs from "fs";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.argv[2] || "/tmp/daw-gate-out/m19g-setnotes-ghost";
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 120_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function connectWithRetry(url, attempts = 60, delayMs = 500) {
  for (let i = 0; i < attempts; i++) {
    try {
      const ws = new WebSocket(url);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      return ws;
    } catch { await sleep(delayMs); }
  }
  throw new Error("no connect");
}
let nextId = 1;
const pending = new Map();
function request(ws, command, params = {}) {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, command });
    ws.send(JSON.stringify({ id, command, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 15000);
  });
}
const ws = await connectWithRetry(`ws://127.0.0.1:${PORT}`);
ws.onmessage = (event) => {
  let msg; try { msg = JSON.parse(event.data); } catch { return; }
  const e = pending.get(msg.id);
  if (!e) return;
  pending.delete(msg.id);
  if (msg.ok === false || msg.error) e.reject(new Error(`${e.command}: ${msg.error}`));
  else e.resolve(msg.result ?? msg);
};
console.log("connected");

let failures = 0;
const check = (label, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail !== undefined ? "  :: " + JSON.stringify(detail) : ""}`);
  if (!cond) failures++;
};

await request(ws, "project.new", { discardChanges: true });
await sleep(300);
await request(ws, "debug.windowFrame", { width: 1440, height: 900 });
await sleep(300);

// Empty 6-beat clip first — setNotes is the injection route under test.
const track = await request(ws, "track.add", { kind: "instrument", name: "SetNotes Ghost" });
const clip = await request(ws, "clip.addMIDI", {
  trackId: track.id, name: "Injected", atBeat: 0, lengthBeats: 6, notes: [],
});
console.log("clip", clip.id);
await sleep(200);

const NOTES = [
  { pitch: 60, startBeat: 0,   lengthBeats: 2, velocity: 100 }, // lit full
  { pitch: 67, startBeat: 2,   lengthBeats: 6, velocity: 118 }, // overhang: lit [2,6) + ghost [6,8)
  { pitch: 64, startBeat: 6,   lengthBeats: 1, velocity: 90 },  // boundary-exact = wholly ghost
  { pitch: 72, startBeat: 7.5, lengthBeats: 2, velocity: 70 },  // wholly latent ghost
];
await request(ws, "clip.setNotes", { clipId: clip.id, notes: NOTES });
await sleep(300);

// (a) Store truth: setNotes must NOT clamp/drop — all 4 notes verbatim.
const snap = await request(ws, "project.snapshot");
const tracks = snap.project?.tracks ?? snap.tracks ?? [];
const tr = tracks.find((t) => t.id === track.id) ?? {};
const cl = (tr.clips ?? []).find((c) => c.id === clip.id) ?? {};
const got = (cl.notes ?? []).map((n) => [n.pitch, n.startBeat, n.lengthBeats]).sort((a, b) => a[1] - b[1]);
const want = NOTES.map((n) => [n.pitch, n.startBeat, n.lengthBeats]).sort((a, b) => a[1] - b[1]);
check("setNotes stores out-of-clip notes un-clamped (4 verbatim)",
  JSON.stringify(got) === JSON.stringify(want), got);
check("clip length unchanged at 6", (cl.lengthBeats ?? cl.length) === 6, cl.lengthBeats ?? cl.length);

// (b) Render: Pro density (VEL lane), capture twice (settle law). Pixel leg
// requires a human/agent to read the emitted capture against the law in the
// header comment — NOT machine-verified here.
await request(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
await sleep(300);
await request(ws, "debug.captureUI", { selectClip: clip.id, path: `${OUT}/my-setnotes.png` });
await sleep(400);
const cap = await request(ws, "debug.captureUI", { selectClip: clip.id, path: `${OUT}/my-setnotes.png` });
console.log("captured", JSON.stringify(cap));

await request(ws, "project.new", { discardChanges: true });
await sleep(300);
ws.close();
clearTimeout(killer);
console.log(failures === 0
  ? `\nORCH SETNOTES GATE (analytic legs): ALL PASS — pixel leg is a human/agent read of ${OUT}/my-setnotes.png`
  : `\nORCH SETNOTES GATE: ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
