// m16-h regression gate — the second-cycle silence recipe, audibility-asserted.
// (docs/research/design-m16h-reconfig.md §5.4/§6-C1; audit trail: m16-f probe3.)
//
// The defect (named from a pure-AVFoundation standalone matrix, design §3):
// an AVAudioPlayerNode whose path to the pre-existing active render graph
// crosses ≥2 nodes attached while the engine was RUNNING can never be
// started — so every strip sandwich born on a running engine was a dead
// player host. `project.new` on a once-rendered engine used to rebuild and
// unconditionally START the fresh empty engine; every strip of the next
// session then attached post-start → from cycle 2 of any play-bearing
// session, ALL audio clips were silent (honest `clip-unplayable` notices,
// wire alive). Pre-fix: cycle 1 AUDIBLE, cycles ≥2 SILENT, deterministic,
// scale-independent (measured 8/8 across 40-strip and 2-strip shapes).
// Post-fix (Leg 1 deferred rebuild start + Leg 2 announce-class strip
// birth): every cycle must be AUDIBLE with ZERO `clip-unplayable`.
//
// Recipe, per cycle: project.new → STRIPS tone tracks + one clip each +
// (optionally) one strip with LIMITERS limiters → warm-up play/stop (Leg 1
// leaves the rebuilt engine STOPPED by design, and debug.masterCapture
// refuses a stopped engine with a teaching error) → capture play →
// 10 ms-window peak RMS + snapshot notice assertions. Audibility is a
// capture MEASUREMENT, never an inference (rider R5: liveness-only soaks
// certify silent sessions).
//
// Per-strip volume scales as min(1, 2/STRIPS) so the coherent tone sum
// lands at the same level (peak RMS ≈ 0.5) at every scale — one threshold
// (0.1) serves the 40-strip and the 2-strip (E4) shapes alike.
//
// Usage against a staging instance (fresh 176xx port; see staging laws):
//   env DAW_CONTROL_PORT=17663 nohup .build/debug/DAWApp &
//   PORT=17663 CYCLES=5 STRIPS=40 LIMITERS=16 node scripts/gates/m16h-second-cycle.mjs
//
// Env contract: PORT (required), CYCLES (default 5), STRIPS (default 40),
// LIMITERS (default 16; 0 skips the limiter strip).
//
// Exit codes: 0 = every cycle audible and zero clip-unplayable;
// 1 = a silent cycle or a clip-unplayable notice (the defect's signature);
// 2 = wire failure (connect/command error or timeout).
import fs from "fs";
import os from "os";
import path from "path";

const PORT = process.env.PORT || "17663";
const CYCLES = Number(process.env.CYCLES || "5");
const STRIPS = Number(process.env.STRIPS || "40");
const LIMITERS = Number(process.env.LIMITERS || "16");
const RMS_MIN = 0.1; // design §6-C1
let seq = 0;

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "m16h-gate-"));

// Self-contained tone fixture: 2 s of 440 Hz sine at 0.35 amplitude,
// stereo Float32 48 kHz WAV (no repo-file dependencies).
function makeToneWav(at) {
  const frames = 96_000, channels = 2, rate = 48_000;
  const dataBytes = frames * channels * 4;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20); // IEEE float
  buf.writeUInt16LE(channels, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * channels * 4, 28); buf.writeUInt16LE(channels * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames; i++) {
    const v = 0.35 * Math.sin(2 * Math.PI * 440 * (i / rate));
    buf.writeFloatLE(v, 44 + (i * channels) * 4);
    buf.writeFloatLE(v, 44 + (i * channels + 1) * 4);
  }
  fs.writeFileSync(at, buf);
}

