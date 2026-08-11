// m23gf-defaults-isolation GATE — the verification for the staging
// preferences isolation that landed at m23-gf-b.
//
// ── THE DEFECT THIS PINS ─────────────────────────────────────────────────────
// Before m23-gf-b, every staging instance a gate launched shared
// `UserDefaults.standard` with whichever process the executable's PATH named,
// which for the bare binary was always `DAWApp` — the user's own real
// preferences domain (`~/Library/Preferences/DAWApp.plist`). A gate run could
// therefore MOVE THE USER'S OWN APP WINDOW: `debug.windowFrame` pins in ~10
// gate files write an `NSWindow Frame …AppWindow-1` key that AppKit itself
// autosaves, and the user watched their own window jump mid-session. The fix
// (`docs/research/design-m23gf-defaults-isolation.md`) launches staging
// through a symlink named `DAWProStaging` beside the real binary, so the
// process's own CFPreferences domain identity becomes `DAWProStaging` instead
// of `DAWApp` — zero Swift call sites changed. This gate is that fix's
// acceptance criterion, on the `m23ay-profile-isolation` control shape.
//
// ── ⚠️⚠️ THIS GATE IS BYTE-READ-ONLY ON THE USER'S TWO REAL DOMAINS ─────────
// It never writes, moves, or deletes `~/Library/Preferences/DAWApp.plist` or
// `~/Library/Preferences/dev.dawpro.app.plist`. It reads their raw bytes
// (`readFileSync`) to hash them and `statSync` for mtime — never `defaults
// write`/`delete` against either name. The ONLY domains this gate ever writes
// are `DAWProStaging` (via the shipped harness, exactly as every other gate
// does) and a SECOND, gate-owned decoy `DAWProStagingDecoy` (§NEG below).
//
// ── ⚠️ "quit cleanly" (design §9) IS NOT LOAD-BEARING — MEASURED, not assumed ─
// The design brief for POS2 says "quit cleanly, then assert". There is no
// wire command that reaches AppKit's clean-termination path — `stopStaging`
// SIGTERMs, and `DAWProApp.swift:3144-3146` records that SIGTERM does NOT
// reach `NSApplication.willTerminateNotification` for this process (it dies
// like a crash). A next reader chasing "quit cleanly" would go build a quit
// path that does not exist over the control wire. MEASURED INSTEAD (3/3 live
// runs, a throwaway probe against this exact binary before this gate was
// written): the `NSWindow Frame …AppWindow-1` write lands in the domain
// WITHIN THE SAME POLL TICK `debug.windowFrame` itself returns on — before
// any teardown is even requested. So POS2 below asserts it twice — once
// immediately after the drive (process still alive) and again after
// `stopStaging` (process gone) — and never depends on a clean-quit path.
//
// ── WHY THE CONTROLS ARE NOT OPTIONAL ────────────────────────────────────────
// Same law as `m23ay-profile-isolation`: "the user's domain did not change"
// passes trivially if the staging app never wrote anywhere, or if the differ
// itself is broken. So:
//   CTL-a — the byte differ is proven to detect a real content change AND a
//     mtime-only touch, on a scratch copy this gate owns.
//   CTL-b — `DAWApp.plist` is non-empty before the run (comparing an absent
//     file to itself is a green that means nothing).
//   POS1/POS2/PS — the staging app is proven, from the OUTSIDE (the wire, the
//     kernel's own `ps`, and the filesystem), to have actually written to ITS
//     OWN domain and to be identified as `DAWProStaging` by the OS — so A1/A2
//     below cannot pass for a launch that crashed before writing anything.
//   SELF (m23-gf-f) — the app's OWN report of the domain it persists under
//     (`debug.defaultsDomain`), checked against PS's outside inference. PS asks
//     the kernel what the process is CALLED; this asks the app where it is
//     WRITING. One fact, two independent instruments — and two instruments
//     disagreeing is the signal.
//   NEG — a DECOY domain the differ is proven to detect a write to, in the
//     SAME run, so "the user's domain is unchanged" is a measurement and not
//     a tautology from an instrument that always says "identical". Never an
//     isolation-defeating switch — `_staging.mjs:296-299` already states why
//     that shape is forbidden, and it binds here too.
//
// ── THE UNTESTED LOCK BRANCH ─────────────────────────────────────────────────
// `acquireDefaultsDomainLock`'s "throws on a LIVE foreign owner" branch has
// never been exercised by a real concurrent process — only the stale-lock
// self-heal path has run. This gate exercises it FIRST, before this node
// process's own `resetStagingDefaultsDomain()` has ever succeeded once (that
// call is memoised per process — testing the throw branch after a success
// would just return the cached domain and touch the lock at all).
// `acquireDefaultsDomainLock` itself is not exported (by design — it is an
// internal precondition guard, not a public seam), so it is exercised through
// the shipped call path, `resetStagingDefaultsDomain()`, exactly as every
// real caller reaches it. `_staging.mjs` is not modified for this.
//
// Staging 17695 ONLY; 17600 is the user's LIVE app and is never touched
// (`assertStagingPort` enforces it, and this gate ALSO refuses to run at all
// while something is listening on 17600 — same precondition as m23ay).
// Staging is killed PIDFILE-EXACT via `stopStaging`, never pkill/pgrep.
//
// Usage: node scripts/gates/m23gf-defaults-isolation.mjs
// Direct-run note: export a SCRATCH `CORPUS_BASELINE` first, or `verdict()`
// writes coverage into the real `scripts/gate-corpus-baseline.json` — the
// m23-gf-b close already recorded that `_verdict.mjs` reads that env var
// independently of the `--only=` runner.
import { createHash } from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { tmpdir } from "node:os";
import { spawn, spawnSync } from "node:child_process";
import {
  LIVE_PORT, STAGING_PORT, ROOT, DEFAULT_BINARY,
  STAGING_DEFAULTS_DOMAIN, STAGING_PROCESS_NAME,
  launchStaging, stopStaging, connect, sleep,
  resetStagingDefaultsDomain, panelDensityGuard, stagingSessionLockPath,
  verdict,
} from "./_staging.mjs";

