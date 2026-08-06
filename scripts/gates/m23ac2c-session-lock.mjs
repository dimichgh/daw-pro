// m23-ac-2c — staging teardown must not leave the USER a false crash recovery.
//
// WHAT THIS GUARDS. Gates stop the staging app with SIGTERM, which skips the
// app's clean-exit path, so the `session.lock` it wrote at launch survives the
// gate. At the next real launch DAW Pro reads that lock and offers to recover
// from a crash that never happened. Measured before the fix: a bare `m23d` run
// left `{"pid":43172}` behind in the user's own profile directory.
//
// ⚠️ THIS GATE REASONS ABOUT THE LOCK FILE. The ownership check in
// `releaseSessionLock` is the entire safety property — the same file name is
// written by the user's LIVE app on port 17600, in their own profile. So the
// legs below split deliberately:
//
//   Leg A drives a real launch end-to-end, because that is the only way to prove
//         the lifecycle actually cleans up. A temp-path-only suite passes
//         perfectly while production cleans nothing.
//   Legs B-F drive `releaseSessionLock` DIRECTLY against a TEMP path. They must
//         never go through `stopStaging`, because `stopStaging` SIGTERMs the pid
//         it finds in the pidfile — a test that fabricates a pidfile to exercise
//         the ownership check would be a test that signals an invented pid.
//
// ── UPDATED AT m23-ay ────────────────────────────────────────────────────────
// Leg A used to assert that a staging launch wrote its lock into the USER'S REAL
// `~/Library/Application Support/DAWPro/Autosave/`, and that teardown removed it
// from there. That was an accurate description of the app — and the defect
// m23-ay fixed: a staging instance now gets its own profile root
// (`DAWPRO_PROFILE_ROOT`, set for every launch by `_staging.mjs`), so the lock is
// written and cleaned under THAT root and the user's file is never created,
// read, or removed by a gate at all.
//
// So leg A now drives the staging profile's lock, and gains leg G: the user's
// real lock must be untouched by the whole launch/teardown cycle — the stronger
// form of the property this gate was filed for. The DEFAULT (no-override)
// spelling that leg A used to prove end-to-end is still pinned, by leg F here
// and by `AppDirectoriesProfileRootTests` on the Swift side.
//
// Run: node scripts/gates/m23ac2c-session-lock.mjs
import fs from "node:fs";
import net from "node:net";
import {
  ROOT, LIVE_PORT, STAGING_PORT,
  buildOrAbort, startStaging, stopStaging, connect,
  sessionLockPath, stagingSessionLockPath, releaseSessionLock, sleep,
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

  // Leg F — the DEFAULT (no-override) path is the app's real one. Since m23-ay
  // no gate LAUNCH goes there any more, which makes this the only place the
  // real-profile spelling is pinned on the JS side: it must still match the way
  // `DAWCore.AppDirectories` spells it, or an app running WITHOUT the override
  // (the shipped one) would be looked for in the wrong place.
  const def = sessionLockPath();
  ck("F default path is the app's Autosave lock",
    def === `${process.env.HOME}/Library/Application Support/DAWPro/Autosave/session.lock`, def);
  ck("F an override wins over the default", sessionLockPath("/tmp/x.json") === "/tmp/x.json");
}

// ── Legs A + G: a real launch, on the staging profile's path ────────────────

async function realPathLeg() {
  const real = sessionLockPath(); // the USER'S lock — read only, never written

  // Refuse to run over the user's live app. Since m23-ay a staging launch can no
  // longer overwrite their lock, but leg G below compares that file before and
  // after, and their own app rewrites it — the comparison would be measuring
  // them, not us.
  if (await portBusy(LIVE_PORT)) {
    ck(`A ABORT: something is listening on ${LIVE_PORT} (the user's live app)`, false,
      "refusing to run — leg G's before/after comparison would be measuring their app");
    return;
  }
  ck(`A the user's live port ${LIVE_PORT} is free`, true);

  // Leg G's "before". `null` when absent — recorded as a value, so absent-stays-
  // absent is asserted as explicitly as present-stays-identical.
  const realBefore = exists(real) ? fs.readFileSync(real, "utf8") : null;

  buildOrAbort();
  const { pid, profileRoot } = startStaging({
    gate: GATE, root: ROOT, port: STAGING_PORT, binary: BINARY, pidfile: PIDFILE,
    outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
  });
  console.log(`staging pid ${pid} on :${STAGING_PORT}, profile root ${profileRoot}`);
  // Where THIS instance's lock lives (m23-ay): under the profile root the
  // harness handed it, not in the user's Autosave directory.
  const staged = stagingSessionLockPath(profileRoot);

  try {
    const ws = await connect({ port: STAGING_PORT });
    ws.close();
    await sleep(500);

    // NON-VACUITY for the whole leg: if the app never writes a lock, "no lock
    // survives teardown" is true for the wrong reason and this gate would
    // certify a fix that does nothing.
    let owner = null;
    try { owner = Number(JSON.parse(fs.readFileSync(staged, "utf8")).pid); } catch {}
    ck("A the running app DID write a lock, owned by our staging pid",
      owner === pid, `lock ${staged} pid ${owner}, staging pid ${pid}`);
  } finally {
    stopStaging(GATE, PIDFILE);
  }

  await sleep(800);
  ck("A no session.lock survives teardown", !exists(staged),
    exists(staged) ? `SURVIVED: ${fs.readFileSync(staged, "utf8")}` : "gone");

  // Leg G (m23-ay) — the property this gate was really filed for, in its
  // strongest form: not "the gate cleans up after itself in the user's profile"
  // but "the gate never touched the user's profile at all".
  const realAfter = exists(real) ? fs.readFileSync(real, "utf8") : null;
  ck("G the USER's own session.lock is untouched by the launch/teardown cycle",
    realBefore === realAfter,
    `${real}: before=${JSON.stringify(realBefore)} after=${JSON.stringify(realAfter)}`);
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
