#!/usr/bin/env node
// COSMIC FORCES — three energies that take turns. Three pieces, ~5:05 each.
//
//   node forces.mjs forces|apart|converge   [--dry]
//
// ⭐ THE BRIEF, IN THE USER'S OWN WORDS (2026-09-22):
//   "Can you now build a composition similar to starlight, but where multiple
//    energies (3 main powerful, different tones) emerge at different point of
//    time and go full force and then oen subsides and another emerges, they
//    should represent cosmic forces, knowledge, stardust, consiousness"
//
// "cosmic forces" is the umbrella. The three energies are STARDUST, KNOWLEDGE
// and CONSCIOUSNESS, and the sentence names four requirements, all of them
// measurable — which is the point, because "it feels like three forces" is not
// something a gate can check:
//
//   ① THREE DIFFERENT TONES ...... each force owns a frequency band, and the
//                                  three bands are ordered high / mid / low.
//   ② EMERGE AT DIFFERENT TIMES .. each force's first bar is its own.
//   ③ GO FULL FORCE .............. each force's share of the spectrum PEAKS in
//                                  its own named section, not anywhere else.
//   ④ ONE SUBSIDES, ANOTHER ...... across a handover, the outgoing force's
//      EMERGES                     share falls while the incoming one's rises.
//
// `forces-gate.py` checks all four against the render. It is written to FAIL on
// a deliberately flat control, and it runs that control every time — because the
// gate that cannot fail is the one this pipeline keeps producing.
//
// ---------------------------------------------------------------------------
// ⭐⭐ "SIMILAR TO STARLIGHT" IS THE OTHER HALF OF THE BRIEF, AND IT IS A
// CONSTRAINT, NOT A GARNISH. Same harmony (D aeolian, the same eight-bar cycle),
// same vocalise, same hall, same 63 BPM, and BEATLESS — the standing rule from
// `cosmic.mjs` that this music has no pulse at all. The one scoped exception the
// user granted (a pulse on two of the five developed pieces) was spent in
// `develop.mjs`; nothing here has one. Three forces do not mean three harmonies.
// They mean three ways of VOICING one, which is also why an eight-bar chord
// period survives and `make-loop.py` still works on the result.
//
// ⭐⭐ HOW A FORCE IS BUILT — THREE LAYERS AND A FILTER OF ITS OWN.
//
//   STARDUST      veil · dust · glint      above the stave, struck, granular
//   KNOWLEDGE     lattice · mind · trace   mid, ordered, it speaks
//   CONSCIOUSNESS aware · vast · abyss     below, slow, enveloping
//
// Each force's PAD is its anchor and carries that force's own djFilter, whose
// arc is the force's life: it opens as the force emerges, sits wide open where
// the force is at full force, and closes as the force subsides. So "goes full
// force and then subsides" is not just more tracks — it is audibly brighter and
// then audibly darker, on that force alone, while the others are doing something
// else entirely. That is three simultaneous filter sweeps where `develop.mjs`
// had one, and it is the mechanism the brief actually asks for.
//
// ⛔ AN ANCHOR MUST PLAY IN EVERY SECTION OF ITS OWN ARC, AND THIS IS CHECKED.
// A filter automating a track that has no clip in that section is an automation
// lane moving in silence: the render succeeds, the build.json looks right, and
// the force simply does not fade. Checked below, with the reason, because it is
// exactly the class of failure that passes every other gate here.
//
// ---------------------------------------------------------------------------
// ⭐ THE THREE PIECES DIFFER ON ONE AXIS: HOW MUCH THE FORCES COEXIST.
// The user is not a musician and their pick IS the feedback, so the three must
// differ in a way that can be described without naming an instrument:
//
//   apart     they never overlap — each force finishes before the next begins
//   forces    they overlap at the seam — one is still going as the next arrives
//   converge  they accumulate — nothing leaves, and all three end together
//
// `forces` is the canonical one because it is what the sentence literally
// describes ("one subsides AND another emerges"); the other two bracket it.
import {
  CHORDS_DM, ROOTS_DM, THEME,
  padNotes, shimmerNotes, bassNotes, leadNotes,
} from "./cosmic-material.mjs";
import { glintNotes, latticeNotes, canonNotes } from "./forces-material.mjs";
import fs from "node:fs";
import path from "node:path";

// ⛔⛔ SAME REASON AS `develop.mjs`: `dawctl.mjs` reads DAW_TIMEOUT_MS ONCE at
// module load and defaults to 30 s, and a static import is HOISTED above this
// assignment. These are five-minute pieces with nine tracks — longer than the
// five-minute Starlight forms, which already took ~9-10 min quiescent — so the
// dynamic import is what makes the value below arrive in time to matter.
process.env.DAW_TIMEOUT_MS ||= "1800000";
const { open, close, cmd, addTrack, addBus, addClip, addFx, automate } =
  await import("./arrange.mjs");

const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const WHICH = (process.argv[2] || "").toLowerCase();

// ------------------------------------------------------------------- forces
// `band` is the frequency range that force OWNS, and it is what `forces-gate.py`
// measures. The three are disjoint and ordered, which is requirement ① made
// literal — if two forces shared a band the gate could not tell them apart, and
// neither could a listener.
const FORCES = {
  stardust:      { label: "Stardust",      anchor: "veil",    layers: ["veil", "dust", "glint"],    band: [800, 9000] },
  knowledge:     { label: "Knowledge",     anchor: "lattice", layers: ["lattice", "mind", "trace"], band: [240, 800] },
  consciousness: { label: "Consciousness", anchor: "aware",   layers: ["aware", "vast", "abyss"],   band: [25, 240] },
};
const FKEYS = Object.keys(FORCES);
const LAYER_FORCE = Object.fromEntries(
  FKEYS.flatMap((f) => FORCES[f].layers.map((l) => [l, f])));

