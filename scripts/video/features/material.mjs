#!/usr/bin/env node
// THE MUSICAL MATERIAL. Everything here is note data; no wire calls.
// Kept separate from the builder so the three variants can be diffed by eye:
// same structure, same drums, same effect chain — different source material.

import { pattern, layers, VOICE } from "./arrange.mjs";

// ------------------------------------------------------------ the shared form
// 64 bars at 128 BPM = 2:00 exactly. A DJ-legible shape a non-musician can
// still follow: it gets busier, it drops out, it comes back bigger.
export const BARS = 64;
export const TEMPO = 128;
export const SECTIONS = [
  { name: "Intro",     bar: 0,  bars: 8  },
  { name: "Build",     bar: 8,  bars: 8  },
  { name: "Drop",      bar: 16, bars: 16 },
  { name: "Breakdown", bar: 32, bars: 8  },
  { name: "Build 2",   bar: 40, bars: 8  },
  { name: "Drop 2",    bar: 48, bars: 16 },
];

// ------------------------------------------------------------------ the drums
// One kit, six section-patterns. Shared by all three variants: the drum machine
// is the thing being demonstrated, so it must not be the thing that varies.
const P = {
  fourFloor:  "X---x---X---x---",
  kickSparse: "X-------X-------",
  clapBackbeat: "----X-------X---",
  hatOffbeat: "--x---x---x---x-",
  hatSixteen: "x-x-x-x-x-x-x-x-",
  hatDriving: "X-x-x-x-X-x-x-x-",
  openHatOff: "----------------",
  openHatLift:"------------x---",
  rimLight:   "----o-------o---",
  tomFill:    "------------x-x-",
};

export function drumsFor(section, bars) {
  switch (section) {
    case "Intro":
      return layers(pattern(VOICE.kick, bars, P.fourFloor),
                    pattern(VOICE.closedHat, bars, P.hatOffbeat));
    case "Build":
      return layers(pattern(VOICE.kick, bars, P.fourFloor),
                    pattern(VOICE.closedHat, bars, P.hatOffbeat),
                    pattern(VOICE.clap, bars, P.clapBackbeat));
    case "Drop":
      return layers(pattern(VOICE.kick, bars, P.fourFloor),
                    pattern(VOICE.closedHat, bars, P.hatOffbeat),
                    pattern(VOICE.clap, bars, P.clapBackbeat),
                    pattern(VOICE.openHat, bars, P.openHatLift));
    case "Breakdown":
      // ⚠ NO KICK. A breakdown a listener can actually hear as a breakdown.
      return layers(pattern(VOICE.closedHat, bars, P.hatOffbeat),
                    pattern(VOICE.rim, bars, P.rimLight));
    case "Build 2":
      return layers(pattern(VOICE.kick, bars, P.fourFloor),
                    pattern(VOICE.closedHat, bars, P.hatSixteen),
                    pattern(VOICE.clap, bars, P.clapBackbeat),
                    pattern(VOICE.tom, bars, P.tomFill));
    case "Drop 2":
      return layers(pattern(VOICE.kick, bars, P.fourFloor),
                    pattern(VOICE.closedHat, bars, P.hatDriving),
                    pattern(VOICE.clap, bars, P.clapBackbeat),
                    pattern(VOICE.openHat, bars, P.openHatLift),
                    pattern(VOICE.cymbal, bars, "x---------------"));
    default:
      throw new Error(`no drum pattern for section ${section}`);
  }
}

// -------------------------------------------------------------- bass builder
/** Offbeat eighths on each bar's root — the engine of a house record. */
export function bassLine(roots, bars, { weight = true } = {}) {
  const notes = [];
  for (let bar = 0; bar < bars; bar++) {
    const root = roots[bar % roots.length];
    if (weight) notes.push({ startBeat: bar * 4, pitch: root, lengthBeats: 0.45, velocity: 104 });
    for (const off of [0.5, 1.5, 2.5, 3.5]) {
      notes.push({ startBeat: bar * 4 + off, pitch: root, lengthBeats: 0.45, velocity: 88 });
    }
  }
  return notes;
}

/** Sustained chords, one per bar. */
export function padLine(voicings, bars, velocity = 64) {
  const notes = [];
  for (let bar = 0; bar < bars; bar++) {
    for (const p of voicings[bar % voicings.length]) {
      notes.push({ startBeat: bar * 4, pitch: p, lengthBeats: 3.9, velocity });
    }
  }
  return notes;
}

