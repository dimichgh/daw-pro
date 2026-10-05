// Pass 1 for the metronome lesson: build the project in DAW Pro, render every
// wav the film measures, and photograph the app doing it.
//
// ⚠ STAGING ONLY (17695). build.mjs refuses 17600 outright and this file never
//   names a port.
// ⚠ Every capture path is absolute -- the APP resolves a wire path against the
//   APP's own cwd and still returns ok with a valid PNG at a plausible name.
import { open, cmd, addTrack, addClip, close, burst, shot, SHOTS } from "../../session/build.mjs";
import * as M from "./material.mjs";
import fs from "node:fs";

const AUD = new URL("./audio/", import.meta.url).pathname;
const MEDIA = new URL("./media/", import.meta.url).pathname;
fs.mkdirSync(AUD, { recursive: true });
fs.mkdirSync(MEDIA, { recursive: true });
fs.mkdirSync(SHOTS, { recursive: true });

const report = { built: new Date().toISOString(), renders: {}, counts: M.COUNTS };

/** Build a fresh project: a Strings track carrying `reps` statements of the
 *  motif, and a Click track carrying ticks every `beatsPerTick` beats. */
async function rig({ bpm, reps, beatsPerTick, withMotif = true, withClick = true }) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm });
  const beats = reps * M.STATEMENT_BEATS;
  const out = { bpm, beats, secs: beats * M.secPerBeat(bpm) };
  if (withMotif) {
    out.tS = await addTrack("Strings", { instrument: M.STRINGS, volume: 0.85 });
    out.cS = await addClip(out.tS, 0, beats, M.motif(reps), "Fifth, opening");
  }
  if (withClick) {
    out.tC = await addTrack("Click", { instrument: M.KIT, volume: 0.62 });
    const ticks = beatsPerTick === 2 ? M.clickHalf(beats) : M.clickQuarter(beats);
    out.tickCount = ticks.length;
    out.cC = await addClip(out.tC, 0, beats, ticks, "Metronome");
  }
  return out;
}

const mix = async (name, r, extraTail = 1.6, opts = {}) => {
  const res = await cmd("render.mixdown", {
    path: `${AUD}${name}.wav`, durationSeconds: r.secs + extraTail,
    ...(opts.excludeTrackIds ? { excludeTrackIds: opts.excludeTrackIds } : {}),
  });
  report.renders[name] = { bpm: r.bpm, beats: r.beats, secs: +r.secs.toFixed(6),
                           rendered: res.durationSeconds, ticks: r.tickCount };
  console.log(`  ${name}.wav  ${res.durationSeconds?.toFixed?.(2)}s  (${r.bpm} BPM)`);
};

await open();

// ── 1. CLICK ONLY, at every tempo the film uses. These are what calibrates the
//      instrument: the film measures the inter-tick intervals back out of the
//      audio and checks them against 60000*beatsPerTick/bpm before it asks the
//      viewer to believe anything else it measures.
for (const [name, bpm, bpt] of [
  ["click-mark-216",   M.BPM_MARK,   2],   // half = 108
  ["click-drift-192",  M.BPM_DRIFT,  2],   // half = 96
  ["click-unit-108",   M.BPM_UNIT,   1],   // quarter = 108  -> the SAME tick rate
  ["click-eroica-152", M.BPM_EROICA, 2],   // half = 76
]) {
  const r = await rig({ bpm, reps: 4, beatsPerTick: bpt, withMotif: false });
  await mix(name, r);
}

