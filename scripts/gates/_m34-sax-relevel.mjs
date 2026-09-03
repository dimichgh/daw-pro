// Re-level the demo after the DecentSampler import.
//
// ⚠️ THE BUG THIS FIXES: the master chain was staged for the QUIET GM sax — a
// +12 dB gain insert plus a limiter. The imported library is ~23 dB hotter, so
// it slammed that gain and the limiter absorbed the difference: pulling the
// FADER down 8 dB moved the output only 2.2 dB, because a limiter's output does
// not follow its input once it is deep into gain reduction.
// ⭐ THE LESSON: NEUTRALISE A CHAIN BEFORE RE-MEASURING IT. Measuring through a
// limiter you are about to re-tune reads the limiter, not the mix.
//
// ⛔ Never calls instrument.listAudioUnits (that wedged this app earlier today).
import { existsSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-relevel";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-song";
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `rl${++n}`;
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

  // --- 1. NEUTRALISE. Gain to unity, fader to unity, limiter BYPASSED, so the
  //        next measurement reads the actual mix and nothing else.
  const snap = await cmd("project.snapshot");
  const master = snap.master ?? snap.masterTrack ?? {};
  const fx = master.effects ?? [];
  console.log(`master chain: ${fx.map((e) => e.kind).join(" → ") || "(empty)"}`);

  let gainId = null, limId = null;
  for (const e of fx) {
    if (e.kind === "gain" && !gainId) gainId = e.id;
    if (e.kind === "limiter" && !limId) limId = e.id;
  }
  if (gainId) await cmd("fx.setParam", { trackId: "master", effectId: gainId, name: "gainLinear", value: 1.0 });
  if (limId) await cmd("fx.setBypass", { trackId: "master", effectId: limId, bypassed: true });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });

  const dry = await lufsOf();
  console.log(`neutral (gain 1.0, fader 1.0, limiter bypassed): ${dry.integratedLufs.toFixed(2)} LUFS, peak ${dry.truePeakDbtp.toFixed(2)} dBTP`);

  // --- 2. One correction, computed from the NEUTRAL reading.
  const needDb = TARGET - dry.integratedLufs;
  const lin = Math.max(0.02, Math.min(4.0, Math.pow(10, needDb / 20)));
  if (gainId) await cmd("fx.setParam", { trackId: "master", effectId: gainId, name: "gainLinear", value: lin });
  console.log(`correction ${needDb >= 0 ? "+" : ""}${needDb.toFixed(1)} dB → gain ${lin.toFixed(3)}x`);

  // --- 3. Limiter back on, as a CEILING rather than a level control.
  if (limId) await cmd("fx.setBypass", { trackId: "master", effectId: limId, bypassed: false });

  const m = await lufsOf();
  console.log(`final: ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
  const off = Math.abs(m.integratedLufs - TARGET);
  console.log(off <= 1.0
    ? `✔ within ${off.toFixed(2)} dB of target — the limiter is a ceiling, not a crutch.`
    : `⚠️ ${off.toFixed(2)} dB off target — say so rather than shipping it quietly.`);

  const mix = `${OUT}/sax-solo-decentsampler.wav`;
  await cmd("render.mixdown", { path: mix });
  if (!existsSync(mix) || statSync(mix).size < 100000) throw new Error("mixdown failed");
  console.log(`rendered ${mix} (${statSync(mix).size} bytes)`);
  await cmd("project.save", { path: PROJECT });
  console.log("saved.");
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(200);
  console.log("\n⚠️ Staging LEFT RUNNING on 17695 (by request). 17600 never touched.");
}
