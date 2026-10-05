// The material for "The Amen break, programmed by hand".
//
// ⛔ THE 1969 RECORDING IS NEVER TOUCHED. "Amen, Brother" (The Winstons, 1969)
//    is a sound recording still in copyright in the US into the 2060s. Nothing
//    in this build reads, downloads, or analyses that record. Every hit below
//    is a MIDI note written by hand into DAW Pro and played by a General MIDI
//    drum kit out of GeneralUser-GS. That limit IS the lesson, not a footnote.
//
// ⚠ AND IT IS AN APPROXIMATION, DELIBERATELY. video-facts-history.md §3 flags
//    this: a 16th-grid transcription "cannot fully capture the original" --
//    Ethan Hein, "hardly any of [Coleman's hits] are exactly where they are
//    'supposed' to be". So this is the SKELETON that producers program, and the
//    film says so on a card. It is not a claimed sample-exact transcription.
//
// LAYERS, not one blob: the film builds the pattern up one voice at a time and
// A/Bs three of the steps, so every stage of the build has to be renderable on
// its own. Three TRACKS (kick / snare / cymbals) rather than one, so per-hit
// onset and level measurement lands on a clean stem instead of on a mix with
// continuous ride eighths underneath it.
import { n } from "../../session/build.mjs";

export const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
export const KIT = { kind: "soundBank", soundBank: { source: GUGS, program: 0, bankMSB: 120 } };

export const BPM = 136;                      // the fact sheet's figure for the record
export const BPM_JUNGLE = 170;
export const SIXTEENTH_MS = 15000 / BPM;     // 110.294 ms
export const BEAT_MS = 60000 / BPM;          // 441.176 ms
export const BARS = 4;
export const LEN_BEATS = BARS * 4;           // 16 beats
export const SECS = LEN_BEATS * (60 / BPM);  // 7.0588 s

// GM percussion map (channel-10 numbering, which is what bankMSB 120 selects)
export const KICK = 36, SNARE = 38, HAT = 42, RIDE = 51, CRASH = 49;

// velocities, chosen FROM THE MEASURED LADDER (probe3.mjs), not from a guess.
// The sound bank's law is amplitude proportional to (v/127)^2, i.e.
// 40*log10(v/127) dB, verified to a tenth of a dB from v10 to v127.
export const V_ACCENT = 110;   // -10.2 dBFS peak on the snare
// ⚠ THE FIRST CHOICE WAS MEASURED AND REJECTED. At V_GHOST 30 with the ride at
// 80 the ghost notes were 13 dB UNDER the ride and the short-time level of the
// two renders never differed by 6 dB for as long as 20 ms -- the attention
// marker found ZERO listen windows, i.e. the chapter's whole demonstration was
// inaudible. The house standard's first remedy is to FIX THE SOURCE MATERIAL,
// so the ghosts came up and the cymbals came down. Predicted from the measured
// law: ghost peak -22.2 dBFS against a ride at -24.1 dBFS.
// ⚠ AND 55 WAS REJECTED TOO, for a second measured reason: the bank's snare has
// a VELOCITY LAYER covering roughly v55-v70 that sits +4.67 dB off the
// (v/127)^2 curve, so a ghost at 55 measured 7.37 dB under the accent where the
// law predicts 12.04. 50 is on the curve: predicted 13.70 dB under, and the
// film can state a prediction that its own render then confirms.
export const V_GHOST  = 50;    // 13.7 dB under the accent (40*log10(50/110))
export const V_KICK   = 110;
export const V_RIDE   = 62;
export const V_RIDE_W = 74;    // the ride on the beat, a little stronger
export const V_CRASH  = 118;

const S = 0.25;                              // one sixteenth, in beats
const at = (bar, sixteenth) => bar * 4 + sixteenth * S;

