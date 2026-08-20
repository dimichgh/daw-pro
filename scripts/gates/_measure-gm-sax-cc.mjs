// MEASUREMENT PROBE for docs/research/measure-gm-sax-cc.md.
//
// NOT a gate: the leading `_` keeps it out of gate discovery (_verdict.mjs:174).
// NOT product code. It answers three questions about the stock GM sound bank
// FROM RENDERED AUDIO:
//
//   Q1  does the DLS sax honour CC 1 as vibrato?
//   Q2  what is AUSampler's real pitch-bend range on this path?
//   Q3  does CC 11 move BRIGHTNESS, or only LOUDNESS?
//
// plus the controls that make a null interpretable (C1/C2/C3, §0.4 of the doc).
//
// ── HOW TO RUN ────────────────────────────────────────────────────────────
//   node scripts/gates/_measure-gm-sax-cc.mjs q3 c1
//   node scripts/gates/_measure-gm-sax-cc.mjs q1
//   node scripts/gates/_measure-gm-sax-cc.mjs c3 q2
//
// Trials are argv-selected and each one APPENDS its raw numbers to
// `<scratch>/gm-sax-cc-results.json` the moment it lands. That shape is
// deliberate: the previous agent on this measurement died to the repo's 600 s
// liveness watchdog mid-run and lost everything. A stall must cost ONE trial.
//
// ── THE TWO RULES C0 EARNED (docs §4) ─────────────────────────────────────
//  1. PROMINENCE ALONE IS NOT A DETECTION. A perfectly flat trace scores
//     modPeak prominence 28.56. Detection is CONJUNCTIVE: depth AND prominence.
//  2. Decide a timbre question on bandRatio, not centroid. Against an identical
//     filter change bandRatio moved 6.59x where centroid moved only 1.50x.
//
// ── PORT LAW ──────────────────────────────────────────────────────────────
// Staging 17695 ONLY. 17600 is the USER'S LIVE APP and is never a target.
// Staging is killed PIDFILE-EXACT in `finally`; never pkill/pgrep.
import { writeFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort, sleep,
} from "./_staging.mjs";
import {
  readMonoFloat, magSpectrum, centroid, bandRatio, coarseF0, instantaneousFreq,
  envelope, modPeak, toCents, toDbTrace, centsBetween, rms, peak, dbfs,
  harmonicProfile,
} from "./_measure-dsp.mjs";

const GATE = "measure-gm-sax-cc";
const SCRATCH = process.env.SAXCC_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";
const RESULTS = `${SCRATCH}/gm-sax-cc-results.json`;
const SR = 48000;
const NFFT = 32768;

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }
mkdirSync(SCRATCH, { recursive: true });

// ── timing, ONE definition shared by every trial ──────────────────────────
// 120 BPM => 1 beat = 0.5 s. The note starts at beat 2 so that
//   (a) a controller point at beat 0 is delivered BEFORE the note-on, and
//   (b) every render carries a PRE-NOTE SILENCE WINDOW that is the noise floor
//       for the SNR figure. Same windows for every trial, so SNR is comparable.
const BPM = 120;
const B2S = 60 / BPM;             // seconds per beat
const NOTE_BEAT = 2;              // clip-local; t = 1.0 s
const NOTE_LEN_BEATS = 12;        // 6.0 s of note
const CLIP_LEN_BEATS = 18;
const RENDER_SECONDS = 8.0;
const NOTE_ON_S = NOTE_BEAT * B2S;                       // 1.0
const NOTE_OFF_S = (NOTE_BEAT + NOTE_LEN_BEATS) * B2S;   // 7.0
const FLOOR_WIN = [0.05, 0.90];   // pre-note silence
const STEADY_WIN = [2.00, 5.50];  // 1.0 s -> 4.5 s into the note (past any DLS LFO delay)

const results = existsSync(RESULTS) ? JSON.parse(readFileSync(RESULTS, "utf8")) : {};
function record(key, value) {
  results[key] = value;
  writeFileSync(RESULTS, JSON.stringify(results, null, 2));
  console.log(`  >> recorded "${key}" to ${RESULTS}`);
}

