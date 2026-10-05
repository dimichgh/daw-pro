// Pass 1 for the Amen rebuild: build every version of the pattern in DAW Pro,
// render the wavs the film measures, and photograph the app doing it.
//
// ⚠ STAGING ONLY (17695). build.mjs refuses 17600 outright and this file never
//   names a port.
// ⚠ Every capture path is absolute -- build.mjs's SHOTS/burst() resolve them,
//   because the APP resolves a wire path against the APP's cwd.
import { open, cmd, addTrack, addClip, n, close, burst, shot, SHOTS } from "../../session/build.mjs";
import * as M from "./material.mjs";
import fs from "node:fs";

const AUD = process.env.AMEN_AUDIO || new URL("./audio/", import.meta.url).pathname;
const MEDIA = new URL("./media/", import.meta.url).pathname;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// two passes of the four-bar loop: 8 bars, 14.12 s -- long enough for a PLAY
// beat to breathe and for a listener to hear the loop come round again.
const twice = (notes) => notes.concat(notes.map(x => ({ ...x, startBeat: x.startBeat + M.LEN_BEATS })));

async function rig({ kick, snare, cym, bars = M.BARS, bpm = M.BPM }) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
  const len = bars * 4;
  const tK = await addTrack("Kick",    { instrument: M.KIT });
  const tS = await addTrack("Snare",   { instrument: M.KIT });
  const tC = await addTrack("Cymbals", { instrument: M.KIT, volume: 0.55 });
  const cK = await addClip(tK, 0, len, kick,  "Kick");
  const cS = await addClip(tS, 0, len, snare, "Snare");
  const cC = await addClip(tC, 0, len, cym,   "Cymbals");
  return { tK, tS, tC, cK, cS, cC, len, bpm };
}

const mix = async (name, bars = M.BARS, bpm = M.BPM) => {
  const secs = bars * 4 * (60 / bpm) + 1.4;
  const r = await cmd("render.mixdown", { path: `${AUD}${name}.wav`, durationSeconds: secs });
  console.log(`  ${name}.wav  ${r.durationSeconds?.toFixed?.(2)}s`);
};

await open();
const report = { bpm: M.BPM, sixteenthMs: M.SIXTEENTH_MS, beatMs: M.BEAT_MS,
                 counts: M.COUNTS, velocities: { accent: M.V_ACCENT, ghost: M.V_GHOST,
                 kick: M.V_KICK, ride: M.V_RIDE, rideStrong: M.V_RIDE_W, crash: M.V_CRASH } };

// ── 1. the build-up, four bars each. Each is the "before" or "after" of an A/B.
await rig({ kick: M.kickPlain, snare: [], cym: [] });                     await mix("s1-kick");
await rig({ kick: M.kickPlain, snare: M.accentPlain, cym: [] });          await mix("s2-snare");
await rig({ kick: M.kickPlain, snare: M.accentPlain, cym: M.cymbalsPlain }); await mix("s3-skeleton");
await rig({ kick: M.kickPlain, snare: M.accentPlain.concat(M.ghostPlain), cym: M.cymbalsPlain });
await mix("s4-ghosts");

// ── 2. the two surprises, isolated. bar3straight is the SAME four bars with
//      the bar-3 snare put back on the beat: one note moved, nothing else.
await rig({ kick: M.kick, snare: M.accentStraight.concat(M.ghost), cym: M.cymbals });
await mix("s5-bar3straight");
await rig({ kick: M.kick, snare: M.accent.concat(M.ghost), cym: M.cymbals });
await mix("s6-full4");

// ── 3. the full loop, twice through -- the film's main PLAY bed, and the
//      quantized "before" of the humanize A/B.
const FULL = { kick: twice(M.kick), snare: twice(M.accent.concat(M.ghost)), cym: twice(M.cymbals) };
await rig({ ...FULL, bars: M.BARS * 2 });
await mix("q-quant", M.BARS * 2);
// per-stem renders of the quantized take, for onset measurement on a clean stem
{
  const r = await rig({ ...FULL, bars: M.BARS * 2 });
  for (const [nm, keep] of [["kick", r.tK], ["snare", r.tS], ["cym", r.tC]]) {
    const others = [r.tK, r.tS, r.tC].filter(x => x !== keep);
    await cmd("render.mixdown", { path: `${AUD}stem-quant-${nm}.wav`,
      durationSeconds: M.BARS * 2 * 4 * (60 / M.BPM) + 1.4, excludeTrackIds: others });
  }
  console.log("  stem-quant-*.wav");
}

