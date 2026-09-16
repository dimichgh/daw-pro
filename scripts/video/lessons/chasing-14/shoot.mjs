// L6 "Chasing −14" — REBUILD. Pass 1: build the mix, render every master the
// film measures, and shoot every picture of the app.
//
// ⚠ STAGING ONLY. build.mjs refuses port 17600 outright.
//
// THE EXPERIMENT, stated before anything is rendered:
//
//   The mix renders at some integrated loudness L and some peak P. Reaching a
//   −14 LUFS target with a plain gain costs exactly (−14 − L) dB, because a
//   static gain moves integrated loudness one-for-one. That same gain moves the
//   PEAK by the same amount, to P + (−14 − L). Whether that lands above 0 dBFS
//   is a property of the MIX's peak-to-loudness ratio and nothing else.
//
//   So the film needs two renders of the same master: one in 32-bit FLOAT,
//   which stores samples above full scale happily, and one in 24-bit INTEGER,
//   which cannot and clamps. Their DIFFERENCE is the clipping, isolated.
//
// ⚠ `bitDepth: 32` IS 32-BIT INTEGER, and it clamps like every other integer
//   depth. The float render is the one that OMITS bitDepth entirely.
//
// THE LADDER. The whole known fault of the shipped film is that its clipping
// distortion sits ~28 dB under the film's own level — correctly measured and
// inaudible on a laptop. So the same clean/clipped pair is rendered at FOUR
// targets, −14 through −5, and the film shows where on that ladder the artefact
// climbs out of the floor. Nothing is faked: −14 stays −14, it just stops being
// the only rung.
import { open, cmd, addTrack, addClip, close, burst, shot } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS, SECS, NOTE_COUNT } from "./material.mjs";
import fs from "node:fs";

const AUD = process.env.C14_AUDIO || "./audio";
const SH = process.env.SESSION_SHOTS || "./shots";
const REN = SECS + 1.5;                      // render window, with a tail
const LADDER = [-14, -11, -8, -5];           // LUFS targets
const dbToLin = (db) => Math.pow(10, db / 20);
const facts = { bpm: BPM, bars: 16, seconds: SECS, notes: NOTE_COUNT,
                parts: PARTS.map(p => ({ name: p.name, volume: p.volume,
                                         notes: p.notes.length })) };

async function buildMix() {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: BPM });
  const ids = [];
  for (const p of PARTS) {
    const t = await addTrack(p.name, { instrument: p.instrument,
                                       volume: p.volume, pan: p.pan });
    const c = await addClip(t, 0, LEN_BEATS, p.notes, p.name);
    ids.push({ id: t, clip: c, name: p.name });
  }
  return ids;
}

const measure = () => cmd("render.measureLoudness", { durationSeconds: REN })
  .then(r => r.measurement);

/** float render — OMITS bitDepth, so peaks above 0 dBFS survive */
const renderFloat = (name) =>
  cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: REN });
/** 24-bit render — the delivery format, and the thing that clamps */
const render24 = (name) =>
  cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: REN,
                          bitDepth: 24 });

async function clearMaster() {
  const ov = await cmd("project.snapshot", {});
  for (const e of ov.masterEffects || []) {
    await cmd("fx.remove", { trackId: "master", effectId: e.id });
  }
}

await open();
const tracks = await buildMix();
console.log(`  mix: ${NOTE_COUNT} notes across ${PARTS.length} tracks, ${SECS}s`);

// ── 0. the pictures of the UNTOUCHED project, shot BEFORE a single master
//    insert exists. ⚠ An earlier cut shot both mixer stills after the chain was
//    built and got two BYTE-IDENTICAL files — a "before and after" that was the
//    same picture twice, and `md5 -q *.png | uniq -d` is what caught it.
await cmd("transport.seek", { beats: 0 });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32 });
await shot("arrange");
await cmd("ui.showMixer", { show: true });
await shot("mixer-dry");
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 20,
                                 pianoRollRowHeight: 11 });
await cmd("debug.captureUI", { path: `${SH}/roll.png`, selectClip: tracks[2].clip });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 42 });
await shot("roll");
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32 });

// ── 1. the mix, untouched ──────────────────────────────────────────────────
facts.dry = await measure();
await renderFloat("dry");
await render24("dry24");
console.log(`  dry  ${facts.dry.integratedLufs.toFixed(2)} LUFS  ` +
            `${facts.dry.truePeakDbtp.toFixed(2)} dBTP  ` +
            `LRA ${facts.dry.loudnessRangeLu.toFixed(2)}`);

// ── 2. the ladder: plain gain to each target, float AND 24-bit ─────────────
facts.ladder = [];
const gainFx = (await cmd("fx.add", { trackId: "master", kind: "gain",
                                      params: { gainLinear: 1 } })).effectId;
