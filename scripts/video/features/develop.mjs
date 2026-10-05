#!/usr/bin/env node
// STARLIGHT, DEVELOPED — five pieces, ~3:30 each.
//
//   node develop.mjs ascent|collapse|heartbeat|aurora|signal
//
// ⭐ THE BRIEF, IN THE USER'S OWN WORDS (2026-09-21, after picking version d):
//   "I have picked the power version. Make it ~3+ min composition. Make it
//    developing, from simple to complex, cosmic energies fluctuating and so on,
//    maybe a few drastically different version of each track (power one and
//    original)"
// and, asked which tracks and what "drastic" should mean:
//   Starlight D + Starlight B  ·  "2 versions each, one with pulse"
//
// So: five pieces. The headline is a NEW developmental D; then two drastic
// readings of D and two of B, one of each pair carrying a pulse.
//
//   cosmic-ascent      D, developmental ......................... beatless
//   cosmic-collapse    D, drastic — the arc INVERTED, slower ..... beatless
//   cosmic-heartbeat   D, drastic — a slow pulse underneath ...... ⚠ PULSE
//   cosmic-aurora      B, drastic — new harmony, brighter, faster  beatless
//   cosmic-signal      B, drastic — the shimmer becomes a pulse .. ⚠ PULSE
//
// ---------------------------------------------------------------------------
// ⭐⭐ ON THE PULSE, AND WHY THIS FILE IS ALLOWED TO HAVE ONE.
// `cosmic.mjs` opens with a ⛔⛔ block saying this music has NO PULSE AT ALL —
// written because the first cosmic attempt was a 118 BPM space-disco and the
// user had to catch it. That rule is not withdrawn: a/b/c/d stay beatless,
// because beatless is what they approved, and three of the five pieces here are
// beatless too. The exception is exactly the one they asked for, scoped exactly
// as they scoped it — ONE of the two drastic versions per track. The other must
// not have one, or there is nothing to compare.
//
// Both pulsed pieces also END beatless: the pulse layer is absent from the final
// section, so the piece still finishes on the wash rather than stopping a beat.
//
// ⚠ THE PULSE IS MADE OF NOTES, NOT OF A MODULATION ROUTE. A trance-gate LFO on
// the volume fader would be the more interesting sound, but the route target
// shape for volume is NOT verified here — three separate refusals were needed to
// pin down `{type:"instrumentParam", param:"cutoffHz"}`, and a wrong guess in
// this position fails at build time after the whole arrangement is up. A note on
// a synth with a fast attack cannot fail silently: either it is in the render or
// the clip is empty and `addClip` says so.
//
// ---------------------------------------------------------------------------
// ⭐⭐ WHAT "DEVELOPING, SIMPLE TO COMPLEX" IS BUILT OUT OF — TWO MECHANISMS.
//
// ① LAYER GATING. Every section names the layers that play in it, and a track
//    only gets a clip where it is named. The opening is ONE synth; the climax is
//    six. This is the difference between a piece that develops and a piece that
//    repeats with the filter moving, which is what the 40-bar versions were.
//
// ② AN UNDULATING SWEEP — "cosmic energies fluctuating", made literal. The old
//    sweep had two points per section: arrive, hold. Here each section travels
//    from its own value to the next one AND carries `wob` cycles of a ±`amp`
//    ripple on the way, so the filter is never still. The ripple deepens as the
//    piece thickens, which is why the late sections shimmer more than the early
//    ones even where the texture is the same.
//
// ⭐ AND THE TWO DELIBERATELY DISAGREE ONCE. In `Depths` the arrangement gets
// its heaviest layers (low octave + sub) at the same moment the filter CLOSES.
// Energy keeps rising while brightness falls — that is the fluctuation the brief
// asks for, and it is why the climb out of it lands. Measured per section by
// `section-arc.py`: loudness rises almost monotonically, centroid dips there.
import {
  CHORDS_DM, ROOTS_DM, THEME,
  padNotes, shimmerNotes, bassNotes, leadNotes,
} from "./cosmic-material.mjs";
import fs from "node:fs";
import path from "node:path";

// ⛔⛔ THE RENDER TIMEOUT IS SET HERE, AND THE `await import` BELOW IS WHY IT
// WORKS. `dawctl.mjs` reads `DAW_TIMEOUT_MS` ONCE, AT MODULE LOAD, and defaults
// to 30 s — but these pieces are three and a half minutes long and take longer
// than that to render. A static `import` of arrange.mjs is HOISTED above every
// statement in this file, so assigning the variable up here would be too late:
// dawctl would already have captured 30000. Hence the dynamic import, which
// runs at exactly this point in the file.
//
// MEASURED, NOT GUESSED: the first run of `ascent` died with "render.mixdown: no
// reply in 30000ms" after 31 s, leaving out/cosmic-ascent EMPTY. Putting the
// value in the shell command instead would have worked once and been forgotten
// — the same shape as the branding step that shipped six visualisers with the
// wrong outro because it lived only in someone's history.
// ⚠ 30 MINUTES, RAISED FROM 15 ON 2026-09-21, AND THE REASON IS CONTENTION.
// A 3½-minute piece renders in ~4 min and 900 s looked like ample headroom. The
// five-minute forms take ~9-10 min quiescent — and a re-render of `ascent5` blew
// the 900 s limit outright because a `section-arc.py` measurement pass (70 ffmpeg
// invocations) was running at the same time. The render was fine; it was simply
// sharing the machine. ⛔ THE REAL LESSON IS THE SCHEDULING ONE — do not run
// ffmpeg batches while a render is in flight — but the timeout should not be the
// thing that converts a slow render into a lost one, so it is no longer near the
// edge. A dead app still fails fast: this only bounds the wait.
process.env.DAW_TIMEOUT_MS ||= "1800000";
const { open, close, cmd, addTrack, addBus, addClip, addFx, automate } =
  await import("./arrange.mjs");

const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const WHICH = (process.argv[2] || "").toLowerCase();