// ── 4. HUMANIZED. The app's own clip.humanize, seeded so a rebuild reproduces
//      it, timing only (velocityRange 0) because velocity already has its own
//      chapter and mixing the two would make neither measurable.
//      ⚠ The shifts are READ BACK off the project rather than assumed: a
//      setter's return is not proof, and the uniform draw is what it is.
const SEED = 20260906;
const TIMING = 0.02;                                  // +/- 0.02 beat = +/- 8.82 ms
{
  const r = await rig({ ...FULL, bars: M.BARS * 2 });
  const before = {};
  for (const [nm, c] of [["kick", r.cK], ["snare", r.cS], ["cym", r.cC]])
    before[nm] = (await cmd("clip.getNotes", { clipId: c })).notes.map(x => x.startBeat);
  const seeds = {};
  for (const [nm, c] of [["kick", r.cK], ["snare", r.cS], ["cym", r.cC]]) {
    const h = await cmd("clip.humanize", { clipId: c, timingBeats: TIMING, velocityRange: 0, seed: SEED });
    seeds[nm] = h.seedUsed;
  }
  const after = {}, shifts = {};
  for (const [nm, c] of [["kick", r.cK], ["snare", r.cS], ["cym", r.cC]]) {
    after[nm] = (await cmd("clip.getNotes", { clipId: c })).notes.map(x => x.startBeat);
    shifts[nm] = after[nm].map((v, i) => (v - before[nm][i]) * M.BEAT_MS);
  }
  report.humanize = { seed: SEED, seedUsed: seeds, timingBeats: TIMING,
                      maxMsAsked: TIMING * M.BEAT_MS, before, after, shiftsMs: shifts };
  const all = [].concat(...Object.values(shifts));
  console.log(`  humanize: ${all.length} notes, max |shift| ${Math.max(...all.map(Math.abs)).toFixed(3)} ms, ` +
              `mean |shift| ${(all.reduce((a, b) => a + Math.abs(b), 0) / all.length).toFixed(3)} ms`);
  await mix("q-human", M.BARS * 2);
  for (const [nm, keep] of [["kick", r.tK], ["snare", r.tS], ["cym", r.tC]]) {
    const others = [r.tK, r.tS, r.tC].filter(x => x !== keep);
    await cmd("render.mixdown", { path: `${AUD}stem-human-${nm}.wav`,
      durationSeconds: M.BARS * 2 * 4 * (60 / M.BPM) + 1.4, excludeTrackIds: others });
  }
  console.log("  stem-human-*.wav");
}

// ── 5. THE EXAGGERATION. The real drummer's average displacement is a few
//      milliseconds and nobody hears that on a laptop speaker in isolation. So
//      the film ALSO plays a version dragged far enough to be unmissable, and
//      says the real number next to it rather than implying they are the same.
const DRAG_MS = 28;
const dragBeats = DRAG_MS / M.BEAT_MS;
{
  const drag = (ns) => ns.map(x => ({ ...x, startBeat: +(x.startBeat + dragBeats).toFixed(6) }));
  await rig({ kick: twice(M.kick), snare: drag(twice(M.accent.concat(M.ghost))),
              cym: twice(M.cymbals), bars: M.BARS * 2 });
  await mix("q-drag", M.BARS * 2);
  {
    const r = await rig({ kick: twice(M.kick), snare: drag(twice(M.accent.concat(M.ghost))),
                          cym: twice(M.cymbals), bars: M.BARS * 2 });
    for (const [nm, keep] of [["snare", r.tS]]) {
      const others = [r.tK, r.tS, r.tC].filter(x => x !== keep);
      await cmd("render.mixdown", { path: `${AUD}stem-drag-${nm}.wav`,
        durationSeconds: M.BARS * 2 * 4 * (60 / M.BPM) + 1.4, excludeTrackIds: others });
    }
  }
  report.dragMs = DRAG_MS;
}

// ── 6. the jungle tempo. SAME NOTES, faster clock.
await rig({ ...FULL, bars: M.BARS * 2, bpm: M.BPM_JUNGLE });
await mix("j-170", M.BARS * 2, M.BPM_JUNGLE);

// ── 7. the pictures, shot on the real four-bar project so the app on screen IS
//      the thing being measured.
{
  const r = await rig({ kick: M.kick, snare: M.accent.concat(M.ghost), cym: M.cymbals });
  await cmd("transport.seek", { beats: 0 });
  await cmd("ui.showMixer", { show: false });
  await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32 });
  await shot("arrange");

  // the SNARE clip in the note editor. The roll opens high in the 128-row pitch
  // stack and this part lives at MIDI 38 -- without pianoRollCenterPitch it
  // photographs as an empty grid, which is exactly the trap the brief names.
  await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 42, pianoRollRowHeight: 13 });
  await cmd("debug.captureUI", { path: `${SHOTS}/roll-open.png`, selectClip: r.cS });
  await cmd("debug.panelLayout", { pianoRollCenterPitch: 38 });
  await shot("roll-snare");
  // and the DRUM GRID view of the same clip -- named lanes instead of pitches
  await cmd("debug.stepSequencer", { mode: "steps" });
  await shot("grid-snare");
  await cmd("debug.captureUI", { path: `${SHOTS}/grid-cym.png`, selectClip: r.cC });
  await cmd("debug.captureUI", { path: `${SHOTS}/grid-kick.png`, selectClip: r.cK });
  await cmd("debug.stepSequencer", { mode: "notes" });
  await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.43 });
  await shot("arrange-wide");

  await burst("b-loop", 8.0, 0, { arrange: true });
}

// ── 8. bursts for the A/B halves and the PLAY beats, all arrange-view so the
//      playhead is visibly crossing the bar the voice is talking about.
for (const [name, mat, bars] of [
  ["b-skeleton", { kick: M.kickPlain, snare: M.accentPlain, cym: M.cymbalsPlain }, M.BARS],
  ["b-ghosts",   { kick: M.kickPlain, snare: M.accentPlain.concat(M.ghostPlain), cym: M.cymbalsPlain }, M.BARS],
  ["b-bar3",     { kick: M.kick, snare: M.accent.concat(M.ghost), cym: M.cymbals }, M.BARS],
]) {
  await rig({ ...mat, bars });
  await burst(name, bars * 4 * (60 / M.BPM) + 0.4, 0, { arrange: true });
}

fs.writeFileSync(`${MEDIA}material.json`, JSON.stringify(report, null, 1));
console.log(`  material.json  ${M.COUNTS.total} notes`);

await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("ui.showMixer", { show: false });
close(); process.exit(0);
