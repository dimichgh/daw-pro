// Fast chain tuner: no renders, only render.measureLoudness. Finds the drive
// that lands a candidate master chain on a target loudness and reports what the
// chain cost in loudness range — so the compressor settings the film shows are
// CHOSEN by measurement rather than by taste.
import { open, cmd, addTrack, addClip, close } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS, SECS } from "./material.mjs";

const REN = SECS + 1.5;
const dbToLin = (db) => Math.pow(10, db / 20);
const MAXG = 20 * Math.log10(16);

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument, volume: p.volume, pan: p.pan });
  await addClip(t, 0, LEN_BEATS, p.notes, p.name);
}
const measure = () => cmd("render.measureLoudness", { durationSeconds: REN }).then(r => r.measurement);
const dry = await measure();
console.log(`dry ${dry.integratedLufs.toFixed(2)} LUFS  LRA ${dry.loudnessRangeLu.toFixed(2)}  ` +
            `TP ${dry.truePeakDbtp.toFixed(2)}`);

const gA = (await cmd("fx.add", { trackId: "master", kind: "gain", params: { gainLinear: 1 } })).effectId;
const gB = (await cmd("fx.add", { trackId: "master", kind: "gain", index: 1, params: { gainLinear: 1 } })).effectId;
const comp = (await cmd("fx.add", { trackId: "master", kind: "compressor", index: 2 })).effectId;
const lim = (await cmd("fx.add", { trackId: "master", kind: "limiter", index: 3,
                                   params: { ceilingDb: -1, releaseMs: 120, truePeak: 1 } })).effectId;

async function setDrive(db) {
  const a = Math.min(db, MAXG);
  await cmd("fx.setParam", { trackId: "master", effectId: gA, name: "gainLinear", value: dbToLin(a) });
  await cmd("fx.setParam", { trackId: "master", effectId: gB, name: "gainLinear",
                             value: dbToLin(Math.min(MAXG, Math.max(0, db - a))) });
}

async function trial(params, target, start) {
  for (const [k, v] of Object.entries(params)) {
    await cmd("fx.setParam", { trackId: "master", effectId: comp, name: k, value: v });
  }
  let g = start, best = null, bg = start;
  for (let i = 0; i < 9; i++) {
    await setDrive(g);
    const m = await measure();
    const err = target - m.integratedLufs;
    if (best === null || Math.abs(err) < Math.abs(target - best.integratedLufs)) { best = m; bg = g; }
    if (Math.abs(err) < 0.06) break;
    g = Math.min(2 * MAXG, g + err * 1.5);
  }
  console.log(`  ${JSON.stringify(params)} -> target ${target}: drive +${bg.toFixed(2)} dB  ` +
              `${best.integratedLufs.toFixed(2)} LUFS  LRA ${best.loudnessRangeLu.toFixed(2)}  ` +
              `TP ${best.truePeakDbtp.toFixed(2)}`);
}

const G = { thresholdDb: -18, ratio: 2, attackMs: 20, releaseMs: 180, kneeDb: 6, makeupDb: 6 };
const CANDIDATES = [
  [G, -14, 7],
  [G, -11, 13],
  [G, -8, 22],
];
for (const [p, t, s] of CANDIDATES) await trial(p, t, s);
close();
process.exit(0);
