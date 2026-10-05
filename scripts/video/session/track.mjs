// THE TRACK. Everything the film has demonstrated, arranged into one piece.
// 128 bpm, 64 bars. Nothing here is a sample: every track is saw, square,
// triangle or sine, shaped by the filter, the envelope and the stock effects.
import { open, cmd, addTrack, addClip, n, rng, close } from "./build.mjs";

const AUD = process.env.SESSION_AUDIO || "./audio";
const PROJ = "~/Music/DAW Pro Lessons/Session — Four Waveforms.dawproj";
const B = 4;                                   // beats per bar
const bar = (i) => (i - 1) * B;                // 1-based bar -> beat

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 128 });

const fx = async (trackId, kind, params = {}) => {
  const r = await cmd("fx.add", { trackId, kind });
  const id = r.effectId || (r.effects && r.effects.at(-1).id);
  for (const [name, value] of Object.entries(params)) {
    const w = await cmd("fx.setParam", { trackId, effectId: id, name, value });
    if (w && w.warnings && w.warnings.length) console.log(`  ⚠ ${kind}.${name}:`, w.warnings[0]);
  }
  return id;
};

// ------------------------------------------------------------------- KICK
// A kick is a sine that falls in pitch. There is no pitch envelope here, so it
// is built the way the earliest drum machines did it: a very short low sine
// with a click on top, and a saturator to give it an edge.
const kick = await addTrack("Kick", { instrument: {
  kind: "polySynth", waveform: "sine",
  attack: 0.001, decay: 0.16, sustain: 0.0, release: 0.08,
  cutoffHz: 260, resonance: 0.0, gain: 1.0 } });
await fx(kick, "saturator", { driveDb: 26, mix: 0.7, outputDb: -3 });

const click = await addTrack("Kick click", { instrument: {
  kind: "polySynth", waveform: "square",
  attack: 0.0002, decay: 0.012, sustain: 0.0, release: 0.01,
  cutoffHz: 7000, resonance: 0.2, gain: 0.30 } });

// --------------------------------------------------------------------- HATS
// The rain experiment, put to work: very short high blips. It failed as noise
// and it succeeds as a hi-hat, because a hi-hat is allowed to be metallic.
const hats = await addTrack("Hats", { instrument: {
  kind: "polySynth", waveform: "square",
  attack: 0.0003, decay: 0.028, sustain: 0.0, release: 0.02,
  cutoffHz: 14000, resonance: 0.1, gain: 0.22 } });
await fx(hats, "eq", { highPassEnabled: 1, highPassFreq: 6000 });

// --------------------------------------------------------------------- BASS
const bass = await addTrack("Bass", { instrument: {
  kind: "polySynth", waveform: "saw",
  attack: 0.004, decay: 0.22, sustain: 0.55, release: 0.12,
  cutoffHz: 900, resonance: 0.28, gain: 0.55 } });

// ---------------------------------------------------------------- 808 SUB
const sub = await addTrack("808 sub", { instrument: {
  kind: "polySynth", waveform: "sine",
  attack: 0.002, decay: 1.6, sustain: 0.0, release: 1.2,
  cutoffHz: 700, resonance: 0.0, gain: 0.8 } });
await fx(sub, "saturator", { driveDb: 30, mix: 1.0, outputDb: 0 });

// --------------------------------------------------------------------- STAB
const stab = await addTrack("Stab", { instrument: {
  kind: "polySynth", waveform: "square",
  attack: 0.003, decay: 0.3, sustain: 0.15, release: 0.25,
  cutoffHz: 3200, resonance: 0.4, gain: 0.34 } });
await fx(stab, "delay", { sync: 1, division: 0.375, feedback: 0.32, mix: 0.28, highCutHz: 5200, pingPong: 1 });

// ---------------------------------------------------------------- THE VOICE
// Same trick as the vowel chapter: a saw through two narrow EQ peaks.
const voice = await addTrack("Voice", { instrument: {
  kind: "polySynth", waveform: "saw",
  attack: 0.06, decay: 0.3, sustain: 0.85, release: 0.5,
  cutoffHz: 6000, resonance: 0.05, gain: 0.30 } });
const voiceEq = await fx(voice, "eq", {
  peak1Enabled: 1, peak2Enabled: 1, peak1Q: 9, peak2Q: 9,
  peak1GainDb: 18, peak2GainDb: 16, peak1Freq: 730, peak2Freq: 1090,
  highPassEnabled: 1, highPassFreq: 110 });
await fx(voice, "reverb", { roomSize: 0.8, mix: 0.3, damping: 0.4, preDelayMs: 25 });

