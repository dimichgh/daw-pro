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
// ⚠️ EVERY LAUNCH IS PROFILE-ISOLATED (m23-ay). `startStaging` sets
//    `DAWPRO_PROFILE_ROOT` so the child's Application-Support profile — autosave,
//    recordings, generations, references, feedback, sound banks — lands in a
//    per-run temp root instead of the USER'S OWN
//    `~/Library/Application Support/DAWPro/`. Also enforced here rather than in
//    each caller: a gate author cannot forget what they never have to write.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, openSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const ROOT = "/Users/dsemenov/Views/daw-pro";
export const STAGING_PORT = 17695;
export const LIVE_PORT = 17600; // the user's app — never a target
export const DEFAULT_BINARY = ".build/debug/DAWApp";

/**
 * The variable `DAWCore.AppDirectories` reads to relocate a process's whole
 * Application-Support profile (m23-ay).
 *
 * ⚠️ SECOND SPELLING OF A NAME SWIFT OWNS —
 * `AppDirectories.profileRootEnvironmentKey`. Pinned on the Swift side by
 * `AppDirectoriesProfileRootTests.environmentKeyIsPinned` precisely because a
 * rename there and not here would silently un-isolate every gate in this
 * directory while all the code still looked correct.
 */
export const PROFILE_ROOT_ENV = "DAWPRO_PROFILE_ROOT";

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
const profileRoots = new Map(); // gate -> the profile root we launched it with

/**
 * `<base>/DAWPro/<Category>` — the JS mirror of `AppDirectories`' path math.
 *
 * ⚠️ SECOND SPELLING OF A PATH `DAWCore.AppDirectories` OWNS, the same hazard
 * `sessionLockPath` already carries and the same reason it is spelled ONCE here:
 * the Swift side appends `DAWPro/<Category>` to a base, and the override
 * (m23-ay) replaces only the BASE. Category names are pinned on the Swift side
 * by `AppDirectoriesTests.categoryNamesArePinned`.
 */
export function profileCategoryDir(base, category) {
  if (typeof base !== "string" || base.length === 0) {
    throw new Error(`profileCategoryDir(base, category) requires a non-empty base; got ${typeof base}: ${JSON.stringify(base)}`);
  }
  if (typeof category !== "string" || category.length === 0) {
    throw new Error(`profileCategoryDir(base, category) requires a non-empty category; got ${typeof category}: ${JSON.stringify(category)}`);
  }
  return `${base}/DAWPro/${category}`;
}

/** The base the app resolves with NO override — the user's real profile base. */
export const REAL_PROFILE_BASE = `${process.env.HOME}/Library/Application Support`;

let processProfileRoot = null;

/**
 * The profile root every staging launch in THIS node process shares (m23-ay).
 *
 * ONE root per gate process, not one per launch, and not one per gate file:
 *   • per-LAUNCH would break any gate that restarts staging and expects the
 *     first instance's autosave/recovery state to still be there — crash
 *     recovery is exactly that shape;
 *   • per-GATE-FILE (a fixed path derived from the gate name) would carry state
 *     between separate runs of the same gate, so a leftover `session.lock` from
 *     yesterday's run would make today's app believe it crashed.
 * A fresh mkdtemp per process gives restart continuity WITHIN a run and no
 * inheritance ACROSS runs.
 *
 * Deliberately NOT deleted at exit: the gate that launched the app has to be
 * able to inspect what it wrote after teardown (that is m23-ay's positive
 * control), and these roots are small and live under the OS-purged temp dir.
 *
 * An operator who exports `DAWPRO_PROFILE_ROOT` themselves keeps it — that is a
 * deliberate ask, and it is still isolated from the user's real profile (the
 * Swift side refuses a value equal to the real base).
 */
export function stagingProfileRoot() {
  if (processProfileRoot) return processProfileRoot;
  const inherited = process.env[PROFILE_ROOT_ENV];
  processProfileRoot = (typeof inherited === "string" && inherited.length > 0)
    ? inherited
    : mkdtempSync(join(tmpdir(), "dawpro-staging-profile-"));
  return processProfileRoot;
}

