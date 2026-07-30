// _staging.mjs — the ONE home for the staging-app lifecycle used by gates.
//
// WHY THIS EXISTS (m23-ac). Before this module, `m23p2-bass-enhancer.mjs:29-58`
// had been copy-pasted verbatim into six other gates, and ELEVEN more gates
// launched the binary with no build step at all while TWENTY-FOUR never
// launched anything and simply drove whatever instance happened to be
// listening on the port. A gate in that last shape certifies an instance of
// unknown provenance and cannot detect that it did: run it after a source edit
// and it returns a confident, meaningless green.
//
// The rule this module makes unrepresentable: you cannot get a connection to a
// staging instance without having built the tree first.
//
// SCOPE — deliberately just the LIFECYCLE. Each gate keeps its own `cmd()` and
// `ck()`; those carry per-gate id prefixes and timeouts, they were never the
// hazard, and absorbing them would turn a mechanical refactor into a rewrite of
// every assertion harness in the directory.
//
// ⚠️ PORT 17695 IS STAGING. 17600 IS THE USER'S LIVE APP AND IS NEVER TOUCHED.
//    That is enforced here (`assertStagingPort`), not left to each caller to
//    remember — the whole point of one home.
// ⚠️ Kill by EXACT pid from the pidfile. Never pkill/pgrep: those match on a
//    name and would take the user's live app down with the staging one.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, openSync } from "node:fs";

export const ROOT = "/Users/dsemenov/Views/daw-pro";
export const STAGING_PORT = 17695;
export const LIVE_PORT = 17600; // the user's app — never a target
export const DEFAULT_BINARY = ".build/debug/DAWApp";

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Refuse to operate on the user's live app, whatever the caller passed. */
export function assertStagingPort(port) {
  if (Number(port) === LIVE_PORT) {
    console.log(`ABORT: ${LIVE_PORT} is the user's LIVE app and is never a gate target`);
    process.exit(2);
  }
  if (!Number.isInteger(Number(port)) || Number(port) <= 0) {
    console.log(`ABORT: invalid staging port ${port}`);
    process.exit(2);
  }
  return Number(port);
}

/**
 * Build the tree, or abort. A gate that skips this tests the PREVIOUS binary —
 * and restoring a mutated source leaves the mutant on disk for the next run to
 * adopt, which is how a mutation check passes for the wrong reason.
 */
export function buildOrAbort({ root = ROOT, label = "building…", skip = false } = {}) {
  if (skip) { console.log("build SKIPPED by request — this run may be testing an older binary"); return; }
  console.log(label);
  const build = spawnSync("swift", ["build"], { cwd: root, stdio: "inherit" });
  if (build.status !== 0) {
    console.log("ABORT: swift build failed — the gate would have tested the previous binary");
    process.exit(2);
  }
}

const live = new Map(); // gate -> { child, pidfile, out, log }

/** Where a gate's pidfile lives. One resolver, so start and stop cannot disagree. */
export function pidfilePath(gate, override) {
  return override || `/tmp/daw-gate-out/${gate}/staging.pid`;
}

/**
 * Launch a staging instance. Returns { pid, out, pidfile }.
 *
 * `detached: true` matches the shape m23v/m23x use — the child outlives this
 * process and its output goes to a real file rather than in-memory pipes. It is
 * NOT the default: an attached child dies with a crashing gate, whereas a
 * detached one is left running and only the pidfile can find it again.
 */
export function startStaging({
  gate,
  root = ROOT,
  port = STAGING_PORT,
  binary = DEFAULT_BINARY,
  env = {},
  detached = false,
  pidfile: pidfileOverride,
  outDir,
  logPath,
} = {}) {
  if (!gate) throw new Error("startStaging requires a { gate } name for its pidfile/out dir");
  assertStagingPort(port);

  const out = outDir || `/tmp/daw-gate-out/${gate}`;
  const pidfile = pidfilePath(gate, pidfileOverride);
  mkdirSync(out, { recursive: true });

  // A pidfile left by a crashed earlier run would otherwise be orphaned.
  stopStaging(gate, pidfileOverride);

  let child, log;
  if (detached) {
    const fd = openSync(logPath || `${out}/staging.log`, "a");
    child = spawn(binary, [], {
      cwd: root,
      env: { ...process.env, DAW_CONTROL_PORT: String(port), ...env },
      stdio: ["ignore", fd, fd],
      detached: true,
    });
    child.unref();
  } else {
    child = spawn(binary, [], {
      cwd: root,
      env: { ...process.env, DAW_CONTROL_PORT: String(port), ...env },
      stdio: ["ignore", "pipe", "pipe"],
      detached: false,
    });
    log = [];
    child.stdout.on("data", (d) => log.push(d.toString()));
    child.stderr.on("data", (d) => log.push(d.toString()));
    process.on("exit", () => {
      try { writeFileSync(logPath || `${out}/staging.log`, log.join("")); } catch { /* best effort */ }
    });
  }
  writeFileSync(pidfile, String(child.pid));
  live.set(gate, { child, pidfile, out, log });
  return { pid: child.pid, out, pidfile };
}

/**
 * The app's crash-detection sentinel (`DAWCore.AutosaveManager.lockURL`).
 *
 * ⚠️ SECOND SPELLING OF A PATH `DAWCore.AppDirectories` OWNS. The Swift side
 * resolves `applicationSupport(.autosave)/session.lock`; this is the JS mirror
 * of it, and the two will diverge silently if `AppDirectories.Category.autosave`
 * ever changes its raw value. It is spelled ONCE here rather than in each gate
 * (m23a2 used to carry its own copy) so the JS tier has one home even though it
 * cannot share the Swift one.
 */
