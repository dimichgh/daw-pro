// Shoot the PIANO ROLL — the one screen the first cut of the film never showed.
//
// ⚠ `debug.selectClip` does not exist on this build, and that is what silently
// cost the film its note-editor shot: capture.mjs wraps the step, prints that it
// skipped, and everything else carries on. The way in without that command is
// the app's own dev affordance — launch it with DAW_DEBUG_OPEN_PIANOROLL=1 and
// the roll opens by itself on the first MIDI clip that appears:
//
//   DAWPRO_PROFILE_ROOT=$PWD/out/profile DAW_DEBUG_OPEN_PIANOROLL=1 \
//   DAW_CONTROL_PORT=17695 .build/debug/DAWApp &
//   DAW_CONTROL_PORT=17695 node pianoshot.mjs
//
// Four bars of the real riff, not sixteen: the roll has to be READ at a glance.
import { open, cmd, shot, close, n, SHOTS } from "./build.mjs";
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 128 });
const t = await cmd("track.add", { kind: "instrument", name: "Bass" });
const id = t.id || t.track?.id;
await cmd("track.setInstrument", { trackId: id, kind: "polySynth",
  waveform: "saw", attack: 0.004, decay: 0.22, sustain: 0.55, release: 0.12,
  cutoffHz: 900, resonance: 0.28, gain: 0.55 });

const RIFF = [0, 0, 3, 0, 7, 0, 3, 5];        // semitones over A, as track.mjs
const notes = [];
for (let b = 0; b < 4; b++)
  for (let i = 0; i < 8; i++)
    notes.push(n(b * 4 + i * 0.5, 45 + RIFF[i], 0.42, i % 2 ? 78 : 104));
const clip = await cmd("clip.addMIDI",
  // ⚠ NO `returnNotes` — that is the MCP tool's parameter. The WIRE refuses it.
  { trackId: id, atBeat: 0, lengthBeats: 16, name: "Bass", notes });
console.log("clip:", clip.id || clip.clip?.id, "notes:", notes.length);

// The roll opens ITSELF (the env var), so all that is left is to give it room.
await cmd("debug.panelLayout", { editorMaximized: true });
await shot("pianoroll-bass");
console.log("shot ->", `${SHOTS}/pianoroll-bass.png`);
await cmd("debug.panelLayout", { editorMaximized: false });
await close();
