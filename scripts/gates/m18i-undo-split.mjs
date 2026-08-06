// m18-i gate — piano-roll editor reseed across undo/split, mutation paths
// the m18-e/m18-i relight gate does NOT cover. That gate proves trim
// extend/shorten reseeds the open editor; this gate drives the SAME seam
// through two different production paths, editor open the whole time, ZERO
// reselects after the initial open:
//   U-leg: wire clip.trim shorten (13->4) then edit.undo — the journal
//          restore must re-light the editor back to the 13-beat truth.
//   S-leg: clip.split at beat 2 — the selected clip keeps its identity but
//          shortens to [0,2); the editor must drop everything past beat 2.
// Ground truth from the STORE via project.overview.
//
// m23-bc: the U-leg's repaint claim IS now machine-checked, as a RELATIVE,
// within-run pixel comparison — never a pinned golden hash:
//   PIXEL leg: sha256(u0-open.png) === sha256(u1-after-undo.png). u0 is the
//     editor's pre-trim paint; u1 is the editor after trim+undo. Undo must
//     restore the journal to the pre-trim 13-beat state, so an identical
//     hash is the correct outcome, not a coincidence.
//   CONTROL leg: sha256(s1-after-split.png) !== sha256(u0-open.png). Without
//     this, a `debug.captureUI` that silently wrote the same bytes every call
//     would make the PIXEL leg pass vacuously (the m23-ay A1 shape) — the
//     control proves the compare can actually SEE a difference when the
//     editor content changes.
// What this DOES NOT prove: a hash match only proves the two frames are
// byte-identical, and a hash mismatch only proves they differ. Neither leg
// establishes WHAT is on screen — "13 beats, 7 CC points, note at beat 4
// back" (U-leg) and "shows ONLY [0,2): 1 note, 2 CC points, boundary at 2"
// (S-leg) remain human/agent pixel-read claims; read the PNGs under OUT
// (u0-open.png / u1-after-undo.png / s1-after-split.png) to check content,
// not just identity.
//
// Stability measurement backing this (2026-08-05, sha256 — NOT the md5 the
// roadmap item recorded from one earlier run; the two are not comparable):
// 5 consecutive standalone runs plus 6 more taken while verifying this very
// change (11 total). Within EVERY run: u0/u1 matched 11/11, s1 differed from
// u0 11/11. Frame dimensions were identical across all runs (2800x2000). BUT
// u0's own bytes were NOT stable ACROSS runs — at least 3 distinct
// hash/size pairs observed over 11 runs (382788 / 382765 / 382859 bytes),
// with no stable pattern: an initial "changed once, then held for 3" shape
// seen in the first 5 runs did NOT survive the next 6 (a 3rd, previously
// unseen size appeared on run 8, from a run whose only source diff was an
// operator flip in a check() line that cannot affect rendering). This
// happens despite `_staging.mjs` giving every gate PROCESS a fresh mkdtemp
// profile root (m23-ay) with no cross-run inheritance in the DAWPro profile
// tree. Cause NOT identified (a `~/Library/Preferences` UserDefaults
// window-frame value is a plausible remaining store — it is outside
// `DAWPRO_PROFILE_ROOT`'s relocation — but that is unmeasured, not a
// finding). This is exactly why the two legs above compare WITHIN one run
// only and never pin an absolute hash: an absolute baseline here is
// guaranteed to rot, and the drift is confirmed erratic, not a settling
// transient.
// ⚠️ If PIXEL/CONTROL ever flap, the fix is to CROP to the editor region
// (the item's original preference) before hashing — not to delete the
// legs. Full-frame hashing is used now only because within-run identity
// measured 5/5; this file has no PNG decoder of its own. `m23c1-offclip-cue`
// shows cropping IS possible in this corpus — it compiles a small Swift pixel
// probe with `swiftc` at run time — but that is a heavier lift than a hash
// compare and was not needed here given the 5/5 result.
//
// Provenance: filed m18-i (editor reseed seam), written as an orchestrator
// disjoint gate 2026-07-16, promoted into scripts/gates/ 2026-07-16 (m19-h
// hygiene sweep). Pixel legs added m23-bc.
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m18i-undo-split.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m18i-undo-split
// m23-ac-3b-1: staging lifecycle from the ONE home. Was "class 3" — it launched
// nothing and drove whatever was on the port, so its greens certified a hand-prepared
// instance. `sleep` stays local (importing it would redeclare); the DAW_CONTROL_PORT
// override is preserved and now passes through assertStagingPort, so this gate can no
// longer be pointed at 17600 even by an env var.
import fs from "fs";
import crypto from "node:crypto";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const GATE = "m18i-undo-split";   // names the pidfile + out dir = the default OUT below
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
fs.mkdirSync(OUT, { recursive: true });
// m23-bc: OUT is a fixed, reused path across runs. If `debug.captureUI` ever
// returned ok without writing (window gone, path rejected, silent no-op),
// the PNG from a PREVIOUS good run would still be sitting there and get
// hashed instead — a stale u0/u1 pair would pass the PIXEL leg vacuously,
// and the stale s1 would still differ from the stale u0 so CONTROL would
// pass too. Unlinking the three capture targets up front turns a missing
// write into a loud ENOENT on read, not a silent adoption of old bytes.
const U0_PNG = `${OUT}/u0-open.png`;
const U1_PNG = `${OUT}/u1-after-undo.png`;
const S1_PNG = `${OUT}/s1-after-split.png`;
for (const p of [U0_PNG, U1_PNG, S1_PNG]) fs.rmSync(p, { force: true });
function sha256File(path) {
  const stat = fs.statSync(path); // throws loudly if the capture never wrote
  const hash = crypto.createHash("sha256").update(fs.readFileSync(path)).digest("hex");
  return { hash, size: stat.size };
}
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 120_000);
const sleep = ms => new Promise(r => setTimeout(r, ms));
buildOrAbort({ label: "building staging binary (m18i)…" });
startStaging({ gate: GATE });
const ws = await connect({ port: Number(PORT) });
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

