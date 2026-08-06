// m23-ay GATE — a gate run must not write into the USER'S OWN
// `~/Library/Application Support/DAWPro/`.
//
// ── THE DEFECT THIS PINS ─────────────────────────────────────────────────────
// Every staging instance a gate launched used to resolve
// `DAWCore.AppDirectories.applicationSupport(…)` to the user's real profile,
// because nothing overrode it. So a gate run shared the autosave, recordings,
// generations, references and feedback directories with the person using the
// app. Two measured consequences, not hypotheses:
//   • a staging launch WRITES `Autosave/session.lock` (crash detection) —
//     m23-ay recorded it replacing the live app's lock (pid 37057's), which
//     corrupts the user's crash state with no teardown that can undo it;
//   • `pruneUntitledRecoveryBundles()` runs at launch and DELETES the older
//     `Untitled-*.dawproj` recovery bundles it finds — the user's, in that
//     directory.
// The fix is `DAWPRO_PROFILE_ROOT` (`Sources/DAWCore/AppDirectories.swift`),
// set for every launch by `_staging.mjs`. This gate is that fix's acceptance
// criterion.
//
// ── ⚠️⚠️ THIS GATE IS READ-ONLY ON THE USER'S PROFILE ────────────────────────
// It NEVER writes, moves, creates or deletes anything under
// `~/Library/Application Support/DAWPro/`. The snapshot is `readdir` + `lstat`
// only — names, sizes, mtimes, and the mtime of every directory including the
// root (a directory mtime is what changes when a file is added or removed
// inside it, and it is the signal that first exposed this defect). Nothing here
// opens a file for writing or reads file CONTENTS from that tree; not even a
// hash, because 1.5 GB of Generations is not ours to churn.
//
// ── ⚠️ WHY THE CONTROLS ARE NOT OPTIONAL ─────────────────────────────────────
// "The user's profile did not change" passes TRIVIALLY if the staging app never
// wrote anywhere at all — a gate in that shape cannot tell "isolated" from
// "did nothing", and would certify a broken launch as a clean bill of health.
// So three independent control families run, each able to go red on its own:
//
//   CTL (differ controls) — the snapshot/diff primitive is proven to DETECT an
//   added file, a size change, an mtime-only touch and a deletion, on a
//   synthetic tree the gate owns. Same functions, same call shape as the real
//   comparison. Without these, a differ that always answers "identical" would
//   pass the headline check for free.
//
//   CTL6 (non-vacuity of the subject) — the user's real profile must actually
//   have contents. Comparing an absent directory to an absent directory is a
//   green that means nothing.
//
//   POS (positive controls) — the staging instance must be PROVEN to have
//   written, to its overridden root: its `session.lock` owned by its own pid,
//   an autosave bundle, a rolling crash snapshot and a feedback bundle. Two of
//   these are asserted from paths the APP ITSELF reports over the wire
//   (`project.recoveryBundles`, `app.feedbackBundle`), which is stronger than
//   finding a file: it proves the app resolved its own directories through the
//   override rather than us finding something that happened to be there.
//
// ── WHAT IS DELIBERATELY NOT HERE ────────────────────────────────────────────
// "With the override ABSENT the app still resolves the REAL path" is the other
// half of the roadmap item, and it CANNOT be a leg of this gate: proving it
// live means launching a staging instance with no override, which writes into
// the user's real profile — the exact harm. It is proven instead, without any
// process writing anywhere, by
// `Tests/DAWCoreTests/AppDirectoriesProfileRootTests.swift`
// (`absentOverrideLeavesEveryCategoryOnTheRealPath`, plus the refusal suite
// that stops an unusable override from silently degrading into "absent").
//
// Staging 17695 ONLY; 17600 is the user's LIVE app and is never touched
// (`assertStagingPort` enforces it). Staging is killed PIDFILE-EXACT via
// `stopStaging`, never pkill/pgrep.
//
// Usage: node scripts/gates/m23ay-profile-isolation.mjs
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import {
  LIVE_PORT, STAGING_PORT, REAL_PROFILE_BASE,
  launchStaging, stopStaging, profileCategoryDir, stagingSessionLockPath,
  stagingProfileRoot, sleep,
} from "./_staging.mjs";

