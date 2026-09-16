// Build the project, capture the stills, render every audio example.
// ⚠ STAGING ONLY (17695) — build.mjs refuses 17600.
import fs from "node:fs";
import { open, cmd, shot, close, burst, SHOTS } from "../../session/build.mjs";
import * as M from "./material.mjs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/lessons/comma";
const A = `${HERE}/audio`;
const SINE = `${HERE}/media/sine440.wav`, SAW = `${HERE}/media/saw440.wav`;
const BPM = 120, B = (s) => s * 2;              // seconds -> beats at 120 BPM

// step -> MIDI pitch. The pitch NAME is the note the fifth lands on, so the
// piano roll draws the actual circle of fifths (A E B F# C# G# D# A# F C G D A)
// rather than a chromatic run that would contradict the narration.
const PITCH = M.WALK.map((w, k) => k === 12 ? 81 : 69 + Math.round(w.cents / 100));
// rootPitch === the zone's own pitch, so keymap varispeed is exactly 1 and
// tuneCents is the ONLY thing setting the frequency.
const walkZones = M.WALK.map((w, k) => ({
  path: SINE, rootPitch: PITCH[k], minPitch: PITCH[k], maxPitch: PITCH[k],
  tuneCents: w.cents,
}));
// ⭐ A 14TH ZONE AT PITCH 82, TUNED TO EXACTLY ZERO — a SECOND A 440.
// It exists so the beating demo has a properly controlled "before": two tones
// of the same timbre at the same level, differing ONLY by the comma. A control
// made of ONE tone would differ in level and in tone count as well as in
// tuning, and then the A/B would not isolate the thing the film is about.
// ⚠ AND IT STARTS A QUARTER OF A CYCLE LATE. Two PHASE-COHERENT copies of the
// same sine sum to +6 dB, while a beating pair averages +3 — so a naive control
// renders 3.0 LU LOUDER than the demo and the viewer hears "the in-tune one is
// louder", which is an artefact of perfect coherence and not a fact about
// tuning. 27 frames is a quarter period at 440 Hz (48000/440/4 = 27.27), i.e.
// 90 degrees, the exact offset at which two equal sines have the same RMS as a
// beating pair. MEASURED: it lands the two halves within 0.1 LU.
walkZones.push({ path: SINE, rootPitch: 82, minPitch: 82, maxPitch: 82,
                 tuneCents: 0, startFrame: 27 });
// ⭐ THE SAME THIRTEEN STEPS IN EQUAL TEMPERAMENT, so the film can PLAY the fix
// as well as draw it: every fifth is exactly 700 cents, so step twelve lands on
// 8400 cents = seven whole octaves = 0 within the octave — the same A it
// started on, audibly, with no beating against it.
const etZones = M.WALK.map((w, k) => ({
  path: SINE, rootPitch: PITCH[k], minPitch: PITCH[k], maxPitch: PITCH[k],
  tuneCents: (k * 700) % 1200,
}));
const oneZone = (path, cents) => [{ path, rootPitch: 69, minPitch: 0, maxPitch: 127,
                                    tuneCents: cents }];

const R = {};                                    // renders, by name
async function bounce(name, fromBeat, seconds, keep, all) {
  const exclude = all.filter((t) => !keep.includes(t));
  const r = await cmd("render.bounce", { path: `${A}/${name}.wav`, fromBeat,
                                         durationSeconds: seconds,
                                         excludeTrackIds: exclude });
  R[name] = { path: `${A}/${name}.wav`, fromBeat, seconds,
              lufs: r.report?.output?.integratedLufs,
              truePeak: r.report?.output?.truePeakDbtp };
  console.log(`  render ${name}: ${seconds}s  ${R[name].lufs?.toFixed(2)} LUFS`);
}

await open();
await cmd("project.new", { discardChanges: false });
await cmd("transport.setTempo", { bpm: BPM });

const mk = async (name, zones, vol) => {
  const t = await cmd("track.add", { kind: "instrument", name });
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument", { trackId: id, kind: "sampler",
    sampler: { zones, attack: 0.02, release: 0.08, gain: 0.8 } });
  if (vol !== undefined) await cmd("track.setVolume", { trackId: id, volume: vol });
  return id;
};

// ⚠ ONE SHARED VOLUME on every tone track. The whole film is a comparison of
// BEAT DEPTH between renders; a per-track level tweak would change the depth
// of the very thing being measured.
const V = 0.5;
const tones = await mk("Pure tones", walkZones, V);
const etones = await mk("Tempered tones", etZones, V);
const root = await mk("Root A", oneZone(SAW, 0), V);
const f5p = await mk("Fifth pure", oneZone(SAW, M.FIFTH_PURE), V);
const f5e = await mk("Fifth tempered", oneZone(SAW, M.FIFTH_ET), V);
const m3p = await mk("Third pure", oneZone(SAW, M.THIRD_PURE), V);
const m3e = await mk("Third tempered", oneZone(SAW, M.THIRD_ET), V);
const ALL = [tones, etones, root, f5p, f5e, m3p, m3e];

// ---- clips ------------------------------------------------------------
const STEP = 3;                                  // beats per walk note = 1.5 s
const walkNotes = PITCH.map((p, k) => ({ startBeat: k * STEP, pitch: p,
                                         lengthBeats: STEP, velocity: 100 }));
const walkClip = await cmd("clip.addMIDI", { trackId: tones, atBeat: 0,
  lengthBeats: 13 * STEP, notes: walkNotes, name: "Twelve fifths" });
