// "As if on each note it makes a new blow" — so stop replaying the blow.
//
// ⭐ THE USER PICKED E (phrased + mono) as closest to a sax, then named exactly
// the cost of mono: every note re-attacks. THE ATTACK THEY HEAR IS NOT AN
// ENVELOPE — it is RECORDED. Each zone file is one sustained note captured with
// the player's own tongue on the front, and MEASURED (ffmpeg, 10 ms windows,
// A#3_v2) that onset ramps −27.7 dB → about −7.5 dB and plateaus by ~70-80 ms.
// Restarting the sample at frame 0 replays that tongue, 40 times a chorus.
//
// So the lever is `startFrame`: begin each note PAST the recorded attack, in the
// steady part of the tone. The note still gets its OWN zone (so the timbre and
// formants stay right, unlike legato's zone-lock, m34-y) but no longer re-blows.
//
// ⚠️ ONE AXIS ONLY: how many frames of recorded attack to skip. Voice mode,
// phrasing, breath and brightness are all held at exactly the user's pick (mono,
// short slurs, breath on, expressionFilterDepth 0). `attack` stays at the
// library's 0.002 s — 96 frames at 48 kHz, already enough of a ramp to de-click
// a mid-waveform start, so it does NOT need to become a second variable.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-skip-the-blow";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-skipblow";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;
const SR = 48000;                 // every zone file measured at 48 kHz

const MAX_SLUR = 3, SLUR_OVERLAP = 0.08, TONGUE_GAP = 0.18, BREATH_GAP = 0.55;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `sb${++n}`;
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
const zonesOf = async (trackId) => {
  const s = await cmd("project.snapshot");
  return (s.tracks ?? []).find((t) => t.id === trackId)?.instrument?.sampler?.zones ?? [];
};

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  // ---------- 1. reproduce the user's pick: phrasing ----------
  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const notes = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  if (notes.length !== (got.totalNotes ?? notes.length))
    throw new Error(`partial read — a whole-array write would DELETE the rest`);

  const groups = [];
  let g = [0];
  for (let i = 0; i < notes.length - 1; i++) {
    const phraseEnd = (notes[i + 1].startBeat - notes[i].startBeat) >= 2.0;
    if (g.length >= MAX_SLUR || phraseEnd) { groups.push({ idx: g, phraseEnd }); g = [i + 1]; }
    else g.push(i + 1);
  }
  groups.push({ idx: g, phraseEnd: true });

  const out = notes.map((x) => ({ ...x }));
  for (const grp of groups) {
    for (let k = 0; k < grp.idx.length; k++) {
      const i = grp.idx[k], isLast = k === grp.idx.length - 1;
      const nextStart = i + 1 < notes.length ? notes[i + 1].startBeat : notes[i].startBeat + notes[i].lengthBeats;
      const end = !isLast ? nextStart + SLUR_OVERLAP
                : grp.phraseEnd ? nextStart - BREATH_GAP : nextStart - TONGUE_GAP;
      const minEnd = notes[i].startBeat + 0.22, maxEnd = notes[i].startBeat + notes[i].lengthBeats;
      out[i].lengthBeats = Math.max(0.22, Math.min(Math.max(end, minEnd), maxEnd) - notes[i].startBeat);
    }
  }
  const overlaps = (a) => { let c = 0; for (let i = 0; i < a.length - 1; i++) if (a[i].startBeat + a[i].lengthBeats > a[i + 1].startBeat + 1e-9) c++; return c; };
  if (overlaps(out) >= overlaps(notes)) throw new Error("articulation did not change — refusing a no-op");
  await cmd("clip.setNotes", { clipId: clip.id, notes: out });
  console.log(`phrasing: ${groups.length} slur groups, slurred adjacencies ${overlaps(notes)} → ${overlaps(out)}`);

  // ---------- 2. reproduce the user's pick: breath, no brightness ----------
  const br = await cmd("clip.applyBreathContour", {
    clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 22, vibratoOnsetSeconds: 0.35,
  });
  if (!(br?.notesTouched > 0)) throw new Error(`breath contour touched ${br?.notesTouched} notes — refusing to label takes "with breath" that have none`);
  console.log(`breath: ${br.notesTouched} notes, ${br.notesWithVibrato} with vibrato, ${br.expressionPointCount} expression points`);

  // ---------- 3. the axis ----------
  const baseZones = await zonesOf(sax.id);
  if (!baseZones.length) throw new Error("no zones on the sax track — refusing to patch blind");
  console.log(`zones: ${baseZones.length}`);

  const TAKES = [
    { f: "H-blow-0ms.wav",   ms: 0,   why: "your pick E, unchanged — the full recorded tongue on every note" },
    { f: "I-blow-50ms.wav",  ms: 50,  why: "skip half the recorded attack" },
    { f: "J-blow-80ms.wav",  ms: 80,  why: "start just past it, where the tone plateaus (MEASURED at ~70-80 ms)" },
    { f: "K-blow-120ms.wav", ms: 120, why: "start well inside the steady tone" },
  ];

  // Level ONCE, on the baseline, so every take shares gain staging.
  await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "mono", glideTime: 0.0, expressionFilterDepth: 0,
               zonePatches: baseZones.map((z) => ({ id: z.id, startFrame: 0 })) } });
  const snap = await cmd("project.snapshot");
  const chain = snap.masterEffects;
  if (!Array.isArray(chain)) throw new Error("snapshot.masterEffects missing — refusing to level blind");
  for (const e of chain) await cmd("fx.remove", { trackId: "master", effectId: e.id });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });
  const neutral = await lufsOf();
  const gg = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = gg.effectId ?? gg.effect?.id;
  if (!gid) throw new Error("fx.add gain returned no id");
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear",
    value: Math.max(0.02, Math.min(4.0, Math.pow(10, (TARGET - neutral.integratedLufs) / 20))) });
  await cmd("fx.add", { trackId: "master", kind: "limiter" });
  console.log(`level: neutral ${neutral.integratedLufs.toFixed(2)} → target ${TARGET}\n`);

  console.log(`=== LADDER (axis: how much of the RECORDED blow each note skips) ===`);
  for (const k of TAKES) {
    const frames = Math.round((k.ms / 1000) * SR);
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: "mono", glideTime: 0.0, expressionFilterDepth: 0,
                 zonePatches: baseZones.map((z) => ({ id: z.id, startFrame: frames })) } });

    // ⭐ A SETTER'S RETURN IS NOT PROOF IT TOOK. Read the zones back and check
    // EVERY one — a patch that silently applied to none would render four
    // identical files with four different names, which is worse than an error.
    const after = await zonesOf(sax.id);
    const wrong = after.filter((z) => (z.startFrame ?? 0) !== frames);
    if (wrong.length)
      throw new Error(`startFrame did not take on ${wrong.length}/${after.length} zones (wanted ${frames}, saw e.g. ${wrong[0].startFrame})`);

    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(20)} startFrame=${String(frames).padStart(5)}  ${m.integratedLufs.toFixed(2)} LUFS  — ${k.why}`);
  }

  console.log(`\nproject NOT saved — these notes and zone offsets are live in the running app only.`);
  console.log(`open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  process.exit(process.exitCode ?? 0);   // see m34-z: teardown-on-exit deadlocks otherwise
}