const GATE = "m23ay";
const PORT = Number(process.env.DAW_CONTROL_PORT || STAGING_PORT);
const OUT = process.env.M23AY_OUT || `/tmp/daw-gate-out/${GATE}`;
const PIDFILE = process.env.M23AY_PIDFILE || `${OUT}/staging.pid`;
const BINARY = process.env.M23AY_BINARY || ".build/debug/DAWApp";
const REAL_PROFILE = `${REAL_PROFILE_BASE}/DAWPro`;
// How long to wait for the 30-s rolling crash-autosave tick
// (`ProjectStore.startCrashAutosave`) to land its snapshot.
const CRASH_AUTOSAVE_WAIT_MS = Number(process.env.M23AY_AUTOSAVE_WAIT_MS || 38_000);

fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 300_000);

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};

// ── the snapshot primitive ───────────────────────────────────────────────────
// READ-ONLY. `readdirSync` + `lstatSync`; no file is opened, no content is read.
// `lstat`, not `stat`, so a symlink is recorded as a symlink rather than
// followed out of the tree.
function snapshot(dir) {
  const entries = new Map();
  const record = (rel, abs) => {
    let st;
    try { st = fs.lstatSync(abs); } catch (e) { entries.set(rel, `UNREADABLE ${e.code}`); return null; }
    if (st.isSymbolicLink()) {
      let target = "?";
      try { target = fs.readlinkSync(abs); } catch { /* recorded as ? */ }
      entries.set(rel, `symlink -> ${target}`);
    } else if (st.isDirectory()) {
      // The directory's OWN mtime is recorded: it is what changes when a file
      // is created or removed inside it, and it is how a staging launch's
      // `session.lock` announced itself in the user's Autosave directory.
      entries.set(rel, `dir mtime=${st.mtimeMs}`);
    } else {
      entries.set(rel, `file size=${st.size} mtime=${st.mtimeMs}`);
    }
    return st;
  };
  const st = record(".", dir);
  if (!st || !st.isDirectory()) return entries;
  const walk = (rel) => {
    const abs = rel === "." ? dir : path.join(dir, rel);
    let listing;
    try { listing = fs.readdirSync(abs, { withFileTypes: true }); }
    catch (e) { entries.set(`${rel}/*`, `UNLISTABLE ${e.code}`); return; }
    for (const entry of listing.sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const childRel = rel === "." ? entry.name : `${rel}/${entry.name}`;
      const childSt = record(childRel, path.join(dir, childRel));
      if (childSt && childSt.isDirectory() && !childSt.isSymbolicLink()) walk(childRel);
    }
  };
  walk(".");
  return entries;
}

/** Human-readable differences, empty when identical. */
function diff(before, after) {
  const out = [];
  for (const [key, value] of before) {
    if (!after.has(key)) out.push(`REMOVED  ${key}  (was ${value})`);
    else if (after.get(key) !== value) out.push(`CHANGED  ${key}  ${value} -> ${after.get(key)}`);
  }
  for (const key of after.keys()) if (!before.has(key)) out.push(`ADDED    ${key}  (${after.get(key)})`);
  return out;
}

/** Total files + bytes under `dir`, from a snapshot. */
function volume(snap) {
  let files = 0, bytes = 0;
  for (const value of snap.values()) {
    const m = /^file size=(\d+)/.exec(value);
    if (m) { files += 1; bytes += Number(m[1]); }
  }
  return { files, bytes, entries: snap.size };
}

/** Is anything listening on `port`? */
const portBusy = (port) =>
  new Promise((res) => {
    const s = net.connect({ host: "127.0.0.1", port }, () => { s.destroy(); res(true); });
    s.on("error", () => res(false));
    setTimeout(() => { s.destroy(); res(false); }, 1500);
  });

// ══ PRECONDITION — refuse to measure while the user's app is running ════════
// Not a check, an ABORT (exit 2), and BEFORE anything is snapshotted or
// launched. Two reasons, and the first is the one that matters:
//   • the user's own app autosaves into that profile every 30 s, so a
//     before/after comparison run alongside it would go red because of THEM.
//     A red that means "someone else wrote" is a different defect from "we
//     wrote", and a gate that cannot tell them apart is a gate that gets
//     ignored.
//   • m23-bl: a failed precondition must not certify its dependents. Exiting
//     here means no downstream check reports a colour at all.
if (await portBusy(LIVE_PORT)) {
  console.log(`ABORT: something is listening on ${LIVE_PORT} — the user's live app is running.`);
  console.log("This gate compares their profile directory before and after, and their own app "
    + "writes into it on a 30-s autosave loop. Re-run when it is closed.");
  clearTimeout(killer);
  process.exit(2);
}