// --------------------------------------------------------------- harmony (B')
// ⭐ AURORA'S OWN HARMONY — the one thing that makes it drastic rather than
// "version b again, but longer".
//
// Two changes a non-musician can hear without being told what to listen for:
//   ① FOUR chords instead of eight, so the harmony moves TWICE AS OFTEN. The
//      generators index by bar modulo the table length, so a shorter table is
//      the whole implementation — no new code path.
//   ② NO THIRDS. Every chord is a stack of fourths and fifths, which is neither
//      major nor minor. The original is unmistakably sad; this is open and cold
//      instead, and that difference survives a phone speaker.
// The vocalise still fits: its Bb and F land as colour tones over these, not as
// clashes, because there is no third for them to argue with.
const CHORDS_AURORA = [
  [62, 69, 76],   // D4 A4 E5 ..... fifths stacked; the 9th on top is the "air"
  [58, 65, 72],   // Bb3 F4 C5
  [57, 64, 71],   // F3 C4 G4
  [60, 67, 74],   // C4 G4 D5
];
const ROOTS_AURORA = [38, 34, 33, 36];

/** THE PULSE. Whole-bar root notes subdivided by `div` beats, with the downbeat
 *  accented and the rest pulled back — a heartbeat, not a drum pattern. At 63
 *  BPM `div: 2` is one impulse every 1.9 s, which reads as breathing; `div: 1`
 *  doubles it for the climb, and that doubling IS the pulse's own development. */
const pulseNotes = (roots, bar0, bars, { div = 2, velocity = 74, lengthBeats = 1.1, octave = 0 } = {}) => {
  const n = [];
  for (let b = 0; b < bars; b++) {
    const root = roots[(bar0 + b) % roots.length] + octave;
    for (let k = 0; k * div < 4; k++) {
      n.push({
        startBeat: b * 4 + k * div, pitch: root, lengthBeats,
        velocity: k === 0 ? velocity : velocity - 14,
      });
    }
  }
  return n;
};

// ------------------------------------------------------------------- pieces
// `layers` is the gate. `filt`/`to` are where the sweep starts and ends in that
// section; `wob`/`amp` are how much it fluctuates on the way.
const L = {
  bare:    ["pad"],
  sky:     ["pad", "halo"],
  sung:    ["pad", "halo", "voice"],
  lit:     ["pad", "halo", "voice", "shimmer"],
  deep:    ["pad", "halo", "shimmer", "low", "deep"],
  full:    ["pad", "halo", "voice", "shimmer", "low", "deep"],
};
const plus = (base, ...x) => [...base, ...x];

