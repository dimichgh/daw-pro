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
// Leg (a) is fully automated (analytic snapshot comparison).
//
// Leg (b), the ghost LAW itself, is STILL a human/agent read — of c2-settled.png
// under OUT. A hash proves a frame CHANGED or DID NOT, never WHAT is on screen
// (m23-bc), so "67 shows a ghost tail over [6,8)" cannot be asserted here.
// What m23-dr made machine-checkable are the two PREMISES that read silently
// stood on, both of which this gate performed and neither of which it checked:
//   SETTLE   sha(c1) === sha(c2) — the double-capture idiom assumes the frame has
//            stopped moving by the second shot. If it flaps, the PNG handed to
//            the human is a mid-animation frame and the read is worthless.
//   CONTROL  sha(c0) !== sha(c2) — c0 is the SAME window at the SAME density with
//            an EMPTY clip, so the ONLY difference is the injected notes. Without
//            it, "identical" could be the degenerate result of captureUI emitting
//            the same bytes regardless of state, and SETTLE would be vacuous.
// Measured 5/5 each before being asserted (m23-bc's "prove it is stable first"),
// and the settled frame was byte-identical across all 10 runs of the measurement.
// ⚠️ If SETTLE ever flaps the fix is CROPPING to the editor region, not deleting
// the leg — a whole-frame hash is exposed to anything time-varying in the window.
//
// Provenance: filed m19-g (out-of-clip note ghost treatment), written as an
// orchestrator disjoint gate 2026-07-16 (never in the implementation brief),
// promoted into scripts/gates/ 2026-07-16 (m19-h hygiene sweep).
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m19g-setnotes-ghost.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m19g-setnotes-ghost
// m23-ac-3b-1: staging lifecycle from the ONE home. Was "class 3" — it launched
// nothing and drove whatever was on the port, so its greens certified a hand-prepared
// instance. `sleep` stays local (importing it would redeclare); the DAW_CONTROL_PORT
// override is preserved and now passes through assertStagingPort, so this gate can no
// longer be pointed at 17600 even by an env var.
import fs from "fs";
import crypto from "crypto";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const GATE = "m19g-setnotes-ghost";   // names the pidfile + out dir = the default OUT below
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
fs.mkdirSync(OUT, { recursive: true });
// Three DISTINCT capture paths. Previously both shots wrote my-setnotes.png, so the
// second silently overwrote the first and no comparison was possible at all.
const C0 = `${OUT}/c0-empty.png`, C1 = `${OUT}/c1-presettle.png`, C2 = `${OUT}/c2-settled.png`;
// m23-bc's stale-adoption law: OUT is a FIXED, REUSED path, so a captureUI that
// returned ok without writing would let a PREVIOUS run's PNG be hashed and both
// pixel legs would pass on stale-but-identical bytes. Unlinking first turns that
// into a loud ENOENT from readFileSync instead of a silent adoption of old bytes.
for (const p of [C0, C1, C2]) { try { fs.unlinkSync(p); } catch {} }
const sha = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 120_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
buildOrAbort({ label: "building staging binary (m19g)…" });
startStaging({ gate: GATE });
const ws = await connect({ port: Number(PORT) });
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

