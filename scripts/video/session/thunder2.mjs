// Thunder, take 2 — plus the control that tells design failure apart from a
// dead automation lane. Take 1's centroid hardly moved; that is what a working
// sweep over a source with no high content looks like, AND what a lane that
// never applied looks like. So: widen the cluster, then render twice, once
// with the lane enabled and once disabled, and compare.
import { open, cmd, addTrack, addClip, n, rng, close } from "./build.mjs";
const AUD = process.env.SESSION_AUDIO || "./audio";
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 120 });
const id = await addTrack("Thunder", { instrument: {
  kind: "polySynth", waveform: "saw",
  attack: 0.004, decay: 3.5, sustain: 0.35, release: 3.5,
  cutoffHz: 16000, resonance: 0.1, gain: 0.55 } });
const r = rng(4242);
const notes = [];
// A crack needs high content to lose. Span five octaves, not one.
for (let i = 0; i < 44; i++)
  notes.push(n(+(r() * 0.35).toFixed(3), 26 + Math.floor(r() * 58), 7.5, 34 + Math.floor(r() * 55)));
await addClip(id, 0, 16, notes, "Thunder");
const eq = await cmd("fx.add", { trackId: id, kind: "eq" });
const eqId = eq.effectId || (eq.effects && eq.effects.at(-1).id);
await cmd("fx.setParam", { trackId: id, effectId: eqId, name: "lowPassEnabled", value: 1 });
await cmd("fx.setParam", { trackId: id, effectId: eqId, name: "lowPassSlopeDbPerOct", value: 24 });
const lane = await cmd("automation.addLane", {
  trackId: id, target: { type: "effectParam", effectId: eqId, param: "lowPassFreq" } });
const laneId = lane.id || (lane.lane && lane.lane.id);
const pts = [];
for (let i = 0; i <= 48; i++) {
  const k = i / 48;
  pts.push({ beat: +(k * 14).toFixed(3), value: +(16000 * Math.pow(70 / 16000, k)).toFixed(1) });
}
await cmd("automation.setPoints", { trackId: id, laneId, points: pts });
const rv = await cmd("fx.add", { trackId: id, kind: "reverb" });
const rvId = rv.effectId || (rv.effects && rv.effects.at(-1).id);
for (const [k, v] of [["roomSize",0.98],["mix",0.5],["damping",0.3],["preDelayMs",55],["width",1.0]])
  await cmd("fx.setParam", { trackId: id, effectId: rvId, name: k, value: v });
await cmd("render.mixdown", { path: `${AUD}/thunder2.wav`, durationSeconds: 9 });
console.log("rendered thunder2.wav (lane ENABLED)");
// CONTROL: same everything, lane off. If this measures the same, the lane is dead.
await cmd("automation.setLaneEnabled", { trackId: id, laneId, enabled: false });
await cmd("render.mixdown", { path: `${AUD}/thunder2-nolane.wav`, durationSeconds: 9 });
console.log("rendered thunder2-nolane.wav (CONTROL, lane DISABLED)");
await close();