// ══ CTL — prove the differ DETECTS change, on a tree we own ═════════════════
{
  const ctl = fs.mkdtempSync(path.join(OUT, "differ-control-"));
  fs.writeFileSync(path.join(ctl, "keep.txt"), "one");
  fs.mkdirSync(path.join(ctl, "sub"));
  fs.writeFileSync(path.join(ctl, "sub", "nested.txt"), "two");
  const base = snapshot(ctl);

  check("CTL0 the differ reports NO difference for an untouched tree — the shape every "
        + "assertion below relies on; if this were red, a green headline would mean nothing",
        diff(base, snapshot(ctl)).length === 0,
        `entries=${base.size}`);

  fs.writeFileSync(path.join(ctl, "added.txt"), "three");
  const added = diff(base, snapshot(ctl));
  check("CTL1 an ADDED file is detected (this is the `session.lock` case — the exact shape of "
        + "the defect: one new file appearing in a directory that was not ours to write in)",
        added.some((d) => d.startsWith("ADDED") && d.includes("added.txt")),
        JSON.stringify(added));

  const grown = snapshot(ctl);
  fs.writeFileSync(path.join(ctl, "keep.txt"), "one-but-longer");
  const changed = diff(grown, snapshot(ctl));
  check("CTL2 a CONTENT change is detected via size (an overwritten file — the `session.lock` "
        + "REPLACEMENT case, which adds and removes nothing)",
        changed.some((d) => d.startsWith("CHANGED") && d.includes("keep.txt")),
        JSON.stringify(changed));

  const beforeTouch = snapshot(ctl);
  const future = new Date(Date.now() + 120_000);
  fs.utimesSync(path.join(ctl, "sub", "nested.txt"), future, future);
  const touched = diff(beforeTouch, snapshot(ctl));
  check("CTL3 an MTIME-ONLY touch is detected, in a SUBdirectory (same bytes, same size — "
        + "this is what a rewritten-with-identical-content lock looks like, and a size-only "
        + "differ would call it identical)",
        touched.some((d) => d.startsWith("CHANGED") && d.includes("nested.txt")),
        JSON.stringify(touched));

  const beforeDelete = snapshot(ctl);
  fs.rmSync(path.join(ctl, "added.txt"));
  const removed = diff(beforeDelete, snapshot(ctl));
  check("CTL4 a DELETED file is detected (the `pruneUntitledRecoveryBundles()` case — the "
        + "staging app deletes the user's older recovery bundles at launch, which no "
        + "additions-only check would ever see)",
        removed.some((d) => d.startsWith("REMOVED") && d.includes("added.txt")),
        JSON.stringify(removed));

  check("CTL5 the containing DIRECTORY's own mtime moved when that file was deleted — the "
        + "signal that first exposed this defect (the user's Autosave directory carried a fresh "
        + "mtime after a gate run) and the only one that survives a write which leaves no file "
        + "behind, e.g. a lock created and then removed by teardown",
        removed.some((d) => /^CHANGED {2}\. {2}dir mtime=/.test(d)),
        JSON.stringify(removed));

  fs.rmSync(ctl, { recursive: true, force: true });
}

// ══ CTL5 — the SUBJECT is non-vacuous ══════════════════════════════════════
const before = snapshot(REAL_PROFILE);
const beforeVolume = volume(before);
check("CTL6 the user's real profile actually has contents — comparing an absent or empty "
      + "directory to itself is a green that means nothing. This is the anti-vacuity check for "
      + "the SUBJECT, as CTL0-CTL4 are for the INSTRUMENT",
      beforeVolume.entries > 1 && beforeVolume.files > 0,
      `${REAL_PROFILE}: ${beforeVolume.entries} entries, ${beforeVolume.files} files, `
      + `${(beforeVolume.bytes / 1e9).toFixed(2)} GB`);