// Pro density (VEL lane) is set BEFORE the control capture on purpose: c0 and c2
// then differ ONLY by the injected notes, which makes CONTROL a sharp "setNotes
// repainted the editor" claim instead of a vague "something moved".
// m23-du(c) CLOSED: this used to leak `pianoRoll=pro` into the shared `DAWApp`
// defaults domain on every run, because `debug.panelDensity` had no read form and
// a gate cannot put back a value it cannot read. m23-du(a) added that read form,
// so the prior is captured here and restored below.
//
// ⚠️ Restore from `stored`, NEVER from `mode`. `mode` is the EFFECTIVE density and
// reads `simple` both when a panel was explicitly set to simple AND when it was
// never set at all; writing that back would convert an unset key into an explicit
// one. `stored` is null in the never-set case, and that case is handled separately
// below — see the note at the restore.
const priorRollDensity = (await request(ws, "debug.panelDensity", { panel: "pianoRoll" })).stored ?? null;
console.log(`prior pianoRoll density: stored=${priorRollDensity ?? "UNSET"}`);
await request(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
await sleep(300);

let densityRestored = false;
async function restoreDensity(reason) {
  if (densityRestored) return;          // idempotent: normal path AND handlers call it
  densityRestored = true;
  try {
    if (priorRollDensity) {
      await request(ws, "debug.panelDensity", { panel: "pianoRoll", mode: priorRollDensity });
      console.log(`   density restored (${reason}): pianoRoll=${priorRollDensity}`);
    } else {
      // The prior was UNSET and `debug.panelDensity` has no clear verb yet, so
      // "unset" is not reachable from here (m23-du(a) documents this half as
      // still open). The choice is between leaving OUR `pro` behind and writing
      // the app default explicitly — and `simple` is strictly better: a fresh
      // machine's EFFECTIVE density is simple, so writing it makes the next gate
      // behave identically to a fresh machine, differing only by the presence of
      // a key. Leaving `pro` would change behaviour, which is the actual defect
      // m23-du is about. Logged, never silent.
      await request(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "simple" });
      console.log(`   density prior was UNSET (${reason}): wrote the app default `
        + `"simple" rather than leaving our "pro" behind — this CREATES an explicit `
        + `key, which only a clear verb (m23-du(a), still open) could avoid.`);
    }
  } catch (e) {
    console.error(`   ⚠️ DENSITY RESTORE FAILED (${reason}): ${e.message}`);
  }
}
for (const sig of ["unhandledRejection", "uncaughtException"]) {
  process.on(sig, async (err) => {
    console.error(`\n${sig.toUpperCase()} — restoring density before exit:`, err);
    await restoreDensity(sig);
    stopStaging(GATE);
    process.exit(3);
  });
}
const cap0 = await request(ws, "debug.captureUI", { selectClip: clip.id, path: C0 });
await sleep(400);

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

// (b) Render: capture twice (the settle law), then CHECK the two premises the
// human read stands on. The ghost LAW itself stays a human read of c2 — see header.
const cap1 = await request(ws, "debug.captureUI", { selectClip: clip.id, path: C1 });
await sleep(400);
const cap2 = await request(ws, "debug.captureUI", { selectClip: clip.id, path: C2 });
const s0 = sha(C0), s1 = sha(C1), s2 = sha(C2);
console.log("captured", JSON.stringify({ c0: cap0, c1: cap1, c2: cap2 }));

// Both legs print BOTH hashes, sizes and paths on failure, so the human pixel read
// stays reachable when the machine leg is the thing that broke (m23-bc's precedent).
const pixelDetail = {
  c0: { sha: s0.slice(0, 16), bytes: fs.statSync(C0).size, path: C0 },
  c1: { sha: s1.slice(0, 16), bytes: fs.statSync(C1).size, path: C1 },
  c2: { sha: s2.slice(0, 16), bytes: fs.statSync(C2).size, path: C2 },
};
check("pixel SETTLE: the frame stopped moving by the second capture (c1 == c2)",
  s1 === s2, pixelDetail);
check("pixel CONTROL: the injected notes repainted the editor (c0 != c2)",
  s0 !== s2, pixelDetail);

await request(ws, "project.new", { discardChanges: true });
await sleep(300);
await restoreDensity("normal exit");   // m23-du(c)
ws.close();
clearTimeout(killer);
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
console.log(failures === 0
  ? `\nORCH SETNOTES GATE: ALL PASS (2 analytic + 2 pixel-premise legs)`
    + `\n  the ghost LAW itself is still a human/agent read of ${C2}`
  : `\nORCH SETNOTES GATE: ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
