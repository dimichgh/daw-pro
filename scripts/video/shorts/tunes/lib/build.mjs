// Build ONE short's project on STAGING from its song.json, then render the wav.
//
// ⚠ STAGING ONLY. session/build.mjs refuses 17600 outright and this file never
//   names a port.
// ⚠ Every path handed to the app is ABSOLUTE — the app resolves a relative wire
//   path against ITS cwd and still answers ok.
//
// The song.json schema is the ONE contract shared with viz.py, so the picture
// and the sound are generated from the same numbers rather than from two
// hand-kept copies.
import { open, cmd, close } from "/Users/dsemenov/Views/daw-pro/scripts/video/session/build.mjs";
import fs from "node:fs";
import path from "node:path";

const songPath = path.resolve(process.argv[2]);
const song = JSON.parse(fs.readFileSync(songPath, "utf8"));
const outDir = path.resolve(process.argv[3] || path.dirname(songPath));
fs.mkdirSync(outDir, { recursive: true });
const MS = "/Users/dsemenov/Library/Application Support/DAWPro/SoundBanks/MuseScore_General.sf2";

await open();
await cmd("project.new", { discardChanges: true });

// tempo: a map ALWAYS, even when constant — one code path, so the accelerando
// short is not a special case that only gets exercised once.
await cmd("tempo.setMap", { segments: song.tempoSegments });
const tmap = await cmd("tempo.map", {});
fs.writeFileSync(`${outDir}/tempo-echo.json`, JSON.stringify(tmap, null, 1));

// buses first, so a track can name one in its `send`
const busId = {};
for (const b of song.buses || []) {
  const t = await cmd("track.add", { kind: "bus", name: b.name });
  busId[b.name] = t.id;
  if (b.volume !== undefined) await cmd("track.setVolume", { trackId: t.id, volume: b.volume });
  for (const f of b.fx || []) await cmd("fx.add", { trackId: t.id, kind: f.kind, params: f.params || {} });
}

const built = [];
for (const tr of song.tracks) {
  const t = await cmd("track.add", { kind: "instrument", name: tr.name });
  await cmd("track.setInstrument", {
    trackId: t.id, kind: "soundBank",
    soundBank: { source: MS, program: tr.program,
                 bankMSB: tr.bankMSB ?? 121, bankLSB: tr.bankLSB ?? 0 },
  });
  if (tr.volume !== undefined) await cmd("track.setVolume", { trackId: t.id, volume: tr.volume });
  if (tr.pan !== undefined) await cmd("track.setPan", { trackId: t.id, pan: tr.pan });
  for (const f of tr.fx || []) await cmd("fx.add", { trackId: t.id, kind: f.kind, params: f.params || {} });
  if (tr.send) {
    if (!busId[tr.send.bus]) throw new Error(`${tr.name}: no bus named ${tr.send.bus}`);
    await cmd("track.addSend", { trackId: t.id, busId: busId[tr.send.bus], level: tr.send.level });
  }
  // ⚠ ONE CLIP PER TRACK, spanning the whole piece, with CLIP-RELATIVE beats.
  // Splitting a part into several clips would put a note's beat in two frames
  // of reference at once; viz.py reads the same absolute beats this writes.
  // ⭐ `audioHoldBeats` IS THE DAMPER PEDAL, AND IT IS AUDIO-ONLY ON PURPOSE.
  // Beethoven's "senza sordini" needs the notes to ring into each other; the
  // wire path here writes note-on/note-off and no CC 64, so a track may ask for
  // its notes to be HELD longer than they are written.
  // ⛔ IT MUST NOT REACH THE PICTURE. Lengthening the notes in song.json itself
  // was tried first and it silently TRIPLED THE PLAYHEADS: prep.mjs's
  // splitVoices deals overlapping notes to separate voices, so one arpeggio
  // line became three parallel lights. The road's note lengths are the truth
  // about the performance; this hold is applied HERE, on the way to the DAW,
  // and nowhere else.
  const hold = tr.audioHoldBeats ?? 0;
  const notes = tr.notes.map(([s, p, l, v]) => ({ startBeat: s, pitch: p,
    lengthBeats: hold ? Math.max(l, hold) : l, velocity: v }));
  if (notes.length) {
    const c = await cmd("clip.addMIDI", {
      trackId: t.id, atBeat: 0, lengthBeats: song.lengthBeats, notes, name: tr.name,
    });
    built.push({ name: tr.name, trackId: t.id, clipId: c.id, notes: notes.length });
  } else {
    built.push({ name: tr.name, trackId: t.id, clipId: null, notes: 0 });
  }
}

// master chain: gain FIRST (index 0), limiter LAST — the fader is a trim, not
// a makeup stage, and a bare multiply needs something after it.
for (const f of song.master?.fx || []) {
  await cmd("fx.add", { trackId: "master", kind: f.kind, params: f.params || {}, ...(f.index !== undefined ? { index: f.index } : {}) });
}
if (song.master?.volume !== undefined) await cmd("mixer.setMasterVolume", { volume: song.master.volume });

// MEASURE before bouncing: the loudness of the MIX is what we are steering.
const m = await cmd("render.measureLoudness", { fromBeat: 0, durationSeconds: song.renderSeconds });
console.log("LOUDNESS " + JSON.stringify(m.measurement));

const wav = `${outDir}/music.wav`;
const r = await cmd("render.mixdown", { path: wav, fromBeat: 0, durationSeconds: song.renderSeconds });
if (r.path !== wav) throw new Error(`render wrote ${r.path}, not ${wav} — a relative path resolves against the APP cwd`);
console.log("RENDER " + JSON.stringify({ path: r.path, seconds: r.durationSeconds }));

// Read the notes BACK out of the app, so anything downstream that asserts on
// them is asserting on what the DAW holds, not on what the author intended.
const readback = {};
for (const b of built) {
  if (!b.clipId) continue;
  const gn = await cmd("clip.getNotes", { clipId: b.clipId });
  readback[b.name] = (gn.notes || []).map((n) => [n.startBeat, n.pitch, n.lengthBeats, n.velocity]);
}
fs.writeFileSync(`${outDir}/readback.json`, JSON.stringify(readback));
fs.writeFileSync(`${outDir}/build-facts.json`, JSON.stringify({
  song: song.id, tracks: built, loudness: m.measurement,
  render: { path: r.path, seconds: r.durationSeconds }, tempoEcho: tmap,
}, null, 1));

await cmd("transport.seek", { beats: 0 });
close();
process.exit(0);
