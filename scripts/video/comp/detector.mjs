// Is the 0.11 dB shortfall the peak detector decaying BETWEEN the peaks of the
// sine? If so, a longer release must close the gap and a shorter one must widen
// it. If the gap does not move with release, my explanation is wrong.
import { open, cmd, addTrack, addClip, n, close } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";
const TONE_PEAK = parseFloat(process.env.COMP_TONE_PEAK);
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 100 });
const id = await addTrack("Tone", { instrument: { kind: "polySynth", waveform: "sine",
  attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05, cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
await addClip(id, 0, 8, [n(0, 57, 7.5, 110)], "Tone");
const r = await cmd("fx.add", { trackId: id, kind: "compressor" });
for (const rel of [5, 100, 2000]) {
  for (const [k, v] of Object.entries({ thresholdDb: TONE_PEAK - 12, ratio: 4, kneeDb: 0,
                                        attackMs: 1, releaseMs: rel, makeupDb: 0, mix: 1 }))
    await cmd("fx.setParam", { trackId: id, effectId: r.effectId, name: k, value: v });
  await cmd("render.mixdown", { path: `${AUD}/det-rel${rel}.wav`, durationSeconds: 5 });
  console.log(`  det-rel${rel}.wav`);
}
await close(); process.exit(0);
