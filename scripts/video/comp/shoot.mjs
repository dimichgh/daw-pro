// The compressor lesson's PICTURES: every demo's rig rebuilt exactly as
// demos.mjs / d5.mjs / detector.mjs built it, the one knob that demo is about
// STEPPED through its values, and a frame taken at each step.
//
// ⚠ A STILL OF A PANEL TELLS A VIEWER NOTHING. They cannot tell a control they
// are being shown from a control that is doing something. shortsmith cycles a
// stage's `shots` at its `cut`, so N stills at a short cut IS the animation and
// every frame is the real app with the real number on it. Same pattern as
// ../session/sweepshot.mjs.
//
// ⚠ THE THRESHOLDS ARE DERIVED, NOT TYPED. COMP_TONE_PEAK is the MEASURED dry
// peak the renders were made against; feeding a different one here would put a
// number on screen that no rendered file was made at.
//
//   DAWPRO_PROFILE_ROOT=$SC/profile DAW_CONTROL_PORT=17695 \
//   SESSION_SHOTS=$SC/shots SESSION_BURSTS=$SC/bursts \
//   COMP_TONE_PEAK=-15.233022 node shoot.mjs
import { open, cmd, addTrack, addClip, n, shot, close, burst, SHOTS } from "../session/build.mjs";

const TONE_PEAK = parseFloat(process.env.COMP_TONE_PEAK);
if (!Number.isFinite(TONE_PEAK)) throw new Error("COMP_TONE_PEAK must be the MEASURED dry peak dB");

const fresh = async (bpm = 100) => {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
};

/** Read a compressor param back OFF THE PROJECT. ⚠ A SETTER'S RETURN IS NOT
 *  PROOF IT TOOK, and a panel photographed a beat early shows the PREVIOUS
 *  value — which every gate in this rig would pass. Master inserts are not in
 *  project.overview at all (its `master` is volume/meters only), so the master
 *  rigs have to come out of the snapshot's masterEffects. */
async function readBack(trackId, effectId, name) {
  const sn = await cmd("project.snapshot", {});
  const chain = trackId === "master"
    ? (sn.masterEffects || sn.project?.masterEffects || [])
    : ((sn.tracks || sn.project?.tracks || []).find((t) => t.id === trackId)?.effects || []);
  return chain.find((e) => e.id === effectId)?.params?.[name];
}

const setP = async (trackId, effectId, params) => {
  for (const [name, value] of Object.entries(params))
    await cmd("fx.setParam", { trackId, effectId, name, value });   // ⚠ WIRE takes `name`
};

/** Step ONE knob through its values, photographing each — with a read-back
 *  printed beside every frame so a step that did not take is visible in the log
 *  rather than only in the pixels. */
async function sweep(trackId, effectId, name, values, tag) {
  for (const v of values) {
    await setP(trackId, effectId, { [name]: v });
    const got = await readBack(trackId, effectId, name);
    const slug = String(v).replace(/\./g, "p");
    console.log(`  ${tag}: ${name} -> ${v}   read back: ${got}`);
    if (got === undefined) throw new Error(`read-back of ${name} returned undefined`);
    if (Math.abs(Number(got) - Number(v)) > 1e-4)
      throw new Error(`${name} did not take: asked ${v}, project holds ${got}`);
    await shot(`comp-${tag}-${slug}`);
  }
}