// The root the harness will hand the child BY DEFAULT (memoised per process),
// read — not chosen — so it can be snapshotted while it is still empty. The
// launch below still passes no `profileRoot`, so the default path is what is
// under test; this only lets POS8 compare the same directory before and after.
const plannedRoot = stagingProfileRoot();
const rootBefore = snapshot(plannedRoot);
// `startStaging` opens the log APPEND-only, so a previous run's announcement
// would still be in it. ISO2 would still be sound (the root is a fresh mkdtemp
// each run, so a stale line cannot contain it) but its evidence would be
// ambiguous to read, which is its own kind of defect in a gate.
fs.rmSync(`${OUT}/staging.log`, { force: true });

let staging = null;
let profileRoot = null;
try {
  // NO `profileRoot` is passed. That is the point: isolation must be what
  // `_staging.mjs` does BY DEFAULT, or every existing gate is still writing into
  // the user's profile and only this one is clean.
  staging = await launchStaging({
    gate: GATE, port: PORT, binary: BINARY, pidfile: PIDFILE, outDir: OUT,
    detached: true, settleMs: 1500, logPath: `${OUT}/staging.log`,
  });
  profileRoot = staging.profileRoot;
  console.log(`staging pid ${staging.pid} on :${PORT}, profile root ${profileRoot}`);

  // Either spelling counts: macOS `/var` and `/tmp` are symlinks, and the Swift
  // side deliberately does not resolve them (so the app writes under exactly the
  // root it was handed), while some paths come back realpath'd.
  const realRoot = (() => { try { return fs.realpathSync(profileRoot); } catch { return profileRoot; } })();
  const under = (p, root) => {
    if (typeof p !== "string" || !p.length) return false;
    const rp = (() => { try { return fs.realpathSync(p); } catch { return p; } })();
    const roots = [root, (() => { try { return fs.realpathSync(root); } catch { return root; } })()];
    return roots.some((r) => p === r || p.startsWith(`${r}/`) || rp === r || rp.startsWith(`${r}/`));
  };

  check("ISO1 the harness gave the app an absolute profile root of its own, outside the user's "
        + "Application Support tree — asserted on the DEFAULT path, with the gate passing no "
        + "profileRoot, because every other gate in this directory takes that same path",
        typeof profileRoot === "string" && profileRoot.startsWith("/")
        && !under(profileRoot, REAL_PROFILE_BASE),
        `profileRoot=${profileRoot} realpath=${realRoot}`);

  const log = fs.existsSync(`${OUT}/staging.log`) ? fs.readFileSync(`${OUT}/staging.log`, "utf8") : "";
  // ⚠️ EXACT equality, parsed out of the line — not `log.includes(profileRoot)`.
  // Measured during this gate's own deliberate-failure run: with the harness
  // handing the app `<root>-DELIBERATE-M23AY-BREAKAGE`, a substring test PASSED,
  // because the wrong root contains the right one as a prefix. A check that
  // cannot tell "the app used my root" from "the app used something starting
  // with my root" is not a check.
  const announced = /DAWPRO_PROFILE_ROOT active — profile root (.+?) \(autosave: /.exec(log)?.[1];
  check("ISO2 the APP ITSELF announced the override on stderr (DAWCore.AppDirectories logs the "
        + "resolved root at first use) and the root it announced is EXACTLY the one the harness "
        + "handed it — proof the Swift side READ the variable, as distinct from us having merely "
        + "set it in the child's environment",
        announced === profileRoot,
        `announced=${JSON.stringify(announced ?? null)} expected=${JSON.stringify(profileRoot)}`);

  // ── the wire ──────────────────────────────────────────────────────────────
  let nextId = 1;
  const pending = new Map();
  staging.ws.onmessage = (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
    if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
    else e.resolve(m.result ?? m);
  };
  const req = (command, params = {}, timeoutMs = 30_000) => {
    const id = String(nextId++);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, command });
      staging.ws.send(JSON.stringify({ id, command, params }));
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, timeoutMs);
    });
  };

  // The lock is written at launch, before any command — check it first.
  const lockPath = stagingSessionLockPath(profileRoot);
  let lockOwner = null;
  try { lockOwner = JSON.parse(fs.readFileSync(lockPath, "utf8")).pid; } catch { /* reported below */ }
  check("POS1 the staging app wrote its crash-detection session.lock under ITS OWN profile "
        + "root, owned by its own pid — this is the exact file the defect put in the user's "
        + "Autosave directory, so finding it here (and, with A1 below, nowhere else) is the "
        + "single most direct statement of the fix",
        lockOwner === staging.pid,
        `${lockPath}: pid ${JSON.stringify(lockOwner)} vs staging pid ${staging.pid}`);

  // ── exercise: an autosave (untitled recovery bundle) ──────────────────────
  await req("project.new", { discardChanges: true });
  await req("track.add", { name: "m23ay probe", kind: "instrument" });
  // A dirty UNTITLED session transitioned via new/open flushes a recovery
  // bundle into the Autosave directory (`ProjectStore.flushForTransition` ->
  // `writeRecoveryBundle`). This is the write that produced the burst of
  // `Untitled-*.dawproj` files in the user's real profile.
  await req("project.new", { discardChanges: false });

  const bundles = await req("project.recoveryBundles");
  const bundleList = bundles.bundles ?? bundles.recoveryBundles ?? [];
  const bundlePaths = bundleList.map((b) => b.path ?? b);
  check("POS2 the app REPORTS its untitled-recovery bundles under the overridden root — read "
        + "back over the wire from project.recoveryBundles, so this is the app's own account of "
        + "where it wrote, not a file we went looking for",
        bundlePaths.length > 0
        && bundlePaths.every((p) => under(p, profileRoot))
        && bundlePaths.every((p) => !under(p, REAL_PROFILE)),
        JSON.stringify(bundlePaths));

  const autosaveDir = profileCategoryDir(profileRoot, "Autosave");
  const untitled = fs.existsSync(autosaveDir)
    ? fs.readdirSync(autosaveDir).filter((n) => n.startsWith("Untitled-") && n.endsWith(".dawproj"))
    : [];
  check("POS3 an Untitled-*.dawproj recovery bundle is on disk under the overridden Autosave "
        + "directory (the same claim as POS2, made against the filesystem rather than the wire — "
        + "a response can be right about a path the app never actually created)",
        untitled.length > 0,
        `${autosaveDir}: ${JSON.stringify(untitled)}`);

  // ── exercise: a save ──────────────────────────────────────────────────────
  const savePath = `${OUT}/m23ay-save.dawproj`;
  fs.rmSync(savePath, { recursive: true, force: true });
  await req("track.add", { name: "m23ay saved track", kind: "instrument" });
  const saved = await req("project.save", { path: savePath });
  check("POS4 an explicit save still works with the profile relocated — the override moves the "
        + "PROFILE, not the user's chosen destination, and a save that broke under it would make "
        + "every gate that saves useless",
        fs.existsSync(savePath),
        `${savePath} exists=${fs.existsSync(savePath)} response=${JSON.stringify(saved).slice(0, 160)}`);

  // ── exercise: the feedback bundle (the Feedback category) ────────────────
  const feedback = await req("app.feedbackBundle", {}, 60_000);
  check("POS5 app.feedbackBundle writes under the overridden root — a SECOND category "
        + "(Feedback), proving the override moves the whole profile and not just the one "
        + "directory the earlier checks happen to exercise. This is the directory that "
        + "accumulated 877 bundles / 195 MB of gate spill in the user's profile",
        typeof feedback.path === "string"
        && under(feedback.path, profileRoot) && !under(feedback.path, REAL_PROFILE)
        && fs.existsSync(feedback.path),
        `${feedback.path} (${feedback.fileCount} files, ${feedback.byteCount} bytes)`);

  // ── exercise: the rolling 30-s crash autosave ────────────────────────────
  // The one that runs unattended in every gate, on a timer nobody triggers.
  await req("track.add", { name: "m23ay dirty for the tick", kind: "instrument" });
  console.log(`waiting ${CRASH_AUTOSAVE_WAIT_MS} ms for the 30-s crash-autosave tick…`);
  await sleep(CRASH_AUTOSAVE_WAIT_MS);
  const rolling = path.join(autosaveDir, "autosave.dawproject");
  const manifest = path.join(autosaveDir, "manifest.json");
  check("POS6 the ROLLING crash autosave (ProjectStore.startCrashAutosave, 30 s) landed under "
        + "the overridden root — the writer no gate triggers deliberately and every gate leaves "
        + "running, so it is the one most likely to reach the user's profile unnoticed",
        fs.existsSync(rolling) && fs.existsSync(manifest),
        `autosave.dawproject=${fs.existsSync(rolling)} manifest.json=${fs.existsSync(manifest)} in ${autosaveDir}`);

} catch (e) {
  check("GATE did not throw", false, e?.stack ?? e?.message ?? String(e));
} finally {
  try { staging?.ws?.close(); } catch { /* best effort */ }
  await sleep(300);
  try { stopStaging(GATE, PIDFILE); } catch (e) { console.log("stopStaging: " + e?.message); }
  await sleep(1200);
}

