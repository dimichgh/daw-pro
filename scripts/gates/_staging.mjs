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
import {
  mkdirSync, mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, openSync,
  lstatSync, symlinkSync, readlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, isAbsolute } from "node:path";

// m23-fa-1: the ONE-home verdict primitive lives in its own tiny module (so the
// 2 pure-static gates — m23aq, m23aw — never have to import this 700+-line
// staging lifecycle just to get a pass/fail decision) and is re-exported here
// so the other 70 gates see no difference in where it comes from. See
// `_verdict.mjs`'s own header for the full contract.
export { verdict } from "./_verdict.mjs";

export const ROOT = "/Users/dsemenov/Views/daw-pro";
export const STAGING_PORT = 17695;
export const LIVE_PORT = 17600; // the user's app — never a target
export const DEFAULT_BINARY = ".build/debug/DAWApp";

/**
 * m23-gf-b — the ONE name a staging launch's CFPreferences domain is allowed
 * to be. It is the alias's filename, the resulting `ProcessInfo.processName`,
 * and therefore the domain, all the same string, on purpose (design §3.1):
 * ⚠️ NOT `DAWAppStaging` — that would be a PREFIX-EXTENSION of the real
 * domain `DAWApp`, so any glob/prefix cleanup (`rm ~/Library/Preferences/DAWApp*`)
 * would reach into the user's real domain. `DAWProStaging` is a prefix of
 * nothing real.
 */
export const STAGING_DEFAULTS_DOMAIN = "DAWProStaging";

/**
 * The staging process's name as the KERNEL and ACCESSIBILITY APIs see it.
 *
 * ⭐ THE SAME STRING AS THE DEFAULTS DOMAIN, AND NOT BY COINCIDENCE — that
 * identity IS the mechanism m23-gf relies on: a bundle-less executable's
 * preferences domain is derived from its executable path's last component, so
 * naming the alias `DAWProStaging` moves the domain to `DAWProStaging`. One
 * string, two consequences.
 *
 * ⚠️ EXPORTED SEPARATELY BECAUSE THE CONSUMERS ARE UNRELATED, AND m23-gf-c-2
 * PAID FOR THIS: `m23do-menubar` drives the app through System Events
 * (`tell process "…"`) and hardcoded `"DAWApp"`. When the alias landed, its AX
 * query started failing with `Can't get process "DAWApp" (-1728)` — a REAL
 * regression the corpus comparison caught. The m23-gf design's coverage
 * analysis had checked `processName` consumers **in `Sources/`** and concluded
 * there was only one; it never asked about consumers in the GATES. A gate
 * asking "what is the app called?" should import this, never spell it.
 */
export const STAGING_PROCESS_NAME = STAGING_DEFAULTS_DOMAIN;

/** The two REAL preferences domains this corpus must never write into. */
export const REAL_DEFAULTS_DOMAINS = ["DAWApp", "dev.dawpro.app"];

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
 * Refuse to clear/seed anything but the one legitimate staging domain,
 * whatever the caller computed (m23-gf-b). Same shape as `assertStagingPort`
 * above: log the reason, then a hard `process.exit(2)` — this guards a
 * PRECONDITION of the whole reset, not a caller bug, so it belongs in the
 * same "could not speak to its subject" exit-code family `buildOrAbort` uses,
 * not a thrown Error.
 *
 * Deliberately over-specified for a constant that is currently hard-coded to
 * one value: a future refactor that lets `resetStagingDefaultsDomain` take a
 * caller-supplied name is the exact moment this guard starts doing real work,
 * and it costs nothing today.
 */
