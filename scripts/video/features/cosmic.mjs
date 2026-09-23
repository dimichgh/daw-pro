#!/usr/bin/env node
// "СВЕТ ЗВЁЗД" / STARLIGHT — a beatless cosmic piece.
//
//   node cosmic.mjs [a|b|c|d] [--long]
//
// ⛔⛔ THIS REPLACED A SPACE-DISCO AND THE USER IS THE ONE WHO CAUGHT IT.
// The first version was 118 BPM with a four-on-the-floor kick, a driving
// offbeat bass and a 16th-note arpeggio — "in the spirit of the 1977 band
// Space", which is what they had asked for earlier. Then they named a specific
// reference: «А. Рыбников — СВЕТ ЗВЁЗД», the theme from *Через тернии к
// звёздам* (1981), and said "we do not need beats at all, it is smooth with
// variations".
//
// That is not a tweak to a disco track. Rybnikov's piece has NO pulse at all:
// sustained strings, a wordless voice floating on top, harmony that moves about
// once every two bars, and all of its motion in TIMBRE rather than rhythm. So
// the kick, the hats, the offbeat bass and the driving arpeggio are all gone. A
// bass playing offbeat eighths is a beat too, even when nothing is hitting a
// drum — so it went with the drums.
//
// ---------------------------------------------------------------------------
// FOUR VERSIONS. a/b/c are ONE AXIS APART — texture density. d is a SECOND
// axis, added on the user's request, and the difference is named honestly
// rather than folded into the same list:
//   a  pads + voice only ............ the barest reading
//   b  + a slow shimmer ............. eighth notes, quiet, long release  ⭐ liked
//   c  + sustained bass roots ....... whole notes, no pulse
//   d  POWER — the Butterworth rise ................................ see below
//
// ⭐⭐ WHY d EXISTS, AND WHY IT IS A DIFFERENT KNOB.
// The user pointed at one file from the effects listening bench — "Butterworth
// — no peak at all" — and said "it has that power, like something is raising".
// That file is the resonance-0.0 CONTROL of the resonance bench: the same
// filter sweep as its three neighbours, with the peak switched off. Two
// measured reasons it reads as power rather than as less:
//   ① With no resonant peak, the ENTIRE spectrum rises together. A resonant
//      sweep spotlights one travelling frequency — you hear a whistle moving
//      across a sound. A Butterworth sweep has nothing to listen to except the
//      whole thing getting bigger, which is what "something is raising" is.
//   ② The app deliberately SCALES BACK high-resonance settings so a Q-10 peak
//      cannot slam the mix (bench note: "high resonance deliberately makes the
//      filter quieter"). Resonance 0.0 takes no such reduction, so it keeps its
//      full broadband energy. The quietest-sounding setting is the loudest one.
// So d runs its filter at resonance 0.0 and spends its whole length on ONE
// continuous opening, with the arrangement thickening underneath it.
//
// ---------------------------------------------------------------------------
// ⭐⭐ THE BEATLESS RULE STILL STANDS HERE, AND HAS ONE NAMED EXCEPTION
// ELSEWHERE. READ THIS BEFORE REFUSING TO BUILD A PULSE.
// On 2026-09-21, after hearing a/b/c/d, the user picked the power version and
// asked for "a few drastically different versions of each track (power one and
// original)" — and, asked what drastic should mean, answered in their own
// words: **"2 versions each, one with pulse"**.
//
// So the prohibition above is NOT withdrawn and NOT softened for a/b/c/d: this
// file stays beatless, because beatless is what they approved. The exception is
// scoped exactly as they scoped it — in `develop.mjs`, ONE of the two drastic
// versions per track may carry a pulse, and the other must not. A future
// session reading the ⛔⛔ block above WITHOUT this one would refuse to build a
// deliverable the user explicitly asked for, which is why the ruling is written
// at the point of refusal rather than only in a notes file.
//
// ⚠ THE SYNTH HAS NO GLIDE AND NO VIBRATO — PROBED, NOT ASSUMED. All 24
// polySynth parameters were enumerated: no portamento, no LFO, no vibrato.
// (Memory claimed "glide shipped"; that is a different instrument.) A vocalise
// slides, so the notes OVERLAP instead — each is longer than the gap to the
// next, so the release carries one pitch into the next and the line never
// articulates.
import { open, close, cmd, addTrack, addBus, addClip, addFx, automate } from "./arrange.mjs";
import fs from "node:fs";
import path from "node:path";