// ── socket: BROWSER-STYLE (addEventListener/ev.data). Node's `.on` is absent ──
let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `sax${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 180000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r.ok) throw new Error(`${command} FAILED: ${JSON.stringify(r.error)}`);
  return r.result;
}

// ── a 16-bit PCM mono WAV, written by hand ────────────────────────────────
// For the C1/C3 built-in-sampler zones. 16-bit int rather than float: it is
// the format every sampler reads without question, and these are CONTROL
// fixtures — their job is to be unambiguous, not pristine.
function writeWav(path, samples, sr = SR) {
  const n = samples.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(sr, 24); buf.writeUInt32LE(sr * 2, 28);
  buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write("data", 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  writeFileSync(path, buf);
  return path;
}
function makeSaw(f0, seconds, harmonics = 40, gain = 0.5) {
  const n = Math.round(SR * seconds), x = new Float64Array(n);
  for (let h = 1; h <= harmonics; h++) {
    if (f0 * h > SR / 2 - 500) break;
    const a = gain / h;
    for (let i = 0; i < n; i++) x[i] += a * Math.sin(2 * Math.PI * f0 * h * i / SR);
  }
  return x;
}
function makeSine(f0, seconds, gain = 0.7) {
  const n = Math.round(SR * seconds), x = new Float64Array(n);
  for (let i = 0; i < n; i++) x[i] = gain * Math.sin(2 * Math.PI * f0 * i / SR);
  return x;
}

// ── analysis helpers ──────────────────────────────────────────────────────
const idx = (sec) => Math.round(sec * SR);

/** Hz for a MIDI pitch — used to CONSTRAIN f0 search, never to assume a result. */
const midiHz = (p) => 440 * Math.pow(2, (p - 69) / 12);

/**
 * ⭐ THE SHARPEST TEST IN THIS FILE, and it is not a metric comparison at all.
 *
 * Least-squares-fit ONE scalar g such that y ≈ g·x, then report the residual
 * ‖y − g·x‖ / ‖y‖ in dB. If a controller does nothing but change level, the
 * residual collapses to the render's numerical floor. If it moves a filter —
 * or anything else — no single scalar can fit and the residual stays high.
 *
 * This is strictly stronger than "centroid and bandRatio did not move": those
 * are two summary statistics that a change could in principle slip past, while
 * this bounds EVERY spectral, temporal and phase difference at once. It only
 * works because the offline renderer is deterministic, which is exactly the
 * property `render.bounce` has and a live capture would not.
 */
function gainFit(x, y, from, to) {
  let num = 0, den = 0;
  for (let i = from; i < to; i++) { num += x[i] * y[i]; den += x[i] * x[i]; }
  const g = num / den;
  let resid = 0, sig = 0;
  for (let i = from; i < to; i++) { const e = y[i] - g * x[i]; resid += e * e; sig += y[i] * y[i]; }
  return {
    gain: Number(g.toFixed(8)),
    gainDb: Number((20 * Math.log10(Math.abs(g))).toFixed(4)),
    // "How much of y is NOT explained by scaling x", in dB. −100 and below is
    // the float-render floor: a PURE gain.
    residualDb: Number((10 * Math.log10(resid / sig)).toFixed(2)),
  };
}

/** 0.5 s RMS bins across the whole render — reveals a sample that stops sustaining. */
function levelProfile(x) {
  const out = [];
  for (let s = 0; s + 0.5 <= x.length / SR; s += 0.5) {
    out.push(Number(dbfs(rms(x, idx(s), idx(s + 0.5))).toFixed(1)));
  }
  return out;
}

/**
 * Steady-state timbre + level of one render. `rmsDb` FIRST, deliberately: a
 * centroid computed on silence is a number, not an error.
 */
function analyseSteady(x, expectHz, win = STEADY_WIN, floorWin = FLOOR_WIN) {
  const [a, b] = win;
  const sigRms = rms(x, idx(a), idx(b));
  const floorRms = rms(x, idx(floorWin[0]), idx(floorWin[1]));
  const floorPk = peak(x, idx(floorWin[0]), idx(floorWin[1]));
  const mid = idx((a + b) / 2) - NFFT / 2;
  const mag = magSpectrum(x, Math.max(0, mid), NFFT);
  // ⚠️ CONSTRAINED to ±25 % of the commanded pitch. Unconstrained, `coarseF0`
  // on this tenor-sax sample returns 1174.7 Hz — the FOURTH harmonic, which is
  // 3 dB louder than the fundamental. That is a correct spectral peak and the
  // wrong f0, and it silently re-bases every harmonic figure below it.
  const f0 = coarseF0(x, SR, Math.max(0, mid), NFFT, expectHz * 0.75, expectHz * 1.25);
  const snr = dbfs(sigRms) - dbfs(floorRms);
  return {
    rmsDb: Number(dbfs(sigRms).toFixed(3)),
    peakDb: Number(dbfs(peak(x, idx(a), idx(b))).toFixed(3)),
    // The pre-note window. `floorPeakAbs === 0` means DIGITAL SILENCE: the
    // noise-floor confound §0.3 warns about (a fixed floor biasing centroid
    // upward in a quiet render) does not exist in these renders at all.
    floorRmsDb: Number.isFinite(dbfs(floorRms)) ? Number(dbfs(floorRms).toFixed(3)) : "-Infinity",
    floorPeakAbs: floorPk,
    snrDb: Number.isFinite(snr) ? Number(snr.toFixed(2)) : "Infinity (floor is digital silence)",
    expectedF0Hz: Number(expectHz.toFixed(3)),
    f0Hz: Number(f0.toFixed(3)),
    f0ErrorCents: Number(centsBetween(f0, expectHz).toFixed(1)),
    centroidHz: Number(centroid(mag, SR, NFFT).toFixed(2)),
    bandRatio: Number(bandRatio(mag, SR, NFFT).toFixed(6)),
    harmonicsDb: harmonicProfile(mag, SR, NFFT, f0, 12)
      .map((v) => (v === null ? null : Number(v.toFixed(2)))),
    levelProfileDb: levelProfile(x),
  };
}

/**
 * Modulation of PITCH and of AMPLITUDE over a window.
 *
 * ⚠️ `fRef` is derived PER WINDOW with coarseF0, never assumed: the heterodyne
 * low-passes at 150 Hz around fRef, so a fixed reference plus a wide bend puts
 * the true partial OUTSIDE the passband and returns a plausible wrong number.
 *
 * ⚠️ The amplitude arm runs modPeak on a dB trace, not a linear one, so its
 * `minDepth` threshold has calibrated units (C0's 0.25-linear tremolo is
 * ±2.0 dB).
 */
function analyseMod(x, expectHz, win) {
  const [a, b] = win;
  const from = idx(a), to = idx(b);
  const nf = Math.min(16384, 1 << Math.floor(Math.log2(to - from)));
  const fRef = coarseF0(x, SR, from, nf, expectHz * 0.75, expectHz * 1.25);
  const ifq = instantaneousFreq(x, SR, fRef, from, to);
  const { cents, meanHz } = toCents(ifq.f);
  const pitch = modPeak(cents, ifq.traceRate);
  const env = envelope(x, SR, from, to);
  const { db } = toDbTrace(env.v);
  const amp = modPeak(db, env.traceRate);
  return {
    fRefHz: Number(fRef.toFixed(3)),
    meanF0Hz: Number(meanHz.toFixed(4)),
    pitch: {
      rateHz: Number(pitch.rateHz.toFixed(3)),
      depthCents: Number(pitch.amplitude.toFixed(4)),
      prominence: Number(pitch.prominence.toFixed(2)),
      // ⭐ CONJUNCTIVE — C0 rule 1. 1.0 cent is the floor a flat trace clears
      // by three orders of magnitude (it scored ±0.0000).
      detected: pitch.amplitude >= 1.0 && pitch.prominence > 20,
    },
    amplitude: {
      rateHz: Number(amp.rateHz.toFixed(3)),
      depthDb: Number(amp.amplitude.toFixed(4)),
      prominence: Number(amp.prominence.toFixed(2)),
      // 0.5 dB floor: C0's genuine tremolo was ±2.0 dB; below 0.5 dB nothing
      // is a musical amplitude vibrato.
      detected: amp.amplitude >= 0.5 && amp.prominence > 20,
    },
  };
}

/**
 * Mean f0 over a window: coarseF0 for the reference, heterodyne for precision.
 *
 * ⚠️ `searchHz` is a WIDE band around the commanded pitch, deliberately sized
 * to admit any plausible bend (up to +14 semitones) while still excluding the
 * neighbouring partials. Fixing `fRef` at the un-bent pitch instead would put a
 * widely-bent partial outside the heterodyne's 150 Hz passband and return a
 * plausible wrong number — the exact failure class this document exists to
 * remove. Each window gets its OWN reference.
 */
function preciseF0(x, expectHz, win) {
  const [a, b] = win;
  const from = idx(a), to = idx(b);
  const nf = Math.min(16384, 1 << Math.floor(Math.log2(to - from)));
  const loHz = expectHz * 0.94;                       // a little below (bend down)
  const hiHz = expectHz * Math.pow(2, 14 / 12);       // +14 semitones, still < 2× f0
  const fRef = coarseF0(x, SR, from, nf, loHz, hiHz);
  const ifq = instantaneousFreq(x, SR, fRef, from, to);
  const { cents, meanHz } = toCents(ifq.f);
  const drift = modPeak(cents, ifq.traceRate);
  return {
    searchBandHz: [Number(loHz.toFixed(1)), Number(hiHz.toFixed(1))],
    coarseHz: Number(fRef.toFixed(4)),
    meanHz: Number(meanHz.toFixed(4)),
    // How steady the window is — a big number here means the window straddled
    // the bend step and the "range" derived from it would be meaningless.
    wobbleCents: Number(drift.amplitude.toFixed(3)),
    rmsDb: Number(dbfs(rms(x, from, to)).toFixed(2)),
  };
}

// ── the render step ───────────────────────────────────────────────────────
let renderCount = 0;
/**
 * Bounce, assert non-silent, read as mono float. A silent render is a RETRY
 * (AUSampler takes time to load gs_instruments.dls), never a recorded null.
 */
async function render(tag, { minRmsDb = -80, retries = 2 } = {}) {
  const path = `${SCRATCH}/saxcc-${tag}.wav`;
  for (let attempt = 0; attempt <= retries; attempt++) {
    const t0 = Date.now();
    const r = await must("render.bounce", {
      path, fromBeat: 0, durationSeconds: RENDER_SECONDS,
    });
    const x = readMonoFloat(r.path ?? path, SR);
    const level = dbfs(rms(x, idx(STEADY_WIN[0]), idx(STEADY_WIN[1])));
    renderCount++;
    console.log(`  render #${renderCount} [${tag}] ${((Date.now() - t0) / 1000).toFixed(1)}s  `
      + `steady RMS ${level.toFixed(2)} dBFS  (${x.length} samples)`);
    if (level > minRmsDb && Number.isFinite(level)) return { x, path: r.path ?? path };
    console.log(`  ...SILENT (<= ${minRmsDb} dBFS) on attempt ${attempt + 1}; settling and retrying`);
    await sleep(3000);
  }
  throw new Error(`render [${tag}] is SILENT after ${retries + 1} attempts — refusing to analyse silence`);
}

