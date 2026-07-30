// m19-f R1 GATE — birth-latency scaling (IDLE players). After R1 (schedule-
// gated player starts), a player with an EMPTY schedule must skip its
// play/stop handshakes entirely, so mid-play track-birth cost at a playhead
// PAST every clip collapses to the core (~140-220 ms round-trip) REGARDLESS
// of clip-player count K. Same recipe as m18c-birth-scaling-active.mjs (41
// audio strips, K in {10,40} tone clips at beat 0, 5 births per block) but
// each block seeks to beat 64 — safely past the 10 s tone fixture at the
// default 120 BPM tempo (beat 64 = 32 s) — before playing, so all K players
// are schedule-empty at the birth resume.
//
// >>> TIMING GATE, MACHINE-CALIBRATED BANDS <<<
// Bands (design doc §4; measured on this machine 2026-07-16 under light
// load): median(K=40 idle) < 300 ms (out of the filed 330-480 ms active
// class); delta_idle = median(K40) - median(K10) in [-40, +60] ms — the
// per-player slope COLLAPSE (~210 ms of play+stop handshake cost vanishes at
// 40 idle players). This is a load-sensitive, manual orchestrator gate —
// NOT for CI. If a run misses a band, re-run once on a quiet machine before
// concluding anything; do not retune the bands to make a noisy run pass.
//
// Self-contained: generates its own 10 s / 440 Hz / mono / 16-bit / 48 kHz
// tone fixture at runtime (same RIFF-writer pattern as m16h-second-cycle.mjs)
// instead of depending on a scratchpad WAV.
//
// Provenance: filed m18-c (cost model) -> m19-f design doc §4 R1 GATE,
// written as an orchestrator disjoint gate 2026-07-16, promoted into
// scripts/gates/ 2026-07-16 (m19-h hygiene sweep). Companion:
// m18c-birth-scaling-active.mjs (same recipe, active players — the pre-R1
// baseline the delta collapse is measured against).
//
// Staging: this gate BUILDS AND LAUNCHES its own app on 17695 — just run
// `node scripts/gates/m19f-birth-scaling-idle.mjs`. The old DAW_CONTROL_PORT
// override is GONE on purpose: it could be pointed at 17600, the user's LIVE
// app, and the harness refuses that port outright.
//
// >>> WHY SELF-LAUNCHING IS SAFE FOR A TIMING GATE (m23-ac-3b-5) <<<
// Measured, not argued. 3 runs against an app left idle 60 s with no build
// immediately prior — the historical calibration condition — gave K40 idle
// medians 109/119/109 and deltas -10/+19/+5; 3 runs through the launching
// harness gave 118/112/120 and +14/+9/+16. Overlapping ranges, 100% band-pass
// both ways. The preamble is neutral, and it finishes ~15 s of setup before the
// first birth is ever timed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m19f";                        // names the pidfile + staging out dir

// Self-contained tone fixture: 10 s of 440 Hz sine at amplitude 0.5, mono
// Int16 48 kHz WAV — matches the original scratchpad fixture byte-for-byte
// in spec. No repo-file dependency.
function makeToneWav(at) {
  const frames = 480_000, channels = 1, rate = 48_000, bits = 16;
  const dataBytes = frames * channels * (bits / 8);
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(channels, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * channels * (bits / 8), 28); buf.writeUInt16LE(channels * (bits / 8), 32);
  buf.writeUInt16LE(bits, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames; i++) {
    const v = Math.round(0.5 * 32767 * Math.sin(2 * Math.PI * 440 * (i / rate)));
    buf.writeInt16LE(v, 44 + i * 2);
  }
  fs.writeFileSync(at, buf);
}
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "m19f-scaling-idle-"));
const WAV = path.join(scratch, "tone440.wav");
makeToneWav(WAV);

let ws, nextId = 0;
const pending = new Map();
function cmd(command, params, timeoutMs = 20000) {
  const id = `oi_${++nextId}`;
  return new Promise((res, rej) => {
    const t0 = Date.now();
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    pending.set(id, { t0, res: (r) => { clearTimeout(t); res(r); } });
    ws.send(JSON.stringify({ id, command, ...(params ? { params } : {}) }));
  });
}
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
let failures = 0;
const check = (label, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail !== undefined ? "  :: " + JSON.stringify(detail) : ""}`);
  if (!cond) failures++;
};

buildOrAbort({ label: "building staging binary (m19f)…" });
// The 150 s watchdog is armed AFTER the build, deliberately. It exists to catch a
// gate hung talking to the app; a cold `swift build` can legitimately outlast it,
// and arming first would turn a slow compile into a bogus GATE TIMEOUT. Its
// teardown is structural since m23-bd (armTeardown), so this self-kill — the path
// that fires precisely when the gate has HUNG — cannot leak the app it was driving.
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 150_000);
startStaging({ gate: GATE });
ws = await connect();
// Re-attach the id-keyed reply pump the local connect() used to install. EVERY
// band in this gate is measured from the `ms` computed here, so it must stay
// exactly as it was: resolve on reply, ms = now - the t0 stamped in cmd().
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  const e = pending.get(m.id);
  if (e) { pending.delete(m.id); e.res({ msg: m, ms: Date.now() - e.t0 }); }
};

async function runBlock(K) {
  const r0 = await cmd("project.new", { discardChanges: true });
  if (!r0.msg.ok) throw new Error("project.new failed");
  for (let i = 0; i < 41; i++) {
    const r = await cmd("track.add", { kind: "audio", name: `S${i}` });
    const tid = (r.msg.result?.track ?? r.msg.result)?.id;
    if (i < K) {
      const c = await cmd("clip.addAudio", { trackId: tid, atBeat: 0, path: WAV });
      if (!c.msg.ok) throw new Error(`clip.addAudio failed: ${c.msg.error}`);
    }
  }
  const samples = [];
  for (let n = 0; n < 5; n++) {
    const sk = await cmd("transport.seek", { beats: 64 });
    if (!sk.msg.ok) throw new Error(`transport.seek failed: ${sk.msg.error}`);
    const p = await cmd("transport.play");
    if (!p.msg.ok) throw new Error("play failed");
    await sleep(600); // settle: rolling with every clip player schedule-empty
    const r = await cmd("track.add", { kind: "audio", name: `Birth${n}` });
    if (!r.msg.ok) throw new Error(`mid-play track.add failed: ${r.msg.error}`);
    samples.push(r.ms);
    const tid = (r.msg.result?.track ?? r.msg.result)?.id;
    const rm = await cmd("track.remove", { trackId: tid });
    if (!rm.msg.ok) console.log(`# note: track.remove refused: ${rm.msg.error}`);
    await cmd("transport.stop");
    await sleep(300);
  }
  console.log(`K=${K} IDLE birth round-trips: [${samples.join(", ")}] median ${median(samples)}`);
  return median(samples);
}

const m10 = await runBlock(10);
const m40 = await runBlock(40);
const delta = m40 - m10;
console.log(`delta_idle (K=40 minus K=10): ${delta} ms`);
check("R1: K=40 idle median out of the filed class (< 300 ms)", m40 < 300, m40);
check("R1: per-player slope COLLAPSED (delta_idle in [-40, +60] ms)", delta >= -40 && delta <= 60, delta);

const norm = await cmd("project.new", { discardChanges: true });
check("post-gate normalize ok", norm.msg.ok);
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
clearTimeout(killer);
console.log(failures === 0 ? "\nORCH IDLE SCALING GATE: ALL PASS" : `\nORCH IDLE SCALING GATE: ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
