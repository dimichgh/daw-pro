// PASS 1 — build the source material and render it DRY (no compressor at all).
// The dry peaks are what pass 2's thresholds are derived FROM, so every
// prediction lands on an exact number instead of chasing a level.
import { open, cmd, addTrack, addClip, n, close } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";

const fresh = async (bpm = 100) => {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
};

// A STEADY TONE for demos 1 and 4. A transient would drag attack into the
// arithmetic, which is the confusion demo 2 exists to introduce deliberately.
async function tone(name) {
  await fresh(100);
  const id = await addTrack("Tone", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05,
    cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(id, 0, 8, [n(0, 57, 7.5, 110)], "Tone");   // A3, held
  await cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: 5 });
  console.log(`  ${name}.wav`);
  return id;
}

// A PROGRAMMED drum kit for demos 2, 3 and 6 — percussive (they need
// transients) and steady (demo 3 measures the envelope in the gaps).
// No sample is loaded: kick/snare/hat are the poly synth's own waveforms.
async function drums(name, bars = 4) {
  await fresh(100);
  const kick = await addTrack("Kick", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.001, decay: 0.13, sustain: 0.0, release: 0.05,
    cutoffHz: 400, resonance: 0.1, gain: 1.0 } });
  const snare = await addTrack("Snare", { instrument: {
    kind: "polySynth", waveform: "square",
    attack: 0.001, decay: 0.10, sustain: 0.0, release: 0.06,
    cutoffHz: 3000, resonance: 0.4, gain: 0.55 } });
  const hat = await addTrack("Hat", { instrument: {
    kind: "polySynth", waveform: "square",
    attack: 0.0005, decay: 0.035, sustain: 0.0, release: 0.02,
    cutoffHz: 9000, resonance: 0.2, gain: 0.3 } });
  const kn = [], sn = [], hn = [];
  for (let b = 0; b < bars; b++) {
    const o = b * 4;
    kn.push(n(o, 36, 0.4, 120), n(o + 2.5, 36, 0.4, 112));
    sn.push(n(o + 1, 40, 0.3, 118), n(o + 3, 40, 0.3, 118));
    for (let e = 0; e < 8; e++) hn.push(n(o + e * 0.5, 66, 0.12, e % 2 ? 70 : 96));
  }
  await addClip(kick, 0, bars * 4, kn, "Kick");
  await addClip(snare, 0, bars * 4, sn, "Snare");
  await addClip(hat, 0, bars * 4, hn, "Hat");
  const secs = (bars * 4) * (60 / 100) + 0.5;
  await cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: secs });
  console.log(`  ${name}.wav  (${secs.toFixed(1)}s)`);
}

await open();
console.log("pass 1 — dry material");
await tone("tone-dry");
await drums("drums-dry");
console.log("done");
await close();
process.exit(0);
