// L11 "Beethoven at 128" — REBUILD. Pass 1: build the project on STAGING,
// render every version and every stem the film measures, and shoot every
// picture of the app.
//
// ⚠ STAGING ONLY. build.mjs refuses port 17600 outright.
//
// THE EXPERIMENT, STATED BEFORE ANYTHING IS RENDERED
// ──────────────────────────────────────────────────
// One riff — Beethoven's four-note cell — played two ways in ONE project at ONE
// tempo for ONE length. The orchestral version is the cell in three octaves in
// unison (violins, celli, double basses) and nothing else. The techno version
// is the same cell on a saw, plus a kick, offbeat hats, a clap and a sustained
// sine root. Rendering each is a matter of silencing the other's tracks, which
// `render.bounce`'s `excludeTrackIds` does WITHOUT touching the project.
//
// PREDICTION: the two will differ far less below 100 Hz than the shipped film
// claimed, because a double-bass section really does put 73–104 Hz into a room.
// What an orchestra of 1808 cannot do is go BELOW its lowest string and hold a
// note there. So the honest measurement is the band under about 60 Hz, and the
// honest counter-measurement is 60–100 Hz, where the orchestra may well win.
// Both get measured and both go on screen.
import { open, cmd, addTrack, addClip, close, burst, shot } from "../../session/build.mjs";
import { PARTS, BPM, BARS, LEN_BEATS, SECS, NOTE_COUNT,
         RIFF_NOTES, DRUM_HITS, SUB_NOTES } from "./material.mjs";
import fs from "node:fs";

const AUD = process.env.B128_AUDIO || "./audio";
const SH = process.env.SESSION_SHOTS || "./shots";
const REN = SECS + 1.5;                      // 31.5 s: the whole thing + a tail

const facts = { bpm: BPM, bars: BARS, seconds: SECS, notes: NOTE_COUNT,
                riffNotes: RIFF_NOTES, drumHits: DRUM_HITS, subNotes: SUB_NOTES,
                parts: PARTS.map(p => ({ name: p.name, group: p.group,
                                         volume: p.volume, pan: p.pan,
                                         notes: p.notes.length })) };

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });

const ids = {}, clips = {};
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument,
                                     volume: p.volume, pan: p.pan });
  clips[p.name] = await addClip(t, 0, LEN_BEATS, p.notes, p.name);
  ids[p.name] = t;
}
const id = (n) => ids[n];
const orchIds = PARTS.filter(p => p.group === "orch").map(p => id(p.name));
const techIds = PARTS.filter(p => p.group === "tech").map(p => id(p.name));
const all = PARTS.map(p => id(p.name));
const except = (keep) => all.filter(t => !keep.includes(t));
console.log(`  ${NOTE_COUNT} notes across ${PARTS.length} tracks, ${SECS}s at ${BPM} BPM`);

/** render.bounce writes the file AND returns a measured loudness report for
 *  exactly that render, with `excludeTrackIds` silenced and THE PROJECT LEFT
 *  ALONE. No mute/bounce/un-mute dance, and no chance of a stray mute surviving
 *  into a still. (`render.measureLoudness` has no exclude list at all, and
 *  `track.setMuted` is not a command — it is `track.setMute`.) */
async function bounce(name, exclude) {
  const r = await cmd("render.bounce", { path: `${AUD}/${name}.wav`,
                                         durationSeconds: REN,
                                         excludeTrackIds: exclude });
  const o = r.report.output;
  console.log(`  ${name.padEnd(12)} ${o.integratedLufs.toFixed(2)} LUFS  ` +
              `${o.truePeakDbtp.toFixed(2)} dBTP  ` +
              `LRA ${(o.loudnessRangeLu ?? NaN).toFixed(2)}`);
  return o;
}

// ── 0. the pictures of the project, shot BEFORE anything is changed ────────
await cmd("transport.seek", { beats: 0 });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32 });
await shot("arrange");
await cmd("ui.showMixer", { show: true });
await shot("mixer");
await cmd("ui.showMixer", { show: false });

// the piano roll of the CELL. ⚠ The riff sits at MIDI 38–44, well below the
// roll's default band, so without pianoRollCenterPitch this is an empty grid —
// and an empty grid photographs as a perfectly valid PNG.
await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 26,
                                 pianoRollRowHeight: 13 });
