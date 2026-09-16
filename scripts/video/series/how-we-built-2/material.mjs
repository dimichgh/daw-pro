#!/usr/bin/env node
// Build the DEMO PROJECT this film is shot on, entirely over the control
// socket -- which is itself one of the film's claims, so the build script IS a
// piece of evidence. Hand-written notes only: no generation model is used for
// anything a viewer sees or hears (house rule for lesson material).
//
// ⚠ STAGING ONLY. DAW_CONTROL_PORT=17695 is asserted below; 17600 is the
// user's live app and this script refuses to run against it.
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const PORT = process.env.DAW_CONTROL_PORT;
if (PORT !== "17695") { console.error("REFUSING: DAW_CONTROL_PORT must be 17695 (staging)"); process.exit(1); }
const DAWCTL = "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";
const BANK = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";

function send(cmd, params) {
  const r = spawnSync("node", [DAWCTL, cmd, JSON.stringify(params ?? {})],
                      { encoding: "utf8", env: process.env, maxBuffer: 64e6 });
  if (r.status !== 0) { console.error(cmd, r.stdout, r.stderr); process.exit(1); }
  try { return JSON.parse(r.stdout); } catch { return r.stdout; }
}

// ── the material: eight bars, C minor, i - VI - III - VII ──────────────────
const BARS = 8, BEATS = BARS * 4;
const CHORDS = [                       // one per bar, repeating every four
  { name: "Cm", root: 36, notes: [48, 51, 55] },
  { name: "Ab", root: 32, notes: [44, 48, 51] },
  { name: "Eb", root: 39, notes: [51, 55, 58] },
  { name: "Bb", root: 34, notes: [46, 50, 53] },
];
const n = (pitch, startBeat, lengthBeats, velocity) => ({ pitch, startBeat, lengthBeats, velocity });

const drums = [];
for (let b = 0; b < BARS; b++) {
  const t = b * 4;
  drums.push(n(36, t, 0.5, 110), n(36, t + 2.5, 0.5, 100));       // kick
  drums.push(n(38, t + 1, 0.5, 104), n(38, t + 3, 0.5, 108));     // snare
  for (let i = 0; i < 8; i++)                                      // hats
    drums.push(n(i === 7 && b % 4 === 3 ? 46 : 42, t + i * 0.5, 0.25, i % 2 ? 62 : 82));
}
const bass = [], keys = [], pad = [];
for (let b = 0; b < BARS; b++) {
  const c = CHORDS[b % 4], t = b * 4;
  bass.push(n(c.root, t, 1.0, 104), n(c.root, t + 1.5, 0.5, 88),
            n(c.root + 12, t + 2, 0.5, 92), n(c.root, t + 3, 0.75, 96));
  for (const p of c.notes) {
    pad.push(n(p + 12, t, 4, 70));                                 // held chord
    keys.push(n(p, t + 0.5, 0.4, 74), n(p, t + 2.5, 0.4, 68));     // offbeat stabs
  }
}
// A plain eight-bar melody, written by hand in C natural minor.
const MEL = [[67,0,1.5],[70,1.5,0.5],[72,2,1],[70,3,1],
             [67,4,1],[63,5,1],[65,6,2],
             [67,8,1.5],[70,9.5,0.5],[75,10,1.5],[74,11.5,0.5],
             [72,12,1],[70,13,1],[67,14,2],
             [70,16,1],[72,17,1],[74,18,1.5],[75,19.5,0.5],
             [74,20,1],[72,21,1],[70,22,2],
             [67,24,1.5],[63,25.5,0.5],[65,26,1],[67,27,1],
             [70,28,1],[67,29,1],[60,30,2]];
const lead = MEL.map(([p, s, l]) => n(p, s, l, 98));

const TRACKS = [
  { name: "Drums", program: 0,  msb: 120, vol: 0.85, notes: drums },
  { name: "Bass",  program: 33, msb: 121, vol: 0.70, notes: bass  },
  { name: "Keys",  program: 4,  msb: 121, vol: 0.45, notes: keys  },
  { name: "Pad",   program: 89, msb: 121, vol: 0.28, notes: pad   },
  { name: "Lead",  program: 81, msb: 121, vol: 0.40, notes: lead  },
];

// ── build ──────────────────────────────────────────────────────────────────
send("project.new", { discardChanges: true });
send("transport.setTempo", { bpm: 100 });
const ids = {};
for (const t of TRACKS) {
  const tr = send("track.add", { name: t.name, kind: "instrument" });
  ids[t.name] = tr.id;
  send("track.setInstrument", { trackId: tr.id, kind: "soundBank",
        soundBank: { source: BANK, program: t.program, bankMSB: t.msb, bankLSB: 0 } });
  send("track.setVolume", { trackId: tr.id, volume: t.vol });
  const clip = send("clip.addMIDI", { trackId: tr.id, name: t.name, atBeat: 0,
                                      lengthBeats: BEATS, notes: t.notes });
  ids[t.name + ":clip"] = clip.id;
  console.log(`  ${t.name.padEnd(6)} ${String(t.notes.length).padStart(4)} notes  clip ${clip.id}`);
}
send("marker.add", { name: "Loop", beat: 0 });
send("transport.setLoop", { enabled: true, startBeat: 0, endBeat: BEATS });
send("transport.seek", { beats: 0 });
writeFileSync(new URL("./ids.json", import.meta.url),
              JSON.stringify({ ids, tempo: 100, beats: BEATS,
                               noteCounts: Object.fromEntries(TRACKS.map(t => [t.name, t.notes.length])) }, null, 1));
const ov = send("project.overview");
console.log(`tempo ${ov.transport.tempoBPM}  tracks ${ov.tracks.length}  ` +
            `notes ${ov.tracks.reduce((a, t) => a + t.clips.reduce((b, c) => b + (c.noteCount || 0), 0), 0)}`);
