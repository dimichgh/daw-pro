// m23-ac-2c — staging teardown must not leave the USER a false crash recovery.
//
// WHAT THIS GUARDS. Gates stop the staging app with SIGTERM, which skips the
// app's clean-exit path, so the `session.lock` it wrote at launch survives the
// gate. At the next real launch DAW Pro reads that lock and offers to recover
// from a crash that never happened. Measured before the fix: a bare `m23d` run
// left `{"pid":43172}` behind in the user's own profile directory.
//
// ⚠️ THIS GATE REASONS ABOUT A FILE IN THE USER'S REAL PROFILE. The ownership
// check in `releaseSessionLock` is the entire safety property — the same lock
// file is written by the user's LIVE app on port 17600. So the legs below split
// deliberately:
//
//   Leg A drives the REAL path end-to-end, because that is the only way to
//         prove the DEFAULT path is spelled correctly. A temp-path-only suite
//         passes perfectly while production cleans nothing.
//   Legs B-F drive `releaseSessionLock` DIRECTLY against a TEMP path. They must
//         never go through `stopStaging`, because `stopStaging` SIGTERMs the pid
//         it finds in the pidfile — a test that fabricates a pidfile to exercise
//         the ownership check would be a test that signals an invented pid.
//
// Run: node scripts/gates/m23ac2c-session-lock.mjs
import fs from "node:fs";
import net from "node:net";
import {
  ROOT, LIVE_PORT, STAGING_PORT,
  buildOrAbort, startStaging, stopStaging, connect,
  sessionLockPath, releaseSessionLock, sleep,
} from "./_staging.mjs";

const GATE = "m23ac2c";
const OUT = process.env.M23AC2C_OUT || `/tmp/daw-gate-out/${GATE}`;
const PIDFILE = process.env.M23AC2C_PIDFILE || `${OUT}/staging.pid`;
const BINARY = process.env.M23AC2C_BINARY || ".build/debug/DAWApp";
const TMP = `${OUT}/tmp-locks`;

fs.mkdirSync(TMP, { recursive: true });