await cmd("debug.captureUI", { path: `${SH}/_roll-pre.png`, selectClip: clips.Riff });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 41 });
await shot("roll-riff");
await cmd("debug.captureUI", { path: `${SH}/_roll-pre2.png`, selectClip: clips.Sub });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 26 });
await shot("roll-sub");
await cmd("debug.captureUI", { path: `${SH}/_roll-pre3.png`, selectClip: clips.Basses });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 41 });
await shot("roll-basses");
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32 });

// the two synth cards — the film's voice reads these values off the screen
await cmd("debug.synthEditor", { open: true, trackId: id("Riff") });
await shot("synth-riff");
await cmd("debug.synthEditor", { close: true });
await cmd("debug.synthEditor", { open: true, trackId: id("Sub") });
await shot("synth-sub");
await cmd("debug.synthEditor", { close: true });

// ── 1. the two versions ────────────────────────────────────────────────────
facts.orch = await bounce("orch", techIds);
facts.techno = await bounce("techno", orchIds);

// ── 2. every stem, for the spectrum work ───────────────────────────────────
facts.stems = {};
for (const p of PARTS)
  facts.stems[p.name] = await bounce(`stem-${p.name.toLowerCase()}`,
                                     except([id(p.name)]));

// ── 3. the layer build, for the chapter where the room arrives ─────────────
//    Each rung is the one before it plus one more strip. The cell never changes.
const RUNGS = [["l1-riff", ["Riff"]],
               ["l2-kick", ["Riff", "Kick"]],
               ["l3-hats", ["Riff", "Kick", "Hats"]],
               ["l4-clap", ["Riff", "Kick", "Hats", "Clap"]],
               ["l5-sub",  ["Riff", "Kick", "Hats", "Clap", "Sub"]]];
facts.layers = [];
for (const [tag, keep] of RUNGS)
  facts.layers.push({ tag, keep, out: await bounce(tag, except(keep.map(id))) });

// ── 4. THE AUDIBLE PROXY. The sub part moved up two octaves, so a laptop can
//    show you the thing it cannot reproduce where it actually lives. The notes
//    are transposed, rendered, and PUT BACK — and the restore is re-read and
//    asserted, because a setter's return is not proof it took.
const subNotes = (await cmd("clip.getNotes", { clipId: clips.Sub })).notes;
// ⚠ `subNotes` holds the ORIGINAL pitches, so the restore patches back to
// x.pitch absolutely rather than by a −24 delta — a delta restore compounds if
// the transpose ever runs twice.
const bump = (semis) => cmd("clip.patchNotes", {
  clipId: clips.Sub,
  update: subNotes.map(x => ({ id: x.id, pitch: x.pitch + semis })) });
await bump(24);
facts.subUp = await bounce("sub-up2", except([id("Sub")]));
await cmd("clip.patchNotes", { clipId: clips.Sub,
  update: subNotes.map(x => ({ id: x.id, pitch: x.pitch })) });
const back = (await cmd("clip.getNotes", { clipId: clips.Sub })).notes;
const drift = back.filter((x, i) => x.pitch !== subNotes[i].pitch);
if (drift.length) throw new Error(`SUB NOT RESTORED: ${drift.length} notes still transposed`);
console.log(`  sub restored: ${back.length} notes, 0 drifted`);
facts.subDown = await bounce("sub-orig", except([id("Sub")]));

// ── 5. the bursts: the app PLAYING, so the play segments are motion ────────
//    ⚠ master to 0 first — build.mjs's burst() does that. Nobody asked for
//    thirty seconds of techno out of a sleeping machine's speakers.
await cmd("ui.showMixer", { show: false });
await burst("orchplay", 9.5, 0, { arrange: true });
await burst("technoplay", 9.5, 32, { arrange: true });
await burst("buildplay", 12.0, 0, { arrange: true });
await cmd("mixer.setMasterVolume", { volume: 1 });

fs.writeFileSync(`${AUD}/facts.json`, JSON.stringify(facts, null, 1));
console.log(`  facts -> ${AUD}/facts.json`);
await cmd("transport.seek", { beats: 0 });
close();
process.exit(0);   // ⚠ the ws keeps node's event loop alive; close() alone hangs