// An arc entry is [from, to, wobbles, amplitude] — the same undulating-sweep
// shape `develop.mjs` proved, one per force per section instead of one per
// section. A force with no entry in a row is not sounding its anchor there.
const PIECES = {
  // ⭐ THE CANONICAL ONE. Each handover is a section where BOTH forces are at
  // two of their three layers — they cross at equal strength, which is the
  // "subsides as another emerges" of the brief taken at its word.
  forces: {
    id: "cosmic-forces", tempo: 63, coexist: "overlapping",
    title: "Stardust, Knowledge, Consciousness",
    subtitle: "THREE ENERGIES, EACH IN TURN · D minor · 63 BPM · beatless",
    blurb: "Three energies cross the same five minutes, and only one of them is ever at full strength. Stardust arrives first, high and granular. Knowledge takes over in the middle — the one that sounds like it is speaking. Consciousness comes up underneath and swallows both. Each hands over while it is still going, so you hear the change happen rather than arriving after it.",
    peak: { stardust: "Stardust", knowledge: "Knowledge", consciousness: "Consciousness" },
    form: [
      { name: "First Light",   bars:  6, layers: ["veil"],
        arcs: { stardust: [-0.62, -0.20, 1, 0.03] }, lead: [] },
      { name: "Stardust",      bars: 12, layers: ["veil", "dust", "glint"],
        arcs: { stardust: [-0.20,  0.00, 2, 0.05] }, lead: [] },
      // ⛔ `dust` LEAVES HERE, AND THAT IS THE FIX FOR ③b — NOT A DEEPER FILTER.
      // Measured on the stems: stardust read 34.2 dB at its own peak and 33.1
      // at The Turn, a lead of only +1.1 dB where the gate wants 1.5. It was
      // plateauing, not peaking. The cause was layer count, not brightness —
      // The Turn kept two of stardust's three layers and opened its filter at
      // 0.00, so almost nothing distinguished it from the peak. This tree has
      // paid for that lesson once already: the Arrival gate rejected three form
      // attempts before LOUDNESS IS LAYER COUNT, NOT FILTER stuck.
      //
      // ⭐ The happy consequence is that `dust` now plays in ONE section of the
      // whole piece — stardust's own — so it becomes that force's full-force
      // signature rather than a texture that hangs around. The filter still
      // travels further (to −0.50) so the two levers agree instead of one
      // fighting the other, and Knowledge's stardust arc starts where this one
      // lands, because pre-flight check ③ requires the handover be continuous.
      { name: "The Turn",      bars:  8, layers: ["veil", "lattice", "mind"],
        arcs: { stardust: [ 0.00, -0.50, 2, 0.06], knowledge: [-0.66, -0.26, 2, 0.05] }, lead: [0] },
      { name: "Knowledge",     bars: 14, layers: ["veil", "lattice", "mind", "trace"],
        arcs: { stardust: [-0.50, -0.88, 1, 0.04], knowledge: [-0.26,  0.00, 2, 0.06] }, lead: [0, 5] },
      { name: "The Deepening", bars:  8, layers: ["lattice", "mind", "aware", "vast"],
        arcs: { knowledge: [ 0.00, -0.42, 2, 0.06], consciousness: [-0.70, -0.28, 1, 0.04] }, lead: ["half"] },
      { name: "Consciousness", bars: 16, layers: ["lattice", "mind", "aware", "vast", "abyss"],
        arcs: { knowledge: [-0.42, -0.88, 2, 0.04], consciousness: [-0.28,  0.00, 3, 0.05] }, lead: ["half"] },
      { name: "Returning",     bars: 10, layers: ["glint", "aware", "vast"],
        arcs: { consciousness: [ 0.00, -0.38, 2, 0.05] }, lead: [] },
      { name: "Wash",          bars:  6, layers: ["glint", "aware"],
        arcs: { consciousness: [-0.38, -0.72, 1, 0.03] }, lead: [] },
    ],
  },

  // ⭐ THE ZERO END OF THE AXIS — no two forces ever sound together. Every
  // section belongs to exactly one force, so each gets a clean going-away
  // section of its own before the next one's coming-in section.
  // ⚠ This is the version where the three tones are easiest to TELL APART and
  // hardest to hear as one piece; that trade is the whole question being asked.
  apart: {
    id: "cosmic-forces-apart", tempo: 63, coexist: "separate",
    title: "Stardust, Knowledge, Consciousness · Apart",
    subtitle: "THE SAME THREE, ONE AT A TIME · D minor · 63 BPM · beatless",
    blurb: "The same three energies, but they never touch. Stardust finishes and goes quiet before Knowledge appears, and Knowledge is gone before Consciousness begins — three clear arrivals and three clear departures with nothing shared between them. This is the version where the three sounds are easiest to tell apart.",
    peak: { stardust: "Stardust", knowledge: "Knowledge", consciousness: "Consciousness" },
    form: [
      { name: "First Light",   bars:  6, layers: ["veil"],
        arcs: { stardust: [-0.62, -0.20, 1, 0.03] }, lead: [] },
      { name: "Stardust",      bars: 12, layers: ["veil", "dust", "glint"],
        arcs: { stardust: [-0.20,  0.00, 2, 0.05] }, lead: [] },
      { name: "Receding",      bars:  8, layers: ["veil", "glint"],
        arcs: { stardust: [ 0.00, -0.80, 2, 0.05] }, lead: [] },
      // ⚠ −0.80, NOT −0.70, AND THE MERGED-SWEEP CHECK IS WHY. With no overlap
      // there is no crossover to hide a mismatch in, so an incoming force that
      // starts brighter than the outgoing one left off is a visible step in the
      // piece's one brightness curve. Handing over at the same value costs
      // nothing musically — knowledge simply emerges out of the dark stardust
      // receded into — and it is the reason this arrives as a fix rather than as
      // a relaxed assertion.
      // ⛔ THE VOICE DOES NOT ARRIVE UNTIL "Knowledge", AND THAT IS THE ③b FIX.
      // Measured: Arriving (lattice+mind) 35.0 dB against Knowledge's 36.4 — a
      // +1.4 dB lead where 1.5 is required, because the only thing separating
      // them was `trace`, the thinnest layer in the piece. Knowledge was
      // plateauing across its whole region instead of peaking in its own
      // section. Dropping `mind` here leaves the anchor roll alone to emerge
      // out of the dark stardust receded into, so the vocalise and the canon
      // both land for the first time AT the peak.
      //
      // ⭐ It also rhymes with the opening: "First Light" is `veil` alone and
      // "Arriving" is now `lattice` alone — each force comes in as its anchor
      // and nothing else. `lead` empties with it; a lead spec on a section
      // whose voice track is gone would generate notes for no clip.
      { name: "Arriving",      bars:  8, layers: ["lattice"],
        arcs: { knowledge: [-0.80, -0.24, 2, 0.05] }, lead: [] },
      { name: "Knowledge",     bars: 12, layers: ["lattice", "mind", "trace"],
        arcs: { knowledge: [-0.24,  0.00, 2, 0.06] }, lead: [0] },
      { name: "Receding II",   bars:  6, layers: ["lattice", "trace"],
        arcs: { knowledge: [ 0.00, -0.82, 1, 0.05] }, lead: ["half"] },
      { name: "Gathering",     bars:  8, layers: ["aware", "vast"],
        arcs: { consciousness: [-0.82, -0.26, 1, 0.04] }, lead: [] },
      { name: "Consciousness", bars: 14, layers: ["aware", "vast", "abyss"],
        arcs: { consciousness: [-0.26,  0.00, 3, 0.05] }, lead: [] },
      { name: "Wash",          bars:  6, layers: ["aware"],
        arcs: { consciousness: [ 0.00, -0.66, 1, 0.03] }, lead: [] },
    ],
  },

  // ⭐ THE FAR END — nothing leaves. A force that has had its moment stays in
  // the texture with its filter closing, so it is still there but no longer the
  // thing you are listening to, and the last full section has all nine layers.
  // ⚠ ITS SHARE STILL FALLS, WHICH IS WHY THE GATE IS WRITTEN ON SHARE AND NOT
  // ON PRESENCE. A layer that keeps playing while five more arrive is a smaller
  // fraction of the sound than it was alone — so requirement ③ still has a real
  // peak to find here, and a gate that had counted layers would have passed this
  // piece for the wrong reason and failed it for the wrong reason too.
  // ⛔⛔ BUILT, MEASURED, AND NOT OFFERED — KEPT HERE BECAUSE A NEGATIVE RESULT
  // THAT IS DELETED GETS REBUILT. `converge` renders and renders correctly; it
  // fails the BRIEF, which is a different thing from failing a threshold, and
  // no gate setting can rescue it. Measured 2026-09-22 on its own stems:
  //   ③b stardust  +1.1 dB   ③b knowledge  +0.2 dB   (both need 1.5)
  //   ⑤ stardust  −4.8 LU    ⑤ knowledge   −5.6 LU   (limit 4.0)
  // It passed ③a comfortably (92.6% / 84.8%), so the forces ARE distinguishable
  // — they just never get a moment that is theirs.
  //
  // ⭐ THE REASON IS THAT ITS PREMISE CONTRADICTS THE BRIEF, AND I WROTE BOTH.
  // "The version that gets biggest" and "each of the three goes full force" are
  // the same axis read from opposite ends: if nothing ever leaves, every later
  // section is louder than every earlier one, so the first two forces can only
  // ever plateau. ⑤ reads the MIX at each force's own peak, and in a piece that
  // monotonically accumulates layers the finale wins by construction.
  //
  // ⛔ AND THE COMMENT BELOW ON "All Three" WAS A WISH, NOT A DESCRIPTION. It
  // says stardust and knowledge are "filtered down to a haze"; the arcs say
  // knowledge moves −0.26 → −0.30 (barely a dim) and stardust −0.66 → −0.34,
  // which BRIGHTENS through the finale. I did not notice until ③b said so.
  // Filtering harder would not have saved it either — dimming the finale until
  // ⑤ passes removes the only thing the variant was for.
  //
  // The third option is `crossing` instead, which moves along the SAME axis
  // (how long two forces sound together) rather than off it.
  converge: {
    id: "cosmic-forces-converge", tempo: 63, coexist: "converging", offered: false,
    title: "Stardust, Knowledge, Consciousness · Convergence",
    subtitle: "THE SAME THREE, GATHERING · D minor · 63 BPM · beatless",
    // ⚠ EVERY NUMBER HERE IS RE-DERIVED FROM `form`, NOT REMEMBERED. The first
    // draft said "none of them leaves" and "the last two minutes carry all
    // three", and the form says otherwise on both counts: "All Three" is 24
    // bars = 91 s = 1:31 (not 2:00), it is NOT last (a 30 s Wash follows it),
    // and that Wash carries no knowledge layer at all — so knowledge does
    // leave, in the final thirty seconds. Prose drifts off a form that is still
    // being edited; the fix is to state what the bars actually do.
    blurb: "The same three energies, but they pile up instead of taking turns. Each one stays in the sound after its moment has passed, dimming rather than departing, until a minute and a half of all nine layers carries the three of them at once. Only the closing wash lets go. This is the version that gets biggest.",
    // ⛔ CONSCIOUSNESS PEAKS IN "All Three", NOT IN A SECTION NAMED AFTER IT,
    // AND THAT IS THE HONEST LABEL RATHER THAN A CONVENIENT ONE. In the
    // converging version the moment consciousness is actually at full force IS
    // the all-nine finale — it is still opening while the others gather under
    // it. Naming an earlier section as its peak would have made the gate fail
    // this piece for a reason that is not true of it, and the fix for that is
    // to name the peak correctly, never to loosen the gate.
    peak: { stardust: "Stardust", knowledge: "Knowledge", consciousness: "All Three" },
    form: [
      { name: "First Light",   bars:  6, layers: ["veil"],
        arcs: { stardust: [-0.62, -0.20, 1, 0.03] }, lead: [] },
      { name: "Stardust",      bars: 12, layers: ["veil", "dust", "glint"],
        arcs: { stardust: [-0.20,  0.00, 2, 0.05] }, lead: [] },
      { name: "The Turn",      bars:  8, layers: ["veil", "dust", "glint", "lattice", "mind"],
        arcs: { stardust: [ 0.00, -0.40, 2, 0.05], knowledge: [-0.66, -0.26, 2, 0.05] }, lead: [0] },
      { name: "Knowledge",     bars: 14, layers: ["veil", "dust", "glint", "lattice", "mind", "trace"],
        arcs: { stardust: [-0.40, -0.62, 1, 0.04], knowledge: [-0.26,  0.00, 2, 0.06] }, lead: [0] },
      { name: "The Deepening", bars:  8, layers: ["veil", "glint", "lattice", "mind", "trace", "aware", "vast"],
        arcs: { stardust: [-0.62, -0.66, 1, 0.03], knowledge: [ 0.00, -0.26, 2, 0.05], consciousness: [-0.70, -0.30, 1, 0.04] }, lead: ["half"] },
      // ⚠ EVERY FORCE STAYS, BUT ONLY CONSCIOUSNESS IS BRIGHT. Stardust and
      // knowledge keep all their layers and are filtered down to a haze, which
      // is what "dimming rather than departing" has to mean if each force's own
      // moment is still to be its loudest.
      { name: "All Three",     bars: 24, layers: ["veil", "dust", "glint", "lattice", "mind", "trace", "aware", "vast", "abyss"],
        arcs: { stardust: [-0.66, -0.34, 2, 0.05], knowledge: [-0.26, -0.30, 2, 0.04], consciousness: [-0.30,  0.00, 3, 0.05] }, lead: [0, 5] },
      { name: "Wash",          bars:  8, layers: ["veil", "glint", "aware", "abyss"],
        arcs: { stardust: [-0.34, -0.62, 1, 0.03], consciousness: [ 0.00, -0.66, 1, 0.03] }, lead: [] },
    ],
  },

  // ⭐ THE FAR END OF THE AXIS THAT THE BRIEF ACTUALLY DESCRIBES. The question
  // being asked of the listener is HOW LONG TWO FORCES SOUND TOGETHER, and the
  // three offered pieces are the three answers: `apart` never overlaps at all,
  // `forces` hands over across 8 bars, and this one stretches each handover to
  // 14 — nearly a minute where two forces share the air and neither is plainly
  // in charge. One axis, three points, which is the only way a pick means
  // anything.
  //
  // ⛔ NOTHING ABOUT THE SOUND CHANGES HERE — ONLY THE BAR COUNTS. Same patches,
  // same anchors, same layer sets per section, and the SAME ARC ENDPOINTS as
  // `forces`, so the section-mean filter positions land where they already
  // measured well (+1.8 / +1.6 / +3.2 dB on ③b). Changing two things at once
  // would make a failure impossible to attribute, and this variant exists
  // precisely because `converge` changed the premise instead of the parameter.
  //
  // ⚠ TWO THINGS HAD TO BE RE-DERIVED RATHER THAN COPIED, BOTH BECAUSE THE
  // SECTIONS CHANGED LENGTH:
  //   · `lead` — the vocalise is EIGHT BARS long and `leadNotes` drops whatever
  //     runs past the section end. `[0, 5]` on canonical's 14-bar Knowledge
  //     fits two statements; on this 10-bar one the second would be sliced off
  //     after two bars. Every spec here is one the section can hold WHOLE.
  //   · `wob` — the ripple count is cycles ACROSS THE SECTION, so carrying 2
  //     over from an 8-bar section into a 14-bar one halves its rate. These are
  //     set to keep roughly one cycle per 4–6 bars, as the shorter form had.
  crossing: {
    id: "cosmic-forces-crossing", tempo: 63, coexist: "long handover",
    title: "Stardust, Knowledge, Consciousness · Crossing",
    subtitle: "THE SAME THREE, SLOWLY TRADING · D minor · 63 BPM · beatless",
    // ⛔ "each changeover runs about fifty seconds" was derived from the SECTION
    // LENGTHS (both are 14 bars = 53.3 s) and was false of the SOUND: measured
    // on the stems, the stretch where neither is plainly in charge is 32.0 s at
    // the first handover and 52.3 s at the second. The form being symmetrical
    // does not make the music symmetrical. ⚠ blurb-arith.py did not catch this —
    // its number-word table has no "fifty", so the claim was silently skipped.
    blurb: "The same three energies, but they take far longer to trade places. Each changeover runs thirty to fifty seconds, so for long stretches you are hearing two at once — Stardust still sounding under Knowledge, then Knowledge under Consciousness — with neither plainly in charge. This is the version with the softest edges: it should feel like one continuous thing rather than a piece in sections.",
    peak: { stardust: "Stardust", knowledge: "Knowledge", consciousness: "Consciousness" },
    form: [
      { name: "First Light",   bars:  6, layers: ["veil"],
        arcs: { stardust: [-0.62, -0.20, 1, 0.03] }, lead: [] },
      { name: "Stardust",      bars: 10, layers: ["veil", "dust", "glint"],
        arcs: { stardust: [-0.20,  0.00, 2, 0.05] }, lead: [] },
      { name: "The Turn",      bars: 14, layers: ["veil", "lattice", "mind"],
        arcs: { stardust: [ 0.00, -0.50, 3, 0.06], knowledge: [-0.66, -0.26, 3, 0.05] }, lead: [0] },
      { name: "Knowledge",     bars: 10, layers: ["veil", "lattice", "mind", "trace"],
        arcs: { stardust: [-0.50, -0.88, 1, 0.04], knowledge: [-0.26,  0.00, 2, 0.06] }, lead: [0] },
      // ⛔ ONE HALF-STATEMENT HERE, NOT TWO — ③b FAILED AT +0.6 dB BECAUSE OF IT.
      // `mind` is by far knowledge's loudest layer: measured on `apart`'s stems,
      // lattice alone is 31.0 dB, lattice+trace 32.3, and lattice+mind+trace
      // 37.3 — the voice is worth ~5 dB and `trace` ~1.3. So what decides where
      // knowledge PEAKS is how much of each section the vocalise covers, and
      // `["half","half"]` covered 8 of these 14 bars (57%) against only 80% in a
      // 10-bar peak. Canonical's ratio is 100% against 50%, and it leads by
      // +1.7; this led by +0.6.
      //
      // ⚠ I INTRODUCED THIS WHEN I RE-DERIVED THE `lead` SPECS FOR THE NEW BAR
      // COUNTS. Picking specs that fit a section WHOLE was right and necessary;
      // I just never asked what they would do to the ENERGY, and a spec is both
      // a musical choice and a loudness one. Thinning the voice as consciousness
      // rises is also the better reading of "one subsides" than repeating it.
      { name: "The Deepening", bars: 14, layers: ["lattice", "mind", "aware", "vast"],
        arcs: { knowledge: [ 0.00, -0.42, 3, 0.06], consciousness: [-0.70, -0.28, 2, 0.04] }, lead: ["half"] },
      { name: "Consciousness", bars: 12, layers: ["lattice", "mind", "aware", "vast", "abyss"],
        arcs: { knowledge: [-0.42, -0.88, 2, 0.04], consciousness: [-0.28,  0.00, 2, 0.05] }, lead: ["half"] },
      { name: "Returning",     bars:  8, layers: ["glint", "aware", "vast"],
        arcs: { consciousness: [ 0.00, -0.38, 2, 0.05] }, lead: [] },
      { name: "Wash",          bars:  6, layers: ["glint", "aware"],
        arcs: { consciousness: [-0.38, -0.72, 1, 0.03] }, lead: [] },
    ],
  },
};

