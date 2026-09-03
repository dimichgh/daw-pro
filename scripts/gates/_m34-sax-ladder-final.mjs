// The glide ladder, re-rendered at a SANE level, with the app left genuinely
// running afterwards.
//
// ⚠️ TWO BUGS THIS FIXES, BOTH MINE, BOTH SILENT:
//  ① The master gain lookup returned null and `if (gainId)` turned that into a
//    no-op. The script printed a correction it never applied and every take came
//    out ~8.5 dB hot. **A guarded setter whose id is null is indistinguishable
//    from a setter that worked.** It now THROWS when it cannot find the chain.
//  ② `process.exit()` in the finally tore staging down while the log claimed
//    "LEFT RUNNING". Now uses `detached: true`, and VERIFIES the port at the end
//    rather than asserting it in prose.
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier today).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-ladder-final";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-ladder";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

buildOrAbort({ label: "building staging binary…" });
const st = startStaging({ gate: GATE, detached: true });
console.log(`staging pid ${st.pid} (detached — it will outlive this script)`);
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `lf${++n}`;
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

  // ---- Find the master chain. Print the shape, then FAIL LOUDLY if absent.
  const snap = await cmd("project.snapshot");
  console.log(`snapshot keys: ${Object.keys(snap).join(", ")}`);
  // MEASURED 2026-09-01: the chain is `snapshot.masterEffects` — a TOP-LEVEL
  // key, not `snapshot.master.effects`. Guessing the latter is what silently
  // shipped four takes 8.5 dB hot; the throw below is what caught it.
  let chain = null, where = null;
  if (Array.isArray(snap.masterEffects)) { chain = snap.masterEffects; where = "snapshot.masterEffects"; }
  if (!chain) for (const k of ["master", "masterTrack", "masterBus", "mixer"]) {
    const v = snap[k];
    if (v && Array.isArray(v.effects)) { chain = v.effects; where = `snapshot.${k}.effects`; break; }
  }
  if (!chain) throw new Error(
    "cannot locate the master effect chain in project.snapshot — refusing to " +
    "'correct' a level through a chain I cannot see. Keys were: " + Object.keys(snap).join(", "));
  console.log(`master chain via ${where}: ${chain.map((e) => `${e.kind}(${e.id})`).join(" → ") || "(empty)"}`);

  // ---- Strip it. Rebuilding from empty beats patching ids I might mis-read.
  for (const e of chain) await cmd("fx.remove", { trackId: "master", effectId: e.id });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });

  const neutral = await lufsOf();
  const needDb = TARGET - neutral.integratedLufs;
  console.log(`neutral (no master chain, fader 1.0): ${neutral.integratedLufs.toFixed(2)} LUFS → need ${needDb.toFixed(1)} dB`);

  const g = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = g.effectId ?? g.effect?.id;
  if (!gid) throw new Error("fx.add gain returned no id — cannot set it");
  const lin = Math.max(0.02, Math.min(4.0, Math.pow(10, needDb / 20)));
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear", value: lin });
  const lm = await cmd("fx.add", { trackId: "master", kind: "limiter" });
  if (!(lm.effectId ?? lm.effect?.id)) throw new Error("fx.add limiter returned no id");

  const check = await lufsOf();
  console.log(`after chain: ${check.integratedLufs.toFixed(2)} LUFS, peak ${check.truePeakDbtp.toFixed(2)} dBTP`);
  if (Math.abs(check.integratedLufs - TARGET) > 1.5)
    throw new Error(`level correction did not take (${check.integratedLufs.toFixed(2)} vs ${TARGET}) — refusing to ship a ladder nobody can compare`);

  const TAKES = [
    { f: "1-glide-0.04-constantTime.wav", t: 0.04, m: "constantTime" },
    { f: "2-glide-0.04-constantRate.wav", t: 0.04, m: "constantRate" },
    { f: "3-glide-off.wav",               t: 0.0,  m: "constantTime" },
    { f: "4-glide-0.12-constantRate.wav", t: 0.12, m: "constantRate" },
  ];
  for (const k of TAKES) {
    await cmd("track.setInstrument", {
      trackId: sax.id, kind: "sampler",
      sampler: { voiceMode: "legato", glideTime: k.t, glideMode: k.m },
    });
    const d = await cmd("instrument.describeSampler", { trackId: sax.id });
    if (d.voiceMode !== "legato" || Math.abs((d.glideTime ?? -1) - k.t) > 1e-9)
      throw new Error(`settings did not take for ${k.f}`);
    const p = `${OUT}/${k.f}`;
    await cmd("render.mixdown", { path: p });
    const m = await lufsOf();
    console.log(`  ${k.f.padEnd(34)} ${m.integratedLufs.toFixed(2)} LUFS  peak ${m.truePeakDbtp.toFixed(2)}  (${statSync(p).size} B)`);
  }

  await cmd("track.setInstrument", {
    trackId: sax.id, kind: "sampler",
    sampler: { voiceMode: "legato", glideTime: 0.04, glideMode: "constantTime" },
  });
  await cmd("project.save", { path: PROJECT });
  console.log("\nproject left on take 1 (0.04 / constantTime) and saved.");
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(500);
  // VERIFY rather than assert. The last script CLAIMED the app was left running
  // and it was not.
  let up = "";
  try { up = execSync("lsof -nP -iTCP:17695 -sTCP:LISTEN 2>/dev/null || true").toString(); } catch {}
  console.log(up.includes("LISTEN")
    ? `\n✅ VERIFIED: staging is LISTENING on 17695 with the song loaded.`
    : `\n⚠️ staging is NOT on 17695 — say so rather than claiming it is up.`);
}