const checks = [];
const ck = (label, cond, detail = "") => {
  checks.push({ label, pass: !!cond, detail });
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail ? `  :: ${detail}` : ""}`);
};

/** Is anything listening on `port`? Used to refuse to run over a live session. */
const portBusy = (port) =>
  new Promise((res) => {
    const s = net.connect({ host: "127.0.0.1", port }, () => { s.destroy(); res(true); });
    s.on("error", () => res(false));
    setTimeout(() => { s.destroy(); res(false); }, 1500);
  });

const writeLock = (path, obj) => fs.writeFileSync(path, JSON.stringify(obj));
const exists = (p) => fs.existsSync(p);

// ── Legs B-F: the ownership check, in isolation, on a temp path ─────────────
// These run FIRST: they are pure and fast, and if the ownership check is wrong
// there is no reason to go near the real profile directory at all.

function ownershipLegs() {
  const lock = `${TMP}/session.lock`;

  // Leg B — ANTI-VACUITY. A lock owned by someone else is LEFT ALONE. This is
  // the leg that fails if the cleanup ever becomes an unconditional delete,
  // which would pass Leg A perfectly while destroying the user's real recovery.
  fs.rmSync(lock, { force: true });
  writeLock(lock, { pid: 999999, startedAt: "2026-07-30T00:00:00Z" });
  const bRet = releaseSessionLock(12345, lock);
  ck("B foreign-owned lock is LEFT ALONE", bRet === false && exists(lock), `returned ${bRet}`);
  ck("B its contents are untouched",
    exists(lock) && JSON.parse(fs.readFileSync(lock, "utf8")).pid === 999999);

  // Leg C — the positive case: our own lock IS removed.
  fs.rmSync(lock, { force: true });
  writeLock(lock, { pid: 12345, startedAt: "2026-07-30T00:00:00Z" });
  const cRet = releaseSessionLock(12345, lock);
  ck("C our own lock is removed", cRet === true && !exists(lock), `returned ${cRet}`);

  // Leg D — every uncertain branch falls through to LEAVING the file.
  fs.rmSync(lock, { force: true });
  ck("D absent lock is a no-op", releaseSessionLock(12345, lock) === null && !exists(lock));

  fs.writeFileSync(lock, "{not json at all");
  ck("D malformed JSON leaves the file", releaseSessionLock(12345, lock) === null && exists(lock));

  fs.rmSync(lock, { force: true });
  writeLock(lock, { startedAt: "2026-07-30T00:00:00Z" }); // no pid field
  ck("D a lock with no pid is left alone", releaseSessionLock(12345, lock) === false && exists(lock));

  fs.rmSync(lock, { force: true });
  writeLock(lock, { pid: "12345" }); // string, not number
  ck("D a string pid does not count as a match",
    releaseSessionLock(12345, lock) === false && exists(lock),
    "Number('12345')===12345 would be a coercion match — the guard must not accept it");

  // Leg E — no pidfile means no provable owner, so `stopStaging` must not even
  // look at the lock. Uses a pidfile path that does not exist, so nothing is
  // signalled.
  fs.rmSync(lock, { force: true });
  writeLock(lock, { pid: 4242 });
  stopStaging(GATE, `${TMP}/definitely-not-a-pidfile`, { lockPath: lock });
  ck("E no pidfile -> lock untouched (no provable owner)", exists(lock));
  fs.rmSync(lock, { force: true });

  // Leg F — the DEFAULT path is the app's real one. Leg A proves it works;
  // this proves it is spelled the way `DAWCore.AppDirectories` spells it.
  const def = sessionLockPath();
  ck("F default path is the app's Autosave lock",
    def === `${process.env.HOME}/Library/Application Support/DAWPro/Autosave/session.lock`, def);
  ck("F an override wins over the default", sessionLockPath("/tmp/x.json") === "/tmp/x.json");
}

// ── Leg A: the real thing, on the real path ─────────────────────────────────

async function realPathLeg() {
  const real = sessionLockPath();

  // Refuse to run over the user's live app: a staging launch OVERWRITES
  // whatever lock is present (measured at m23-ac-2c), so doing this while the
  // user has DAW Pro open would clobber their real crash-detection state.
  if (await portBusy(LIVE_PORT)) {
    ck(`A ABORT: something is listening on ${LIVE_PORT} (the user's live app)`, false,
      "refusing to run — a staging launch would overwrite the live session's lock");
    return;
  }
  ck(`A the user's live port ${LIVE_PORT} is free`, true);

  buildOrAbort();
  const { pid } = startStaging({
    gate: GATE, root: ROOT, port: STAGING_PORT, binary: BINARY, pidfile: PIDFILE,
    outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
  });
  console.log(`staging pid ${pid} on :${STAGING_PORT}`);

  try {
    const ws = await connect({ port: STAGING_PORT });
    ws.close();
    await sleep(500);

    // NON-VACUITY for the whole leg: if the app never writes a lock, "no lock
    // survives teardown" is true for the wrong reason and this gate would
    // certify a fix that does nothing.
    let owner = null;
    try { owner = Number(JSON.parse(fs.readFileSync(real, "utf8")).pid); } catch {}
    ck("A the running app DID write a lock, owned by our staging pid",
      owner === pid, `lock pid ${owner}, staging pid ${pid}`);
  } finally {
    stopStaging(GATE, PIDFILE);
  }

  await sleep(800);
  ck("A no session.lock survives teardown", !exists(real),
    exists(real) ? `SURVIVED: ${fs.readFileSync(real, "utf8")}` : "gone");
}

(async () => {
  ownershipLegs();
  await realPathLeg();

  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify(checks, null, 2));
  const passed = checks.filter((c) => c.pass).length;
  console.log(`\n${passed}/${checks.length} checks passed`);
  process.exit(passed === checks.length ? 0 : 1);
})().catch((e) => {
  console.log(`FAIL  unhandled: ${e && e.stack ? e.stack : e}`);
  try { stopStaging(GATE, PIDFILE); } catch {}
  process.exit(1);
});