/** Where a gate's pidfile lives. One resolver, so start and stop cannot disagree. */
export function pidfilePath(gate, override) {
  // m23-ah-3: `override` survived m23-ah-1 unvalidated — an object, number,
  // or array here used to fall straight into the `return override || ...`
  // below, then get handed to `existsSync` by every caller, which coerces it
  // to `false` and takes the SAME silent early-return path m23-ah-1 exists to
  // eliminate, just one argument over. `undefined` and `null` both stay legal
  // and both take the derived-path branch below, because they are ABSENCE
  // markers — "no path was named" — matching pre-existing behaviour
  // (`return override || derived`) and the callers that rely on
  // `stopStaging(GATE)` / `pidfilePath(GATE)` with no second argument, who
  // outnumber every other shape in this corpus. `""` is different in kind,
  // not degree: it is an AFFIRMATIVE attempt to name a path that cannot be
  // one, so it throws rather than silently falling through to derived (no
  // live caller passes it — every `PIDFILE` in this corpus is
  // `process.env.X || "/tmp/..."`, a template literal, or `pidfilePath(GATE)`,
  // none of which can produce `""`). The rule is "if present, a non-empty
  // string" — not "must be present".
  if (override !== undefined && override !== null &&
      (typeof override !== "string" || override.length === 0)) {
    throw new Error(
      `pidfilePath(gate, override) requires override to be a non-empty string ` +
      `when given (omit it, or pass null/undefined, to derive the path from ` +
      `gate); got ${typeof override}: ${JSON.stringify(override)}`
    );
  }
  // m23-ah-1: this is the function that silently produced
  // `/tmp/daw-gate-out/[object Object]/staging.pid` when `gate` was actually
  // an options object. `stopStaging` now rejects that before calling here, but
  // this function is itself exported and called directly by a couple of
  // gates — guard it too. Only checked when there is no explicit override,
  // since an override makes `gate` unused and every existing caller that
  // supplies one already passes a real gate string regardless.
  if (!override && (typeof gate !== "string" || gate.length === 0)) {
    throw new Error(
      `pidfilePath(gate, override) requires gate to be a non-empty string ` +
      `when no override is given; got ${typeof gate}: ${JSON.stringify(gate)}`
    );
  }
  return override || `/tmp/daw-gate-out/${gate}/staging.pid`;
}

/**
 * Teardown that fires on EVERY way this process can end (m23-bd).
 *
 * WHY. Twelve gates arm a watchdog shaped
 * `setTimeout(() => { console.error("TIMEOUT"); process.exit(2) }, 600_000)`
 * and none of them tear down first. That is the one exit path that fires
 * precisely when the gate has HUNG — i.e. when a staging app is most likely to
 * be in a bad state — and it was the path that leaked it. MEASURED, not
 * reasoned: a probe using this very function with a fake binary exited via a
 * watchdog and left both the child and its pidfile alive.
 *
 * Fixing it HERE rather than in the twelve call sites is the point. A gate
 * author cannot forget what they never have to write, and the next gate gets it
 * for free. `stopStaging` is idempotent (a missing pidfile is an early return),
 * so a gate that already tears down explicitly is unaffected.
 *
 * ⚠️ TWO HOOKS, AND NEITHER IS REDUNDANT — do not delete one as duplication.
 *   • `exit`   covers `process.exit()` (the watchdogs, the guards) and falling
 *              off the end. It does NOT fire on a signal.
 *   • signals  cover Ctrl-C and `kill`. Their ONLY job is to convert the signal
 *              into an exit so the `exit` hook above can run: installing any
 *              listener replaces Node's default "die immediately", which runs
 *              no hooks at all. This matters most for `detached: true` children,
 *              which leave our process group and so never receive the Ctrl-C
 *              that would otherwise have killed them alongside us.
 *
 * Synchronous by necessity — an `exit` handler gets no event loop. That is
 * already `stopStaging`'s contract: it SIGTERMs and then does its own
 * ownership-checked `releaseSessionLock` without waiting for the app (see its
 * docstring, verified at m23-ac-2c), so nothing here needs to await anything.
 */
const armed = new Map(); // gate -> pidfileOverride, for gates started in this process
let signalsHooked = false;

function armTeardown(gate, pidfileOverride) {
  if (!armed.has(gate)) {
    armed.set(gate, pidfileOverride);
    process.on("exit", () => {
      try { stopStaging(gate, pidfileOverride); } catch { /* exiting anyway */ }
    });
  }
  if (signalsHooked) return;
  signalsHooked = true;
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => process.exit(sig === "SIGINT" ? 130 : 143));
  }
}

