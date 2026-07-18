// m18-c birth-latency scaling gate (ACTIVE players) — the m18-c cost model
// said mid-play track-birth cost is core(~140-160 ms @41 strips) + ~6-7 ms x
// CLIP-PLAYER-COUNT (play(at:) handshakes), i.e. linear in PLAYERS, not
// strips. The model was never checked by varying player count at fixed
// strip count — this gate does exactly that: 41 audio strips, K in {10,40}
// tone clips, ALL of them actively rolling (playhead at 0) when the birth
// happens.
// PREDICTION: median(K=40) - median(K=10) ~= 30 x ~6.5 = ~180-210 ms (band
// 120-280 for host variance); K=10 median lands well under the filed
// ~390 ms class.
//
// >>> TIMING GATE, MACHINE-CALIBRATED BANDS <<<
// Bands (measured on this machine 2026-07-16 under light load):
//   K40 median in [330, 480] ms; K10 median < 300 ms; delta in [120, 280] ms.
// This is a load-sensitive, manual orchestrator gate — NOT for CI. If a run
// misses a band, re-run once on a quiet machine before concluding anything;
// do not retune the bands to make a noisy run pass.
//
// Self-contained: generates its own 10 s / 440 Hz / mono / 16-bit / 48 kHz
// tone fixture at runtime (same RIFF-writer pattern as m16h-second-cycle.mjs)
// instead of depending on a scratchpad WAV.
//
// Provenance: filed m18-c (cost model), the R1/R2 control leg cited by
// m19-f's design doc, written as an orchestrator disjoint gate 2026-07-16,
// promoted into scripts/gates/ 2026-07-16 (m19-h hygiene sweep). Companion:
// m19f-birth-scaling-idle.mjs (same recipe, idle players — the R1 gate).
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m18c-birth-scaling-active.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const URL_ = `ws://127.0.0.1:${PORT}`;
const killer = setTimeout(() => { console.error("GATE TIMEOUT"); process.exit(2); }, 150_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Self-contained tone fixture: 10 s of 440 Hz sine at amplitude 0.5, mono
// Int16 48 kHz WAV — matches the original scratchpad fixture byte-for-byte
// in spec (verified: RIFF/WAVE, fmt PCM(1) mono 48000, 16-bit, 10 s, 440 Hz,
// peak amplitude 0.5). No repo-file dependency.
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
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "m18c-scaling-"));
const WAV = path.join(scratch, "tone440.wav");
makeToneWav(WAV);

let ws, nextId = 0;
const pending = new Map();
async function connect() {
  for (let i = 0; i < 20; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(URL_);
        w.onopen = () => res(w);
        w.onerror = () => rej(new Error("refused"));
        w.onmessage = (ev) => {
          const m = JSON.parse(ev.data);
          const e = pending.get(m.id);
          if (e) { pending.delete(m.id); e.res({ msg: m, ms: Date.now() - e.t0 }); }
        };
      });
    } catch { await sleep(1000); }
  }
  throw new Error("no connect");
}
function cmd(command, params, timeoutMs = 20000) {
  const id = `oc_${++nextId}`;
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

ws = await connect();

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
    const p = await cmd("transport.play");
    if (!p.msg.ok) throw new Error("play failed");
    await sleep(600); // settle: players rolling
    const r = await cmd("track.add", { kind: "audio", name: `Birth${n}` });
    if (!r.msg.ok) throw new Error(`mid-play track.add failed: ${r.msg.error}`);
    samples.push(r.ms);
    const tid = (r.msg.result?.track ?? r.msg.result)?.id;
    const rm = await cmd("track.remove", { trackId: tid });
    if (!rm.msg.ok) console.log(`# note: track.remove refused: ${rm.msg.error}`);
    await cmd("transport.stop");
    await sleep(300);
  }
  console.log(`K=${K} birth round-trips: [${samples.join(", ")}] median ${median(samples)}`);
  return median(samples);
}

const m10 = await runBlock(10);
const m40 = await runBlock(40);
const delta = m40 - m10;
console.log(`delta (K=40 minus K=10): ${delta} ms`);
check("model: K=40 median in the filed class (330-480 ms)", m40 >= 330 && m40 <= 480, m40);
check("model: K=10 strictly cheaper AND under old 300 ms budget", m10 < m40 && m10 < 300, m10);
check("model: delta ~= 30 players x ~6.5 ms (120-280 ms band)", delta >= 120 && delta <= 280, delta);

const norm = await cmd("project.new", { discardChanges: true });
check("post-gate normalize ok", norm.msg.ok);
ws.close();
clearTimeout(killer);
console.log(failures === 0 ? "\nORCH SCALING GATE (active): ALL PASS" : `\nORCH SCALING GATE (active): ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
