// The material for "Beethoven's metronome marks are too fast. Nobody knows why."
//
// ⭐ THE SUBJECT IS DISPUTED AND THE FILM ENDORSES NOTHING. Three explanations
//    have real evidence and named advocates; none is settled. What this build
//    CAN do is measure what the marks actually SOUND like, which is the one
//    thing every side of the argument agrees about, and let the viewer hear it.
//
// ⛔ EVERY HISTORICAL NUMBER TRACES TO docs/research/video-facts-history.md §2.
//    Sourced there and used here: 135 markings, 66 called absurdly fast, the
//    Fifth's first movement at HALF NOTE = 108, the Eroica finale at HALF NOTE
//    = 76, PLOS ONE 2020's ~12-13 bpm average shortfall and its 44-of-63, the
//    Ninth's march at dotted-quarter=84 vs dotted-half=84, Forsen 2013's
//    damaged-pendulum model and the surviving metronome's missing weight.
//    NOT sourced there and therefore NOT stated anywhere in this film: the
//    Fifth's composition date, Maelzel's patent date, the movement's time
//    signature, the notch spacing on the metronome's scale.
//    ⚠ Schuller's ~92 and the Stokowski ~40 ARE in the fact sheet and are
//    DELIBERATELY UNUSED: 92 is the mean of 66 recordings of the Fifth's
//    FINALE, while 108 is the FIRST MOVEMENT's mark. The shipped 182 s film
//    paired them. Pairing a finale average with a first-movement mark is a
//    comparison of two different things, and the fact sheet itself flags that
//    line as a secondary citation to verify before use. It is cut.
//
// ⛔ THE MUSIC IS PUBLIC DOMAIN AND TYPED BY HAND. Eight notes of Beethoven's
//    Fifth, entered as MIDI. No recording of any orchestra is read, downloaded
//    or analysed. Beethoven died in 1827, so the COMPOSITION is public domain
//    everywhere; a specific modern edition or a downloaded MIDI file can carry
//    its own editorial copyright, which is exactly why these eight notes are
//    typed rather than fetched (the same reasoning as the Bach lesson's).
import { n } from "../../session/build.mjs";

export const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
// GM program 48, String Ensemble 1 -- the motif's own voice.
export const STRINGS = { kind: "soundBank", soundBank: { source: GUGS, program: 48 } };
// GM percussion (bankMSB 120). Pitch 76 is High Wood Block: a short, hard,
// pitch-free tick whose onset is unambiguous, which is what an onset detector
// and a viewer both need from a metronome.
export const KIT = { kind: "soundBank", soundBank: { source: GUGS, program: 0, bankMSB: 120 } };
export const WOODBLOCK = 76;

// ---------------------------------------------------------------- the tempi
//
// ⚠ EVERY ONE OF THESE IS A QUARTER-NOTE BPM, because that is the only unit a
//   DAW's tempo field has. The whole lesson lives in the gap between that field
//   and what a score writes. Beethoven's mark for the Fifth's first movement is
//   HALF NOTE = 108: one hundred and eight HALF notes a minute, which is two
//   hundred and sixteen QUARTER notes a minute. Same tempo, two numbers.
export const HALF_MARK = 108;            // [EXACT, fact sheet] Symphony No. 5, mvt I
export const BPM_MARK = HALF_MARK * 2;   // 216 quarter BPM -- what the app shows

// The average conductor. PLOS ONE 2020 measured performances landing ~12-13 bpm
// under the marks across 36 recordings of 9 symphonies. 12 is MY arithmetic
// applied to THEIR average, in the mark's own unit, and the film says so.
export const PLOS_SHORTFALL = 12;
export const HALF_DRIFT = HALF_MARK - PLOS_SHORTFALL;   // 96
export const BPM_DRIFT = HALF_DRIFT * 2;                // 192 quarter BPM

// The notational-unit reading: the SAME number, 108, with a quarter note on the
// tick instead of a half note. The metronome does not move. The music halves.
export const BPM_UNIT = HALF_MARK;       // 108 quarter BPM

// [EXACT, fact sheet] Symphony No. 3 "Eroica", finale: HALF NOTE = 76. Cited
// alongside the Fifth as an argument AGAINST one fixed broken rate.
export const HALF_EROICA = 76;
export const BPM_EROICA = HALF_EROICA * 2;              // 152 quarter BPM

