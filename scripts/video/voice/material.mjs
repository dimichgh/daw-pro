// material.mjs — ALL the musical data for the voice film. DATA ONLY: no wire
// calls, no top-level effects (an ES import RUNS a module; a data file that
// opened the socket would rebuild the project every time something imported it).
//
// ⛔ THE USER'S RULING (2026-10-11, relayed by the orchestrator): "do not use
// twinke or row your bot song, create a modern style song and create lead
// melody and then appy lyrics to the lead track notes". So this is an ORIGINAL
// song — melody, chords and words written for this film. The nursery-tune
// first attempt is kept in ../out-superseded-2026-10-11-twinkle/ and is not used.
//
// "Light On" — D major, 100 BPM, 4/4. A modern pop verse: vi–IV–I–V
// (Bm G D A), syncopated eighths, each line landing on a held note.
//
// ⭐ THE KEY IS CHOSEN FROM A MEASUREMENT. sing.listVoices (2026-10-11) puts the
// built-in singer at p10 61.7 / median 65.9 / p90 68.7 (D4 / F#4 / A4). The
// melody lives D4–A4 with ONE B4 at the lift of line 3.

export const TEMPO = 100;          // a beat = 0.6 s
export const INTRO_BARS = 2;       // drums + bass + pad before the voice
export const BARS = 11;            // 2 intro + 8 sung + 1 ending
export const SONG_BEATS = BARS * 4;

const D4 = 62, E4 = 64, Fs4 = 66, G4 = 67, A4 = 69, B4 = 71;

// One line = 2 bars. Eight syllables on the iambic stresses:
//   w   S   w   S       w   S(held over the bar)   w   S(held)
//   .5  1  1.5  2       3   3.5                    4.5 5 → 6.9
const RHYTHM = [[0.5, 0.45], [1.0, 0.45], [1.5, 0.45], [2.0, 0.9],
                [3.0, 0.45], [3.5, 0.9], [4.5, 0.45], [5.0, 1.9]];
const LINES = [
  [Fs4, Fs4, E4, Fs4, A4, Fs4, E4, D4],    // I left the light on by the door
  [D4, Fs4, Fs4, A4, Fs4, E4, D4, E4],     // in case you wan-der home to-night
  [Fs4, A4, A4, B4, G4, A4, G4, Fs4],      // the ci-ty hums a song for two
  [Fs4, A4, Fs4, E4, D4, E4, Fs4, D4],     // and ev-ery win-dow's burn-ing bright
];

export const MELODY = LINES.flatMap((pitches, line) => pitches.map((pitch, i) => {
  const [at, len] = RHYTHM[i];
  // the last note of the song holds into the ending bar (a sus4 over A that
  // resolves when the D chord arrives)
  const last = line === 3 && i === 7;
  return { pitch, startBeat: INTRO_BARS * 4 + line * 8 + at, lengthBeats: last ? 2.4 : len, velocity: 96 };
}));

export const LYRICS = [
  "I left the light on by the door,",
  "in case you wan-der home to-night.",
  "The ci-ty hums a song for two,",
  "and ev-ery win-dow's burn-ing bright.",
].join("\n");

// ---- the band ---------------------------------------------------------------
// Chords per bar (root MIDI in octave 3, quality). Intro: Bm G. Then the
// four-line verse, then D to end.
const B2 = 47, G2 = 43, D3 = 50, A2 = 45;
const BAR_CHORDS = [
  ["Bm", B2], ["G", G2],                       // intro
  ["Bm", B2], ["G", G2], ["D", D3], ["A", A2], // lines 1-2
  ["Bm", B2], ["G", G2], ["D", D3], ["A", A2], // lines 3-4
  ["D", D3],                                   // ending
];
// Close voicings in octave 3, all UNDER the voice (D4 up), smooth common tones.
const VOICING = {
  Bm: [50, 54, 59],   // D3 F#3 B3
  G:  [50, 55, 59],   // D3 G3 B3
  D:  [50, 54, 57],   // D3 F#3 A3
  A:  [49, 52, 57],   // C#3 E3 A3
};

export const PAD = BAR_CHORDS.flatMap(([name], bar) =>
  VOICING[name].map((pitch) => ({ pitch, startBeat: bar * 4, lengthBeats: bar === BARS - 1 ? 3.5 : 3.95, velocity: 70 })));

// Bass: root on the beat, a push on the "and" of 2, root again on 3, eighth
// pickup into the next bar — a plain modern-pop bass.
export const BASS = BAR_CHORDS.flatMap(([, root], bar) => {
  const b = bar * 4;
  const r = root - 12;   // bass register: G1..D2
  if (bar === BARS - 1) return [{ pitch: r, startBeat: b, lengthBeats: 3.5, velocity: 96 }];
  return [
    { pitch: r, startBeat: b, lengthBeats: 1.4, velocity: 100 },
    { pitch: r, startBeat: b + 1.5, lengthBeats: 0.45, velocity: 84 },
    { pitch: r, startBeat: b + 2, lengthBeats: 1.4, velocity: 96 },
    { pitch: r + 7, startBeat: b + 3.5, lengthBeats: 0.45, velocity: 84 },
  ];
});

// Drums: our own drum machine. Voices measured at DrumKit.swift (36..43, the
// pad-grid base; see features/arrange.mjs): kick 36, snare 37, closed hat 38,
// open hat 39, clap 40.
const KICK = 36, SNARE = 37, CHAT = 38, OHAT = 39, CLAP = 40;
export const DRUMS = (() => {
  const out = [];
  for (let bar = 0; bar < BARS; bar++) {
    const b = bar * 4;
    if (bar === BARS - 1) { out.push({ pitch: KICK, startBeat: b, lengthBeats: 0.25, velocity: 110 }); break; }
    for (const k of [0, 1.5, 2.5]) out.push({ pitch: KICK, startBeat: b + k, lengthBeats: 0.25, velocity: k === 0 ? 112 : 96 });
    for (const s of [1, 3]) {
      out.push({ pitch: SNARE, startBeat: b + s, lengthBeats: 0.25, velocity: 104 });
      out.push({ pitch: CLAP, startBeat: b + s, lengthBeats: 0.25, velocity: 88 });
    }
    for (let e = 0; e < 8; e++) {
      if (e === 7 && bar % 2 === 1) { out.push({ pitch: OHAT, startBeat: b + 3.5, lengthBeats: 0.5, velocity: 80 }); continue; }
      out.push({ pitch: CHAT, startBeat: b + e * 0.5, lengthBeats: 0.25, velocity: e % 2 === 0 ? 90 : 70 });
    }
  }
  return out;
})();
