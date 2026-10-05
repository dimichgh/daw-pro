// The MATERIAL for the rebuilt "Beethoven at 128" lesson. Written by hand,
// note by note — no generation model, per the lesson-material rule. Shared by
// probe.mjs and shoot.mjs so the thing that was measured and the thing that was
// filmed cannot drift apart.
//
// THE DESIGN DECISION THE WHOLE FILM RESTS ON
// ───────────────────────────────────────────
// The film compares an "orchestral" rendering of Beethoven's four-note cell
// against a "techno" one, and then measures what is different at the bottom of
// the spectrum. That comparison is only honest if the two versions play THE
// SAME NOTES, at THE SAME TEMPO, for THE SAME LENGTH — so that the only things
// that differ are the INSTRUMENTS and the ARRANGEMENT, which is exactly the
// claim being made.
//
// So there is ONE riff, `RIFF`, and:
//
//   * the orchestral version plays it in three octaves, in unison, the way the
//     Fifth actually opens — violins two octaves up, celli one octave up,
//     double basses at the written pitch. No drums. No sustained anything.
//   * the techno version plays the SAME riff on a saw, and adds the room: a
//     kick from bar 2, offbeat hats from bar 4, a clap from bar 6, and a
//     sustained low sine root from bar 5.
//
// ⚠ THE ORCHESTRAL VERSION IS NOT BASS-FREE, AND THE FILM MUST NOT SAY IT IS.
// The double-bass part's fundamentals are 73–104 Hz. What it does not have is
// anything SUSTAINED down there — every note in it is a short cell note that
// stops. That is the real, defensible claim, and it is what gets measured.
//
// ⚠ THE REPETITION IS MINE, NOT BEETHOVEN'S. He never wrote this as a loop.
// The four notes and their rhythm are his; the 4-bar phrase repeated four times
// is the film's own invention and the film says so out loud.
import { n } from "../../session/build.mjs";

export const BPM = 128;                      // MY choice of tempo, not his
export const BARS = 16;
export const LEN_BEATS = BARS * 4;           // 64 beats
export const SECS = LEN_BEATS * (60 / BPM);  // 30.0 s

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const sb = (program, extra = {}) =>
  ({ kind: "soundBank", soundBank: { source: GUGS, program, ...extra } });
// ⚠ THE WIRE FLATTENS THE SYNTH PARAMS. track.setInstrument takes
// waveform/attack/…/gain as TOP-LEVEL keys and REFUSES a nested
// `polySynth` object outright (the good case — a silent accept would
// have rendered the default patch and nobody would have known).
const poly = (p) => ({ kind: "polySynth", ...p });

// ── the cell ────────────────────────────────────────────────────────────────
// Three short notes on ONE pitch, then a longer note lower down. An eighth rest
// first — the cell starts off the beat, which is half of why it is so hard to
// clap along to. At 128 BPM one beat is 468.75 ms and one eighth is 234.375 ms.
//
// C minor. Pitches are given at the DOUBLE-BASS octave; the orchestral parts
// transpose up from here and the techno riff plays them as written.
const G2 = 43, Eb2 = 39, F2 = 41, D2 = 38, Ab2 = 44;

/** one bar of the cell: three repeats of `hi`, then `lo` held. */
const cell = (bar, hi, lo, vHi = 108, vLo = 112) => {
  const o = bar * 4;
  return [n(o + 0.5, hi, 0.4, vHi), n(o + 1.0, hi, 0.4, vHi),
          n(o + 1.5, hi, 0.4, vHi), n(o + 2.0, lo, 1.9, vLo)];
};

// the 4-bar phrase, four times through
const PHRASE = [[G2, Eb2], [F2, D2], [G2, Eb2], [Ab2, G2]];
export const RIFF = [];
for (let b = 0; b < BARS; b++) {
  const [hi, lo] = PHRASE[b % 4];
  RIFF.push(...cell(b, hi, lo));
}

const up = (notes, semis) =>
  notes.map((x) => ({ ...x, pitch: x.pitch + semis }));

// ── the orchestral version: the same riff, in three octaves, in unison ──────
export const VIOLINS = up(RIFF, 24);   // G4 392 Hz down to D4 293.7 Hz
export const CELLI   = up(RIFF, 12);   // G3 196 Hz
export const BASSES  = RIFF;           // G2 98.0 · Eb2 77.8 · F2 87.3 · D2 73.4

