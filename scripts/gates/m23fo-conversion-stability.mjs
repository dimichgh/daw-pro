// m23-fo GATE — repeated voice conversion must NOT degrade to saturation.
//
// ⭐ THIS IS THE LEG THAT PROVES THE FIX, and it is also the FIRST TIME the
// defect is reproduced over HTTP at all. The m23-fd spike measured it by
// calling `RVC_MLX.infer()` directly and said so explicitly: "Not verified
// through the HTTP server ... reproduce it through the sidecar before acting"
// (docs/research/2026-08-10-voice-blending-spike.md §2.4). Leg 1 is therefore
// not merely a control — it is the confirmation.
//
// Two legs, ONE variable:
//
//   leg 1 RED    bash <scratch>/rvcgate/run.sh   PYTHONPATH UNSET   -> saturates
//   leg 2 GREEN  bash <scratch>/rvcgate/run.sh   PYTHONPATH SET     -> stable
//
// PYTHONPATH points at `scripts/rvc-mitigation/`, whose single `sitecustomize.py`
// wraps `RVC_MLX.infer` with `mx.clear_cache()`. Everything else — argv, cwd,
// every other environment variable, the reps, the stimulus, the request body —
// is identical. Leg 2's later bind time is a CONSEQUENCE of that one variable
// (the hook eagerly imports MLX + the engine before the port binds), not a
// second variable; it is reported as the cost.
//
// ⚠️⚠️ ASSERTS ON WITHIN-PROCESS RATIOS, NEVER ABSOLUTE BANDS. m23-fn means the
// shipped `base_f0G40k.npz` randomises `flow_1`/`flow_3` on EVERY load, so
// cross-process absolute levels differ BY DESIGN (LSD 0.4148 between processes).
// An absolute band here would be a guaranteed flaky gate. Every threshold below
// compares a leg against ITSELF.
//
// ⛔ SAFETY — the scratch topology is what keeps this off the user's sidecar:
//   * `run.sh` + `server.py` + `.install-state.json` are COPIED into scratch and
//     SHA256-verified against the originals (or the gate silently drifts from
//     what ships). Only `runtime/src` is symlinked to the real vendored tree,
//     and `runtime/` itself is a REAL directory so LOG_DIR/OUT_DIR derive into
//     scratch — asserted, not assumed.
//   * Port 18002. NEVER 8002 (the user's real sidecar) and NEVER 17600 (the
//     user's live app). The scratch `run.sh` writes its OWN pidfile beside
//     itself, so the fenced `scripts/rvc/.rvc.pid` is never read or written and
//     the double-start guard can never collide with the real sidecar.
//   * `PYTHONPYCACHEPREFIX` sends every `.pyc` into scratch, so importing
//     through the symlink writes nothing under the fence.
//   * Every facade is killed PID-EXACT from the SCRATCH pidfile in a `finally`
//     — including on the RED leg, which is the one that leaves residue. SIGTERM,
//     poll, escalate to SIGKILL, verify with `kill -0`. Never pkill/pgrep.
//     A model-holding process left alive can hold tens of GB while RSS
//     under-reports it.
//   * `scripts/rvc/` is a READ-ONLY FENCE: the gate audits it by mtime bracket
//     at start and end, with a positive control, plus the `.pyc` count and the
//     fenced pidfile's state.
//
// Legs 3+ (the Swift env merge, the tri-state honesty field) are m23-fo-2.
// Leg 5 (the real fenced run.sh on 8002, by hand) is m23-fo-3.
//
//   node scripts/gates/m23fo-conversion-stability.mjs
//   M23FO_REPS=4 node scripts/gates/m23fo-conversion-stability.mjs   # smoke
import { spawn, spawnSync } from "node:child_process";
import { startStaging, stopStaging, connect, buildOrAbort } from "./_staging.mjs";
import {
  mkdirSync, rmSync, writeFileSync, readFileSync, existsSync,
  copyFileSync, symlinkSync, statSync, readdirSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.dirname(path.dirname(HERE));   // scripts/gates -> scripts -> repo
const FENCE = path.join(REPO, "scripts", "rvc");
const REAL_SRC = path.join(FENCE, "runtime", "src");
const VENV_PY = path.join(REAL_SRC, ".venv", "bin", "python");
const MITIGATION_DIR = path.join(REPO, "scripts", "rvc-mitigation");
const RVC_MODEL_DIR = path.join(REPO, "scripts", "rvc-model");

const GATE = "m23fo-conversion-stability";
const OUT = path.join(process.env.DAWPRO_GATE_OUT || "/tmp/daw-gate-out", GATE);
const RVCGATE = path.join(OUT, "rvcgate");
const RUNTIME = path.join(RVCGATE, "runtime");
const PIDFILE = path.join(RVCGATE, ".rvc.pid");
const PYCACHE = path.join(OUT, "pycache");
const CAPTURED = path.join(OUT, "captured");
const STIMULUS = path.join(OUT, "stimulus.wav");
const EPOCH = path.join(OUT, "fence-epoch");

const PORT = 18002;                       // NEVER 8002, NEVER 17600
const REPS = Number(process.env.M23FO_REPS || 12);
/// `M23FO_LEGS=1,2` runs the audio legs alone; `=3` the Swift-seam leg alone.
const LEGS = new Set((process.env.M23FO_LEGS || "1,2,3").split(",").map((s) => s.trim()));
const BOOT_TIMEOUT_MS = 180_000;
const CONVERT_TIMEOUT_MS = 600_000;

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
  return !!cond;
};
const note = (m) => console.log("  · " + m);
const sha256 = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ⚠️ `kill(pid, 0)` ALONE IS NOT A LIVENESS TEST FOR OUR OWN CHILD. An exited
// child that node has not yet reaped is a ZOMBIE, and a zombie answers
// `kill -0` successfully — which made the first run of this gate report
// "SURVIVED SIGKILL" for a process that had already exited. The `ps` state is
// what settles it: empty (reaped) or `Z` (zombie) both mean dead.
const alive = (pid) => {
  try { process.kill(pid, 0); } catch { return false; }
  const r = spawnSync("/bin/ps", ["-p", String(pid), "-o", "state="], { encoding: "utf8" });
  const st = (r.stdout || "").trim();
  return st !== "" && !st.startsWith("Z");
};