for (const target of LADDER) {
  const db = target - facts.dry.integratedLufs;
  await cmd("fx.setParam", { trackId: "master", effectId: gainFx,
                             name: "gainLinear", value: dbToLin(db) });
  const m = await measure();
  const tag = `g${String(target).replace("-", "")}`;
  await renderFloat(`${tag}f`);
  await render24(`${tag}24`);
  facts.ladder.push({ target, gainDb: db, gainLinear: dbToLin(db), tag, measured: m });
  // ⚠ THE NAIVE MOVE HAS TO BE PHOTOGRAPHED WHILE IT IS THE ONLY THING ON THE
  //   MASTER. The later fx-gain card is shot with the finished chain in place
  //   and reads +7.2 dB — the number master C needs, not the +6.48 the film
  //   says here. A panel showing one number while the voice says another is
  //   exactly the defect the house standard exists to stop.
  if (target === -14) {
    await cmd("debug.effectEditor", { open: true, trackId: "master", effectId: gainFx });
    await shot("fx-gain-naive");
    await cmd("debug.effectEditor", { close: true });
  }
  console.log(`  ${tag}  +${db.toFixed(2)} dB -> ${m.integratedLufs.toFixed(2)} LUFS  ` +
              `${m.truePeakDbtp.toFixed(2)} dBTP`);
}

// ── 3. master B: the SAME naive gain, with a true-peak limiter after it ────
//    Same drive, so what changes is only what the limiter does about it.
const naiveDb = LADDER[0] - facts.dry.integratedLufs;
await cmd("fx.setParam", { trackId: "master", effectId: gainFx,
                           name: "gainLinear", value: dbToLin(naiveDb) });
const limFx = (await cmd("fx.add", {
  trackId: "master", kind: "limiter", index: 1,
  // ⚠ truePeak DEFAULTS TO 0 (sample peak). A −1.0 dBTP delivery claim made
  //   with the default on would measure ~−0.3 dBTP and be wrong.
  params: { ceilingDb: -1.0, releaseMs: 120, truePeak: 1 },
})).effectId;
facts.limiterOnly = { gainDb: naiveDb, ceilingDb: -1.0, releaseMs: 120,
                      truePeak: true, measured: await measure() };
await renderFloat("limonly");
console.log(`  limonly  ${facts.limiterOnly.measured.integratedLufs.toFixed(2)} LUFS  ` +
            `${facts.limiterOnly.measured.truePeakDbtp.toFixed(2)} dBTP`);

// ── 4. master C: gain -> gentle compressor -> the same limiter ─────────────
//    The compressor is what buys back the loudness the limiter costs: it takes
//    the peaks down BEFORE the brickwall, so the whole thing can be driven
//    harder without the limiter having to grab as much.
const COMP = { thresholdDb: -18, ratio: 2, attackMs: 20, releaseMs: 180,
               kneeDb: 6, makeupDb: 6 };
const compFx = (await cmd("fx.add", { trackId: "master", kind: "compressor",
                                      index: 1, params: COMP })).effectId;

/** Solve the drive so the finished chain lands on `target` LUFS. A compressor
 *  plus a limiter is not a one-for-one gain, so this is a short secant search
 *  rather than arithmetic — and the number it lands on is REPORTED, not
 *  assumed. ⚠ It RE-SETS the winning gain before returning: an earlier version
 *  left the LAST TRIED value in the chain while reporting the one that was
 *  measured, so the render and the number disagreed by 0.17 dB. */
const MAX_GAIN_DB = 20 * Math.log10(16);      // one gain insert's ceiling

/** Set a total drive in dB, splitting it across the gain inserts available.
 *  ⚠ fx.setParam CLAMPS SILENTLY (it reports the clamp in `warnings`, which is
 *  the only reason this was ever noticed) — a single insert stops at +24.08 dB
 *  and every further solver step then measures the identical loudness. */
async function setDrive(db, second) {
  const a = Math.min(db, second ? MAX_GAIN_DB : Infinity);
  const r = await cmd("fx.setParam", { trackId: "master", effectId: gainFx,
                                       name: "gainLinear", value: dbToLin(a) });
  if (r.warnings?.length) console.log(`    ⚠ gain clamped: ${r.warnings[0]}`);
  if (second) {
    await cmd("fx.setParam", { trackId: "master", effectId: second,
                               name: "gainLinear", value: dbToLin(Math.max(0, db - a)) });
  }
}

async function solveDrive(start, target, second) {
  let g = start, best = null, bestG = start;
  for (let i = 0; i < 10; i++) {
    await setDrive(g, second);
    const m = await measure();
    console.log(`    solve ${target}: +${g.toFixed(2)} dB -> ${m.integratedLufs.toFixed(2)} LUFS`);
    const err = target - m.integratedLufs;
    if (best === null || Math.abs(err) < Math.abs(target - best.integratedLufs)) {
      best = m; bestG = g;
    }
    if (Math.abs(err) < 0.06) break;
    g += err * 1.6;
  }
  await setDrive(bestG, second);
  return { gainDb: bestG, measured: best };
}

const md = await solveDrive(naiveDb, -14.0);
facts.mastered = { ...md, compressor: COMP, ceilingDb: -1.0, releaseMs: 120,
                   truePeak: true };