// --------------------------------------------------------------- the rigs
// Rebuilt to match the render scripts EXACTLY, so the panel on screen is the
// panel the audio was rendered through.
async function toneRig() {
  const id = await addTrack("Tone", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05,
    cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(id, 0, 8, [n(0, 57, 7.5, 110)], "Tone");
  const r = await cmd("fx.add", { trackId: id, kind: "compressor" });
  return { trackId: id, fx: r.effectId };
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
  // ⚠ ON THE MASTER, exactly as demos.mjs did it — a compressor on one of three
  // tracks leaves the mix peak set by the two it never touches.
  const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
  return { trackId: "master", fx: r.effectId };
}
const openEditor = (trackId, effectId) =>
  cmd("debug.effectEditor", { open: true, trackId, effectId });
const closeEditor = () => cmd("debug.effectEditor", { close: true });

const want = process.argv.slice(2);
const run = (k) => want.length === 0 || want.includes(k);

await open();

// ── the app itself, whole window, compressor open: the intro's "this is DAW Pro"
if (run("intro")) {
  await fresh(); const t = await drumRig();
  await setP(t.trackId, t.fx, { thresholdDb: -30, ratio: 4, kneeDb: 6,
                                attackMs: 10, releaseMs: 100, makeupDb: 0, mix: 1 });
  await cmd("debug.panelLayout", { editorMaximized: false });
  await shot("app-arrange");
  await openEditor(t.trackId, t.fx);
  await shot("app-compressor");
  await closeEditor();
}

// ── DEMO 1 — threshold + ratio decide HOW MUCH.  over = 12 dB, hard knee.
if (run("d1")) {
  await fresh(); const t = await toneRig();
  await setP(t.trackId, t.fx, { thresholdDb: TONE_PEAK - 12, kneeDb: 0, attackMs: 1,
                                releaseMs: 100, makeupDb: 0, mix: 1, ratio: 1 });
  await openEditor(t.trackId, t.fx);
  await sweep(t.trackId, t.fx, "ratio", [1, 2, 4], "d1-ratio");
  await closeEditor();
}

// ── DEMO 1b — the detector's own limit: the shortfall closes with release.
if (run("d1b")) {
  await fresh(); const t = await toneRig();
  await setP(t.trackId, t.fx, { thresholdDb: TONE_PEAK - 12, kneeDb: 0, attackMs: 1,
                                ratio: 4, makeupDb: 0, mix: 1, releaseMs: 5 });
  await openEditor(t.trackId, t.fx);
  await sweep(t.trackId, t.fx, "releaseMs", [5, 100, 2000], "d1b-rel");
  await closeEditor();
}

// ── DEMO 2 — attack decides WHAT SURVIVES.
if (run("d2")) {
  await fresh(); const d = await drumRig();
  await setP(d.trackId, d.fx, { thresholdDb: -30, ratio: 8, kneeDb: 2, releaseMs: 120,
                                makeupDb: 0, mix: 1, attackMs: 0.1 });
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "attackMs", [0.1, 5, 50], "d2-atk");
  await closeEditor();
}

// ── DEMO 3 — release is pumping, and pumping is a RECOVERY.
if (run("d3")) {
  await fresh(); const d = await drumRig();
  await setP(d.trackId, d.fx, { thresholdDb: -34, ratio: 10, kneeDb: 2, attackMs: 1,
                                makeupDb: 0, mix: 1, releaseMs: 30 });
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "releaseMs", [30, 200, 800], "d3-rel");
  await closeEditor();
}

// ── DEMO 4 — the knee demo nobody does: a tone 2 dB BELOW threshold.
if (run("d4")) {
  await fresh(); const t = await toneRig();
  await setP(t.trackId, t.fx, { thresholdDb: TONE_PEAK + 2, ratio: 4, attackMs: 1,
                                releaseMs: 100, makeupDb: 0, mix: 1, kneeDb: 0 });
  await openEditor(t.trackId, t.fx);
  await sweep(t.trackId, t.fx, "kneeDb", [0, 6, 12, 24], "d4-knee");
  await closeEditor();
}

// ── DEMO 5 — makeup. GENTLE 3:1 soft knee, exactly d5.mjs's setting.
if (run("d5")) {
  await fresh(); const d = await drumRig();
  await setP(d.trackId, d.fx, { thresholdDb: -24, ratio: 3, kneeDb: 6, attackMs: 10,
                                releaseMs: 150, mix: 1, makeupDb: 0 });
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "makeupDb", [0, 5.3, 7.3], "d5-makeup");
  await closeEditor();
}

