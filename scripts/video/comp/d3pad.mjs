// DEMO 3, RE-SHOT.  The user could not hear the release difference on laptop
// speakers, and they were right — it was a SOURCE fault, not a speaker fault.
//
// MEASURED on the first cut: the 30 ms and 800 ms renders differ by 11.5 dB at
// t=1.30 s, but at -39.9 vs -51.5 dBFS. The information lived in the drum TAIL,
// because between hits NOTHING ELSE WAS SOUNDING. 25-35 dB below the film's own
// level is under a laptop speaker's floor, so the one thing the chapter exists
// to demonstrate was the one thing inaudible.
//
// The fix is what pumping actually is in real music: something that SITS UNDER
// the hits and gets pushed down with them. A held pad at a level you can hear
// means the kick ducks the PAD by ~13 dB, and the recovery — fast or slow —
// happens on a sound that is present the whole time.
import { open, cmd, addTrack, addClip, n, close } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";

const BARS = 4, BPM = 100;
const SECS = (BARS * 4) * (60 / BPM) + 1.5;   // +1.5 s of tail: the 800 ms
                                              // recovery needs ~2 s to finish,
                                              // and a window that ends mid-
                                              // recovery cannot show it.

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });

const kick = await addTrack("Kick", { instrument: { kind: "polySynth", waveform: "sine",
  attack: 0.001, decay: 0.13, sustain: 0.0, release: 0.05, cutoffHz: 400, resonance: 0.1, gain: 1.0 } });
const snare = await addTrack("Snare", { instrument: { kind: "polySynth", waveform: "square",
  attack: 0.001, decay: 0.10, sustain: 0.0, release: 0.06, cutoffHz: 3000, resonance: 0.4, gain: 0.55 } });
const hat = await addTrack("Hat", { instrument: { kind: "polySynth", waveform: "square",
  attack: 0.0005, decay: 0.035, sustain: 0.0, release: 0.02, cutoffHz: 9000, resonance: 0.2, gain: 0.3 } });
// THE PAD — the thing you can hear being ducked. Sustain 1.0 and a long note:
// it must still be sounding in the gaps, which is the entire point.
const pad = await addTrack("Pad", { instrument: { kind: "polySynth", waveform: "saw",
  attack: 0.02, decay: 0.0, sustain: 1.0, release: 0.3, cutoffHz: 1800, resonance: 0.15, gain: 0.08 } });
// ⚠️ PAD GAIN IS THE WHOLE DEMO, AND 0.42 BROKE IT. MEASURED at 0.42 the pad
// peaked -9.05 dBFS against a -4.82 dBFS full mix -- 4 dB apart, so the pad on
// its own sat above threshold and the compressor NEVER let go: gain reduction
// pinned at 15-18 dB for the entire render, with no recovery to show. The pad
// has to be audible AND clearly below the hits: at 0.08 it lands near -23 dBFS,
// about 15 dB under the kick, so the kick alone crosses the threshold and the
// pad is what you hear swelling back.

const kn = [], sn = [], hn = [];
for (let b = 0; b < BARS; b++) {
  const o = b * 4;
  kn.push(n(o, 36, 0.4, 120), n(o + 2.5, 36, 0.4, 112));
  sn.push(n(o + 1, 40, 0.3, 118), n(o + 3, 40, 0.3, 118));
  for (let e = 0; e < 8; e++) hn.push(n(o + e * 0.5, 66, 0.12, e % 2 ? 70 : 96));
}
// One held triad across the whole loop, plus a beat of tail past the last hit
// so the final recovery is audible with no drum on top of it.
const pn = [];
for (const p of [45, 52, 57]) pn.push(n(0, p, BARS * 4 + 2, 96));

await addClip(kick, 0, BARS * 4, kn, "Kick");
await addClip(snare, 0, BARS * 4, sn, "Snare");
await addClip(hat, 0, BARS * 4, hn, "Hat");
await addClip(pad, 0, BARS * 4 + 2, pn, "Pad");

const mix = (name) => cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: SECS })
  .then(() => console.log(`  ${name}.wav`));

// DRY first — it is the denominator gaincurve.py divides by, and it is also
// the control: if the "compressed" renders match it, nothing compressed.
await mix("d3p-dry");

const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
// DERIVED, not chosen: the rig's standing rule. COMP_D3_PEAK is the measured
// dry peak of THIS material; the threshold sits 9 dB under it, so the kick
// crosses by 9 dB and ratio 8 predicts 9*(1-1/8) = 7.9 dB of reduction.
const PEAK = parseFloat(process.env.COMP_D3_PEAK);
if (!Number.isFinite(PEAK)) throw new Error("COMP_D3_PEAK must be the MEASURED dry peak dB");
// Ratio 20, not 8. DEPTH IS THE AUDIBILITY LEVER: ratio 8 measured only 5.9 dB
// of duck, and a 6 dB dip is a nuance the ear files under "slightly quieter".
// A ~9 dB return to an audible level is a GESTURE, which is what the listener
// actually tracks. 9 dB over the threshold at ratio 20 predicts 9*(1-1/20) =
// 8.55 dB. The threshold cannot go lower instead -- the pad has to stay under
// it by more than the knee half-width or the compressor re-pins and never
// recovers, which is the failure this whole re-shoot started from.
const base = { thresholdDb: PEAK - 9, ratio: 20, kneeDb: 2, attackMs: 1, makeupDb: 0, mix: 1 };
const setP = async (params) => {
  for (const [name, value] of Object.entries(params))
    await cmd("fx.setParam", { trackId: "master", effectId: r.effectId, name, value });
};
await setP({ ...base, releaseMs: 30 });   await mix("d3p-fast");
await setP({ ...base, releaseMs: 800 });  await mix("d3p-slow");

console.log("done");
await close();
process.exit(0);
