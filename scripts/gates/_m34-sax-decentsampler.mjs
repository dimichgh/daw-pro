// Re-cut the sax solo demo with the USER'S OWN DecentSampler tenor sax, imported
// INTO our built-in sampler (not hosted as a plugin) so it inherits legato,
// glide and constant-rate.
//
// ⛔ THIS SCRIPT NEVER CALLS `instrument.listAudioUnits`. Enumerating third-party
// AUs wedged this app's main actor for minutes earlier today — the scan returned
// results to the client and left the app unresponsive afterwards. Nothing here
// needs it.
//
// Staging: DAW_CONTROL_PORT=17695. NEVER 17600.
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-decentsampler";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-song";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const LIB = `${process.env.HOME}/Music/Audio Music Apps/Decidedly/DecentSampler/Sample Libraries/TenorSax Legato v2.dspreset`;

if (!existsSync(LIB)) { console.log("ABORT: library not found :: " + LIB); process.exit(1); }
if (!existsSync(PROJECT)) { console.log("ABORT: project not found :: " + PROJECT); process.exit(1); }

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ds${++n}`;
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
async function cmd(command, params = {}) {
  const r = await raw(command, params);
  if (!r.ok) throw new Error(`${command} REFUSED :: ${r.error ?? JSON.stringify(r.result)}`);
  return r.result;
}

try {
  console.log("\n=== open the saved demo ===");
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no track matching /sax/i — refusing to guess");
  console.log(`  target track: "${sax.name}" (${sax.id})`);

  // ---- DRY RUN FIRST. The mapper reason-codes every opcode it skips; a silent
  // apply would hide an unsupported feature as "it just sounds wrong".
  console.log("\n=== DRY RUN — what will the mapper actually take? ===");
  const dry = await cmd("instrument.importSampleLibrary", {
    trackId: sax.id, path: LIB, dryRun: true,
  });
  const rep = dry.report ?? dry;
  console.log(`  applied: ${dry.applied}`);
  console.log(`  ${JSON.stringify(rep).slice(0, 1400)}`);

  console.log("\n=== APPLY ===");
  const applied = await cmd("instrument.importSampleLibrary", {
    trackId: sax.id, path: LIB, dryRun: false,
  });
  console.log(`  applied: ${applied.applied}`);

  const after = await cmd("instrument.describeSampler", { trackId: sax.id });
  console.log(`  zones now: ${after.zones?.length ?? after.zoneCount ?? "?"}`);

  // ---- Re-apply the articulation. An import REPLACES the keyzone map, and may
  // reset globals with it, so these are set AFTER the import, not before.
  console.log("\n=== articulation ===");
  await cmd("track.setInstrument", {
    trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "legato", glideTime: 0.12, glideMode: "constantRate" },
  });
  const d2 = await cmd("instrument.describeSampler", { trackId: sax.id });
  console.log(`  voiceMode=${d2.voiceMode}  glideTime=${d2.glideTime}  glideMode=${d2.glideMode}  glideEffective=${d2.glideEffective}`);
  if (d2.voiceMode !== "legato") throw new Error("legato did not take — refusing to render a false demo");

  console.log("\n=== level + render ===");
  const lufsOf = async () => (await cmd("render.measureLoudness", {})).measurement;
  let m = await lufsOf();
  console.log(`  with the new sax: ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
  // The master chain (gain + limiter) survives in the project; only trim if the
  // new library's level moved things materially.
  const drift = -14.0 - m.integratedLufs;
  if (Math.abs(drift) > 0.5) {
    const cur = (await cmd("project.overview")).masterVolume ?? 1.0;
    const vol = Math.max(0.05, Math.min(2.0, cur * Math.pow(10, drift / 20)));
    await cmd("mixer.setMasterVolume", { volume: vol });
    m = await lufsOf();
    console.log(`  trimmed ${drift > 0 ? "+" : ""}${drift.toFixed(1)} dB → ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
  }

  const mix = `${OUT}/sax-solo-decentsampler.wav`;
  await cmd("render.mixdown", { path: mix });
  if (!existsSync(mix) || statSync(mix).size < 100000) throw new Error(`mixdown failed: ${mix}`);
  console.log(`  ${mix} (${statSync(mix).size} bytes)`);

  const saved = await cmd("project.save", { path: PROJECT });
  console.log(`  saved: ${saved?.path ?? PROJECT}`);
  console.log("\nDONE.");
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(200);
  console.log("\n⚠️ Staging LEFT RUNNING on 17695 (by request). 17600 never touched.");
}