const etWalkClip = await cmd("clip.addMIDI", { trackId: etones, atBeat: 0,
  lengthBeats: 13 * STEP, notes: walkNotes, name: "Twelve tempered fifths" });
const SOLO_BEAT = 48, UNI_BEAT = 80, BEAT_BEAT = 112, PAIR_BEAT = 144, HOLD = B(12);
const soloClip = await cmd("clip.addMIDI", { trackId: tones, atBeat: SOLO_BEAT,
  lengthBeats: HOLD, notes: [{ startBeat: 0, pitch: 69, lengthBeats: HOLD, velocity: 100 }],
  name: "A 440 alone" });
const uniClip = await cmd("clip.addMIDI", { trackId: tones, atBeat: UNI_BEAT,
  lengthBeats: HOLD, name: "Two As in tune",
  notes: [{ startBeat: 0, pitch: 69, lengthBeats: HOLD, velocity: 100 },
          { startBeat: 0, pitch: 82, lengthBeats: HOLD, velocity: 100 }] });
const beatClip = await cmd("clip.addMIDI", { trackId: tones, atBeat: BEAT_BEAT,
  lengthBeats: HOLD, name: "A against A",
  notes: [{ startBeat: 0, pitch: 69, lengthBeats: HOLD, velocity: 100 },
          { startBeat: 0, pitch: 81, lengthBeats: HOLD, velocity: 100 }] });
for (const t of [root, f5p, f5e, m3p, m3e])
  await cmd("clip.addMIDI", { trackId: t, atBeat: PAIR_BEAT, lengthBeats: HOLD,
    notes: [{ startBeat: 0, pitch: 69, lengthBeats: HOLD, velocity: 100 }] });

// ---- renders ----------------------------------------------------------
await bounce("walk", 0, 20.0, [tones], ALL);
await bounce("walk-et", 0, 20.0, [etones], ALL);
await bounce("single", SOLO_BEAT, 12.0, [tones], ALL);
await bounce("unison", UNI_BEAT, 12.0, [tones], ALL);
await bounce("comma", BEAT_BEAT, 12.0, [tones], ALL);
await bounce("saw-alone", PAIR_BEAT, 12.0, [root], ALL);
await bounce("fifth-pure", PAIR_BEAT, 12.0, [root, f5p], ALL);
await bounce("fifth-et", PAIR_BEAT, 12.0, [root, f5e], ALL);
await bounce("third-pure", PAIR_BEAT, 12.0, [root, m3p], ALL);
await bounce("third-et", PAIR_BEAT, 12.0, [root, m3e], ALL);

// ---- stills -----------------------------------------------------------
fs.mkdirSync(SHOTS, { recursive: true });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
await cmd("transport.seek", { beats: 0 });
await shot("arrange");
await cmd("debug.panelLayout", { editorFraction: 0.55, pianoRollPPB: 26,
                                 pianoRollRowHeight: 13, pianoRollMinimap: true });
await cmd("debug.captureUI", { path: `${SHOTS}/roll-walk.png`,
                               selectClip: walkClip.id || walkClip.clip?.id });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 75 });
await shot("roll-walk");
await cmd("debug.captureUI", { path: `${SHOTS}/roll-beat.png`,
                               selectClip: beatClip.id || beatClip.clip?.id });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 75 });
await shot("roll-beat");
await cmd("ui.showMixer", { show: true });
await shot("mixer");
await cmd("ui.showMixer", { show: false });

// The sampler card, showing the TUNE control that does all the work in this
// film. ⚠ THE ZONE MUST BE SELECTED: with no `zoneId` the card reads "Pick a
// zone above to tune its pitch" and the tune readout is not on screen at all —
// the first cut of this film shot it that way and the still was useless.
// ⚠ NEITHER debug.samplerEditor's state response NOR instrument.describeSampler
// carries zone ids (describe returns a zoneSummary and no per-zone array).
// project.snapshot is the only read path to one.
for (const [nm, tid] of [["fifth", f5p], ["fifthet", f5e],
                         ["third", m3p], ["thirdet", m3e]]) {
  const snap = await cmd("project.snapshot", {});
  const zid = snap.tracks.find((t) => t.id === tid)?.instrument?.sampler?.zones?.[0]?.id;
  await cmd("debug.samplerEditor", { trackId: tid, open: true });
  const st = await cmd("debug.samplerEditor", { zoneId: zid });
  if (st.selectedZoneId !== zid) throw new Error(`zone not selected for ${nm}`);
  await shot(`sampler-${nm}`);
}
await cmd("debug.samplerEditor", { close: true });

// ---- bursts (the transport actually running) --------------------------
process.env.SESSION_BURSTS = `${HERE}/bursts`;
await burst("walkplay", 20.0, 0);
await burst("beatplay", 12.0, BEAT_BEAT);

await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
fs.writeFileSync(`${HERE}/renders.json`, JSON.stringify(
  { bpm: BPM, pitches: PITCH, renders: R,
    tracks: { tones, etones, root, f5p, f5e, m3p, m3e },
    beats: { solo: SOLO_BEAT, unison: UNI_BEAT, comma: BEAT_BEAT, pair: PAIR_BEAT },
    clips: { walk: walkClip.id, walkET: etWalkClip.id, solo: soloClip.id, unison: uniClip.id,
             beat: beatClip.id } }, null, 1));
console.log("wrote renders.json");
close(); process.exit(0);