const PIECES = {
  // ⭐ THE HEADLINE — the ~3:30 developmental power version the brief asks for.
  ascent: {
    id: "cosmic-ascent", tempo: 63, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Ascent",
    subtitle: "THE POWER ONE, DEVELOPED · D minor · 63 BPM · beatless",
    blurb: "The version you picked, rebuilt as a 3½-minute arc. It opens on one synth and ends on six. Halfway through, the heaviest layers arrive at the same moment the filter closes — the music gets thicker and darker at once — and the last ninety seconds are one continuous Butterworth climb out of that.",
    form: [
      { name: "Emergence", bars: 6,  filt: -0.72, to: -0.58, wob: 1, amp: 0.03, lead: [],        layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.58, to: -0.40, wob: 1, amp: 0.04, lead: [],        layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.40, to: -0.22, wob: 2, amp: 0.05, lead: [0],       layers: L.sung },
      { name: "Widening",  bars: 8,  filt: -0.22, to: -0.10, wob: 2, amp: 0.06, lead: [0],       layers: L.lit },
      { name: "Depths",    bars: 8,  filt: -0.10, to: -0.44, wob: 2, amp: 0.07, lead: [],        layers: L.deep },
      { name: "Ascent",    bars: 16, filt: -0.44, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],   layers: L.full },
      { name: "Release",   bars: 6,  filt:  0.00, to: -0.55, wob: 1, amp: 0.03, lead: ["half"],  layers: ["pad", "halo", "voice", "shimmer", "deep"] },
    ],
  },

  // ⭐ D, DRASTIC #1 — the same music running backwards in shape.
  // Not "quieter": it BEGINS at full Butterworth with the whole arrangement
  // already playing, and spends three and a half minutes going out. Slower, too
  // — 52 BPM against 63 — so the chords last nearly five seconds each.
  // ⚠ It does NOT collapse to nothing: the last section still holds pad, halo
  // and voice and the filter stops at −0.56, because a demo that fades to
  // inaudible is a demo nobody can judge.
  collapse: {
    id: "cosmic-collapse", tempo: 52, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Collapse",
    subtitle: "THE POWER ONE, INVERTED — it falls instead of rising · D minor · 52 BPM · beatless",
    blurb: "The same instrument, the same tune, the opposite shape. It starts where Ascent ends — everything playing, filter wide open — and cools for three and a half minutes, shedding a layer at a time. It reopens once, near the middle, and that recovery does not hold.",
    form: [
      { name: "Arrival",  bars: 8, filt:  0.00, to: -0.08, wob: 1, amp: 0.03, lead: [0],       layers: ["pad", "halo", "voice", "low", "deep"] },
      { name: "Cooling",  bars: 8, filt: -0.08, to: -0.26, wob: 2, amp: 0.05, lead: [],        layers: L.deep },
      { name: "Drift",    bars: 8, filt: -0.26, to: -0.18, wob: 2, amp: 0.07, lead: [0],       layers: ["pad", "halo", "voice", "shimmer", "low"] },
      { name: "Fading",   bars: 8, filt: -0.18, to: -0.42, wob: 2, amp: 0.06, lead: [],        layers: ["pad", "halo", "shimmer"] },
      { name: "Embers",   bars: 8, filt: -0.42, to: -0.34, wob: 1, amp: 0.05, lead: [0],       layers: ["pad", "voice"] },
      { name: "Dark",     bars: 6, filt: -0.34, to: -0.56, wob: 1, amp: 0.03, lead: ["half"],  layers: L.sung },
    ],
  },

  // ⭐ D, DRASTIC #2 — THE PULSED ONE.
  // Everything Ascent has, plus a low impulse on the root. In `Ascent` the pulse
  // DOUBLES (div 2 → 1), which is the one place this piece gets close to having
  // a beat; `Release` drops it entirely so the ending is still a wash.
  heartbeat: {
    id: "cosmic-heartbeat", tempo: 63, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Heartbeat",
    subtitle: "THE POWER ONE, WITH A PULSE · D minor · 63 BPM · ⚠ this one has a pulse",
    blurb: "Ascent with something beating under it — one low impulse every two beats, about one every two seconds, which is a heartbeat rather than a drum. It doubles for the final climb and then stops altogether, so the piece still ends on the wash.",
    form: [
      { name: "Emergence", bars: 6,  filt: -0.72, to: -0.58, wob: 1, amp: 0.03, lead: [],       layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.58, to: -0.40, wob: 1, amp: 0.04, lead: [],       layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.40, to: -0.22, wob: 2, amp: 0.05, lead: [0],      layers: plus(L.sung, "pulse") },
      { name: "Widening",  bars: 8,  filt: -0.22, to: -0.10, wob: 2, amp: 0.06, lead: [0],      layers: plus(L.lit, "pulse") },
      { name: "Depths",    bars: 8,  filt: -0.10, to: -0.44, wob: 2, amp: 0.07, lead: [],       layers: plus(L.deep, "pulse") },
      { name: "Ascent",    bars: 16, filt: -0.44, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],  layers: plus(L.full, "pulse"), pulseDiv: 1 },
      { name: "Release",   bars: 6,  filt:  0.00, to: -0.55, wob: 1, amp: 0.03, lead: ["half"], layers: ["pad", "halo", "voice", "shimmer", "deep"] },
    ],
  },

  // ⭐ B, DRASTIC #1 — the approved version taken somewhere else harmonically.
  // ⚠ 72 BPM AND THAT CHANGES THE SHIMMER'S JOB. The material file's own warning:
  // eighth notes read as WASH at 63 BPM because 0.48 s is far shorter than the
  // release, and the same spacing starts to ARTICULATE as the tempo rises. This
  // piece is one of the beatless three, so its shimmer step is widened to 0.75
  // beats (0.62 s at 72 BPM) to keep it light rather than rhythmic.
  aurora: {
    id: "cosmic-aurora", tempo: 72, power: false, family: "b",
    chords: CHORDS_AURORA, roots: ROOTS_AURORA,
    shimmer: { step: 0.75, per: 5, lengthBeats: 1.3 },
    title: "Starlight · Aurora",
    subtitle: "THE ORIGINAL, OPENED OUT — new harmony, brighter, moves twice as often · 72 BPM · beatless",
    blurb: "The version you approved, moved into a different harmonic world: four chords instead of eight, so it changes twice as often, and not one of them contains a third — every chord is a stack of fifths, which is neither major nor minor. The original sounds sad; this one sounds open.",
    // ⛔⛔ THIS TABLE WAS CORRECTED AFTER THE FIRST RENDER, BY MEASUREMENT.
    // `section-arc.py` failed it on two counts and both were real:
    //   ① `Dawn` measured −40.9 LUFS — under the audibility floor. A single
    //      non-power pad behind a djFilter at −0.66 is nearly nothing, so the
    //      opening now starts at −0.50. It is still the quietest thing here.
    //   ② `Fold` measured −35.3, NINE AND A HALF LU below the section before it.
    //      Cause: Aurora has no low octave and no sub, so its LEVEL is carried
    //      almost entirely by the Voice — taking the voice out to make a "dip"
    //      did not darken the section, it emptied it, and a 9.5 LU hole reads as
    //      the piece breaking rather than as a gesture. `Fold` now keeps the
    //      voice an OCTAVE DOWN (`lead: [-12]`) and drops the halo instead, so
    //      the dip is a change of colour and register, which is what it was for.
    // ⭐ WORTH RECORDING: Aurora's arc is in BRIGHTNESS, not loudness — measured
    // −26.8 dB at Dawn rising to −3.8 dB at Corona, a 23 dB brightening. That is
    // the right shape for this piece; it just means loudness alone never
    // described it, which is exactly why the gate measures both.
    form: [
      { name: "Dawn",     bars: 8,  filt: -0.50, to: -0.40, wob: 1, amp: 0.03, lead: [],       layers: L.bare },
      { name: "Glow",     bars: 8,  filt: -0.40, to: -0.28, wob: 1, amp: 0.04, lead: [],       layers: L.sky },
      { name: "Curtain",  bars: 8,  filt: -0.28, to: -0.16, wob: 2, amp: 0.05, lead: [0],      layers: L.sung },
      { name: "Ribbons",  bars: 8,  filt: -0.16, to: -0.05, wob: 2, amp: 0.06, lead: [0],      layers: L.lit },
      { name: "Fold",     bars: 8,  filt: -0.05, to: -0.32, wob: 2, amp: 0.08, lead: [-12],    layers: ["pad", "voice", "shimmer"] },
      { name: "Corona",   bars: 16, filt: -0.32, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],  layers: L.lit },
      { name: "Settle",   bars: 8,  filt:  0.00, to: -0.44, wob: 1, amp: 0.03, lead: ["half"], layers: L.lit },
    ],
  },

  // ⭐ B, DRASTIC #2 — THE PULSED ONE, and it gets its pulse a different way.
  // Heartbeat adds a layer; Signal turns a layer it ALREADY HAS into the pulse.
  // The shimmer's step drops to 0.25 beats and its release is cut, so the same
  // notes that read as light in version b read as sixteenths here — which is
  // precisely the tempo-coupling the material file warns about, used on purpose.
  // A mid-register impulse sits under it. `Release` drops both.
  signal: {
    id: "cosmic-signal", tempo: 66, power: false, family: "b",
    chords: CHORDS_DM, roots: ROOTS_DM,
    shimmer: { step: 0.25, per: 16, lengthBeats: 0.42, baseVel: 46, accent: 12 },
    pulse: { octave: 12, velocity: 64 },
    title: "Starlight · Signal",
    subtitle: "THE ORIGINAL, WITH A PULSE — the shimmer turned into one · D minor · 66 BPM · ⚠ this one has a pulse",
    blurb: "The same shimmer as the version you approved, but tightened until it articulates instead of blurring — the notes were always there, they just stop overlapping. A soft impulse sits underneath. It fades back to a wash for the ending.",
    // ⛔⛔ CORRECTED AFTER MEASUREMENT, THE SAME TWO FAULTS AS AURORA AND FOR THE
    // SAME REASON — both are B-family, so neither has a low octave or a sub, and
    // in both the VOICE turned out to be carrying the level:
    //   ① `Emergence` measured −41.0 LUFS, under the audibility floor.
    //   ② `Depths` measured −34.9, EIGHT AND A HALF LU below the section before
    //      it, because taking the voice away to make a dip emptied it instead of
    //      darkening it. It now keeps the voice an octave down and drops the
    //      halo, so the dip is colour and register rather than a hole.
    // ⭐ The D-family pieces did NOT have this fault: their `Depths` ADDS a low
    // octave and a sub in the same bar, which is exactly what fills the gap the
    // departing voice leaves. Same form table, opposite outcome — which is why
    // the gate measures the render and not the intention.
    form: [
      { name: "Emergence", bars: 6,  filt: -0.50, to: -0.42, wob: 1, amp: 0.03, lead: [],       layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.42, to: -0.32, wob: 1, amp: 0.04, lead: [],       layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.32, to: -0.20, wob: 2, amp: 0.05, lead: [0],      layers: L.sung },
      { name: "Signal",    bars: 8,  filt: -0.20, to: -0.08, wob: 2, amp: 0.06, lead: [0],      layers: plus(L.lit, "pulse") },
      { name: "Depths",    bars: 8,  filt: -0.08, to: -0.34, wob: 2, amp: 0.07, lead: [-12],    layers: ["pad", "voice", "shimmer", "pulse"] },
      { name: "Ascent",    bars: 16, filt: -0.34, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],  layers: plus(L.lit, "pulse") },
      { name: "Release",   bars: 6,  filt:  0.00, to: -0.44, wob: 1, amp: 0.03, lead: ["half"], layers: L.sung },
    ],
  },

  // ==================================================================== 5 MIN
  // ⭐⭐ THE FIVE-MINUTE CUTS, USER-ASKED 2026-09-21: "I also liked 5 mins
  // versions, do them and upload". The 5-minute thing they had heard is
  // `cosmic-b-long`/`cosmic-d-long` — 80 bars, 5:05 — so that is the length.
  //
  // ⛔⛔ LENGTH IS NOT A BAR MULTIPLIER. Scaling 58 bars to 80 at the same seven
  // sections does not make a five-minute piece, it makes the same piece played
  // more slowly — every section gets longer and NOTHING NEW HAPPENS. That is
  // padding, and it is exactly what `cosmic.mjs` already refuses: "the long form
  // earns its length by GOING SOMEWHERE, not by repeating."
  //
  // ⭐ SO EACH OF THESE ADDS A SECOND WAVE, which is the shape the user already
  // approved in the B/D long forms: after the first climax the music pulls back
  // FURTHER than its first dip went, returns an octave up, and spends its longest
  // section on one unbroken climb. Three and a half minutes supports one
  // fluctuation; five supports two, and the second is bigger than the first.
  //
  // ⚠ BARS ARE COMPUTED PER TEMPO, NEVER COPIED. 80 bars is 5:05 at 63 BPM, 6:09
  // at 52 and 4:27 at 72 — the same number would have produced three different
  // lengths. bars = round(305 × tempo ÷ 240).
  //
  // ⛔ B-FAMILY DIPS KEEP THE VOICE. `aurora5`/`signal5` have no low octave and
  // no sub, so the voice carries their level; both second dips use the same
  // `lead: [-12]` + drop-the-halo shape that fixed the measured 9.5 LU hole in
  // the 3½-minute versions, rather than the D-family "drop the voice" dip.
  ascent5: {
    id: "cosmic-ascent-5m", tempo: 63, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Ascent · long",
    subtitle: "THE POWER ONE, TWICE OVER — five minutes, two climbs · D minor · 63 BPM · beatless",
    blurb: "Ascent given room to do it twice. The first climb stops well short of the top, then falls further than the piece has been since its opening bar — two synths left, filter almost shut — before the theme returns an octave above itself for a sixteen-bar climb that is the only place it ever reaches full open. Five minutes, and the second half is the reason for them.",
    form: [
      { name: "Emergence", bars: 6,  filt: -0.72, to: -0.60, wob: 1, amp: 0.03, lead: [],        layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.60, to: -0.46, wob: 1, amp: 0.04, lead: [],        layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.46, to: -0.34, wob: 2, amp: 0.05, lead: [0],       layers: L.sung },
      { name: "Widening",  bars: 8,  filt: -0.34, to: -0.26, wob: 2, amp: 0.06, lead: [0],       layers: L.lit },
      { name: "Depths",    bars: 8,  filt: -0.26, to: -0.50, wob: 2, amp: 0.07, lead: [],        layers: L.deep },
      { name: "Ascent",    bars: 8,  filt: -0.50, to: -0.14, wob: 3, amp: 0.05, lead: [0],       layers: ["pad", "halo", "voice", "shimmer", "low"] },
      { name: "Drift",     bars: 8,  filt: -0.14, to: -0.64, wob: 2, amp: 0.06, lead: [],        layers: L.sky },
      { name: "Return",    bars: 8,  filt: -0.64, to: -0.30, wob: 2, amp: 0.05, lead: [12],      layers: L.sung },
      { name: "Summit",    bars: 16, filt: -0.30, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],   layers: L.full },
      { name: "Release",   bars: 4,  filt:  0.00, to: -0.55, wob: 1, amp: 0.03, lead: ["half"],  layers: ["pad", "halo", "voice", "shimmer", "deep"] },
    ],
  },

  // ⭐ The inverted one, given a second false recovery. `Rekindle` climbs higher
  // than `Drift` did and brings the theme back an octave up — and it still does
  // not hold. Same refusal to end inaudible: `Dark` stops at −0.58 with pad, halo
  // and voice still sounding.
  collapse5: {
    id: "cosmic-collapse-5m", tempo: 52, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Collapse · long",
    subtitle: "THE INVERTED ONE, TWICE OVER — five minutes, two false recoveries · D minor · 52 BPM · beatless",
    blurb: "Collapse with a second chance it does not take. It starts wide open and cools, recovers a little, cools further — and then reopens properly, theme an octave up, brighter than anything since the first minute. That is the last time. The last eighty seconds shed layer after layer and stop just short of silence.",
    form: [
      { name: "Arrival",   bars: 8,  filt:  0.00, to: -0.08, wob: 1, amp: 0.03, lead: [0],       layers: ["pad", "halo", "voice", "low", "deep"] },
      { name: "Cooling",   bars: 8,  filt: -0.08, to: -0.26, wob: 2, amp: 0.05, lead: [],        layers: L.deep },
      { name: "Drift",     bars: 8,  filt: -0.26, to: -0.18, wob: 2, amp: 0.07, lead: [0],       layers: ["pad", "halo", "voice", "shimmer", "low"] },
      { name: "Fading",    bars: 8,  filt: -0.18, to: -0.42, wob: 2, amp: 0.06, lead: [],        layers: ["pad", "halo", "shimmer"] },
      { name: "Embers",    bars: 8,  filt: -0.42, to: -0.30, wob: 1, amp: 0.05, lead: [0],       layers: ["pad", "voice"] },
      { name: "Rekindle",  bars: 8,  filt: -0.30, to: -0.10, wob: 2, amp: 0.06, lead: [0, 12],   layers: ["pad", "halo", "voice", "shimmer", "low"] },
      { name: "Guttering", bars: 8,  filt: -0.10, to: -0.46, wob: 2, amp: 0.06, lead: [],        layers: ["pad", "halo", "shimmer"] },
      { name: "Dark",      bars: 10, filt: -0.46, to: -0.58, wob: 1, amp: 0.03, lead: ["half"],  layers: L.sung },
    ],
  },

  // ⭐ The pulsed D, and the pulse gets a form of its own: present from `Theme`,
  // ABSENT through the deep pullback at `Drift` — so the piece goes fully
  // beatless in its quietest minute — back for `Return`, doubled for `Summit`,
  // and gone again by `Release`. The pulse arrives, leaves and returns rather
  // than simply running underneath for five minutes.
  heartbeat5: {
    id: "cosmic-heartbeat-5m", tempo: 63, power: true, family: "d",
    chords: CHORDS_DM, roots: ROOTS_DM,
    title: "Starlight · Heartbeat · long",
    subtitle: "THE PULSED ONE, TWICE OVER — the pulse stops and comes back · D minor · 63 BPM · ⚠ this one has a pulse",
    blurb: "The five-minute Ascent with the heartbeat under it — and this time the heartbeat has a shape too. It stops completely for the deep middle — thirty seconds with no pulse at all — returns with the theme an octave up, and doubles for the last climb before stopping for good.",
    form: [
      { name: "Emergence", bars: 6,  filt: -0.72, to: -0.60, wob: 1, amp: 0.03, lead: [],        layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.60, to: -0.46, wob: 1, amp: 0.04, lead: [],        layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.46, to: -0.34, wob: 2, amp: 0.05, lead: [0],       layers: plus(L.sung, "pulse") },
      { name: "Widening",  bars: 8,  filt: -0.34, to: -0.26, wob: 2, amp: 0.06, lead: [0],       layers: plus(L.lit, "pulse") },
      { name: "Depths",    bars: 8,  filt: -0.26, to: -0.50, wob: 2, amp: 0.07, lead: [],        layers: plus(L.deep, "pulse") },
      { name: "Ascent",    bars: 8,  filt: -0.50, to: -0.14, wob: 3, amp: 0.05, lead: [0],       layers: ["pad", "halo", "voice", "shimmer", "low", "pulse"] },
      { name: "Drift",     bars: 8,  filt: -0.14, to: -0.64, wob: 2, amp: 0.06, lead: [],        layers: L.sky },
      { name: "Return",    bars: 8,  filt: -0.64, to: -0.30, wob: 2, amp: 0.05, lead: [12],      layers: plus(L.sung, "pulse") },
      { name: "Summit",    bars: 16, filt: -0.30, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12],   layers: plus(L.full, "pulse"), pulseDiv: 1 },
      { name: "Release",   bars: 4,  filt:  0.00, to: -0.55, wob: 1, amp: 0.03, lead: ["half"],  layers: ["pad", "halo", "voice", "shimmer", "deep"] },
    ],
  },

  // ⭐ B-family. 92 bars at 72 BPM = 5:07. `Veil` is the second dip and it uses
  // the SAME shape as `Fold` — voice an octave down, halo dropped — because this
  // piece has no low register to fall back on.
  aurora5: {
    id: "cosmic-aurora-5m", tempo: 72, power: false, family: "b",
    chords: CHORDS_AURORA, roots: ROOTS_AURORA,
    shimmer: { step: 0.75, per: 5, lengthBeats: 1.3 },
    title: "Starlight · Aurora · long",
    subtitle: "THE OPEN ONE, TWICE OVER — five minutes, two curtains · 72 BPM · beatless",
    blurb: "The fifths-only harmony given five minutes to move through twice. It brightens, folds back into a low unison, opens much further than before, and then folds a second time, lower than the first, before a twenty-four-bar rise takes it all the way up. Still no thirds anywhere in it, so it never resolves to happy or sad.",
    form: [
      { name: "Dawn",    bars: 8,  filt: -0.62, to: -0.54, wob: 1, amp: 0.03, lead: [],           layers: L.bare },
      { name: "Glow",    bars: 8,  filt: -0.54, to: -0.46, wob: 1, amp: 0.04, lead: [],           layers: L.sky },
      { name: "Curtain", bars: 8,  filt: -0.46, to: -0.38, wob: 2, amp: 0.05, lead: [0],          layers: L.sung },
      { name: "Ribbons", bars: 8,  filt: -0.38, to: -0.30, wob: 2, amp: 0.06, lead: [0],          layers: L.sung },
      { name: "Fold",    bars: 8,  filt: -0.30, to: -0.56, wob: 2, amp: 0.08, lead: [-12],        layers: ["pad", "voice"] },
      { name: "Corona",  bars: 12, filt: -0.56, to: -0.24, wob: 3, amp: 0.05, lead: [0],          layers: L.lit },
      { name: "Veil",    bars: 8,  filt: -0.24, to: -0.60, wob: 2, amp: 0.08, lead: [-12],        layers: ["pad", "voice"] },
      { name: "Aurora",  bars: 24, filt: -0.60, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12, 12],  layers: L.lit },
      { name: "Settle",  bars: 8,  filt:  0.00, to: -0.50, wob: 1, amp: 0.03, lead: ["half"],     layers: L.lit },
    ],
  },

  // ⭐ B-family, pulsed. `Silence` is the second dip AND the section where the
  // pulse drops out entirely — the shimmer goes back to being a wash for eight
  // bars — then `Return` brings it back doubled for the longest climb in any of
  // these five. `Silence` keeps the voice an octave down for the same reason
  // `Depths` does.
  signal5: {
    id: "cosmic-signal-5m", tempo: 66, power: false, family: "b",
    chords: CHORDS_DM, roots: ROOTS_DM,
    shimmer: { step: 0.25, per: 16, lengthBeats: 0.42, baseVel: 46, accent: 12 },
    pulse: { octave: 12, velocity: 64 },
    title: "Starlight · Signal · long",
    subtitle: "THE PULSED ORIGINAL, TWICE OVER — the pulse stops dead in the middle · D minor · 66 BPM · ⚠ this one has a pulse",
    blurb: "Five minutes of the tightened shimmer, with a hole cut in the middle of it. Eight bars where the pulse simply stops and the same notes go back to being a wash — then it returns at double speed for a twenty-four-bar climb — at this tempo, the longest unbroken rise in any of these. It ends as a wash again.",
    form: [
      { name: "Emergence", bars: 6,  filt: -0.50, to: -0.44, wob: 1, amp: 0.03, lead: [],          layers: L.bare },
      { name: "Light",     bars: 6,  filt: -0.44, to: -0.36, wob: 1, amp: 0.04, lead: [],          layers: L.sky },
      { name: "Theme",     bars: 8,  filt: -0.36, to: -0.26, wob: 2, amp: 0.05, lead: [0],         layers: L.sung },
      { name: "Signal",    bars: 8,  filt: -0.26, to: -0.18, wob: 2, amp: 0.06, lead: [0],         layers: plus(L.lit, "pulse") },
      { name: "Depths",    bars: 8,  filt: -0.18, to: -0.42, wob: 2, amp: 0.07, lead: [-12],       layers: ["pad", "voice", "shimmer", "pulse"] },
      { name: "Ascent",    bars: 8,  filt: -0.42, to: -0.20, wob: 3, amp: 0.05, lead: [0],         layers: plus(L.lit, "pulse") },
      { name: "Silence",   bars: 8,  filt: -0.20, to: -0.50, wob: 2, amp: 0.07, lead: [-12],       layers: ["pad", "voice", "shimmer"] },
      { name: "Return",    bars: 24, filt: -0.50, to:  0.00, wob: 3, amp: 0.05, lead: [0, 12, 12], layers: plus(L.lit, "pulse"), pulseDiv: 1 },
      { name: "Release",   bars: 8,  filt:  0.00, to: -0.44, wob: 1, amp: 0.03, lead: ["half"],    layers: L.sung },
    ],
  },
};

