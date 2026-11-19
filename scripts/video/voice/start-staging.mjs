#!/usr/bin/env node
// Launch staging for the voice film AND PARK (features/start-staging.mjs's shape).
//
// ⚠ WHY THIS PARKS: `startStaging` registers a process-exit handler that kills
// the child. A film build spans many shell invocations, so this process stays
// alive and IS the stop button: kill THIS pid (the launcher) and staging stops
// pidfile-exact.
//
// ⚠ 17695 ONLY. 17600 is the user's live app; this file never names it.
//
// THE SINGING ENGINE (census 2026-10-10, SingingSidecarManager.swift:1000-1018):
//   DAWPRO_SING_RUNTIME_DIR → the runtime folder (its run/sing.pid is the
//     sidecar's pidfile). Here: a PRIVATE copy built by sing-runtime.sh, so the
//     user's real install's pidfile is never touched.
//   SING_API_URL → the base URL the app spawns run.sh on (port parsed from it).
//     Here: 127.0.0.1:18004, the documented staging/test port. NEVER 8004.
import { writeFileSync, existsSync } from "node:fs";
import { launchStaging, STAGING_PORT } from "/Users/dsemenov/Views/daw-pro/scripts/gates/_staging.mjs";

const DIR = process.env.VOICE_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const RT = `${DIR}/work/sing-runtime`;
if (!existsSync(`${RT}/install.json`)) {
  console.error(`⛔ no private singing runtime at ${RT} — run sing-runtime.sh first`);
  process.exit(1);
}

const s = await launchStaging({
  gate: "voice-film",
  port: STAGING_PORT,
  detached: true,
  pidfile: `${DIR}/staging.pid`,
  settleMs: 1500,
  // 1600x900 = 16:9: at screenrec --scale 2.0 it captures 3200x1800, a clean
  // downsample to the film's 1920x1080 (screenrec/README). Set ONCE, at launch.
  env: {
    STAGING_WINDOW_SIZE: "1600x900",
    DAWPRO_SING_RUNTIME_DIR: RT,
    SING_API_URL: "http://127.0.0.1:18004",
  },
  outDir: DIR,
});

const reply = await new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error("no reply in 20s")), 20000);
  s.ws.addEventListener("message", (e) => { clearTimeout(t); res(String(e.data)); });
  s.ws.send(JSON.stringify({ id: "probe-1", command: "project.overview", params: {} }));
});
s.ws.close();

writeFileSync(`${DIR}/staging.json`, JSON.stringify({
  pid: s.pid, port: STAGING_PORT, profileRoot: s.profileRoot,
  binary: s.binary, defaultsDomain: s.defaultsDomain,
  launcherPid: process.pid, probeOk: reply.slice(0, 200), at: new Date().toISOString(),
  singRuntime: RT, singApi: "http://127.0.0.1:18004",
}, null, 2));

console.log(`staging up: app pid ${s.pid} on ${STAGING_PORT}, launcher pid ${process.pid}`);
console.log("PARKED — kill THIS process (the launcher) to stop staging cleanly.");
setInterval(() => {}, 1 << 30);
