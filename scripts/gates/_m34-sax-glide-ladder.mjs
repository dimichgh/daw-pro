// Four renders of the SAME phrase on the user's DecentSampler tenor sax,
// differing on ONE axis: how much glide.
//
// WHY: the user reported the 0.12 s / constantRate render "sounds weird but
// continues" — continuity is right, timbre is not. The library's own header
// asks for glideTime="0.04", a THIRD of what I set, and at constantRate the
// slurred 5th in the head stretches to ~0.30 s.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier today).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-glide-ladder";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-ladder";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `gl${++n}`;
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

  // ---- Neutralise the master chain ONCE, then correct ONCE, so every take in
  // the ladder shares identical gain staging. Measuring through a limiter you
  // are about to re-tune reads the limiter, not the mix.
  const snap = await cmd("project.snapshot");
  const fx = (snap.master ?? snap.masterTrack ?? {}).effects ?? [];
  const gainId = fx.find((e) => e.kind === "gain")?.id ?? null;
  const limId = fx.find((e) => e.kind === "limiter")?.id ?? null;
  if (gainId) await cmd("fx.setParam", { trackId: "master", effectId: gainId, name: "gainLinear", value: 1.0 });
  if (limId) await cmd("fx.setBypass", { trackId: "master", effectId: limId, bypassed: true });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });

  const neutral = await lufsOf();
  const lin = Math.max(0.02, Math.min(4.0, Math.pow(10, (TARGET - neutral.integratedLufs) / 20)));
  if (gainId) await cmd("fx.setParam", { trackId: "master", effectId: gainId, name: "gainLinear", value: lin });
  if (limId) await cmd("fx.setBypass", { trackId: "master", effectId: limId, bypassed: false });
  console.log(`neutral ${neutral.integratedLufs.toFixed(2)} LUFS → gain ${lin.toFixed(3)}x`);

  const TAKES = [
    { f: "1-glide-0.04-constantTime.wav", t: 0.04, m: "constantTime",
      why: "the LIBRARY AUTHOR'S own value and the closest to their intent" },
    { f: "2-glide-0.04-constantRate.wav", t: 0.04, m: "constantRate",
      why: "same amount, but wide slurs take proportionally longer" },
    { f: "3-glide-off.wav",               t: 0.0,  m: "constantTime",
      why: "pure legato — voice continues, pitch STEPS with no slide at all" },
    { f: "4-glide-0.12-constantRate.wav", t: 0.12, m: "constantRate",
      why: "what you already heard, kept for comparison" },
  ];

  const rows = [];
  for (const k of TAKES) {
    await cmd("track.setInstrument", {
      trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: "legato", glideTime: k.t, glideMode: k.m },
    });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== "legato" || Math.abs((d.glideTime ?? -1) - k.t) > 1e-9)
      throw new Error(`settings did not take for ${k.f}: ${JSON.stringify({v: d.voiceMode, g: d.glideTime})}`);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed " + p);
    const m = await lufsOf();
    rows.push({ ...k, bytes: statSync(p).size, lufs: m.integratedLufs });
    console.log(`  ${k.f.padEnd(34)} ${m.integratedLufs.toFixed(2)} LUFS   ${k.why}`);
  }

  // Restore the take the user is most likely to want kept in the project.
  await cmd("track.setInstrument", {
    trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantTime" },
  });
  await cmd("project.save", { path: PROJECT });
  console.log("\nproject left on take 1 (0.04 / constantTime) and saved.");
  console.log(`open ${OUT}`);
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(200);
  console.log("\n⚠️ Staging LEFT RUNNING on 17695 (by request). 17600 never touched.");
  process.exit(process.exitCode ?? 0);   // don't leak the client (it held a lock earlier)
}