const P = PIECES[WHICH];
if (!P) {
  console.error(`usage: node develop.mjs <${Object.keys(PIECES).join("|")}>`);
  process.exit(2);
}

// ⛔⛔ EVERY SECTION MUST START WHERE THE LAST ONE ENDED, AND THIS IS CHECKED
// BECAUSE IT SILENTLY BROKE. Editing a form means touching two numbers — the
// `to` of one row and the `filt` of the next — and on 2026-09-21 a pass over
// `ascent5` changed `Drift.to` to -0.62 and left `Return.filt` at -0.58. The
// sweep generator takes each section's own filt→to, so the result was a 0.04
// STEP in the filter at that bar: nothing errored, the render succeeded, and the
// only symptom would have been a small click in the middle of the quietest
// moment in the piece. It was caught by eye while reading the table for an
// unrelated reason, which is not a method.
P.form.forEach((s, i) => {
  if (i === 0) return;
  const prev = P.form[i - 1];
  if (Math.abs(s.filt - prev.to) > 1e-9) {
    console.error(`⛔ ${P.id}: SWEEP DISCONTINUITY — "${prev.name}" ends at ${prev.to} `
      + `but "${s.name}" starts at ${s.filt}. Thread filt = the previous section's to.`);
    process.exit(3);
  }
});