const P = PIECES[WHICH];
if (!P) {
  console.error(`usage: node forces.mjs ${Object.keys(PIECES).join("|")} [--dry]`);
  process.exit(2);
}
P.chords = CHORDS_DM;
P.roots = ROOTS_DM;
P.family = "f";          // ⛔ NOT b OR d — the two-axis gate ④ in `section-arc.py`
                         // assumes ONE arrival and does not apply to a piece with
                         // three. `forces-gate.py` is what judges this family.

// ------------------------------------------------------------------ checking
// Everything below runs BEFORE the socket opens, so `--dry` catches a bad form
// table in a tenth of a second instead of after a ten-minute render.
let _bar = 0;
const SECTIONS = P.form.map((s) => ({ ...s, bar: (_bar += s.bars) - s.bars }));
const BARS = _bar;
const SECONDS = (BARS * 4 / P.tempo) * 60;
const has = (s, layer) => s.layers.includes(layer);
const uses = (layer) => SECTIONS.some((s) => has(s, layer));

const die = (msg) => { console.error(`⛔ ${P.id}: ${msg}`); process.exit(3); };

// ⛔ ① EVERY LAYER NAMED IN A FORM ROW MUST BELONG TO A FORCE. A typo in a layer
// name is otherwise a silent omission: `layerClips` skips a track that is never
// named, so "sitmmer" would just mean that track never plays, with no error.
for (const s of SECTIONS)
  for (const l of s.layers)
    if (!LAYER_FORCE[l]) die(`section "${s.name}" names unknown layer "${l}"`);

