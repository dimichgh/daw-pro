// Build the project, balance it by measurement, capture the stills, render
// every audio example, then photograph the app playing each layer.
//
// ⚠ STAGING ONLY (17695) — build.mjs refuses 17600.
// ⚠ RUN WITH DAW_TIMEOUT_MS=180000. render.bounce on five tracks takes longer
//   than dawctl's 30 s default; the timeout is not a hang.
//
// ⛔⛔ ORDER IS LOAD-BEARING: EVERY RENDER HAPPENS BEFORE THE FIRST BURST.
// MEASURED IN THIS SESSION: once the transport has been run for a burst, every
// soundBank (SoundFont) instrument in this app instance renders SILENT offline
// — and the silent render still returns ok, with the loudness report simply
// ABSENT. The first eight renders (before the bursts) were fine; `piano72`,
// rendered afterwards, is digital silence at -70 LUFS, and re-setting the
// instruments did not revive it. The polySynth bass was unaffected. So: renders
// first, bursts last, and every bounce is asserted non-silent below.
import fs from "node:fs";
import { open, cmd, shot, close, burst, SHOTS } from "../../session/build.mjs";
import * as M from "./material.mjs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/lessons/bach-house";
const A = `${HERE}/audio`;
const R = {};

// ── the balance targets ─────────────────────────────────────────────────────
// Solo loudness each part should hit over bars 9-16, chosen so the sum lands
// near -14.5 LUFS and the piano stays the lead voice. Nobody here has ears;
// this is arithmetic on measurements, and the result is measured back.
// ⚠ THE BALANCE IS SET WITH A `gain` INSERT, NOT THE FADER. track.setVolume is
// capped at 2.0 (+6 dB) and CLAMPS SILENTLY at the cap: the first balanced take
// asked the hats for 2.11 and got 2, so they rendered 3 dB under target and
// nothing said so. A gain insert reaches +24.08 dB, and the clamp is reported.
const TARGET = { Prelude: -21.0, Kick: -20.0, Hats: -28.0, Clap: -26.0, Bass: -22.0 };

async function bounce(name, fromBeat, seconds, keep, all) {
  const exclude = all.filter((t) => !keep.includes(t));
  const r = await cmd("render.bounce", { path: `${A}/${name}.wav`, fromBeat,
                                         durationSeconds: seconds,
                                         excludeTrackIds: exclude });
  const lufs = r.report?.output?.integratedLufs;
  // ⚠ A SILENT RENDER RETURNS ok WITH NO REPORT. Refuse rather than build a
  // film on it — that is exactly how the first take of this shoot went wrong.
  if (lufs === undefined || lufs === null || lufs < -60)
    throw new Error(`render ${name} came back SILENT (lufs=${lufs})`);
  R[name] = { path: `${A}/${name}.wav`, fromBeat, seconds, lufs,
              truePeak: r.report?.output?.truePeakDbtp };
  console.log(`  render ${name}: ${seconds.toFixed(3)}s  ${lufs.toFixed(2)} LUFS  `
              + `tp ${R[name].truePeak?.toFixed(2)}`);
}

await open();
await cmd("project.new", { discardChanges: false });
await cmd("transport.setTempo", { bpm: M.BPM_HOUSE });

// ── the five strips ─────────────────────────────────────────────────────────
const ID = {}, CLIP = {};
for (const p of M.PARTS) {
  const t = await cmd("track.add", { kind: "instrument", name: p.name });
  ID[p.name] = t.id || t.track?.id;
  await cmd("track.setInstrument", { trackId: ID[p.name], ...p.instrument });
  await cmd("track.setVolume", { trackId: ID[p.name], volume: p.volume });
  await cmd("track.setPan", { trackId: ID[p.name], pan: p.pan });
  const c = await cmd("clip.addMIDI", { trackId: ID[p.name], atBeat: 0,
                                        lengthBeats: M.LEN_BEATS,
                                        notes: p.notes, name: p.name });
  CLIP[p.name] = c.id || c.clip?.id;
  console.log(`  track ${p.name}: ${p.notes.length} notes`);
}
const ALL = Object.values(ID);
const ONLY = (...names) => names.map((x) => ID[x]);

// ── balance by measurement ──────────────────────────────────────────────────
const BAL = {};
for (const p of M.PARTS) {
  const g = await cmd("fx.add", { trackId: ID[p.name], kind: "gain",
                                  params: { gainLinear: 1 } });
  BAL[p.name] = { effectId: g.effectId || g.id, volume: p.volume };
}
for (const p of M.PARTS) {
  await bounce(`probe-${p.name}`, 32, 8.0, ONLY(p.name), ALL);
  const measured = R[`probe-${p.name}`].lufs;
  const gain = Math.pow(10, (TARGET[p.name] - measured) / 20);
  if (gain > 16) throw new Error(`${p.name} needs ${gain.toFixed(2)}x, past the +24 dB insert ceiling`);
  const res = await cmd("fx.setParam", { trackId: ID[p.name], effectId: BAL[p.name].effectId,
                                         name: "gainLinear", value: +gain.toFixed(4) });
  if (res && res.warnings && res.warnings.length)
    throw new Error(`${p.name} gain was CLAMPED: ${JSON.stringify(res.warnings)}`);
  Object.assign(BAL[p.name], { probedLufs: measured, target: TARGET[p.name],
                               gainLinear: +gain.toFixed(4),
                               gainDb: +(20 * Math.log10(gain)).toFixed(2) });
  console.log(`  balance ${p.name}: gain x${gain.toFixed(3)} `
              + `(${(20 * Math.log10(gain)).toFixed(2)} dB)  `
              + `${measured.toFixed(2)} -> ${TARGET[p.name]} LUFS`);
}

