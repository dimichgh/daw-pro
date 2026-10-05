// m34-t LISTEN — the same sax phrase three ways, one change per step.
//
// ⚠️ THIS IS NOT A GATE. It asserts almost nothing on purpose. No gate in this
// tree can judge a slur; this exists to produce three files a HUMAN plays.
// The only checks here are that each render actually wrote a distinct file —
// three identical files would make the comparison meaningless without ever
// failing anything.
//
// Legato lives ONLY on the built-in sampler, and a fresh project ships no
// sample content, so this renders a sustained GM tenor-sax note FIRST and then
// uses that WAV as the sampler's sample. The bundled `builtin:test-tone-a4` is
// a 0.35 s one-shot — far too short to hear a slur across.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { existsSync, mkdirSync, statSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m34t-sax-legato-listen";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-listen";
mkdirSync(OUT, { recursive: true });

const SOURCE = `${OUT}/00-source-sustained-sax.wav`;
const TEMPO = 100;

buildOrAbort({ label: "building staging binary (m34-t listen)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34t${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 120000);
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

const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex").slice(0, 16);
const must = (r, what) => {
  if (!r.ok) throw new Error(`${what} FAILED :: ${r.error ?? JSON.stringify(r.result)}`);
  return r.result;
};

try {
  // ================================================================ STAGE 1
  // A sustained sax note, rendered from the GM bank, to become the sample.
  console.log("\n=== STAGE 1 · render a sustained GM tenor-sax note ===");
  must(await cmd("project.new", { discardChanges: true }), "project.new");
  must(await cmd("transport.setTempo", { bpm: TEMPO }), "setTempo");

  const progs = must(
    await cmd("instrument.listSoundBankPrograms", { source: "gm" }),
    "listSoundBankPrograms"
  );
  const list = progs.programs ?? progs ?? [];
  // Discover by NAME. Refuse to guess a program number — the same discipline
  // `_measure-gm-sax-cc.mjs` already uses on this bank.
  const sax =
    list.find((p) => /tenor\s*sax/i.test(p.name ?? "")) ??
    list.find((p) => /sax/i.test(p.name ?? ""));
  if (!sax) throw new Error("no program matching /sax/i in the gm bank — refusing to guess a number");
  console.log(`  sax program: #${sax.program} "${sax.name}"`);

  const srcTrack = must(await cmd("track.add", { name: "SaxSource", kind: "instrument" }), "track.add");
  must(
    await cmd("track.setInstrument", {
      trackId: srcTrack.id,
      kind: "soundBank",
      soundBank: { source: "gm", program: sax.program },
    }),
    "setInstrument soundBank"
  );

  // 24 beats at 100 BPM = 14.4 s of held tone — comfortably longer than the
  // phrase, so a continued (slurred) voice never reads off the end.
  must(
    await cmd("clip.addMIDI", {
      trackId: srcTrack.id,
      atBeat: 0,
      lengthBeats: 24,
      name: "HeldA4",
      notes: [{ pitch: 69, startBeat: 0, lengthBeats: 24, velocity: 100 }],
    }),
    "addMIDI held note"
  );

  must(await cmd("render.mixdown", { path: SOURCE }), "render source");
  if (!existsSync(SOURCE) || statSync(SOURCE).size < 10000)
    throw new Error(`source render is missing or tiny: ${SOURCE}`);
  console.log(`  wrote ${SOURCE} (${statSync(SOURCE).size} bytes, sha ${sha(SOURCE)})`);

  // ================================================================ STAGE 2
  // The same phrase, three ways, through the built-in sampler.
  console.log("\n=== STAGE 2 · the same phrase, three ways ===");
  must(await cmd("project.new", { discardChanges: true }), "project.new #2");
  must(await cmd("transport.setTempo", { bpm: TEMPO }), "setTempo #2");

  const track = must(await cmd("track.add", { name: "Sax", kind: "instrument" }), "track.add sax");

  // OVERLAPPING notes — the legato idiom. Each note starts 0.1 beats before its
  // predecessor ends; without overlap there is nothing for legato to continue.
  const P = [
    [69, 0.0, 1.1], [72, 1.0, 1.1], [74, 2.0, 1.1], [76, 3.0, 1.6],
    [74, 4.5, 1.1], [72, 5.5, 1.1], [69, 6.5, 2.5],
  ];
  const notes = P.map(([pitch, startBeat, lengthBeats]) => ({
    pitch, startBeat, lengthBeats, velocity: 96,
  }));
  must(
    await cmd("clip.addMIDI", { trackId: track.id, atBeat: 0, lengthBeats: 10, name: "Lick", notes }),
    "addMIDI phrase"
  );

  const ZONES = [{ path: SOURCE, rootPitch: 69, minPitch: 0, maxPitch: 127 }];

  const TAKES = [
    { file: "1-mono.wav",          voiceMode: "mono",   glideTime: 0,
      why: "today's behaviour — a fresh attack on every note" },
    { file: "2-legato.wav",        voiceMode: "legato", glideTime: 0,
      why: "the voice continues; no second attack" },
    { file: "3-legato-glide.wav",  voiceMode: "legato", glideTime: 0.12,
      why: "same, but the pitch slides instead of stepping" },
  ];

  const hashes = [];
  for (const t of TAKES) {
    // `zones` is resent each time deliberately: track_set_instrument REPLACES
    // the whole keyzone map when `zones` is present, so sending it keeps all
    // three takes on provably identical sample mapping — the only thing that
    // differs between them is the mode.
    must(
      await cmd("track.setInstrument", {
        trackId: track.id,
        kind: "sampler",
        sampler: { zones: ZONES, voiceMode: t.voiceMode, glideTime: t.glideTime },
      }),
      `setInstrument ${t.voiceMode}/${t.glideTime}`
    );
    const path = `${OUT}/${t.file}`;
    must(await cmd("render.mixdown", { path }), `render ${t.file}`);
    if (!existsSync(path) || statSync(path).size < 10000)
      throw new Error(`render missing or tiny: ${path}`);
    const h = sha(path);
    hashes.push({ ...t, path, bytes: statSync(path).size, sha: h });
    console.log(`  ${t.file.padEnd(22)} ${String(statSync(path).size).padStart(8)} B  sha ${h}   ${t.why}`);
  }

  // The ONLY real assertion: three DISTINCT renders. Identical files would make
  // the whole comparison meaningless while failing nothing.
  console.log("\n=== the one thing worth asserting ===");
  const uniq = new Set(hashes.map((h) => h.sha));
  if (uniq.size !== 3) {
    console.log(`FAIL: expected 3 distinct renders, got ${uniq.size} — the mode is not reaching the sound.`);
    hashes.forEach((h) => console.log(`   ${h.file} ${h.sha}`));
    process.exitCode = 1;
  } else {
    console.log(`PASS: 3 distinct renders (${[...uniq].join(", ")}) — each mode demonstrably changes the audio.`);
  }
  console.log(`\nListen in order:\n  open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(200);
  // ⚠️ POSITIONAL — `stopStaging(gate, …)`, NOT startStaging's options object.
  // The two helpers take different shapes and passing `{ gate }` here throws
  // AFTER the work is done, which reads as a failed run when nothing failed.
  stopStaging(GATE);
}
