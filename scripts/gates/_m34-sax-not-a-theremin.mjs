// "no more separate between note, but all of them sound more like Theremin not Sax"
//
// ⭐⭐ THE SEPARATION PROBLEM IS SOLVED — continuous legato fixed it. What is
// left is that a THEREMIN is precisely: a continuous tone that SLIDES between
// pitches, with heavy vibrato and no consonants. I introduced two of those.
//
//  ① ⛔ GLIDE. I set `glideTime: 0.03` when I switched to legato. THE USER'S OWN
//     EARLIER PICK (E) HAD glideTime 0. A saxophone does not portamento between
//     notes — the fingers close holes, so pitch changes ESSENTIALLY INSTANTLY
//     while the tone continues. "Continuous tone + pitch slide" is the defining
//     sound of a theremin, and it is the one thing I changed.
//     ⚠️ Our engine supports exactly this: `voiceMode: legato` with
//     `glideTime: 0` is voice CONTINUATION with the pitch STEPPING — a slur
//     without a slide, which is what a wind player actually does.
//
//  ② VIBRATO. 22 cents on 36 of 40 notes is continuous and even; a theremin
//     player leans on vibrato constantly, a saxophonist uses it sparingly and
//     mostly late in a held note.
//
// ⚠️ 2×2, because these are independent and the user reads a 2×2 well (they
// picked cleanly from the last one). Everything else is held at the take they
// just approved the CONTINUITY of: overlapping notes, legato, breath on,
// brightness off, startFrame 80 ms.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-not-a-theremin";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-theremin";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0, SR = 48000;
const MAX_SLUR = 4, PHRASE_BREATH = 0.30, START_MS = 80, SPACING = -0.08;
const LEAP_TONGUE = 5;   // semitones: a leap wider than this gets RE-ARTICULATED

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `th${++n}`;
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

  // ⭐ FIX THE SLURRED OCTAVE while I am here — flagged last round and it is
  // plainly wrong: a leap of an octave is the ONE place every player tongues.
  // Breaking the slur there also removes the worst sample-stretch in the part.
  const groups = [];
  let g = [0], leapBreaks = 0;
  for (let i = 0; i < ORIG.length - 1; i++) {
    const phraseEnd = (ORIG[i + 1].startBeat - ORIG[i].startBeat) >= 2.0;
    const bigLeap = Math.abs(ORIG[i + 1].pitch - ORIG[i].pitch) > LEAP_TONGUE;
    if (bigLeap) leapBreaks++;
    if (g.length >= MAX_SLUR || phraseEnd || bigLeap) {
      groups.push({ idx: g, phraseEnd: phraseEnd || bigLeap }); g = [i + 1];
    } else g.push(i + 1);
  }
  groups.push({ idx: g, phraseEnd: true });
  console.log(`${groups.length} slur groups; ${leapBreaks} slur(s) broken at a leap > ${LEAP_TONGUE} semitones`);

  const notes = ORIG.map((x) => ({ ...x }));
  for (const grp of groups) {
    for (let k = 0; k < grp.idx.length; k++) {
      const i = grp.idx[k], isLast = k === grp.idx.length - 1;
      const nextStart = i + 1 < ORIG.length ? ORIG[i + 1].startBeat : ORIG[i].startBeat + ORIG[i].lengthBeats;
      const end = !isLast ? nextStart + 0.08
                : grp.phraseEnd ? nextStart - PHRASE_BREATH : nextStart - SPACING;
      const minEnd = ORIG[i].startBeat + 0.22;
      const maxEnd = ORIG[i].startBeat + ORIG[i].lengthBeats + Math.max(0, -SPACING) + 0.10;
      notes[i].lengthBeats = Math.max(0.22, Math.min(Math.max(end, minEnd), maxEnd) - ORIG[i].startBeat);
    }
  }

  const frames = Math.round((START_MS / 1000) * SR);
  const patches = baseZones.map((z) => ({ id: z.id, startFrame: frames }));

  //        vibrato 22c (as heard)      vibrato 8c (light)
  // glide0        P                            Q
  // glide.03      R  (= what you heard)        S
  const TAKES = [
    { f: "P-noglide-vib22.wav", glide: 0.0,  vib: 22, why: "NO SLIDE, vibrato as you heard it" },
    { f: "Q-noglide-vib8.wav",  glide: 0.0,  vib: 8,  why: "NO SLIDE, light vibrato" },
    { f: "R-glide-vib22.wav",   glide: 0.03, vib: 22, why: "what you just heard, for reference" },
    { f: "S-glide-vib8.wav",    glide: 0.03, vib: 8,  why: "slide kept, vibrato lightened" },
  ];

  // Level once on the first configuration.
  await cmd("clip.setNotes", { clipId: clip.id, notes });
  await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35 });
  await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "legato", glideTime: 0.0, expressionFilterDepth: 0, zonePatches: patches } });
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
  console.log(`level: neutral ${neutral.integratedLufs.toFixed(2)} → target ${TARGET}\n`);

  console.log(`=== 2x2 (axes: pitch SLIDE between notes, and vibrato depth) ===`);
  for (const k of TAKES) {
    await cmd("clip.setNotes", { clipId: clip.id, notes });
    const br = await cmd("clip.applyBreathContour", {
      clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2,
      vibratoDepthCents: k.vib, vibratoOnsetSeconds: 0.35,
    });
    if (!(br?.notesTouched > 0)) throw new Error(`breath touched ${br?.notesTouched} notes for ${k.f}`);

    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: "legato", glideTime: k.glide, glideMode: "constantRate",
                 expressionFilterDepth: 0, zonePatches: patches } });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== "legato") throw new Error(`voiceMode did not take for ${k.f}`);
    // ⭐ A SETTER'S RETURN IS NOT PROOF. Glide is THE axis here — if it silently
    // failed, P/Q and R/S would be the same file under different names.
    if (Math.abs((d.glideTime ?? -1) - k.glide) > 1e-9)
      throw new Error(`glideTime did not take for ${k.f}: asked ${k.glide}, got ${d.glideTime}`);
    if (k.glide > 0 && d.glideEffective === false)
      throw new Error(`${k.f} asked for glide but the engine reports glideEffective=false`);

    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(24)} glide=${String(k.glide).padEnd(5)} vib=${String(k.vib).padStart(2)}c  ${m.integratedLufs.toFixed(2)} LUFS  — ${k.why}`);
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