let _bar = 0;
const SECTIONS = P.form.map((s) => ({ ...s, bar: (_bar += s.bars) - s.bars }));
const BARS = _bar;
const has = (s, layer) => s.layers.includes(layer);
const uses = (layer) => SECTIONS.some((s) => has(s, layer));
const SECONDS = (BARS * 4 / P.tempo) * 60;

// ⭐ THE UNDULATING SWEEP. Each section travels filt→to across its own length
// and carries `wob` cycles of a ±`amp` ripple on top. The ripple is zero at both
// ends of a section by construction (sin of a whole number of cycles), so
// sections still join exactly at their stated values and the travel is what the
// form table says it is — the fluctuation rides the arc, it does not replace it.
//
// ⚠ BUILT UP HERE, BEFORE THE SOCKET OPENS, BECAUSE IT IS PURE DATA. That is
// what lets `--dry` print the entire plan — form, layer gate and sweep — without
// touching the app, so a form-table mistake is caught in a tenth of a second
// instead of after a four-minute render.
const clamp = (v) => Math.max(-0.95, Math.min(0.0, v));
const ease = (u) => u * u * (3 - 2 * u);      // smoothstep: no corner at the joins
const SWEEP = [];
SECTIONS.forEach((s) => {
  const start = s.bar * 4, len = s.bars * 4;
  const steps = Math.max(4, s.wob * 6);
  for (let k = 0; k < steps; k++) {
    const u = k / steps;
    const base = s.filt + (s.to - s.filt) * ease(u);
    const ripple = s.amp * Math.sin(u * Math.PI * 2 * s.wob);
    SWEEP.push({ beat: +(start + u * len).toFixed(4), value: +clamp(base + ripple).toFixed(4) });
  }
});
// The final point, emitted once outside the loop — sections deliberately stop
// one step short of their own end so no two points ever share a beat.
SWEEP.push({ beat: BARS * 4 - 1, value: +clamp(SECTIONS[SECTIONS.length - 1].to).toFixed(4) });