/** Lay a fixed motif out repeatedly across `bars`. */
export function motif(notes, motifBars, bars, transposeCycle = [0]) {
  const out = [];
  const reps = Math.floor(bars / motifBars);
  for (let r = 0; r < reps; r++) {
    const shift = transposeCycle[r % transposeCycle.length];
    for (const n of notes) {
      out.push({ ...n, startBeat: n.startBeat + r * motifBars * 4, pitch: n.pitch + shift });
    }
  }
  return out;
}

const nn = (startBeat, pitch, lengthBeats, velocity = 96) => ({ startBeat, pitch, lengthBeats, velocity });

// ============================================================== VARIANT A
// "Machine Room" — original material. A minor, i-VI-III-VII (Am F C G):
// the most-used loop in dance music, chosen because a novice recognises the
// FEELING even though the tune is new.
export const MACHINE_ROOM = {
  id: "machine-room",
  title: "Machine Room",
  subtitle: "Original · A minor · 128 BPM",
  kit: "909",
  blurb: "An original club track written for this demo — nothing borrowed, so every sound you hear came out of the instruments we built.",
  bassRoots: [33, 29, 36, 31],                    // A1  F1  C2  G1
  pads: [[57, 60, 64], [53, 57, 60], [55, 60, 64], [55, 59, 62]],
  leadBars: 4,
  lead: [
    nn(0, 69, 0.5), nn(1, 76, 0.5), nn(1.5, 74, 0.5), nn(2, 72, 0.5), nn(3, 69, 1),
    nn(4, 72, 0.5), nn(5, 76, 0.5), nn(5.5, 79, 0.5), nn(6.5, 76, 1.5),
    nn(8, 69, 0.5), nn(9, 76, 0.5), nn(9.5, 74, 0.5), nn(10, 72, 0.5), nn(11, 76, 1),
    nn(12, 74, 1), nn(13, 72, 1), nn(14, 69, 2),
  ],
};

// ---------------------------------------------- research -> arrangement notes
/** Map the research file's {beat,midi,len} shape into this file's note shape.
 *  `transpose` moves the excerpt into the LEAD's register: both themes were
 *  transcribed in the octave a person hums them in, which is well below the
 *  square-wave lead this arrangement uses. Transposing by whole octaves keeps
 *  the tune identical — it is the one change that cannot alter which piece a
 *  listener hears. */
function fromResearch(notes, transpose, velocity = 100) {
  return notes.map((n) => ({
    startBeat: n.beat, pitch: n.midi + transpose,
    lengthBeats: n.len, velocity,
  }));
}