const GATE = "m23gf";
const PORT = Number(process.env.DAW_CONTROL_PORT || STAGING_PORT);
const OUT = process.env.M23GF_OUT || `/tmp/daw-gate-out/${GATE}`;
const PIDFILE = process.env.M23GF_PIDFILE || `${OUT}/staging.pid`;
const BINARY = process.env.M23GF_BINARY || DEFAULT_BINARY;
const HOME = process.env.HOME;
const REAL_DAWAPP_PLIST = `${HOME}/Library/Preferences/DAWApp.plist`;
const REAL_BUNDLE_PLIST = `${HOME}/Library/Preferences/dev.dawpro.app.plist`;

// ⚠️ NOT "DAWProStaging" as a prefix. A decoy sharing that prefix would make
// any `DAWProStaging*` glob match both, and the "real staging domain
// unchanged" check would redden for the WRONG reason (advisor finding #5).
// Exact-name reads only, everywhere in this file.
const DECOY_DOMAIN = "DAWProStagingDecoy";
const DECOY_PLIST = `${HOME}/Library/Preferences/${DECOY_DOMAIN}.plist`;
const STAGING_PLIST = `${HOME}/Library/Preferences/${STAGING_DEFAULTS_DOMAIN}.plist`;

// ⚠️ SECOND SPELLING of a path `_staging.mjs` owns (`DEFAULTS_LOCK_PATH`) —
// not exported, so this gate must know it to plant a foreign-owner lock. If
// that constant ever moves, this gate's lock leg goes to "lock file never
// appears" rather than a false pass — checked explicitly below (LOCK-pre).
const DEFAULTS_LOCK_PATH = "/tmp/daw-gate-out/_staging-defaults.lock";

fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 300_000);

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
let skipped = 0;
const skip = (name, reason) => {
  skipped += 1;
  console.log(`SKIP ${name}: ${reason}`);
};

// ── byte-level fingerprint primitive (hash authoritative, mtime evidence) ───
// ⚠️ advisor finding #6: the brief (hash+size) and design §9 (+mtime) disagree
// on what is BLOCKING. Hash+size is "byte-identical" — that is what A1/A2
// gate on. mtime is reported alongside as evidence; a hash-identical file
// with a MOVED mtime is cfprefsd housekeeping (e.g. a no-op rewrite), not a
// leak, and must be distinguishable from a real difference rather than
// reddening the same check.
function fingerprint(filePath) {
  let st;
  try { st = fs.statSync(filePath); } catch { return { exists: false }; }
  const buf = fs.readFileSync(filePath);
  return {
    exists: true,
    size: st.size,
    mtimeMs: st.mtimeMs,
    sha256: createHash("sha256").update(buf).digest("hex"),
  };
}

const byteIdentical = (a, b) => a.exists && b.exists && a.sha256 === b.sha256 && a.size === b.size;

/** Is anything listening on `port`? (m23ay's `portBusy`, copied — same shape.) */
const portBusy = (port) =>
  new Promise((res) => {
    const s = net.connect({ host: "127.0.0.1", port }, () => { s.destroy(); res(true); });
    s.on("error", () => res(false));
    setTimeout(() => { s.destroy(); res(false); }, 1500);
  });

/**
 * Poll `condFn` until it is true or `boundMs` elapses. `condFn` may be sync
 * or async — always `await`ed, so a sync boolean and a Promise<boolean> both
 * work correctly (an un-awaited Promise is truthy as an OBJECT, which would
 * make this return "ok" on the very first tick regardless of the real
 * result — a bug this file's own NEG-pre leg caught in a self-review before
 * this comment existed).
 */
async function pollUntil(condFn, { boundMs, intervalMs = 200 } = {}) {
  const start = Date.now();
  for (;;) {
    if (await condFn()) return { ok: true, elapsedMs: Date.now() - start };
    if (Date.now() - start >= boundMs) return { ok: false, elapsedMs: Date.now() - start };
    await sleep(intervalMs);
  }
}

/** `/bin/ps -o comm= -p <pid>`, base name only (symlink-followed comm is a full path on some macOS versions). */
function commOf(pid) {
  const r = spawnSync("/bin/ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8" });
  const comm = (r.stdout || "").trim();
  return comm.split("/").pop();
}

function pidIsLive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

// Read one preferences domain's raw text via `defaults read <domain> [key]`.
function defaultsRead(domain, key) {
  const args = key !== undefined ? ["read", domain, key] : ["read", domain];
  const r = spawnSync("/usr/bin/defaults", args, { encoding: "utf8" });
  return { status: r.status, stdout: (r.stdout || "").trim(), stderr: (r.stderr || "").trim() };
}

