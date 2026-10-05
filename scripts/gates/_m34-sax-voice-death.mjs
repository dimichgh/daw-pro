// Does the legato voice actually DIE mid-phrase, or is that just arithmetic?
//
// The zone-lock measurement predicts it: the slur run at beat 16 burns 22.50 s
// of a 5.80 s UNLOOPED sample, and SamplerInstrument.swift:1467 frees the voice
// the moment the playhead passes `endFrame`:
//
//     if idx >= zone.endFrame || position < zone.startFrameD {
//         voices[index] = Voice()     // freed — instant silence
//         continue
//     }
//
// Under `.legato` nothing re-triggers, so the REST OF THE PHRASE IS SILENCE.
// That is a prediction about audio, and it deserves an audio measurement rather
// than a second reading of the same source.
//
// ⭐ SO: solo the sax, render it alone under legato and under mono, and walk the
// RMS in 0.25 s windows. Legato should show a long silent stretch inside a run
// where mono keeps sounding. A whole-file LUFS number would average the hole
// away — the hole IS the finding, so the window size is the instrument.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-voice-death";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-voicedeath";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `vd${++n}`;
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

// RMS per window, straight from ffmpeg's astats, one row per window.
function rmsWindows(path, win = 0.25) {
  // ⚠️ NO `2>/dev/null`. I am about to interpret this command's EMPTINESS as
  // silence in the audio, and that redirect is precisely what turns a loud
  // failure into a quiet, clean, wrong negative. `-v error` is safe here for a
  // different reason than usual: `ametadata=print:file=-` writes to STDOUT, not
  // to the log, so unlike an ebur128/astats SUMMARY it is not suppressed by the
  // log level. The positive control below is the real backstop.
  const out = execSync(
    `ffmpeg -hide_banner -v error -i ${JSON.stringify(path)} ` +
    `-af "asetnsamples=n=${Math.round(48000 * win)}:p=0,astats=metadata=1:reset=1,` +
    `ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" -f null -`
  ).toString();
  const vals = [];
  for (const line of out.split("\n")) {
    const m = line.match(/RMS_level=(-?[\d.]+|-inf)/);
    if (m) vals.push(m[1] === "-inf" ? -120 : parseFloat(m[1]));
  }
  return vals;
}

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const bpm = ov.tempo ?? ov.bpm ?? 92;
  const secPerBeat = 60 / bpm;

  // Solo the sax so the piano and bass cannot fill in the hole I am looking for.
  await cmd("track.setSolo", { trackId: sax.id, soloed: true });

  const TAKES = [
    { f: "solo-legato.wav", s: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantTime" } },
    { f: "solo-mono.wav",   s: { voiceMode: "mono",   glideTime: 0.0 } },
  ];
  const series = {};
  for (const k of TAKES) {
    await cmd("track.setInstrument", { trackId: sax.id, kind: "sampler", sampler: k.s });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== k.s.voiceMode) throw new Error(`voiceMode did not take for ${k.f}`);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    series[k.f] = rmsWindows(p);
    console.log(`${k.f}: ${statSync(p).size} bytes, ${series[k.f].length} windows of 0.25s`);
  }
  await cmd("track.setSolo", { trackId: sax.id, soloed: false });

  const L = series["solo-legato.wav"], M = series["solo-mono.wav"];
  if (!L.length || !M.length) throw new Error("no RMS windows parsed — the meter never ran; refusing to read silence as a finding");

  // POSITIVE CONTROL on the meter: the mono take MUST show plenty of loud
  // windows, or my "silence" readings are just a broken parse.
  const SIL = -60;
  const monoLoud = M.filter((v) => v > SIL).length;
  if (monoLoud < M.length * 0.2)
    throw new Error(`meter positive control FAILED: only ${monoLoud}/${M.length} mono windows above ${SIL} dB — the parse is broken, not the audio`);
  console.log(`✔ meter positive control: mono has ${monoLoud}/${M.length} windows above ${SIL} dB\n`);

  const legLoud = L.filter((v) => v > SIL).length;
  console.log(`sounding windows:  legato ${legLoud}/${L.length}   mono ${monoLoud}/${M.length}`);
  console.log(`legato is sounding ${((legLoud / monoLoud) * 100).toFixed(0)}% as much of the time as mono.\n`);

  // Where are the holes? Report contiguous silent stretches inside the piece.
  const runsOfSilence = (arr) => {
    const out = []; let start = -1;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i] <= SIL) { if (start < 0) start = i; }
      else if (start >= 0) { out.push([start, i]); start = -1; }
    }
    if (start >= 0) out.push([start, arr.length]);
    return out.filter(([a, b]) => (b - a) * 0.25 >= 1.0);   // ≥1 s only
  };
  const fmt = (i) => `${(i * 0.25).toFixed(1)}s (beat ${((i * 0.25) / secPerBeat).toFixed(1)})`;
  for (const [name, arr] of [["LEGATO", L], ["MONO", M]]) {
    const holes = runsOfSilence(arr);
    console.log(`${name} silent stretches ≥1s: ${holes.length ? "" : "none"}`);
    for (const [a, b] of holes)
      console.log(`   ${fmt(a)} → ${fmt(b)}   (${((b - a) * 0.25).toFixed(2)}s of silence)`);
  }

  console.log(`\n=== VERDICT ===`);
  const legHoles = runsOfSilence(L).reduce((s, [a, b]) => s + (b - a) * 0.25, 0);
  const monoHoles = runsOfSilence(M).reduce((s, [a, b]) => s + (b - a) * 0.25, 0);
  console.log(`  legato silent ${legHoles.toFixed(2)}s in stretches ≥1s;  mono silent ${monoHoles.toFixed(2)}s.`);
  console.log(legHoles > monoHoles + 2.0
    ? `  ⛔ CONFIRMED: legato drops ${(legHoles - monoHoles).toFixed(1)}s of melody that mono plays. The voice dies when the sample runs out.`
    : `  ⚠️ NOT confirmed — legato is not measurably dropping more than mono. The arithmetic predicted it; the audio does not. Say so.`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
  process.exit(process.exitCode ?? 0);   // see _m34-sax-zone-lock.mjs: the lock deadlock
}