console.log(`${P.id}: ${BARS} bars @ ${P.tempo} BPM = ${(SECONDS / 60).toFixed(2)} min  (${Math.floor(SECONDS / 60)}:${String(Math.round(SECONDS % 60)).padStart(2, "0")})`);
for (const s of SECTIONS) {
  const notes = {
    pad: () => padNotes(P.chords, s.bar, s.bars).length,
    halo: () => padNotes(P.chords, s.bar, s.bars, { octave: 12 }).length,
    low: () => padNotes(P.chords, s.bar, s.bars, { octave: -12 }).length,
    shimmer: () => shimmerNotes(P.chords, s.bar, s.bars, P.shimmer || {}).length,
    deep: () => bassNotes(P.roots, s.bar, s.bars).length,
    pulse: () => pulseNotes(P.roots, s.bar, s.bars, { div: s.pulseDiv ?? 2, ...(P.pulse || {}) }).length,
    voice: () => leadNotes(THEME, s.lead, s.bars).length,
  };
  const played = s.layers.filter((l) => notes[l]().length !== 0 || true).map((l) => `${l}:${notes[l]()}`);
  console.log(`  bar ${String(s.bar).padStart(3)}  ${s.name.padEnd(10)} ${String(s.bars).padStart(2)}b  ` +
              `filt ${s.filt.toFixed(2)}→${s.to.toFixed(2)} ±${s.amp.toFixed(2)}×${s.wob}  ` +
              `${String(s.layers.length).padStart(2)} layers  ${played.join(" ")}`);
}
{
  const vals = SWEEP.map((p) => p.value);
  const beats = SWEEP.map((p) => p.beat);
  const dupes = beats.length - new Set(beats).size;
  console.log(`sweep: ${SWEEP.length} points, ${Math.min(...vals).toFixed(2)} … ${Math.max(...vals).toFixed(2)}, ` +
              `duplicate beats ${dupes}, monotonic ${beats.every((b, i) => i === 0 || b > beats[i - 1]) ? "yes" : "NO"}`);
  if (dupes) { console.error("⛔ duplicate automation beats — refusing"); process.exit(1); }
}
if (process.argv.includes("--dry")) process.exit(0);