// ⚠️ `defaults read <domain>` (no key) prints the OLD-STYLE plist dump —
// `    "KeyName" = "value";` — never a bare `^KeyName …$` line. A first draft
// of this file anchored on `^NSWindow Frame .*AppWindow-1$` and it silently
// matched NOTHING against real output (the line starts with whitespace + a
// quote and ends with `";`), which would have made every POS2 leg pass for
// the wrong reason (an absent key looks identical to a key that was never
// searched for correctly). Caught before this gate's first real run by
// diffing this regex against the captured probe output in the session
// transcript, not by assuming the anchor was right.
const NS_WINDOW_KEY_RE = /"NSWindow Frame [^"]*AppWindow-1"\s*=\s*"([^"]*)"/g;

/** All NSWindow …AppWindow-1 key VALUES found in a `defaults read` dump. */
function nsWindowFrameValues(domainReadStdout) {
  const values = [];
  for (const m of domainReadStdout.matchAll(NS_WINDOW_KEY_RE)) values.push(m[1]);
  return values;
}

// ══ PRECONDITION — refuse to measure while the user's app is running ════════
// Same reasoning as m23ay: the user's own live app on 17600 could be writing
// into DAWApp.plist on its own schedule, which would make a before/after
// diff here indistinguishable from "the user did it".
if (await portBusy(LIVE_PORT)) {
  console.log(`ABORT: something is listening on ${LIVE_PORT} — the user's live app is running.`);
  console.log("This gate compares DAWApp.plist byte-for-byte before and after; re-run when it is closed.");
  clearTimeout(killer);
  process.exit(2);
}

// ══ CTL-b — the subject is non-vacuous ══════════════════════════════════════
const dawAppBefore = fingerprint(REAL_DAWAPP_PLIST);
check("CTL-b ~/Library/Preferences/DAWApp.plist is NON-EMPTY before the run — otherwise "
      + "'unchanged' below is a claim about nothing (m23ay's CTL6, applied to a file instead of a "
      + "directory tree)",
      dawAppBefore.exists && dawAppBefore.size > 0,
      JSON.stringify(dawAppBefore));

const bundlePlistBefore = fingerprint(REAL_BUNDLE_PLIST);

// ══ CTL-a — prove the byte differ DETECTS change, on a file this gate owns ══
{
  const ctlDir = fs.mkdtempSync(path.join(OUT, "differ-control-"));
  const scratch = path.join(ctlDir, "scratch.plist");
  fs.writeFileSync(scratch, "one two three four five");

  const f0 = fingerprint(scratch);
  const f0again = fingerprint(scratch);
  check("CTL-a0 the differ reports IDENTICAL for an untouched file — the shape every assertion "
        + "below relies on",
        byteIdentical(f0, f0again),
        `sha256=${f0.sha256.slice(0, 12)}… size=${f0.size}`);

  fs.writeFileSync(scratch, "one two three four five SIX");
  const f1 = fingerprint(scratch);
  check("CTL-a1 a CONTENT change is detected (hash AND size differ) — a deliberately planted "
        + "change to a scratch copy, per the brief: 'a negative result from a hand-built probe is "
        + "the weakest evidence there is — make it find something you know is there first'",
        !byteIdentical(f0, f1) && f1.sha256 !== f0.sha256 && f1.size !== f0.size,
        `before sha256=${f0.sha256.slice(0, 12)}… size=${f0.size}; `
        + `after sha256=${f1.sha256.slice(0, 12)}… size=${f1.size}`);

  const before2 = fingerprint(scratch);
  const future = new Date(Date.now() + 120_000);
  fs.utimesSync(scratch, future, future);
  const after2 = fingerprint(scratch);
  check("CTL-a2 a MTIME-ONLY touch (same bytes, same size) is detected via the mtime field — the "
        + "'rewritten with identical content' shape a hash-only differ would call unchanged, which "
        + "is why A1/A2 report mtime as evidence even though hash+size is what BLOCKS them "
        + "(advisor finding #6)",
        before2.sha256 === after2.sha256 && before2.size === after2.size
        && before2.mtimeMs !== after2.mtimeMs,
        `sha256 unchanged=${before2.sha256 === after2.sha256} mtime ${before2.mtimeMs} -> ${after2.mtimeMs}`);

  fs.rmSync(ctlDir, { recursive: true, force: true });
}

// ══ LOCK — exercise the branch that has never fired: a LIVE foreign owner ═══
// Deliberately BEFORE any successful `resetStagingDefaultsDomain()` in this
// process — that call is memoised per process, so testing the throw branch
// after a success would just hand back the cached domain and never touch the
// lock at all.
{
  fs.mkdirSync(path.dirname(DEFAULTS_LOCK_PATH), { recursive: true });

  // Safety: refuse to clobber a REAL concurrent run's lock. If a live foreign
  // pid already owns it, this is not our test fixture to plant over.
  let preexisting = null;
  try { preexisting = fs.readFileSync(DEFAULTS_LOCK_PATH, "utf8").trim(); } catch { /* absent, fine */ }
  const preexistingPid = Number(preexisting);
  if (preexisting && Number.isInteger(preexistingPid) && pidIsLive(preexistingPid)) {
    console.log(`ABORT: ${DEFAULTS_LOCK_PATH} is already held by LIVE pid ${preexistingPid} — `
      + `refusing to overwrite what may be a real concurrent gate run's lock.`);
    clearTimeout(killer);
    process.exit(2);
  }

  const foreign = spawn("/bin/sleep", ["60"], { detached: true, stdio: "ignore" });
  foreign.unref();
  const foreignPid = foreign.pid;
  // Wait for the kernel to actually schedule it before trusting `pidIsLive`.
  await pollUntil(() => pidIsLive(foreignPid), { boundMs: 3000, intervalMs: 50 });
  fs.writeFileSync(DEFAULTS_LOCK_PATH, String(foreignPid));

  let threw = null;
  try {
    resetStagingDefaultsDomain();
  } catch (e) {
    threw = e;
  }
  const expectedNeedle = `LIVE pid ${foreignPid}`;
  check("LOCK1 resetStagingDefaultsDomain() THROWS when the lock names a LIVE foreign pid — the "
        + "branch that has never been exercised by a real concurrent process before this gate. "
        + "Message-matched on the EXACT pid, not just 'something threw' — a typo in the setup "
        + "would otherwise green this for the wrong reason",
        threw !== null && typeof threw.message === "string" && threw.message.includes(expectedNeedle),
        threw ? `threw: ${threw.message}` : "did NOT throw");

  // Kill the foreign owner, then wait past the zombie state — SIGKILL alone
  // leaves it a zombie until node reaps it, and `process.kill(pid, 0)` on a
  // zombie does NOT throw (advisor finding #4: a fixed sleep here flakes).
  try { process.kill(foreignPid, "SIGKILL"); } catch { /* already gone */ }
  const reaped = await pollUntil(() => !pidIsLive(foreignPid), { boundMs: 5000, intervalMs: 50 });
  check("LOCK-pre the foreign pid is confirmed DEAD (polled past any zombie window) before the "
        + "self-heal is attempted — a precondition for LOCK2, not itself the self-heal claim",
        reaped.ok,
        `dead after ${reaped.elapsedMs}ms (pidIsLive=${pidIsLive(foreignPid)})`);

  const stillNames = (() => {
    try { return Number(fs.readFileSync(DEFAULTS_LOCK_PATH, "utf8").trim()) === foreignPid; }
    catch { return false; }
  })();
  let selfHealed = false, selfHealError = null;
  try {
    resetStagingDefaultsDomain();
    selfHealed = true;
  } catch (e) { selfHealError = e; }
  check("LOCK2 the STALE lock (now naming a dead pid) self-heals — resetStagingDefaultsDomain() "
        + "succeeds, clearing + reseeding the domain exactly as a fresh process would",
        stillNames && selfHealed,
        `lock still named the dead pid=${stillNames}; self-heal `
        + (selfHealed ? "succeeded" : `FAILED: ${selfHealError?.message}`));
}

// ══ PRIMARY LAUNCH — POS1, POS2, PS ══════════════════════════════════════════
let staging = null;
let seedQuantizeBefore = null;
try {
  staging = await launchStaging({
    gate: GATE, port: PORT, binary: BINARY, pidfile: PIDFILE, outDir: OUT,
    detached: true, settleMs: 1500, logPath: `${OUT}/staging.log`,
  });
  console.log(`staging pid ${staging.pid} on :${PORT}, domain ${staging.defaultsDomain}, binary ${staging.binary}`);

  check("PS the spawned pid's comm reads DAWProStaging — the kernel's own idea of the process "
        + "name, checked independently of the internal confirmation `startStaging` already did "
        + "(and would have thrown on, had it failed)",
        commOf(staging.pid) === STAGING_DEFAULTS_DOMAIN,
        `comm=${JSON.stringify(commOf(staging.pid))}`);

  // ── the wire ──────────────────────────────────────────────────────────────
  let nextId = 1;
  const pending = new Map();
  staging.ws.onmessage = (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
    if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
    else e.resolve(m.result ?? m);
  };
  const req = (command, params = {}, timeoutMs = 15_000) => {
    const id = String(nextId++);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, command });
      staging.ws.send(JSON.stringify({ id, command, params }));
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, timeoutMs);
    });
  };

  // ── POS1 — the app wrote a key the gate itself changed, not merely one the ─
  // seed already wrote. Vacuity check (advisor #1): if this passed with the
  // wire call skipped entirely, it would only be proving the SEED landed,
  // which resetStagingDefaultsDomain() already proves on every run. So: read
  // the seed's value for `quantize` FIRST, then drive a DIFFERENT value
  // (simple), and assert the app-written value differs from the seed.
  // ⛔ m23-gf-e: this used to assert `seedQuantizeBefore === "pro"`, which was
  // true only while the seed carried `panelDensity.quantize: "pro"`. Phase E
  // shrank the seed to `onboarding.state` alone, the key became ABSENT
  // (stored: null), and POS1 failed on its OWN PREMISE rather than on app
  // behaviour — a fixture asserting the seed's former contents, not the thing
  // the check exists to prove. The condition below is now stated the way the
  // sentence above always meant it: whatever the prior value was, driving to
  // "simple" must be a REAL change, so the prior must not already BE "simple".
  // That holds for "pro" (old seed), for null (absent), and for any value a
  // future seed might carry — it cannot go stale against seed content again.
  const guard = panelDensityGuard((cmd, params) => req(cmd, params));
  const seedRead = await req("debug.panelDensity", { panel: "quantize" });
  seedQuantizeBefore = seedRead.stored;
  await guard.set("quantize", "simple");
  // `defaults read` answers from cfprefsd's in-memory cache (fast — unlike the
  // physical plist file NEG1 fingerprints, which flushes to disk on a slower,
  // separate schedule, see NEG1's comment below). Still polled, not a single
  // shot: cheap insurance against exactly the class of timing gap NEG1's
  // first live run exposed, applied defensively here even though the direct
  // measurement was consistently instant.
  const wrote = await pollUntil(
    () => defaultsRead(STAGING_DEFAULTS_DOMAIN, "panelDensity.quantize").stdout === "simple",
    { boundMs: 5000, intervalMs: 200 }
  );
  const afterWrite = defaultsRead(STAGING_DEFAULTS_DOMAIN, "panelDensity.quantize");
  check("POS1 the staging domain gained a value the GATE ITSELF changed (not merely a seeded one) "
        + "— quantize seed=" + JSON.stringify(seedQuantizeBefore) + ", driven to \"simple\" over "
        + "the wire, then read back from the filesystem via `defaults read` independent of the "
        + "app's own response. Without this, A1 below would pass for a staging app that crashed "
        + "before writing anything, since the SEED alone already puts panelDensity.* keys in the "
        + "domain",
        seedQuantizeBefore !== "simple" && wrote.ok && afterWrite.stdout === "simple",
        `seed stored=${JSON.stringify(seedQuantizeBefore)}; ${STAGING_DEFAULTS_DOMAIN} `
        + `panelDensity.quantize now reads ${JSON.stringify(afterWrite.stdout)} (confirmed after `
        + `${wrote.elapsedMs}ms, exit ${afterWrite.status})`);

  // ── SELF (m23-gf-f) — the APP's own statement, checked against PS's ────────
  // PS above is an OUTSIDE inference: the kernel's `comm` for the pid. This is
  // the app answering the same question from the inside, through CFPreferences.
  // Two independent instruments on one fact — and two instruments disagreeing
  // is the signal. A `comm` that reads `DAWProStaging` while the app persists
  // somewhere else is precisely the failure PS alone cannot see.
  //
  // Three conjuncts, each doing separate work:
  //   • `derivedDomain === STAGING_PROCESS_NAME` — the agreement itself.
  //   • `probe.agrees && !probe.vacuous` — the DERIVATION is only a restatement
  //     of Apple's rule; the probe is the measured half, so it must be
  //     non-vacuously true. `panelDensity.quantize` is used deliberately: POS1
  //     drove it over the wire moments ago and read it back off the filesystem,
  //     so it is a key the APP ITSELF persisted (not a registration default,
  //     which would be legitimately invisible to `persistentDomain(forName:)`).
  //   • the domain dump is unchanged ACROSS the call — a measured read-only
  //     proof for a verb whose whole purpose is proving the app does not
  //     pollute a domain. It bounds the window to this one request; it is not a
  //     claim about the handler's source, which is checked separately by grep.
  const selfBefore = defaultsRead(STAGING_DEFAULTS_DOMAIN);
  const selfReport = await req("debug.defaultsDomain", { probeKey: "panelDensity.quantize" });
  const selfAfter = defaultsRead(STAGING_DEFAULTS_DOMAIN);
  check("SELF the APP reports its own defaults domain (debug.defaultsDomain, m23-gf-f) and it "
        + "agrees with STAGING_PROCESS_NAME — the inside view of what PS above infers from the "
        + "outside — with a NON-VACUOUS probe on a key the app itself persisted, and the domain "
        + "byte-unchanged across the call (the verb is read-only)",
        selfReport.derivedDomain === STAGING_PROCESS_NAME
        && selfReport.processName === STAGING_PROCESS_NAME
        && selfReport.probe?.agrees === true && selfReport.probe?.vacuous === false
        && selfAfter.stdout === selfBefore.stdout,
        `derivedDomain=${JSON.stringify(selfReport.derivedDomain)} `
        + `processName=${JSON.stringify(selfReport.processName)} `
        + `bundleIdentifier=${JSON.stringify(selfReport.bundleIdentifier)} `
        + `(expected ${JSON.stringify(STAGING_PROCESS_NAME)}); probe=${JSON.stringify(selfReport.probe)}; `
        + `domain dump unchanged across the call=${selfAfter.stdout === selfBefore.stdout} `
        + `(${selfBefore.stdout.length} vs ${selfAfter.stdout.length} bytes)`);

  // ── POS2 — the incident itself: debug.windowFrame -> NSWindow Frame write ──
  const before = defaultsRead(STAGING_DEFAULTS_DOMAIN);
  const beforeValues = nsWindowFrameValues(before.stdout);

  const wf = await req("debug.windowFrame", { width: 1400, height: 1000 });
  check("POS2-drive debug.windowFrame {width:1400,height:1000} was accepted and echoed the "
        + "requested size — the exact call ~10 gate files already pin",
        wf && wf.width === 1400 && wf.height === 1000,
        JSON.stringify(wf));

  // The frame's serialized form is "x y width height minX minY maxX maxY"
  // (measured directly against this app: "144 27 1400 1000 0 0 1728 1084").
  // Match the literal "1400 1000" substring in POSITION (width then height),
  // not merely present somewhere in the 8-number string.
  const encodesRequestedSize = (v) => typeof v === "string" && /(^|\s)1400 1000(\s|$)/.test(v);

  // Poll immediately (process still alive) — measured 3/3 at t+0 on this
  // machine before this gate was written; bounded generously anyway rather
  // than assuming that holds forever.
  const liveObserved = await pollUntil(() => {
    const r = defaultsRead(STAGING_DEFAULTS_DOMAIN);
    return nsWindowFrameValues(r.stdout).some(encodesRequestedSize);
  }, { boundMs: 10_000, intervalMs: 250 });

  if (liveObserved.ok) {
    check("POS2a the STAGING domain's NSWindow Frame …AppWindow-1 key encodes 1400×1000 while "
          + "the app is still running — observed " + liveObserved.elapsedMs + "ms after the drive "
          + `(${beforeValues.length} such key(s) existed before this call, from launch's own `
          + `initial frame)`,
          true,
          `observed after ${liveObserved.elapsedMs}ms; before-drive value(s)=${JSON.stringify(beforeValues)}`);
  } else {
    // The design brief's own escape hatch: report UNKNOWN, never fake green.
    skip("POS2a windowFrame-flush-live", `could not observe a 1400×1000 NSWindow Frame key in `
      + `${STAGING_DEFAULTS_DOMAIN} within ${liveObserved.elapsedMs}ms of the drive while the app `
      + `was still running — cfprefsd flush timing is not force-able from here. Measured reliably `
      + `at t+0 in 3/3 pre-flight probes on this machine; UNKNOWN here, not zero, not a fail.`);
  }

  // Restore the panel this gate itself changed BEFORE teardown, same
  // discipline every other gate in the corpus follows (panelDensityGuard's
  // whole purpose) — even though the domain is wiped fresh on the next
  // process anyway, leaving a value only THIS run's exercise wrote is not
  // this gate's to keep.
  await guard.restore("m23gf gate exit").catch((e) => console.log("guard restore: " + e?.message));

  await sleep(300);
  try { staging.stop(); } catch { /* best effort, teardown handles the rest */ }
  await sleep(1200);

  const postObserved = await pollUntil(() => {
    const r = defaultsRead(STAGING_DEFAULTS_DOMAIN);
    return nsWindowFrameValues(r.stdout).some(encodesRequestedSize);
  }, { boundMs: 8000, intervalMs: 250 });

  if (postObserved.ok) {
    check("POS2b the write PERSISTED after teardown (SIGTERM via stopStaging — this process does "
          + "NOT reach AppKit's clean-termination path, DAWProApp.swift:3144-3146) — read again "
          + "with the app's own process gone, so this is disk state, not a live cache",
          true,
          `observed ${postObserved.elapsedMs}ms after teardown poll began`);
  } else {
    skip("POS2b windowFrame-flush-post-teardown", `the 1400×1000 key was not observed in `
      + `${STAGING_DEFAULTS_DOMAIN} within ${postObserved.elapsedMs}ms after teardown, though `
      + `POS2a ${liveObserved.ok ? "DID" : "also did NOT"} observe it live. UNKNOWN, not zero.`);
  }

  // The other half of the incident: DAWApp.plist's OWN NSWindow Frame key(s)
  // must be untouched by any of this. Anti-vacuity first (advisor #2): count
  // them, and require at least one, or "none changed" compares 0 to 0.
  const dawAppNow = defaultsRead("DAWApp");
  const dawAppKeyCount = nsWindowFrameValues(dawAppNow.stdout).length;
  check("POS2-precondition DAWApp.plist actually HOLDS at least one NSWindow Frame …AppWindow-1 "
        + "key right now — the anti-vacuity check for the next assertion (the m23-fu law: 'cannot "
        + "say nothing changed when that compares 0 to 0')",
        dawAppKeyCount >= 1,
        `${dawAppKeyCount} matching key(s) in DAWApp`);
} catch (e) {
  check("PRIMARY LAUNCH did not throw", false, e?.stack ?? e?.message ?? String(e));
} finally {
  try { staging?.ws?.close(); } catch { /* best effort */ }
  await sleep(300);
  try { stopStaging(GATE, PIDFILE); } catch (e) { console.log("stopStaging: " + e?.message); }
  await sleep(1200);
}