// ── fixtures ──────────────────────────────────────────────────────────────
async function freshProject() {
  await must("project.new", {});
  await must("transport.setTempo", { bpm: BPM });
  const tempo = await must("tempo.map", {});
  console.log(`  tempo read back: ${JSON.stringify(tempo).slice(0, 160)}`);
  const t = await must("track.add", { name: "CC probe", kind: "instrument" });
  const trackId = t.id ?? t.track?.id ?? t.trackId;
  if (!trackId) throw new Error(`no track id in ${JSON.stringify(t).slice(0, 200)}`);
  return trackId;
}

/** The DLS sax program, found BY NAME — never derived from GM numbering. */
let saxProgram = null;
async function findSaxProgram() {
  if (saxProgram) return saxProgram;
  const listing = await must("instrument.listSoundBankPrograms", { source: "gm" });
  const programs = listing.programs ?? [];
  const named = programs.filter((p) => /sax/i.test(p.name ?? ""));
  console.log(`  sound-bank programs: ${programs.length}, namesParsed=${listing.namesParsed}, `
    + `sax matches: ${named.map((p) => `${p.program}:${p.name}`).join(", ") || "NONE"}`);
  const tenor = named.find((p) => /tenor/i.test(p.name)) ?? named[0];
  if (!tenor) throw new Error("no program matching /sax/i in the gm bank — refusing to guess a program number");
  saxProgram = tenor;
  return tenor;
}

async function setSax(trackId) {
  const prog = await findSaxProgram();
  const inst = await must("track.setInstrument", {
    trackId,
    soundBank: {
      source: "gm", program: prog.program,
      bankMSB: prog.bankMSB ?? 121, bankLSB: prog.bankLSB ?? 0,
    },
  });
  console.log(`  instrument: ${JSON.stringify(inst.soundBank ?? inst).slice(0, 220)}`);
  return { prog, displayName: inst.soundBank?.displayName ?? null };
}

async function addNote(trackId, pitch, velocity = 100) {
  const clip = await must("clip.addMIDI", {
    trackId, name: "held", atBeat: 0, lengthBeats: CLIP_LEN_BEATS,
    notes: [{ pitch, velocity, startBeat: NOTE_BEAT, lengthBeats: NOTE_LEN_BEATS }],
  });
  return clip.id;
}

/**
 * Author a lane and CAPTURE THE ENGINE'S OWN WARNING (m27's
 * `store.controllerLaneWarning`, Commands.swift ~2828). That warning is the
 * engine's primary-source claim about whether it will consume the lane; a
 * measurement that ignores it is throwing away free evidence.
 */
const laneWarnings = [];
async function setLane(clipId, type, controller, points) {
  const params = { clipId, type, points };
  if (type === "cc") params.controller = controller;
  const r = await cmd("clip.setControllerLane", params);
  if (!r.ok) throw new Error(`setControllerLane FAILED: ${JSON.stringify(r.error)}`);
  const w = r.result?.warnings ?? [];
  const label = type === "cc" ? `CC${controller}` : type;
  if (w.length) {
    console.log(`  ⚠️ lane ${label} WARNING: ${w.join(" | ")}`);
    laneWarnings.push({ lane: label, warnings: w });
  } else {
    console.log(`  lane ${label}: ${points.length} point(s), no warning`);
    laneWarnings.push({ lane: label, warnings: [] });
  }
  return w;
}
const held = (value) => [{ beat: 0, value }];