// ============================================================== VARIANT B
// "Mountain King" — Grieg, In the Hall of the Mountain King (1875), Op. 46 No. 4.
// PUBLIC DOMAIN beyond argument: Grieg died 1907 (life+70 expired 1977) and the
// score was published 1876/1888, before 1929. Pitches were read off the Mutopia
// Project's public-domain engraving, which carries its own PD dedication.
//
// ⚠ TWO DISCLOSED DEPARTURES FROM THE SCORE, neither of which changes the tune:
//  1. TEMPO. The score says Alla marcia, quarter = 138. This plays at 128, the
//     arrangement's shared tempo. Every variant must sit on the same grid or
//     they stop being one axis apart.
//  2. THE RAISED SIXTH (G#3, here 80). The engraving carries a written sharp the
//     2-sharp key signature does not explain, and the secondary sources read it
//     as the raised-6th colour tone. The researcher flagged this as MEDIUM
//     confidence and I am keeping the flag rather than quietly promoting it:
//     substituting plain G would change the colour, not the identity, because
//     the repeated-note cell is what anybody actually recognises.
// ⛔⛔ THIS DATA REPLACED A WRONG FIRST DRAFT, AND THE CONTRADICTION WAS VISIBLE
// IN THE RESEARCH ITSELF. The first pass pixel-read the engraved PDF and produced
// a REPEATED-NOTE cell (D-D-D-D-E-F#) while quoting secondary sources that all
// described "upward scalar motion". Four repeated notes then two steps is not
// scalar motion — the report disagreed with itself and I built a variant on it
// anyway. My own visualiser then showed the tell: one bright vertical line at a
// single pitch, where the real theme has to climb through a fifth.
//
// The fix was to stop reading pixels and read the SOURCE: Mutopia publishes the
// LilyPond `.ly` text next to the PDF, and LilyPond's \relative octave rule was
// hand-traced token by token. The theme is scale degrees 1-2-3-4-5-3-5
// (B-C#-D-E-F#-D-F#), stated twice with a chromatic "sighing" bar between, and
// the second statement lands AN OCTAVE HIGHER — which the trace produced on its
// own rather than by assumption.
//
// The bar-0 dominant pedal is dropped here so the phrase is a clean 8 bars that
// tiles the arrangement's 16- and 8-bar sections. Beats are shifted by -4.
const GRIEG_THEME = [
  // statement 1 — B2 up to F#3
  { beat: 0.0, midi: 47, len: 0.5 }, { beat: 0.5, midi: 49, len: 0.5 }, { beat: 1.0, midi: 50, len: 0.5 }, { beat: 1.5, midi: 52, len: 0.5 },
  { beat: 2.0, midi: 54, len: 0.5 }, { beat: 2.5, midi: 50, len: 0.5 }, { beat: 3.0, midi: 54, len: 1.0 },
  // the chromatic sighing bar — E#->E natural, C#->C natural
  { beat: 4.0, midi: 53, len: 0.5 }, { beat: 4.5, midi: 49, len: 0.5 }, { beat: 5.0, midi: 53, len: 1.0 },
  { beat: 6.0, midi: 52, len: 0.5 }, { beat: 6.5, midi: 48, len: 0.5 }, { beat: 7.0, midi: 52, len: 1.0 },
  { beat: 8.0, midi: 47, len: 0.5 }, { beat: 8.5, midi: 49, len: 0.5 }, { beat: 9.0, midi: 50, len: 0.5 }, { beat: 9.5, midi: 52, len: 0.5 },
  { beat: 10.0, midi: 54, len: 0.5 }, { beat: 10.5, midi: 50, len: 0.5 }, { beat: 11.0, midi: 54, len: 0.5 }, { beat: 11.5, midi: 59, len: 0.5 },
  { beat: 12.0, midi: 57, len: 0.5 }, { beat: 12.5, midi: 54, len: 0.5 }, { beat: 13.0, midi: 50, len: 0.5 }, { beat: 13.5, midi: 54, len: 0.5 },
  { beat: 14.0, midi: 57, len: 2.0 },
  // statement 2 — the same thing an octave up, exactly as the source computes
  { beat: 16.0, midi: 59, len: 0.5 }, { beat: 16.5, midi: 61, len: 0.5 }, { beat: 17.0, midi: 62, len: 0.5 }, { beat: 17.5, midi: 64, len: 0.5 },
  { beat: 18.0, midi: 66, len: 0.5 }, { beat: 18.5, midi: 62, len: 0.5 }, { beat: 19.0, midi: 66, len: 1.0 },
  { beat: 20.0, midi: 65, len: 0.5 }, { beat: 20.5, midi: 61, len: 0.5 }, { beat: 21.0, midi: 65, len: 1.0 },
  { beat: 22.0, midi: 64, len: 0.5 }, { beat: 22.5, midi: 60, len: 0.5 }, { beat: 23.0, midi: 64, len: 1.0 },
  { beat: 24.0, midi: 59, len: 0.5 }, { beat: 24.5, midi: 61, len: 0.5 }, { beat: 25.0, midi: 62, len: 0.5 }, { beat: 25.5, midi: 64, len: 0.5 },
  { beat: 26.0, midi: 66, len: 0.5 }, { beat: 26.5, midi: 62, len: 0.5 }, { beat: 27.0, midi: 66, len: 0.5 }, { beat: 27.5, midi: 71, len: 0.5 },
  { beat: 28.0, midi: 69, len: 0.5 }, { beat: 28.5, midi: 66, len: 0.5 }, { beat: 29.0, midi: 62, len: 0.5 }, { beat: 29.5, midi: 66, len: 0.5 },
  { beat: 30.0, midi: 69, len: 2.0 },
];

