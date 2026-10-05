// PASS 2 — every demo render. Thresholds are DERIVED from pass 1's measured dry
// peak, so each prediction lands on an exact number instead of chasing a level.
import { open, cmd, addTrack, addClip, n, close, burst } from "../session/build.mjs";
const AUD = process.env.COMP_AUDIO || "./audio";
const TONE_PEAK = parseFloat(process.env.COMP_TONE_PEAK);   // measured, never assumed
if (!Number.isFinite(TONE_PEAK)) throw new Error("COMP_TONE_PEAK must be the MEASURED dry peak dB");

const fresh = async (bpm = 100) => {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
};
const setP = async (trackId, effectId, params) => {
  for (const [name, value] of Object.entries(params))
    await cmd("fx.setParam", { trackId, effectId, name, value });   // WIRE takes `name`
};

async function toneRig() {
  const id = await addTrack("Tone", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05,
    cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(id, 0, 8, [n(0, 57, 7.5, 110)], "Tone");
  const r = await cmd("fx.add", { trackId: id, kind: "compressor" });
  return { id, fx: r.effectId };
}
async function drumRig(bars = 4) {
  const kick = await addTrack("Kick", { instrument: { kind: "polySynth", waveform: "sine",
    attack: 0.001, decay: 0.13, sustain: 0.0, release: 0.05, cutoffHz: 400, resonance: 0.1, gain: 1.0 } });
  const snare = await addTrack("Snare", { instrument: { kind: "polySynth", waveform: "square",
    attack: 0.001, decay: 0.10, sustain: 0.0, release: 0.06, cutoffHz: 3000, resonance: 0.4, gain: 0.55 } });
  const hat = await addTrack("Hat", { instrument: { kind: "polySynth", waveform: "square",
    attack: 0.0005, decay: 0.035, sustain: 0.0, release: 0.02, cutoffHz: 9000, resonance: 0.2, gain: 0.3 } });
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
  // ⚠️ ON THE MASTER, NOT THE KICK. A compressor on one of three tracks leaves
  // the mix peak set by the two it never touches: measured, `d6-wet` and
  // `d6-parallel` came back with BYTE-IDENTICAL peaks (-11.222977 both), which
  // is not a subtle result, it is an instrument pointed at the wrong signal.
  // The master is also where drum-bus compression actually lives.
  const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
  return { kick: "master", fx: r.effectId, secs: (bars * 4) * (60 / 100) + 0.5 };
}
const mix = (name, secs) => cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: secs })
  .then(() => console.log(`  ${name}.wav`));

await open();

// ── DEMO 1: threshold + ratio decide HOW MUCH.  over = 12 dB, ratio 4, hard knee
//    -> predicted GR exactly 9.0 dB.  ratio 1 is the unity CONTROL: 0.0 dB.
{
  await fresh(); const t = await toneRig();
  const base = { thresholdDb: TONE_PEAK - 12, kneeDb: 0, attackMs: 1, releaseMs: 100, makeupDb: 0, mix: 1 };
  await setP(t.id, t.fx, { ...base, ratio: 4 });  await mix("d1-ratio4", 5);
  await setP(t.id, t.fx, { ...base, ratio: 1 });  await mix("d1-ratio1-CONTROL", 5);
}

// ── DEMO 4: the knee demo nobody does — a tone JUST BELOW threshold.
//    hard knee -> 0.0 dB (untouched);  soft knee 24 -> 1.5625 dB (already working).
{
  await fresh(); const t = await toneRig();
  const base = { thresholdDb: TONE_PEAK + 2, ratio: 4, attackMs: 1, releaseMs: 100, makeupDb: 0, mix: 1 };
  await setP(t.id, t.fx, { ...base, kneeDb: 0 });   await mix("d4-hard", 5);
  await setP(t.id, t.fx, { ...base, kneeDb: 24 });  await mix("d4-soft", 5);
}

// ── DEMO 2: attack decides WHAT SURVIVES.  Same hit, 0.1 ms vs 50 ms.
{
  await fresh(); const d = await drumRig();
  const base = { thresholdDb: -30, ratio: 8, kneeDb: 2, releaseMs: 120, makeupDb: 0, mix: 1 };
  await setP(d.kick, d.fx, { ...base, attackMs: 0.1 });  await mix("d2-attack-fast", d.secs);
  await setP(d.kick, d.fx, { ...base, attackMs: 50 });   await mix("d2-attack-slow", d.secs);
  await cmd("fx.setBypass", { trackId: d.kick, effectId: d.fx, bypassed: true });
  await mix("d2-bypassed-CONTROL", d.secs);
}

// ── DEMO 3: release is PUMPING, and pumping is a RATE.  30 ms vs 800 ms.
{
  await fresh(); const d = await drumRig();
  const base = { thresholdDb: -34, ratio: 10, kneeDb: 2, attackMs: 1, makeupDb: 0, mix: 1 };
  await setP(d.kick, d.fx, { ...base, releaseMs: 30 });   await mix("d3-release-fast", d.secs);
  await setP(d.kick, d.fx, { ...base, releaseMs: 800 });  await mix("d3-release-slow", d.secs);
}

// ── DEMO 5: makeup, and why every A/B you have heard is a lie.
{
  await fresh(); const d = await drumRig();
  const base = { thresholdDb: -30, ratio: 6, kneeDb: 4, attackMs: 5, releaseMs: 120, mix: 1 };
  await cmd("fx.setBypass", { trackId: d.kick, effectId: d.fx, bypassed: true });
  await mix("d5-uncompressed", d.secs);
  await cmd("fx.setBypass", { trackId: d.kick, effectId: d.fx, bypassed: false });
  await setP(d.kick, d.fx, { ...base, makeupDb: 6 });  await mix("d5-makeup6", d.secs);
  await setP(d.kick, d.fx, { ...base, makeupDb: 0 });  await mix("d5-makeup0", d.secs);
}

// ── DEMO 6: mix — parallel compression, and the bit-exact bypass claim CHECKED.
{
  await fresh(); const d = await drumRig();
  const base = { thresholdDb: -40, ratio: 20, kneeDb: 2, attackMs: 0.5, releaseMs: 90, makeupDb: 0 };
  await setP(d.kick, d.fx, { ...base, mix: 1.0 });  await mix("d6-wet", d.secs);
  await setP(d.kick, d.fx, { ...base, mix: 0.4 });  await mix("d6-parallel", d.secs);
  await setP(d.kick, d.fx, { ...base, mix: 0.0 });  await mix("d6-mix0-CONTROL", d.secs);
  await cmd("fx.setBypass", { trackId: d.kick, effectId: d.fx, bypassed: true });
  await mix("d6-dry-CONTROL", d.secs);
}
console.log("done");
await close();
process.exit(0);