// ⚠ SOURCES live in the repo; OUTPUT goes to the scratchpad, the same root
// build.mjs, the loops, the VO and the visualisers already use.
const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");

const ARGS = process.argv.slice(2);
const VARIANT = (ARGS.find((a) => !a.startsWith("--")) || "b").toLowerCase();
const LONG = ARGS.includes("--long");
if (!["a", "b", "c", "d"].includes(VARIANT)) {
  console.error(`unknown version '${VARIANT}' — use a, b, c or d`);
  process.exit(1);
}
const SHIMMER = ["b", "c", "d"].includes(VARIANT);
const BASS = ["c", "d"].includes(VARIANT);
const POWER = VARIANT === "d";

// What ONE thing each version changes — this is the caption on its video, so a
// listener can say which one they preferred without having to remember a file
// name. Keep these phrased as what you would HEAR, not as what was configured.
const AXIS = {
  a: "Strings and voice, nothing else",
  b: "Strings, voice and a slow shimmer",
  c: "Strings, voice, shimmer and a low register",
  d: "All of it, an octave lower — and no filter peak at all",
};

// 63 BPM: one bar lasts 3.8 seconds, so a chord change every bar already feels
// slow. Short form 40 bars = 2:32; long form 80 bars = 5:05.
const TEMPO = 63;

// ⚠ THE FORM IS A TABLE, AND THE SWEEP IS GENERATED FROM IT. Hard-coded
// automation beats silently desynchronise from the arrangement the moment a
// section length changes — which is exactly what a long form does.
//   lead:  how many statements of the theme, and the transposition of each
//   filt:  where the filter sits at the START of this section
const SHORT_FORM = [
  { name: "Emergence", bars: 8,  filt: -0.62, lead: [] },
  { name: "Light",     bars: 8,  filt: -0.30, lead: [] },
  { name: "Theme",     bars: 8,  filt:  0.0,  lead: [0] },
  { name: "Wide",      bars: 8,  filt:  0.0,  lead: [0] },
  { name: "Fade",      bars: 8,  filt: -0.34, lead: ["half"] },
];
// The long form earns its length by GOING SOMEWHERE, not by repeating. It pulls
// back to almost nothing at Drift, returns an octave up, and spends sixteen
// bars on one unbroken climb before letting go.
const LONG_FORM = [
  { name: "Emergence", bars: 8,  filt: -0.62, lead: [] },
  { name: "Light",     bars: 8,  filt: -0.30, lead: [] },
  { name: "Theme",     bars: 8,  filt:  0.0,  lead: [0] },
  { name: "Wide",      bars: 8,  filt:  0.0,  lead: [0] },
  { name: "Drift",     bars: 8,  filt: -0.48, lead: [] },          // almost gone
  { name: "Return",    bars: 16, filt: -0.10, lead: [0, 12] },     // then an octave up
  { name: "Rise",      bars: 16, filt: -0.55, lead: [12, 12] },    // ⭐ the long climb
  { name: "Fade",      bars: 8,  filt: -0.30, lead: ["half"] },
];

const FORM = LONG ? LONG_FORM : SHORT_FORM;
let _bar = 0;
const SECTIONS = FORM.map((s) => ({ ...s, bar: (_bar += s.bars) - s.bars }));
const BARS = _bar;

// ----------------------------------------------------------------- material
// The harmony, the vocalise and the four note generators moved to
// `cosmic-material.mjs` on 2026-09-21 so `develop.mjs` could share them without
// importing THIS file — an ES import RUNS a module, and this one opens the
// control socket, runs `project.new` and renders a wav at its top level.
//
// The move was gated on a NOTE-LIST DIFF, not a re-render: 84 argument cases,
// 1982 notes, zero mismatches, with a planted velocity change proving the
// comparison could fail. a/b/c/d were NOT re-rendered and did not need to be.
//
// The generators now take their harmony as a leading argument so other pieces
// can pass their own; these three binders hold the D-aeolian tables, which
// keeps every call site below unchanged.
import {
  CHORDS_DM, ROOTS_DM, THEME,
  padNotes as _pad, shimmerNotes as _shimmer,
  bassNotes as _bass, leadNotes as _lead,
} from "./cosmic-material.mjs";