export const MOUNTAIN_KING = {
  id: "mountain-king",
  title: "Mountain King",
  subtitle: "Grieg, 1875 · B minor · 128 BPM",
  kit: "909",
  blurb: "Grieg's creeping ostinato from Peer Gynt, put over the same drum machine and the same effect chain. Public domain since 1977.",
  source: "Edvard Grieg, In the Hall of the Mountain King (Peer Gynt, Op. 46 No. 4, 1875) — public domain",
  // B minor. Grieg's own left hand is a staccato bassoon ostinato alternating
  // B/F# under the first three bars and D/A under the fourth. `bassLine` plays
  // offbeat eighths on ONE root per bar — the house engine this arrangement
  // shares — so this keeps Grieg's harmonic rhythm and simplifies the
  // alternation away. Disclosed, not hidden. 35=B1, 38=D2.
  // ⚠ 35 is B1 ≈ 62 Hz. It will be weak or absent on a phone speaker.
  bassRoots: [35, 35, 35, 38, 35, 35, 35, 38],
  // Bm under the scalar bars, D (the relative major) under the fourth. The
  // chromatic sighing bars get a BARE OCTAVE — no third — because a B minor
  // triad under Grieg's E#/C-natural would clash with the very notes that make
  // that bar interesting.
  pads: [
    [59, 62, 66], [59, 71], [59, 62, 66], [62, 66, 69],
    [59, 62, 66], [59, 71], [59, 62, 66], [62, 66, 69],
  ],
  leadBars: 8,                                   // 8 bars = 32 beats, tiles 16 and 8
  lead: fromResearch(GRIEG_THEME, 12),           // B2 register -> B3..A5, the lead's own
};

// ============================================================== VARIANT C
// "Fate" — Beethoven, Symphony No. 5 in C minor, Op. 67 (1808), opening motif.
// PUBLIC DOMAIN: Beethoven died 1827; published 1809.
//
// ⚠ THE CONTINUATION IS NOT BEETHOVEN'S AND THE FILM SAYS SO.
// Only the four-bar motif is transcribed. From bar 5 the real score becomes
// imitative counterpoint, and the researcher could not source exact pitches for
// it — so rather than fabricate a famous composer's notes, the verified 4-bar
// unit repeats. That is an arrangement choice, disclosed, not a transcription.
// A famous tune with invented notes is the one defect every listener catches.
//
// ⚠ THE SECOND FERMATA IS TIED ACROSS TWO BARS, NOT ONE. A first draft of the
// research gave it one bar; the corrected read gives four beats, and that
// asymmetry — the second held note lasting twice the first — is a documented
// feature of the piece, not a transcription slip. Keeping it makes the unit
// TWENTY beats, so the phrase is FIVE bars against a four-bar drum grid and the
// two realign every twenty bars. That is faithful, and it is also why the lead
// leaves a bar of air at the end of each section — which a build can use.
// Shortening it to close a tidy four-bar loop would have quietly reintroduced
// exactly the error that was just corrected.
//
// The eighth REST that opens each statement is why the first note sits at 0.5.
const BEETHOVEN_MOTIF = [
  { beat: 0.5, midi: 67, len: 0.5 }, { beat: 1.0, midi: 67, len: 0.5 }, { beat: 1.5, midi: 67, len: 0.5 },
  { beat: 2.0, midi: 63, len: 2.0 },
  { beat: 4.5, midi: 65, len: 0.5 }, { beat: 5.0, midi: 65, len: 0.5 }, { beat: 5.5, midi: 65, len: 0.5 },
  { beat: 6.0, midi: 62, len: 4.0 },
  { beat: 10.5, midi: 67, len: 0.5 }, { beat: 11.0, midi: 67, len: 0.5 }, { beat: 11.5, midi: 67, len: 0.5 },
  { beat: 12.0, midi: 63, len: 2.0 },
  { beat: 14.5, midi: 65, len: 0.5 }, { beat: 15.0, midi: 65, len: 0.5 }, { beat: 15.5, midi: 65, len: 0.5 },
  { beat: 16.0, midi: 62, len: 4.0 },
];

export const FATE = {
  id: "fate",
  title: "Fate",
  subtitle: "Beethoven, 1808 · C minor · 128 BPM",
  kit: "909",
  blurb: "The four notes everyone can hum, over the same kit and the same chain. Only the motif is Beethoven's — the arrangement around it is ours, and the film says so.",
  source: "Ludwig van Beethoven, Symphony No. 5 in C minor, Op. 67 (1808), opening motif — public domain",
  // ⚠ THE BASS IS OURS, NOT BEETHOVEN'S. The real opening is a bare unison with
  // no bass under it at all, so any bass here is an arrangement addition. C
  // minor with a dominant G in the turnaround bar. 36=C2, 31=G1.
  bassRoots: [36, 36, 36, 31],
  pads: [[60, 63, 67], [60, 63, 67], [60, 63, 67], [59, 62, 67]],
  leadBars: 5,                                   // 10 bars of 2/4 = 5 bars of 4/4
  lead: fromResearch(BEETHOVEN_MOTIF, 12),       // G4 anchor -> G5, the lead's own
};

export const VARIANTS = {
  "machine-room": MACHINE_ROOM,
  "mountain-king": MOUNTAIN_KING,
  "fate": FATE,
};