// ══ NEG — a DECOY domain, never an isolation-defeating switch ═══════════════
// ⛔⛔ FORBIDDEN SHAPE, on purpose not implemented: "disable isolation and
// assert A1 fails" — when it fires it would write into DAWApp.plist, damaging
// the exact asset this gate protects. `_staging.mjs:296-299` already states
// the rule for the profile root; it binds here too. Instead: a SECOND real
// domain this gate owns end-to-end, proving the differ fires on a domain the
// app really writes, without the app ever resolving to the user's domain.
let decoyChild = null;
let decoyAliasPath = null;
try {
  // Wait for the primary's port to actually free (advisor #5: async SIGTERM,
  // a still-bound socket gives a confusing bind failure, not a clean red).
  const freed = await pollUntil(() => portBusy(PORT).then((busy) => !busy), { boundMs: 8000, intervalMs: 200 });
  check(`NEG-pre port :${PORT} freed after the primary's teardown before the decoy launch`,
        freed.ok,
        `freed=${freed.ok} after ${freed.elapsedMs}ms`);
  if (!freed.ok) throw new Error(`port ${PORT} never freed — refusing to spawn the decoy onto a busy port`);

  // Build the decoy alias by hand — `stagingBinaryAlias` is hard-pinned to
  // STAGING_DEFAULTS_DOMAIN by design (assertStagingDefaultsDomain refuses
  // anything else on the RESET path); this mirrors its symlink-only,
  // throw-never-fallback shape for a SECOND name, entirely inside this gate
  // file. `_staging.mjs` is not touched.
  const realPath = path.isAbsolute(BINARY) ? BINARY : path.join(ROOT, BINARY);
  if (!fs.existsSync(realPath)) throw new Error(`decoy alias: real binary missing at ${realPath}`);
  decoyAliasPath = path.join(path.dirname(realPath), DECOY_DOMAIN);
  let prior = null;
  try { prior = fs.lstatSync(decoyAliasPath); } catch { /* nothing there — fine */ }
  if (prior && !prior.isSymbolicLink()) {
    throw new Error(`decoy alias: ${decoyAliasPath} exists and is NOT a symlink — refusing to touch it`);
  }
  if (prior) fs.rmSync(decoyAliasPath, { force: true });
  fs.symlinkSync(realPath, decoyAliasPath);
  const target = fs.readlinkSync(decoyAliasPath);
  if (target !== realPath) throw new Error(`decoy alias target mismatch: ${target} != ${realPath}`);

  // Clear + seed the decoy domain (advisor: seed onboarding.state so a wire
  // round-trip is never racing the tour overlay — cheap, removes a whole
  // class of flake).
  spawnSync("/usr/bin/defaults", ["delete", DECOY_DOMAIN], { stdio: "ignore" });
  spawnSync("/usr/bin/defaults", ["write", DECOY_DOMAIN, "onboarding.state", "-string", "completed"], { stdio: "ignore" });
  const decoyBefore = fingerprint(DECOY_PLIST);
  const stagingBeforeDecoy = fingerprint(STAGING_PLIST);

  const decoyProfileRoot = fs.mkdtempSync(path.join(tmpdir(), "dawpro-decoy-profile-"));
  decoyChild = spawn(decoyAliasPath, [], {
    cwd: ROOT,
    env: { ...process.env, DAW_CONTROL_PORT: String(PORT), DAWPRO_PROFILE_ROOT: decoyProfileRoot },
    stdio: ["ignore", "ignore", "ignore"],
    detached: true,
  });
  decoyChild.unref();
  const decoyPidfile = `${OUT}/decoy.pid`;
  fs.writeFileSync(decoyPidfile, String(decoyChild.pid));

  // Retry, not a fixed sleep — `_staging.mjs`'s own `confirmAliasIdentity`
  // notes `ps` can report the PARENT node binary's name for the first tens
  // of milliseconds right after spawn.
  const identityConfirmed = await pollUntil(() => commOf(decoyChild.pid) === DECOY_DOMAIN, { boundMs: 3000, intervalMs: 100 });
  check("NEG-identity the decoy pid's comm reads DAWProStagingDecoy — proof the alias trick moved "
        + "the domain to a name this gate owns, not to DAWProStaging or DAWApp",
        identityConfirmed.ok,
        `comm=${JSON.stringify(commOf(decoyChild.pid))} confirmed after ${identityConfirmed.elapsedMs}ms`);
  await sleep(500); // settle before connecting, same shape `launchStaging`'s settleMs gives the primary

  const decoyWs = await connect({ port: PORT });
  let nextId = 1;
  const pending = new Map();
  decoyWs.onmessage = (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
    if (m.ok === false || m.error) e.reject(new Error(JSON.stringify(m.error)));
    else e.resolve(m.result ?? m);
  };
  const decoyReq = (command, params = {}) => {
    const id = String(nextId++);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      decoyWs.send(JSON.stringify({ id, command, params }));
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error("timeout " + command)); } }, 15000);
    });
  };
  await decoyReq("debug.panelDensity", { panel: "quantize", mode: "pro" });
  try { decoyWs.close(); } catch { /* best effort */ }

  // ⚠️ MEASURED, not assumed, and a real defect in this gate's first draft:
  // `defaults read` answers from cfprefsd's IN-MEMORY cache almost instantly
  // (this is what POS1/POS2 poll on, correctly), but the PHYSICAL PLIST FILE
  // this differ fingerprints is written to disk on cfprefsd's OWN, separate,
  // SLOWER schedule — independent of the client process and not force-able
  // from here. A dedicated probe against this exact write path (same alias,
  // same command) saw the file's bytes change ~2000ms after the wire call
  // returned, WHILE THE APP WAS STILL ALIVE — past this file's original
  // `sleep(1000)`, which is exactly why the gate's own first live run
  // reddened NEG1 with `defaults read` already showing "pro" and the file
  // hash still showing "unchanged". Fixed by polling the SAME byte
  // fingerprint CTL-a already proved detects change, bounded generously, with
  // the design brief's own UNKNOWN-not-zero escape hatch if it never lands.
  const decoyFlushed = await pollUntil(
    () => !byteIdentical(decoyBefore, fingerprint(DECOY_PLIST)),
    { boundMs: 15_000, intervalMs: 300 }
  );

  await sleep(300);
  // ⚠️ Explicit lockPath, pointed at the decoy's OWN profile root — without
  // it, `stopStaging`'s fallback (`sessionLockPath(undefined)`) resolves to
  // the USER'S REAL Autosave lock (this gate never called `startStaging` for
  // "m23gf-decoy", so `profileRoots` has no entry for it and the module falls
  // back exactly as it does for any gate it did not start). The strict
  // pid-ownership check in `releaseSessionLock` would have refused to delete
  // it either way, but there is no reason for this gate to even READ a file
  // under the user's real profile when the decoy's own lock path is known.
  try { stopStaging("m23gf-decoy", decoyPidfile, { lockPath: stagingSessionLockPath(decoyProfileRoot) }); }
  catch (e) { console.log("decoy stopStaging: " + e?.message); }
  await sleep(1000);

  const decoyAfter = fingerprint(DECOY_PLIST);
  const decoyReadback = defaultsRead(DECOY_DOMAIN, "panelDensity.quantize");
  if (decoyFlushed.ok) {
    check("NEG1 the differ DETECTS the write to the DECOY domain — a domain the app really wrote "
          + "to, proving the instrument fires at all (the whole job of a negative control)",
          !byteIdentical(decoyBefore, decoyAfter) && decoyReadback.stdout === "pro",
          `${DECOY_PLIST} before.exists=${decoyBefore.exists} after.exists=${decoyAfter.exists} `
          + `changed=${!byteIdentical(decoyBefore, decoyAfter)} (flushed ${decoyFlushed.elapsedMs}ms `
          + `after the drive, while still alive); panelDensity.quantize=${JSON.stringify(decoyReadback.stdout)}`);
  } else {
    skip("NEG1 decoy-plist-flush", `the byte-level ${DECOY_DOMAIN}.plist never changed within `
      + `${decoyFlushed.elapsedMs}ms of the drive, even though \`defaults read\` reports `
      + `panelDensity.quantize=${JSON.stringify(decoyReadback.stdout)} — cfprefsd's disk flush is `
      + `slower than its in-memory answer and not force-able from here (measured ~2000ms in a `
      + `dedicated probe). UNKNOWN, not zero, not a fail.`);
  }

  const stagingAfterDecoy = fingerprint(STAGING_PLIST);
  check("NEG2 the REAL staging domain (DAWProStaging, EXACT name, never a glob) is BYTE-IDENTICAL "
        + "across the decoy launch — the decoy wrote only into its own domain, never bleeding "
        + "into the real one",
        byteIdentical(stagingBeforeDecoy, stagingAfterDecoy),
        `before sha256=${stagingBeforeDecoy.sha256?.slice(0, 12)}… after sha256=${stagingAfterDecoy.sha256?.slice(0, 12)}…`);
} catch (e) {
  check("NEG did not throw", false, e?.stack ?? e?.message ?? String(e));
} finally {
  if (decoyChild && decoyChild.pid) {
    try { process.kill(decoyChild.pid, "SIGTERM"); } catch { /* already gone */ }
  }
  if (decoyAliasPath) {
    try { fs.rmSync(decoyAliasPath, { force: true }); } catch { /* best effort cleanup */ }
  }
  await sleep(500);
  // m23-gf-c follow-up: delete the decoy's PREFERENCES DOMAIN too, not just its
  // alias. Launching the decoy materialises `~/Library/Preferences/
  // DAWProStagingDecoy.plist`, and leaving it there is litter in the user's own
  // Preferences directory — which is precisely the class of pollution this gate
  // exists to prove we no longer cause. A gate that demonstrates isolation while
  // depositing its own debris next to the user's files is not making the point.
  //
  // ⚠️ EXACT NAME, NEVER A GLOB. `defaults delete DAWProStaging*` would take the
  // real staging domain with it, and a careless `DAWApp*` would take the USER'S.
  // This is the same reasoning that picked `DAWProStaging` over `DAWAppStaging`
  // (design §3.1): a name that is a prefix of nothing real.
  // ⚠️ A SINGLE `defaults delete` HERE LOSES A RACE — measured, not guessed.
  // `cfprefsd` flushes a domain to disk on its own schedule, 2000–5728 ms behind
  // the client (the same lag that produced this gate's NEG1 false negative). The
  // decoy's pending write therefore lands AFTER a delete issued immediately, and
  // re-materialises the plist. So: delete, then POLL FOR ABSENCE and re-delete,
  // bounded — the same "poll the instrument you already validated" discipline
  // NEG1 uses, instead of a blind sleep tuned to today's machine.
  // ⚠️⚠️ POLL THE DOMAIN, NOT THE FILE — measured. `defaults delete` empties the
  // DOMAIN, but `cfprefsd` leaves a 42-byte EMPTY plist husk on disk that
  // `defaults` cannot remove (`plutil -p` on it prints `{}` while
  // `defaults read` says "Domain … does not exist"). Polling `existsSync` on the
  // FILE therefore reports failure forever while the cleanup has in fact
  // succeeded — the wrong instrument answering a question it cannot see.
  // So: poll the DOMAIN for absence, then unlink the husk separately.
  const decoyPlist = `${process.env.HOME}/Library/Preferences/${DECOY_DOMAIN}.plist`;
  const decoyDomainGone = () => {
    const r = spawnSync("/usr/bin/defaults", ["read", DECOY_DOMAIN], { encoding: "utf8" });
    return r.status !== 0;                                // non-zero == "does not exist"
  };
  let decoyGone = false;
  for (let i = 0; i < 16 && !decoyGone; i++) {           // ≤ ~8 s, covers the 2000–5728 ms flush lag
    try { spawnSync("/usr/bin/defaults", ["delete", DECOY_DOMAIN], { stdio: "ignore" }); } catch { /* best effort */ }
    await sleep(500);
    decoyGone = decoyDomainGone();
  }
  // Only once the domain is provably empty is the husk safe to unlink — removing
  // it while cfprefsd still holds pending writes would just let it reappear.
  if (decoyGone) {
    try { fs.rmSync(decoyPlist, { force: true }); } catch { /* husk removal is best effort */ }
  }
  // Reported, never asserted: leftover decoy state is untidy, not wrong, and must
  // not be able to redden a gate whose subject is the user's REAL domains.
  console.log(decoyGone
    ? `  decoy domain ${DECOY_DOMAIN} removed from ~/Library/Preferences`
    : `  ⚠️ decoy domain ${DECOY_DOMAIN} still present after ~8s of delete+poll — `
      + `untidy, not a failure. Remove by hand: defaults delete ${DECOY_DOMAIN}`);
}

