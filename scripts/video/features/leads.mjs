// LEAD PATCHES — data only, no wire calls, no side effects.
//
// ⛔ THIS MODULE EXISTS BECAUSE OF A NEAR-MISS. The patches started out inside
// `lead-options.mjs`, which is a SCRIPT: it opens the wire, calls project.new
// three times, renders three WAVs and then process.exit(0)s, all at top level.
// Importing `LEADS` from there — which is exactly what build.mjs wanted to do —
// would have executed every one of those as an import side effect: three
// projects destroyed and three renders written, silently, every time anything
// built an arrangement. An ES import is not a lookup; it RUNS the module.
//
// So the data lives here, where importing it does nothing at all, and both the
// comparison script and the film builder read it from one place.
//
// ---------------------------------------------------------------------------
// ⛔ WHY THESE EXIST AT ALL: the user heard the first film and said the lead
// "is cheap, like toy". The cause was not taste — the patch set EIGHT of the
// synth's TWENTY-FOUR parameters, and `unisonVoices` defaults to 1, so the lead
// was a single clean oscillator. No detune, no sub, no drift, no drive, no
// per-note jitter. No effect downstream fixes a one-oscillator source.
//
// Three candidates went out, one axis apart, same notes and same everything
// else. ⭐ THE USER PICKED A (supersaw).

export const LEADS = {
  // A — ⭐ CHOSEN. The sound most dance records actually use. Seven detuned
  // saws, wide, with a sub underneath.
  supersaw: {
    kind: "polySynth", waveform: "saw",
    unisonVoices: 7, unisonDetuneCents: 30, unisonStereoSpread: 0.85,
    subLevel: 0.28, subOctave: -1, subWaveform: "sine",
    cutoffHz: 5200, resonance: 0.22, keyToCutoff: 0.55, velocityToCutoff: 0.35,
    drive: 0.32, drift: 0.12, voiceJitter: 0.10, envelopeCurve: 0.45,
    attack: 0.006, decay: 0.28, sustain: 0.5, release: 0.28, gain: 0.62,
  },
  // B — fewer voices, more analog wobble, rounder. Warmer, less aggressive.
  analog: {
    kind: "polySynth", waveform: "saw",
    unisonVoices: 4, unisonDetuneCents: 16, unisonStereoSpread: 0.5,
    subLevel: 0.45, subOctave: -1, subWaveform: "triangle",
    cutoffHz: 2600, resonance: 0.3, keyToCutoff: 0.7, velocityToCutoff: 0.5,
    drive: 0.5, drift: 0.35, voiceJitter: 0.28, envelopeCurve: 0.2,
    noiseLevel: 0.05, noiseColor: 0.28,   // a NUMBER: 0 dark, 0.5 white, 1 hissy
    attack: 0.02, decay: 0.4, sustain: 0.62, release: 0.45, gain: 0.66,
  },
  // C — the whistle at the edge. resonanceBoost reaches a Q of 60, which is the
  // self-oscillating peak the user singled out in the effects demos. It went on
  // to become the VOICE of the cosmic piece, where it belongs better than here.
  resonant: {
    kind: "polySynth", waveform: "square",
    unisonVoices: 5, unisonDetuneCents: 22, unisonStereoSpread: 0.7,
    subLevel: 0.3, subOctave: -1, subWaveform: "sine",
    cutoffHz: 1700, resonance: 0.72, resonanceBoost: 0.55,
    keyToCutoff: 0.85, velocityToCutoff: 0.6,
    drive: 0.24, drift: 0.2, voiceJitter: 0.14, envelopeCurve: 0.6,
    attack: 0.008, decay: 0.5, sustain: 0.35, release: 0.35, gain: 0.5,
  },
};

export const CHOSEN = "supersaw";