// ---------------------------------------------------------------- the motif
//
// The opening of Symphony No. 5: an eighth rest, three eighth notes on one
// pitch, then a longer note a third lower; then the same shape a step down.
// Written here in QUARTER-NOTE BEATS, which is what clip.addMIDI takes.
//
//   beat 0.0  (rest)
//   beat 0.5  G   eighth
//   beat 1.0  G   eighth
//   beat 1.5  G   eighth
//   beat 2.0  Eb  half        <- carries a fermata in the score
//   beat 4.0  (rest)
//   beat 4.5  F   eighth
//   beat 5.0  F   eighth
//   beat 5.5  F   eighth
//   beat 6.0  D   half        <- carries a fermata in the score
//
// ⚠ THE FERMATAS ARE PLAYED AS WRITTEN, WHICH IS NOT HOW ANYONE PERFORMS THEM,
//   AND THE FILM SAYS SO OUT LOUD. A fermata is a hold of no written length. No
//   metronome mark governs it, no DAW tempo field can express it, and that is
//   itself part of the argument this lesson is about: a number on a page does
//   not contain everything a performance needs.
export const G4 = 67, EB4 = 63, F4 = 65, D4 = 62;
export const STATEMENT_BEATS = 8;
const V = 104;

export const motifOnce = (off = 0) => [
  n(off + 0.5, G4, 0.5, V), n(off + 1.0, G4, 0.5, V), n(off + 1.5, G4, 0.5, V),
  n(off + 2.0, EB4, 2.0, V),
  n(off + 4.5, F4, 0.5, V), n(off + 5.0, F4, 0.5, V), n(off + 5.5, F4, 0.5, V),
  n(off + 6.0, D4, 2.0, V),
];
export const NOTES_PER_STATEMENT = motifOnce().length;   // 8

/** N statements of the motif, back to back.
 *  ⚠ THE REPETITION IS MINE, NOT BEETHOVEN'S, and the film states that. He
 *  develops the cell; this build simply repeats it, because a drift of a
 *  quarter of a second per statement is only visible once it has accumulated
 *  over several of them. */
export const motif = (reps) =>
  Array.from({ length: reps }, (_, i) => motifOnce(i * STATEMENT_BEATS)).flat();

// ---------------------------------------------------------------- the clicks
//
// Two click patterns, and the difference between them IS explanation three.
// `clickHalf` puts a tick on every HALF note; `clickQuarter` puts one on every
// QUARTER note. Play clickHalf at 216 and clickQuarter at 108 and the ticks
// come at exactly the same rate -- 108 a minute, 555.556 ms apart, both of them
// -- while the music underneath runs at half speed in the second. The
// metronome setting is literally the same; only the note value written on the
// tick has changed.
const V_TICK = 112;
export const clickHalf = (beats) =>
  Array.from({ length: Math.floor(beats / 2) }, (_, i) => n(i * 2, WOODBLOCK, 0.25, V_TICK));
export const clickQuarter = (beats) =>
  Array.from({ length: Math.floor(beats) }, (_, i) => n(i, WOODBLOCK, 0.25, V_TICK));

// ---------------------------------------------------------------- arithmetic
// Everything below is derived. Nothing here is typed twice, and measure.py
// re-derives all of it independently from the renders rather than reading it.
export const secPerBeat = (bpm) => 60 / bpm;
export const tickIoiMs = (bpm, beatsPerTick) => 60000 * beatsPerTick / bpm;
export const statementSec = (bpm) => STATEMENT_BEATS * secPerBeat(bpm);

// The A/B window. 10.000 s is EXACTLY four statements at 192 (10.0000 s) and
// EXACTLY four and a half at 216 (36 beats) -- and beat 36 is the eighth REST
// that opens the second half of a statement, so both halves are cut in silence
// rather than through a note. A round number of seconds is not usually a
// musical length; this one was chosen because it happens to be one for both.
export const AB_SECONDS = 10.0;

// The unit A/B window. 8.8889 s is EXACTLY four statements at 216 and EXACTLY
// two at 108 -- the same span of clock time, twice as much music.
export const UNIT_SECONDS = STATEMENT_BEATS * 4 * secPerBeat(BPM_MARK);

// The jitter positive control for the onset probe (see measure.py). A clean
// rendered click can genuinely come back at a spread of a fraction of a
// millisecond, and a tiny uniform number across many units is the signature of
// a probe that never measured. So one render is deliberately humanised by a
// KNOWN amount and the probe has to find it.
export const JITTER_BEATS = 0.02;        // +/- 0.02 beat
export const JITTER_SEED = 20260906;
export const jitterMs = (bpm) => JITTER_BEATS * 60000 / bpm;   // +/- 5.556 ms at 216

export const COUNTS = {
  notesPerStatement: NOTES_PER_STATEMENT,
  statements: 4,
  motifNotes: NOTES_PER_STATEMENT * 4,
  distinctPitches: new Set([G4, EB4, F4, D4]).size,
};