// -------------------------------------------------------------------- build
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: P.tempo });
for (const s of SECTIONS) await cmd("marker.add", { name: s.name, beat: s.bar * 4 });

const mixBus = await addBus("Mix Bus");
const POWER = P.power;

// Clip a track into exactly the sections that name it. This is the layer gate;
// everything about "simple to complex" is this function plus the form table.
const layerClips = async (trackId, layer, notesFor, label) => {
  let n = 0;
  for (const s of SECTIONS) {
    if (!has(s, layer)) continue;
    const notes = notesFor(s);
    if (!notes.length) continue;
    await addClip(trackId, s.bar * 4, s.bars * 4, notes, `${label} ${s.name}`);
    n += notes.length;
  }
  return n;
};

const counts = {};
const padT = await addTrack("Strings", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 7, unisonDetuneCents: 26, unisonStereoSpread: 1.0,
  cutoffHz: POWER ? 3200 : 2300, resonance: 0.2, keyToCutoff: 0.4,
  drift: 0.5, voiceJitter: 0.34, noiseLevel: 0.03, noiseColor: 0.22,
  drive: POWER ? 0.3 : 0,
  attack: 1.5, decay: 1.2, sustain: 0.9, release: 3.2, gain: POWER ? 0.6 : 0.5,
}, { volume: POWER ? 0.78 : 0.7, pan: -0.08, busId: mixBus });
counts.pad = await layerClips(padT, "pad", (s) => padNotes(P.chords, s.bar, s.bars), "Strings");

const haloT = await addTrack("Halo", {
  kind: "polySynth", waveform: "triangle",
  unisonVoices: 5, unisonDetuneCents: 18, unisonStereoSpread: 0.9,
  cutoffHz: 4200, resonance: 0.16, drift: 0.4, voiceJitter: 0.3,
  attack: 2.2, decay: 1.5, sustain: 0.85, release: 4.0, gain: 0.3,
}, { volume: 0.44, pan: 0.14, busId: mixBus });
counts.halo = await layerClips(haloT, "halo",
  (s) => padNotes(P.chords, s.bar, s.bars, { octave: 12, velocity: 46 }), "Halo");

let lowT = null;
if (uses("low")) {
  lowT = await addTrack("Low Strings", {
    kind: "polySynth", waveform: "saw",
    unisonVoices: 5, unisonDetuneCents: 14, unisonStereoSpread: 0.35,
    subLevel: 0.3, subOctave: -1, subWaveform: "sine",
    cutoffHz: 1400, resonance: 0.14, drift: 0.3, voiceJitter: 0.2, drive: 0.35,
    attack: 1.2, decay: 1.4, sustain: 0.9, release: 3.0, gain: 0.55,
  }, { volume: 0.62, pan: 0.02, busId: mixBus });
  counts.low = await layerClips(lowT, "low",
    (s) => padNotes(P.chords, s.bar, s.bars, { octave: -12, velocity: 62 }), "Low");
}

let shimmerT = null;
if (uses("shimmer")) {
  const SH = P.shimmer || {};
  shimmerT = await addTrack("Shimmer", {
    kind: "polySynth", waveform: "triangle",
    unisonVoices: 3, unisonDetuneCents: 12, unisonStereoSpread: 0.8,
    cutoffHz: 5200, resonance: 0.18, keyToCutoff: 0.5, velocityToCutoff: 0.3,
    drift: 0.2, voiceJitter: 0.2,
    // ⚠ A SHORTER RELEASE IS WHAT MAKES THE PULSED VERSION ARTICULATE. With a
    // 1.4 s release the sixteenths would simply blur back into a wash and
    // "Signal" would be indistinguishable from "b, faster".
    attack: 0.04, decay: 0.9, sustain: 0.25,
    release: SH.step && SH.step <= 0.3 ? 0.45 : 1.4,
    gain: 0.3,
  }, { volume: SH.step && SH.step <= 0.3 ? 0.32 : 0.36, pan: 0.2, busId: mixBus });
  counts.shimmer = await layerClips(shimmerT, "shimmer",
    (s) => shimmerNotes(P.chords, s.bar, s.bars, SH), "Shimmer");
}

let bassT = null;
if (uses("deep")) {
  bassT = await addTrack("Deep", {
    kind: "polySynth", waveform: "sine",
    subLevel: POWER ? 0.8 : 0.6, subOctave: -1, subWaveform: "sine",
    cutoffHz: 420, resonance: 0.1, drive: POWER ? 0.25 : 0,
    attack: 0.8, decay: 1.0, sustain: 0.85, release: 2.4, gain: POWER ? 0.85 : 0.7,
  }, { volume: POWER ? 0.72 : 0.6, busId: mixBus });
  counts.deep = await layerClips(bassT, "deep",
    (s) => bassNotes(P.roots, s.bar, s.bars, POWER ? 76 : 64), "Deep");
}