export function assertStagingDefaultsDomain(name) {
  if (typeof name !== "string" || name.length === 0) {
    console.log(`ABORT: invalid staging defaults domain ${JSON.stringify(name)}`);
    process.exit(2);
  }
  if (REAL_DEFAULTS_DOMAINS.includes(name)) {
    console.log(`ABORT: ${name} is a REAL preferences domain (${REAL_DEFAULTS_DOMAINS.join(", ")}) and is never a staging reset/seed target`);
    process.exit(2);
  }
  if (name !== STAGING_DEFAULTS_DOMAIN) {
    console.log(`ABORT: staging defaults domain must be ${STAGING_DEFAULTS_DOMAIN}; got ${JSON.stringify(name)}`);
    process.exit(2);
  }
  if (name.includes("/")) {
    console.log(`ABORT: staging defaults domain name must not contain "/" — a domain name that is a path can write an arbitrary plist: ${JSON.stringify(name)}`);
    process.exit(2);
  }
  return name;
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

// ═══════════════════════════════════════════════════════════════════════════
// m23-gf-b — the staging defaults-isolation seam. See
// docs/research/design-m23gf-defaults-isolation.md §3 for the full spec; this
// is the implementation of §3.5's ordered mechanism.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Concurrency lock for `resetStagingDefaultsDomain` — one shared file, NOT
 * per-gate, because the hazard is TWO NODE PROCESSES clearing the SAME
 * domain underneath each other (design F2). A hand-run gate started mid
 * corpus-run must refuse rather than silently truncate the corpus run's
 * seeded state.
 */
const DEFAULTS_LOCK_PATH = "/tmp/daw-gate-out/_staging-defaults.lock";
let defaultsLockExitHookInstalled = false;

function pidIsLive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

/**
 * Pid-owner lock, self-healing on a stale (crashed-owner) file. THROWS on a
 * LIVE foreign owner — deliberately a real JS throw, not `process.exit(2)`:
 * this is the one guard the design brief calls out by name as "throws", and
 * a thrown Error is what makes the acceptance-test shape ("call it, catch it")
 * possible without spawning a subprocess just to observe an exit code.
 */
function acquireDefaultsDomainLock() {
  mkdirSync(dirname(DEFAULTS_LOCK_PATH), { recursive: true });
  if (existsSync(DEFAULTS_LOCK_PATH)) {
    const raw = readFileSync(DEFAULTS_LOCK_PATH, "utf8").trim();
    const owner = Number(raw);
    if (Number.isInteger(owner) && owner > 0 && owner !== process.pid && pidIsLive(owner)) {
      throw new Error(
        `acquireDefaultsDomainLock: ${DEFAULTS_LOCK_PATH} is held by LIVE pid ${owner} — ` +
        `refusing to clear/reseed the staging defaults domain underneath a concurrent run. ` +
        `If pid ${owner} is not actually a gate process, remove the lock file by hand.`
      );
    }
    // Absent, unreadable-as-a-pid, or the owner is dead — a stale lock. Self-heal.
  }
  writeFileSync(DEFAULTS_LOCK_PATH, String(process.pid));
  if (!defaultsLockExitHookInstalled) {
    defaultsLockExitHookInstalled = true;
    // Best-effort, same shape as `armTeardown`'s exit hook below (m23-bd):
    // only remove the lock if it still names OUR pid, so a lock that raced
    // past us is never deleted out from under its real owner.
    process.on("exit", () => {
      try {
        if (existsSync(DEFAULTS_LOCK_PATH)
            && Number(readFileSync(DEFAULTS_LOCK_PATH, "utf8").trim()) === process.pid) {
          rmSync(DEFAULTS_LOCK_PATH, { force: true });
        }
      } catch { /* exiting anyway */ }
    });
  }
}

const STAGING_DEFAULTS_SEED_PATH = join(ROOT, "scripts/gates/_staging-defaults-seed.json");

/**
 * Load + validate the checked-in seed (design §3.7). Malformed or missing is
 * an ABORT, never a silent "run virgin" — a virgin domain puts the onboarding
 * tour in front of every UI gate in the corpus (brief trap 4).
 */
function loadStagingDefaultsSeed() {
  let raw;
  try {
    raw = readFileSync(STAGING_DEFAULTS_SEED_PATH, "utf8");
  } catch (e) {
    console.log(`ABORT: could not read the staging defaults seed at ${STAGING_DEFAULTS_SEED_PATH}: ${e.message}`);
    process.exit(2);
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (e) {
    console.log(`ABORT: staging defaults seed at ${STAGING_DEFAULTS_SEED_PATH} is not valid JSON: ${e.message}`);
    process.exit(2);
  }
  const keys = doc && typeof doc === "object" ? doc.keys : null;
  if (keys === null || typeof keys !== "object" || Array.isArray(keys) || Object.keys(keys).length === 0) {
    console.log(`ABORT: staging defaults seed at ${STAGING_DEFAULTS_SEED_PATH} has no non-empty "keys" object`);
    process.exit(2);
  }
  for (const [key, entry] of Object.entries(keys)) {
    if (key.startsWith("NS")) {
      console.log(`ABORT: staging defaults seed must NEVER seed an "NS*" key (must be left to regenerate) — found ${JSON.stringify(key)}`);
      process.exit(2);
    }
    if (!entry || typeof entry !== "object"
        || (entry.type !== "string" && entry.type !== "float")
        || !Object.prototype.hasOwnProperty.call(entry, "value")) {
      console.log(`ABORT: staging defaults seed entry ${JSON.stringify(key)} is malformed (need {type: "string"|"float", value}): ${JSON.stringify(entry)}`);
      process.exit(2);
    }
  }
  return keys;
}

let defaultsDomainReset = false; // memoised ONCE PER NODE PROCESS (design §3.5)

/**
 * Clear the staging defaults domain, then seed it from the checked-in
 * fixture, then READ BACK every seeded key — a setter's return is not proof
 * it took. Memoised so a run that calls `startStaging` more than once (a
 * relaunch, several gates in one process) does not re-clear state a leg is
 * mid-way through relying on.
 *
 * ORDER (design §3.5, load-bearing): the caller (`startStaging`) MUST call
 * `stopStaging` before this — a surviving app from a previous run holds the
 * domain open in `cfprefsd`, and clearing underneath it is a race. This
 * function does not call `stopStaging` itself; it trusts its caller, the same
 * way `assertStagingPort` trusts callers to have already resolved `port`.
 */
export function resetStagingDefaultsDomain() {
  if (defaultsDomainReset) return STAGING_DEFAULTS_DOMAIN;
  const domain = assertStagingDefaultsDomain(STAGING_DEFAULTS_DOMAIN);
  acquireDefaultsDomainLock();

  const seed = loadStagingDefaultsSeed();

  // Non-zero exit when the domain is already absent is SUCCESS, not failure —
  // `defaults delete` on a domain with nothing written yet exits 1. Status is
  // deliberately unchecked here; only the read-back below is the proof.
  spawnSync("/usr/bin/defaults", ["delete", domain], { stdio: "ignore" });

  // ⛔ Seeded with `defaults write`, a real persistent write — NEVER as
  // command-line `-key value` ARGUMENTS to the app. `NSArgumentDomain`
  // outranks the persistent domain, so a gate that then WRITES the key would
  // read back the stale argument value forever (design §3.7).
  for (const [key, { type, value }] of Object.entries(seed)) {
    const flag = type === "string" ? "-string" : "-float";
    const w = spawnSync("/usr/bin/defaults", ["write", domain, key, flag, String(value)], { stdio: "ignore" });
    if (w.status !== 0) {
      console.log(`ABORT: seeding ${domain} ${key} ${flag} ${JSON.stringify(String(value))} failed (exit ${w.status})`);
      process.exit(2);
    }
  }

  const mismatches = [];
  for (const [key, { type, value }] of Object.entries(seed)) {
    const r = spawnSync("/usr/bin/defaults", ["read", domain, key], { encoding: "utf8" });
    const got = (r.stdout || "").trim();
    if (type === "string") {
      if (got !== String(value)) mismatches.push(`${key}: wrote ${JSON.stringify(value)}, read back ${JSON.stringify(got)}`);
    } else {
      const n = Number(got);
      if (!Number.isFinite(n) || Math.abs(n - Number(value)) > 1e-9) {
        mismatches.push(`${key}: wrote ${value}, read back ${JSON.stringify(got)}`);
      }
    }
  }
  if (mismatches.length) {
    console.log(`ABORT: staging defaults domain ${domain} failed read-back verification —\n  ${mismatches.join("\n  ")}`);
    process.exit(2);
  }

  console.log(`staging defaults domain ${domain}: cleared + seeded (${Object.keys(seed).length} key(s), read-back verified)`);
  defaultsDomainReset = true;
  return domain;
}

/**
 * Create/verify the `DAWProStaging` symlink beside the real binary and
 * return its absolute path. THROWS, NEVER FALLS BACK (design §3.6, brief
 * trap 1) — a fallback to the real binary would put every write back in the
 * user's domain while every log line still said "isolated". The three throw
 * conditions below are exhaustive on purpose: missing real binary, an
 * existing non-symlink at the alias path, and a symlink whose target does
 * not read back as what was just requested.
 *
 * SYMLINK ONLY (design §3.2) — never a hardlink (pins the inode; a rebuild
 * would silently run the OLD binary with no symptom) and never a copy (needs
 * hash-verified refresh per build). Re-created on every call so a `swift
 * build` in between is always picked up, even though a path-following
 * symlink does not strictly require re-creation after every build.
 */
export function stagingBinaryAlias(binary, root = ROOT) {
  if (typeof binary !== "string" || binary.length === 0) {
    throw new Error(`stagingBinaryAlias(binary, root) requires a non-empty binary path; got ${typeof binary}: ${JSON.stringify(binary)}`);
  }
  const realPath = isAbsolute(binary) ? binary : join(root, binary);
  if (!existsSync(realPath)) {
    throw new Error(
      `stagingBinaryAlias: the real binary does not exist at ${realPath} — refusing to fall back to it. ` +
      `(A silent fallback here would put every write back in the user's domain while the logs kept saying "isolated".)`
    );
  }
  const aliasPath = join(dirname(realPath), STAGING_DEFAULTS_DOMAIN);
  let prior = null;
  try { prior = lstatSync(aliasPath); } catch { /* nothing there yet — fine */ }
  if (prior && !prior.isSymbolicLink()) {
    throw new Error(
      `stagingBinaryAlias: ${aliasPath} already exists and is NOT a symlink — refusing to overwrite it ` +
      `(could be a real file/directory a human or another tool put there) and refusing to fall back to ${realPath}.`
    );
  }
  if (prior) rmSync(aliasPath, { force: true }); // re-create every call — see docstring
  symlinkSync(realPath, aliasPath);
  let target;
  try {
    target = readlinkSync(aliasPath);
  } catch (e) {
    throw new Error(`stagingBinaryAlias: readlinkSync(${aliasPath}) failed right after creating it: ${e.message}`);
  }
  if (target !== realPath) {
    throw new Error(
      `stagingBinaryAlias: readlinkSync(${aliasPath}) = ${JSON.stringify(target)}, expected ${JSON.stringify(realPath)} — ` +
      `refusing to use an alias that does not verify its own target.`
    );
  }
  return aliasPath;
}

/**
 * Out-of-band confirmation that a spawned pid's process name really is
 * `DAWProStaging` (design F1) — the killer failure mode is a silent fallback
 * that LOOKS isolated in every log line while it is not, so this checks the
 * kernel's own idea of the process name, not anything our own code claims.
 * Retries briefly: immediately after `spawn()` a non-shell child can still be
 * mid-exec, and `ps` has been observed to report the PARENT node binary's
 * name for the first tens of milliseconds.
 */
function confirmAliasIdentity(pid, expected, { attempts = 30, intervalMs = 100 } = {}) {
  for (let i = 0; i < attempts; i++) {
    const r = spawnSync("/bin/ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8" });
    const comm = (r.stdout || "").trim();
    const base = comm.split("/").pop();
    if (base === expected) return comm;
    if (!comm) {
      // No `ps` line at all — the process may not have appeared yet, or it
      // may already be gone. Only stop early for the second case.
      if (!pidIsLive(pid)) break;
    }
    spawnSync("sleep", ["0.1"]);
  }
  return null;
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
  // m23-dx-3: parsed HERE, before anything is spawned, so a typo'd
  // STAGING_WINDOW_SIZE fails without first launching an app that would then
  // have to be torn down. Absent env ⇒ null ⇒ this whole feature is inert.
  const wantWindowSize = parseStagingWindowSize();
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

  // m23-gf-b: clear + seed the ONE staging defaults domain (memoised once per
  // process — MUST follow `stopStaging` above, design §3.5: a surviving app
  // from a previous run holds the domain open in cfprefsd, and clearing
  // underneath it is a race), then alias the binary so the child's own
  // CFPreferences domain identity actually IS that domain. Order matches the
  // design exactly: reset the domain, THEN resolve the alias, THEN spawn it.
  const defaultsDomain = resetStagingDefaultsDomain();
  const alias = stagingBinaryAlias(binary, root);

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
    child = spawn(alias, [], {
      cwd: root,
      env: childEnv,
      stdio: ["ignore", fd, fd],
      detached: true,
    });
    child.unref();
  } else {
    child = spawn(alias, [], {
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
  // ⚠️ PIDFILE + TEARDOWN ARE ARMED *BEFORE* THE F1 CONFIRMATION BELOW, ON
  // PURPOSE. If confirmation fails, this function throws — and this module's
  // whole kill discipline is PIDFILE-EXACT (never pkill/pgrep). A throw that
  // happened before the pidfile existed would leave an unconfirmed child
  // process alive on the staging port with no pidfile pointing at it: exactly
  // the kind of process this module exists to make un-orphanable. Arming
  // first means the inline SIGKILL below AND every later `stopStaging` call
  // can still reach it by pid, whether or not this call ever returns.
  writeFileSync(pidfile, String(child.pid));
  live.set(gate, { child, pidfile, out, log });
  // Registered AFTER the log-flush hook above, so `exit` runs them in that
  // order: write the log we captured, then kill the app that produced it.
  armTeardown(gate, pidfileOverride);

  // F1's out-of-band confirmation: the kernel's own idea of this pid's process
  // name must read the staging domain name, not just "we spawned the alias
  // path" (a silent fallback earlier in the chain would still reach this
  // line). This is the check that actually closes the failure mode.
  const confirmedComm = confirmAliasIdentity(child.pid, STAGING_DEFAULTS_DOMAIN);
  if (confirmedComm === null) {
    try { process.kill(child.pid, "SIGKILL"); } catch { /* best effort */ }
    throw new Error(
      `startStaging: spawned pid ${child.pid} via ${alias} but /bin/ps never reported its comm as ` +
      `${STAGING_DEFAULTS_DOMAIN} — the alias may not have taken effect. Refusing to proceed with a ` +
      `launch that cannot be confirmed isolated.`
    );
  }
  // m23-dx-3: THE WINDOW PIN. Deliberately the LAST thing `startStaging` does.
  //
  //  - AFTER `resetStagingDefaultsDomain()`, so the reset cannot undo it. That
  //    ordering is the whole point: m23-dx's original method pinned in a
  //    THROWAWAY EARLIER SESSION and the reset wiped it, so every "pinned" gate
  //    silently ran at the app default 1440x900 (measured, m23-dx-2).
  //  - AFTER `armTeardown`, so a pin failure still kills the app it launched
  //    rather than orphaning it on the staging port.
  //  - AFTER `confirmAliasIdentity`, so we only ever pin a confirmed-isolated app.
  //  - Via `spawnSync` on a separate process, because `startStaging` is
  //    SYNCHRONOUS and every gate depends on that; the pin needs async socket
  //    work. Making this function async would break the whole corpus.
  //
  // Port is passed EXPLICITLY, never inherited by luck — the pinner is a
  // different process and re-asserts the staging-port rule itself.
  if (wantWindowSize) {
    const pin = spawnSync(
      process.execPath,
      [`${root}/scripts/gates/_pin-window.mjs`, String(port), String(wantWindowSize.width), String(wantWindowSize.height)],
      { stdio: "inherit" }
    );
    if (pin.status !== 0) {
      throw new Error(
        `startStaging: ${STAGING_WINDOW_SIZE_ENV}=${wantWindowSize.width}x${wantWindowSize.height} ` +
        `could not be applied (pinner exit ${pin.status}). Refusing to hand back a session whose ` +
        `window size is not the one that was asked for — a wrong size is a WRONG MEASUREMENT, ` +
        `not a cosmetic miss.`
      );
    }
  }

  return { pid: child.pid, out, pidfile, profileRoot: profile, binary: alias, defaultsDomain };
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
/**
 * m23-dx-3 — `STAGING_WINDOW_SIZE=<W>x<H>` pins the staging window size.
 *
 * WHY THIS LIVES HERE AND NOT IN A THROWAWAY SESSION: `startStaging` resets the
 * staging defaults domain on every launch (the m23-gf isolation seam), which
 * wipes the `NSWindow Frame …` autosave a previous session wrote. So a pin set
 * in session N is GONE in session N+1, and m23-dx's sweep method silently
 * compared an arm against itself — measured at m23-dx-2, where all four runs
 * across two arms ran at the app default 1440x900 while the pinning session's
 * own read-back cheerfully said 1400x1000. Applying the pin AFTER the reset,
 * inside the session that will actually run the gate, is the only placement the
 * reset cannot undo. ⛔ The other tempting fix — seeding an `NSWindow Frame …`
 * key — is forbidden by `_staging-defaults-seed.json` in terms, and for a
 * stated reason: NS* keys must regenerate or the isolation seam is defeated.
 *
 * ⚠️ RE-APPLIED ON EVERY `connect()`, DELIBERATELY. A once-per-process flag
 * would silently skip the pin for a second staging launch in the same process,
 * and a missed pin is exactly the invisible no-op this item exists to remove.
 * Re-pinning is idempotent and cheap; only TRANSITIONS are logged.
 *
 * ⚠️ THE LOG DISTINGUISHES A REAL PIN FROM A NO-OP ON PURPOSE. 1440x900 is the
 * app default, so `STAGING_WINDOW_SIZE=1440x900` sets what is already there and
 * its read-back would "succeed" while proving nothing — the precise shape that
 * blessed the broken method at m23-dx-2. `pin: 1440x900 -> 1400x1000` and
 * `pin: 1440x900 (already — no change)` must never be confused for each other.
 * This does NOT abort on equality: pinning the default is legitimate. It is the
 * SWEEP's job to require that the two arms' GATE-REPORTED frames differ.
 */
export const STAGING_WINDOW_SIZE_ENV = "STAGING_WINDOW_SIZE";

export function parseStagingWindowSize(raw = process.env[STAGING_WINDOW_SIZE_ENV]) {
  if (raw === undefined || raw === null || String(raw).trim() === "") return null;
  const m = /^\s*(\d+)\s*[xX]\s*(\d+)\s*$/.exec(String(raw));
  if (!m) {
    throw new Error(
      `${STAGING_WINDOW_SIZE_ENV}="${raw}" is not <WIDTH>x<HEIGHT> (e.g. 1400x1000). ` +
      `Refusing to continue: a malformed pin that silently did nothing is the defect ` +
      `m23-dx-3 exists to remove.`
    );
  }
  const width = Number(m[1]), height = Number(m[2]);
  if (!(width > 0 && height > 0)) {
    throw new Error(`${STAGING_WINDOW_SIZE_ENV}="${raw}" parsed to a non-positive size`);
  }
  return { width, height };
}

/**
 * ⛔ THE PIN IS APPLIED IN `startStaging`, NOT HERE — MEASURED REASON, KEEP.
 * The first implementation of m23-dx-3 pinned inside this `connect()`. It
 * worked, and it was still wrong: only **31 of the 75** non-harness gates
 * import this function. The other 44 define their own local `connect` or
 * hand-roll a raw `new WebSocket`, so they inherited NO pin — and inherited it
 * SILENTLY, which is the very invisible-no-op failure class this item exists to
 * remove. It was caught because `m23e-empty-lane-create` passed 38/38 under a
 * pin that had never been applied: the `pin:` line was simply ABSENT from the
 * log. `startStaging` is the one call every gate makes (`launchStaging`
 * delegates to it just below), so that is where the pin belongs.
 *
 * ⭐ A GREEN RUN UNDER A FEATURE THAT NEVER RAN IS NOT EVIDENCE THE FEATURE
 * WORKS. Check that the feature ANNOUNCED ITSELF, not merely that the gate
 * passed — the pass was identical in both cases.
 */
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
    binary: info.binary, defaultsDomain: info.defaultsDomain,
    stop: () => stopStaging(gate, pidfile),
  };
}

/**
 * ONE home for "seed `debug.panelDensity` for a test, then put it back" —
 * m23-ej-2. Before this, 27 gates hand-rolled the write half and only two
 * (`m19g-setnotes-ghost`, `m22g-reference-panel`) ever restored, and both of
 * those predate `debug.panelDensity {panel, clear:true}` (m23-ej-1) so their
 * restore falls back to writing the app default `"simple"` for a never-set
 * panel instead of actually clearing it — leaving an explicit key where there
 * was none. 27 independent copies of this is exactly how m23-dv-1 shipped a
 * restore that silently did nothing while the gate stayed green: one shared,
 * tested implementation beats 27 chances to get the null-prior branch wrong.
 *
 * `call` is whatever the gate already uses to send a command — `(command,
 * params) => Promise<response>`. Response shape varies across this corpus
 * (`must`/`req` already unwrap to `.result ?? whole envelope`; `cmd` returns
 * the raw `{id, ok, result, error}` envelope) — normalized below.
 *
 * ⚠️ HAND THIS THE RAW SOCKET CALL, NEVER A WRAPPER THAT CAN `process.exit()`
 * OR THROW ON A NON-OK RESPONSE (several gates' `must` does exactly that on
 * ANY failing command). If a restore write fails through such a wrapper the
 * whole process dies mid-loop and every panel after the failing one is never
 * even attempted — silently, since the panel never printed. This function's
 * own per-panel try/catch is the failure boundary; a `call` that removes that
 * boundary defeats the whole point.
 *
 * @param {(command: string, params?: object) => Promise<any>} call
 * @returns {{ set: (panel: string, mode: string) => Promise<any>,
 *             restore: (reason: string, opts?: { timeoutMs?: number }) =>
 *               Promise<{ restored: boolean, timedOut: boolean, results: Array }> }}
 */
export function panelDensityGuard(call) {
  const priors = new Map();   // panel -> stored prior (string | null), first touch only
  let restored = false;       // idempotence flag — set at ENTRY of restore(), not completion,
                               // so a handler firing while the normal path is mid-restore
                               // cannot double-fire (m19g/m22g/m23ej precedent).

  /**
   * FORM 2 read, normalized, with the A1 loud-failure contract: the four
   * request-helper shapes in this corpus disagree on envelope vs. unwrapped
   * result, so normalize with `resp?.result ?? resp` and then REQUIRE an own
   * `stored` property. `stored: null` (never-set) is legitimate and must
   * survive normalization untouched; "the field isn't there at all" (wrong
   * command, malformed envelope, a typo'd `call`) must never collapse into
   * that same null — that collapse is the exact m23-dv-1 defect. So: no
   * `stored` key anywhere on the normalized object throws, loudly, naming
   * both what was expected and what actually came back.
   */
  async function readStored(panel) {
    const raw = await call("debug.panelDensity", { panel });
    const norm = raw?.result ?? raw;
    if (norm === null || typeof norm !== "object"
        || !Object.prototype.hasOwnProperty.call(norm, "stored")) {
      throw new Error(
        `panelDensityGuard: unrecognized debug.panelDensity read envelope for ` +
        `panel ${JSON.stringify(panel)} — normalized (resp?.result ?? resp) to ` +
        `${JSON.stringify(norm)}, which has no own "stored" property. This must ` +
        `THROW rather than treat the panel as never-set: a broken read here ` +
        `silently degrades into the SAME branch as a genuine stored:null and a ` +
        `real prior value would then be lost on restore.`
      );
    }
    return norm.stored; // string | null
  }

  return {
    /** Remember the panel's CURRENT prior on first touch, then write `mode`. */
    async set(panel, mode) {
      if (!priors.has(panel)) {
        const prior = await readStored(panel);
        priors.set(panel, prior);
        console.log(`panelDensityGuard: first touch of "${panel}" — prior stored=`
          + `${prior === null ? "UNSET" : JSON.stringify(prior)}`);
      }
      return call("debug.panelDensity", { panel, mode });
    },

    /**
     * Put every touched panel back. Idempotent — safe to call from the
     * normal exit path AND every error/timeout handler; only the first call
     * does anything. Bounded (default 3 s, the `cleanupProbeKeys` shape from
     * `m23ej-panel-density-forms.mjs`): a restore that hangs must never block
     * the process from exiting, but it must also never pretend to have
     * finished — a timeout is reported LOUDLY, by panel, with the exact hand
     * fix, never folded into a quiet success.
     */
    async restore(reason, { timeoutMs = 3000 } = {}) {
      if (restored) return { restored: false, timedOut: false, results: [] };
      restored = true;
      const entries = [...priors.entries()];
      if (entries.length === 0) {
        console.log(`panelDensityGuard: restore(${reason}) — no panels touched, nothing to do`);
        return { restored: true, timedOut: false, results: [] };
      }
      const work = (async () => {
        const results = [];
        for (const [panel, prior] of entries) {
          try {
            if (prior !== null) {
              await call("debug.panelDensity", { panel, mode: prior });
              console.log(`panelDensityGuard: restored (${reason}) "${panel}" -> mode=${prior}`);
            } else {
              await call("debug.panelDensity", { panel, clear: true });
              console.log(`panelDensityGuard: restored (${reason}) "${panel}" -> cleared `
                + `(was never set — writing the default would leave a false explicit key)`);
            }
            results.push({ panel, ok: true });
          } catch (e) {
            // LOUD, never silent, never swallowed into a green run.
            console.error(`panelDensityGuard: RESTORE FAILED (${reason}) for panel `
              + `"${panel}" (prior was ${prior === null ? "UNSET" : JSON.stringify(prior)}): `
              + `${e && e.message}`);
            results.push({ panel, ok: false, error: e && e.message });
          }
        }
        return results;
      })();
      const TIMED_OUT = Symbol("panelDensityGuard-restore-timeout");
      const outcome = await Promise.race([work, sleep(timeoutMs).then(() => TIMED_OUT)]);
      if (outcome === TIMED_OUT) {
        const hints = entries.map(([panel, prior]) => prior === null
          // m23-gf-b: this domain moved off the user's real DAWApp — a
          // staging launch now writes into DAWProStaging (STAGING_DEFAULTS_DOMAIN).
          ? `defaults delete ${STAGING_DEFAULTS_DOMAIN} panelDensity.${panel}`
          : `debug.panelDensity {panel:${JSON.stringify(panel)}, mode:${JSON.stringify(prior)}}`);
        console.error(`panelDensityGuard: RESTORE TIMED OUT after ${timeoutMs}ms (${reason}) `
          + `— state of [${entries.map(([p]) => p).join(", ")}] is UNKNOWN (the write may still `
          + `land after this process exits). Hand fix per panel: ${hints.join("  ;  ")}`);
        return { restored: true, timedOut: true, results: [] };
      }
      return { restored: true, timedOut: false, results: outcome };
    },
  };
}

/**
 * ONE home for "snapshot the WHOLE panelDensity domain, then put back
 * anything a caller wrote through it — directly OR as an unadvertised side
 * effect of a completely different verb" — m23-en.
 *
 * `panelDensityGuard` above only remembers panels a gate explicitly
 * `guard.set()`s. m23-en's own reproducer: `debug.effectEditor` (and
 * `debug.effectPicker`, and part of `debug.quantizePanel`) write
 * `panelDensity.mixer = pro` as a side effect nobody's `guard.set()` ever
 * named — so a per-panel guard scoped to `"effectEditor"` never touches
 * `"mixer"`, and the leak survives a green run untouched. This guard trades
 * per-panel opt-in for a domain-wide before/after diff: whatever is
 * EXPLICITLY stored when `snapshot()` runs is the truth `restore()`
 * reconciles every panel back to, no matter which verb wrote it meanwhile.
 *
 * Deliberately a SEPARATE guard, not a rewrite of `panelDensityGuard`: a gate
 * that only ever touches panels through `guard.set()` (most of this corpus)
 * has no leak class to defend against and no reason to pay for a whole-domain
 * read on every restore.
 *
 * @param {(command: string, params?: object) => Promise<any>} call — same
 *   contract as `panelDensityGuard`: hand this the raw socket call, never a
 *   wrapper that can `process.exit()` or throw on a non-ok response — this
 *   function's own per-panel try/catch inside `restore` is the failure
 *   boundary a throwing `call` would defeat.
 * @returns {{ snapshot: () => Promise<{panels: object}>,
 *             restore: (reason: string, opts?: { timeoutMs?: number }) =>
 *               Promise<{ restored: boolean, timedOut: boolean, results: Array }> }}
 */
export function panelDensityDomainGuard(call) {
  let priorPanels = null;     // Map<panel, mode> from snapshot(); null until taken
  let restored = false;       // idempotence flag — set at ENTRY of restore(), not
                               // completion, same reasoning as panelDensityGuard above.

  /**
   * FORM 3 (bare) read, normalized, with the A1 loud-failure contract THIS
   * class needs MORE than the per-panel guard does: a malformed read that
   * degrades into "no panels stored" would make restore() CLEAR EVERY
   * EXPLICITLY-STORED PANEL — the per-panel guard's m23-dv-1 defect loses ONE
   * prior; this collapse would wipe the user's WHOLE density domain. So: no
   * own "panels" property anywhere on the normalized object throws, loudly,
   * naming both what was expected and what actually came back. A missing key
   * must never collapse into the same branch as a legitimately empty `{}`.
   */
  async function readDomain() {
    const raw = await call("debug.panelDensity", {});
    const norm = raw?.result ?? raw;
    if (norm === null || typeof norm !== "object"
        || !Object.prototype.hasOwnProperty.call(norm, "panels")) {
      throw new Error(
        `panelDensityDomainGuard: unrecognized debug.panelDensity bare-read envelope — `
        + `normalized (resp?.result ?? resp) to ${JSON.stringify(norm)}, which has no own `
        + `"panels" property. This must THROW rather than treat the domain as empty: a `
        + `broken read here would make restore() CLEAR EVERY EXPLICITLY-STORED PANEL.`
      );
    }
    const { panels } = norm;
    if (panels === null || typeof panels !== "object" || Array.isArray(panels)) {
      throw new Error(
        `panelDensityDomainGuard: debug.panelDensity "panels" is not a plain object — got `
        + `${JSON.stringify(panels)}. Refusing to treat this as an empty domain.`
      );
    }
    return panels;
  }

  return {
    /**
     * Snapshot every EXPLICITLY stored panel right now. Call this before
     * anything that might write panelDensity — directly or as a side effect
     * — so the snapshot is the true pre-gate state and not a state already
     * contaminated by the gate's own first writes.
     */
    async snapshot() {
      const panels = await readDomain();
      priorPanels = new Map(Object.entries(panels));
      console.log(`panelDensityDomainGuard: snapshot — ${priorPanels.size} panel(s) `
        + `explicitly stored: ${priorPanels.size
          ? [...priorPanels.entries()].map(([p, m]) => `${p}=${m}`).join(", ")
          : "(none)"}`);
      return { panels };
    },

    /**
     * Re-read the domain NOW and reconcile every panel back to the
     * snapshot: a panel the snapshot had gets its stored mode written back;
     * a panel present now but ABSENT from the snapshot — the leak case —
     * gets CLEARED, never defaulted to a written value (the m23-du law:
     * converting "never set" into an explicit value silently changes what a
     * fresh machine looks like). Idempotent and bounded, same shape as
     * `panelDensityGuard.restore` above: idempotence flag set at entry, a
     * `Promise.race` timeout with a `TIMED_OUT` symbol.
     *
     * ⚠️ ONE DELIBERATE DEPARTURE from that shape's timeout hints: the
     * per-panel guard knows its full touched-panel list synchronously before
     * the race begins (built by `set()` calls that already happened), so its
     * timeout hints can name every panel with certainty. This guard cannot —
     * the leaked-panel half of the plan only exists after the "read NOW"
     * call resolves, and that read is itself inside the raced work (it must
     * be: a hang on that very read is exactly the case the timeout exists to
     * catch). So on timeout this only prints hints for the SNAPSHOTTED
     * panels, plus an explicit instruction to re-read and hand-check for
     * anything else.
     */
    async restore(reason, { timeoutMs = 3000 } = {}) {
      if (restored) return { restored: false, timedOut: false, results: [] };
      restored = true;
      if (priorPanels === null) {
        console.log(`panelDensityDomainGuard: restore(${reason}) — snapshot() was never `
          + `called, nothing to reconcile`);
        return { restored: true, timedOut: false, results: [] };
      }
      const snapshotAtRestore = priorPanels; // stable local binding for the hints below
      const work = (async () => {
        const results = [];
        const nowPanels = await readDomain();
        const leaked = Object.keys(nowPanels).filter((p) => !snapshotAtRestore.has(p));
        const plan = [
          ...[...snapshotAtRestore.entries()].map(([panel, mode]) => ({ panel, mode })),
          ...leaked.map((panel) => ({ panel, mode: null })),   // null => clear (the leak case)
        ];
        for (const { panel, mode } of plan) {
          try {
            if (mode !== null) {
              await call("debug.panelDensity", { panel, mode });
              console.log(`panelDensityDomainGuard: restored (${reason}) "${panel}" -> `
                + `mode=${mode}`);
            } else {
              await call("debug.panelDensity", { panel, clear: true });
              console.log(`panelDensityDomainGuard: restored (${reason}) "${panel}" -> `
                + `cleared (present now but absent from the snapshot — a leaked write)`);
            }
            results.push({ panel, ok: true });
          } catch (e) {
            // LOUD, never silent, never swallowed into a green run.
            console.error(`panelDensityDomainGuard: RESTORE FAILED (${reason}) for panel `
              + `"${panel}" (target was ${mode === null ? "CLEAR" : JSON.stringify(mode)}): `
              + `${e && e.message}`);
            results.push({ panel, ok: false, error: e && e.message });
          }
        }
        return results;
      })();
      const TIMED_OUT = Symbol("panelDensityDomainGuard-restore-timeout");
      const outcome = await Promise.race([work, sleep(timeoutMs).then(() => TIMED_OUT)]);
      if (outcome === TIMED_OUT) {
        const hints = [...snapshotAtRestore.entries()].map(([panel, mode]) =>
          `debug.panelDensity {panel:${JSON.stringify(panel)}, mode:${JSON.stringify(mode)}}`);
        console.error(`panelDensityDomainGuard: RESTORE TIMED OUT after ${timeoutMs}ms `
          + `(${reason}) — state of the WHOLE panelDensity domain is UNKNOWN (the write `
          + `may still land after this process exits, and any panel written by a LEAK `
          + `after the snapshot was taken may still be sitting there — this guard cannot `
          + `enumerate that half without a read that itself may be what hung). Hand fix for `
          + `the SNAPSHOTTED panels: ${hints.length ? hints.join("  ;  ") : "(none were stored)"}`
          + `. For any OTHER panel: re-read with a bare debug.panelDensity {} and clear `
          // m23-gf-b: this domain moved off the user's real DAWApp — a staging
          // launch now writes into DAWProStaging (STAGING_DEFAULTS_DOMAIN).
          + `(defaults delete ${STAGING_DEFAULTS_DOMAIN} panelDensity.<panel>) anything NOT in this snapshot: `
          + `${JSON.stringify(Object.fromEntries(snapshotAtRestore))}`);
        return { restored: true, timedOut: true, results: [] };
      }
      return { restored: true, timedOut: false, results: outcome };
    },
  };
}