const padNotes = (bar0, bars, opts) => _pad(CHORDS_DM, bar0, bars, opts);
const shimmerNotes = (bar0, bars) => _shimmer(CHORDS_DM, bar0, bars);
const bassNotes = (bar0, bars, velocity) => _bass(ROOTS_DM, bar0, bars, velocity);
const leadNotes = (spec, bars) => _lead(THEME, spec, bars);

// -------------------------------------------------------------------- build
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: TEMPO });
for (const s of SECTIONS) await cmd("marker.add", { name: s.name, beat: s.bar * 4 });

const mixBus = await addBus("Mix Bus");

// THE WASH — the whole floor of the piece. Very long attack so nothing ever
// starts, only arrives; drift and jitter so the tuning is never quite still.
const padT = await addTrack("Strings", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 7, unisonDetuneCents: 26, unisonStereoSpread: 1.0,
  cutoffHz: POWER ? 3200 : 2300, resonance: 0.2, keyToCutoff: 0.4,
  drift: 0.5, voiceJitter: 0.34, noiseLevel: 0.03, noiseColor: 0.22,
  drive: POWER ? 0.3 : 0,
  attack: 1.5, decay: 1.2, sustain: 0.9, release: 3.2, gain: POWER ? 0.6 : 0.5,
}, { volume: POWER ? 0.78 : 0.7, pan: -0.08, busId: mixBus });
for (const s of SECTIONS) {
  await addClip(padT, s.bar * 4, s.bars * 4, padNotes(s.bar, s.bars), `Strings ${s.name}`);
}

// A second wash an octave up, quieter — the "halo". This is what makes a pad
// sound like a sky rather than a chord.
const haloT = await addTrack("Halo", {
  kind: "polySynth", waveform: "triangle",
  unisonVoices: 5, unisonDetuneCents: 18, unisonStereoSpread: 0.9,
  cutoffHz: 4200, resonance: 0.16, drift: 0.4, voiceJitter: 0.3,
  attack: 2.2, decay: 1.5, sustain: 0.85, release: 4.0, gain: 0.3,
}, { volume: 0.44, pan: 0.14, busId: mixBus });
for (const s of SECTIONS) {
  if (s.name === "Emergence") continue;             // the sky opens after the ground
  await addClip(haloT, s.bar * 4, s.bars * 4,
    padNotes(s.bar, s.bars, { octave: 12, velocity: 46 }), `Halo ${s.name}`);
}

// ⭐ POWER ONLY — a LOW octave of the string chord. This is most of where "more
// power" actually comes from: not more volume, but chord tones an octave down
// so the filter has real low-mid mass to open onto. Width kept narrow; wide
// low frequencies smear.
let lowT = null;
if (POWER) {
  lowT = await addTrack("Low Strings", {
    kind: "polySynth", waveform: "saw",
    unisonVoices: 5, unisonDetuneCents: 14, unisonStereoSpread: 0.35,
    subLevel: 0.3, subOctave: -1, subWaveform: "sine",
    cutoffHz: 1400, resonance: 0.14, drift: 0.3, voiceJitter: 0.2, drive: 0.35,
    attack: 1.2, decay: 1.4, sustain: 0.9, release: 3.0, gain: 0.55,
  }, { volume: 0.62, pan: 0.02, busId: mixBus });
  for (const s of SECTIONS) {
    if (s.name === "Emergence") continue;
    await addClip(lowT, s.bar * 4, s.bars * 4,
      padNotes(s.bar, s.bars, { octave: -12, velocity: 62 }), `Low ${s.name}`);
  }
}