// ══ A — THE HEADLINE: both REAL domains are unchanged across the whole run ══
const dawAppAfter = fingerprint(REAL_DAWAPP_PLIST);
check("A1 ~/Library/Preferences/DAWApp.plist is byte-identical (sha256 + size) across the whole "
      + "run — the bare-binary domain the incident was filed about",
      byteIdentical(dawAppBefore, dawAppAfter),
      `before sha256=${dawAppBefore.sha256?.slice(0, 12)}… size=${dawAppBefore.size} mtime=${dawAppBefore.mtimeMs}; `
      + `after sha256=${dawAppAfter.sha256?.slice(0, 12)}… size=${dawAppAfter.size} mtime=${dawAppAfter.mtimeMs}`
      + (dawAppBefore.exists && dawAppAfter.exists && dawAppBefore.sha256 === dawAppAfter.sha256
          && dawAppBefore.mtimeMs !== dawAppAfter.mtimeMs
        ? " [hash+size identical but mtime moved — cfprefsd housekeeping, not a leak; reported, not reddened]"
        : ""));

const bundlePlistAfter = fingerprint(REAL_BUNDLE_PLIST);
check("A2 ~/Library/Preferences/dev.dawpro.app.plist (the OTHER real domain — the bundle's) is "
      + "byte-identical across the whole run — staging never touches the bundle identity, but "
      + "this is the assertion that says so instead of assuming it",
      byteIdentical(bundlePlistBefore, bundlePlistAfter),
      `before sha256=${bundlePlistBefore.sha256?.slice(0, 12)}… size=${bundlePlistBefore.size}; `
      + `after sha256=${bundlePlistAfter.sha256?.slice(0, 12)}… size=${bundlePlistAfter.size}`);

clearTimeout(killer);
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23GF ${pass}/${checks.length} (${skipped} skipped)`);
verdict({ ran: checks.length, failed: checks.length - pass });
