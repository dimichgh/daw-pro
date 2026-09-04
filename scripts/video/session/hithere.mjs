// "Hi there", out of a saw wave and two EQ peaks.
//
// The vowel chapter proves a single vowel is two numbers. A WORD is those two
// numbers MOVING. So: one held saw note per word, and the two formant peaks
// automated along the vowel path —
//
//   "Hi"    = /aɪ/  ah (730/1090) → ee (270/2290)   a diphthong IS a glide
//   "there" = /ðɛː/ eh (530/1840) → er (490/1350)
//
// ⚠ WHAT THIS CANNOT DO, STATED UP FRONT: /h/, /ð/ and /r/ are noise and
// near-noise, and this synth has no noise oscillator (that is the whole film).
// So the consonants are missing by construction and the result will read as a
// voice humming the SHAPE of the words. That is the finding, not a bug to hide.
import { open, cmd, close, burst } from "./build.mjs";

const A = process.env.SESSION_AUDIO || "./audio";
const BPM = 90;
const beat = 60 / BPM;

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });

const t = await cmd("track.add", { kind: "instrument", name: "Voice" });
const id = t.id || t.track?.id;
await cmd("track.setInstrument", { trackId: id, kind: "polySynth",
  waveform: "saw", attack: 0.06, decay: 0.20, sustain: 0.85,
  release: 0.18, cutoffHz: 5000, resonance: 0.05, gain: 0.5 });

// D3. Low enough to have harmonics under 3 kHz for the peaks to lift, high
// enough that the harmonic spacing does not leave the formants stranded --
// the failure the vowel chapter already measured on "oh".
const D3 = 50;
await cmd("clip.addMIDI", { trackId: id, atBeat: 0, lengthBeats: 8, name: "Hi there",
  notes: [{ startBeat: 0, pitch: D3, lengthBeats: 1.6, velocity: 100 },
          { startBeat: 2, pitch: D3, lengthBeats: 2.4, velocity: 96 }] });

const fx = await cmd("fx.add", { trackId: id, kind: "eq", params: {
  peak1Enabled: 1, peak1Freq: 730, peak1GainDb: 20, peak1Q: 9,
  peak2Enabled: 1, peak2Freq: 1090, peak2GainDb: 16, peak2Q: 9 } });
const eid = fx.effectId || fx.id;

// The vowel path, in BEATS. Each pair is [beat, F1, F2].
const PATH = [
  [0.00, 730, 1090],   // "h-AH"  — the consonant is missing; the vowel starts
  [1.20, 300, 2200],   // ...gliding to EE: that glide IS the "i" in "Hi"
  [1.60, 270, 2290],
  [2.00, 530, 1840],   // "th-EH" — again no consonant
  [3.20, 490, 1350],   // ...to ER, which is F3 work we cannot really do
  [4.40, 490, 1350],
];
for (const [param, idx] of [["peak1Freq", 1], ["peak2Freq", 2]]) {
  const lane = await cmd("automation.addLane",
    { trackId: id, target: { type: "effectParam", effectId: eid, param } });
  await cmd("automation.setPoints", { trackId: id,
    laneId: lane.lane?.id || lane.id,
    points: PATH.map(p => ({ beat: p[0], value: p[idx] })) });
  console.log("lane", param, "points", PATH.length);
}

const out = `${A}/hithere.wav`;
await cmd("render.mixdown", { path: out, durationSeconds: 5.0 });
console.log("rendered ->", out);
// The automation lanes ARE the chapter, so the burst shows the playhead
// crossing them while the two peaks travel.
await burst("hithere", 5.0);
await close();
process.exit(0);