// 10 ms-window peak RMS over a WAV capture (Float32/Int16/Int32 PCM).
function peakRMS(file) {
  const buf = fs.readFileSync(file);
  let off = 12, fmt = null, dataOff = 0, dataLen = 0;
  while (off + 8 <= buf.length) {
    const id = buf.toString("ascii", off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    if (id === "fmt ") fmt = { format: buf.readUInt16LE(off + 8), ch: buf.readUInt16LE(off + 10), rate: buf.readUInt32LE(off + 12), bits: buf.readUInt16LE(off + 22) };
    if (id === "data") { dataOff = off + 8; dataLen = Math.min(size, buf.length - off - 8); }
    off += 8 + size + (size % 2);
  }
  if (!fmt || !dataOff) throw new Error(`unparseable WAV: ${file}`);
  const { ch, rate, bits, format } = fmt;
  const bytesPer = bits / 8;
  const frames = Math.floor(dataLen / (ch * bytesPer));
  const read = (i) => {
    const p = dataOff + i * ch * bytesPer;
    if (format === 3) return buf.readFloatLE(p);
    if (bits === 16) return buf.readInt16LE(p) / 32768;
    if (bits === 32) return buf.readInt32LE(p) / 2147483648;
    throw new Error("unsupported fmt " + JSON.stringify(fmt));
  };
  const win = Math.round(rate / 100); // 10 ms
  let peak = 0;
  for (let w = 0; w < Math.floor(frames / win); w++) {
    let s = 0;
    for (let i = 0; i < win; i++) { const v = read(w * win + i); s += v * v; }
    peak = Math.max(peak, Math.sqrt(s / win));
  }
  return { frames, peak };
}

function connect(timeoutMs = 5000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error("connect timeout")), timeoutMs);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = () => { clearTimeout(t); rej(new Error("connect failed")); };
  });
}

function cmd(ws, command, params, timeoutMs = 20000) {
  return new Promise((res, rej) => {
    const id = "m16h-" + (++seq);
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      ws.removeEventListener("message", h);
      clearTimeout(t);
      if (!m.ok) rej(new Error(`${command}: ${JSON.stringify(m.error)}`));
      else res(m.result);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (s) => console.log(`[${new Date().toISOString()}] ${s}`);

const tone = path.join(scratch, "tone440.wav");
makeToneWav(tone);
const volume = Math.min(1, 2 / STRIPS);

let ws;
try {
  ws = await connect();
} catch (e) {
  log(`FAIL: cannot connect to ws://127.0.0.1:${PORT} — ${e.message}`);
  process.exit(2);
}

let failures = 0;
try {
  for (let c = 1; c <= CYCLES; c++) {
    const t0 = Date.now();
    await cmd(ws, "project.new", { discardChanges: true });
    for (let i = 0; i < STRIPS; i++) {
      const t = await cmd(ws, "track.add", { kind: "audio", name: `Tone${i}` });
      await cmd(ws, "clip.addAudio", { trackId: t.id, path: tone, atBeat: 0 });
      await cmd(ws, "track.setVolume", { trackId: t.id, volume });
    }
    if (LIMITERS > 0) {
      const dummy = await cmd(ws, "track.add", { kind: "audio", name: "DummyLatency" });
      for (let i = 0; i < LIMITERS; i++) {
        await cmd(ws, "fx.add", { trackId: dummy.id, kind: "limiter" });
      }
    }
    // Warm-up: post-m16-h the rebuilt engine is STOPPED by design, and
    // debug.masterCapture refuses a stopped engine (a teaching error).
    await cmd(ws, "transport.play"); await sleep(500);
    await cmd(ws, "transport.stop"); await sleep(300);
    const wav = path.join(scratch, `cycle-${c}.wav`);
    await cmd(ws, "debug.masterCapture", { action: "start", path: wav });
    await cmd(ws, "transport.seek", { beats: 0 });
    await cmd(ws, "transport.play");
    await sleep(1200);
    await cmd(ws, "transport.stop"); await sleep(300);
    await cmd(ws, "debug.masterCapture", { action: "stop" });

    const snap = await cmd(ws, "project.snapshot");
    const notices = snap.engineNotices || [];
    const unplayable = notices
      .filter((n) => n.code === "clip-unplayable")
      .reduce((s, n) => s + (n.count ?? 1), 0);
    const { frames, peak } = peakRMS(wav);
    const audible = peak > RMS_MIN;
    const ok = audible && unplayable === 0;
    if (!ok) failures++;
    log(`cycle ${c}/${CYCLES} [${STRIPS} strips, ${LIMITERS} limiters]: ` +
        `${audible ? "AUDIBLE" : "SILENT"} peakRMS=${peak.toFixed(4)} frames=${frames} ` +
        `clip-unplayable=${unplayable} ` +
        `notices=[${notices.map((n) => `${n.code}x${n.count ?? 1}`).join(",") || "none"}] ` +
        `${ok ? "ok" : "FAIL"} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  }
} catch (e) {
  log(`FAIL: wire error — ${e.message}`);
  process.exit(2);
}

if (failures === 0) {
  log(`m16-h gate PASS: ${CYCLES}/${CYCLES} cycles audible, zero clip-unplayable`);
  process.exit(0);
}
log(`m16-h gate FAIL: ${failures}/${CYCLES} cycles silent or raising (the pre-fix signature)`);
process.exit(1);