// ── 2. THE JITTER POSITIVE CONTROL. A clean click can come back at a spread of
//      a fraction of a millisecond, and a tiny uniform number across many units
//      is exactly what a probe that never measured looks like. So this render
//      is deliberately humanised by a KNOWN amount and the onset probe has to
//      find it. The shifts are READ BACK off the project, not assumed -- a
//      setter's return is not proof it took.
{
  const r = await rig({ bpm: M.BPM_MARK, reps: 4, beatsPerTick: 2, withMotif: false });
  const before = await cmd("clip.getNotes", { clipId: r.cC });
  await cmd("clip.humanize", { clipId: r.cC, timingBeats: M.JITTER_BEATS,
                               velocityRange: 0, seed: M.JITTER_SEED });
  const after = await cmd("clip.getNotes", { clipId: r.cC });
  const b = new Map(before.notes.map(x => [x.id, x.startBeat]));
  const msPerBeat = 60000 / M.BPM_MARK;
  const shifts = after.notes.map(x => (x.startBeat - b.get(x.id)) * msPerBeat);
  report.jitter = {
    seed: M.JITTER_SEED, timingBeats: M.JITTER_BEATS, bpm: M.BPM_MARK,
    boundMs: M.jitterMs(M.BPM_MARK), n: shifts.length,
    shiftsMs: shifts.map(x => +x.toFixed(4)),
    maxAbsMs: +Math.max(...shifts.map(Math.abs)).toFixed(4),
    meanAbsMs: +(shifts.reduce((a, x) => a + Math.abs(x), 0) / shifts.length).toFixed(4),
  };
  console.log(`  jitter: ${shifts.length} ticks, max |shift| ` +
              `${report.jitter.maxAbsMs} ms (bound ${M.jitterMs(M.BPM_MARK).toFixed(3)})`);
  await mix("click-jitter-216", r);
}

// ── 3. THE MOTIF, at each tempo. Six statements rendered so any A/B window the
//      film wants can be cut from real audio rather than padded.
//      `-dry` is the strings alone: onset measurement needs a stem without a
//      woodblock landing on the same instant.
for (const [name, bpm, bpt] of [
  ["motif-mark-216",  M.BPM_MARK,  2],
  ["motif-drift-192", M.BPM_DRIFT, 2],
  ["motif-unit-108",  M.BPM_UNIT,  1],
]) {
  const r = await rig({ bpm, reps: 6, beatsPerTick: bpt });
  await mix(name, r);
  await mix(`${name}-dry`, r, 1.6, { excludeTrackIds: [r.tC] });
  await mix(`${name}-click`, r, 1.6, { excludeTrackIds: [r.tS] });
}

// ── 4. PICTURES. The project is left holding the mark version -- 216 BPM, the
//      tempo field the whole lesson turns on -- because that is what every
//      still and every burst should show.
const main = await rig({ bpm: M.BPM_MARK, reps: 4, beatsPerTick: 2 });
report.mainProject = { bpm: main.bpm, beats: main.beats, ticks: main.tickCount };

await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.42 });
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");

// the piano roll, pointed at the eight notes -- pitches 62-67 sit inside the
// roll's visible band, but centre it anyway rather than trusting that.
await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 44,
                                 pianoRollRowHeight: 14, pianoRollMinimap: true });
await cmd("debug.captureUI", { path: `${SHOTS}/app-roll.png`, selectClip: main.cS });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 64 });
await shot("app-roll-notes");

await cmd("debug.captureUI", { path: `${SHOTS}/app-click.png`, selectClip: main.cC });
await cmd("debug.panelLayout", { pianoRollCenterPitch: M.WOODBLOCK });
await shot("app-click-notes");

// ── 5. BURSTS: the transport actually running, so the playhead crosses the
//      notes it is playing instead of the film showing a frozen picture.
await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 30 });
await cmd("debug.captureUI", { path: `${SHOTS}/_burstopen.png`, selectClip: main.cS });
await burst("b-mark", 9.5, 0);
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.42 });
await burst("b-arrange", 9.5, 0, { arrange: true });

// ── 6. leave the app tidy, then save this build's project under its own name so
//      ownership of what is on staging is never ambiguous.
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.stop", {});
await cmd("transport.seek", { beats: 0 });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.43,
                                 pianoRollPPB: 55, pianoRollRowHeight: 14 });
await cmd("ui.showMixer", { show: false });
await cmd("project.save", { path: `${MEDIA}Metronome lesson (staging scratch).dawproj` });

const ov = await cmd("project.overview", {});
report.staging = { tempo: ov.transport?.tempoBPM, master: ov.master?.volume,
                   tracks: (ov.tracks || []).map(t => ({ name: t.name, clips: t.clips?.length })) };
fs.writeFileSync(`${MEDIA}shoot.json`, JSON.stringify(report, null, 1));
console.log("\nwrote media/shoot.json");
close();
process.exit(0);