export function sessionLockPath(override) {
  return override || `${process.env.HOME}/Library/Application Support/DAWPro/Autosave/session.lock`;
}

/**
 * Remove the staging app's `session.lock` — but ONLY if `pid` owns it.
 *
 * WHY (m23-ac-2c). Gates kill staging with SIGTERM, which skips the app's
 * clean-exit path, so the lock it wrote at launch survives the gate. At the
 * next real launch DAW Pro reads that lock and offers the USER a recovery from
 * a crash that never happened. That is test tooling reaching out and lying to
 * the person running the app, which is why this is not merely tidiness.
 *
 * ⚠️ THE OWNERSHIP CHECK IS THE ENTIRE SAFETY PROPERTY. This function runs
 * against the user's REAL profile directory — the same file the user's live app
 * on port 17600 writes. A cleanup that deleted unconditionally would pass the
 * obvious test and destroy a real crash recovery. So: a lock we cannot PROVE is
 * ours is left alone, and every uncertain branch (absent file, unreadable,
 * malformed JSON, missing/NaN pid) falls through to leaving it.
 *
 * Returns true if removed, false if left alone, null if there was no lock.
 */
export function releaseSessionLock(pid, lockPathOverride) {
  const lock = sessionLockPath(lockPathOverride);
  let owner;
  try {
    owner = JSON.parse(readFileSync(lock, "utf8")).pid;
  } catch {
    return null; // absent / unreadable / malformed — never guess at ownership
  }
  // ⚠️ STRICT `typeof`, NOT `Number(owner)`. The app writes `pid` as a JSON
  // number; anything else was written by something we do not recognise, and
  // coercing it is guessing. m23a2's original said `Number(j.pid) === pid`,
  // which means a lock holding the STRING "12345" matches staging pid 12345
  // and gets deleted — the gate's leg D caught exactly that when this function
  // inherited the coercion. Being strict costs at most a leftover lock in a
  // case that should never occur; being loose deletes a file we cannot prove
  // is ours, in the user's real profile.
  if (typeof owner !== "number" || !Number.isInteger(owner) || owner !== pid) {
    console.log(`session.lock belongs to pid ${JSON.stringify(owner)} — left alone`);
    return false;
  }
  try {
    rmSync(lock, { force: true });
    console.log(`removed our stale session.lock (pid ${pid})`);
    return true;
  } catch {
    return false; // e.g. permissions — better to leave it than to pretend
  }
}

/**
 * SIGTERM the exact pid recorded in the pidfile, then release that pid's
 * `session.lock`. Safe to call twice.
 *
 * ORDER MATTERS: the pid is read BEFORE the pidfile is removed, because the
 * ownership check needs it — that ordering is why the lock cleanup lives here
 * rather than in each caller, where the pid is no longer available afterwards.
 *
 * The early return on a missing pidfile is deliberate and is part of the safety
 * property: with no pidfile there is no pid to compare against, so there is no
 * lock we can prove is ours.
 *
 * SYNCHRONOUS on purpose. m23a2's hand-rolled version slept 1200 ms after the
 * kill before checking, but making this async would change the signature for
 * every caller. Both orderings are safe: if SIGTERM triggers the app's clean
 * exit, the app removes the lock itself and the read below finds nothing; if it
 * does not, the lock is still there and we remove it. (Verified empirically at
 * m23-ac-2c — m23a2 still reports 31/31 with the sleep gone.)
 */
export function stopStaging(gate, pidfileOverride, { lockPath } = {}) {
  if (!gate) throw new Error("stopStaging requires the gate name");
  const pidfile = pidfilePath(gate, pidfileOverride);
  if (!existsSync(pidfile)) { live.delete(gate); return; }
  const pid = Number(readFileSync(pidfile, "utf8").trim());
  if (Number.isInteger(pid) && pid > 0) {
    try { process.kill(pid, "SIGTERM"); } catch { /* already gone */ }
    releaseSessionLock(pid, lockPath);
  }
  rmSync(pidfile, { force: true });
  live.delete(gate);
}

/** Connect to the staging control port, retrying while the app boots. */
export async function connect({ port = STAGING_PORT, attempts = 40, intervalMs = 1000 } = {}) {
  assertStagingPort(port);
  for (let i = 0; i < attempts; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(`ws://127.0.0.1:${port}`);
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(intervalMs); }
  }
  throw new Error(`could not connect to staging on ${port}`);
}

/**
 * The one call most gates want: build, launch, connect.
 * Returns { ws, stop, out }. `stop` is idempotent.
 */
export async function launchStaging({
  gate,
  root = ROOT,
  port = STAGING_PORT,
  binary = DEFAULT_BINARY,
  env = {},
  skipBuild = false,
  attempts = 40,
  detached = false,
  pidfile,
  outDir,
  logPath,
  settleMs = 0,
} = {}) {
  buildOrAbort({ root, skip: skipBuild });
  const info = startStaging({ gate, root, port, binary, env, detached, pidfile, outDir, logPath });
  if (settleMs) await sleep(settleMs);
  const ws = await connect({ port, attempts });
  return { ws, out: info.out, pid: info.pid, stop: () => stopStaging(gate, pidfile) };
}