// ⛔ ② AN ANCHOR MUST PLAY IN EVERY SECTION WHERE ITS FORCE HAS AN ARC.
// The filter is automated on the anchor track. If the anchor has no clip there,
// the automation moves a filter over silence — the render succeeds, build.json
// looks correct, and the force simply never brightens or fades. Nothing else in
// this pipeline would catch that.
for (const f of FKEYS) {
  const { anchor, label } = FORCES[f];
  for (const s of SECTIONS) {
    if (s.arcs[f] && !has(s, anchor))
      die(`${label} sweeps in "${s.name}" but its anchor "${anchor}" has no clip there`);
  }
}

// ⛔ ③ A FORCE'S ARC MUST BE ONE UNBROKEN RUN OF SECTIONS, AND CONTINUOUS.
// Both halves matter. A gap means the force left and came back, and the second
// run would start from wherever the first one stopped — a filter jump. A
// mismatch between one row's `to` and the next row's `from` is the SWEEP
// DISCONTINUITY that bit `ascent5` on 2026-09-21: a 0.04 step in the filter,
// no error, and the only symptom a small click in the quietest bar of the piece.
for (const f of FKEYS) {
  const idx = SECTIONS.map((s, i) => (s.arcs[f] ? i : -1)).filter((i) => i >= 0);
  if (!idx.length) die(`force ${f} never sweeps — it has no arc in any section`);
  for (let k = 1; k < idx.length; k++) {
    if (idx[k] !== idx[k - 1] + 1)
      die(`${FORCES[f].label} arc has a GAP: "${SECTIONS[idx[k - 1]].name}" then "${SECTIONS[idx[k]].name}"`);
    const prevTo = SECTIONS[idx[k - 1]].arcs[f][1];
    const thisFrom = SECTIONS[idx[k]].arcs[f][0];
    if (Math.abs(prevTo - thisFrom) > 1e-9)
      die(`${FORCES[f].label} SWEEP DISCONTINUITY — "${SECTIONS[idx[k - 1]].name}" ends at ${prevTo} `
        + `but "${SECTIONS[idx[k]].name}" starts at ${thisFrom}`);
  }
}

