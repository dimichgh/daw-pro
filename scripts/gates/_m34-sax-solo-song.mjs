// A sax solo song — a jazz ballad trio (tenor sax, piano, upright bass) built to
// DOGFOOD the m34-t/w articulation work end to end: legato slurs on the stepwise
// writing, constant-rate glide so a wide slur takes longer than a step, and
// TONGUED leaps where a real player would tongue them.
//
// ⚠️ NOT A GATE. It writes music and renders it for a human to judge. The only
// assertions are the ones that would otherwise let it "succeed" silently:
// every send is checked for `ok` (m34-v's lesson — a refused command and a
// command that did nothing look identical), and the render must be a real file.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-solo-song";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-song";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
mkdirSync(`${process.env.HOME}/Music/DAW Pro Dogfood`, { recursive: true });

const TEMPO = 92;

buildOrAbort({ label: "building staging binary (sax solo song)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `song${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 180000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t);
      ws.removeEventListener("message", h);
      res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
// m34-v: ALWAYS read `ok`. A refused command and a command that did nothing are
// indistinguishable otherwise — that is how a probe once photographed an
// untouched default and reported success.
async function cmd(command, params = {}) {
  const r = await raw(command, params);
  if (!r.ok) throw new Error(`${command} REFUSED :: ${r.error ?? JSON.stringify(r.result)}`);
  return r.result;
}

// ---------------------------------------------------------------- THE MUSIC
// F major ballad. | Fmaj7 | Dm7 | Gm7 | C7 | Fmaj7 | Dm7 | Gm7 C7 | Fmaj7 |
const CHORDS = [
  [53, 57, 60, 64], [50, 53, 57, 60], [55, 58, 62, 65], [48, 52, 55, 58],
  [53, 57, 60, 64], [50, 53, 57, 60], [55, 58, 62, 65], [53, 57, 60, 64],
];
const ROOTS = [41, 38, 43, 36, 41, 38, 43, 41];

// [pitch, beat, length]. Notes OVERLAP (next starts 0.1 before this ends) where
// the line should slur; a GAP where a player would tongue.
const HEAD = [
  [69, 0.0, 1.6], [72, 1.5, 1.6], [69, 3.0, 1.1],
  [65, 4.0, 1.6], [69, 5.5, 1.1], [74, 6.5, 1.6],   // A4->D5, a slurred 5th: glide shows here
  [72, 8.0, 1.6], [70, 9.5, 1.1], [67, 10.5, 1.6],
  [69, 12.0, 2.1], [67, 14.0, 2.1],
  [65, 16.0, 1.6], [69, 17.5, 1.1], [72, 18.5, 1.6],
  [74, 20.0, 2.1], [72, 22.0, 2.1],
  [70, 24.0, 1.6], [69, 25.5, 1.1], [67, 26.5, 1.6],
  [65, 28.0, 4.0],
];
const SOLO = [
  [65, 0.0, 1.1], [69, 1.0, 1.1], [72, 2.0, 1.1], [77, 3.0, 1.6],
  [76, 4.0, 1.6], [74, 5.5, 1.1], [69, 6.5, 1.6],
  [70, 8.0, 1.6], [74, 9.5, 1.1], [77, 10.5, 1.6],
  [76, 12.0, 2.1], [72, 14.0, 2.1],
  // ⭐ The octave leap is TONGUED, not slurred (0.1-beat GAP, not an overlap).
  // Two reasons, and both are honest: a real player tongues a leap that wide,
  // AND a slurred voice keeps its own sample, so a 12-semitone slur would
  // varispeed one zone an octave and drift badly in timbre. Detaching lets the
  // note retrigger and pick the RIGHT zone. This is the documented limit being
  // played around rather than hidden.
  [65, 16.0, 0.9], [77, 17.0, 1.9],
  [76, 20.0, 1.6], [72, 21.5, 2.1],
  [70, 24.0, 1.6], [69, 25.5, 1.1], [67, 26.5, 1.6],
  [65, 28.0, 4.0],
];

const note = (p, b, l, v = 84) => ({ pitch: p, startBeat: b, lengthBeats: l, velocity: v });
const shift = (arr, at, v) => arr.map(([p, b, l]) => note(p, at + b, l, v));

try {
  // ============================================================== STAGE 1
  // Three sax samples so the lead is not one sample varispeed'd across an
  // octave. Roots at D4/A4/D5 keep every note within ~4 semitones of a root.
  console.log("\n=== STAGE 1 · render three sustained GM tenor-sax samples ===");
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: TEMPO });

  const progs = await cmd("instrument.listSoundBankPrograms", { source: "gm" });
  const list = progs.programs ?? progs ?? [];
  const sax = list.find((p) => /tenor\s*sax/i.test(p.name ?? "")) ??
              list.find((p) => /sax/i.test(p.name ?? ""));
  if (!sax) throw new Error("no /sax/i program in the gm bank — refusing to guess a number");
  console.log(`  sax program #${sax.program} "${sax.name}"`);

  const srcTrack = await cmd("track.add", { name: "SaxSource", kind: "instrument" });
  await cmd("track.setInstrument", {
    trackId: srcTrack.id, kind: "soundBank",
    soundBank: { source: "gm", program: sax.program },
  });

  const ROOTS_TO_SAMPLE = [62, 69, 74];
  const samples = {};
  for (const root of ROOTS_TO_SAMPLE) {
    const snap = await cmd("project.snapshot");
    for (const c of snap.tracks?.find((t) => t.id === srcTrack.id)?.clips ?? []) {
      await cmd("clip.remove", { clipId: c.id });
    }
    await cmd("clip.addMIDI", {
      trackId: srcTrack.id, atBeat: 0, lengthBeats: 20, name: `S${root}`,
      notes: [note(root, 0, 20, 100)],
    });
    const p = `${OUT}/sax-root-${root}.wav`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 10000) throw new Error(`sample render failed: ${p}`);
    samples[root] = p;
    console.log(`  root ${root}: ${statSync(p).size} bytes`);
  }

  // ============================================================== STAGE 2
  console.log("\n=== STAGE 2 · build the song ===");
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: TEMPO });

  const piano = await cmd("track.add", { name: "Piano", kind: "instrument" });
  await cmd("track.setInstrument", {
    trackId: piano.id, kind: "soundBank", soundBank: { source: "gm", program: 0 },
  });
  const bass = await cmd("track.add", { name: "Upright Bass", kind: "instrument" });
  await cmd("track.setInstrument", {
    trackId: bass.id, kind: "soundBank", soundBank: { source: "gm", program: 32 },
  });
  const lead = await cmd("track.add", { name: "Tenor Sax", kind: "instrument" });

  // ⭐ The whole point: the lead is the BUILT-IN sampler, because that is the
  // only path that can actually slur. legato + a 0.12 s glide (the user's own
  // pick, by ear) + constantRate so the slurred 5th takes longer than a step.
  await cmd("track.setInstrument", {
    trackId: lead.id, kind: "sampler",
    sampler: {
      zones: [
        { path: samples[62], rootPitch: 62, minPitch: 0, maxPitch: 65 },
        { path: samples[69], rootPitch: 69, minPitch: 66, maxPitch: 71 },
        { path: samples[74], rootPitch: 74, minPitch: 72, maxPitch: 127 },
      ],
      voiceMode: "legato",
      glideTime: 0.12,
      glideMode: "constantRate",
    },
  });

  // Comp + bass across 96 beats (24 bars): 4 intro, 16 head+solo, 4 outro.
  const compNotes = [], bassNotes = [];
  for (let bar = 0; bar < 24; bar++) {
    const c = CHORDS[bar % 8], r = ROOTS[bar % 8], at = bar * 4;
    for (const p of c) {
      compNotes.push(note(p, at + 0.0, 1.8, 58));
      compNotes.push(note(p, at + 2.0, 1.8, 50));
    }
    bassNotes.push(note(r, at + 0.0, 1.9, 74));
    bassNotes.push(note(r + 7, at + 2.0, 1.9, 66));
  }
  await cmd("clip.addMIDI", { trackId: piano.id, atBeat: 0, lengthBeats: 96, name: "Comp", notes: compNotes });
  await cmd("clip.addMIDI", { trackId: bass.id, atBeat: 0, lengthBeats: 96, name: "Bass", notes: bassNotes });

  // Sax enters after a 4-bar intro: head (32 beats), then the solo (32).
  await cmd("clip.addMIDI", {
    trackId: lead.id, atBeat: 0, lengthBeats: 96, name: "Sax",
    notes: [...shift(HEAD, 16, 84), ...shift(SOLO, 48, 92)],
  });

  await cmd("track.setVolume", { trackId: piano.id, volume: 0.5 });
  await cmd("track.setVolume", { trackId: bass.id, volume: 0.72 });
  await cmd("track.setVolume", { trackId: lead.id, volume: 1.0 });

  // A little room, so a dry GM patch does not sound like a test tone.
  for (const t of [lead.id, piano.id]) {
    const fx = await cmd("fx.add", { trackId: t, kind: "reverb" });
    const id = fx.effectId ?? fx.effect?.id;
    if (id) await cmd("fx.setParam", { trackId: t, effectId: id, name: "mix", value: t === lead.id ? 0.22 : 0.14 });
  }

  // ============================================================== STAGE 3
  // LEVEL. A GM-sourced trio lands around -29 LUFS, which is unlistenably
  // quiet. ⚠️ The master FADER cannot fix it: it stops at 2.0 (+6 dB) and
  // REJECTS more rather than clamping. The move is a `gain` insert at the FRONT
  // of the master chain, then the fader for the remainder, then a limiter to
  // catch the peaks that adding 14 dB inevitably creates.
  console.log("\n=== STAGE 3 · level ===");
  const lufsOf = async () => (await cmd("render.measureLoudness", {})).measurement;
  const TARGET = -14.0;

  let m = await lufsOf();
  console.log(`  before:  ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);

  const needDb = TARGET - m.integratedLufs;
  const gainLin = Math.min(4.0, Math.pow(10, needDb / 20));       // insert caps at 4 (+12 dB)
  const g = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = g.effectId ?? g.effect?.id;
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear", value: gainLin });
  console.log(`  needed ${needDb.toFixed(1)} dB → gain insert ${gainLin.toFixed(2)}x (${(20*Math.log10(gainLin)).toFixed(1)} dB)`);

  m = await lufsOf();
  const remainder = TARGET - m.integratedLufs;
  if (remainder > 0.2) {
    const vol = Math.min(2.0, Math.pow(10, remainder / 20));
    await cmd("mixer.setMasterVolume", { volume: vol });
    console.log(`  fader picks up the remaining ${remainder.toFixed(1)} dB → ${vol.toFixed(2)}x`);
  }

  const lim = await cmd("fx.add", { trackId: "master", kind: "limiter" });
  console.log(`  limiter added: ${!!(lim.effectId ?? lim.effect?.id)}`);

  m = await lufsOf();
  console.log(`  after:   ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
  if (m.integratedLufs < -20) console.log("  ⚠️ STILL QUIET — report this rather than calling it done.");
  if (m.truePeakDbtp > -0.5) console.log("  ⚠️ PEAK HOT — the limiter is not holding the ceiling.");

  console.log("\n=== render + save ===");
  const mix = `${OUT}/sax-solo-demo.wav`;
  await cmd("render.mixdown", { path: mix });
  if (!existsSync(mix) || statSync(mix).size < 100000) throw new Error(`mixdown failed: ${mix}`);
  console.log(`  ${mix}  (${statSync(mix).size} bytes)`);

  const saved = await cmd("project.save", { path: PROJECT });
  console.log(`  saved: ${saved?.path ?? PROJECT}`);

  console.log("\nDONE. Listen:");
  console.log(`  open "${mix}"`);
  console.log(`  open "${PROJECT}"`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(200);
  // ⭐ The user asked for the app to be LEFT OPEN, so staging is deliberately
  // NOT stopped here. It stays on 17695 with the song loaded.
  // ⚠️ Quit it from the app's own menu, or pidfile-exact — never pkill.
  console.log(`\n⚠️ Staging LEFT RUNNING on 17695 with the song loaded (by request).`);
  console.log(`   Port 17600 was never bound or contacted.`);
}