await renderFloat("mastered");
await render24("mastered24");
console.log(`  mastered  +${md.gainDb.toFixed(2)} dB  ` +
            `${md.measured.integratedLufs.toFixed(2)} LUFS  ` +
            `${md.measured.truePeakDbtp.toFixed(2)} dBTP  ` +
            `LRA ${md.measured.loudnessRangeLu.toFixed(2)}`);

// ── 4b. WHAT THE COMPRESSOR ACTUALLY DID, measured rather than described.
//    Two renders at the SAME drive with the limiter out: compressor bypassed,
//    then engaged. Dividing one by the other sample for sample IS the
//    compressor's own gain signal — no makeup, no mix, nothing else in the way.
await cmd("fx.setBypass", { trackId: "master", effectId: limFx, bypassed: true });
await cmd("fx.setBypass", { trackId: "master", effectId: compFx, bypassed: true });
await renderFloat("compoff");
await cmd("fx.setBypass", { trackId: "master", effectId: compFx, bypassed: false });
await renderFloat("compin");
await cmd("fx.setBypass", { trackId: "master", effectId: limFx, bypassed: false });

// ── 4c. master D: the same idea driven to −8 LUFS, which is where a great
//    deal of released music actually sits.
//
//    ⚠ MEASURED, AND IT CHANGED THE DESIGN: ONE GAIN INSERT TOPS OUT at
//    +24.08 dB (gainLinear 16) and clamps SILENTLY. The first attempt at this
//    master ran seven identical solver steps against a clamped parameter and
//    reported a confident, wrong −12.40 LUFS. Master D needs +35 dB of drive,
//    so it gets a second gain stage — and WHY it needs that much is itself the
//    lesson: above the threshold a 2:1 compressor gives back half a decibel for
//    every decibel you feed it, so the fader number runs away from you.
//
//    The COMPRESSOR IS THE SAME as master C's. Nothing about the chain changes
//    between C and D except how hard it is driven.
const gain2 = (await cmd("fx.add", { trackId: "master", kind: "gain", index: 1,
                                     params: { gainLinear: 1 } })).effectId;
const lw = await solveDrive(md.gainDb + 22, -8.0, gain2);
facts.loudwar = { ...lw, compressor: COMP, ceilingDb: -1.0,
                  note: "two gain stages: one insert clamps at +24.08 dB" };
await renderFloat("loudwar");
console.log(`  loudwar  +${lw.gainDb.toFixed(2)} dB  ` +
            `${lw.measured.integratedLufs.toFixed(2)} LUFS  ` +
            `${lw.measured.truePeakDbtp.toFixed(2)} dBTP  ` +
            `LRA ${lw.measured.loudnessRangeLu.toFixed(2)}`);

// ── put the chain back the way master C had it, because that is what gets
//    photographed and what the narration reads its numbers off.
await cmd("fx.remove", { trackId: "master", effectId: gain2 });
await cmd("fx.setParam", { trackId: "master", effectId: gainFx,
                           name: "gainLinear", value: dbToLin(md.gainDb) });
const backCheck = await measure();
facts.restoreCheck = backCheck;
console.log(`  restored  ${backCheck.integratedLufs.toFixed(2)} LUFS ` +
            `(master C measured ${md.measured.integratedLufs.toFixed(2)})`);

// ── 5. the pictures of the MASTERED project ────────────────────────────────
//    Shot on the finished master chain, so the app on screen IS the thing the
//    film has just measured.
await cmd("transport.seek", { beats: 0 });
await cmd("ui.showMixer", { show: false });

// the three master inserts, each on its own card
for (const [name, id] of [["fx-gain", gainFx], ["fx-comp", compFx], ["fx-lim", limFx]]) {
  await cmd("debug.effectEditor", { open: true, trackId: "master", effectId: id });
  await shot(name);
  await cmd("debug.effectEditor", { close: true });
}
await cmd("ui.showMixer", { show: true });
await shot("mixer-mastered");

// ── ⛔ THE APP'S OWN LIVE LOUDNESS READOUT WAS SHOT AND THEN DELIBERATELY
//    DROPPED, and the reason belongs in the script rather than in a comment
//    somewhere else. The master strip carries live M / S / I / LRA / TP figures
//    and they are exactly the meters this lesson is about — but they are
//    POST-FADER. Every other burst in this repo drops the master to 0.03 so a
//    build does not shout out of the machine's speakers at night, and at 0.03
//    the readout measured I −40.2 LUFS on a master the renders put at −14.05.
//    A wrong number on screen is worse than no picture, and the honest fix
//    (master at unity) means playing the mix out loud on a sleeping user's
//    laptop — measured: system output volume 38, not muted. So the film reads
//    its loudness off the RENDERS and the charts, and the app appears through
//    the mixer stills and the three insert cards above.

await cmd("ui.showMixer", { show: false });

// real motion: the transport actually running across the arrangement
await burst("c14-arrange", 9.0, 0, { arrange: true });

await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
fs.writeFileSync(`${AUD}/facts.json`, JSON.stringify(facts, null, 1));
console.log(`  facts.json written`);
close();
process.exit(0);