// ⛔ ④ EACH FORCE'S NAMED PEAK SECTION MUST EXIST, MUST CARRY ALL THREE OF THAT
// FORCE'S LAYERS, AND MUST BE WHERE ITS ARC IS WIDEST. `peak` is what the gate
// will hold the render to, so a peak that names a section the force is barely in
// would make the gate fail a piece that is actually fine — or, worse, be
// quietly relaxed until it passed.
for (const f of FKEYS) {
  const { label, layers, anchor } = FORCES[f];
  const s = SECTIONS.find((x) => x.name === P.peak[f]);
  if (!s) die(`${label}'s peak section "${P.peak[f]}" is not in the form`);
  const missing = layers.filter((l) => !has(s, l));
  if (missing.length) die(`${label} peaks in "${s.name}" but ${missing.join(",")} do not play there`);
  const widest = Math.max(...SECTIONS.filter((x) => x.arcs[f]).map((x) => Math.max(x.arcs[f][0], x.arcs[f][1])));
  if (Math.max(s.arcs[f][0], s.arcs[f][1]) < widest - 1e-9)
    die(`${label} peaks in "${s.name}" but its filter is wider elsewhere`);
  void anchor;
}

// ⛔ ⑤ THE THREE FORCES MUST EMERGE AT THREE DIFFERENT BARS — requirement ② of
// the brief, checked rather than assumed. Two forces starting together is a
// two-force piece with an extra instrument.
{
  const first = Object.fromEntries(FKEYS.map((f) =>
    [f, SECTIONS.find((s) => s.layers.some((l) => LAYER_FORCE[l] === f))?.bar]));
  for (const f of FKEYS) if (first[f] === undefined) die(`force ${f} never plays`);
  const bars = FKEYS.map((f) => first[f]);
  if (new Set(bars).size !== 3) die(`forces do not emerge at distinct bars: ${JSON.stringify(first)}`);
  P._emerge = first;
}

// ------------------------------------------------------------------- sweeps
// Each force's own undulating curve. Same generator `develop.mjs` proved: travel
// filt→to across the section with `wob` cycles of ±`amp` ripple riding on top.
// The ripple is zero at both ends by construction (sin of a whole number of
// cycles), so the joins are exact and the arc is what the table says.
const clamp = (v) => Math.max(-0.95, Math.min(0.0, v));
const ease = (u) => u * u * (3 - 2 * u);
const SWEEPS = {};
for (const f of FKEYS) {
  const pts = [];
  const rows = SECTIONS.filter((s) => s.arcs[f]);
  rows.forEach((s) => {
    const [from, to, wob, amp] = s.arcs[f];
    const start = s.bar * 4, len = s.bars * 4;
    const steps = Math.max(4, wob * 6);
    for (let k = 0; k < steps; k++) {
      const u = k / steps;
      pts.push({
        beat: +(start + u * len).toFixed(4),
        value: +clamp(from + (to - from) * ease(u) + amp * Math.sin(u * Math.PI * 2 * wob)).toFixed(4),
      });
    }
  });
  const last = rows[rows.length - 1];
  pts.push({ beat: (last.bar + last.bars) * 4 - 1, value: +clamp(last.arcs[f][1]).toFixed(4) });
  const beats = pts.map((p) => p.beat);
  if (beats.length !== new Set(beats).size) die(`${f}: duplicate automation beats`);
  if (!beats.every((b, i) => i === 0 || b > beats[i - 1])) die(`${f}: automation beats not monotonic`);
  SWEEPS[f] = pts;
}

// ⭐ THE MERGED CURVE — the brightest live force at each moment, which is the
// single line that honestly describes this piece: it climbs to wide open three
// times, once per force, and dips between. Emitted as `sweep` so `review-page.py`
// can draw it and `section-arc.py` can read per-section `filt`/`to`, both of
// which assume the one-sweep shape `develop.mjs` had.
// ⚠ A MAX OF CONTINUOUS CURVES IS CONTINUOUS, so the derived per-section
// filt/to still thread exactly — that is a property of the merge, not luck, and
// it is asserted below rather than trusted.
const liveAt = (s) => FKEYS.filter((f) => s.arcs[f]);
SECTIONS.forEach((s) => {
  const live = liveAt(s);
  s.filt = +Math.max(...live.map((f) => s.arcs[f][0])).toFixed(4);
  s.to = +Math.max(...live.map((f) => s.arcs[f][1])).toFixed(4);
  s.forces = [...new Set(s.layers.map((l) => LAYER_FORCE[l]))];
});
SECTIONS.forEach((s, i) => {
  if (i && Math.abs(s.filt - SECTIONS[i - 1].to) > 1e-9)
    die(`merged sweep discontinuity at "${s.name}" (${SECTIONS[i - 1].to} → ${s.filt})`);
});
const SWEEP = [];
{
  const byBeat = new Map();
  for (const f of FKEYS) for (const p of SWEEPS[f])
    byBeat.set(p.beat, Math.max(byBeat.get(p.beat) ?? -1, p.value));
  for (const b of [...byBeat.keys()].sort((x, y) => x - y))
    SWEEP.push({ beat: b, value: +byBeat.get(b).toFixed(4) });
}

// -------------------------------------------------------------------- report
console.log(`${P.id}: ${BARS} bars @ ${P.tempo} BPM = ${(SECONDS / 60).toFixed(2)} min  `
  + `(${Math.floor(SECONDS / 60)}:${String(Math.round(SECONDS % 60)).padStart(2, "0")})  coexist=${P.coexist}`);