// ── the techno version ──────────────────────────────────────────────────────
// Kick from bar 2, hats from bar 4, clap from bar 6, sub from bar 5. The layers
// arrive one at a time on purpose: the film shows the room being built while
// the cell never changes, which IS the lesson.
export const KICK = [];
for (let b = 1; b < BARS; b++)
  for (let q = 0; q < 4; q++) KICK.push(n(b * 4 + q, 36, 0.25, 120));

export const HATS = [];
for (let b = 3; b < BARS; b++)
  for (let q = 0; q < 4; q++) HATS.push(n(b * 4 + q + 0.5, 42, 0.2, q % 2 ? 74 : 88));

export const CLAP = [];
for (let b = 5; b < BARS; b++) {
  CLAP.push(n(b * 4 + 1, 39, 0.25, 108));
  CLAP.push(n(b * 4 + 3, 39, 0.25, 108));
}

// ── the sub: a SINE, sustained, one note per bar from bar 5 ─────────────────
// A sine deliberately. A techno sub IS close to a sine, and a sine puts all of
// its energy at the fundamental — which makes the "below 100 Hz" measurement
// mean what it says instead of being smeared across harmonics. C1 is 32.70 Hz;
// under the fourth bar of the phrase it moves to G1, 49.00 Hz.
const C1 = 24, G1 = 31;
export const SUB = [];
for (let b = 4; b < BARS; b++)
  SUB.push(n(b * 4, (b % 4 === 3) ? G1 : C1, 3.95, 112));

// ── the strips ──────────────────────────────────────────────────────────────
// Volumes were chosen by probe.mjs so the two versions land within ~1.5 LU of
// each other — the comparison must not be a loudness trick. The first pass
// measured orch −17.54 LUFS against techno −20.92, so all three orchestral
// strips were multiplied by 0.759 (−2.4 dB). See NOTES.md.
const V = (k, d) => +(process.env[k] ?? d);

export const ORCH_NAMES = ["Violins", "Celli", "Basses"];
export const TECH_NAMES = ["Riff", "Kick", "Hats", "Clap", "Sub"];

export const PARTS = [
  { name: "Violins", group: "orch", instrument: sb(48),
    volume: V("B128_VVLN", 0.47), pan: -0.12, notes: VIOLINS },
  { name: "Celli", group: "orch", instrument: sb(42),
    volume: V("B128_VCEL", 0.55), pan: 0.10, notes: CELLI },
  { name: "Basses", group: "orch", instrument: sb(43),
    volume: V("B128_VBAS", 0.65), pan: 0, notes: BASSES },

  { name: "Riff", group: "tech",
    instrument: poly({ waveform: "saw", attack: 0.004, decay: 0.12,
                       sustain: 0.72, release: 0.08, cutoffHz: 2400,
                       resonance: 0.22, gain: 0.8 }),
    volume: V("B128_VRIF", 0.34), pan: 0, notes: RIFF },
  { name: "Kick", group: "tech", instrument: sb(0, { bankMSB: 120 }),
    volume: V("B128_VKIK", 0.80), pan: 0, notes: KICK },
  { name: "Hats", group: "tech", instrument: sb(0, { bankMSB: 120 }),
    volume: V("B128_VHAT", 0.42), pan: 0.18, notes: HATS },
  { name: "Clap", group: "tech", instrument: sb(0, { bankMSB: 120 }),
    volume: V("B128_VCLP", 0.55), pan: -0.15, notes: CLAP },
  { name: "Sub", group: "tech",
    instrument: poly({ waveform: "sine", attack: 0.01, decay: 0.05,
                       sustain: 1.0, release: 0.10, cutoffHz: 18000,
                       resonance: 0.0, gain: 0.9 }),
    volume: V("B128_VSUB", 0.62), pan: 0, notes: SUB },
];

export const NOTE_COUNT = PARTS.reduce((a, p) => a + p.notes.length, 0);
export const RIFF_NOTES = RIFF.length;
export const DRUM_HITS = KICK.length + HATS.length + CLAP.length;
export const SUB_NOTES = SUB.length;
