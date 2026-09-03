// Re-articulate the sax part the way a saxophonist actually plays it, and give
// it breath.
//
// ⭐ THE AUTHORING DEFECT WAS MINE. I wrote every note to overlap the next by
// 0.1 beat, so the whole 16-note head is ONE unbroken slur. A wind player
// tongues most notes and breathes every couple of bars; nobody slurs sixteen
// notes in a row. Under our zone-locking legato that one slur becomes ONE
// sample stretched across the entire phrase — measured at 13 semitones of
// varispeed (formants up an octave: "small instrument") and 22.50 s of playback
// demanded from a 5.80 s UNLOOPED sample, after which
// SamplerInstrument.swift:1467 FREES THE VOICE and the phrase goes silent.
//
// So this is not a workaround for an engine bug — the engine bug is real and
// filed. This is the part being written correctly in the first place, which
// also happens to keep every slur short enough that neither defect bites.
//
// TWO THINGS CHANGE, and they are separable on purpose:
//   1. ARTICULATION — slur groups of at most 3, a tongued gap between groups,
//      a real breath at phrase ends.
//   2. BREATH — CC11 dynamics across each phrase, because a sax is a wind
//      instrument and a flat sustain reads as an organ no matter the samples.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-phrasing";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-phrasing";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

const MAX_SLUR = 3;        // notes per slur group — a breath-length gesture
const SLUR_OVERLAP = 0.08; // beats of overlap INSIDE a group (the slur)
const TONGUE_GAP = 0.18;   // beats of silence BETWEEN groups (the tongue)
const BREATH_GAP = 0.55;   // beats of silence at a phrase end (the breath)

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ph${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 180000);
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

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  // ⚠️ UNFILTERED READ. clip.setNotes is a WHOLE-ARRAY REPLACE.
  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const notes = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  const total = got.totalNotes ?? notes.length;
  if (notes.length !== total)
    throw new Error(`partial read (${notes.length} of ${total}) — a whole-array write would DELETE the rest`);
  console.log(`sax clip: ${notes.length} notes`);

  // ---- where were the composer's own phrase boundaries? A gap in the ORIGINAL
  // onsets is a musical rest and must be preserved, not overwritten.
  const onsetGap = (i) => i + 1 < notes.length ? notes[i + 1].startBeat - notes[i].startBeat : Infinity;

  // ---- group into slurs. A group ends at MAX_SLUR, or wherever the composer
  // already left a gap of a beat or more (that was a phrase end).
  const groups = [];
  let g = [0];
  for (let i = 0; i < notes.length - 1; i++) {
    const phraseEnd = onsetGap(i) >= 2.0;
    if (g.length >= MAX_SLUR || phraseEnd) { groups.push({ idx: g, phraseEnd }); g = [i + 1]; }
    else g.push(i + 1);
  }
  groups.push({ idx: g, phraseEnd: true });
  console.log(`slur groups: ${groups.length} (max ${MAX_SLUR} notes each), longest ${Math.max(...groups.map(x => x.idx.length))}`);

  // ---- re-length every note. Pitches and onsets are UNTOUCHED: this changes
  // articulation only, so the tune is exactly the tune the user already heard.
  const out = notes.map((x) => ({ ...x }));
  for (const grp of groups) {
    for (let k = 0; k < grp.idx.length; k++) {
      const i = grp.idx[k];
      const isLast = k === grp.idx.length - 1;
      const nextStart = i + 1 < notes.length ? notes[i + 1].startBeat : notes[i].startBeat + notes[i].lengthBeats;
      let end;
      if (!isLast) end = nextStart + SLUR_OVERLAP;                       // slur into the next
      else if (grp.phraseEnd) end = nextStart - BREATH_GAP;              // breathe
      else end = nextStart - TONGUE_GAP;                                 // tongue
      // Never shorter than a real note, never longer than the original tail.
      const minEnd = notes[i].startBeat + 0.22;
      const maxEnd = notes[i].startBeat + notes[i].lengthBeats;
      out[i].lengthBeats = Math.max(0.22, Math.min(Math.max(end, minEnd), maxEnd) - notes[i].startBeat);
    }
  }

  // ---- PROVE the articulation changed: count overlapping adjacencies before
  // and after. This is the whole point of the edit, so it gets a number.
  const overlaps = (arr) => {
    let c = 0;
    for (let i = 0; i < arr.length - 1; i++)
      if (arr[i].startBeat + arr[i].lengthBeats > arr[i + 1].startBeat + 1e-9) c++;
    return c;
  };
  const before = overlaps(notes), after = overlaps(out);
  console.log(`slurred adjacencies: ${before} → ${after} (of ${notes.length - 1})`);
  if (after >= before) throw new Error(`articulation did not change (${before} → ${after}) — refusing to ship a no-op as a fix`);
  if (after === 0) throw new Error(`every slur was removed — that is staccato, not phrasing; refusing`);

  await cmd("clip.setNotes", { clipId: clip.id, notes: out });
  const back = await cmd("clip.getNotes", { clipId: clip.id });
  if ((back.notes ?? []).length !== notes.length)
    throw new Error(`note count changed ${notes.length} -> ${(back.notes ?? []).length}`);
  console.log(`✔ re-articulated, ${(back.notes ?? []).length} notes intact`);

  // ---- the longest run now, recomputed the same way the engine groups them
  const re = (back.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  let longest = 1, cur = 1;
  for (let i = 1; i < re.length; i++) {
    const prev = re[i - 1];
    if (re[i].startBeat < prev.startBeat + prev.lengthBeats - 1e-9) { cur++; longest = Math.max(longest, cur); }
    else cur = 1;
  }
  console.log(`longest slur run is now ${longest} notes (was 20).`);

  // ---- BREATH. A flat sustain reads as an organ however good the samples are.
  console.log(`\n=== breath contour ===`);
  // ⚠️ Param names READ FROM Commands.swift, not remembered: it is `depth`
  // (not "intensity") and `vibratoOnsetSeconds` (not "...Beats"). A verified
  // NAME is not a verified SIGNATURE — that has bitten twice on this surface.
  const br = await cmd("clip.applyBreathContour", {
    clipId: clip.id,
    depth: 0.7,
    vibratoRateHz: 5.2,
    vibratoDepthCents: 22,
    vibratoOnsetSeconds: 0.35,
  }).catch((e) => { console.log(`  breath contour REFUSED :: ${e.message}`); return null; });
  if (br) console.log(`  ${JSON.stringify(br).slice(0, 400)}`);

  // ---- level once, then render
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
  const lv = await lufsOf();
  console.log(`\nlevel: neutral ${neutral.integratedLufs.toFixed(2)} → ${lv.integratedLufs.toFixed(2)} LUFS`);
  if (Math.abs(lv.integratedLufs - TARGET) > 1.5) throw new Error("level correction did not take");

  // 2×2, and each pair differs on exactly ONE thing:
  //   D vs E / F vs G  → voice mode (slurred vs re-tongued)
  //   D vs F / E vs G  → brightness tracking
  // ⭐ THE BRIGHTNESS AXIS EXISTS BECAUSE THE ENGINE ASKED FOR IT. The breath
  // call warned: "the swell will change LOUDNESS but not BRIGHTNESS … sampler
  // has expressionFilterDepth off (0)". A real horn opens up as it is blown
  // harder; with depth 0 the contour is a volume knob. 0.55 is mid-range —
  // Model.swift:1718 warns a steep setting "starts sounding like a synth sweep
  // rather than a player".
  const BRIGHT = 0.55;
  const TAKES = [
    { f: "D-phrased-legato.wav",        s: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantRate", expressionFilterDepth: 0 },
      why: "short slurs + breath, slurred" },
    { f: "E-phrased-mono.wav",          s: { voiceMode: "mono",   glideTime: 0.0, expressionFilterDepth: 0 },
      why: "short slurs + breath, every note re-tongued" },
    { f: "F-phrased-legato-bright.wav", s: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantRate", expressionFilterDepth: BRIGHT },
      why: "as D, but it gets BRIGHTER as it is blown harder" },
    { f: "G-phrased-mono-bright.wav",   s: { voiceMode: "mono",   glideTime: 0.0, expressionFilterDepth: BRIGHT },
      why: "as E, but it gets BRIGHTER as it is blown harder" },
  ];
  console.log(`\n=== RENDERS ===`);
  for (const k of TAKES) {
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler", sampler: k.s });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== k.s.voiceMode) throw new Error(`voiceMode did not take for ${k.f}`);
    // ⭐ A SETTER'S RETURN IS NOT PROOF IT TOOK — check the brightness axis too,
    // or D/F and E/G could be identical files with different names.
    const gotDepth = d.expressionFilterDepth ?? 0;
    if (Math.abs(gotDepth - k.s.expressionFilterDepth) > 1e-9)
      throw new Error(`expressionFilterDepth did not take for ${k.f}: asked ${k.s.expressionFilterDepth}, got ${gotDepth}`);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(24)} ${m.integratedLufs.toFixed(2)} LUFS  — ${k.why}`);
  }

  // ⚠️ NOT saved over the project: the ladder takes are still worth comparing
  // against, and overwriting the user's session on my own judgement is not mine
  // to do. Say so rather than quietly saving.
  console.log(`\nproject NOT saved — the re-articulated notes are live in the running app only.`);
  console.log(`open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  process.exit(process.exitCode ?? 0);   // see _m34-sax-zone-lock.mjs: the lock deadlock
}