let shimmerT = null;
if (SHIMMER) {
  shimmerT = await addTrack("Shimmer", {
    kind: "polySynth", waveform: "triangle",
    unisonVoices: 3, unisonDetuneCents: 12, unisonStereoSpread: 0.8,
    cutoffHz: 5200, resonance: 0.18, keyToCutoff: 0.5, velocityToCutoff: 0.3,
    drift: 0.2, voiceJitter: 0.2,
    attack: 0.04, decay: 0.9, sustain: 0.25, release: 1.4, gain: 0.3,
  }, { volume: 0.36, pan: 0.2, busId: mixBus });
  for (const s of SECTIONS) {
    if (s.name === "Emergence") continue;
    await addClip(shimmerT, s.bar * 4, s.bars * 4, shimmerNotes(s.bar, s.bars), `Shimmer ${s.name}`);
  }
}

let bassT = null;
if (BASS) {
  bassT = await addTrack("Deep", {
    kind: "polySynth", waveform: "sine",
    subLevel: POWER ? 0.8 : 0.6, subOctave: -1, subWaveform: "sine",
    cutoffHz: 420, resonance: 0.1, drive: POWER ? 0.25 : 0,
    attack: 0.8, decay: 1.0, sustain: 0.85, release: 2.4, gain: POWER ? 0.85 : 0.7,
  }, { volume: POWER ? 0.72 : 0.6, busId: mixBus });
  for (const s of SECTIONS) {
    if (s.name === "Emergence") continue;
    await addClip(bassT, s.bar * 4, s.bars * 4,
      bassNotes(s.bar, s.bars, POWER ? 76 : 64), `Deep ${s.name}`);
  }
}

// ⭐⭐ THE VOICE — the whistle at the edge, singing.
// resonance 0.78 + resonanceBoost 0.62 puts the filter at the point where its
// peak self-oscillates; keyToCutoff 0.9 makes that peak follow the note, so it
// sings the tune instead of whistling on one fixed pitch. The long attack is
// what separates this from the disco version: the note arrives, it does not hit.
const leadT = await addTrack("Voice", {
  kind: "polySynth", waveform: "square",
  unisonVoices: 3, unisonDetuneCents: 11, unisonStereoSpread: 0.55,
  subLevel: 0.18, subOctave: -1, subWaveform: "sine",
  cutoffHz: 1450, resonance: 0.78, resonanceBoost: 0.62,
  keyToCutoff: 0.9, velocityToCutoff: 0.4,
  drive: 0.16, drift: 0.28, voiceJitter: 0.12, envelopeCurve: 0.55,
  attack: 0.35, decay: 1.2, sustain: 0.7, release: 2.6, gain: 0.46,
}, { volume: 0.68, pan: 0.05, busId: mixBus });
for (const s of SECTIONS) {
  if (!s.lead.length) continue;
  await addClip(leadT, s.bar * 4, s.bars * 4, leadNotes(s.lead, s.bars), `Voice ${s.name}`);
}

// ------------------------------------------------------------------ effects
const fx = {};
fx.padVerb   = await addFx(padT, "hallReverb", { mix: POWER ? 0.5 : 0.62, decaySeconds: 6.5, sizeMeters: 40, preDelayMs: 45 });
fx.padPhaser = await addFx(padT, "phaser", { rateHz: 0.05, stages: 8, depthOctaves: 3.6, mix: 0.45 });
fx.haloVerb  = await addFx(haloT, "hallReverb", { mix: 0.7, decaySeconds: 7.5, sizeMeters: 45, preDelayMs: 60 });
fx.haloWide  = await addFx(haloT, "stereoWidth", { width: 1.5 });
fx.leadDelay = await addFx(leadT, "tapeDelay", { timeMs: 720, feedback: 0.44, mix: 0.32, wowDepthMs: 4.5 });
fx.leadVerb  = await addFx(leadT, "hallReverb", { mix: 0.5, decaySeconds: 5.5, sizeMeters: 36, preDelayMs: 35 });
if (shimmerT) {
  fx.shimDelay = await addFx(shimmerT, "tapeDelay", { timeMs: 571, feedback: 0.5, mix: 0.42, wowDepthMs: 3.0 });
  fx.shimVerb  = await addFx(shimmerT, "hallReverb", { mix: 0.66, decaySeconds: 6.0, sizeMeters: 38, preDelayMs: 25 });
}
if (lowT) {
  fx.lowVerb = await addFx(lowT, "hallReverb", { mix: 0.3, decaySeconds: 4.0, sizeMeters: 28, preDelayMs: 20 });
  // ⚠ Glue, not colour: the low octave is the one layer that can eat headroom
  // when the filter opens, and a Butterworth open has no peak-scaling to hide
  // behind. The saturator adds harmonics that read as loudness without level.
  fx.lowSat  = await addFx(lowT, "saturator", { driveDb: 5, mix: 0.45 });
}

