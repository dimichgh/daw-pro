// Chapter material: every sound in the film, each built in its own fresh
// project and rendered solo, so a demo clip is exactly the sound being
// discussed and nothing else.
//
// THE CLAIM THIS FILM MAKES: saw, square, triangle, sine. That is the entire
// palette the poly synth offers -- there is no noise oscillator and no sample
// is loaded anywhere. Everything below is those four, a resonant filter, an
// envelope, and effects.
import { open, cmd, addTrack, addClip, n, rng, close, burst } from "./build.mjs";

const AUD = process.env.SESSION_AUDIO || "./audio";
const only = process.argv[2] || "all";
const want = (k) => only === "all" || only === k;

const fresh = async (bpm = 120) => {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
};
const render = async (name, seconds) => {
  const r = await cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: seconds });
  console.log(`  rendered ${name}.wav (${seconds}s)`);
  await burst(name, seconds);
  return r;
};


await open();

// ---------------------------------------------------------------- 1. SIREN
// One note, held. The pitch does all the work, through a pitch-bend lane.
// ⚠ The poly synth's bend range is the GM default of +/-2 semitones and there
// is no parameter to widen it (only the sampler has bendRangeSemitones), so
// the whole wail lives inside 4 semitones. That is close to a real two-tone
// siren's minor third, which is why it still reads as one.
if (want("siren")) {
  console.log("siren");
  await fresh(120);
  const id = await addTrack("Siren", { instrument: {
    kind: "polySynth", waveform: "saw",
    attack: 0.02, decay: 0.1, sustain: 0.95, release: 0.25,
    cutoffHz: 2600, resonance: 0.35, gain: 0.55 } });
  const clip = await addClip(id, 0, 16, [n(0, 69, 16, 105)], "Siren");
  // A triangle wave in pitch: up over a second, down over a second.
  const pts = [];
  for (let i = 0; i <= 160; i++) {
    const t = i / 10;                          // beats, 16 beats total
    const ph = (t / 2) % 1;                    // 2 beats = one wail at 120bpm
    const v = ph < 0.5 ? ph * 2 : 2 - ph * 2;  // 0..1..0
    // ⚠ pitchBend points are RAW 14-BIT MIDI, 0..16383 with 8192 as centre --
    // not the -1..+1 normalised value the name suggests. A normalised value is
    // REFUSED rather than silently clamped to the bottom of the range, which
    // is the one mercy here.
    pts.push({ beat: +t.toFixed(3), value: Math.round(8192 + 8191 * (-1 + 2 * v)) });
  }
  await cmd("clip.setControllerLane", { clipId: clip, type: "pitchBend", points: pts });
  await render("siren", 8);
}

// ------------------------------------------------------------ 2. HEARTBEAT
// A sine low enough that you feel it more than hear it, hit twice: lub-dub.
if (want("heart")) {
  console.log("heartbeat");
  await fresh(60);                              // 60 bpm = one beat per second
  const id = await addTrack("Heart", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.004, decay: 0.16, sustain: 0.0, release: 0.14,
    cutoffHz: 400, resonance: 0.0, gain: 0.95 } });
  const notes = [];
  for (let b = 0; b < 10; b++) {
    notes.push(n(b, 31, 0.18, 112));            // lub  (G0, ~49 Hz)
    notes.push(n(b + 0.30, 33, 0.16, 88));      // dub, softer and a touch higher
  }
  await addClip(id, 0, 10, notes, "Heart");
  await render("heart", 9);
}

// -------------------------------------------------------------- 3. THUNDER
// A low cluster with a filter closing over it. Thunder is not a pitch; it is a
// spectrum collapsing, which is exactly what a lowpass sweep does.
if (want("thunder")) {
  console.log("thunder");
  await fresh(120);
  const id = await addTrack("Thunder", { instrument: {
    kind: "polySynth", waveform: "saw",
    attack: 0.9, decay: 2.0, sustain: 0.55, release: 3.0,
    cutoffHz: 9000, resonance: 0.15, gain: 0.7 } });
  const r = rng(4242);
  const notes = [];
  for (let i = 0; i < 26; i++)                  // a detuned low cluster
    notes.push(n(+(r() * 1.2).toFixed(3), 24 + Math.floor(r() * 14), 7.5, 40 + Math.floor(r() * 50)));
  const clip = await addClip(id, 0, 16, notes, "Thunder");
  const eq = await cmd("fx.add", { trackId: id, kind: "eq" });
  const eqId = eq.effectId || (eq.effects && eq.effects[eq.effects.length - 1].id);
  await cmd("fx.setParam", { trackId: id, effectId: eqId, name: "lowPassEnabled", value: 1 });
  await cmd("fx.setParam", { trackId: id, effectId: eqId, name: "lowPassSlopeDbPerOct", value: 24 });
  const lane = await cmd("automation.addLane", {
    trackId: id, target: { type: "effectParam", effectId: eqId, param: "lowPassFreq" } });
  const laneId = lane.id || (lane.lane && lane.lane.id);
  // 12 kHz down to 90 Hz across eight beats: the rumble arriving after the crack.
  const pts = [];
  for (let i = 0; i <= 32; i++) {
    const k = i / 32;
    pts.push({ beat: +(k * 8).toFixed(3), value: +(12000 * Math.pow(90 / 12000, k)).toFixed(1) });
  }
  await cmd("automation.setPoints", { trackId: id, laneId, points: pts });
  const rv = await cmd("fx.add", { trackId: id, kind: "reverb" });
  const rvId = rv.effectId || (rv.effects && rv.effects[rv.effects.length - 1].id);
  for (const [k, v] of [["roomSize", 0.95], ["mix", 0.45], ["damping", 0.35], ["preDelayMs", 40]])
    await cmd("fx.setParam", { trackId: id, effectId: rvId, name: k, value: v });
  await render("thunder", 9);
}

