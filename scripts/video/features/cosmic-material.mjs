// The musical material of STARLIGHT — chords, roots, the vocalise, and the four
// note generators. DATA AND PURE FUNCTIONS ONLY.
//
// ⛔⛔ WHY THIS IS A SEPARATE FILE AND NOT AN IMPORT FROM `cosmic.mjs`.
// An ES import RUNS the module. `cosmic.mjs` opens the control socket at top
// level, calls `project.new`, builds an arrangement and renders a wav — so
// `import { THEME } from "./cosmic.mjs"` would DESTROY the caller's project and
// spend four minutes rendering, as a side effect of reading a note list. This
// repo has already been bitten by exactly that shape once: `lead-options.mjs` is
// a script, `leads.mjs` is its data-only twin, and the same split is why
// `build.mjs` can import the lead patch without re-running the comparison.
//
// Nothing in here touches the wire, the filesystem, or the clock.
//
// ⚠ EXTRACTED 2026-09-21 FROM `cosmic.mjs`, GATED ON NOTE-LIST EQUALITY, not on
// a re-render: these are pure functions, so a JSON diff of their output at
// several arguments is exact and instant, while a render comparison would be
// fuzzed by the synth's own `drift` and `voiceJitter` and cost four minutes to
// say less. The generators gained a leading `chords`/`roots`/`theme` argument
// and an options bag so the drastically-different versions can pass their own
// harmony; every default reproduces the shipped a/b/c/d output exactly.

// ------------------------------------------------------------------ harmony
// i - VI - III - VII - iv, D aeolian. One chord per bar, which at ~63 BPM is
// about one change every four seconds. The point is that it barely moves.
export const CHORDS_DM = [
  [62, 65, 69],   // Dm
  [62, 65, 69],   // Dm
  [58, 62, 65],   // Bb
  [57, 60, 65],   // F
  [55, 58, 62],   // Gm
  [60, 64, 67],   // C
  [58, 62, 65],   // Bb — holds up the melody's high F
  [62, 65, 69],   // Dm
];
export const ROOTS_DM = [38, 38, 34, 33, 31, 36, 34, 38];   // D2 D2 Bb1 F1 G1 C2 Bb1 D2

// ⭐ THE VOICE. Eight bars, ten notes — at 63 BPM that is thirty seconds of
// music from ten pitches. A vocalise is a SHAPE, not a display of notes: one
// low phrase that asks, one that climbs to a single high F and lets go.
export const THEME = [
  [0,  69, 4.2],   // A4 ....... the question
  [4,  72, 2.4],   // C5
  [6,  70, 2.4],   // Bb4
  [8,  69, 4.2],   // A4
  [12, 65, 4.4],   // F4 ....... settles
  [16, 70, 2.4],   // Bb4 ...... the climb begins
  [18, 72, 2.4],   // C5
  [20, 74, 4.2],   // D5
  [24, 77, 4.4],   // F5 ....... the peak, one note, held
  [28, 74, 4.5],   // D5 ....... lets go
].map(([startBeat, pitch, lengthBeats], i) => ({
  startBeat, pitch, lengthBeats,
  velocity: [78, 84, 84, 82, 76, 86, 92, 100, 108, 88][i],
}));

// ---------------------------------------------------------------- generators

/** Sustained chord tones, one chord per bar, overlapping into the next. */
export const padNotes = (chords, bar0, bars, { octave = 0, velocity = 58, lengthBeats = 4.6 } = {}) => {
  const n = [];
  for (let b = 0; b < bars; b++)
    for (const p of chords[(bar0 + b) % chords.length])
      n.push({ startBeat: b * 4, pitch: p + octave, lengthBeats, velocity });
  return n;
};

/** A shimmer, NOT an arpeggio engine. Eighth notes at 63 BPM land every 0.48 s
 *  and the release is well over a second, so they pile into a wash rather than
 *  reading as a pattern. Low velocity, high register, buried in the hall.
 *
 *  ⚠ `step` IS THE KNOB THAT DECIDES WASH-OR-PULSE, AND IT IS TEMPO-COUPLED.
 *  0.5 beats reads as light at 63 BPM because the gap (0.48 s) is far shorter
 *  than the release. Raise the tempo and the same 0.5 starts to articulate — so
 *  a faster beatless variant must WIDEN the step, and a variant that WANTS a
 *  pulse can simply narrow it and shorten the release. */
export const shimmerNotes = (chords, bar0, bars, {
  step = 0.5, per = 8, lengthBeats = 0.9, octave = 12, baseVel = 40, accent = 6,
} = {}) => {
  const n = [];
  for (let b = 0; b < bars; b++) {
    const ch = chords[(bar0 + b) % chords.length];
    const ladder = [...ch, ...ch.map((p) => p + 12)];
    for (let i = 0; i < per; i++) {
      n.push({
        startBeat: b * 4 + i * step,
        pitch: ladder[(i * 2 + b) % ladder.length] + octave,
        lengthBeats,
        velocity: baseVel + (i % 2 ? 0 : accent),   // barely accented; no downbeat stress
      });
    }
  }
  return n;
};

/** WHOLE notes. One per bar, no offbeats, nothing that could be counted. */
export const bassNotes = (roots, bar0, bars, velocity = 64, { lengthBeats = 4.4 } = {}) => {
  const n = [];
  for (let b = 0; b < bars; b++)
    n.push({ startBeat: b * 4, pitch: roots[(bar0 + b) % roots.length], lengthBeats, velocity });
  return n;
};

/** The theme laid out across a section, once per 8 bars, per the form table.
 *  `spec` entries are semitone transpositions, or "half" for the opening phrase
 *  alone — the last section sings only the question and stops, so the piece ends
 *  on the wash rather than on a cadence. */
export const leadNotes = (theme, spec, bars) => {
  const out = [];
  spec.forEach((t, r) => {
    if (t === "half") {
      for (const n of theme.filter((x) => x.startBeat < 16)) out.push({ ...n });
      return;
    }
    for (const n of theme) out.push({ ...n, startBeat: n.startBeat + r * 32, pitch: n.pitch + t });
  });
  return out.filter((n) => n.startBeat < bars * 4);
};
