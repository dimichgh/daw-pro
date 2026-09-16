// DEMO 3, RE-DESIGNED: release is PREDICTED, not compared.
//
// ⭐ THE FORMULA. `Sources/DAWEngine/Effects/CompressorEffect.swift:184` derives
//    releaseCoeff = exp(-1/(releaseMs*0.001*sampleRate))
// which is a plain one-pole with time constant tau = releaseMs. So from G dB of
// gain reduction, the time to climb back to within 1 dB of unity is
//    t = releaseMs * ln(G)
// and from 12 dB that is 74.6 ms / 248.5 ms / 1988 ms at 30 / 100 / 800 ms.
//
// ⚠ THE MATERIAL IS A GATED BURST, NOT THE DRUM LOOP. The loop cannot show a
// release: the next hit arrives before the recovery finishes. A loud burst that
// stops at a known instant lets the level fall below threshold once, cleanly.
//
// ⚠ AND IT DROPS TO A QUIET TAIL, NOT TO SILENCE. Gain is measured as
// compressed/dry sample by sample; on silence that is 0/0 and there is nothing
// to measure. The tail is the carrier the recovery is measured ON, and it is
// 13 dB below the threshold so the compressor's target is exactly 0 throughout.
//
// ⚠ THE BURST VOICE'S OWN RELEASE IS 0.001, NOT THE 0.05 THE OTHER RIGS USE. A
// 50 ms synth release takes ~70 ms to fall through 12.8 dB, which is longer than
// the whole 30 ms recovery -- it would have measured the SYNTH.
import { open, cmd, addTrack, addClip, n, close, burst, shot } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";
const BP = parseFloat(process.env.COMP_BURST_PEAK || "NaN");   // measured, pass 2 only

export const RATIO = 20;
// slope = 1/20 - 1 = -0.95, so 14.5 dB over threshold targets -13.8 dB of
// reduction. ⚠ IT WAS 12.85 FIRST, targeting -12.2, and the 30 ms release NEVER
// REACHED -12 (deepest -11.934): a fast release starts recovering while the peak
// detector is still falling. Deeper reduction makes the -12 dB crossing exist at
// every release, and the two-crossing time is independent of how deep it went.
export const OVER = 14.5;

const rig = async () => {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: 100 });
  const b = await addTrack("Burst", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.002, decay: 0.0, sustain: 1.0, release: 0.001,
    cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(b, 0, 8, [n(0, 69, 2.0, 120)], "Burst");      // A4, beats 0-2
  const t = await addTrack("Tail", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05,
    cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(t, 0, 8, [n(0, 57, 7.5, 110)], "Tail");       // A3, all the way
  await cmd("track.setVolume", { trackId: t, volume: 0.06 }); // ~ -24 dB: below threshold
  const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
  return { fx: r.effectId };
};
const setP = async (fx, p) => {
  for (const [name, value] of Object.entries(p))
    await cmd("fx.setParam", { trackId: "master", effectId: fx, name, value });
};
const mix = (name) => cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: 5.5 })
  .then(() => console.log(`  ${name}.wav`));

const mode = process.argv[2] || "dry";
await open();

if (mode === "dry") {
  const { fx } = await rig();
  await cmd("fx.setBypass", { trackId: "master", effectId: fx, bypassed: true });
  await mix("d3b-dry");
} else {
  if (!Number.isFinite(BP)) throw new Error("COMP_BURST_PEAK must be the MEASURED dry burst peak dB");
  const { fx } = await rig();
  const base = { thresholdDb: BP - OVER, kneeDb: 0, attackMs: 1, makeupDb: 0, mix: 1 };
  for (const rel of [30, 100, 800]) {
    await setP(fx, { ...base, ratio: RATIO, releaseMs: rel });
    await mix(`d3b-rel${rel}`);
  }
  // ⭐ THE CONTROL THAT MAKES IT FALSIFIABLE: ratio 1 is unity, so there is no
  // reduction to recover from and the recovery time must be undefined.
  await setP(fx, { ...base, ratio: 1, releaseMs: 100 });
  await mix("d3b-rel100-ratio1-CONTROL");
}
console.log("done");
await close();
process.exit(0);
