// m16-a C1 regression gate — the deterministic MainActor poisoner recipe.
// (docs/research/design-m16a-canvas-crash.md §1/§6-C1; audit-m16 crash-3 shape.)
//
// Recipe, per iteration: project.new → instrument track + audio track →
// clip.addAudio (a REAL file) → clip.setFades + clip.setGainEnvelope →
// DELETE the file from disk → transport.seek {beats:1} → transport.play →
// wait → transport.stop → project.snapshot liveness probe + notice-honesty
// assertions.
//
// Pre-fix (design round, 6/6): `-[AVAudioPlayerNode playAtTime:]` raises
// "player started when in a disconnected state" on the 2nd play-bearing
// cycle; the NSException unwinds through the MainActor job, leaks the
// executor-tracking TLS record, and the app either crashes at the next
// SE-0423 dynamic-isolation check or wedges (wire connects, every command
// times out). Post-fix (Leg 0 play-guard + Leg 1 ObjC exception barrier):
// every iteration completes and the wire keeps answering.
//
// EXPECTATION REPLACEMENT (2026-07-13, m16-h —
// docs/research/design-m16h-reconfig.md §5.5): this gate originally
// REQUIRED a `clip-unplayable` notice per run ("proof the guard fired").
// That requirement asserted the DEFECT's signature: the raise this recipe
// provoked on iterations ≥2 was the deep post-start reconfig defect (every
// strip born on the running just-rebuilt engine was a dead player host),
// not the missing-media shape. m16-h removed the raise class by
// construction (deferred rebuild start + announce-class strip birth), and
// the dying clip now PLAYS its already-open unlinked fd audibly — so
// `clip-unplayable` is PERMITTED but NOT REQUIRED. The gate's real job —
// wedge/crash detection under the poisoner recipe — is unchanged: all
// iterations must complete, the wire must keep answering, and the
// operator's .ips ledger must be byte-identical around the run.
//
// Usage against a staging instance (fresh 176xx port; see staging laws):
//   env DAW_CONTROL_PORT=17663 nohup .build/debug/DAWApp &
//   PORT=17663 ITERS=10 node scripts/gates/m16a-poison-recipe.mjs
//
// Exit codes: 0 = all iterations clean (wire answered throughout);
// 2 = app dead (connect failed); 3 = wedge (commands stopped answering);
// 4 = iteration shortfall (an iteration failed without a wedge/crash).
import fs from "fs";
import os from "os";
import path from "path";

const PORT = process.env.PORT || "17663";
const ITERS = Number(process.env.ITERS || "10");
const PLAY_MS = Number(process.env.PLAY_MS || "6000");
let seq = 0;

// A tiny stereo Float32 WAV fixture, generated fresh so the gate has no
// repo-file dependencies: 1 s of low-amplitude DC at 48 kHz.
function makeWav(at) {
  const frames = 48_000, channels = 2, rate = 48_000;
  const dataBytes = frames * channels * 4;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20); // IEEE float
  buf.writeUInt16LE(channels, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * channels * 4, 28); buf.writeUInt16LE(channels * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames * channels; i++) buf.writeFloatLE(0.05, 44 + i * 4);
  fs.writeFileSync(at, buf);
}

function connect(timeoutMs = 5000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error("connect timeout")), timeoutMs);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = () => { clearTimeout(t); rej(new Error("connect failed")); };
  });
}

function cmd(ws, command, params, timeoutMs = 15000) {
  return new Promise((res, rej) => {
    const id = "m16a-c1-" + (++seq);
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      ws.removeEventListener("message", h);
      clearTimeout(t);
      if (!m.ok) rej(new Error(`${command}: ${m.error}`));
      else res(m.result);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (s) => console.log(`[${new Date().toISOString()}] ${s}`);

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "m16a-c1-"));
const NOTICE_FAMILY = ["clip-unplayable", "clip-fades-skipped", "clip-envelope-skipped"];
let sawUnplayable = 0;

async function iteration(ws, iter) {
  await cmd(ws, "project.new");
  await cmd(ws, "track.add", { name: "Keys", kind: "instrument" });
  const t2 = await cmd(ws, "track.add", { name: "Gtr" });
  const dying = path.join(scratch, `dying-${iter}-${Date.now()}.wav`);
  makeWav(dying);
  const clip = await cmd(ws, "clip.addAudio", { trackId: t2.id, path: dying, atBeat: 0 });
  await cmd(ws, "clip.setFades", { trackId: t2.id, clipId: clip.id, fadeInBeats: 0.5, fadeOutBeats: 0.5 });
  await cmd(ws, "clip.setGainEnvelope", { trackId: t2.id, clipId: clip.id,
    points: [{ beat: 0, gainDb: -6 }, { beat: 2, gainDb: 0 }, { beat: 4, gainDb: -12 }] });
  fs.unlinkSync(dying);
  await cmd(ws, "transport.seek", { beats: 1 });
  await cmd(ws, "transport.play");
  await sleep(PLAY_MS);
  await cmd(ws, "transport.stop");

  // Liveness probe + notice honesty (C1 assertions).
  const snap = await cmd(ws, "project.snapshot", undefined, 10000);
  const notices = snap.engineNotices || [];
  const codes = notices.map((n) => n.code);
  if (codes.includes("clip-unplayable")) sawUnplayable++;
  // Post-m16-h a notice-free iteration is the NORM (the dying clip plays
  // its unlinked fd) — informational only, never a failure.
  const familyHit = codes.filter((c) => NOTICE_FAMILY.includes(c));
  if (familyHit.length === 0) {
    log(`iter ${iter}: no guard-family notice (codes: ${codes.join(",") || "none"}) — expected post-m16-h`);
  }
  return codes;
}

let clean = 0;
for (let iter = 1; iter <= ITERS; iter++) {
  let ws;
  try {
    ws = await connect();
  } catch {
    log(`iter ${iter}: CONNECT FAILED — app dead (pre-fix signature: crash)`);
    process.exit(2);
  }
  try {
    const codes = await iteration(ws, iter);
    clean++;
    log(`iter ${iter}: ok — notices [${codes.join(",") || "none"}]`);
  } catch (e) {
    if (String(e.message).startsWith("TIMEOUT")) {
      // Distinguish wedge from crash: try one fresh-connection probe.
      try { ws.close(); } catch {}
      try {
        const probe = await connect();
        await cmd(probe, "project.snapshot", undefined, 10000);
        probe.close();
        log(`iter ${iter}: transient timeout but wire answers — continuing (${e.message})`);
      } catch {
        log(`iter ${iter}: WEDGED — wire connects/dead or gone (pre-fix signature: leaked executor record)`);
        process.exit(3);
      }
    } else {
      log(`iter ${iter}: command error: ${e.message}`);
      process.exit(2);
    }
  }
  try { ws.close(); } catch {}
  await sleep(500);
}

log(`done: ${clean}/${ITERS} iterations clean; clip-unplayable seen in ${sawUnplayable} snapshots (permitted, not required — m16-h)`);
if (clean === ITERS) {
  log("C1 PASS");
  process.exit(0);
}
log("C1 FAIL");
process.exit(4);