// ------------------------------------------------------------------ cleanup
// Idempotent, pid-exact, and registered on signals so an interrupted run never
// leaves a model-holding process alive.
const tracked = new Set();

// Must be ASYNC: a synchronous busy-wait blocks node's event loop, so the
// child is never reaped and stays a zombie for the whole wait — which is
// precisely how the first run manufactured a false "SURVIVED SIGKILL".
async function killPidExact(pid, label) {
  if (!pid || !Number.isInteger(pid) || pid <= 1) return "no-pid";
  if (!alive(pid)) return "already-gone";
  try { process.kill(pid, "SIGTERM"); } catch { /* raced */ }
  for (let i = 0; i < 100; i++) { await sleep(100); if (!alive(pid)) return "sigterm"; }
  try { process.kill(pid, "SIGKILL"); } catch { /* raced */ }
  for (let i = 0; i < 50; i++) { await sleep(100); if (!alive(pid)) return "sigkill"; }
  console.log(`  !! ${label} pid ${pid} SURVIVED SIGKILL — investigate by hand`);
  return "SURVIVED";
}

async function cleanupAll(reason) {
  for (const entry of [...tracked]) {
    const how = await killPidExact(entry.pid, entry.label);
    if (how !== "no-pid" && how !== "already-gone") {
      console.log(`  · cleanup(${reason}): ${entry.label} pid ${entry.pid} -> ${how}`);
    }
    tracked.delete(entry);
  }
}
// On a signal there is no time to be polite: SIGKILL every tracked pid, still
// pid-exact, still never pkill/pgrep. A model-holding facade left alive can
// hold tens of GB while RSS under-reports it.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    for (const e of tracked) { try { process.kill(e.pid, "SIGKILL"); } catch { /* gone */ } }
    process.exit(130);
  });
}

// --------------------------------------------------------------- fence audit
function fencePyc() {
  const r = spawnSync("/bin/sh", ["-c",
    `find ${JSON.stringify(FENCE)} -name '*.pyc' | wc -l; ` +
    `find ${JSON.stringify(FENCE)} -type d -name '__pycache__' | wc -l`],
    { encoding: "utf8" });
  const [pyc, dirs] = (r.stdout || "").trim().split("\n").map((s) => Number(s.trim()));
  return { pyc, dirs };
}
function fenceTouchedSince(epochFile, kind) {
  const r = spawnSync("/bin/sh", ["-c",
    `find ${JSON.stringify(FENCE)} -type ${kind} -newer ${JSON.stringify(epochFile)} ` +
    `2>/dev/null | head -40`], { encoding: "utf8" });
  return (r.stdout || "").trim().split("\n").filter(Boolean);
}
// ⚠️ MEASURED, NOT ASSUMED — and it is NOT us. A conversion makes librosa call
// numba, whose on-disk cache lives in librosa's own `__pycache__` directories;
// touching that cache bumps THREE directory mtimes while creating, deleting and
// modifying NO file (the .nbc/.nbi/.pyc inside keep their install-day mtimes and
// the fence .pyc count is constant). Independently controlled: a bare
// `librosa.load()` on the vendored interpreter with PYTHONDONTWRITEBYTECODE=1,
// no PYTHONPATH, no hook and cwd outside the repo bumps exactly the same
// directories. The user's real sidecar therefore does this on every single
// conversion; it is shipped behaviour of the vendored engine, not gate residue.
// The lever, if the project ever wants a hermetic fence, is `NUMBA_CACHE_DIR` —
// deliberately NOT set here, because this gate's value is fidelity to the
// environment the sidecar actually runs in.
const NUMBA_CACHE_DIR_RE = /\/librosa\/(?:[^/]+\/)*__pycache__$/;
function pidfileState(p) {
  if (!existsSync(p)) return { present: false };
  const st = statSync(p);
  return { present: true, mtimeMs: st.mtimeMs, body: readFileSync(p, "utf8") };
}

// ------------------------------------------------------------------- HTTP
async function get(pathname, timeoutMs = 5_000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}${pathname}`, { signal: ctrl.signal });
    const text = await res.text();
    let json = null; try { json = JSON.parse(text); } catch { /* teaching html? */ }
    return { status: res.status, json, text };
  } finally { clearTimeout(t); }
}
async function post(pathname, body, timeoutMs) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}${pathname}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const text = await res.text();
    let json = null; try { json = JSON.parse(text); } catch { /* */ }
    return { status: res.status, json, text };
  } finally { clearTimeout(t); }
}

/// ⚠️ SLICE BYTES, NOT CHARACTERS. `statSync().size` is a BYTE count but
/// `String.prototype.slice` counts UTF-16 code units, and this log is dense
/// with multi-byte em-dashes (the hook's own line has one). Slicing a decoded
/// string by a byte offset OVERSHOOTS by one index per multi-byte character —
/// which silently cut leg 3's "mitigation ACTIVE" line out of its own slice
/// once legs 1-2 had put ~38 kB ahead of it. Invisible at offset 0, which is
/// why only the full run caught it.
function readLogSince(file, byteOffset) {
  return readFileSync(file).subarray(byteOffset).toString("utf8");
}

function logTail(n = 30) {
  const f = path.join(RUNTIME, "logs", "rvc-facade.log");
  if (!existsSync(f)) return "(no scratch facade log)";
  return readFileSync(f, "utf8").split("\n").slice(-n).join("\n");
}

// ======================================================================
// 0. Preflight + scratch topology
// ======================================================================
console.log(`# ${GATE} — reps=${REPS}, port=${PORT}`);
console.log("");
console.log("0. preflight + scratch topology");

