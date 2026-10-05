// Is our LEGATO ZONE-LOCK what makes the tenor sound like a small pipe?
//
// ⭐ THE HYPOTHESIS, and it is stated as a deliberate limit in our own source
// (SamplerInstrument.swift:38): "A LEGATO VOICE DOES NOT CHANGE ZONE — it is
// retuned against its own zone's root pitch … timbre drift on a wide slurred
// interval is the accepted limit."
//
// A voice advances through its sample at 2^((pitch − rootPitch)/12). The user's
// library roots a sample every 2 semitones, so a DETACHED note varispeeds by at
// most ±1 semitone — inaudible. But a SLURRED run never changes zone, so the
// whole run plays ONE sample stretched across the entire phrase. Varispeeding a
// sample UP shifts its formants up, and shifted-up formants are heard as a
// PHYSICALLY SMALLER INSTRUMENT. That is the user's word for it: "трубочка",
// a little pipe.
//
// ⚠️ SO THIS SCRIPT MEASURES BEFORE IT RENDERS. It walks the actual note list,
// reconstructs each slur run exactly as the engine's mono/legato rule does, maps
// the run's first note through the ACTUAL zone table from describeSampler, and
// prints how far each run drags its sample. A ladder without that number would
// just be three files and a guess.
//
// The ladder varies ONE axis: what the sampler does when a note arrives while
// another is sounding.
//   A  legato — voice continues, ZONE LOCKED, sample varispeeds  (what they heard)
//   B  mono   — voice chokes, the new note gets its OWN zone and attack
//   C  poly   — notes overlap naturally, each with its own zone
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-zone-lock";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-zonelock";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `zl${++n}`;
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
const NM = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
const nn = (m) => `${NM[((m % 12) + 12) % 12]}${Math.floor(m / 12) - 1}`;

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  // ---------- the zone table, from the engine, not from the .dspreset ----------
  // ⚠️ describeSampler carries `zoneSummary` (count + coverage), NOT the zone
  // table — I tried it first and it has no per-zone roots. The full table is in
  // project.snapshot's instrument object. Verified in Commands.swift:12090.
  const desc = await cmd("instrument.describeSampler", { trackId: sax.id });
  const fullSnap = await cmd("project.snapshot");
  const snapTrack = (fullSnap.tracks ?? []).find((t) => t.id === sax.id);
  const zones = snapTrack?.instrument?.sampler?.zones ?? [];
  if (!Array.isArray(zones) || zones.length === 0)
    throw new Error(`no zone table on the sax track in project.snapshot ` +
      `(instrument keys: ${Object.keys(snapTrack?.instrument ?? {}).join(", ")}) — refusing to model zone selection blind`);
  const z0 = zones[0];
  console.log(`zones: ${zones.length}; first zone fields: ${Object.keys(z0).join(", ")}`);

  // ---------- did the importer actually TAKE the library's ADSR? ----------
  // The .dspreset asks for attack=0.002 decay=25.0 sustain=1.0 release=0.5.
  // Unverified until now, and it changes how take B's re-attacks sound.
  const globals = Object.fromEntries(
    ["attack", "decay", "sustain", "release", "voiceMode", "glideTime", "glideMode", "oneShot"]
      .filter((k) => k in desc).map((k) => [k, desc[k]]));
  console.log(`stored globals:    ${JSON.stringify(globals)}`);
  // ⭐ THE STORED SCALAR IS NOT THE APPLIED ONE. Commands.swift:1837 says so in
  // as many words — a global every zone overrides "looks exactly like a valid
  // answer while being inert", which is the 2026-08-20 sax-team defect D.
  // effectiveGlobals is what the engine actually applies.
  console.log(`effectiveGlobals:  ${JSON.stringify(desc.effectiveGlobals ?? "(absent)")}`);
  if (Array.isArray(desc.warnings) && desc.warnings.length)
    for (const w of desc.warnings) console.log(`  ⚠️ ${w}`);
  console.log(`  .dspreset asked for: attack=0.002 decay=25.0 sustain=1.0 release=0.5`);

  const rootKey = "rootPitch", loKey = "minPitch", hiKey = "maxPitch";
  for (const k of [rootKey, loKey, hiKey])
    if (typeof z0[k] !== "number")
      throw new Error(`zone has no numeric ${k} (fields: ${Object.keys(z0).join(", ")}) — refusing to guess the mapping`);

  // Velocity matters: this library has TWO layers (split at 89/90), so a
  // pitch-only mapper would pick the wrong sample half the time.
  const zoneFor = (pitch, vel = 100) => zones.find((z) =>
    pitch >= z[loKey] && pitch <= z[hiKey] &&
    vel >= (z.minVelocity ?? 0) && vel <= (z.maxVelocity ?? 127)) ?? null;

  // POSITIVE CONTROL on the zone mapper: a pitch I can see in the table must map.
  const ctlPitch = z0[rootKey];
  const ctlVel = (z0.minVelocity ?? 0) + 1;
  if (!zoneFor(ctlPitch, ctlVel))
    throw new Error(`zone mapper found nothing for ${nn(ctlPitch)} @vel ${ctlVel}, a root that IS in the table — the mapper is broken, not the map`);
  // NEGATIVE control: a pitch far outside the table must NOT map, or the mapper
  // matches everything and every "hit" below is meaningless.
  if (zoneFor(3, 100))
    throw new Error(`zone mapper matched MIDI 3, which is outside the library — it matches anything, so its hits prove nothing`);
  console.log(`✔ zone-mapper controls: ${nn(ctlPitch)}@${ctlVel} → root ${nn(zoneFor(ctlPitch, ctlVel)[rootKey])}; MIDI 3 correctly unmatched`);

  // Real per-zone sample durations, measured — not the 6.47s I spot-checked.
  const durOf = (p) => {
    try {
      const s = execSync(`ffprobe -hide_banner -v error -show_entries format=duration -of csv=p=0 ${JSON.stringify(p)}`).toString().trim();
      const d = parseFloat(s);
      return Number.isFinite(d) ? d : null;
    } catch { return null; }
  };

  // ---------- the notes ----------
  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const notes = (got.notes ?? []).slice().sort((a, b) => a.startBeat - b.startBeat);
  const total = got.totalNotes ?? notes.length;
  if (notes.length !== total) throw new Error(`partial read (${notes.length} of ${total})`);
  console.log(`\nsax clip: ${notes.length} notes, ${nn(Math.min(...notes.map(x=>x.pitch)))}..${nn(Math.max(...notes.map(x=>x.pitch)))}`);

  // ---------- reconstruct the slur runs ----------
  // The engine continues a voice when a note-on arrives while one is sounding.
  // A run therefore breaks at the first note whose onset is at/after the
  // previous note's end.
  const runs = [];
  let cur = [notes[0]];
  for (let i = 1; i < notes.length; i++) {
    const prev = cur[cur.length - 1];
    const overlapping = notes[i].startBeat < prev.startBeat + prev.lengthBeats - 1e-9;
    if (overlapping) cur.push(notes[i]);
    else { runs.push(cur); cur = [notes[i]]; }
  }
  runs.push(cur);

  // SECOND consequence of zone-lock, independent of formants: the zones are
  // UNLOOPED ~6.47 s files (ffprobe, 2026-09-01, 48 kHz mono). A slurred run
  // advances through ONE of them at >=1x, so a long chain can run off the END of
  // the sample and decay into nothing. That is a different symptom from "small
  // instrument" and worth separating.
  const bpm = ov.tempo ?? ov.bpm ?? 92;
  const secPerBeat = 60 / bpm;
  const probeDur = durOf(z0.path);
  if (probeDur === null) throw new Error(`ffprobe could not read ${z0.path} — refusing to assert exhaustion without real durations`);
  console.log(`\ntempo ${bpm} BPM → ${secPerBeat.toFixed(3)} s/beat; sample durations measured per zone (first: ${probeDur.toFixed(2)}s), UNLOOPED`);

  console.log(`\n=== SLUR RUNS (a run holds ONE sample for its whole length) ===`);
  let worst = null, worstBurn = null;
  for (const run of runs) {
    if (run.length < 2) continue;
    const head = run[0];
    const z = zoneFor(head.pitch, head.velocity ?? 100);
    if (!z) { console.log(`  run at beat ${head.startBeat}: head ${nn(head.pitch)} maps to NO zone`); continue; }
    const root = z[rootKey];
    const zoneSeconds = durOf(z.path);
    if (zoneSeconds === null) throw new Error(`ffprobe could not read the locked zone's file ${z.path}`);
    let far = head, farDist = Math.abs(head.pitch - root);
    for (const nt of run) {
      const d = Math.abs(nt.pitch - root);
      if (d > farDist) { farDist = d; far = nt; }
    }
    const ratio = Math.pow(2, (far.pitch - root) / 12);
    const ownZone = zoneFor(far.pitch, far.velocity ?? 100);
    const ownDist = ownZone ? Math.abs(far.pitch - ownZone[rootKey]) : null;

    // Sample seconds consumed: integrate each note's own playback rate over its
    // own duration, since the rate changes as the run walks.
    const runEnd = Math.max(...run.map((x) => x.startBeat + x.lengthBeats));
    let burned = 0;
    for (let i = 0; i < run.length; i++) {
      const from = run[i].startBeat;
      const to = i + 1 < run.length ? run[i + 1].startBeat : runEnd;
      burned += Math.max(0, to - from) * secPerBeat * Math.pow(2, (run[i].pitch - root) / 12);
    }
    const exhausted = burned > zoneSeconds;

    const row = { beat: head.startBeat, len: run.length, head: head.pitch, root, far: far.pitch, farDist, ratio, ownDist, burned, exhausted, zoneSeconds };
    if (!worst || farDist > worst.farDist) worst = row;
    if (!worstBurn || burned > worstBurn.burned) worstBurn = row;
    console.log(
      `  beat ${String(head.startBeat).padStart(5)}  ${String(run.length).padStart(2)} notes  ` +
      `head ${nn(head.pitch)} → sample root ${nn(root)};  furthest ${nn(far.pitch)} = ` +
      `${farDist.toFixed(0)} semitone${farDist === 1 ? "" : "s"} of varispeed (${ratio.toFixed(3)}× rate)` +
      (ownDist !== null ? `,  detached it would be ${ownDist.toFixed(0)}` : "") +
      `;  burns ${burned.toFixed(2)}s of a ${zoneSeconds.toFixed(2)}s sample${exhausted ? "  ⛔ RUNS OFF THE END" : ""}`);
  }

  console.log(`\n=== THE NUMBER ===`);
  if (!worst) {
    console.log("  no multi-note slur runs — the zone-lock hypothesis does NOT apply to this part.");
  } else {
    console.log(`  worst run drags its sample ${worst.farDist.toFixed(0)} semitones (${worst.ratio.toFixed(3)}× playback rate).`);
    console.log(`  the same note played DETACHED would sit ${worst.ownDist} semitone(s) from its own root.`);
    console.log(`  formants therefore shift by ~${(worst.farDist).toFixed(0)} semitones under legato vs ~${worst.ownDist} detached.`);
    console.log(worst.farDist >= 4
      ? `  ⭐ ≥4 semitones is squarely in "sounds like a smaller instrument" territory. Hypothesis SUPPORTED.`
      : `  ⚠️ under 4 semitones — formant shift is probably NOT the main culprit here. Say so.`);
    console.log(`\n  sample exhaustion: worst run burns ${worstBurn.burned.toFixed(2)}s of a ${worstBurn.zoneSeconds.toFixed(2)}s unlooped sample` +
      (worstBurn.exhausted
        ? `  ⛔ IT RUNS OFF THE END — a second, separate defect from the formant shift.`
        : `  ✔ within the sample; exhaustion is NOT in play here.`));
  }

  // ---------- level once, shared by every take ----------
  const snap = await cmd("project.snapshot");
  const chain = snap.masterEffects;
  if (!Array.isArray(chain)) throw new Error("snapshot.masterEffects missing — refusing to level blind");
  for (const e of chain) await cmd("fx.remove", { trackId: "master", effectId: e.id });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });
  const neutral = await lufsOf();
  const g = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = g.effectId ?? g.effect?.id;
  if (!gid) throw new Error("fx.add gain returned no id");
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear",
    value: Math.max(0.02, Math.min(4.0, Math.pow(10, (TARGET - neutral.integratedLufs) / 20))) });
  await cmd("fx.add", { trackId: "master", kind: "limiter" });
  const lv = await lufsOf();
  console.log(`\nlevel: neutral ${neutral.integratedLufs.toFixed(2)} → ${lv.integratedLufs.toFixed(2)} LUFS`);
  if (Math.abs(lv.integratedLufs - TARGET) > 1.5) throw new Error("level correction did not take");

  // ---------- the ladder: ONE axis ----------
  const TAKES = [
    { f: "A-legato-zone-locked.wav", s: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantTime" },
      why: "what you heard: voice continues, ONE sample stretched across the slur" },
    { f: "B-mono-own-zone.wav",      s: { voiceMode: "mono",   glideTime: 0.0 },
      why: "each note takes ITS OWN sample and re-attacks — correct timbre, re-tongued" },
    { f: "C-poly-own-zone.wav",      s: { voiceMode: "poly",   glideTime: 0.0 },
      why: "own sample per note, tails overlap naturally instead of choking" },
  ];
  console.log(`\n=== LADDER (axis: what happens when a note arrives while one is sounding) ===`);
  for (const k of TAKES) {
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler", sampler: k.s });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== k.s.voiceMode)
      throw new Error(`voiceMode did not take for ${k.f}: asked ${k.s.voiceMode}, got ${d.voiceMode}`);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(28)} ${m.integratedLufs.toFixed(2)} LUFS  — ${k.why}`);
  }

  // Leave the project on the take the measurement predicts, and SAY that is a
  // prediction rather than a verdict — nobody here can hear it.
  await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "mono", glideTime: 0.0 } });
  await cmd("project.save", { path: PROJECT });
  console.log(`\nproject left on B (mono). That is what the MEASUREMENT predicts, not something I heard.`);
  console.log(`open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  // ⚠️ EXPLICIT EXIT IS LOAD-BEARING, and the reason is a genuine deadlock:
  // startStaging registers its teardown on `process.on("exit")`, but the spawned
  // staging child keeps node's event loop alive, so exit NEVER ARRIVES and the
  // handler that would release /tmp/daw-gate-out/_staging-defaults.lock cannot
  // run. Every aborted run then blocks the NEXT one with "lock is held by LIVE
  // pid N". Cost today: two wasted runs. Forcing exit fires the handler.
  process.exit(process.exitCode ?? 0);
}
