// Pass 2: the stills. Separate from shoot.mjs so a framing iteration costs no
// renders, and framed by LOOKING at the pixels rather than by trusting ok.
//
// ⚠ MEASURED: the STEP-SEQUENCER grid ignores `pianoRollPPB` entirely. Shot at
//   ppb 20, 30 and 42 the PNG is byte-identical (one md5, three files), and the
//   window is a fixed ~3.05 bars wide -- so a 4-bar clip photographs with BAR 4
//   OFF SCREEN, including the crash that is the whole point of bar 4. The fix
//   is not a zoom parameter, it is shooting the bar the chapter is about as its
//   own clip. Every such clip is a slice of the same 53 notes; nothing is
//   re-voiced or re-timed for a picture.
import { open, cmd, addTrack, addClip, close, shot, SHOTS } from "../../session/build.mjs";
import * as M from "./material.mjs";

const slice = (notes, fromBar, toBar) => notes
  .filter(x => x.startBeat >= fromBar * 4 && x.startBeat < toBar * 4)
  .map(x => ({ ...x, startBeat: +(x.startBeat - fromBar * 4).toFixed(6) }));
const ALL = M.kick.concat(M.accent, M.ghost, M.cymbals);
const ALL_STRAIGHT = M.kick.concat(M.accentStraight, M.ghost, M.cymbals);
const PLAIN = M.kickPlain.concat(M.accentPlain, M.cymbalsPlain);

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: M.BPM });
const tK = await addTrack("Kick",    { instrument: M.KIT });
const tS = await addTrack("Snare",   { instrument: M.KIT });
const tC = await addTrack("Cymbals", { instrument: M.KIT, volume: 0.55 });
const cK = await addClip(tK, 0, M.LEN_BEATS, M.kick, "Kick");
const cS = await addClip(tS, 0, M.LEN_BEATS, M.accent.concat(M.ghost), "Snare");
const cC = await addClip(tC, 0, M.LEN_BEATS, M.cymbals, "Cymbals");

// A photography-only track. MUTED, and every wav in this film comes from
// shoot.mjs's three-track projects -- this exists so ONE drum grid can show
// kick, snare and cymbals as NAMED LANES together, which is what a novice can
// actually read. Its clips are bar slices of the same 53 notes.
const tA = await addTrack("Amen Break", { instrument: M.KIT });
await cmd("track.setMute", { trackId: tA, muted: true });
const clips = {};
const put = async (key, notes, bars, at, name) => {
  clips[key] = await addClip(tA, at * 4, bars * 4, notes, name);
};
await put("all",      ALL,                     4, 0,  "Amen Break — 4 bars");
await put("bars12",   slice(ALL, 0, 2),        2, 4,  "Bars 1-2");
await put("bar3",     slice(ALL, 2, 3),        1, 6,  "Bar 3 — snare pushed late");
await put("bar3str",  slice(ALL_STRAIGHT, 2, 3), 1, 7, "Bar 3 — snare on the beat");
await put("bar4",     slice(ALL, 3, 4),        1, 8,  "Bar 4 — no kick on 1");
await put("plain",    slice(PLAIN, 0, 2),      2, 9,  "The straight skeleton");
await put("ghosts",   slice(ALL, 0, 2),        2, 11, "…with the ghost notes");

await cmd("ui.showMixer", { show: false });
await cmd("transport.seek", { beats: 0 });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
await cmd("debug.arrangeZoom", { ppb: 34 });
await shot("arrange");

// the note editor, on the SNARE part. The roll opens anchored high in the
// 128-row pitch stack and this part is at MIDI 38 -- without centerPitch it
// photographs as an empty grid.
await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 42, pianoRollRowHeight: 13 });
await cmd("debug.captureUI", { path: `${SHOTS}/roll-open.png`, selectClip: cS });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 38 });
await shot("roll-snare");

await cmd("debug.stepSequencer", { mode: "steps" });
for (const key of Object.keys(clips)) {
  await cmd("debug.captureUI", { path: `${SHOTS}/grid-${key}.png`, selectClip: clips[key] });
  await cmd("debug.panelLayout", { pianoRollCenterPitch: 44 });
  await shot(`grid-${key}`);
}
// the per-part grids, from the three real tracks
for (const [nm, c] of [["kick", cK], ["snare", cS], ["cym", cC]]) {
  await cmd("debug.captureUI", { path: `${SHOTS}/grid-t-${nm}.png`, selectClip: c });
  await cmd("debug.panelLayout", { pianoRollCenterPitch: 44 });
  await shot(`grid-t-${nm}`);
}
await cmd("debug.stepSequencer", { mode: "notes" });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.43 });
console.log("stills done:", Object.keys(clips).join(" "));
close(); process.exit(0);