// ══ POS7 — the whole point of a positive control ═══════════════════════════
const rootSnap = profileRoot ? snapshot(profileRoot) : new Map();
const rootVolume = volume(rootSnap);
check("POS7 the overridden profile root is NON-EMPTY after the run. Without this the headline "
      + "check below cannot tell 'isolated' from 'the app never wrote anything anywhere' — a "
      + "staging instance that failed to boot would pass A1 perfectly",
      rootVolume.files > 0 && rootVolume.bytes > 0,
      `${profileRoot}: ${rootVolume.entries} entries, ${rootVolume.files} files, ${rootVolume.bytes} bytes`);

// ⚠️ THE DISCRIMINATION PROOF FOR A1, and the reason A1 is not a gate that
// cannot fail. CTL0-CTL5 prove the instrument detects synthetic changes; this
// proves it detects THIS staging app's REAL writes, in the SAME run, on a
// directory of the same shape (a `DAWPro/<Category>` profile) using the SAME
// snapshot and diff functions. So when the identical instrument reports
// "identical" for the user's profile a few lines below, that is a measurement,
// not a tautology.
//
// The alternative — deliberately un-isolating a launch to watch A1 go red — is
// the one experiment this gate may never run: it would write into the user's
// real profile, which is the harm being fixed.
const rootDifferences = diff(rootBefore, rootSnap);
check("POS8 the SAME snapshot+diff instrument reports MANY differences for the directory this "
      + "staging app actually wrote to, measured before launch and after teardown — the "
      + "discrimination proof for A1: the instrument that calls the user's profile 'identical' "
      + "is demonstrably able to see a staging app's writes",
      rootDifferences.length > 0 && profileRoot === plannedRoot,
      `${rootDifferences.length} difference(s) under ${profileRoot}; planned=${plannedRoot}\n        `
      + rootDifferences.slice(0, 8).join("\n        "));