// m23-bg: pin the capture window and CONFIRM it stuck before anything else
// runs. A pin's own echo is not proof it took — `debug.windowFrame
// {width:1440,height:640}` returns 640 exactly, then the window drifts to
// 672 within ~100ms and holds there (WindowFloor is applied to the content
// area below the titlebar while this command sets a contentRect INCLUDING
// it, +32 exactly) — {1400,1000} holds perfectly instead. So this settles,
// then re-reads with a BARE (mutation-free — DAWProApp.swift:3617 only
// mutates when width/height are present) call and asserts the re-read
// matches the request. Unpinned, this gate would inherit whatever size the
// LAST gate run on this machine left in the shared DAWApp autosave domain —
// and this gate's own u0/u1/s1 pixel legs are exactly the kind of capture
// comparison that geometry drift can quietly invalidate.
{
  let wf = null;
  for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
    wf = await cmd("debug.windowFrame", {});
    if (!(wf && typeof wf.width === "number")) await sleep(250);
  }
  check(`${GATE} m23-bg window exists pre-pin`, wf && typeof wf.width === "number", JSON.stringify(wf));
  await cmd("debug.windowFrame", { width: 1400, height: 1000 });
  await sleep(300);
  wf = await cmd("debug.windowFrame", {});
  console.log(`${GATE} m23-bg pin: requested 1400x1000, confirmed ${wf?.width}x${wf?.height}`);
  check(`${GATE} m23-bg pin took (re-read matches request)`, wf?.width === 1400 && wf?.height === 1000, JSON.stringify(wf));
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
await cmd("debug.captureUI", { selectClip: clip.id, path: U0_PNG });
await sleep(400);
// Double-capture is a settle pattern: the second call overwrites the
// first. Read AFTER this second call, once, since u0-open.png is never
// touched again after this point.
await cmd("debug.captureUI", { selectClip: clip.id, path: U0_PNG });
const u0 = sha256File(U0_PNG);
console.log(`u0-open.png sha256=${u0.hash} size=${u0.size} (${U0_PNG})`);

// -- U-leg: shorten, then undo -------------------------------------------------
await cmd("clip.trim", { trackId: track.id, clipId: clip.id, newStartBeat: 0, newLengthBeats: 4 });
await sleep(400);
await cmd("edit.undo", {});
await sleep(400);
const afterUndo = await cmd("project.overview", {});
const cUndo = afterUndo.tracks?.flatMap(t => t.clips ?? []).find(c => c.id === clip.id);
check("U store: undo restored 13 beats", cUndo && cUndo.lengthBeats === 13, JSON.stringify(cUndo ?? {}));
// NO reselect: plain capture (no selectClip param).
await cmd("debug.captureUI", { path: U1_PNG });
await sleep(400);
await cmd("debug.captureUI", { path: U1_PNG });
const u1 = sha256File(U1_PNG);
console.log(`u1-after-undo.png sha256=${u1.hash} size=${u1.size} (${U1_PNG})`);
check(
  "U pixel: undo repainted editor pixel-identical to pre-trim open (sha256 u0==u1)",
  u0.hash === u1.hash,
  `u0=${u0.hash} size=${u0.size} (${U0_PNG})  u1=${u1.hash} size=${u1.size} (${U1_PNG})`
);
console.log("U-leg captured (editor must show 13-beat truth, 7 CC points, note at beat 4 back)");

// -- S-leg: split at beat 2 ------------------------------------------------------
await cmd("clip.split", { trackId: track.id, clipId: clip.id, atBeat: 2 });
await sleep(400);
const afterSplit = await cmd("project.overview", {});
const clips = afterSplit.tracks?.flatMap(t => t.clips ?? []) ?? [];
const kept = clips.find(c => c.id === clip.id);
check("S store: original id kept and shortened to 2", kept && kept.lengthBeats === 2, JSON.stringify(kept ?? {}));
check("S store: two clips exist after split", clips.length === 2, JSON.stringify(clips.map(c => c.lengthBeats)));
await cmd("debug.captureUI", { path: S1_PNG });
await sleep(400);
await cmd("debug.captureUI", { path: S1_PNG });
const s1 = sha256File(S1_PNG);
console.log(`s1-after-split.png sha256=${s1.hash} size=${s1.size} (${S1_PNG})`);
check(
  "S pixel CONTROL: split repainted editor different from pre-trim open (sha256 s1!=u0)",
  s1.hash !== u0.hash,
  `u0=${u0.hash} size=${u0.size} (${U0_PNG})  s1=${s1.hash} size=${s1.size} (${S1_PNG})`
);
console.log("S-leg captured (editor must show ONLY [0,2): 1 note, 2 CC points, boundary at 2)");

// -- Normalize -------------------------------------------------------------------
await cmd("project.new", { discardChanges: true });
console.log(`M18I_UNDO_SPLIT pass=${pass} fail=${fail}`);
clearTimeout(killer);
ws.close();
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
process.exit(fail === 0 ? 0 : 1);