// ⚠ PULSE — only on the two pieces that asked for one. Short attack, no
// sustain: it is an impulse, so the sound is the envelope, not the note.
let pulseT = null;
if (uses("pulse")) {
  const PU = P.pulse || {};
  pulseT = await addTrack("Pulse", {
    kind: "polySynth", waveform: "sine",
    subLevel: PU.octave ? 0.25 : 0.7, subOctave: -1, subWaveform: "sine",
    cutoffHz: PU.octave ? 900 : 260, resonance: 0.12, drive: 0.2,
    attack: 0.012, decay: 0.55, sustain: 0.0, release: 0.85, gain: 0.7,
  }, { volume: 0.6, busId: mixBus });
  counts.pulse = await layerClips(pulseT, "pulse",
    (s) => pulseNotes(P.roots, s.bar, s.bars, { div: s.pulseDiv ?? 2, ...PU }), "Pulse");
}

const leadT = await addTrack("Voice", {
  kind: "polySynth", waveform: "square",
  unisonVoices: 3, unisonDetuneCents: 11, unisonStereoSpread: 0.55,
  subLevel: 0.18, subOctave: -1, subWaveform: "sine",
  cutoffHz: 1450, resonance: 0.78, resonanceBoost: 0.62,
  keyToCutoff: 0.9, velocityToCutoff: 0.4,
  drive: 0.16, drift: 0.28, voiceJitter: 0.12, envelopeCurve: 0.55,
  attack: 0.35, decay: 1.2, sustain: 0.7, release: 2.6, gain: 0.46,
}, { volume: 0.68, pan: 0.05, busId: mixBus });
counts.voice = await layerClips(leadT, "voice",
  (s) => leadNotes(THEME, s.lead, s.bars), "Voice");

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
  fx.lowSat  = await addFx(lowT, "saturator", { driveDb: 5, mix: 0.45 });
}
if (pulseT) {
  // ⚠ A SHORT, SMALL ROOM, NOT THE HALL. Every other layer sits in a 40-metre
  // hall with a 6-second tail; put an impulse in that and its decay smears over
  // the next two impulses until the pulse stops reading as a pulse at all.
  fx.pulseVerb = await addFx(pulseT, "hallReverb", { mix: 0.18, decaySeconds: 1.8, sizeMeters: 14, preDelayMs: 10 });
}

// ⛔ THE SWEEP IS ON THE STRINGS, NOT THE BUS — a measured decision carried over
// from cosmic.mjs: on the bus at high resonance the djFilter has a cliff either
// side of zero (position −0.08 measured −41.5 LUFS against −31.9 at 0.0), and a
// mix with no drums has no floor to survive that.
fx.padFilter = await addFx(padT, "djFilter", {
  position: SECTIONS[0].filt,
  resonance: POWER ? 0.0 : 0.55,
});

fx.sweepLane = await automate(padT, fx.padFilter, "position", SWEEP);

fx.masterLimiter = await addFx("master", "limiter", { ceilingDb: -1.0, truePeak: 1, releaseMs: 80 });

// ⭐ THE BREATH — a slow LFO on the voice's own cutoff; the synth has no vibrato.
// ⚠ Depth lives on the ROUTE, not the source, and the target key is `param`.
// Not wrapped in a silent catch: if modulation refuses, the piece still renders
// and the failure is VISIBLE.
let breath = null;
try {
  const src = await cmd("mod.addSource", {
    trackId: leadT, kind: "lfo", name: "Breath",
    params: { waveform: "sine", rateHz: 0.13, bipolar: true },
  });
  const srcId = src.sourceId || src.id;
  const route = await cmd("mod.addRoute", {
    trackId: leadT, sourceId: srcId,
    target: { type: "instrumentParam", param: "cutoffHz" },
    depth: 0.22,
  });
  breath = { srcId, routeId: route.routeId || route.id };
  console.log(`breath LFO: source=${srcId} route=${breath.routeId}`);
} catch (e) {
  console.error(`⚠ BREATH LFO NOT APPLIED — ${String(e.message || e).slice(0, 300)}`);
}

// --------------------------------------------------------------------- render
const outDir = `${DIR}/out/${P.id}`;
const wav = path.resolve(`${outDir}/${P.id}.wav`);
fs.mkdirSync(outDir, { recursive: true });
// +10 s of tail: the halo releases over 4 s into a hall that decays for 7.5.
await cmd("render.mixdown", { path: wav, durationSeconds: Math.ceil(SECONDS) + 10 });

// ⛔⛔ THE CARD MUST NAME THE VERSION AND SAY WHICH TRACK IT CAME FROM. All four
// earlier versions shipped with identical captions under a request to "tell me a
// letter" — a listener cannot report a preference they have no way to name.
fs.writeFileSync(`${outDir}/build.json`, JSON.stringify({
  variant: P.id, title: P.title, subtitle: P.subtitle, blurb: P.blurb,
  // ⛔ FAMILY COMES FROM THE PIECE, NOT FROM THE ARGV KEY. It used to read
  // `WHICH === "aurora" || WHICH === "signal" ? "b" : "d"`, which was correct for
  // exactly the five keys that existed when it was written and silently wrong for
  // the sixth: adding `aurora5` would have labelled a B-family piece "d" in
  // build.json, on the review page and in its YouTube metadata, with nothing
  // failing. The family decides which audibility trap applies (B-family has no
  // low octave, so the VOICE carries the level) — it is not cosmetic.
  family: P.family,
  pulsed: uses("pulse"), power: POWER,
  tempo: P.tempo, bars: BARS, seconds: +SECONDS.toFixed(1),
  sections: SECTIONS, sweep: SWEEP, noteCounts: counts,
  chords: P.chords, roots: P.roots,
  tracks: { pad: padT, halo: haloT, low: lowT, shimmer: shimmerT, bass: bassT, pulse: pulseT, lead: leadT, mixBus },
  fx, breath, wav, at: new Date().toISOString(),
}, null, 2));

console.log(`notes: ${Object.entries(counts).map(([k, v]) => `${k}=${v}`).join(" ")}`);
console.log(`wrote ${wav}`);
await close();
// ⛔ EXPLICIT EXIT, AND IT IS NOT BELT-AND-BRACES. `close()` closes the socket
// but something in the client keeps the loop alive, so the process sits there
// forever AFTER the wav and build.json are both safely on disk. The first run of
// `ascent` looked like a render that had hung for eleven minutes when in fact it
// had finished — and a driver script running five of these in sequence would
// have stopped dead after the first one, with nothing to show why.
process.exit(0);