// ══ A — THE HEADLINE: the user's real profile is unchanged ═════════════════
const after = snapshot(REAL_PROFILE);
const differences = diff(before, after);
check("A1 the user's real ~/Library/Application Support/DAWPro/ is BYTE-FOR-BYTE unchanged "
      + "across the whole run — same entries, same sizes, same mtimes, including every "
      + "directory's own mtime. Measured after teardown, so it covers the teardown path too "
      + "(stopStaging's session-lock release used to run against this very tree)",
      differences.length === 0,
      differences.length === 0
        ? `${after.size} entries, identical`
        : `${differences.length} difference(s):\n        ` + differences.slice(0, 40).join("\n        "));

const realLock = `${profileCategoryDir(REAL_PROFILE_BASE, "Autosave")}/session.lock`;
const lockBefore = before.get("Autosave/session.lock");
const lockAfter = after.get("Autosave/session.lock");
check("A2 the user's OWN session.lock is exactly as it was (absent stays absent, present stays "
      + "byte-identical) — called out separately from A1 because this is the file the item was "
      + "filed about, and a failure here should name itself rather than hide in a diff list",
      lockBefore === lockAfter,
      `${realLock}: before=${JSON.stringify(lockBefore ?? "(absent)")} after=${JSON.stringify(lockAfter ?? "(absent)")}`);

const afterVolume = volume(after);
check("A3 the user's profile holds the same number of files and the same number of bytes "
      + "(a coarse, independently-computed restatement of A1 — if a subtle diff-key bug ever "
      + "made A1 blind, a changed file count or byte total would still surface here)",
      afterVolume.files === beforeVolume.files && afterVolume.bytes === beforeVolume.bytes
      && afterVolume.entries === beforeVolume.entries,
      `before ${beforeVolume.entries} entries / ${beforeVolume.files} files / ${beforeVolume.bytes} bytes; `
      + `after ${afterVolume.entries} entries / ${afterVolume.files} files / ${afterVolume.bytes} bytes`);

clearTimeout(killer);
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23AY ${pass}/${checks.length}`);
process.exit(pass === checks.length ? 0 : 1);
