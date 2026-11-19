#!/usr/bin/env node
// CHAPTER "the song" — an original modern pop verse built on camera, one layer
// at a time: an empty named project → our drum machine → bass and pad → a Lead
// track with the melody. A still after each step (debug.captureUI). Writes
// work/state.json and SAVES the project, so later phases OPEN it.
//
//   node build-song.mjs            build + shots
//   node build-song.mjs --no-shots build only (before screen recording:
//                                  editor cards cannot be closed)
// ⚠ ONE WIRE SCRIPT AT A TIME: this calls project.new.
import { writeFileSync, mkdirSync } from "node:fs";
import { open, close, cmd, silence, VOICE_HOME } from "./wire.mjs";
import { shot } from "./shoot.mjs";
import { TEMPO, SONG_BEATS, MELODY, LYRICS, PAD, BASS, DRUMS } from "./material.mjs";

const SHOTS = !process.argv.includes("--no-shots");
const WORK = `${VOICE_HOME}/work`;
mkdirSync(WORK, { recursive: true });
const PROJECT = `${WORK}/Voice Film 2026-10-11.dawproj`;
const snap = async (name, extra) => { if (SHOTS) await shot(name, extra); };
const idOf = (r) => r.id || r.track?.id || r.clip?.id;

await open();
try {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: TEMPO });
  const dev = await silence();
  console.log(`output: ${dev.name} — staging only`);
  await cmd("mixer.setMasterVolume", { volume: 1 });
  await cmd("ui.showMixer", { show: false });
  // Name the project by saving it once, empty: the title bar then reads it.
  await cmd("project.save", { path: PROJECT });
  await snap("s01-empty");

  // ---- drums: OUR drum machine (not a sampler of recordings) -------------
  const drums = idOf(await cmd("track.add", { kind: "instrument", name: "Drums" }));
  // ⚠ `drumKit` does NOT imply the kind (memory: a silent inaudible success),
  // so the kind is set explicitly, then the kit preset.
  await cmd("track.setInstrument", { trackId: drums, kind: "drumSynth" });
  const kit = await cmd("instrument.loadDrumPreset", { trackId: drums, name: "909" });
  console.log("kit:", JSON.stringify(kit).slice(0, 160));
  // ⚠ TWO-BAR PATTERN CLIPS, NOT ONE 11-BAR CLIP — and the reason is a product
  // defect, MEASURED 2026-10-11: the step grid on an 11-bar drum clip draws
  // 176 steps x 30 pt = 5280 pt in a 1440 pt window and pushes the WHOLE arrange
  // layout off screen (track list, lane names and editor header gone); the same
  // kit on a 2-bar clip lays out correctly (out/shots/probe/p01 vs p02). A
  // repeated 2-bar pattern is also how a beat is normally built.
  const beatClips = [];
  for (let at = 0; at < SONG_BEATS; at += 8) {
    const len = Math.min(8, SONG_BEATS - at);
    const notes = DRUMS.filter((n) => n.startBeat >= at && n.startBeat < at + len)
      .map((n) => ({ ...n, startBeat: n.startBeat - at }));
    beatClips.push(idOf(await cmd("clip.addMIDI", { trackId: drums, atBeat: at, lengthBeats: len, notes, name: len === 8 ? "Beat" : "End" })));
  }
  const beat = beatClips[0];
  // Drums at half level (−6 dB): at unity the sung mix measured +1.9 dBTP
  // (float render, peak +1.85 dBFS); at 0.5 it measures −16.9 LUFS / −1.1 dBTP
  // with the voice on top (out/renders/probe-song*.wav, loud.sh).
  await cmd("track.setVolume", { trackId: drums, volume: 0.5 });
  await snap("s02-drums");
  if (SHOTS) {
    await cmd("view.selectClip", { clipId: beat });
    await cmd("debug.stepSequencer", { mode: "steps" });
    await snap("s03-step-grid");
    const grid = await cmd("debug.stepSequencer", {});
    writeFileSync(`${WORK}/step-grid-echo.json`, JSON.stringify(grid, null, 2));
  }

  // ---- bass and pad -------------------------------------------------------
  const bass = idOf(await cmd("track.add", { kind: "instrument", name: "Bass" }));
  await cmd("track.setInstrument", { trackId: bass, soundBank: { source: "gm", program: 33 } });   // Electric Bass (finger)
  await cmd("clip.addMIDI", { trackId: bass, atBeat: 0, lengthBeats: SONG_BEATS, notes: BASS, name: "Bass" });
  const pad = idOf(await cmd("track.add", { kind: "instrument", name: "Pad" }));
  await cmd("track.setInstrument", { trackId: pad, soundBank: { source: "gm", program: 89 } });    // Pad 2 (warm)
  await cmd("track.setVolume", { trackId: pad, volume: 0.6 });
  await cmd("clip.addMIDI", { trackId: pad, atBeat: 0, lengthBeats: SONG_BEATS, notes: PAD, name: "Chords" });
  await snap("s04-band");

  // ---- the lead melody, on its own track ---------------------------------
  const lead = idOf(await cmd("track.add", { kind: "instrument", name: "Lead" }));
  await cmd("track.setInstrument", { trackId: lead, soundBank: { source: "gm", program: 4 } });    // Electric Piano 1
  const melody = idOf(await cmd("clip.addMIDI", { trackId: lead, atBeat: 0, lengthBeats: SONG_BEATS, notes: MELODY, name: "Lead melody" }));
  if (SHOTS) {
    await cmd("view.selectClip", { clipId: melody });
    await cmd("debug.stepSequencer", { mode: "notes" });
    await snap("s05-lead-roll", { selectClip: melody });
  }

  await cmd("project.save", { path: PROJECT });
  const state = { project: PROJECT, tempo: TEMPO, songBeats: SONG_BEATS,
                  tracks: { drums, bass, pad, lead }, clips: { beat, melody }, lyrics: LYRICS };
  writeFileSync(`${WORK}/state.json`, JSON.stringify(state, null, 2));
  console.log(JSON.stringify(state, null, 2));
} catch (err) {
  // ⛔ WITHOUT THIS, AN ERROR EXITS 0: the finally below calls process.exit,
  // which ends the process before Node reports the rejection. MEASURED
  // 2026-10-11: tune.mjs died after one still and printed "exit 0".
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