// --------------------------------------------------------------- 4. THE 808
// A sine, a long decay, and a saturator. The most recognisable bass sound in
// popular music is a pure tone that somebody deliberately ruined.
if (want("bass808")) {
  console.log("808");
  await fresh(120);
  const id = await addTrack("808", { instrument: {
    kind: "polySynth", waveform: "sine",
    attack: 0.002, decay: 1.4, sustain: 0.0, release: 1.2,
    cutoffHz: 900, resonance: 0.0, gain: 0.9 } });
  await addClip(id, 0, 16, [n(0,29,2,118), n(4,29,2,118), n(8,32,2,110), n(12,27,3.5,120)], "808");
  const sat = await cmd("fx.add", { trackId: id, kind: "saturator" });
  const satId = sat.effectId || (sat.effects && sat.effects[sat.effects.length - 1].id);
  for (const [k, v] of [["driveDb", 14], ["mix", 0.85], ["outputDb", -4]])
    await cmd("fx.setParam", { trackId: id, effectId: satId, name: k, value: v });
  await render("bass808", 9);
  // The same notes with the saturator bypassed -- the A/B the chapter turns on.
  await cmd("fx.setBypass", { trackId: id, effectId: satId, bypassed: true });
  await render("bass808-clean", 9);
}

// ---------------------------------------------------------------- 5. VOWELS
// Two resonances are enough to make a vowel: F1 and F2 are what your ear reads.
// A saw wave through two narrow EQ peaks says "ah". Move the peaks and it says
// something else. No sample, no voice, no model -- two numbers.
if (want("vowel")) {
  console.log("vowels");
  const VOWELS = { ee: [270, 2290], eh: [530, 1840], ah: [730, 1090], oh: [570, 840], oo: [300, 870] };
  await fresh(100);
  const id = await addTrack("Voice", { instrument: {
    kind: "polySynth", waveform: "saw",
    attack: 0.05, decay: 0.2, sustain: 0.9, release: 0.3,
    cutoffHz: 6000, resonance: 0.05, gain: 0.35 } });
  const names = Object.keys(VOWELS);
  await addClip(id, 0, names.length * 2,
    names.map((_, i) => n(i * 2, 50, 1.8, 100)), "Voice");
  const eq = await cmd("fx.add", { trackId: id, kind: "eq" });
  const eqId = eq.effectId || (eq.effects && eq.effects[eq.effects.length - 1].id);
  for (const [k, v] of [["peak1Enabled",1],["peak2Enabled",1],["peak1Q",9],["peak2Q",9],
                        ["peak1GainDb",18],["peak2GainDb",16],
                        ["highPassEnabled",1],["highPassFreq",90]])
    await cmd("fx.setParam", { trackId: id, effectId: eqId, name: k, value: v });
  const mk = async (param) => {
    const l = await cmd("automation.addLane", {
      trackId: id, target: { type: "effectParam", effectId: eqId, param } });
    return l.id || (l.lane && l.lane.id);
  };
  const l1 = await mk("peak1Freq"), l2 = await mk("peak2Freq");
  const p1 = [], p2 = [];
  names.forEach((v, i) => {
    const [f1, f2] = VOWELS[v];
    // Step to the vowel just before its note, so the formants are already in
    // place when the note speaks rather than gliding into it mid-syllable.
    p1.push({ beat: +(i * 2 - 0.05).toFixed(3) < 0 ? 0 : +(i * 2 - 0.05).toFixed(3), value: f1 });
    p2.push({ beat: +(i * 2 - 0.05).toFixed(3) < 0 ? 0 : +(i * 2 - 0.05).toFixed(3), value: f2 });
  });
  await cmd("automation.setPoints", { trackId: id, laneId: l1, points: p1 });
  await cmd("automation.setPoints", { trackId: id, laneId: l2, points: p2 });
  await render("vowel", names.length * 2 * 60 / 100 + 1);
  console.log("  vowels:", names.join(" "));
}

await close();
console.log("done");
// ⚠ EXIT EXPLICITLY. Closing the socket does not always let node's event loop
// drain, and a script that has finished its work but never exits looks exactly
// like a script that hung — it blocked a capture loop for four minutes per
// chapter before anyone noticed the work was already done.
process.exit(0);
