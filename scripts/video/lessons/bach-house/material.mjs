// The material for "Bach House" — every note the film plays, derived in ONE
// place so probe/shoot/measure/spec can never disagree about what was built.
//
// ⭐ THE PIANO PART IS NOT MINE. bars1-8.json is the first eight measures of
// J. S. Bach's Prelude in C, BWV 846, parsed out of a public MusicXML encoding
// of the score (music21's corpus, `bach/bwv846.mxl`, a MuseScore transcription)
// by parse846.py. Onsets, pitches and written durations come straight from it.
// The COMPOSITION is public domain; nothing here is a recording of anyone
// playing it — the app's sampler plays this note list.
//
// ⚠ THE ONE THING THE FILM MAY NOT CLAIM: that the piano part is "untouched"
// in every respect. It is untouched in PITCH and in ONSET; the note LENGTHS
// are the score's written durations, and what a pianist's pedal does to them
// is not encoded. Say pitches and onsets, never "exactly as performed".
import { n } from "../../session/build.mjs";
import fs from "node:fs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/lessons/bach-house";
export const BARS8 = JSON.parse(fs.readFileSync(`${HERE}/bars1-8.json`, "utf8"));

// There is NO tempo marking in BWV 846. 72 is a common performance tempo and
// it is MY choice; the film says so out loud rather than attributing it to Bach.
export const BPM_BACH = 72;
export const BPM_HOUSE = 124;
export const BARS = 16;                        // the 8-bar phrase, twice
export const LEN_BEATS = BARS * 4;             // 64
export const SECS_HOUSE = LEN_BEATS * 60 / BPM_HOUSE;   // 30.968
export const SECS_8BARS_HOUSE = 32 * 60 / BPM_HOUSE;    // 15.484
export const SECS_8BARS_BACH  = 32 * 60 / BPM_BACH;     // 26.667

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const sb = (program, extra = {}) =>
  ({ kind: "soundBank", soundBank: { source: GUGS, program, ...extra } });
const poly = (p) => ({ kind: "polySynth", ...p });

// ── the piano: the eight bars, twice ────────────────────────────────────────
export const PIANO = [];
for (let pass = 0; pass < 2; pass++)
  for (let bar = 1; bar <= 8; bar++)
    for (const [start, pitch, len] of BARS8[String(bar)])
      PIANO.push(n(pass * 32 + (bar - 1) * 4 + start, pitch, len, 96));

// per-bar facts, measured off the note list rather than typed
export const BAR_PITCHES = [];                 // ascending unique pitches, bar 1..8
export const BAR_ONSETS = [];                  // sorted unique onsets within the bar
for (let bar = 1; bar <= 8; bar++) {
  const b = BARS8[String(bar)];
  BAR_PITCHES.push([...new Set(b.map((x) => x[1]))].sort((a, z) => a - z));
  BAR_ONSETS.push([...new Set(b.map((x) => +x[0].toFixed(4)))].sort((a, z) => a - z));
}
export const ROOTS = BAR_PITCHES.map((ps) => ps[0]);   // the lowest note Bach wrote

// ── the house layers ────────────────────────────────────────────────────────
// Entries are staggered so the film can play the room being built while the
// prelude never changes: kick bar 3, hats bar 5, clap bar 7, bass bar 9.
export const ENTRY = { kick: 3, hats: 5, clap: 7, bass: 9 };

export const KICK = [];
for (let b = ENTRY.kick - 1; b < BARS; b++)
  for (let q = 0; q < 4; q++) KICK.push(n(b * 4 + q, 36, 0.25, 120));

export const HATS = [];
for (let b = ENTRY.hats - 1; b < BARS; b++)
  for (let q = 0; q < 4; q++)
    HATS.push(n(b * 4 + q + 0.5, 42, 0.2, q % 2 ? 104 : 124));

export const CLAP = [];
for (let b = ENTRY.clap - 1; b < BARS; b++) {
  CLAP.push(n(b * 4 + 1, 39, 0.25, 106));
  CLAP.push(n(b * 4 + 3, 39, 0.25, 106));
}

// ⭐ THE BASS PLAYS BACH'S OWN LOWEST NOTE OF EACH BAR, two octaves down, on
// the offbeats — the gaps the kick leaves. Bars 1-8 give C C B C C C B B: the
// opening of the prelude is a pedal point, which is exactly what a house
// bassline is. Nothing here is invented harmony.
export const BASS_DROP = 24;
export const BASS = [];
for (let b = ENTRY.bass - 1; b < BARS; b++) {
  const root = ROOTS[b % 8] - BASS_DROP;
  for (let q = 0; q < 4; q++) BASS.push(n(b * 4 + q + 0.5, root, 0.42, 108));
}

const V = (k, d) => +(process.env[k] ?? d);

export const PARTS = [
  // ⛔⛔ NOT A SOUNDFONT PIANO, AND THIS IS A MEASUREMENT, NOT A PREFERENCE.
  // MEASURED on staging 2026-09-05: the GeneralUser GS sound-bank path DROPS
  // OUT on this material. The identical 288-note clip, rendered three ways over
  // the same eight bars, gave per-bar RMS of
  //   soundBank, notes as written : -5.1 -27.4 -19.2 -69.1 -6.1 -10.0 -27.2 -19.1
  //   soundBank, notes shortened  : -5.7 -33.3 -63.0 -84.5 -6.5 -12.6 -53.5 -76.3
  //   built-in polySynth          : -15.8 -15.7 -15.8 -15.7 -15.7 -15.7 -15.7 -15.1
  // Bars 1 and 4 hold the SAME five pitches, so a 14-64 dB difference between
  // them cannot be the music. Shortening the notes (to remove every same-pitch
  // abuttal) made it worse, which rules out the documented note-off pairing
  // hazard as the whole story. The synth is even to 0.7 dB across eight bars.
  // measure.py now REFUSES a build whose piano bars spread by more than 6 dB.
  //
  // The patch is a plucked saw: fast attack, long decay, low sustain — an
  // electric-piano/house-arp voice rather than an imitation grand. The film
  // says out loud that this is a synthesiser playing Bach's notes, not a
  // recording of a piano, which is true and is also the honest provenance line.
  { name: "Prelude", instrument:
      poly({ waveform: "saw", attack: 0.003, decay: 0.45, sustain: 0.18,
             release: 0.35, cutoffHz: 3200, resonance: 0.15, gain: 0.8 }),
    volume: V("BH_VPNO", 0.8), pan: 0, notes: PIANO },
  { name: "Kick", instrument: sb(0, { bankMSB: 120 }),
    volume: V("BH_VKIK", 0.8), pan: 0, notes: KICK },
  { name: "Hats", instrument: sb(0, { bankMSB: 120 }),
    volume: V("BH_VHAT", 0.8), pan: 0.16, notes: HATS },
  { name: "Clap", instrument: sb(0, { bankMSB: 120 }),
    volume: V("BH_VCLP", 0.8), pan: -0.14, notes: CLAP },
  { name: "Bass", instrument:
      poly({ waveform: "saw", attack: 0.004, decay: 0.09, sustain: 0.55,
             release: 0.06, cutoffHz: 520, resonance: 0.12, gain: 0.85 }),
    volume: V("BH_VBAS", 0.8), pan: 0, notes: BASS },
];

export const COUNTS = {
  piano: PIANO.length, kick: KICK.length, hats: HATS.length,
  clap: CLAP.length, bass: BASS.length,
  bars8: Object.values(BARS8).reduce((a, v) => a + v.length, 0),
};
