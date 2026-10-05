// "It should sustain while breathing dynamic keeps it human." — the user, and
// they are right on both halves.
//
// ⭐⭐ TWO THINGS WERE WRONG WITH THE LAST FOUR TAKES, AND THE SECOND IS MINE.
//
//  ① The "gaps" I wrote between slur groups are NOT silence. Zone release is
//     0.5 s (measured) and my tongue gap was 0.18 beats = 117 ms at 92 BPM, so
//     the departing note is still sounding at ~40% when the next one snaps back
//     to full sustain. THE AUDIBLE EVENT IS AN AMPLITUDE STEP, not the recorded
//     tongue — which is why skipping the tongue with startFrame (H..K) changed
//     so little. The user heard this and described it exactly.
//
//  ② ⛔ IN `mono`, THE NOTE OVERLAPS I AUTHORED DO NOTHING. Mono chokes the
//     sounding voice and triggers a NEW one on every note-on, overlapped or not
//     — only `.legato` CONTINUES a voice. So all four takes re-attacked all 40
//     notes and none of the phrasing could help. I shipped a ladder whose held
//     variable silently defeated its own axis.
//
// So: `legato`, and notes that genuinely OVERLAP, so the voice never stops
// inside a phrase. Articulation then comes from the BREATH CONTOUR's dynamics
// rather than from silence — which is how a wind player slurs.
//
// ⚠️ ONE AXIS: how much space sits between slur groups, from clearly separated
// to fully continuous. Everything else is held — legato, breath on, brightness
// off (their pick), startFrame 80 ms so that where a voice DOES re-trigger it
// does not replay the recorded tongue.
//
// ⚠️ THE COST IS KNOWN AND PRINTED, NOT HIDDEN: the longer a voice runs, the
// further it varispeeds its ONE locked sample (m34-y ①). This script reports the
// worst drift per take so the trade is visible rather than discovered later.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-never-stop";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-neverstop";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0, SR = 48000;
const MAX_SLUR = 4;          // notes per slur group
const PHRASE_BREATH = 0.30;  // beats of real breath where the composer wrote a rest
const START_MS = 80;         // skip the recorded tongue where a trigger DOES happen

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ns${++n}`;
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
const NM = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
const nn = (m) => `${NM[((m % 12) + 12) % 12]}${Math.floor(m / 12) - 1}`;

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const ORIG = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  if (ORIG.length !== (got.totalNotes ?? ORIG.length))
    throw new Error("partial read — a whole-array write would DELETE the rest");
  console.log(`sax clip: ${ORIG.length} notes`);

  const baseZones = await zonesOf(sax.id);
  if (!baseZones.length) throw new Error("no zones — refusing to patch blind");
  const zoneFor = (p, v = 100) => baseZones.find((z) =>
    p >= z.minPitch && p <= z.maxPitch &&
    v >= (z.minVelocity ?? 0) && v <= (z.maxVelocity ?? 127)) ?? null;
  if (!zoneFor(baseZones[0].rootPitch, (baseZones[0].minVelocity ?? 0) + 1) || zoneFor(3))
    throw new Error("zone-mapper controls failed — its hits would prove nothing");

  // Build the note list for a given inter-group spacing.
  // spacing > 0 → silence between groups; = 0 → they abut; < 0 → they OVERLAP,
  // which under legato means the voice never stops and the groups merge into one
  // continuous phrase.
  function articulate(spacing) {
    const groups = [];
    let g = [0];
    for (let i = 0; i < ORIG.length - 1; i++) {
      const phraseEnd = (ORIG[i + 1].startBeat - ORIG[i].startBeat) >= 2.0;
      if (g.length >= MAX_SLUR || phraseEnd) { groups.push({ idx: g, phraseEnd }); g = [i + 1]; }
      else g.push(i + 1);
    }
    groups.push({ idx: g, phraseEnd: true });

    const out = ORIG.map((x) => ({ ...x }));
    for (const grp of groups) {
      for (let k = 0; k < grp.idx.length; k++) {
        const i = grp.idx[k], isLast = k === grp.idx.length - 1;
        const nextStart = i + 1 < ORIG.length ? ORIG[i + 1].startBeat : ORIG[i].startBeat + ORIG[i].lengthBeats;
        // Inside a group the note ALWAYS overlaps the next (that is the slur).
        // Only the group's last note is governed by `spacing`.
        const end = !isLast ? nextStart + 0.08
                  : grp.phraseEnd ? nextStart - PHRASE_BREATH
                  : nextStart - spacing;
        const minEnd = ORIG[i].startBeat + 0.22;
        const maxEnd = ORIG[i].startBeat + ORIG[i].lengthBeats + Math.max(0, -spacing) + 0.10;
        out[i].lengthBeats = Math.max(0.22, Math.min(Math.max(end, minEnd), maxEnd) - ORIG[i].startBeat);
      }
    }
    return out;
  }

  // How long does a voice actually run, and how far does it drag its sample?
  function analyse(arr) {
    const s = arr.slice().sort((a, b) => a.startBeat - b.startBeat);
    let longest = 1, cur = 1, worstDrift = 0, runHead = s[0];
    for (let i = 1; i < s.length; i++) {
      const prev = s[i - 1];
      if (s[i].startBeat < prev.startBeat + prev.lengthBeats - 1e-9) {
        cur++; longest = Math.max(longest, cur);
        const z = zoneFor(runHead.pitch, runHead.velocity ?? 100);
        if (z) worstDrift = Math.max(worstDrift, Math.abs(s[i].pitch - z.rootPitch));
      } else { cur = 1; runHead = s[i]; }
    }
    return { longest, worstDrift };
  }

  const TAKES = [
    { f: "L-separated.wav",  sp: 0.10, why: "groups clearly separated (65 ms)" },
    { f: "M-touching.wav",   sp: 0.02, why: "barely separated (13 ms)" },
    { f: "N-abutting.wav",   sp: 0.00, why: "groups meet exactly — no silence, but the voice still restarts" },
    { f: "O-continuous.wav", sp: -0.08, why: "groups OVERLAP — the voice never stops inside a phrase" },
  ];

  // Level once on the first take's material.
  await cmd("clip.setNotes", { clipId: clip.id, notes: articulate(TAKES[0].sp) });
  await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35 });
  const frames = Math.round((START_MS / 1000) * SR);
  const sampler = { voiceMode: "legato", glideTime: 0.03, glideMode: "constantRate", expressionFilterDepth: 0,
                    zonePatches: baseZones.map((z) => ({ id: z.id, startFrame: frames })) };
  await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler", sampler });

  const snap = await cmd("project.snapshot");
  if (!Array.isArray(snap.masterEffects)) throw new Error("snapshot.masterEffects missing — refusing to level blind");
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
  console.log(`held for every take: legato, breath on, brightness off, startFrame ${frames} (${START_MS} ms)\n`);

  console.log(`=== LADDER (axis: space between slur groups) ===`);
  for (const k of TAKES) {
    const notes = articulate(k.sp);
    await cmd("clip.setNotes", { clipId: clip.id, notes });
    const br = await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35 });
    if (!(br?.notesTouched > 0)) throw new Error(`breath touched ${br?.notesTouched} notes for ${k.f}`);
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler", sampler });

    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== "legato") throw new Error(`voiceMode did not take for ${k.f}: ${d.voiceMode}`);
    const back = await cmd("clip.getNotes", { clipId: clip.id });
    if ((back.notes ?? []).length !== ORIG.length) throw new Error(`note count changed for ${k.f}`);

    const a = analyse(back.notes ?? []);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(18)} ${m.integratedLufs.toFixed(2)} LUFS  longest unbroken voice ${String(a.longest).padStart(2)} notes, worst sample drift ${String(a.worstDrift).padStart(2)} semitones  — ${k.why}`);
  }

  console.log(`\n⚠️ The drift column is the COST (m34-y ①): a longer unbroken voice keeps`);
  console.log(`   ONE sample further from its root, so smoother also means thinner.`);
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