/**
 * Launch a staging instance. Returns { pid, out, pidfile }.
 *
 * `detached: true` matches the shape m23v/m23x use — the child outlives this
 * process and its output goes to a real file rather than in-memory pipes.
 *
 * ⚠️ An ATTACHED child is NOT automatically cleaned up either. This comment
 * used to claim "an attached child dies with a crashing gate"; that is false for
 * the path that actually mattered, and believing it is plausibly why the
 * watchdog leak above went unnoticed for so long. `detached: false` only keeps
 * the child in our process GROUP, so it dies when a signal is delivered to the
 * group (Ctrl-C in a terminal) — a plain `process.exit()` sends no signal and
 * the child survives it. MEASURED at m23-bd with the attached default.
 * Teardown comes from `armTeardown`, not from the spawn mode.
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
  profileRoot,
} = {}) {
  if (!gate) throw new Error("startStaging requires a { gate } name for its pidfile/out dir");
  assertStagingPort(port);
  // m23-ay: same "present-but-invalid throws, absent is legal" split as every
  // other optional argument in this file. A non-string here would be spread into
  // `env` and reach the child as the STRING "[object Object]" or "42", which the
  // Swift side would refuse — a launch failure two layers away from its cause.
  if (profileRoot !== undefined && profileRoot !== null &&
      (typeof profileRoot !== "string" || profileRoot.length === 0)) {
    throw new Error(
      `startStaging({ profileRoot }) requires a non-empty absolute path when given ` +
      `(omit it to use this process's shared staging profile root); ` +
      `got ${typeof profileRoot}: ${JSON.stringify(profileRoot)}`
    );
  }
  if (typeof profileRoot === "string" && !profileRoot.startsWith("/")) {
    throw new Error(
      `startStaging({ profileRoot }) requires an ABSOLUTE path; got ${JSON.stringify(profileRoot)}`
    );
  }

  const out = outDir || `/tmp/daw-gate-out/${gate}`;
  const pidfile = pidfilePath(gate, pidfileOverride);
  mkdirSync(out, { recursive: true });

  // A pidfile left by a crashed earlier run would otherwise be orphaned.
  // ⚠️ BEFORE `profileRoots` learns this run's root, on purpose: that orphan
  // belongs to a PREVIOUS process with a different (or, if it predates m23-ay,
  // no) profile root, so its lock must still be looked for where `stopStaging`
  // has always looked for it.
  stopStaging(gate, pidfileOverride);

  const profile = profileRoot || stagingProfileRoot();
  profileRoots.set(gate, profile);
  // ⚠️ ORDER: the caller's `env` is spread LAST, so a gate that names
  // DAWPRO_PROFILE_ROOT itself still wins. There is deliberately no way to UNSET
  // it from here — an opt-out would be a per-gate switch that puts writes back
  // in the user's real profile, which is the defect m23-ay exists to remove.
  const childEnv = {
    ...process.env,
    DAW_CONTROL_PORT: String(port),
    [PROFILE_ROOT_ENV]: profile,
    ...env,
  };

  let child, log;
  if (detached) {
    const fd = openSync(logPath || `${out}/staging.log`, "a");
    child = spawn(binary, [], {
      cwd: root,
      env: childEnv,
      stdio: ["ignore", fd, fd],
      detached: true,
    });
    child.unref();
  } else {
    child = spawn(binary, [], {
      cwd: root,
      env: childEnv,
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
  // Registered AFTER the log-flush hook above, so `exit` runs them in that
  // order: write the log we captured, then kill the app that produced it.
  armTeardown(gate, pidfileOverride);
  return { pid: child.pid, out, pidfile, profileRoot: profile };
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
  // m23-ah-4: same rule as `pidfilePath` (m23-ah-1) and `stopStaging`'s
  // `pidfileOverride` (m23-ah-3) — this used to be `return override || ...`,
  // so any TRUTHY non-path (an object, a number, an array) was returned AS
  // the path and only blew up two calls later, inside `releaseSessionLock`'s
  // `readFileSync`, as a bare TypeError swallowed by that function's own
  // catch (see its comment) — silently leaving a stale `session.lock` in
  // place instead of raising anything. `undefined` and `null` are ABSENCE
  // markers and stay legal, deriving the default Autosave path below; `""` is
  // an affirmative attempt to name a path that cannot be one and still
  // throws — the same "present-but-invalid throws, absent is legal" split as
  // the other two resolvers in this file.
  if (override !== undefined && override !== null &&
      (typeof override !== "string" || override.length === 0)) {
    throw new Error(
      `sessionLockPath(override) requires override to be a non-empty string ` +
      `when given (omit it, or pass null/undefined, to derive the default ` +
      `Autosave lock path); got ${typeof override}: ${JSON.stringify(override)}`
    );
  }
  // ⚠️ THE DEFAULT IS STILL THE USER'S REAL LOCK, deliberately. This function
  // answers "where does an app with NO profile override write its lock", which
  // is what `m23ac2c` leg F pins and what the orphan-cleanup path in
  // `startStaging` needs. A staging instance launched since m23-ay writes its
  // lock under its own profile root instead — `stagingSessionLockPath` below,
  // which `stopStaging` now uses for the gates it started.
  return override || `${profileCategoryDir(REAL_PROFILE_BASE, "Autosave")}/session.lock`;
}

/** Where a staging instance launched with `profileRoot` writes its lock. */
export function stagingSessionLockPath(profileRoot) {
  return `${profileCategoryDir(profileRoot, "Autosave")}/session.lock`;
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
  // m23-ah-4: split into two try/catches on purpose — they guard DIFFERENT
  // failure classes and must not be collapsed back into one bare catch.
  //
  // The read: a TypeError here means `lock` was not a value `readFileSync`
  // could use as a path AT ALL — either the wrong JS type (the historical
  // bug: `sessionLockPath`/`stopStaging` used to hand this function an
  // object/number/array unvalidated) or, MEASURED to still be reachable even
  // after those guards, a non-empty STRING containing a null byte (Node's fs
  // layer rejects that with its own TypeError — `ah-1`/`ah-3`/`ah-4`'s
  // `typeof x !== "string" || x.length === 0` checks accept it, since it IS
  // a non-empty string). Either way that is a caller/programmer bug, not a
  // fact about the lock file, so it is deliberately LOUD: it propagates
  // rather than being reported identically to a lock that simply is not
  // there — which is exactly how this defect hid (m23-ah-4's filed bug).
  // Every OTHER failure here (ENOENT: absent, EACCES/EISDIR: unreadable,
  // ...) is an ordinary fs `Error` with a `.code`, never a `TypeError`, and
  // keeps returning null exactly as before.
  let raw;
  try {
    raw = readFileSync(lock, "utf8");
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return null; // absent / unreadable — never guess at ownership
  }
  // The parse: kept as a BARE catch, unlike the read above, because both of
  // its failure modes are facts about the LOCK FILE's CONTENT, not about our
  // own arguments, and m23-ah-4 must not turn either into a throw — that
  // would weaken the exact guarantee this function exists for. This covers
  // JSON syntax errors AND structurally-wrong-but-valid JSON: a lock file
  // holding the literal `null` parses fine but throws its own TypeError on
  // `.pid` access below (`Cannot read properties of null`) — that TypeError
  // must NOT propagate, so it is caught here rather than folded into the
  // stricter check above.
  let owner;
  try {
    owner = JSON.parse(raw).pid;
  } catch {
    return null; // malformed — never guess at ownership
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
  // ⚠️ m23-ah-1: `startStaging({...})` takes an OPTIONS OBJECT but this is
  // POSITIONAL — `stopStaging({pidfile, proc})` passes an object as `gate`,
  // which is truthy, so a bare `if (!gate)` guard never fires. `pidfilePath`
  // then silently builds `.../[object Object]/staging.pid`, which never
  // exists, and this function early-returns as if teardown succeeded: no
  // SIGTERM, no lock release, no pidfile removal. Reject anything but a
  // non-empty string so the next copy-paste fails LOUDLY at the call site
  // instead of disarming itself.
  if (typeof gate !== "string" || gate.length === 0) {
    throw new Error(
      `stopStaging(gate, pidfileOverride, { lockPath }) requires gate to be a ` +
      `non-empty string (positional signature — this is NOT startStaging's ` +
      `{ gate, ... } options object); got ${typeof gate}: ${JSON.stringify(gate)}`
    );
  }
  // m23-ah-3: same defect, one argument over. `pidfileOverride` used to reach
  // `pidfilePath`'s override branch unchecked and get handed straight to
  // `existsSync`, which coerces a non-path to `false` and silently takes the
  // early-return two lines below — no SIGTERM, no `releaseSessionLock`, no
  // pidfile removal — exactly the outcome m23-ah-1 fixed for argument one.
  // `undefined` (the common omitted case) and `null` are both absence
  // markers and remain legal, deriving the pidfile path from `gate`, same as
  // `pidfilePath` itself tolerates; `""` is an affirmative non-path and still
  // throws (see `pidfilePath`'s comment for why those are different in
  // kind). This check is REDUNDANT with the one in `pidfilePath` below —
  // every call here already reaches it via `pidfilePath(gate, pidfileOverride)`
  // two lines down — kept explicit anyway, in lockstep with `pidfilePath`, so
  // the error names `stopStaging`'s own signature rather than a callee's.
  if (pidfileOverride !== undefined && pidfileOverride !== null &&
      (typeof pidfileOverride !== "string" || pidfileOverride.length === 0)) {
    throw new Error(
      `stopStaging(gate, pidfileOverride, { lockPath }) requires pidfileOverride ` +
      `to be a non-empty string when given (omit it, or pass null/undefined, to ` +
      `derive the pidfile path from gate); got ${typeof pidfileOverride}: ` +
      `${JSON.stringify(pidfileOverride)}`
    );
  }
  // m23-ah-4: same defect, one argument further. `lockPath` used to reach
  // `sessionLockPath` unchecked and be returned AS the path, which
  // `releaseSessionLock` then handed to `readFileSync` — a TypeError that
  // function's own bare catch swallowed (see its docstring), so the process
  // still got SIGTERM'd but `session.lock` silently SURVIVED with nothing
  // raised. That is worse than m23-ah-1/-3's no-op: it reaches the USER, as a
  // phantom crash-recovery prompt at the next real launch (m23-ac-2c).
  // `undefined` and `null` stay legal (absence markers, deriving the default
  // Autosave path); `""` still throws. REDUNDANT with `sessionLockPath`
  // below — every call here already reaches it via
  // `releaseSessionLock(pid, lockPath)` a few lines down — kept explicit
  // anyway, in lockstep with the two guards above, so the error names
  // `stopStaging`'s own signature rather than a callee's.
  if (lockPath !== undefined && lockPath !== null &&
      (typeof lockPath !== "string" || lockPath.length === 0)) {
    throw new Error(
      `stopStaging(gate, pidfileOverride, { lockPath }) requires lockPath to ` +
      `be a non-empty string when given (omit it, or pass null/undefined, to ` +
      `derive the default Autosave lock path); got ${typeof lockPath}: ` +
      `${JSON.stringify(lockPath)}`
    );
  }
  const pidfile = pidfilePath(gate, pidfileOverride);
  if (!existsSync(pidfile)) { live.delete(gate); profileRoots.delete(gate); return; }
  const pid = Number(readFileSync(pidfile, "utf8").trim());
  if (Number.isInteger(pid) && pid > 0) {
    try { process.kill(pid, "SIGTERM"); } catch { /* already gone */ }
    // m23-ay: if THIS process launched the instance, its lock is under the
    // profile root we gave it — not in the user's real Autosave directory. An
    // explicit `lockPath` still wins (m23ac2c drives that seam directly), and a
    // gate we did not start falls back to the real path exactly as before, which
    // is what the orphan cleanup in `startStaging` depends on.
    const known = profileRoots.get(gate);
    releaseSessionLock(pid, lockPath ?? (known ? stagingSessionLockPath(known) : undefined));
  }
  rmSync(pidfile, { force: true });
  live.delete(gate);
  profileRoots.delete(gate);
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
 * Returns { ws, stop, out, profileRoot }. `stop` is idempotent.
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
  profileRoot,
} = {}) {
  buildOrAbort({ root, skip: skipBuild });
  const info = startStaging({
    gate, root, port, binary, env, detached, pidfile, outDir, logPath, profileRoot,
  });
  if (settleMs) await sleep(settleMs);
  const ws = await connect({ port, attempts });
  return {
    ws, out: info.out, pid: info.pid, profileRoot: info.profileRoot,
    stop: () => stopStaging(gate, pidfile),
  };
}
