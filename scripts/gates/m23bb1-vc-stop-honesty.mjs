// m23-bb-1 gate — `vc.sidecarStop` must never claim the RVC voice-conversion
// sidecar "was not running" while it is demonstrably answering its health probe.
//
// ⭐ THE POINT OF THIS GATE, and why it costs seconds rather than minutes: it
// proves the honesty invariant over the REAL wire WITHOUT booting the real RVC
// sidecar and WITHOUT loading any model. A tiny detached HTTP responder answers
// `GET /health` with the facade's own envelope shape, which is all
// `VoiceConversionManager.probeHealth()` reads — so the app genuinely believes a
// sidecar is up — while the on-disk pidfile is left GENUINELY STALE. That is
// precisely the m23-bb-1 condition, reproduced.
//
// ⚠️ THE RESPONDER IS SPAWNED AS A DETACHED SIBLING, never as a parent of the
// staging app. `SidecarStop.resolvePlan` blocks this process and all of its own
// ANCESTORS before any other check, so a responder sitting in the staging app's
// ancestor chain would trip the SELF-PROTECTION refusal and mask the IDENTITY
// refusal this gate is actually about. Both are correct refusals; only one is
// the branch under test.
//
// ⚠️ The responder script deliberately lives OUTSIDE the configured
// DAWPRO_RVC_DIR. The identity predicate's primary limb is containment of that
// directory, so a responder stored inside it would correctly identify AS the
// sidecar and be killed — turning a refusal test into a termination test.
//
// ⚠️ Never touches 8001/8002 (the real sidecar ports) or 17600 (the user's live
// app). The responder binds an EPHEMERAL port and the app is pointed at it with
// RVC_API_URL; staging is 17695 as always.
import { spawnSync, spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m23bb1-vc-stop-honesty";
const OUT = `/tmp/daw-gate-out/${GATE}`;
const RVC_DIR = `${OUT}/rvcdir`;           // the configured sidecar dir
const RESP_DIR = `${OUT}/responder`;       // deliberately NOT under RVC_DIR
const RESP_SCRIPT = `${RESP_DIR}/health-responder.mjs`;
const PORT_FILE = `${RESP_DIR}/port.txt`;

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const argsOf = (pid) => {
  const r = spawnSync("/bin/ps", ["-ww", "-p", String(pid), "-o", "args="], { encoding: "utf8" });
  return (r.stdout || "").trim();
};

rmSync(OUT, { recursive: true, force: true });
mkdirSync(RVC_DIR, { recursive: true });
mkdirSync(RESP_DIR, { recursive: true });

// ---------------------------------------------------------------- responder
// Answers ONLY what probeHealth() reads: 200 + `{"data": {...}}`. Writes its own
// ephemeral port to a file so the gate never has to guess/race for a free one.
writeFileSync(RESP_SCRIPT, `
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const body = JSON.stringify({
  data: { service: "rvc-vc-facade", version: "0.1.0",
          engine: "Acelogic/Retrieval-based-Voice-Conversion-MLX",
          baseModelPresent: true, voiceCount: 0 },
  code: 0, error: null,
});
const server = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(body);
});
server.listen(0, "127.0.0.1", () => {
  writeFileSync(${JSON.stringify(PORT_FILE)}, String(server.address().port));
});
`);

const responder = spawn(process.execPath, [RESP_SCRIPT], {
  detached: true, stdio: "ignore",
});
responder.unref();
const responderPid = responder.pid;

let responderPort = null;
for (let i = 0; i < 60 && responderPort === null; i++) {
  if (existsSync(PORT_FILE)) responderPort = readFileSync(PORT_FILE, "utf8").trim();
  else await sleep(100);
}
if (!responderPort) {
  console.log("FAIL responder never reported a port — aborting");
  if (responderPid && alive(responderPid)) process.kill(responderPid, "SIGKILL");
  process.exit(1);
}
console.log(`responder: pid ${responderPid} on 127.0.0.1:${responderPort}`);
ck("A responder is a SIBLING, not an ancestor of this process", responderPid !== process.pid);

// ------------------------------------------------------- genuinely stale pid
// A pid that really is dead: run a trivial command and reuse its (now-exited)
// pid. Far better than a guessed constant, which could be a live stranger.
const corpse = spawnSync("/bin/echo", ["stale"]);
const stalePid = corpse.pid;
writeFileSync(`${RVC_DIR}/.rvc.pid`, String(stalePid));
writeFileSync(`${RVC_DIR}/.install-state.json`, "{}");
ck("B the pidfile's pid is genuinely dead (the m23-bb-1 precondition)",
   !alive(stalePid), `pid ${stalePid} is still alive`);

// -------------------------------------------------------------------- launch
buildOrAbort({ label: "building staging binary (m23bb1)…" });
startStaging({
  gate: GATE,
  env: { DAWPRO_RVC_DIR: RVC_DIR, RVC_API_URL: `http://127.0.0.1:${responderPort}` },
});
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `bb1${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}

// ---------------------------------------------------------------------- legs
let r = await cmd("vc.sidecarStatus");
const statusBefore = r.result ?? {};
ck("C vc.sidecarStatus sees the sidecar as HEALTHY (the probe answers)",
   statusBefore.state === "healthy", JSON.stringify(statusBefore));

r = await cmd("vc.sidecarStop");
const stopMsg = String(r.error?.message ?? r.error ?? r.result?.message ?? "");
console.log(`vc.sidecarStop -> ok=${r.ok} :: ${stopMsg}`);

ck("D vc.sidecarStop FAILS rather than returning a success-shaped status",
   r.ok === false, JSON.stringify(r));
ck("E the message never says 'not running' (THE m23-bb-1 DEFECT)",
   !/not running/i.test(stopMsg), stopMsg);
ck("F the message says the sidecar is STILL UP",
   /still up/i.test(stopMsg), stopMsg);
ck("G the message names the base URL it is still answering on",
   stopMsg.includes(`127.0.0.1:${responderPort}`), stopMsg);
ck("H the message is ACTIONABLE — it names a `kill <pid>` the user can run",
   /kill \d+/.test(stopMsg) || /kill <pid>/.test(stopMsg), stopMsg);

// ⚠️ Assert the branch by the wording the SOURCE actually emits. m23-bb's own
// e2e went red here because the assertion said "not identified" while the
// message says "does not identify" — a broken pattern, not a finding.
ck("I the IDENTITY refusal fired (not the self-protection one)",
   /does not identify it as/i.test(stopMsg), stopMsg);
ck("J the refusal names the RVC sidecar, never ACE-Step",
   /RVC/.test(stopMsg) && !/ace[-_]?step/i.test(stopMsg), stopMsg);

// A refusal must mutate NOTHING.
ck("K the responder was NOT killed — we never signal what we cannot identify",
   alive(responderPid), `responder pid ${responderPid} died`);
ck("L the stale pidfile still exists — a refusal removes nothing",
   existsSync(`${RVC_DIR}/.rvc.pid`));
r = await cmd("vc.sidecarStatus");
ck("M the sidecar is still reported healthy after the refusal",
   (r.result ?? {}).state === "healthy", JSON.stringify(r.result));

// ---------------------------------------------------------------- teardown
ws.close();
stopStaging(GATE);

// Pid-exact, and only after CONFIRMING the pid is still our responder — never
// pkill/pgrep, and never a pid we cannot identify (the m23-az law).
if (alive(responderPid)) {
  const args = argsOf(responderPid);
  if (args.includes(RESP_SCRIPT)) {
    process.kill(responderPid, "SIGTERM");
    await sleep(300);
    if (alive(responderPid)) process.kill(responderPid, "SIGKILL");
    console.log(`restore: responder pid ${responderPid} confirmed stopped (${!alive(responderPid)})`);
  } else {
    console.log(`restore: REFUSING to kill pid ${responderPid} — args do not match the responder: ${args}`);
    fail++;
  }
}

console.log(`ORCH_M23BB1 pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