// ⭐ THE SWEEP, AND HERE IT IS THE ONLY THING THAT BUILDS.
// ⛔ IT IS ON THE STRINGS, NOT THE BUS, AND THAT IS A MEASURED DECISION.
// On the bus at high resonance the djFilter has a brutal cliff either side of
// zero — measured on the previous version, position -0.08 gave -41.5 LUFS
// against -31.9 at 0.0: 9.6 LU for eight hundredths of travel. With drums that
// was survivable. With nothing but pads there is no floor underneath, so a bus
// sweep would take the whole piece inaudible. Putting it on the STRINGS means
// the sweep changes the COLOUR of the wash while the halo and the voice hold
// the level up — which is also what it does on the record.
//
// ⭐ d RUNS IT AT RESONANCE 0.0 — Butterworth, no peak. That is the whole point
// of that version: the entire spectrum rises together instead of one frequency
// whistling across it, and nothing gets scaled back.
fx.padFilter = await addFx(padT, "djFilter", {
  position: SECTIONS[0].filt,
  resonance: POWER ? 0.0 : 0.55,
});

// Build the automation from the form table, so the sweep can never drift out of
// step with the arrangement. Each section gets a point at its downbeat and a
// point just before the next one, so the travel happens ACROSS the section
// rather than instantly at the boundary.
const SWEEP = [];
SECTIONS.forEach((s, i) => {
  const start = s.bar * 4;
  const next = SECTIONS[i + 1];
  SWEEP.push({ beat: start, value: s.filt });
  if (next) {
    // ⭐ "Rise" is the exception and the reason d exists: instead of settling,
    // it climbs for its whole length. Everything else eases toward the next
    // section over the last quarter of this one.
    if (s.name === "Rise") SWEEP.push({ beat: start + s.bars * 4 - 1, value: 0.0 });
    else SWEEP.push({ beat: start + s.bars * 4 - Math.max(2, s.bars), value: s.filt });
  } else {
    SWEEP.push({ beat: start + s.bars * 4 - 1, value: LONG ? -0.66 : -0.66 });
  }
});
fx.sweepLane = await automate(padT, fx.padFilter, "position", SWEEP);

fx.masterLimiter = await addFx("master", "limiter", { ceilingDb: -1.0, truePeak: 1, releaseMs: 80 });

// ⭐ THE BREATH — a slow LFO on the VOICE's own cutoff.
// The synth has no vibrato, so this is how a held note stops being static.
// 0.13 Hz is about one cycle every eight seconds: not a wobble, a breath.
// ⚠ THE SIGNATURE TOOK TWO REFUSALS TO PIN DOWN, AND BOTH NAMED THE ANSWER.
//   ① flat keys      → "valid keys are 'kind','name','params','trackId'"
//   ② params.depth   → "unknown modulation param 'depth' for kind 'lfo' —
//                       valid: waveform, rateHz, syncDivision, phaseDeg,
//                       pulseWidth, edgeMs, bipolar, seed"
// So an LFO source describes only its SHAPE; how far it moves anything is a
// property of the ROUTE, not the source — one LFO can drive two destinations by
// different amounts. `shape` is spelled `waveform`.
// ⚠ `instrumentParam` is addressed BY NAME with no id. NOT wrapped in a silent
// catch: if the modulation layer refuses, the piece still renders and the
// failure has to be VISIBLE.
let breath = null;
try {
  const src = await cmd("mod.addSource", {
    trackId: leadT, kind: "lfo", name: "Breath",
    params: { waveform: "sine", rateHz: 0.13, bipolar: true },
  });
  const srcId = src.sourceId || src.id;
  const route = await cmd("mod.addRoute", {
    trackId: leadT, sourceId: srcId,
    // ⚠ `param`, NOT `parameter` — the third refusal in this one call chain,
    // and like the other two it named the answer: "'target' must be {type, …
    // param?} — missing 'param'". Verified by round-trip: mod.describe reads
    // the route back with target {type:"instrumentParam", param:"cutoffHz"}.
    target: { type: "instrumentParam", param: "cutoffHz" },
    depth: 0.22,   // ⭐ DEPTH LIVES ON THE ROUTE, not the source (refusal ②)
  });
  breath = { srcId, routeId: route.routeId || route.id };
  console.log(`breath LFO: source=${srcId} route=${breath.routeId}`);
} catch (e) {
  console.error(`⚠ BREATH LFO NOT APPLIED — ${String(e.message || e).slice(0, 300)}`);
}