// ── renders at 124 ──────────────────────────────────────────────────────────
const P = ["Prelude"], PK = [...P, "Kick"], PKH = [...PK, "Hats"],
      PKHC = [...PKH, "Clap"], FULL = [...PKHC, "Bass"];
const S8 = M.SECS_8BARS_HOUSE;

await bounce("piano124", 0, S8, ONLY(...P), ALL);
await bounce("l2-kick", (M.ENTRY.kick - 1) * 4, 13.0, ONLY(...PK), ALL);
await bounce("l3-hats", (M.ENTRY.hats - 1) * 4, 13.0, ONLY(...PKH), ALL);
await bounce("l4-clap", (M.ENTRY.clap - 1) * 4, 13.0, ONLY(...PKHC), ALL);
await bounce("l5-bass", (M.ENTRY.bass - 1) * 4, 13.0, ONLY(...FULL), ALL);
await bounce("full", 0, M.SECS_HOUSE, ONLY(...FULL), ALL);
await bounce("ab-piano-src", 32, S8, ONLY(...P), ALL);
await bounce("ab-full-src", 32, S8, ONLY(...FULL), ALL);

// ── the tempo change, and the PROOF that it is the only change ──────────────
const before = (await cmd("clip.getNotes", { clipId: CLIP["Prelude"] })).notes
  .map((x) => [x.startBeat, x.pitch, x.lengthBeats, x.velocity]);
await cmd("transport.setTempo", { bpm: M.BPM_BACH });
const after = (await cmd("clip.getNotes", { clipId: CLIP["Prelude"] })).notes
  .map((x) => [x.startBeat, x.pitch, x.lengthBeats, x.velocity]);
const same = JSON.stringify(before) === JSON.stringify(after);
console.log(`  tempo 124 -> 72: ${before.length} notes before, ${after.length} after, `
            + `identical=${same}`);
if (!same) throw new Error("the tempo change moved notes — the film's claim is false");
await bounce("piano72", 0, M.SECS_8BARS_BACH, ONLY(...P), ALL);

// ── stills ──────────────────────────────────────────────────────────────────
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30,
                                 rowHeight: 50, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await shot("transport-72");                       // still at 72 BPM
await cmd("transport.setTempo", { bpm: M.BPM_HOUSE });
await shot("arrange");
await shot("transport-124");
await cmd("ui.showMixer", { show: true });
await shot("mixer");
await cmd("ui.showMixer", { show: false });

async function roll(name, clipId, ppb, centre) {
  await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: ppb,
                                   pianoRollRowHeight: 11, pianoRollMinimap: true });
  await cmd("debug.captureUI", { path: `${SHOTS}/${name}.png`, selectClip: clipId });
  await cmd("debug.panelLayout", { pianoRollCenterPitch: centre });
  await cmd("debug.captureUI", { path: `${SHOTS}/${name}.png`, selectClip: clipId });
  console.log(`  shot ${name}`);
}
await roll("roll-piano", CLIP["Prelude"], 12, 70);   // the whole 16-bar clip
await roll("roll-figure", CLIP["Prelude"], 90, 70);  // four bars, figure legible
await roll("roll-kick", CLIP["Kick"], 12, 40);
await roll("roll-bass", CLIP["Bass"], 12, 40);
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });

// ── bursts: the app PLAYING each layer, from that layer's own entry bar ─────
// ⛔ NOTHING MAY RENDER AFTER THIS POINT — see the header.
await burst("pianoplay", 13.0, 0);
for (const [name, beat] of [["kickplay", (M.ENTRY.kick - 1) * 4],
                            ["hatsplay", (M.ENTRY.hats - 1) * 4],
                            ["clapplay", (M.ENTRY.clap - 1) * 4],
                            ["bassplay", (M.ENTRY.bass - 1) * 4]])
  await burst(name, 13.0, beat, { arrange: true });
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.seek", { beats: 0 });

fs.writeFileSync(`${HERE}/renders.json`, JSON.stringify({
  bpm: { bach: M.BPM_BACH, house: M.BPM_HOUSE },
  counts: M.COUNTS, entry: M.ENTRY, roots: M.ROOTS, barPitches: M.BAR_PITCHES,
  barOnsets: M.BAR_ONSETS, bassDrop: M.BASS_DROP, balance: BAL,
  tempoChangeMovedNothing: same, pianoNotes: before.length,
  barSecondsHouse: 4 * 60 / M.BPM_HOUSE,
  secs8House: S8, secs8Bach: M.SECS_8BARS_BACH, secsHouse: M.SECS_HOUSE,
  renders: R,
}, null, 1));
console.log(`  wrote ${HERE}/renders.json`);
await close();
