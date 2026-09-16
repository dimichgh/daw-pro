// The MIX this lesson masters. Written by hand, note by note — no generation
// model, per the lesson-material rule. Shared by probe.mjs and shoot.mjs so the
// thing that was measured and the thing that was filmed cannot drift apart.
//
// WHY IT IS SHAPED THE WAY IT IS. A mastering lesson about clipping needs a mix
// whose CREST FACTOR is real: the film's whole premise is that the gain needed
// to reach −14 LUFS pushes the peak past 0 dBFS, and that only happens if the
// peaks stand well above the average. So:
//
//   * a real drum kit with real transients (kick/snare/hat), not a synth blip;
//   * an arrangement that BUILDS — pad+bass, then drums, then lead —
//     which is where the loudness RANGE comes from, and loudness range is the
//     thing the film measures being destroyed;
//   * sound-bank instruments (GeneralUser-GS), because a lesson has to be
//     exactly the thing being taught.
import { n } from "../../session/build.mjs";

export const BPM = 100;                    // 1 bar = 2.4 s
export const BARS = 16;
export const LEN_BEATS = BARS * 4;          // 64 beats
export const SECS = LEN_BEATS * (60 / BPM); // 38.4 s

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const sb = (program, extra = {}) =>
  ({ kind: "soundBank", soundBank: { source: GUGS, program, ...extra } });

// ── harmony: Am · F · C · G, one bar each, four times through ───────────────
const CHORDS = [
  { pad: [57, 60, 64], bass: 33, fifth: 40 },   // Am : A3 C4 E4 / A1
  { pad: [53, 57, 60], bass: 29, fifth: 36 },   // F  : F3 A3 C4 / F1
  { pad: [60, 64, 67], bass: 36, fifth: 43 },   // C  : C4 E4 G4 / C2
  { pad: [55, 59, 62], bass: 31, fifth: 38 },   // G  : G3 B3 D4 / G1
];
const chordAt = (bar) => CHORDS[bar % 4];

// ── pad: whole-bar chords, all 16 bars ─────────────────────────────────────
const pad = [];
for (let b = 0; b < BARS; b++) {
  const v = b < 2 ? 74 : b < 4 ? 82 : 90;
  for (const p of chordAt(b).pad) pad.push(n(b * 4, p, 3.9, v));
}

// ── bass: all 16 bars. Root on 1 and 2.5, fifth on 4, root octave on 4.5 ────
const bass = [];
for (let b = 0; b < BARS; b++) {
  const c = chordAt(b);
  const v = b < 2 ? 88 : 104;
  bass.push(n(b * 4 + 0.0, c.bass, 0.9, v));
  bass.push(n(b * 4 + 1.5, c.bass, 0.45, v - 12));
  bass.push(n(b * 4 + 2.0, c.bass, 0.9, v - 4));
  bass.push(n(b * 4 + 3.0, c.fifth, 0.45, v - 10));
  bass.push(n(b * 4 + 3.5, c.bass, 0.45, v - 6));
}

// ── drums: from bar 3 (index 2). GM percussion map. ──────────────────────────────────
//    36 kick · 38 snare · 42 closed hat · 46 open hat · 49 crash
const drums = [];
for (let b = 2; b < BARS; b++) {
  const o = b * 4;
  drums.push(n(o + 0, 36, 0.25, 118));
  drums.push(n(o + 1, 38, 0.25, 112));
  drums.push(n(o + 2.5, 36, 0.25, 110));
  drums.push(n(o + 3, 38, 0.25, 114));
  if (b % 4 === 3) drums.push(n(o + 3.5, 38, 0.25, 100));   // a fill push
  for (let e = 0; e < 8; e++) {
    const open = e === 7 && b % 4 === 3;
    drums.push(n(o + e * 0.5, open ? 46 : 42, 0.2, e % 2 ? 72 : 88));
  }
  if (b % 8 === 2) drums.push(n(o, 49, 1.5, 112));           // crash on the lift
}

// ── lead: from bar 9 (beat 32), A-minor pentatonic, phrased over two bars ────────────
const LEAD = [
  [0.0, 69, 0.9], [1.0, 72, 0.45], [1.5, 71, 0.45], [2.0, 69, 1.4],
  [4.0, 67, 0.9], [5.0, 69, 0.45], [5.5, 72, 0.45], [6.0, 71, 1.9],
  [8.0, 76, 0.9], [9.0, 74, 0.45], [9.5, 72, 0.45], [10.0, 69, 1.4],
  [12.0, 71, 0.9], [13.0, 72, 0.45], [13.5, 74, 0.45], [14.0, 76, 1.9],
];
const lead = LEAD.map(([o, p, l]) => n(32 + o, p, l, 104));

export const NOTE_COUNT = pad.length + bass.length + drums.length + lead.length;

export const PARTS = [
  { name: "Pad",   instrument: sb(89), volume: +(process.env.C14_VPAD ?? 0.088), pan: 0,     notes: pad },
  { name: "Bass",  instrument: sb(33), volume: +(process.env.C14_VBASS ?? 0.44), pan: 0,     notes: bass },
  { name: "Drums", instrument: sb(0, { bankMSB: 120 }), volume: +(process.env.C14_VDRUM ?? 1.04), pan: 0, notes: drums },
  { name: "Lead",  instrument: sb(81), volume: +(process.env.C14_VLEAD ?? 0.068), pan: 0.15,  notes: lead },
];

// MEASURED at these volumes (probe2.mjs, render.bounce per stem):
//   FULL  -20.48 LUFS  peak -2.19 dBTP  LRA 3.63
//   Pad   -27.85   Bass -28.40   Drums -20.98   Lead -24.05  (integrated, alone)
// The peak-to-loudness ratio of 18.3 dB is the number the whole film depends
// on: it is what makes +6.5 dB of gain land the peak ABOVE 0 dBFS.
