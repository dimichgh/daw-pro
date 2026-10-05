#!/usr/bin/env node
// Launch staging for the film build AND PARK.
//
// ⚠ WHY THIS PARKS INSTEAD OF EXITING — MEASURED, NOT STYLE.
// `startStaging` calls `armTeardown` (_staging.mjs:774), which registers a
// process-exit handler that kills the child. That is right for a gate (launch,
// probe, exit, app dies) and WRONG here: a film build spans dozens of separate
// shell invocations. The first version of this file called `process.exit(0)`
// and the app was dead before the next command ran — while the launch log still
// read like a success. So this process stays alive for the whole build and the
// teardown handler becomes the STOP button rather than an accident.
//
// ⚠ 17695 ONLY. 17600 is the user's live app; this file never names it.
import { writeFileSync } from "node:fs";
import { launchStaging, STAGING_PORT } from "/Users/dsemenov/Views/daw-pro/scripts/gates/_staging.mjs";

const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const GATE = "m39-film";

const s = await launchStaging({
  gate: GATE,
  port: STAGING_PORT,
  detached: true,
  pidfile: `${DIR}/staging.pid`,
  settleMs: 1500,
  env: { STAGING_WINDOW_SIZE: "1600x1000" },
  outDir: DIR,
});

// Prove the socket answers a REAL command before declaring the app up.
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
}, null, 2));

console.log(`staging up: app pid ${s.pid} on ${STAGING_PORT}, launcher pid ${process.pid}`);
console.log("PARKED — kill THIS process (the launcher) to stop staging cleanly.");

// Park forever. SIGTERM/SIGINT fall through to armTeardown, which stops the app
// pidfile-exact — so stopping the launcher is the sanctioned way to stop staging.
setInterval(() => {}, 1 << 30);