// ── DEMO 6 — mix. Parallel compression at a crushing setting.
if (run("d6")) {
  await fresh(); const d = await drumRig();
  await setP(d.trackId, d.fx, { thresholdDb: -40, ratio: 20, kneeDb: 2, attackMs: 0.5,
                                releaseMs: 90, makeupDb: 0, mix: 1 });
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "mix", [1, 0.7, 0.4, 0], "d6-mix");
  await closeEditor();
}


// ── DEMO 3 RE-DESIGNED — the gated-burst rig, exactly as d3burst.mjs builds it.
// ⚠ THE OLD d3 SHOTS ARE THE WRONG PANEL FOR THIS AUDIO (threshold -34, ratio 10,
// the drum rig). A panel photographed at settings no rendered file was made at is
// a picture that lies, and every gate in this rig would pass it.
const BURST_PEAK = parseFloat(process.env.COMP_BURST_PEAK || "NaN");
async function burstRig() {
  const b = await addTrack("Burst", { instrument: { kind: "polySynth", waveform: "sine",
    attack: 0.002, decay: 0.0, sustain: 1.0, release: 0.001, cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(b, 0, 8, [n(0, 69, 2.0, 120)], "Burst");
  const t = await addTrack("Tail", { instrument: { kind: "polySynth", waveform: "sine",
    attack: 0.005, decay: 0.0, sustain: 1.0, release: 0.05, cutoffHz: 8000, resonance: 0.0, gain: 0.8 } });
  await addClip(t, 0, 8, [n(0, 57, 7.5, 110)], "Tail");
  await cmd("track.setVolume", { trackId: t, volume: 0.06 });
  const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
  return { trackId: "master", fx: r.effectId };
}
if (run("d3b")) {
  if (!Number.isFinite(BURST_PEAK)) throw new Error("COMP_BURST_PEAK must be the MEASURED dry burst peak dB");
  await fresh(); const d = await burstRig();
  await setP(d.trackId, d.fx, { thresholdDb: BURST_PEAK - 14.5, ratio: 20, kneeDb: 0,
                                attackMs: 1, makeupDb: 0, mix: 1, releaseMs: 30 });
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "releaseMs", [30, 100, 800], "d3b-rel");
  await closeEditor();
  await shot("app-burst-arrange");
}
if (run("d3bursts")) {
  await closeEditor();
  await fresh(); const d = await burstRig();
  await setP(d.trackId, d.fx, { thresholdDb: BURST_PEAK - 14.5, ratio: 20, kneeDb: 0,
                                attackMs: 1, makeupDb: 0, mix: 1, releaseMs: 30 });
  await cmd("ui.showMixer", { show: false });
  await burst("d3b-fast", 4.5, 0, { arrange: true });
  await setP(d.trackId, d.fx, { releaseMs: 800 });
  await cmd("ui.showMixer", { show: false });
  await burst("d3b-slow", 4.5, 0, { arrange: true });
}

// ── DEMO 3 RE-SHOT WITH A PAD — the panel that MATCHES d3pad.mjs's renders.
// ⚠ THE OLD comp-d3-rel-* SHOTS ARE THE WRONG PANEL FOR THE NEW AUDIO. They were
// photographed at threshold -34 / ratio 10 on a drums-only rig; the re-shot demo
// runs threshold PEAK-9 / ratio 20 / knee 2 / attack 1 on drums+pad. A panel
// photographed at settings no rendered file was made at is a picture that lies,
// and every gate in this rig would pass it.
const PAD_PEAK = parseFloat(process.env.COMP_D3_PEAK || "NaN");
async function padRig() {
  const kick = await addTrack("Kick", { instrument: { kind: "polySynth", waveform: "sine",
    attack: 0.001, decay: 0.13, sustain: 0.0, release: 0.05, cutoffHz: 400, resonance: 0.1, gain: 1.0 } });
  const snare = await addTrack("Snare", { instrument: { kind: "polySynth", waveform: "square",
    attack: 0.001, decay: 0.10, sustain: 0.0, release: 0.06, cutoffHz: 3000, resonance: 0.4, gain: 0.55 } });
  const hat = await addTrack("Hat", { instrument: { kind: "polySynth", waveform: "square",
    attack: 0.0005, decay: 0.035, sustain: 0.0, release: 0.02, cutoffHz: 9000, resonance: 0.2, gain: 0.3 } });
  const pad = await addTrack("Pad", { instrument: { kind: "polySynth", waveform: "saw",
    attack: 0.02, decay: 0.0, sustain: 1.0, release: 0.3, cutoffHz: 1800, resonance: 0.15, gain: 0.08 } });
  const BARS = 4, kn = [], sn = [], hn = [], pn = [];
  for (let b = 0; b < BARS; b++) {
    const o = b * 4;
    kn.push(n(o, 36, 0.4, 120), n(o + 2.5, 36, 0.4, 112));
    sn.push(n(o + 1, 40, 0.3, 118), n(o + 3, 40, 0.3, 118));
    for (let e = 0; e < 8; e++) hn.push(n(o + e * 0.5, 66, 0.12, e % 2 ? 70 : 96));
  }
  for (const p of [45, 52, 57]) pn.push(n(0, p, BARS * 4 + 2, 96));
  await addClip(kick, 0, BARS * 4, kn, "Kick");
  await addClip(snare, 0, BARS * 4, sn, "Snare");
  await addClip(hat, 0, BARS * 4, hn, "Hat");
  await addClip(pad, 0, BARS * 4 + 2, pn, "Pad");
  const r = await cmd("fx.add", { trackId: "master", kind: "compressor" });
  return { trackId: "master", fx: r.effectId };
}
if (run("d3p")) {
  if (!Number.isFinite(PAD_PEAK)) throw new Error("COMP_D3_PEAK must be the MEASURED dry peak dB of the pad rig");
  await fresh(); const d = await padRig();
  await setP(d.trackId, d.fx, { thresholdDb: PAD_PEAK - 9, ratio: 20, kneeDb: 2,
                                attackMs: 1, makeupDb: 0, mix: 1, releaseMs: 30 });
  await cmd("debug.panelLayout", { editorMaximized: false });
  await cmd("ui.showMixer", { show: false });
  await shot("app-pad-arrange");
  await openEditor(d.trackId, d.fx);
  await sweep(d.trackId, d.fx, "releaseMs", [30, 200, 800], "d3p-rel");
  await closeEditor();
}

// ── THE PLAY SEGMENTS. Separated from the sweeps because the first take of
// these photographed the MIXER: debug.effectEditor selects the MIX tab, and
// nothing in burst() selects it back, so twenty-one frames of "the app playing"
// were three channel strips with no arrangement, no playhead and no notes. Every
// gate in this rig passed them. `ui.showMixer {show:false}` is the fix, and it
// has to come before burst()'s own panel work rather than after.
if (run("bursts")) {
  await closeEditor();
  {                                  // the kit, in the arrangement, playing
    await fresh(); await drumRig();
    await cmd("ui.showMixer", { show: false });
    await burst("mat-drums", 7.0, 0, { arrange: true });
  }
  {                                  // the held tone, in the piano roll
    await fresh(); await toneRig();
    await cmd("ui.showMixer", { show: false });
    await burst("mat-tone", 5.0, 0);
  }
  {                                  // release 30 vs 800, the same bars twice
    await fresh(); const d = await drumRig();
    await setP(d.trackId, d.fx, { thresholdDb: -34, ratio: 10, kneeDb: 2,
                                  attackMs: 1, makeupDb: 0, mix: 1, releaseMs: 30 });
    await cmd("ui.showMixer", { show: false });
    await burst("d3-fast", 6.0, 0, { arrange: true });
    await setP(d.trackId, d.fx, { releaseMs: 800 });
    await cmd("ui.showMixer", { show: false });
    await burst("d3-slow", 6.0, 0, { arrange: true });
  }
}

console.log("shots in", SHOTS);
await close();
process.exit(0);   // ⚠ close() does not always drain node's event loop.