// ═══════════════════════════════════════════════════════════════════════════
// Q3 — does CC 11 move BRIGHTNESS on the sax path, or only LOUDNESS?
//
// Run FIRST, on purpose. Its RMS arm is the only evidence in this whole
// measurement that a CC BYTE REACHES THE DLS SAX AT ALL. Without it a Q1 null
// is two hypotheses wearing one number ("the patch has no mod routing" vs "the
// lane was never delivered").
// ═══════════════════════════════════════════════════════════════════════════
async function trialQ3() {
  console.log("\n=== Q3 — CC 11 on the stock GM sax: brightness or loudness? ===");
  const pitch = 62; // D4, 293.66 Hz — fundamental well above the 150 Hz heterodyne passband
  const expectHz = midiHz(pitch);
  const out = { pitch, expectedF0Hz: Number(expectHz.toFixed(3)), laneWarnings: [], arms: {} };
  const waves = {};

  const arms = [
    ["cc11-127", (clipId) => setLane(clipId, "cc", 11, held(127))],
    ["cc11-040", (clipId) => setLane(clipId, "cc", 11, held(40))],
    ["nolane", async () => { console.log("  no lanes (baseline — CC11 unset)"); }],
    ["cc7-040", (clipId) => setLane(clipId, "cc", 7, held(40))],
  ];
  for (const [tag, author] of arms) {
    laneWarnings.length = 0;
    const trackId = await freshProject();
    const { prog, displayName } = await setSax(trackId);
    out.program = { number: prog.program, name: prog.name, displayName };
    const clipId = await addNote(trackId, pitch);
    await author(clipId);
    out.laneWarnings.push(...laneWarnings.map((w) => ({ arm: tag, ...w })));
    const { x } = await render(`q3-${tag}`);
    waves[tag] = x;
    out.arms[tag] = analyseSteady(x, expectHz);
    console.log(`  [${tag}] rms ${out.arms[tag].rmsDb} dBFS  floorPeak ${out.arms[tag].floorPeakAbs}  `
      + `centroid ${out.arms[tag].centroidHz} Hz  bandRatio ${out.arms[tag].bandRatio}  `
      + `f0 ${out.arms[tag].f0Hz} Hz (${out.arms[tag].f0ErrorCents} cents off ${out.arms[tag].expectedF0Hz})`);
    record("q3", out);
  }

  // ⭐ The exact-gain test. See `gainFit`: this bounds EVERY difference between
  // the two renders, not just the two summary statistics above.
  const F = idx(STEADY_WIN[0]), T = idx(STEADY_WIN[1]);
  out.gainFit = {
    "cc11 127->40": gainFit(waves["cc11-127"], waves["cc11-040"], F, T),
    "cc7 default->40": gainFit(waves["nolane"], waves["cc7-040"], F, T),
    "cc11-127 vs nolane": gainFit(waves["cc11-127"], waves["nolane"], F, T),
  };
  // The MIDI convention both controllers are being tested against: level scales
  // as the SQUARE of the ratio. CC11's reference is 127 (full); CC7's default
  // is the GM power-on 100, which is why its reference is not 127.
  out.theory = {
    "cc11 (40/127)^2 dB": Number((20 * Math.log10((40 / 127) ** 2)).toFixed(4)),
    "cc7 (40/100)^2 dB": Number((20 * Math.log10((40 / 100) ** 2)).toFixed(4)),
  };
  console.log(`  GAINFIT ${JSON.stringify(out.gainFit)}`);
  console.log(`  THEORY  ${JSON.stringify(out.theory)}`);

  const a = out.arms["cc11-127"], b = out.arms["cc11-040"], d = out.arms["cc7-040"], n = out.arms["nolane"];
  out.verdict = {
    rmsDeltaDb_cc11: Number((a.rmsDb - b.rmsDb).toFixed(3)),
    rmsDeltaDb_cc7: Number((n.rmsDb - d.rmsDb).toFixed(3)),
    bandRatioFactor: Number((a.bandRatio / b.bandRatio).toFixed(6)),
    centroidFactor: Number((a.centroidHz / b.centroidHz).toFixed(6)),
    // THE CC-ARRIVAL EVIDENCE. Without this a Q1 null is two hypotheses wearing
    // one number: "the patch has no mod routing" vs "the lane never arrived".
    cc11ReachesInstrument: Math.abs(a.rmsDb - b.rmsDb) > 1.0,
    cc7ReachesInstrument: Math.abs(n.rmsDb - d.rmsDb) > 1.0,
    cc11DefaultsTo127: Math.abs(a.rmsDb - n.rmsDb) < 0.05,
    // "Pure gain" = a single scalar explains the whole difference. −100 dB and
    // below is the deterministic float render's own floor.
    cc11IsPureGain: out.gainFit["cc11 127->40"].residualDb < -60,
    cc11MatchesMidiSquareLaw:
      Math.abs(out.gainFit["cc11 127->40"].gainDb - out.theory["cc11 (40/127)^2 dB"]) < 0.05,
  };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("q3", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// C1 — built-in .sampler, expressionFilterDepth 1.0, CC11 127 vs 40.
// THE CONTROL THAT MAKES A Q3 NULL INTERPRETABLE. Predicted (Model.swift
// 1630-1660): cutoff 20 kHz at CC11=127, 400 x 50^0.315 ~= 1.37 kHz at CC11=40.
// If this does NOT move, the setup is wrong and no Q3 null may be interpreted.
// ═══════════════════════════════════════════════════════════════════════════
async function trialC1() {
  console.log("\n=== C1 — built-in sampler + expressionFilterDepth 1.0 ===");
  const zonePath = `${SCRATCH}/c1-saw220.wav`;
  writeWav(zonePath, makeSaw(220, 9.0));
  console.log(`  fixture: ${zonePath} (220 Hz saw, 40 harmonics, 9 s, 16-bit)`);
  const out = { zonePath, arms: {} };
  const waves = {};

  for (const [tag, value] of [["cc11-127", 127], ["cc11-040", 40]]) {
    const trackId = await freshProject();
    await must("track.setInstrument", {
      trackId, kind: "sampler",
      sampler: {
        zones: [{ path: zonePath, rootPitch: 57, minPitch: 0, maxPitch: 127 }],
        attack: 0.005, release: 0.05,
        expressionFilterDepth: 1.0, // the thing under test
        // expressionModDepth deliberately LEFT AT 0 so amplitude stays out of it
      },
    });
    const clipId = await addNote(trackId, 57); // root pitch — no resampling
    await setLane(clipId, "cc", 11, held(value));
    const { x } = await render(`c1-${tag}`);
    waves[tag] = x;
    out.arms[tag] = analyseSteady(x, 220);
    console.log(`  [${tag}] rms ${out.arms[tag].rmsDb}  centroid ${out.arms[tag].centroidHz} Hz  `
      + `bandRatio ${out.arms[tag].bandRatio}`);
    record("c1", out);
  }
  const a = out.arms["cc11-127"], b = out.arms["cc11-040"];
  // Run the SAME exact-gain test Q3 uses. C1 is the case where it must FAIL to
  // fit — a filter change cannot be explained by one scalar — which is what
  // proves the test can tell the two apart rather than always reading "gain".
  out.gainFit = gainFit(waves["cc11-127"], waves["cc11-040"], idx(STEADY_WIN[0]), idx(STEADY_WIN[1]));
  console.log(`  GAINFIT ${JSON.stringify(out.gainFit)}`);
  out.verdict = {
    bandRatioFactor: Number((a.bandRatio / b.bandRatio).toFixed(4)),
    centroidFactor: Number((a.centroidHz / b.centroidHz).toFixed(4)),
    rmsDeltaDb: Number((a.rmsDb - b.rmsDb).toFixed(3)),
    gainFitResidualDb: out.gainFit.residualDb,
    // The predicted cutoffs (Model.swift:1630-1660): 20 kHz at CC11=127,
    // 400 × 50^0.315 ≈ 1.37 kHz at CC11=40.
    fired: a.bandRatio / b.bandRatio > 1.5,
    // NEGATIVE CONTROL ON THE GAIN TEST ITSELF: a real filter must NOT fit one
    // scalar. If this is false, `gainFit` is reading "pure gain" for everything
    // and Q3's −104 dB residual means nothing.
    gainFitCorrectlyRefusesToFit: out.gainFit.residualDb > -20,
  };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("c1", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// Q1 — does the DLS sax honour CC 1 as vibrato?
//
// The answer is a DIFFERENCE BETWEEN TWO RENDERS, not a detection in one: DLS
// samples LOOP, and a loop point can put a periodic bump in the 2-12 Hz band
// that passes the conjunctive rule cleanly. CC1=0 is the negative control.
// The ENVELOPE arm is reported too — CC1 producing AM rather than FM is a
// different and equally reportable answer.
// ═══════════════════════════════════════════════════════════════════════════
async function trialQ1() {
  console.log("\n=== Q1 — CC 1 (mod wheel) on the stock GM sax ===");
  const pitch = 62;
  const expectHz = midiHz(pitch);
  const out = { pitch, expectedF0Hz: Number(expectHz.toFixed(3)), laneWarnings: [], arms: {} };
  const waves = {};
  // Three points, not two. CC1 = 64 is what turns "CC1 does something" into a
  // usable MAPPING for the breath pad — the design has to choose a lane value
  // per note, and it cannot do that from an on/off pair.
  for (const [tag, value] of [["cc1-000", 0], ["cc1-064", 64], ["cc1-127", 127]]) {
    laneWarnings.length = 0;
    const trackId = await freshProject();
    const { prog, displayName } = await setSax(trackId);
    out.program = { number: prog.program, name: prog.name, displayName };
    const clipId = await addNote(trackId, pitch);
    await setLane(clipId, "cc", 1, held(value));
    out.laneWarnings.push(...laneWarnings.map((w) => ({ arm: tag, ...w })));
    const { x } = await render(`q1-${tag}`);
    waves[tag] = x;
    // ONSET SCAN: 1 s sub-windows walking out from the note-on. A DLS patch
    // conventionally DELAYS its modulation LFO, and "how long until the
    // vibrato arrives" is a number the breath-pad design needs — leg D already
    // models a straight opening before vibrato blooms, and if the plugin
    // imposes its own delay on top, the two stack.
    const onsetScan = [];
    for (let s = NOTE_ON_S; s + 1.0 <= NOTE_OFF_S - 0.5; s += 0.5) {
      const m = analyseMod(x, expectHz, [s, s + 1.0]);
      onsetScan.push({
        fromNoteOnS: Number((s - NOTE_ON_S).toFixed(2)),
        depthCents: m.pitch.depthCents,
        rateHz: m.pitch.rateHz,
        prominence: m.pitch.prominence,
      });
    }
    out.arms[tag] = {
      steady: analyseSteady(x, expectHz),
      mod: analyseMod(x, expectHz, STEADY_WIN),
      onsetScan,
    };
    console.log(`  [${tag}] onset scan (s from note-on -> cents): `
      + onsetScan.map((o) => `${o.fromNoteOnS}:${o.depthCents}`).join(" "));
    const m = out.arms[tag].mod;
    console.log(`  [${tag}] f0 ${m.meanF0Hz} Hz | PITCH ${m.pitch.rateHz} Hz +-${m.pitch.depthCents} cents `
      + `prom ${m.pitch.prominence} detected=${m.pitch.detected} | AMP ${m.amplitude.rateHz} Hz `
      + `+-${m.amplitude.depthDb} dB prom ${m.amplitude.prominence} detected=${m.amplitude.detected}`);
    record("q1", out);
  }
  const off = out.arms["cc1-000"].mod, mid = out.arms["cc1-064"].mod, on = out.arms["cc1-127"].mod;
  out.gainFit = gainFit(waves["cc1-000"], waves["cc1-127"], idx(STEADY_WIN[0]), idx(STEADY_WIN[1]));
  console.log(`  GAINFIT ${JSON.stringify(out.gainFit)}`);
  out.verdict = {
    depthCentsByCC1: { 0: off.pitch.depthCents, 64: mid.pitch.depthCents, 127: on.pitch.depthCents },
    rateHzByCC1: { 0: off.pitch.rateHz, 64: mid.pitch.rateHz, 127: on.pitch.rateHz },
    pitchDepthDeltaCents: Number((on.pitch.depthCents - off.pitch.depthCents).toFixed(4)),
    ampDepthDeltaDb: Number((on.amplitude.depthDb - off.amplitude.depthDb).toFixed(4)),

    // ⚠️ THE ORIGINAL SHAPE OF THIS VERDICT WAS WRONG AND THE MEASUREMENT
    // CAUGHT IT. It read `on.detected && !off.detected` — built for the
    // hypothesis that any modulation at CC1=0 would be a DLS LOOP artefact, in
    // which case it would appear at the SAME depth in both arms. What is
    // actually there is a genuine ALWAYS-ON vibrato LFO that CC1 DEEPENS, so
    // `!off.detected` is false and the old boolean reported "CC1 does not
    // drive vibrato" about a 16x depth change. The discriminator that
    // separates a loop artefact from a driven LFO is not presence/absence, it
    // is whether the DEPTH RESPONDS while the RATE HOLDS.
    baselineVibratoAtCC1Zero: off.pitch.detected,
    cc1DeepensVibrato: on.pitch.detected
      && on.pitch.depthCents > off.pitch.depthCents * 3
      && Math.abs(on.pitch.rateHz - off.pitch.rateHz) < 0.3,
    depthFactor127over0: Number((on.pitch.depthCents / off.pitch.depthCents).toFixed(2)),

    // CC1 as AMPLITUDE modulation — the "different and equally reportable
    // answer". Both arms sit under the 0.5 dB floor, so this is a NULL.
    tremoloIsCC1Driven: on.amplitude.detected && !off.amplitude.detected,
    ampDepthDbByCC1: { 0: off.amplitude.depthDb, 64: mid.amplitude.depthDb, 127: on.amplitude.depthDb },
    rmsDeltaDb: Number((out.arms["cc1-127"].steady.rmsDb - out.arms["cc1-000"].steady.rmsDb).toFixed(3)),

    residualDb: out.gainFit.residualDb,
    cc1ChangedNothing: out.gainFit.residualDb < -60 && Math.abs(out.gainFit.gainDb) < 0.05,
  };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("q1", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// Bend trials (Q2 on the sax, C3 on the built-in sampler).
//
// ONE render, bend STEPPED MID-NOTE: centre for the first half, max for the
// second. Same voice, same sample, same zone — no cross-render tuning or
// zone-selection difference can contaminate the ratio.
// ═══════════════════════════════════════════════════════════════════════════
const BEND_STEP_BEAT = 8;                       // t = 4.0 s, mid-note
const BEND_CENTRE_WIN = [2.00, 3.80];
const BEND_MAX_WIN = [4.50, 6.50];

async function bendRun(tag, setup, pitch) {
  const expectHz = midiHz(pitch);
  const trackId = await freshProject();
  const info = await setup(trackId);
  const clipId = await addNote(trackId, pitch);
  await setLane(clipId, "pitchBend", null,
    [{ beat: 0, value: 8192 }, { beat: BEND_STEP_BEAT, value: 16383 }]);
  const { x } = await render(tag);
  const centre = preciseF0(x, expectHz, BEND_CENTRE_WIN);
  const max = preciseF0(x, expectHz, BEND_MAX_WIN);
  const cents = centsBetween(max.meanHz, centre.meanHz);
  const out = {
    info, pitch, expectedF0Hz: Number(expectHz.toFixed(3)), centre, max,
    // 16383 is +8191 of 8192 units, i.e. 0.99988 of full positive deflection.
    bendCents: Number(cents.toFixed(2)),
    fullRangeSemitones: Number((cents / 100 * (8192 / 8191)).toFixed(4)),
    // Guards against the one way this could be a plausible wrong number: if
    // the two windows locked onto DIFFERENT partials, the ratio is a harmonic
    // interval, not a bend. A tracked partial 14+ semitones up is not a bend
    // any sampler implements, and the centre window must sit ON the commanded
    // pitch to begin with.
    sanity: {
      centreIsCommandedPitch: Math.abs(centsBetween(centre.meanHz, expectHz)) < 60,
      centreOffCommandedCents: Number(centsBetween(centre.meanHz, expectHz).toFixed(1)),
      bothWindowsSteady: centre.wobbleCents < 5 && max.wobbleCents < 5,
      inPlausibleBendRange: cents > 0 && cents < 1400,
    },
    steady: analyseSteady(x, expectHz),
    levelProfileDb: levelProfile(x),
  };
  console.log(`  [${tag}] centre ${centre.meanHz} Hz (wobble +-${centre.wobbleCents} c) -> `
    + `max ${max.meanHz} Hz (wobble +-${max.wobbleCents} c)  = ${out.bendCents} cents `
    + `= +-${out.fullRangeSemitones} semitones`);
  console.log(`  sanity ${JSON.stringify(out.sanity)}`);
  return out;
}

async function trialC3() {
  console.log("\n=== C3 — built-in sampler bend range (expect 200 cents) ===");
  const zonePath = `${SCRATCH}/c3-sine440.wav`;
  writeWav(zonePath, makeSine(440, 9.0));
  const out = await bendRun("c3-bend", async (trackId) => {
    await must("track.setInstrument", {
      trackId, kind: "sampler",
      sampler: {
        zones: [{ path: zonePath, rootPitch: 69, minPitch: 0, maxPitch: 127 }],
        attack: 0.005, release: 0.05,
      },
    });
    return { zonePath, expectedCents: 200 };
  }, 69);
  out.verdict = { withinOneCentOf200: Math.abs(out.bendCents - 200) < 2.0 };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("c3", out);
}

async function trialQ2() {
  console.log("\n=== Q2 — AUSampler's real pitch-bend range on the GM sax ===");
  laneWarnings.length = 0;
  let program = null;
  const out = await bendRun("q2-bend", async (trackId) => {
    const { prog, displayName } = await setSax(trackId);
    program = { number: prog.program, name: prog.name, displayName };
    return program;
  }, 62);
  out.program = program;
  out.laneWarnings = [...laneWarnings];
  out.verdict = {
    // Leg D's BreathContour default. 200 cents => the default is CORRECT here.
    legDAssumedSemitones: 2,
    measuredSemitones: out.fullRangeSemitones,
    correctionFactor: Number((out.fullRangeSemitones / 2).toFixed(4)),
    matchesLegDDefault: Math.abs(out.bendCents - 200) < 6.0,
  };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("q2", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// C2 — an AUTHORED 5 Hz pitch-bend vibrato on the DLS sax itself.
// Proves (a) bend bytes reach AUSampler on this path and (b) the f0 tracker
// finds a KNOWN modulation there. Without it, a Q1 null could be "the tracker
// cannot see modulation through a DLS sample" rather than "there is none".
// ═══════════════════════════════════════════════════════════════════════════
async function trialC2() {
  console.log("\n=== C2 — authored bend vibrato on the DLS sax ===");
  const RATE = 5.0, DEPTH_CENTS = 50;
  laneWarnings.length = 0;
  const trackId = await freshProject();
  const { prog, displayName } = await setSax(trackId);
  const clipId = await addNote(trackId, 62);

  // Assumes ±2 semitones for the AUTHORING only; Q2 measures what actually
  // came out, so a wrong assumption here shows up as a depth error, not a
  // missed detection.
  const pts = [];
  const spacing = 0.008; // seconds — leg D's own bendSpacingSeconds default
  for (let t = 0; t <= (NOTE_BEAT + NOTE_LEN_BEATS) * B2S; t += spacing) {
    const cents = DEPTH_CENTS * Math.sin(2 * Math.PI * RATE * t);
    const units = Math.round(8192 + (cents / 200) * 8192);
    pts.push({ beat: Number((t / B2S).toFixed(6)), value: Math.max(0, Math.min(16383, units)) });
  }
  await setLane(clipId, "pitchBend", null, pts);
  const { x } = await render("c2-vibrato");
  const mod = analyseMod(x, midiHz(62), STEADY_WIN);
  const out = {
    program: { number: prog.program, name: prog.name, displayName },
    commanded: { rateHz: RATE, depthCents: DEPTH_CENTS, points: pts.length, spacingSeconds: spacing },
    mod, steady: analyseSteady(x, midiHz(62)), laneWarnings: [...laneWarnings],
    verdict: {
      rateFound: Math.abs(mod.pitch.rateHz - RATE) < 0.3,
      detected: mod.pitch.detected,
      depthRatioToCommanded: Number((mod.pitch.depthCents / DEPTH_CENTS).toFixed(4)),
    },
  };
  console.log(`  PITCH ${mod.pitch.rateHz} Hz +-${mod.pitch.depthCents} cents prom ${mod.pitch.prominence} `
    + `detected=${mod.pitch.detected}`);
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record("c2", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// Q2-SWEEP — the static bend TRANSFER CURVE, six levels in ONE render.
//
// Q2's two-point measurement returned 201.65 cents where C3's built-in sampler
// returned 199.97. Before that 1.65-cent excess is written down as "AUSampler's
// range is 2.0167 semitones", it has to be distinguished from an OFFSET or a
// non-linearity — two points cannot tell those apart, and the always-on ±2.42
// cent patch vibrato (Q1) biases any window that is not a whole number of LFO
// cycles. Each level is analysed over EXACTLY 4 cycles of the 5.400 Hz LFO
// (0.7407 s), which nulls that bias.
// ═══════════════════════════════════════════════════════════════════════════
const SWEEP_LEVELS = [8192, 9830, 11469, 13107, 14746, 16383]; // centre → max in 5 equal steps
async function trialQ2Sweep() {
  console.log("\n=== Q2-SWEEP — static bend transfer curve on the GM sax ===");
  const pitch = 62, expectHz = midiHz(pitch);
  const trackId = await freshProject();
  const { prog, displayName } = await setSax(trackId);
  const clipId = await addNote(trackId, pitch);
  // One level per second, starting at the note-on beat.
  const pts = SWEEP_LEVELS.map((value, i) => ({ beat: NOTE_BEAT + i * 2, value }));
  await setLane(clipId, "pitchBend", null, pts);
  const { x } = await render("q2-sweep");

  const LFO_CYCLE = 4 / 5.400; // 0.7407 s — a whole number of LFO cycles
  const rows = [];
  for (let i = 0; i < SWEEP_LEVELS.length; i++) {
    const start = NOTE_ON_S + i * 1.0 + 0.20;  // 200 ms after the step, past any smoothing
    const f = preciseF0(x, expectHz, [start, start + LFO_CYCLE]);
    rows.push({
      value: SWEEP_LEVELS[i],
      units: SWEEP_LEVELS[i] - 8192,
      meanHz: f.meanHz,
      cents: Number(centsBetween(f.meanHz, rows[0]?.meanHz ?? f.meanHz).toFixed(3)),
      wobbleCents: f.wobbleCents,
      rmsDb: f.rmsDb,
    });
  }
  // Least-squares slope through the origin: cents per bend unit.
  let num = 0, den = 0;
  for (const r of rows) { num += r.units * r.cents; den += r.units * r.units; }
  const centsPerUnit = num / den;
  const out = {
    program: { number: prog.program, name: prog.name, displayName }, rows,
    centsPerUnit: Number(centsPerUnit.toFixed(8)),
    fullRangeSemitones: Number((centsPerUnit * 8192 / 100).toFixed(4)),
    maxResidualCents: Number(Math.max(...rows.map((r) => Math.abs(r.cents - centsPerUnit * r.units))).toFixed(3)),
  };
  console.log(`  ${rows.map((r) => `${r.units}u:${r.cents}c`).join("  ")}`);
  console.log(`  slope ${out.centsPerUnit} cents/unit => full range ±${out.fullRangeSemitones} semitones, `
    + `max residual ${out.maxResidualCents} cents`);
  record("q2sweep", out);
}

// ═══════════════════════════════════════════════════════════════════════════
// BENDLPF — is AUSampler LOW-PASSING the pitch-bend lane?
//
// C2 recovered only 0.739 of the commanded vibrato depth. A one-pole smoother
// on the bend input would do exactly that, and it would be a REAL constraint on
// the breath pad: leg D's doc comment says "the emitted run IS the waveform",
// which is true of the BUILT-IN sampler and would be false here.
//
// The test is the FREQUENCY DEPENDENCE, not the single ratio: a one-pole rolls
// off as 1/sqrt(1+(2πfτ)²), so depth must fall as rate rises. A constant ratio
// across rates would mean something else (a range error) and must not be
// written up as smoothing.
//
// ⚠️ RATES CHOSEN TO BE RESOLVABLE FROM THE PATCH'S OWN 5.400 Hz LFO. A 3.5 s
// trace has ~1.14 Hz of Hann main-lobe width, so a commanded 5.0 Hz (C2's
// choice) is NOT separable from 5.4 Hz — that alone makes C2's ratio suspect.
// ═══════════════════════════════════════════════════════════════════════════
const LPF_RATES = [2.0, 3.5, 5.5, 8.0, 11.0, 11.72, 14.0];
async function trialBendLPF(label = "hosted AUSampler (GM sax)", setup = null,
                            pitch = 62, rates = LPF_RATES, key = "bendlpf") {
  console.log(`\n=== BENDLPF — pitch-bend smoothing on ${label} ===`);
  const DEPTH_CENTS = 50, expectHz = midiHz(pitch);
  const out = { label, pitch, commandedDepthCents: DEPTH_CENTS, rates: {} };
  for (const rate of rates) {
    const trackId = await freshProject();
    if (setup) await setup(trackId); else await setSax(trackId);
    const clipId = await addNote(trackId, pitch);
    const pts = [];
    for (let t = 0; t <= NOTE_OFF_S; t += 0.008) {
      const cents = DEPTH_CENTS * Math.sin(2 * Math.PI * rate * t);
      pts.push({
        beat: Number((t / B2S).toFixed(6)),
        value: Math.max(0, Math.min(16383, Math.round(8192 + (cents / 200) * 8192))),
      });
    }
    await setLane(clipId, "pitchBend", null, pts);
    const { x } = await render(`${key}-${rate}Hz`);
    const from = idx(STEADY_WIN[0]), to = idx(STEADY_WIN[1]);
    const fRef = coarseF0(x, SR, from, 16384, expectHz * 0.75, expectHz * 1.25);
    const ifq = instantaneousFreq(x, SR, fRef, from, to);
    const { cents } = toCents(ifq.f);
    // Look for the peak in a NARROW band around the commanded rate only.
    const p = modPeak(cents, ifq.traceRate,
      { loHz: Math.max(0.5, rate - 0.6), hiHz: rate + 0.6, stepHz: 0.005 });
    const ratio = p.amplitude / DEPTH_CENTS;
    // Implied ONE-POLE time constant. Reported so the one-pole hypothesis can
    // be REJECTED on the evidence rather than never considered: a real one-pole
    // gives the SAME tau at every rate.
    const tau = Math.sqrt(Math.max(0, 1 / (ratio * ratio) - 1)) / (2 * Math.PI * rate);
    // The competing hypothesis: a zero-order hold / boxcar of length T, i.e.
    // controller events applied once per render block. |sinc(pi f T)|, with a
    // NULL at f = 1/T — a shape a one-pole can never produce.
    const sinc = (f, T) => (f * T === 0 ? 1 : Math.abs(Math.sin(Math.PI * f * T) / (Math.PI * f * T)));
    const T4096 = 4096 / SR;
    out.rates[rate] = {
      measuredRateHz: Number(p.rateHz.toFixed(3)),
      depthCents: Number(p.amplitude.toFixed(3)),
      prominence: Number(p.prominence.toFixed(1)),
      ratio: Number(ratio.toFixed(4)),
      impliedTauMs: Number((tau * 1000).toFixed(2)),
      sincPredicted4096: Number(sinc(rate, T4096).toFixed(4)),
      sincErrorPct: Number(((ratio - sinc(rate, T4096)) * 100).toFixed(2)),
    };
    console.log(`  ${rate} Hz -> ${out.rates[rate].depthCents} cents `
      + `(${(ratio * 100).toFixed(1)}% of commanded)  |  one-pole tau ${out.rates[rate].impliedTauMs} ms  `
      + `|  sinc(4096) predicts ${(out.rates[rate].sincPredicted4096 * 100).toFixed(1)}% `
      + `(err ${out.rates[rate].sincErrorPct} pp)`);
    record(key, out);
  }
  const taus = rates.map((r) => out.rates[r].impliedTauMs);
  const ratios = rates.map((r) => out.rates[r].ratio);
  const sincErrs = rates.map((r) => Math.abs(out.rates[r].sincErrorPct));
  out.verdict = {
    ratioFallsWithRate: ratios[0] > ratios[ratios.length - 1] + 0.05,
    // ⭐ THE DISCRIMINATOR. A one-pole demands ONE tau; a spread of tens of ms
    // across the band REJECTS it. The sinc model is then judged on its own
    // worst-case error, not merely on being "better".
    onePoleTauSpreadMs: Number((Math.max(...taus) - Math.min(...taus)).toFixed(2)),
    onePoleRejected: (Math.max(...taus) - Math.min(...taus)) > 20,
    sincWorstErrorPct: Number(Math.max(...sincErrs).toFixed(2)),
    sincModelFits: Math.max(...sincErrs) < 3,
    blockFrames: 4096,
    blockMs: Number((4096 / SR * 1000).toFixed(2)),
    firstNullHz: Number((SR / 4096).toFixed(3)),
  };
  console.log(`  VERDICT ${JSON.stringify(out.verdict)}`);
  record(key, out);
}

/** The SAME test on the BUILT-IN sampler. Decides WHOSE smoothing this is. */
async function trialBendLPFBuiltIn() {
  const zonePath = `${SCRATCH}/c3-sine440.wav`;
  writeWav(zonePath, makeSine(440, 9.0));
  await trialBendLPF("the BUILT-IN .sampler (sine zone)", async (trackId) => {
    await must("track.setInstrument", {
      trackId, kind: "sampler",
      sampler: {
        zones: [{ path: zonePath, rootPitch: 69, minPitch: 0, maxPitch: 127 }],
        attack: 0.005, release: 0.05,
      },
    });
  }, 69, LPF_RATES, "bendlpfBuiltIn");
}

// ── driver ────────────────────────────────────────────────────────────────
const TRIALS = {
  q1: trialQ1, q2: trialQ2, q3: trialQ3, c1: trialC1, c2: trialC2, c3: trialC3,
  q2sweep: trialQ2Sweep, bendlpf: trialBendLPF, bendlpfb: trialBendLPFBuiltIn,
};
const wanted = process.argv.slice(2).map((s) => s.toLowerCase());
if (wanted.length === 0 || wanted.some((w) => !TRIALS[w])) {
  console.log(`usage: node scripts/gates/_measure-gm-sax-cc.mjs <${Object.keys(TRIALS).join("|")}> ...`);
  process.exit(2);
}

let failed = 0;
try {
  const s = await launchStaging({ gate: GATE, settleMs: 2000 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}  trials: ${wanted.join(", ")}`);
  for (const w of wanted) {
    try {
      await TRIALS[w]();
      console.log(`TRIAL ${w.toUpperCase()} COMPLETE`);
    } catch (e) {
      failed++;
      console.log(`TRIAL ${w.toUpperCase()} FAILED :: ${e.stack}`);
      record(`${w}_error`, String(e.message));
    }
  }
} catch (e) {
  failed++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
  console.log("staging stopped (pidfile-exact)");
}
console.log(`SAXCC done, ${failed} trial(s) failed. Results: ${RESULTS}`);
process.exit(failed === 0 ? 0 : 1);