// A setter's return is not proof: read the whistle and the filter back.
const d = await cmd("instrument.describeSynth", { trackId: leadT });
const P = d.parameters || d.params || d;
console.log(`voice: resonance=${P.resonance?.value} resonanceBoost=${P.resonanceBoost?.value} attack=${P.attack?.value}`);
// ⚠ GUARDED, AND ONLY BECAUSE THIS IS A READ-BACK. `fx.describe`'s signature is
// not verified here, and it sits AFTER the whole arrangement is built but
// BEFORE the render — an unverified verb in that position would throw the build
// away to satisfy a check. The check still runs and still reports loudly; it
// just cannot destroy the thing it is checking.
// ⚠ `fx.describe` takes ONLY `kind` — it is a CATALOG lookup (what does a
// djFilter have?), not an instance read (what is THIS djFilter set to?). There
// is no per-instance read-back verb, so the filter's resonance is asserted from
// the render instead: measure.py checks d's spectrum against a/b/c.
console.log(`filter: resonance requested = ${POWER ? 0.0 : 0.55}` +
            `${POWER ? "  ← Butterworth, no peak — verified in the render, not here" : ""}`);

const id = `cosmic-${VARIANT}${LONG ? "-long" : ""}`;
const outDir = `${DIR}/out/${id}`;
const wav = path.resolve(`${outDir}/${id}.wav`);
fs.mkdirSync(outDir, { recursive: true });
const seconds = (BARS * 4 / TEMPO) * 60;
// +8 s of tail: the halo's release is 4 s and the hall decays for 7.5 s, so a
// render that stops at the last beat chops the ending off mid-air.
await cmd("render.mixdown", { path: wav, durationSeconds: Math.ceil(seconds) + 8 });

const DESC = {
  a: "The barest reading: two sustained string layers and the voice, nothing else moving.",
  b: "A slow shimmer underneath — eighth notes so quiet and so long-released that they read as light, not as a pattern.",
  c: "The shimmer plus a sustained low register. Whole notes only; nothing you could count.",
  d: "POWER. A Butterworth filter — no resonant peak at all — so the whole spectrum rises together instead of one frequency whistling across it, over a low octave of strings that gives it something to open onto.",
};
fs.writeFileSync(`${outDir}/build.json`, JSON.stringify({
  // ⛔⛔ THE CARD MUST NAME THE VERSION. All four versions shipped captioned
  // "Starlight — Cosmic · D minor · 63 BPM · no percussion", identically, under
  // a request to "tell me a letter". A listener comparing four files cannot
  // report a preference they have no way to name, and the whole point of
  // shipping options that differ on ONE axis is that the pick IS the feedback.
  // So the letter goes in the title and the axis goes in the subtitle.
  variant: id, title: `Starlight ${VARIANT.toUpperCase()}${LONG ? " · long" : ""}`,
  subtitle: `${AXIS[VARIANT] ?? "Cosmic"} · D minor · ${TEMPO} BPM${LONG ? " · long form" : ""}`,
  blurb: `Beatless, in the spirit of Rybnikov's «Свет звёзд». ${DESC[VARIANT]}`,
  texture: VARIANT, long: LONG, tempo: TEMPO, bars: BARS,
  sections: SECTIONS, sweep: SWEEP,
  tracks: { pad: padT, halo: haloT, low: lowT, shimmer: shimmerT, bass: bassT, lead: leadT, mixBus },
  fx, breath, wav, at: new Date().toISOString(),
}, null, 2));
console.log(`wrote ${wav} — ${BARS} bars, ${(seconds / 60).toFixed(2)} min + 8 s tail`);
close();
process.exit(0);