for (const s of SECTIONS) {
  const arcs = FKEYS.filter((f) => s.arcs[f])
    .map((f) => `${f[0]}${s.arcs[f][0].toFixed(2)}→${s.arcs[f][1].toFixed(2)}`).join(" ");
  console.log(`  bar ${String(s.bar).padStart(3)}  ${s.name.padEnd(14)} ${String(s.bars).padStart(2)}b  `
    + `${String(s.layers.length)}L ${s.layers.join(",").padEnd(46)} ${arcs}`);
}
console.log(`emerge: ${FKEYS.map((f) => `${f}@bar${P._emerge[f]}`).join("  ")}`);
console.log(`sweeps: ${FKEYS.map((f) => `${f}=${SWEEPS[f].length}`).join(" ")}  merged=${SWEEP.length}`);
if (process.argv.includes("--dry")) process.exit(0);

// --------------------------------------------------------------------- build
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: P.tempo });
for (const s of SECTIONS) await cmd("marker.add", { name: s.name, beat: s.bar * 4 });

// ⭐⭐ ONE BUS PER FORCE, AND IT IS A MEASUREMENT DECISION BEFORE IT IS A MIXING
// ONE. `render.stems` will only render a MASTER INPUT — "a track routed
// directly to master, or a bus"; a track inside a bus has no stem of its own.
// Three force buses therefore yield exactly three per-force stems, which is what
// lets `forces-gate.py` ask "which force is sounding here" by MEASURING each
// force alone instead of guessing a frequency band for it.
//
// ⛔ AND GUESSING IS EXACTLY WHAT FAILED. Two renders were judged by splitting
// the spectrum into a high, a mid and a low band and calling them stardust,
// knowledge and consciousness. It does not work, and not because the numbers
// were wrong: KNOWLEDGE'S OWN INSTRUMENTS ARE BRIGHT. A resonant square and a
// saw put strong harmonics above 800 Hz — they have to, or the layer stops
// sounding like a voice — so the "stardust band" measured 35.0 dB in the
// Knowledge section while stardust's only layer there was filtered to -0.88.
// The band was measuring BRIGHTNESS, not stardust. Register and attack are what
// separate these forces; treble is not, and no choice of boundary fixes that.
//
// ⚠ No effect sits on a bus (they are all per-track, plus the master limiter),
// so the three buses sum exactly as one did — but they are NO LONGER AT UNITY;
// see the trim below.
const BUS = {};
for (const f of FKEYS) BUS[f] = await addBus(FORCES[f].label);

// ⭐⭐ THE BALANCE TRIM, AND EVERY NUMBER IN IT WAS SIMULATED BEFORE IT WAS
// RENDERED. Requirement ⑤ asks that no force's full-force moment sit far below
// the others', and measured across all three variants knowledge kept coming
// last: −3.9 LU on the canonical form (a pass with 0.1 LU to spare), −4.4 on
// `apart`, −5.6 on `converge`. That is systematic, not a quirk of one form.
//
// ⛔ AND THE OBVIOUS FIX WAS WRONG, WHICH IS WHY IT WAS SIMULATED FIRST. Adding
// +3 dB to knowledge rescued `apart` and BROKE the canonical piece (spread 3.90
// → 4.10), because sections SHARE layers: canonical's Consciousness section
// carries lattice and mind, so lifting knowledge lifts consciousness's own peak
// with it. A per-force balance question is never about one number.
//
// ⭐ THE LEVER IS THAT PRE-MASTER STEMS SUM. `balance-sim.py` scales one bus's
// stem, re-sums, and re-measures — so a mix change costs one ffmpeg pass rather
// than a twenty-minute render. It refuses to predict anything until a unity sum
// reproduces the real mixdown; here it matched to 0.00 LU on every section,
// which also proves the master limiter is not engaging at these levels.
// Measured outcome of the chosen trim: canonical spread 3.90 → 2.10,
// `apart` 4.40 → 1.40, with consciousness still the loudest of the three so it
// keeps the role the piece gives it.
const FORCE_TRIM = { stardust: 1.0, knowledge: 1.122, consciousness: 0.794 };
for (const f of FKEYS) {
  const r = await cmd("track.setVolume",
                      { trackId: BUS[f], volume: FORCE_TRIM[f] });
  // ⚠ THIS CALL CAN SUCCEED AND CHANGE NOTHING. `track.setVolume` returns
  // {automationControlled:true} when a volume lane owns the fader, and then the
  // render ignores the value entirely — a silent inaudible success, which is
  // this tree's signature failure. No bus has a volume lane, so this should
  // never fire; that is exactly why it is worth asserting rather than assuming.
  if (r && r.automationControlled)
    throw new Error(`bus ${f} volume is automation-controlled (${r.automationPointCount} points) — the trim would not have taken`);
}
console.log(`bus trim: ${FKEYS.map((f) => `${f}=${FORCE_TRIM[f]}`).join("  ")}`);

// The layer gate, unchanged from `develop.mjs`: a track gets a clip in exactly
// the sections that name it, and that single function is what makes a force
// emerge and subside.
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
const T = {};
const mk = async (layer, name, inst, mix, notesFor) => {
  if (!uses(layer)) { T[layer] = null; return null; }
  const id = await addTrack(name, inst, { ...mix, busId: BUS[LAYER_FORCE[layer]] });
  T[layer] = id;
  counts[layer] = await layerClips(id, layer, notesFor, name);
  return id;
};

// ══ STARDUST ════════════════════════════════════════════ high · struck · granular
// ⚠ NO LOW END AT ALL, ON PURPOSE, AND THAT IS WHY IT WILL MEASURE QUIETEST.
// K-weighting boosts above 2 kHz and cuts below 100, so a force made of nothing
// but the top of the spectrum still reads lower in LUFS than one made of sub —
// the fix is level and layer density, NOT adding a bass to stardust, which would
// destroy the one thing that makes it a different tone.
await mk("veil", "Veil", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 7, unisonDetuneCents: 22, unisonStereoSpread: 1.0,
  cutoffHz: 5200, resonance: 0.18, keyToCutoff: 0.45,
  drift: 0.45, voiceJitter: 0.3, noiseLevel: 0.04, noiseColor: 0.55, drive: 0.22,
  attack: 0.5, decay: 1.1, sustain: 0.9, release: 3.0, gain: 0.58,
}, { volume: 0.84, pan: -0.06 },
  (s) => padNotes(P.chords, s.bar, s.bars, { octave: 24, velocity: 64 }));

await mk("dust", "Dust", {
  kind: "polySynth", waveform: "triangle",
  unisonVoices: 3, unisonDetuneCents: 15, unisonStereoSpread: 0.95,
  cutoffHz: 7000, resonance: 0.2, keyToCutoff: 0.5, velocityToCutoff: 0.3,
  drift: 0.2, voiceJitter: 0.25,
  attack: 0.02, decay: 0.8, sustain: 0.22, release: 1.3, gain: 0.34,
}, { volume: 0.6, pan: 0.22 },
  (s) => shimmerNotes(P.chords, s.bar, s.bars, { octave: 24, baseVel: 44 }));

