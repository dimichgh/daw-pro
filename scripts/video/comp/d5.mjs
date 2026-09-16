// DEMO 5, done properly. The beat is "the compressed one is LOUDER, and louder
// wins every blind A/B" -- so the compression has to be GENTLE enough that
// makeup can actually overshoot the original. My first attempt crushed ~11 LU
// and then offered 6 dB of makeup, which left the "louder" version QUIETER: a
// demo that proved the opposite of its own point.
// Two-pass: render at makeup 0, measure the loss, then set makeup to cover it
// plus the 2 dB of cheat that makes the A/B unfair.
import { open, cmd, addTrack, addClip, n, close } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";
const MAKEUP = parseFloat(process.env.COMP_MAKEUP || "0");
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 100 });
const mk = async (name, wave, p, gain, notes) => {
  const id = await addTrack(name, { instrument: { kind: "polySynth", waveform: wave, gain, ...p } });
  await addClip(id, 0, 16, notes, name); return id;
};
const kn = [], sn = [], hn = [];
for (let b = 0; b < 4; b++) { const o = b * 4;
  kn.push(n(o, 36, .4, 120), n(o + 2.5, 36, .4, 112));
  sn.push(n(o + 1, 40, .3, 118), n(o + 3, 40, .3, 118));
  for (let e = 0; e < 8; e++) hn.push(n(o + e * .5, 66, .12, e % 2 ? 70 : 96)); }
await mk("Kick", "sine", { attack: .001, decay: .13, sustain: 0, release: .05, cutoffHz: 400, resonance: .1 }, 1.0, kn);
await mk("Snare", "square", { attack: .001, decay: .10, sustain: 0, release: .06, cutoffHz: 3000, resonance: .4 }, .55, sn);
await mk("Hat", "square", { attack: .0005, decay: .035, sustain: 0, release: .02, cutoffHz: 9000, resonance: .2 }, .3, hn);
const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
// GENTLE: 3:1 with a soft knee, the setting a mix engineer actually reaches for.
for (const [k, v] of Object.entries({ thresholdDb: -24, ratio: 3, kneeDb: 6,
                                      attackMs: 10, releaseMs: 150, mix: 1, makeupDb: MAKEUP }))
  await cmd("fx.setParam", { trackId: "master", effectId: r.effectId, name: k, value: v });
const secs = 16 * 0.6 + 0.5;
await cmd("render.mixdown", { path: `${AUD}/d5-makeup${MAKEUP}.wav`, durationSeconds: secs });
await cmd("fx.setBypass", { trackId: "master", effectId: r.effectId, bypassed: true });
await cmd("render.mixdown", { path: `${AUD}/d5-uncompressed.wav`, durationSeconds: secs });
console.log(`  rendered at makeup ${MAKEUP}`);
await close(); process.exit(0);
