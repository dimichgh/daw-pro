// THE THREE FORCES — the note generators that are NOT in `cosmic-material.mjs`.
// DATA AND PURE FUNCTIONS ONLY. Same reason as that file: an ES import RUNS the
// module, and `forces.mjs` opens the control socket and renders a wav at top
// level, so importing a note list from it would destroy the caller's project.
//
// ⭐ THE BRIEF, IN THE USER'S OWN WORDS (2026-09-22):
//   "build a composition similar to starlight, but where multiple energies
//    (3 main powerful, different tones) emerge at different point of time and go
//    full force and then oen subsides and another emerges, they should represent
//    cosmic forces, knowledge, stardust, consiousness"
//
// "cosmic forces" is the umbrella; the three energies are KNOWLEDGE, STARDUST,
// CONSCIOUSNESS. The harmony stays Starlight's — D aeolian, the same eight-bar
// cycle, the same vocalise — because "similar to starlight" is the other half of
// the brief, and because every downstream tool (`make-loop.py` above all) assumes
// an EIGHT-BAR harmonic period. Three forces do not mean three harmonies; they
// mean three ways of VOICING one.
//
// ⭐⭐ WHAT MAKES A NON-MUSICIAN HEAR THREE DIFFERENT THINGS, in order of strength:
//   ① REGISTER   — stardust lives above the stave, knowledge in the middle,
//                  consciousness below it. This is the axis that survives a
//                  phone speaker, so it is the one pushed hardest.
//   ② ATTACK     — stardust strikes (~10 ms), knowledge speaks (~250 ms),
//                  consciousness arrives (~2 s). You can hear the difference
//                  between a ping, a word and a swell with your eyes shut.
//   ③ TEXTURE    — points of light / an ordered unfolding / one enveloping mass.
// Waveform is LAST on that list, not first: a saw and a triangle at the same
// pitch through the same filter are far closer than two attacks are.
//
// ⛔ BEATLESS, STILL. The standing rule from `cosmic.mjs` is not withdrawn and
// the one scoped exception (a pulse on two of the five developed pieces) was
// spent there. Nothing here repeats an impulse: `latticeNotes` is a ROLL whose
// notes all sustain into one chord, and `glintNotes` deliberately walks OFF the
// bar so its spacing can never be counted. Both were designed against the
// heartbeat's `div: 2` — one impulse every 1.9 s — which IS a pulse and is
// exactly what these must not become.

/** STARDUST · the bells. Sparse, very high, and DELIBERATELY UNCOUNTABLE.
 *
 *  ⚠ THE STRIDE IS THE WHOLE POINT AND IT IS NOT A ROUND NUMBER. At 63 BPM a
 *  note every 1.31 beats lands every 1.25 s — close enough to the heartbeat's
 *  1.9 s that an EVEN spacing would read as a slow pulse. Because 1.31 does not
 *  divide 4, every bell lands at a different place in the bar and the pattern
 *  takes 131 bars to repeat, which is longer than the piece. There is nothing to
 *  count, only glitter.
 *
 *  Pitch follows whatever chord the bell LANDS in — computed from the absolute
 *  beat, not from a bar loop — so a bell that drifts across a barline changes
 *  harmony with it. */
export const glintNotes = (chords, bar0, bars, {
  stride = 1.31, octave = 24, lengthBeats = 3.2, baseVel = 52, spread = 10,
} = {}) => {
  const n = [];
  const total = bars * 4;
  for (let k = 0; k * stride < total; k++) {
    const beat = k * stride;
    const ch = chords[(bar0 + Math.floor(beat / 4)) % chords.length];
    // A ladder that reaches two octaves, walked by a step that is coprime with
    // its length so consecutive bells are never neighbours.
    const ladder = [...ch, ...ch.map((p) => p + 12)];
    n.push({
      startBeat: +beat.toFixed(4),
      pitch: ladder[(k * 5) % ladder.length] + octave,
      lengthBeats,
      velocity: baseVel + ((k * 7) % spread) - Math.floor(spread / 2),
    });
  }
  return n;
};

/** KNOWLEDGE · the ordered unfolding. One chord per bar, but its tones ENTER IN
 *  SEQUENCE rather than together, and the direction alternates bar by bar.
 *
 *  ⛔ THIS IS A ROLL, NOT A PULSE, AND THE DIFFERENCE IS THE NOTE LENGTH. Every
 *  tone sustains to the end of the bar and past it, so three attacks assemble
 *  ONE chord that is then held — the ear hears a thing being built, not three
 *  events being counted. Shorten `holdToBarEnd` and it becomes an arpeggio;
 *  shorten it further and it becomes the beat this music is not allowed to have.
 *
 *  The alternating direction is what makes it read as ORDERED rather than
 *  mechanical: up, down, up, down is a structure you can follow, where a fixed
 *  direction is a machine. */
export const latticeNotes = (chords, bar0, bars, {
  offsets = [0, 1.3, 2.6], octave = 0, velocity = 62, tail = 1.4, accent = 8,
} = {}) => {
  const n = [];
  for (let b = 0; b < bars; b++) {
    const ch = chords[(bar0 + b) % chords.length];
    const order = (bar0 + b) % 2 === 0 ? ch : [...ch].reverse();
    offsets.forEach((off, i) => {
      const start = b * 4 + off;
      n.push({
        startBeat: start,
        pitch: order[i % order.length] + octave,
        // to the end of ITS OWN bar plus a tail, so the chord is complete and
        // still sounding when the next bar's first tone arrives
        lengthBeats: +((b + 1) * 4 - start + tail).toFixed(3),
        velocity: i === 0 ? velocity + accent : velocity,
      });
    });
  }
  return n;
};

/** KNOWLEDGE · the reply. The vocalise again, an octave down and `offsetBeats`
 *  late — a canon, which is the oldest way music has of sounding like thought:
 *  one idea, examined by being laid against itself.
 *
 *  ⚠ IT SHARES `leadNotes`' SPEC FORMAT so a section's `lead` row drives both
 *  voices from one place. Anything the canon would push past the end of the
 *  section is dropped rather than spilling into the next one, exactly as
 *  `leadNotes` does — a note that outlives its clip is a note the layer gate
 *  cannot take away. */
export const canonNotes = (theme, spec, bars, {
  offsetBeats = 8, transpose = -12, velocityScale = 0.72,
} = {}) => {
  const out = [];
  spec.forEach((t, r) => {
    const src = t === "half" ? theme.filter((x) => x.startBeat < 16) : theme;
    const shift = t === "half" ? 0 : t;
    for (const n of src) {
      out.push({
        ...n,
        startBeat: n.startBeat + r * 32 + offsetBeats,
        pitch: n.pitch + shift + transpose,
        velocity: Math.round(n.velocity * velocityScale),
      });
    }
  });
  return out.filter((n) => n.startBeat < bars * 4);
};
