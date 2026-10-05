// A SAXOPHONE IS MONOPHONIC. Make the render monophonic too.
//
// ⭐⭐⭐ THE FINDING, AND THE USER'S EARS LOCATED IT TO THE SECOND. They said of
// the poly take: "10 and 11 seconds of sax is sax", then theremin later. Counting
// sounding voices against their own timestamps:
//
//      10.5 s / 11.0 s  -> 1 voice   "sax is sax"
//      16 s             -> 2 voices  "theremin"
//      20 s             -> 2 voices  "theremin"
//
// ONE VOICE = SAX. TWO VOICES = THEREMIN. A wind player has one air column, so
// any instant with two notes sounding cannot read as a wind instrument — it
// reads as an electronic pad. That is the whole thing, and it was not the
// sample stretch (which I had just spent a round bounding) nor the glide.
//
// ⛔ AND THE SECOND VOICE IS NOT A NOTE, IT IS A TAIL. Effective release is
// 0.5 s (measured, every zone overrides the global). Solo notes arrive every
// ~0.6 s, so each note is STILL SOUNDING when the next begins — in `poly` as an
// extra voice, and in `mono` as the choke's release ramp. I have been running a
// half-second tail on a monophonic instrument all session.
//
// ⚠️ ONE AXIS: RELEASE LENGTH. Held: `mono` (so the engine can never sound two
// notes), each note on its OWN zone (stretch <=1 semitone — the thing the last
// round established), startFrame 80 ms (no recorded tongue), no glide (no
// theremin slide), breath on, brightness off.
//
// ⭐ Every constraint the user has identified is now satisfied at once, except
// note-transition smoothness — which is exactly and only what m34-y fixes.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-one-voice";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-onevoice";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -15.0, SR = 48000, START_MS = 80;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ov${++n}`;
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
  const bpm = ov.tempo ?? 92, spb = 60 / bpm;

  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const ORIG = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  if (ORIG.length !== (got.totalNotes ?? ORIG.length)) throw new Error("partial read");

  // ⭐ NOTES BUTT UP, THEY DO NOT OVERLAP. Under mono an overlap only buys a
  // choke; what actually joins notes is the (now short) release. Each note ends
  // exactly where the next begins, except at a real phrase rest.
  const notes = ORIG.map((x, i) => {
    const next = i + 1 < ORIG.length ? ORIG[i + 1].startBeat : x.startBeat + x.lengthBeats;
    const rest = (next - x.startBeat) >= 2.0;
    const end = rest ? Math.min(next - 0.30, x.startBeat + x.lengthBeats) : next;
    return { ...x, lengthBeats: Math.max(0.22, end - x.startBeat) };
  });
  let overlapping = 0;
  for (let i = 0; i < notes.length - 1; i++)
    if (notes[i].startBeat + notes[i].lengthBeats > notes[i + 1].startBeat + 1e-9) overlapping++;
  if (overlapping) throw new Error(`${overlapping} notes still overlap — mono would choke, refusing`);
  console.log(`${notes.length} notes, ZERO overlaps (a monophonic instrument cannot overlap)`);

  const baseZones = await zonesOf(sax.id);
  if (!baseZones.length) throw new Error("no zones — refusing to patch blind");
  const frames = Math.round((START_MS / 1000) * SR);

  const TAKES = [
    { f: "A1-release-500ms.wav", rel: 0.50, why: "as it has been all session — the tail that made two voices" },
    { f: "A2-release-200ms.wav", rel: 0.20, why: "" },
    { f: "A3-release-100ms.wav", rel: 0.10, why: "" },
    { f: "A4-release-050ms.wav", rel: 0.05, why: "shortest — cleanest separation, driest" },
  ];

  // Predict the two-voice time each release buys, BEFORE rendering.
  console.log(`\n  release  time with a tail still sounding into the next note`);
  for (const k of TAKES) {
    let overlapSec = 0;
    for (let i = 0; i < notes.length - 1; i++) {
      const end = (notes[i].startBeat + notes[i].lengthBeats) * spb;
      const nxt = notes[i + 1].startBeat * spb;
      overlapSec += Math.max(0, Math.min(end + k.rel, nxt + 10) - Math.max(nxt, end));
    }
    console.log(`   ${String(k.rel * 1000).padStart(4)} ms   ${overlapSec.toFixed(1)} s`);
  }

  await cmd("clip.setNotes", { clipId: clip.id, notes });
  const br = await cmd("clip.applyBreathContour", { clipId: clip.id, depth: 0.7, vibratoRateHz: 5.2, vibratoDepthCents: 14, vibratoOnsetSeconds: 0.35 });
  if (!(br?.notesTouched > 0)) throw new Error("breath contour touched nothing");

  console.log(`\n=== LADDER (axis: RELEASE — how long a note keeps sounding after it ends) ===`);
  for (const k of TAKES) {
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: "mono", glideTime: 0.0, expressionFilterDepth: 0,
                 zonePatches: baseZones.map((z) => ({ id: z.id, startFrame: frames, release: k.rel })) } });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== "mono") throw new Error(`voiceMode did not take for ${k.f}`);
    // ⭐ VERIFY THE RELEASE REACHED THE ENGINE, not the inert global. The stored
    // scalar is NOT what plays — effectiveGlobals is (Commands.swift:1837).
    const eff = d.effectiveGlobals?.release;
    const applied = eff?.effectiveValues ?? [];
    if (!applied.length || Math.abs(applied[0] - k.rel) > 1e-9 || applied.length > 1)
      throw new Error(`release did not take for ${k.f}: engine applies ${JSON.stringify(applied)}, wanted [${k.rel}]`);

    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    console.log(`  ${k.f.padEnd(24)} engine applies release=${applied[0]}s  ${k.why}`);
  }

  console.log(`\nproject NOT saved.`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  process.exit(process.exitCode ?? 0);   // see m34-z
}