if (!existsSync(VENV_PY)) {
  console.log(`FAIL vendored interpreter missing at ${VENV_PY} — run scripts/rvc/install.sh`);
  process.exit(1);
}

// Refuse to run if anything already owns our port, and NEVER probe 8002/17600.
{
  const r = spawnSync("/usr/sbin/lsof", ["-nP", `-iTCP:${PORT}`, "-sTCP:LISTEN"], { encoding: "utf8" });
  ck("port 18002 is free before we start", !(r.stdout || "").trim(), (r.stdout || "").trim());
}

rmSync(OUT, { recursive: true, force: true });
mkdirSync(RVCGATE, { recursive: true });
mkdirSync(RUNTIME, { recursive: true });        // REAL dir: only src is a symlink
mkdirSync(PYCACHE, { recursive: true });
mkdirSync(CAPTURED, { recursive: true });
writeFileSync(EPOCH, "");

const fenceBefore = fencePyc();
const fencePidBefore = pidfileState(path.join(FENCE, ".rvc.pid"));
note(`fence baseline: ${fenceBefore.pyc} .pyc in ${fenceBefore.dirs} __pycache__ dirs; ` +
     `scripts/rvc/.rvc.pid ${fencePidBefore.present ? "present" : "ABSENT"}`);

// --- copy + SHA256 against the originals ------------------------------
for (const f of ["run.sh", "server.py", ".install-state.json"]) {
  const src = path.join(FENCE, f), dst = path.join(RVCGATE, f);
  copyFileSync(src, dst);
  ck(`scratch ${f} is byte-identical to the shipped one`, sha256(src) === sha256(dst), sha256(src).slice(0, 16));
}
symlinkSync(REAL_SRC, path.join(RUNTIME, "src"));
ck("runtime/ is a real directory and only runtime/src is a symlink",
   !statSync(RUNTIME).isSymbolicLink() && statSync(path.join(RUNTIME, "src")).isDirectory());

// --- deterministic stimulus (rights-clear synthetic; never a recording) ---
{
  const gen = path.join(OUT, "make_stimulus.py");
  writeFileSync(gen, `
import sys
import numpy as np, soundfile as sf
# Fixed seed; the only stochastic component is a -60 dBFS breath bed, so the
# file is bit-reproducible on any machine. ~4 s, matching the length the spike
# measured the rep-4/5 onset with: allocation volume per call scales with it.
rng = np.random.default_rng(20260810)
sr, secs, f0 = 44100, 4.0, 120.0
t = np.arange(int(sr * secs)) / sr
vib = 1.0 + 0.004 * np.sin(2 * np.pi * 5.2 * t)
sig = np.zeros_like(t)
# 24 harmonics under a 3-formant envelope -> a sustained /a/-like vowel that
# RMVPE tracks cleanly (a pure tone or noise gives it nothing to lock to).
formants = [(700.0, 110.0, 1.0), (1220.0, 140.0, 0.55), (2600.0, 220.0, 0.28)]
for n in range(1, 25):
    fn = f0 * n
    if fn > sr / 2 - 1000: break
    g = sum(a / (1.0 + ((fn - fc) / bw) ** 2) for fc, bw, a in formants)
    sig += (g / n ** 0.5) * np.sin(2 * np.pi * fn * np.cumsum(vib) / sr)
env = np.minimum(1.0, np.minimum(t / 0.05, (secs - t) / 0.15))
sig = sig * env
sig = sig / np.abs(sig).max() * 0.30           # ~ -10.5 dBFS peak
sig += rng.normal(0.0, 1e-3, sig.shape)
sf.write(sys.argv[1], sig.astype(np.float32), sr)
print("stimulus", sys.argv[1])
`);
  const r = spawnSync(VENV_PY, [gen, STIMULUS], {
    encoding: "utf8",
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", OMP_NUM_THREADS: "1" },
  });
  ck("deterministic stimulus generated", existsSync(STIMULUS), (r.stderr || "").slice(-300));
}

