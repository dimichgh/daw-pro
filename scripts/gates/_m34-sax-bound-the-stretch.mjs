// The theremin IS the stretch. So bound the stretch — one axis, four steps.
//
// ⭐⭐ WHAT THE USER'S EARS ESTABLISHED, AND WHAT MEASUREMENT SAID BACK:
//   "some notes sound like sax ... then theremin" — PER NOTE, not per section.
//   I guessed the second half was worse and CHECKED: it is not (mean drift 4.0
//   vs 4.3, worst 10 vs 10). What the numbers DO show is a wide spread — a mean
//   of ~4 semitones with a worst of 10. A note sitting on its sample's home
//   pitch sounds right; a note whose sample has been stretched 8-10 semitones
//   has its formants shifted most of an octave and sounds synthetic. That is
//   the theremin, and it is m34-y ① heard directly.
//
// ⛔ EVERY KNOB SO FAR TRADED SEPARATION AGAINST SLIDING AND LEFT THE STRETCH
//    ALONE. Glide off → notes separate. Glide on → seamless but theremin. The
//    stretch was the held variable the whole time.
//
// ⭐ THE AXIS: MAXIMUM SEMITONES A VOICE MAY DRAG ITS SAMPLE.
//    T  ≤1  — `poly`: EVERY note takes its own zone, so with roots every 2
//             semitones nothing is ever more than 1 semitone from home. Tails
//             overlap instead of choking, so the line still joins up.
//    U  ≤2  — legato, but the slur BREAKS before the voice drifts past 2.
//    V  ≤4  — legato, looser.
//    W  ≤10 — legato uncapped: this is take P, the reference.
//
// ⚠️ POLY IS THE INTERESTING ONE AND IT HAS NEVER BEEN TRIED WITH `startFrame`.
//    Poly was dismissed early for re-attacking every note — but that was before
//    the recorded tongue could be skipped. Poly + startFrame is "own zone, no
//    recorded attack, overlapping tails", which is the closest this engine can
//    currently get to what m34-y would do properly.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-bound-the-stretch";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-stretch";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0, SR = 48000, START_MS = 80;
const PHRASE_BREATH = 0.30, SLUR_OVERLAP = 0.08;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `bs${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 240000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
async function cmd(c, p = {}) {
  const r = await raw(c, p);
  if (!r.ok) throw new Error(`${c} REFUSED :: ${r.error ?? JSON.stringify(r.result)}`);
  return r.result;
}
const lufsOf = async () => (await cmd("render.measureLoudness", {})).measurement;
const zonesOf = async (id) => {
  const s = await cmd("project.snapshot");
  return (s.tracks ?? []).find((t) => t.id === id)?.instrument?.sampler?.zones ?? [];
};

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const ORIG = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  if (ORIG.length !== (got.totalNotes ?? ORIG.length)) throw new Error("partial read");

  const baseZones = await zonesOf(sax.id);
  if (!baseZones.length) throw new Error("no zones — refusing to patch blind");
  const zoneFor = (p, v = 100) => baseZones.find((z) =>
    p >= z.minPitch && p <= z.maxPitch &&
    v >= (z.minVelocity ?? 0) && v <= (z.maxVelocity ?? 127)) ?? null;
  if (!zoneFor(baseZones[0].rootPitch, (baseZones[0].minVelocity ?? 0) + 1) || zoneFor(3))
    throw new Error("zone-mapper controls failed");

  // Group so that no voice ever drifts further than `cap` from ITS OWN sample's
  // root — the drift is measured against the GROUP HEAD's zone, which is the
  // zone the whole group will be locked to.
  function group(cap) {
    const groups = []; let g = [0];
    const rootOf = (i) => zoneFor(ORIG[i].pitch, ORIG[i].velocity ?? 100)?.rootPitch ?? ORIG[i].pitch;
    let head = 0;
    for (let i = 0; i < ORIG.length - 1; i++) {
      const phraseEnd = (ORIG[i + 1].startBeat - ORIG[i].startBeat) >= 2.0;
      const wouldDrift = Math.abs(ORIG[i + 1].pitch - rootOf(head));
      if (phraseEnd || wouldDrift > cap) { groups.push({ idx: g, phraseEnd }); g = [i + 1]; head = i + 1; }
      else g.push(i + 1);
    }
    groups.push({ idx: g, phraseEnd: true });
    const out = ORIG.map((x) => ({ ...x }));
    for (const grp of groups) {
      for (let k = 0; k < grp.idx.length; k++) {
        const i = grp.idx[k], isLast = k === grp.idx.length - 1;
        const nextStart = i + 1 < ORIG.length ? ORIG[i + 1].startBeat : ORIG[i].startBeat + ORIG[i].lengthBeats;
        // Notes ALWAYS overlap — inside a group that is the slur; at a boundary
        // it lets the outgoing tail cover the incoming note instead of a gap.
        const end = grp.phraseEnd && isLast ? nextStart - PHRASE_BREATH : nextStart + SLUR_OVERLAP;
        const minEnd = ORIG[i].startBeat + 0.22;
        const maxEnd = ORIG[i].startBeat + ORIG[i].lengthBeats + SLUR_OVERLAP + 0.10;
        out[i].lengthBeats = Math.max(0.22, Math.min(Math.max(end, minEnd), maxEnd) - ORIG[i].startBeat);
      }
    }
    // Report the drift this grouping ACTUALLY achieves, per take.
    let worst = 0, sum = 0, cnt = 0;
    for (const grp of groups) {
      const r = zoneFor(ORIG[grp.idx[0]].pitch, ORIG[grp.idx[0]].velocity ?? 100)?.rootPitch ?? 0;
      for (const i of grp.idx) { const d = Math.abs(ORIG[i].pitch - r); worst = Math.max(worst, d); sum += d; cnt++; }
    }
    return { notes: out, groups: groups.length, worst, mean: sum / cnt };
  }

  const frames = Math.round((START_MS / 1000) * SR);
  const patches = baseZones.map((z) => ({ id: z.id, startFrame: frames }));

  const TAKES = [
    { f: "T-stretch-max1-poly.wav", mode: "poly",   cap: 99, why: "EVERY note takes its own sample — stretch can never exceed 1 semitone" },
    { f: "U-stretch-max2.wav",      mode: "legato", cap: 2,  why: "slur breaks before the sample stretches past 2 semitones" },
    { f: "V-stretch-max4.wav",      mode: "legato", cap: 4,  why: "looser — up to 4 semitones" },
    { f: "W-stretch-max10.wav",     mode: "legato", cap: 99, why: "uncapped — this is take P, your reference" },
  ];

  // Level once.
  const first = group(TAKES[0].cap);
  await cmd("clip.setNotes", { clipId: clip.id, notes: first.notes });
  await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35 });
  await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "poly", glideTime: 0.0, expressionFilterDepth: 0, zonePatches: patches } });
  const snap = await cmd("project.snapshot");
  if (!Array.isArray(snap.masterEffects)) throw new Error("snapshot.masterEffects missing");
  for (const e of snap.masterEffects) await cmd("fx.remove", { trackId: "master", effectId: e.id });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });
  const neutral = await lufsOf();
  const gg = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = gg.effectId ?? gg.effect?.id;
  if (!gid) throw new Error("fx.add gain returned no id");
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear",
    value: Math.max(0.02, Math.min(4.0, Math.pow(10, (TARGET - neutral.integratedLufs) / 20))) });
  await cmd("fx.add", { trackId: "master", kind: "limiter" });
  console.log(`level: neutral ${neutral.integratedLufs.toFixed(2)} → target ${TARGET}`);
  console.log(`held: no glide, breath on, brightness off, startFrame ${frames} (${START_MS} ms)\n`);

  console.log(`=== LADDER (axis: how far a sample may be STRETCHED) ===`);
  for (const k of TAKES) {
    const gr = group(k.cap);
    await cmd("clip.setNotes", { clipId: clip.id, notes: gr.notes });
    const br = await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35 });
    if (!(br?.notesTouched > 0)) throw new Error(`breath touched ${br?.notesTouched} notes for ${k.f}`);
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: k.mode, glideTime: 0.0, expressionFilterDepth: 0, zonePatches: patches } });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== k.mode) throw new Error(`voiceMode did not take for ${k.f}: ${d.voiceMode}`);

    // Under poly every note gets its OWN zone, so the effective stretch is
    // whatever its own zone gives it — never the group figure.
    const eff = k.mode === "poly"
      ? { worst: Math.max(...ORIG.map((x) => Math.abs(x.pitch - (zoneFor(x.pitch, x.velocity ?? 100)?.rootPitch ?? x.pitch)))), mean: null, groups: ORIG.length }
      : gr;

    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(26)} ${m.integratedLufs.toFixed(2)} LUFS  WORST STRETCH ${String(eff.worst).padStart(2)} semitones (${Math.pow(2, eff.worst / 12).toFixed(2)}x)  — ${k.why}`);
  }

  console.log(`\nproject NOT saved.`);
  console.log(`open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  process.exit(process.exitCode ?? 0);   // see m34-z
}