// ⚠ SUSTAIN 0 — a bell IS its envelope. With any sustain at all these become a
// high drone and stardust stops sounding granular.
await mk("glint", "Glint", {
  kind: "polySynth", waveform: "sine",
  cutoffHz: 9000, resonance: 0.1,
  attack: 0.004, decay: 1.9, sustain: 0.0, release: 3.4, gain: 0.42,
}, { volume: 0.56, pan: -0.24 },
  (s) => glintNotes(P.chords, s.bar, s.bars));

// ══ KNOWLEDGE ═════════════════════════════════════════════ mid · ordered · it speaks
await mk("lattice", "Lattice", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 5, unisonDetuneCents: 12, unisonStereoSpread: 0.55,
  cutoffHz: 1700, resonance: 0.26, keyToCutoff: 0.55, velocityToCutoff: 0.25,
  drift: 0.22, voiceJitter: 0.14, drive: 0.2,
  attack: 0.22, decay: 1.1, sustain: 0.82, release: 2.2, gain: 0.55,
}, { volume: 0.78, pan: 0.04 },
  (s) => latticeNotes(P.chords, s.bar, s.bars));

// ⭐ THE STARLIGHT PATCH, KEPT EXACTLY — resonance 0.78 with a 0.62 boost and
// keyToCutoff 0.9 is what makes it read as a voice rather than a synth, and it
// is the most literal part of "similar to starlight". It also sings the same
// vocalise. If anything in this piece is recognisable as the other one, it is
// this layer, and that is deliberate: KNOWLEDGE is the force that speaks.
await mk("mind", "Mind", {
  kind: "polySynth", waveform: "square",
  unisonVoices: 3, unisonDetuneCents: 11, unisonStereoSpread: 0.55,
  subLevel: 0.18, subOctave: -1, subWaveform: "sine",
  cutoffHz: 1450, resonance: 0.78, resonanceBoost: 0.62,
  keyToCutoff: 0.9, velocityToCutoff: 0.4,
  drive: 0.16, drift: 0.28, voiceJitter: 0.12, envelopeCurve: 0.55,
  attack: 0.35, decay: 1.2, sustain: 0.7, release: 2.6, gain: 0.48,
}, { volume: 0.76, pan: 0.05 },
  (s) => leadNotes(THEME, s.lead, s.bars));

await mk("trace", "Trace", {
  kind: "polySynth", waveform: "triangle",
  unisonVoices: 3, unisonDetuneCents: 9, unisonStereoSpread: 0.4,
  cutoffHz: 1200, resonance: 0.3, keyToCutoff: 0.6,
  drift: 0.2, voiceJitter: 0.1,
  attack: 0.4, decay: 1.3, sustain: 0.65, release: 2.6, gain: 0.42,
}, { volume: 0.62, pan: -0.18 },
  (s) => canonNotes(THEME, s.lead, s.bars));

// ══ CONSCIOUSNESS ═══════════════════════════════════════ low · slow · enveloping
// ⚠ ATTACK 2.4 s IS THE POINT, NOT A TASTE DECISION. It is the axis that makes
// this force unmistakable next to a bell that strikes in 4 ms — you can hear the
// difference with your eyes shut and without knowing a single instrument name.
await mk("aware", "Aware", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 7, unisonDetuneCents: 30, unisonStereoSpread: 1.0,
  cutoffHz: 1100, resonance: 0.16, keyToCutoff: 0.35,
  drift: 0.55, voiceJitter: 0.36, noiseLevel: 0.03, noiseColor: 0.2, drive: 0.24,
  attack: 2.4, decay: 2.0, sustain: 0.94, release: 5.0, gain: 0.6,
}, { volume: 0.74, pan: 0.0 },
  (s) => padNotes(P.chords, s.bar, s.bars, { octave: -12, velocity: 62, lengthBeats: 4.8 }));

await mk("vast", "Vast", {
  kind: "polySynth", waveform: "saw",
  unisonVoices: 5, unisonDetuneCents: 16, unisonStereoSpread: 0.35,
  subLevel: 0.35, subOctave: -1, subWaveform: "sine",
  cutoffHz: 950, resonance: 0.14, drift: 0.3, voiceJitter: 0.2, drive: 0.4,
  attack: 1.8, decay: 1.6, sustain: 0.9, release: 4.2, gain: 0.6,
}, { volume: 0.68, pan: 0.02 },
  (s) => padNotes(P.chords, s.bar, s.bars, { octave: -12, velocity: 66 }));

await mk("abyss", "Abyss", {
  kind: "polySynth", waveform: "sine",
  subLevel: 0.85, subOctave: -1, subWaveform: "sine",
  cutoffHz: 380, resonance: 0.1, drive: 0.25,
  attack: 1.2, decay: 1.2, sustain: 0.88, release: 3.0, gain: 0.85,
}, { volume: 0.74 },
  (s) => bassNotes(P.roots, s.bar, s.bars, 78));

// ------------------------------------------------------------------ effects
// ⭐ THE HALL IS PART OF THE TONE, NOT A FINISH. Stardust sits in a small bright
// room so its bells stay separate; consciousness sits in a 55-metre hall with a
// nine-second tail so it has no edges at all. Same three notes, two different
// forces — and this is why, as much as the waveform is.
const fx = {};
const add = async (layer, key, kind, params) => {
  if (!T[layer]) return;
  fx[key] = await addFx(T[layer], kind, params);
};
await add("veil", "veilVerb", "hallReverb", { mix: 0.55, decaySeconds: 4.5, sizeMeters: 26, preDelayMs: 25 });
await add("veil", "veilWide", "stereoWidth", { width: 1.45 });
await add("dust", "dustVerb", "hallReverb", { mix: 0.6, decaySeconds: 4.0, sizeMeters: 24, preDelayMs: 18 });
await add("dust", "dustWide", "stereoWidth", { width: 1.6 });
await add("glint", "glintDelay", "tapeDelay", { timeMs: 631, feedback: 0.42, mix: 0.4, wowDepthMs: 2.5 });
await add("glint", "glintVerb", "hallReverb", { mix: 0.7, decaySeconds: 5.0, sizeMeters: 30, preDelayMs: 20 });

await add("lattice", "latVerb", "hallReverb", { mix: 0.42, decaySeconds: 5.0, sizeMeters: 32, preDelayMs: 35 });
await add("mind", "mindDelay", "tapeDelay", { timeMs: 720, feedback: 0.44, mix: 0.32, wowDepthMs: 4.5 });
await add("mind", "mindVerb", "hallReverb", { mix: 0.5, decaySeconds: 5.5, sizeMeters: 36, preDelayMs: 35 });
await add("trace", "traceDelay", "tapeDelay", { timeMs: 960, feedback: 0.3, mix: 0.26, wowDepthMs: 3.5 });
await add("trace", "traceVerb", "hallReverb", { mix: 0.5, decaySeconds: 5.5, sizeMeters: 34, preDelayMs: 40 });