// ── the grid, sixteenth by sixteenth (0..15 within each bar) ───────────────
// bars 1-2  straight funk: kick on 1 and the "and-a" of 3, snare on 2 and 4
// bar 3     IDENTICAL skeleton except the beat-4 snare is pushed one sixteenth
//           late -- the moment the loop stops repeating itself
// bar 4     the famous one: NO kick on the downbeat, a syncopated snare
//           flurry, a crash on the "and" of 3
const KICKS = [
  [0, [0, 10]],
  [1, [0, 10]],
  [2, [0, 10]],
  [3, [6]],                                   // <- nothing on the downbeat
];
const SNARES_ACCENT = [
  [0, [4, 12]],
  [1, [4, 12]],
  [2, [4, 13]],                               // <- 13, not 12: the displacement
  [3, [2, 9, 13]],                            // <- the flurry
];
const SNARES_GHOST = [
  [0, [7]],
  [1, [7, 14]],
  [2, [7]],
  [3, [15]],
];

const build = (rows, pitch, vel, len = 0.24) =>
  rows.flatMap(([bar, hits]) => hits.map(h => n(at(bar, h), pitch, len, vel)));

export const kick   = build(KICKS, KICK, V_KICK, 0.24);
export const accent = build(SNARES_ACCENT, SNARE, V_ACCENT, 0.24);
export const ghost  = build(SNARES_GHOST, SNARE, V_GHOST, 0.18);
// the snare with the bar-3 displacement UNDONE -- the A/B "before" for stage 07
export const accentStraight = build(
  SNARES_ACCENT.map(([b, h]) => [b, b === 2 ? [4, 12] : h]), SNARE, V_ACCENT, 0.24);

// cymbals: continuous eighths, the crash replacing the ride on bar 4's "and of 3"
const cym = [];
for (let b = 0; b < BARS; b++)
  for (let e = 0; e < 8; e++) {
    const beatStrong = e % 2 === 0;
    if (b === 3 && e === 5) { cym.push(n(b * 4 + e * 0.5, CRASH, 1.4, V_CRASH)); continue; }
    cym.push(n(b * 4 + e * 0.5, RIDE, 0.4, beatStrong ? V_RIDE_W : V_RIDE));
  }
export const cymbals = cym;

// the two-bar skeleton, repeated across all four bars: bars 1-2 with no ghosts
// and no bar-3/bar-4 surprises. This is what a novice programs first, and the
// "before" half of two of the film's A/Bs.
const repeat2 = (rows) => rows.filter(([b]) => b < 2)
  .flatMap(([b, h]) => [[b, h], [b + 2, h]]);
export const kickPlain   = build(repeat2(KICKS), KICK, V_KICK, 0.24);
export const accentPlain = build(repeat2(SNARES_ACCENT), SNARE, V_ACCENT, 0.24);
export const ghostPlain  = build(repeat2(SNARES_GHOST), SNARE, V_GHOST, 0.18);
const cymPlain = [];
for (let b = 0; b < BARS; b++)
  for (let e = 0; e < 8; e++)
    cymPlain.push(n(b * 4 + e * 0.5, RIDE, 0.4, e % 2 === 0 ? V_RIDE_W : V_RIDE));
export const cymbalsPlain = cymPlain;

export const NOTE_COUNT = kick.length + accent.length + ghost.length + cymbals.length;
export const COUNTS = {
  kick: kick.length, snareAccent: accent.length, snareGhost: ghost.length,
  snare: accent.length + ghost.length, cymbals: cymbals.length,
  ride: cymbals.filter(x => x.pitch === RIDE).length,
  // ⚠ ghostDemo IS NOT snareGhost, AND THE FILM ONCE SAID IT WAS. The ghost A/B
  //   (s3-skeleton vs s4-ghosts) is built from `ghostPlain` -- bars 1-2 repeated --
  //   which carries SIX ghosts, while the real four-bar pattern carries FIVE
  //   (bar 4 trades its second ghost for the displaced accent). The listen-window
  //   count is derived from the DEMO render, so it must be checked against THIS
  //   number; checking it against snareGhost needed a `+ 1` fudge to pass, which
  //   is how a rigged assertion looks from the inside.
  ghostDemo: ghostPlain.length,
  crash: cymbals.filter(x => x.pitch === CRASH).length,
  total: NOTE_COUNT,
};