// --- warm the bytecode cache so the two legs' BOOT times are comparable ---
// PYTHONPYCACHEPREFIX makes the interpreter ignore the fence's existing
// __pycache__ trees, so the first boot under it recompiles thousands of
// modules. Paying that here means leg 1 and leg 2 both start warm and the
// boot-time delta reported below is the hook's cost, not cache luck.
{
  const t0 = Date.now();
  const r = spawnSync(VENV_PY, ["-c", "import rvc_mlx.infer.infer_mlx, uvicorn, fastapi"], {
    cwd: REAL_SRC, encoding: "utf8",
    env: { ...process.env, PYTHONPYCACHEPREFIX: PYCACHE, OMP_NUM_THREADS: "1",
           PYTHONPATH: REAL_SRC },
  });
  ck("bytecode cache warmed under PYTHONPYCACHEPREFIX", r.status === 0, (r.stderr || "").slice(-400));
  note(`warm-up took ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}

// ======================================================================
// leg runner
// ======================================================================
async function runLeg({ name, withHook }) {
  const leg = {
    name, withHook, bootSeconds: null, mitigationStatus: null,
    reps: [], outputs: [], captured: [], clearCacheCalls: null, engineLoadSeconds: null,
    childPid: null, pidfilePid: null, killedBy: null, error: null, stderr: "",
  };
  const env = {
    ...process.env,
    RVC_RUNTIME_DIR: RUNTIME,
    RVC_API_PORT: String(PORT),
    DAWPRO_RVC_DIR: RVCGATE,
    PYTHONPYCACHEPREFIX: PYCACHE,
  };
  // THE one variable.
  if (withHook) env.PYTHONPATH = MITIGATION_DIR; else delete env.PYTHONPATH;

  let child = null;
  // The facade log is APPENDED across both legs (run.sh:70 `exec >> LOG_FILE`),
  // so slice out only this leg's share before asserting on it.
  const logFile = path.join(RUNTIME, "logs", "rvc-facade.log");
  const logOffset = existsSync(logFile) ? statSync(logFile).size : 0;
  try {
    const t0 = Date.now();
    child = spawn("/bin/bash", [path.join(RVCGATE, "run.sh")], {
      env, stdio: ["ignore", "pipe", "pipe"],
    });
    leg.childPid = child.pid;
    tracked.add({ pid: child.pid, label: `${name} facade` });
    child.stdout.on("data", () => {});   // run.sh redirects into the log after 2 lines
    // Informational only: run.sh's own diagnostics land here before it
    // redirects into the log. A non-empty stderr is NOT by itself a failure.
    child.stderr.on("data", (d) => { leg.stderr += d.toString(); });

    // wait for health
    const deadline = Date.now() + BOOT_TIMEOUT_MS;
    let up = false;
    while (Date.now() < deadline) {
      if (child.exitCode !== null) {
        leg.error = `run.sh exited ${child.exitCode}\n${leg.stderr.slice(-600)}`;
        break;
      }
      try {
        const h = await get("/health", 3_000);
        if (h.status === 200 && h.json && h.json.data) { up = true; break; }
      } catch { /* not up yet */ }
      await sleep(500);
    }
    leg.bootSeconds = (Date.now() - t0) / 1000;
    if (!up) { leg.error = (leg.error || "") + "\nfacade never became healthy\n" + logTail(); return leg; }

    if (existsSync(PIDFILE)) leg.pidfilePid = Number(readFileSync(PIDFILE, "utf8").trim());

    // The mitigation route: ABSENT on leg 1, PRESENT on leg 2. Proves the one
    // variable landed at the HOOK level, before any audio is looked at.
    const m = await get("/v1/_dawpro/mitigation", 5_000);
    leg.mitigationStatus = m.status;
    leg.mitigationBody = m.json;

    for (let i = 0; i < REPS; i++) {
      const r = await post("/v1/voice/convert",
        { inputPath: STIMULUS, voiceId: "base", pitchSemitones: 0 }, CONVERT_TIMEOUT_MS);
      if (r.status !== 200 || !r.json || !r.json.outputPath) {
        leg.error = (leg.error || "") + `\nconvert ${i} -> ${r.status} ${r.text.slice(0, 300)}`;
        break;
      }
      leg.outputs.push(r.json.outputPath);
      // ⚠️ CAPTURE IMMEDIATELY, BEFORE THE NEXT CONVERSION. `server.py:333`
      // builds the output name from a ONE-SECOND-RESOLUTION UTC timestamp plus
      // voiceId, pid and thread id — all constant within a second — so at
      // ~0.15 s per conversion the facade OVERWRITES its own output and 12 reps
      // land in as few as 3 distinct files. Measured. Analysing the returned
      // paths after the loop silently aliases most reps onto the last write and
      // manufactures exactly the flat curve this gate is trying to detect.
      const cap = path.join(CAPTURED, `${name}-rep${String(i).padStart(2, "0")}.wav`);
      copyFileSync(r.json.outputPath, cap);
      leg.captured.push(cap);
      leg.reps.push({
        rep: i,
        inferSeconds: r.json.inferSeconds,
        engineLoadSeconds: r.json.engineLoadSeconds,
        rtf: r.json.rtf,
      });
      if (i === 0) leg.engineLoadSeconds = r.json.engineLoadSeconds;
    }

    const m2 = await get("/v1/_dawpro/mitigation", 5_000);
    if (m2.status === 200 && m2.json && m2.json.data) {
      leg.clearCacheCalls = m2.json.data.clearCacheCalls;
      leg.mitigationFinal = m2.json.data;
    }
  } catch (e) {
    leg.error = (leg.error || "") + "\n" + String(e && e.stack || e);
  } finally {
    // PID-EXACT, from the SCRATCH pidfile, on EVERY path including the red leg.
    const pids = new Set();
    if (existsSync(PIDFILE)) {
      const p = Number(readFileSync(PIDFILE, "utf8").trim());
      if (Number.isInteger(p) && p > 1) pids.add(p);
    }
    if (child && child.pid) pids.add(child.pid);
    for (const p of pids) leg.killedBy = await killPidExact(p, `${name} facade`);
    for (const t of [...tracked]) if (pids.has(t.pid)) tracked.delete(t);
    leg.stillAlive = [...pids].filter(alive);
    leg.logSlice = existsSync(logFile) ? readLogSince(logFile, logOffset) : "";
    // run.sh refuses to double-start while its pidfile names a live process,
    // so leg 2 cannot begin until this is genuinely dead.
    rmSync(PIDFILE, { force: true });
  }
  return leg;
}

function analyse(paths) {
  if (!paths.length) return [];
  const drv = path.join(OUT, "analyse.py");
  writeFileSync(drv, `
import json, sys
sys.path.insert(0, ${JSON.stringify(RVC_MODEL_DIR)})
from measure_conversion import analyse      # the SAME analyser m23-fn used
print(json.dumps([analyse(p) for p in sys.argv[1:]]))
`);
  const r = spawnSync(VENV_PY, [drv, ...paths], {
    encoding: "utf8", maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", OMP_NUM_THREADS: "1" },
  });
  try { return JSON.parse(r.stdout); }
  catch { console.log("  !! analyse failed: " + (r.stderr || "").slice(-500)); return []; }
}

const summarise = (m) => ({
  rms: m.map((x) => x.rms),
  peak: m.map((x) => x.peak),
  first: m[0], last: m[m.length - 1],
  maxPeak: Math.max(...m.map((x) => x.peak)),
  minRms: Math.min(...m.map((x) => x.rms)),
  maxRms: Math.max(...m.map((x) => x.rms)),
});

// ======================================================================
// LEG 3 (m23-fo-2) — the SWIFT seam
// ======================================================================
// Legs 1-2 set `PYTHONPATH` themselves, so they prove the HOOK works and say
// nothing about whether the APP arms it. Leg 3 removes exactly that gap: the
// staging app spawns the facade over the control protocol and the only thing
// that can have set `PYTHONPATH` is
// `VoiceConversionManager.Configuration.childEnvironment`.
//
// ⚠️ `PYTHONPATH: ""` is passed to the STAGING APP on purpose. It makes the
// claim airtight — the app inherits nothing to pass on, so a `PYTHONPATH` in
// the facade can only have come from Swift — and it exercises the
// present-but-empty case (a real shell state, and the one a naive join turns
// into a trailing `:` that Python reads as the current directory).
function wsCall(ws) {
  let n = 0;
  return (command, params = {}) => new Promise((res, rej) => {
    const id = `fo3${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 120_000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

const STAGING_ENV_BASE = {
  RVC_RUNTIME_DIR: RUNTIME,
  RVC_API_PORT: String(PORT),
  DAWPRO_RVC_DIR: RVCGATE,
  DAWPRO_RVC_MITIGATION_DIR: MITIGATION_DIR,
  PYTHONPYCACHEPREFIX: PYCACHE,
  PYTHONPATH: "",
};

/// 3a — NEGATIVE CONTROL. Proves the tri-state parses BOTH ways: without it a
/// green `true` could just mean "this field is always true". A tiny responder
/// answers `/health` like the facade and 404s the mitigation route — exactly
/// the shape of a `run.sh` a user started by hand, which `start()`'s
/// already-healthy early return means the app never re-launches.
async function leg3Negative() {
  console.log("");
  console.log("3a. LEG 3 NEGATIVE CONTROL — an unhooked facade must read FALSE, not null");
  const dir = path.join(OUT, "unhooked");
  mkdirSync(dir, { recursive: true });
  const script = path.join(dir, "unhooked-facade.mjs");
  const portFile = path.join(dir, "port.txt");
  writeFileSync(script, `
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const health = JSON.stringify({
  data: { service: "rvc-vc-facade", version: "0.1.0",
          engine: "Acelogic/Retrieval-based-Voice-Conversion-MLX",
          baseModelPresent: true, voiceCount: 0, port: 0 },
  code: 0, error: null });
createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(health);
  } else {                       // notably /v1/_dawpro/mitigation
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ detail: "Not Found" }));
  }
}).listen(0, "127.0.0.1", function () {
  writeFileSync(${JSON.stringify(portFile)}, String(this.address().port));
});
`);
  const responder = spawn(process.execPath, [script], { detached: true, stdio: "ignore" });
  responder.unref();
  tracked.add({ pid: responder.pid, label: "leg3 unhooked responder" });

  let stubPort = null;
  for (let i = 0; i < 100 && stubPort === null; i++) {
    await sleep(100);
    if (existsSync(portFile)) stubPort = Number(readFileSync(portFile, "utf8").trim());
  }
  if (!ck("3a responder bound a port", !!stubPort, String(stubPort))) return;

  let ws = null;
  try {
    startStaging({
      gate: GATE,
      env: { ...STAGING_ENV_BASE, RVC_API_URL: `http://127.0.0.1:${stubPort}` },
    });
    ws = await connect();
    const call = wsCall(ws);
    const res = await call("vc.sidecarStatus");
    const st = res.result ?? {};
    report.leg3Negative = st;
    ck("3a the app sees the sidecar as healthy", st.state === "healthy", JSON.stringify(st));
    ck("3a mitigationActive is FALSE — a positive answer, NOT null",
       st.mitigationActive === false, JSON.stringify(st.mitigationActive));
    ck("3a mitigationDetail explains WHICH false path (the 404 one)",
       typeof st.mitigationDetail === "string" && st.mitigationDetail.includes("404"),
       String(st.mitigationDetail));
    ck("3a the message WARNS and names m23-fo — the user's only signal here",
       /m23-fo/i.test(String(st.message)), String(st.message));
  } catch (e) {
    ck("3a leg completed", false, String(e && e.stack || e));
  } finally {
    try { ws && ws.close(); } catch { /* already closed */ }
    stopStaging(GATE);
    for (const t of [...tracked]) {
      if (t.pid === responder.pid) { await killPidExact(t.pid, t.label); tracked.delete(t); }
    }
  }
}

/// 3b — THE POSITIVE LEG. The app itself spawns the real scratch facade.
async function leg3Positive() {
  console.log("");
  console.log("3b. LEG 3 — the STAGING APP starts the facade; only Swift can set PYTHONPATH");
  let ws = null;
  const logFile = path.join(RUNTIME, "logs", "rvc-facade.log");
  const logOffset = existsSync(logFile) ? statSync(logFile).size : 0;
  try {
    startStaging({
      gate: GATE,
      env: { ...STAGING_ENV_BASE, RVC_API_URL: `http://127.0.0.1:${PORT}` },
    });
    ws = await connect();
    const call = wsCall(ws);

    const started = await call("vc.sidecarStart");
    ck("3b vc.sidecarStart succeeded", started.ok !== false,
       JSON.stringify(started.error ?? started.result));
    if (existsSync(PIDFILE)) {
      const p = Number(readFileSync(PIDFILE, "utf8").trim());
      if (Number.isInteger(p) && p > 1) tracked.add({ pid: p, label: "leg3 facade" });
    }

    let st = started.result ?? {};
    for (let i = 0; i < 60 && st.state !== "healthy"; i++) {
      await sleep(1000);
      st = (await call("vc.sidecarStatus")).result ?? {};
    }
    report.leg3Positive = st;
    ck("3b the app-spawned facade is healthy", st.state === "healthy", JSON.stringify(st));
    // ⭐ THE ASSERTION THIS LEG EXISTS FOR.
    ck("3b mitigationActive is TRUE — Swift alone set PYTHONPATH",
       st.mitigationActive === true, JSON.stringify(st));
    ck("3b the healthy message carries NO m23-fo warning",
       !/m23-fo/i.test(String(st.message)), String(st.message));

    // Independent confirmation, from the facade's own log rather than from the
    // route: if the route answered for some other reason, this would not be here.
    const slice = existsSync(logFile) ? readLogSince(logFile, logOffset) : "";
    ck("3b the facade's own log carries the hook's loud ACTIVE line",
       slice.includes("[dawpro-m23-fo]") && slice.includes("mitigation ACTIVE"),
       (slice.match(/\[dawpro-m23-fo\].*/) || ["(absent)"])[0]);

    const stopped = await call("vc.sidecarStop");
    ck("3b vc.sidecarStop succeeded", stopped.ok !== false,
       JSON.stringify(stopped.error ?? stopped.result));
  } catch (e) {
    ck("3b leg completed", false, String(e && e.stack || e));
  } finally {
    // ⚠️ ORDER: the facade FIRST. `stopStaging` kills the app that spawned it,
    // and a facade orphaned by that would hold its model with nothing tracking
    // it. Pid-exact, from OUR scratch pidfile, never pkill/pgrep.
    for (const t of [...tracked]) {
      if (t.label === "leg3 facade") { await killPidExact(t.pid, t.label); tracked.delete(t); }
    }
    try { ws && ws.close(); } catch { /* already closed */ }
    stopStaging(GATE);
    rmSync(PIDFILE, { force: true });
  }
}

async function runLeg3() {
  buildOrAbort({ root: REPO, label: "building staging binary (m23fo leg 3)…" });
  await leg3Negative();
  await leg3Positive();
}

// ======================================================================
// legs
// ======================================================================
let exitCode = 1;
const report = {};
const AUDIO = LEGS.has("1") || LEGS.has("2");
const EMPTY_LEG = { outputs: [], captured: [], reps: [], logSlice: "" };
let leg1 = EMPTY_LEG, leg2 = EMPTY_LEG;
try {
  // ---------------------------------------------------------- LEG 1 (RED)
  if (AUDIO) {
  console.log("");
  console.log("1. LEG 1 — PYTHONPATH UNSET: the defect must REPRODUCE over HTTP");
  leg1 = await runLeg({ name: "leg1", withHook: false });
  report.leg1 = leg1;
  ck("leg 1 facade booted", leg1.bootSeconds !== null && !leg1.error, (leg1.error || "").slice(-600));
  ck("leg 1 pidfile pid IS the spawned pid (run.sh execs, no wrapper process)",
     leg1.pidfilePid === leg1.childPid, `${leg1.pidfilePid} vs ${leg1.childPid}`);
  ck("leg 1 has NO mitigation route (404) — the unhooked facade, positively",
     leg1.mitigationStatus === 404, String(leg1.mitigationStatus));
  ck(`leg 1 completed ${REPS} conversions`, leg1.reps.length === REPS,
     `${leg1.reps.length}/${REPS} ${(leg1.error || "").slice(-300)}`);
  const m1 = analyse(leg1.captured);
  ck("leg 1 outputs analysed (from the per-rep CAPTURES, not the returned paths)",
     m1.length === leg1.captured.length && m1.length > 0);

  if (m1.length) {
    const s1 = summarise(m1);
    report.leg1Metrics = s1;
    console.log("   rep : rms      peak     infer(s)");
    m1.forEach((x, i) => console.log(
      `   ${String(i).padStart(3)} : ${x.rms.toFixed(6)} ${x.peak.toFixed(4)}   ` +
      `${(leg1.reps[i] && leg1.reps[i].inferSeconds) ?? "?"}`));

    // Guard BEFORE any ratio: a degenerate stimulus makes the ratio inf/NaN
    // and the RED leg would "pass" for entirely the wrong reason.
    ck("leg 1 rep 0 is not degenerate (rms > 1e-4)", s1.rms[0] > 1e-4, String(s1.rms[0]));
    ck("RED: peak[last] >= 0.98 (pinned at the vendored max-normaliser)",
       s1.last.peak >= 0.98, String(s1.last.peak));
    ck("RED: rms[last]/rms[0] >= 5", s1.rms[0] > 1e-4 && s1.last.rms / s1.rms[0] >= 5,
       (s1.last.rms / s1.rms[0]).toFixed(3));
    // COUNT PIN FIRST — `[].every()` is true, so an empty metrics array would pass
    // this vacuously. That is the m23-fa class, and this gate ships inside the
    // milestone that exists to kill it (flagged by the m23-fb vacuity census).
    ck("leg 1 output is finite throughout (no NaN/Inf samples)",
       m1.length === REPS && m1.every((x) => x.nonFinite === 0),
       `n=${m1.length}/${REPS} ` + JSON.stringify(m1.map((x) => x.nonFinite)));
  }
  // NEGATIVE control on the only diagnostic channel a user gets when the route
  // is unreachable: an unhooked facade must say nothing about the mitigation.
  ck("leg 1 facade log carries NO [dawpro-m23-fo] line",
     !(leg1.logSlice || "").includes("[dawpro-m23-fo]"),
     ((leg1.logSlice || "").match(/\[dawpro-m23-fo\].*/) || [""])[0]);
  ck("leg 1 facade is dead (pid-exact)", (leg1.stillAlive || []).length === 0,
     JSON.stringify(leg1.stillAlive));

  // -------------------------------------------------------- LEG 2 (GREEN)
  console.log("");
  console.log("2. LEG 2 — PYTHONPATH SET: identical in every other respect");
  leg2 = await runLeg({ name: "leg2", withHook: true });
  report.leg2 = leg2;
  ck("leg 2 facade booted", leg2.bootSeconds !== null && !leg2.error, (leg2.error || "").slice(-600));
  ck("leg 2 pidfile pid IS the spawned pid", leg2.pidfilePid === leg2.childPid,
     `${leg2.pidfilePid} vs ${leg2.childPid}`);
  ck("leg 2 HAS the mitigation route (200)", leg2.mitigationStatus === 200,
     String(leg2.mitigationStatus));
  const body = leg2.mitigationBody && leg2.mitigationBody.data;
  ck("leg 2 reports the engine patched, with no hook error",
     !!body && body.enginePatched === true && body.error === null,
     JSON.stringify(body));
  ck("leg 2 resolved the facade module BY IDENTITY",
     !!body && body.facadeResolvedBy === "identity",
     body ? `${body.facadeModule} via ${body.facadeResolvedBy} (aliases ${JSON.stringify(body.facadeModuleAliases)})` : "-");
  ck(`leg 2 completed ${REPS} conversions`, leg2.reps.length === REPS,
     `${leg2.reps.length}/${REPS} ${(leg2.error || "").slice(-300)}`);
  const m2 = analyse(leg2.captured);
  ck("leg 2 outputs analysed (from the per-rep CAPTURES, not the returned paths)",
     m2.length === leg2.captured.length && m2.length > 0);

  if (m2.length) {
    const s2 = summarise(m2);
    report.leg2Metrics = s2;
    console.log("   rep : rms      peak     infer(s)");
    m2.forEach((x, i) => console.log(
      `   ${String(i).padStart(3)} : ${x.rms.toFixed(6)} ${x.peak.toFixed(4)}   ` +
      `${(leg2.reps[i] && leg2.reps[i].inferSeconds) ?? "?"}`));

    ck("leg 2 rep 0 is not degenerate (rms > 1e-4)", s2.rms[0] > 1e-4, String(s2.rms[0]));
    ck("GREEN: max(peak) <= 0.90 (never reaches the normaliser)",
       s2.maxPeak <= 0.90, String(s2.maxPeak));
    ck("GREEN: max(rms)/min(rms) <= 1.05",
       s2.minRms > 0 && s2.maxRms / s2.minRms <= 1.05,
       (s2.maxRms / s2.minRms).toFixed(5));
    ck(`GREEN: clearCacheCalls == ${REPS}`, leg2.clearCacheCalls === REPS,
       String(leg2.clearCacheCalls));
    // COUNT PIN FIRST — see the leg-1 note; `[].every()` is true.
    ck("leg 2 output is finite throughout (no NaN/Inf samples)",
       m2.length === REPS && m2.every((x) => x.nonFinite === 0),
       `n=${m2.length}/${REPS} ` + JSON.stringify(m2.map((x) => x.nonFinite)));
  }
  // POSITIVE control on the same channel: the hook's one loud line must survive
  // run.sh:70's `exec >> LOG_FILE` and land in the facade log, end to end.
  {
    const line = ((leg2.logSlice || "").match(/\[dawpro-m23-fo\].*/) || [""])[0];
    ck("leg 2 facade log carries the hook's loud line (run.sh:70 redirect works)",
       line.includes("[dawpro-m23-fo]") && line.includes("mitigation ACTIVE"), line);
  }
  ck("leg 2 facade is dead (pid-exact)", (leg2.stillAlive || []).length === 0,
     JSON.stringify(leg2.stillAlive));

  }  // end AUDIO legs

  // ============================================================== LEG 3
  // m23-fo-2. Legs 1-2 prove the HOOK cures the defect; they set PYTHONPATH
  // themselves, so they say nothing about whether the APP does. Leg 3 removes
  // that: the staging app spawns the facade over the control protocol and
  // PYTHONPATH is set by SWIFT ALONE (`Configuration.childEnvironment`).
  if (LEGS.has("3")) await runLeg3();

  // ------------------------------------------------------------- topology
  if (AUDIO) {
  console.log("");
  console.log("3. isolation — nothing derived into the fence");
  const scratchLog = path.join(RUNTIME, "logs", "rvc-facade.log");
  ck("LOG_DIR derived into SCRATCH (not the fenced log)", existsSync(scratchLog), scratchLog);
  const outs = existsSync(path.join(RUNTIME, "out"))
    ? readdirSync(path.join(RUNTIME, "out")).filter((f) => f.endsWith(".wav")) : [];
  const allReturned = [...leg1.outputs, ...leg2.outputs];
  const distinct = new Set(allReturned);
  ck("OUT_DIR derived into SCRATCH", outs.length > 0 && outs.length === distinct.size,
     `${outs.length} wavs on disk vs ${distinct.size} distinct returned paths`);
  ck("every returned outputPath is under scratch",
     allReturned.every((p) => p.startsWith(RUNTIME)),
     allReturned.find((p) => !p.startsWith(RUNTIME)) || "ok");

  // Reported as a NAMED check, not a silent workaround: this is a defect in the
  // shipped facade that the gate had to route around, and it is worth someone
  // filing. `server.py:333` timestamps to the second, so back-to-back
  // conversions overwrite each other's wav.
  report.outputPathCollisions = { returned: allReturned.length, distinct: distinct.size };
  ck("NOTE — shipped facade reuses output paths within one second (m23-fo-1 finding)",
     true, `${allReturned.length} conversions -> ${distinct.size} distinct files ` +
           `(server.py:333 timestamps to 1 s; gate captures each rep immediately)`);

  // -------------------------------------------------------------- timing
  console.log("");
  console.log("4. cost of the mitigation, as a number");
  const mean = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
  const i1 = leg1.reps.map((r) => r.inferSeconds).filter(Number.isFinite);
  const i2 = leg2.reps.map((r) => r.inferSeconds).filter(Number.isFinite);
  report.timing = {
    leg1BootSeconds: leg1.bootSeconds, leg2BootSeconds: leg2.bootSeconds,
    leg1EngineLoadSeconds: leg1.engineLoadSeconds, leg2EngineLoadSeconds: leg2.engineLoadSeconds,
    leg1MeanInferSeconds: mean(i1), leg2MeanInferSeconds: mean(i2),
  };
  console.log(`   boot        : ${leg1.bootSeconds?.toFixed(2)} s -> ${leg2.bootSeconds?.toFixed(2)} s  (hook imports MLX + engine before bind)`);
  console.log(`   engine load : ${leg1.engineLoadSeconds} s -> ${leg2.engineLoadSeconds} s`);
  console.log(`   mean infer  : ${mean(i1).toFixed(3)} s -> ${mean(i2).toFixed(3)} s  (${(mean(i2) - mean(i1)).toFixed(3)} s, reallocation from Metal)`);
  console.log("   ⚠️ leg 1's infer times are NOT a clean baseline: from ~rep 4 it is");
  console.log("      computing saturated garbage, which is not the same work.");

  }  // end AUDIO reporting

  exitCode = fail === 0 ? 0 : 1;
} finally {
  await cleanupAll("finally");

  console.log("");
  console.log("5. fence audit — scripts/rvc/ is READ-ONLY");
  // ⚠️ `git status --porcelain scripts/rvc/` is nearly worthless here:
  // scripts/rvc/.gitignore:6 ignores runtime/, and only 5 files are tracked.
  // The mtime bracket is the real audit — with a positive control, because an
  // empty `find` from a broken invocation looks exactly like innocence.
  const touchedFiles = fenceTouchedSince(EPOCH, "f");
  ck("NO FILE under scripts/rvc/ is newer than the gate's epoch",
     touchedFiles.length === 0, JSON.stringify(touchedFiles.slice(0, 10)));
  const touchedDirs = fenceTouchedSince(EPOCH, "d");
  const rogue = touchedDirs.filter((d) => !NUMBA_CACHE_DIR_RE.test(d));
  ck("the only directory mtimes bumped are numba's librosa cache (shipped behaviour, see note)",
     rogue.length === 0, JSON.stringify(rogue.slice(0, 10)));
  if (touchedDirs.length) {
    note(`${touchedDirs.length} numba cache dir mtime(s) bumped: ` +
         touchedDirs.map((d) => d.replace(FENCE + "/", "")).join(", "));
  }
  const ctrl = path.join(OUT, "positive-control");
  writeFileSync(ctrl, "x");
  const ctrlSeen = spawnSync("/bin/sh", ["-c",
    `find ${JSON.stringify(OUT)} -name positive-control -newer ${JSON.stringify(EPOCH)}`],
    { encoding: "utf8" }).stdout.trim();
  ck("…and the -newer probe DOES see a file written after the epoch (positive control)",
     ctrlSeen.endsWith("positive-control"), ctrlSeen);

  const fenceAfter = fencePyc();
  ck("fence .pyc count unchanged", fenceAfter.pyc === fenceBefore.pyc,
     `${fenceBefore.pyc} -> ${fenceAfter.pyc}`);
  ck("fence __pycache__ dir count unchanged", fenceAfter.dirs === fenceBefore.dirs,
     `${fenceBefore.dirs} -> ${fenceAfter.dirs}`);
  const fencePidAfter = pidfileState(path.join(FENCE, ".rvc.pid"));
  ck("fenced scripts/rvc/.rvc.pid untouched (content AND mtime)",
     JSON.stringify(fencePidAfter) === JSON.stringify(fencePidBefore),
     `${JSON.stringify(fencePidBefore)} -> ${JSON.stringify(fencePidAfter)}`);

  writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 2));
  console.log("");
  console.log(`${GATE.toUpperCase().replace(/-/g, "_")} pass=${pass} fail=${fail}`);
  console.log(`report: ${path.join(OUT, "report.json")}`);
}
process.exit(fail === 0 ? 0 : 1);