await add("aware", "awareVerb", "hallReverb", { mix: 0.75, decaySeconds: 9.0, sizeMeters: 55, preDelayMs: 70 });
await add("aware", "awareWide", "stereoWidth", { width: 1.7 });
await add("vast", "vastVerb", "hallReverb", { mix: 0.4, decaySeconds: 6.0, sizeMeters: 40, preDelayMs: 30 });
await add("vast", "vastSat", "saturator", { driveDb: 5, mix: 0.45 });
// ⚠ A SMALL ROOM ON THE SUB. Put a 40-metre hall on a 37 Hz sine and its tail
// smears into the next chord as mud that no EQ later can separate.
await add("abyss", "abyssVerb", "hallReverb", { mix: 0.2, decaySeconds: 2.6, sizeMeters: 18, preDelayMs: 12 });

// ⛔ THE FILTERS GO ON THE ANCHOR TRACKS, NEVER ON A BUS. Carried over from
// `cosmic.mjs`: on a bus at high resonance the djFilter has a cliff either side
// of zero (position −0.08 measured −41.5 LUFS against −31.9 at 0.0), and a mix
// with no drums has no floor to survive that. Resonance 0 here for the same
// reason — three of these are running at once and any one of them ringing would
// colour the whole piece.
const lanes = {};
for (const f of FKEYS) {
  const { anchor, label } = FORCES[f];
  const first = SECTIONS.find((s) => s.arcs[f]);
  fx[`${f}Filter`] = await addFx(T[anchor], "djFilter", { position: first.arcs[f][0], resonance: 0.0 });
  lanes[f] = await automate(T[anchor], fx[`${f}Filter`], "position", SWEEPS[f]);
  console.log(`${label}: filter on ${anchor} (track ${T[anchor]}), ${SWEEPS[f].length} points`);
}

fx.masterLimiter = await addFx("master", "limiter", { ceilingDb: -1.0, truePeak: 1, releaseMs: 80 });

// ⭐ THE BREATH — a slow LFO on the voice's own cutoff; the synth has no vibrato.
// ⚠ Depth lives on the ROUTE, not the source, and the target key is `param`.
// Not wrapped in a silent catch: if modulation refuses, the piece still renders
// and the failure is VISIBLE.
let breath = null;
try {
  const src = await cmd("mod.addSource", {
    trackId: T.mind, kind: "lfo", name: "Breath",
    params: { waveform: "sine", rateHz: 0.13, bipolar: true },
  });
  const srcId = src.sourceId || src.id;
  const route = await cmd("mod.addRoute", {
    trackId: T.mind, sourceId: srcId,
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
// +12 s of tail: `aware` releases over 5 s into a hall that decays for 9.
const TAIL = Math.ceil(SECONDS) + 12;
await cmd("render.mixdown", { path: wav, durationSeconds: TAIL });

// ⭐ THE THREE STEMS — one per force, the gate's actual evidence.
// ⚠ Stems are PRE-MASTER by design ("render_stems excludes master moves"), so
// these three do not sum to the mixdown once the limiter engages. That is
// correct for measurement and wrong for listening: the deliverable is the
// mixdown above, and these exist only to be measured. `forces-gate.py` still
// takes ⑤ (loudness) off the MIX, never off a stem.
const stemDir = path.resolve(`${outDir}/stems`);
fs.mkdirSync(stemDir, { recursive: true });
let stems = null;
try {
  const r = await cmd("render.stems", {
    trackIds: FKEYS.map((f) => BUS[f]),
    directory: stemDir, durationSeconds: TAIL,
  });
  // ⛔ MATCH BY BUS ID, NEVER BY FILENAME ORDER. The reply's ordering is not
  // promised anywhere, and a gate that silently measures knowledge's stem as
  // stardust's would produce a clean, plausible, wrong table — the exact
  // failure shape this pipeline keeps producing.
  // ⚠ THE REPLY SHAPE IS NOT VERIFIED HERE, SO IT IS PRINTED. A wrong guess at
  // the container key would otherwise look identical to "the app returned
  // nothing" — and this pipeline has already spent a session on one of those.
  console.log(`render.stems reply keys: ${JSON.stringify(Object.keys(r))}`);
  const list = r.stems || r.files || r.renders || r.outputs || [];
  if (!Array.isArray(list) || !list.length)
    throw new Error(`no stem list in reply: ${JSON.stringify(r).slice(0, 500)}`);
  console.log(`first stem entry: ${JSON.stringify(list[0]).slice(0, 300)}`);
  stems = {};
  for (const f of FKEYS) {
    const hit = list.find((s) => (s.trackId || s.id) === BUS[f]);
    if (!hit) throw new Error(`no stem came back for ${f} (bus ${BUS[f]})`);
    stems[f] = hit.path || hit.file;
    if (!stems[f]) throw new Error(`stem entry for ${f} carries no path: ${JSON.stringify(hit)}`);
  }
  for (const f of FKEYS) console.log(`stem ${f}: ${stems[f]}`);
} catch (e) {
  // Not swallowed: the mixdown is already safely on disk, and the gate will
  // refuse to score without stems rather than quietly falling back to bands.
  console.error(`⚠ STEMS NOT RENDERED — ${String(e.message || e).slice(0, 400)}`);
  stems = null;
}

fs.writeFileSync(`${outDir}/build.json`, JSON.stringify({
  variant: P.id, title: P.title, subtitle: P.subtitle, blurb: P.blurb,
  family: P.family, coexist: P.coexist,
  pulsed: false, power: true,
  tempo: P.tempo, bars: BARS, seconds: +SECONDS.toFixed(1),
  // ⭐ THE DESIGN TRAVELS WITH THE RENDER. `forces-gate.py` reads the bands, the
  // peak section names and the emergence bars FROM HERE rather than keeping its
  // own copy — a gate with a second, hand-maintained copy of the form is a gate
  // that passes the piece it remembers instead of the piece that was built.
  forces: Object.fromEntries(FKEYS.map((f) => [f, {
    ...FORCES[f], peakSection: P.peak[f], emergeBar: P._emerge[f],
  }])),
  sections: SECTIONS, sweep: SWEEP, sweeps: SWEEPS, noteCounts: counts,
  chords: P.chords, roots: P.roots,
  tracks: { ...T }, buses: BUS, fx, lanes, breath,
  wav, stems, at: new Date().toISOString(),
}, null, 2));

console.log(`notes: ${Object.entries(counts).map(([k, v]) => `${k}=${v}`).join(" ")}`);
console.log(`wrote ${wav}`);
await close();
// ⛔ EXPLICIT EXIT — `close()` closes the socket but something in the client
// keeps the loop alive, so the process would sit there forever AFTER the wav and
// build.json are both safely on disk, and a driver running three of these in
// sequence would stop dead after the first with nothing to show why.
process.exit(0);