// ------------------------------------------------------------------- SIREN
const siren = await addTrack("Siren", { instrument: {
  kind: "polySynth", waveform: "saw",
  attack: 0.02, decay: 0.1, sustain: 0.95, release: 0.3,
  cutoffHz: 2600, resonance: 0.35, gain: 0.22 } });

console.log("tracks built");

// =====================================================================
// THE ARRANGEMENT. 64 bars: intro 1-8, groove 9-24, break 25-32,
// drop 33-48, outro 49-64.
// =====================================================================
const r = rng(128128);

// Kick — four to the floor from bar 5, out for the break.
const kickBeats = [];
for (let b = 5; b <= 64; b++) {
  if (b >= 25 && b <= 32) continue;
  for (let q = 0; q < 4; q++) kickBeats.push(bar(b) + q);
}
await addClip(kick, 0, bar(65), kickBeats.map(t => n(t, 36, 0.22, 122)), "Kick");
await addClip(click, 0, bar(65), kickBeats.map(t => n(t, 84, 0.01, 44)), "Click");

// Hats — offbeat eighths from bar 9, doubled to sixteenths in the drop.
const hatNotes = [];
for (let b = 9; b <= 64; b++) {
  if (b >= 25 && b <= 32) continue;
  const div = b >= 33 && b <= 48 ? 0.25 : 0.5;
  for (let t = div; t < 4; t += div * 2)
    hatNotes.push(n(bar(b) + t, 90 + Math.floor(r() * 8), 0.03, 40 + Math.floor(r() * 30)));
}
await addClip(hats, 0, bar(65), hatNotes, "Hats");

// Bass — an A minor riff, offbeat, the engine of the thing.
const RIFF = [0, 0, 3, 0, 7, 0, 3, 5];         // semitones over A
const bassNotes = [];
for (let b = 9; b <= 64; b++) {
  if (b >= 25 && b <= 32) continue;
  for (let i = 0; i < 8; i++)
    bassNotes.push(n(bar(b) + i * 0.5, 45 + RIFF[i], 0.42, i % 2 ? 78 : 104));
}
await addClip(bass, 0, bar(65), bassNotes, "Bass");

// 808 sub — one long note per two bars, following the harmony.
const HARM = [45, 45, 50, 43];                  // Am, Am, Dm, G
const subNotes = [];
for (let b = 33; b <= 64; b += 2)
  subNotes.push(n(bar(b), HARM[((b - 33) / 2) % 4] - 12, 7.0, 118));
await addClip(sub, 0, bar(65), subNotes, "808");

// Stab — a chord on the offbeat of 2 and 4.
const CH = { 45: [45,48,52], 50: [50,53,57], 43: [43,47,50] };
const stabNotes = [];
for (let b = 17; b <= 64; b++) {
  if (b >= 25 && b <= 32) continue;
  const root = HARM[Math.floor((b - 17) / 2) % 4];
  for (const off of [1.5, 3.5])
    for (const p of CH[root]) stabNotes.push(n(bar(b) + off, p + 12, 0.3, 74));
}
await addClip(stab, 0, bar(65), stabNotes, "Stab");

// Voice — the hook. Long notes over the break and the drop.
const voiceNotes = [];
for (let b = 25; b <= 32; b++) voiceNotes.push(n(bar(b), 57 + [0,0,5,3][(b-25)%4], 3.6, 96));
for (let b = 33; b <= 48; b += 2) voiceNotes.push(n(bar(b), 57 + [0,5,3,7][((b-33)/2)%4], 7.0, 88));
await addClip(voice, 0, bar(65), voiceNotes, "Voice");

// Siren — a riser into the drop, and one last wail at the end.
const sirenClip = await addClip(siren, bar(29), 16, [n(0, 69, 15.5, 92)], "Siren");
const bend = [];
for (let i = 0; i <= 155; i++) {
  const t = i / 10, ph = (t / 2) % 1, v = ph < 0.5 ? ph * 2 : 2 - ph * 2;
  bend.push({ beat: +t.toFixed(3), value: Math.round(8192 + 8191 * (-1 + 2 * v)) });
}
await cmd("clip.setControllerLane", { clipId: sirenClip, type: "pitchBend", points: bend });

console.log("arrangement written");

// ------------------------------------------------------------------ MARKERS
for (const [name, b] of [["Intro",1],["Groove",9],["Build",17],["Break",25],["Drop",33],["Outro",49]])
  await cmd("marker.add", { name, beat: bar(b) });

await cmd("project.save", { path: PROJ });
console.log("saved:", PROJ);
const ov = await cmd("project.overview", {});
console.log("tracks:", ov.tracks.length,
            "clips:", ov.tracks.reduce((a, t) => a + t.clips.length, 0),
            "notes:", kickBeats.length * 2 + hatNotes.length + bassNotes.length +
                      subNotes.length + stabNotes.length + voiceNotes.length + 1);
await close();
