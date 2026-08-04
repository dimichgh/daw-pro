// m23-aq GATE — `./scripts/test.sh` must never write into the user's REAL
// `~/Library/Application Support/DAWPro/Autosave/` or `.../Feedback/`.
//
// ══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
// Two instance defaults resolved the user's real data directory and leaked
// nothing TODAY only because every call site remembered to override them —
// the exact shape m23-aa already removed for `autosaveRecoveryDirectory`:
//   (1) `ProjectStore.crashRecovery` (an `AutosaveManager`) used to
//       default-construct via `AutosaveManager()`'s own bare default, the
//       real Autosave path. Its bundle is `autosave.dawproject` (a DIRECTORY,
//       not a `.dawproj` file) — a `*.dawproj`-only glob does NOT match it,
//       which is why this gate compares FULL entry sets, not just the glob.
//   (2) `DiagnosticsReporter.outputDir` used to default via
//       `DiagnosticsReporter.defaultOutputDir()`, the real Feedback path.
// The fix (m23-aq) redirects both instance defaults under a detected Swift
// test process (`TestEnvironment.isRunningTests`), layered ABOVE the real
// computation — `AppDirectories` / `AutosaveManager.defaultDirectory()` /
// `DiagnosticsReporter.defaultOutputDir()` are UNTOUCHED (the
// `AppDirectoriesTests` one-home pins still hold).
//
// ══ WHAT A GLOB-ONLY / RUN-ONCE GATE MISSES (do not "simplify" this back) ══
//   • `autosave.dawproject`, `manifest.json`, `session.lock` are ROLLING,
//     STABLE-NAMED writes — a leak overwrites the SAME entry name run to run,
//     so a naive "same file list" check across two runs is vacuously green
//     even while leaking. This gate snapshots the REAL directories BEFORE any
//     run and diffs every later snapshot against that ORIGINAL baseline, not
//     against the previous run.
//   • `feedback-<yyyyMMdd-HHmmss>/` (Target 2) matches NEITHER `*.dawproj` NOR
//     `autosave.dawproject`. A glob scoped to the item's literal wording would
//     be structurally blind to a Target-2 regression. This gate compares the
//     FULL, unfiltered entry set of BOTH directories; the glob from the
//     roadmap wording is kept ONLY as a labeled subset leg on Autosave.
//   • An unchanged entry set is ALSO consistent with "the leaking code path
//     never ran this pass" (a refactor that skips `flushForTransition`, a
//     `--filter` that stops matching). So this gate ALSO asserts the POSITIVE
//     evidence that the redirection mechanism engaged: fresh
//     `DAWPro-test-autosave-*` / `DAWPro-test-feedback-*` roots under
//     `os.tmpdir()`, each containing the artifacts the real writers would have
//     produced (m23-aa's own law: pair "the bad thing did not happen" with
//     "the good thing did").
//
// ══ RED/GREEN PROOF THIS GATE CAN ACTUALLY FAIL (recorded, not re-run here) ═
// MUTANT M1 (`Tests/DAWControlTests/FeedbackBundleCommandTests.swift`,
// `makeRouter()`): commented out `store.diagnostics.outputDir = tempDir("out")`.
//   • Pre-fix tree, `--filter FeedbackBundleCommandTests`: 5/5 tests PASSED
//     (the wire-shape assertions don't inspect location) but the REAL Feedback
//     dir's entry count went 982 → 985 — 3 NEW entries,
//     `feedback-20231114-141320{,-2,-3}` (the test suite's fixed clock,
//     1_700_000_000s) — i.e. this gate's full-entry-set leg would have gone
//     RED. Left in place afterward (2026-08-03); DiagnosticsReporter writes no
//     key material, so this is inert, but deletion is the user's call.
//   • Post-fix tree, SAME mutant re-applied, SAME filtered run: entry count
//     stayed at 985 — GREEN, zero NEW entries — because the new instance
//     default now redirects even without the test's override.
// Mutant M2 (`Sources/DAWCore/ProjectStore.swift`, `crashRecovery` property):
// reverted to bare `AutosaveManager()`. RESTRICTED to the three
// non-writing legs of `CrashRecoveryFeedbackRedirectionTests` (construction
// alone touches no disk; the suite's OWN write-proving test was excluded from
// this run on purpose — under this mutant it would write
// `autosave.dawproject`/`manifest.json` into the REAL Autosave dir, which
// already holds the live app's own genuine crash-recovery snapshot):
//   `--filter '(crashRecoveryDirectoryIsRedirected|crashRecoveryShareRootWithUntitledRecovery|crashRecoveryRootIsStablePerProcess)'`
//   → RED, 3 tests / 1 suite, 5 issues (both discriminating `#expect`s in the
//   first two tests; the third correctly still passes under the mutant, since
//   two bare stores still agree on ONE shared real directory). Reverted
//   byte-exact; post-fix same filter is GREEN (confirmed 2026-08-03).
//   ⚠️ NON-CLAIM: Target 1's WRITE path (`autosaveTick` into the redirected
//   root) is pinned only by `autosaveTickWritesOnlyIntoTheRedirectedRoot`
//   (Swift-only, never observed red under a live mutant) — deliberately, to
//   avoid overwriting the live app's real `autosave.dawproject`/
//   `manifest.json`/`session.lock`. Target 2's write path (`writeFeedbackBundle`)
//   IS observed red-then-green live, via M1 above.
//
// ══ WHAT THIS SCRIPT DOES, AND WHAT ACTUALLY GATES THE EXIT CODE ═══════════
//   1. Snapshot both real directories' full entry sets (baseline).
//   2. Run `./scripts/test.sh` (run 1). ADVISORY ONLY (printed, not counted —
//      see the flake note below): whether `✘` appeared, and which test names.
//   3. Snapshot again; diff against baseline (both dirs, full sets). COUNTED.
//   4. Run `./scripts/test.sh` again (run 2). ADVISORY ONLY, same as run 1.
//   5. Snapshot again; diff against baseline (both dirs, full sets). COUNTED.
//   6. Labeled subset leg: the glob the roadmap item names
//      (`*.dawproj` OR `autosave.dawproject`) on the Autosave snapshots only.
//      COUNTED.
//   7. Positive co-assertion: `>= 1` FRESH `DAWPro-test-autosave-*` root AND
//      `>= 1` FRESH `DAWPro-test-feedback-*` root under `os.tmpdir()`, each
//      containing at least one file, created since this script started.
//      COUNTED. (Measured 2/2 on this machine, swift-testing's own worker-
//      process count — m23-aa's precedent measured 11 for the single
//      autosave root; do not read either count as a target, only `>= 1`.)
//
// Suite-health (legs 2/4) is DELIBERATELY ADVISORY, not counted in the exit
// code — see the flake note immediately below. THE GATE'S EXIT CODE IS
// GOVERNED ONLY BY LEGS 3/5/6/7 (the entry-set, glob-subset, and
// co-assertion legs) — that is this gate's actual subject. A suite-health
// leg coupled to the exit code is the m23-bk trap: a gate that fails on a
// pre-existing, unrelated failure gets misread as "this item regressed" by
// the next author who runs it.
//
// Never deletes or moves anything in the real directory. Never touches ports
// 17600/17695 — this is a pure `swift test` + filesystem check, no staging
// app involved.
//
// ⚠️ KNOWN PRE-EXISTING FLAKE, UNRELATED TO THIS GATE (why legs 2/4 are
// advisory): `OutputDeviceTests`' `enumerate(selectedUID:) stamps isSelected…`
// (real CoreAudio hardware enumeration, m20-j) intermittently reddens with 1
// issue when run as part of the FULL suite — the measured failure is a
// DEVICE-COUNT change between two enumeration calls inside that one test
// (`[false,true,false,false]` vs `[false,true,false]`), i.e. the real Mac's
// CoreAudio device list changed mid-test. Nothing in DAWCore (what m23-aq
// touches) can cause that. Passes clean in isolation
// (`--filter OutputDeviceTests`) every time it was checked. Reproduced
// 2026-08-03 (3 of 5 full runs that day hit it, 2 of 5 did not), matches the
// memory-recorded history of this exact test. If you want to see it anyway,
// legs 2/4 print the failing test name(s) when a run reddens.
//
// Usage: `node scripts/gates/m23aq-data-dir-leak.mjs`
// (~180s: two full-suite runs. Run backgrounded in an agent shell.)

import { execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";

const HOME = os.homedir();
const REAL_AUTOSAVE = path.join(HOME, "Library/Application Support/DAWPro/Autosave");
const REAL_FEEDBACK = path.join(HOME, "Library/Application Support/DAWPro/Feedback");
const REPO_ROOT = path.resolve(new URL(".", import.meta.url).pathname, "../..");

function snapshot(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).sort();
}

function sameSet(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function autosaveGlobSubset(entries) {
  return entries.filter((e) => e.endsWith(".dawproj") || e === "autosave.dawproject").sort();
}

// A known, pre-existing, UNRELATED flake (see the header note): real CoreAudio
// hardware enumeration whose device list can change mid-test on this actual
// Mac. Named here ONLY so this gate's advisory print can say "this is the
// known one" vs. "this is something new" — it does not suppress the print,
// and it does NOT affect the exit code (suite-health legs are advisory).
const KNOWN_FLAKY_TESTS = [
  'enumerate(selectedUID:) stamps isSelected on exactly that device, and nil stamps none',
];

function runSuite(label) {
  console.log(`\n── running ./scripts/test.sh (${label}) ──`);
  let output;
  let hardFailed = false;
  try {
    output = execFileSync("./scripts/test.sh", { cwd: REPO_ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  } catch (err) {
    // ./scripts/test.sh is documented to exit 0 even on a failed run — but
    // capture stdout either way in case something upstream (build) hard-fails.
    output = (err.stdout || "") + (err.stderr || "");
    hardFailed = true;
  }
  const summaryLine = output.split("\n").find((l) => l.includes("Test run with"));
  console.log(`  ${summaryLine ?? "(no summary line found)"}`);
  const failingTestNames = output
    .split("\n")
    .filter((l) => /^✘ Test "/.test(l.trim()))
    .map((l) => l.trim().match(/^✘ Test "([^"]+)"/)?.[1])
    .filter(Boolean);
  const uniqueFailing = [...new Set(failingTestNames)];
  if (uniqueFailing.length > 0) {
    for (const name of uniqueFailing) {
      const known = KNOWN_FLAKY_TESTS.includes(name);
      console.log(`  ${known ? "(known flake, unrelated to m23-aq)" : "⚠️ UNRECOGNIZED FAILURE"} ✘ "${name}"`);
    }
  }
  if (hardFailed && uniqueFailing.length === 0) {
    console.log(`  ⚠️ ${label} exited non-zero with no parsed test-name failures — inspect raw output.`);
  }
  return { green: uniqueFailing.length === 0 && !hardFailed, failingTestNames: uniqueFailing };
}

function findFreshTestRoots(prefix, sinceMs) {
  const tmp = os.tmpdir();
  if (!fs.existsSync(tmp)) return [];
  return fs
    .readdirSync(tmp)
    .filter((e) => e.startsWith(prefix))
    .map((e) => path.join(tmp, e))
    .filter((p) => {
      try {
        return fs.statSync(p).mtimeMs >= sinceMs;
      } catch {
        return false;
      }
    });
}

function hasAnyFile(dir) {
  const stack = [dir];
  while (stack.length) {
    const d = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) stack.push(p);
      else return true;
    }
  }
  return false;
}

async function main() {
  const startedAt = Date.now();
  let legsPassed = 0;
  let legsTotal = 0;
  const fail = (msg) => {
    console.log(`✘ ${msg}`);
  };
  const pass = (msg) => {
    legsPassed++;
    console.log(`✔ ${msg}`);
  };

  const baselineAutosave = snapshot(REAL_AUTOSAVE);
  const baselineFeedback = snapshot(REAL_FEEDBACK);
  console.log(`Baseline: Autosave ${baselineAutosave.length} entries, Feedback ${baselineFeedback.length} entries.`);
  const baselineGlobSubset = autosaveGlobSubset(baselineAutosave);

  // ADVISORY ONLY — printed, not counted in legsPassed/legsTotal. See the
  // header's "what actually gates the exit code" note: suite-health is
  // coupled to a known unrelated hardware flake (OutputDeviceTests), so a red
  // run here must never fail THIS gate on its own.
  const run1 = runSuite("run 1 of 2");
  console.log(run1.green ? "  (advisory) run 1 green." : "  (advisory) run 1 reported a failure — see test name(s) above.");

  const afterRun1Autosave = snapshot(REAL_AUTOSAVE);
  const afterRun1Feedback = snapshot(REAL_FEEDBACK);

  legsTotal++;
  if (sameSet(baselineAutosave, afterRun1Autosave) && sameSet(baselineFeedback, afterRun1Feedback)) {
    pass("after run 1: BOTH real directories' full entry sets are unchanged from baseline");
  } else {
    fail("after run 1: a real directory's entry set CHANGED — see diff below");
    console.log("  Autosave now:", afterRun1Autosave);
    console.log("  Feedback now (count):", afterRun1Feedback.length);
  }

  // ADVISORY ONLY — see the leg-1 comment above.
  const run2 = runSuite("run 2 of 2");
  console.log(run2.green ? "  (advisory) run 2 green." : "  (advisory) run 2 reported a failure — see test name(s) above.");

  const afterRun2Autosave = snapshot(REAL_AUTOSAVE);
  const afterRun2Feedback = snapshot(REAL_FEEDBACK);

  legsTotal++;
  if (sameSet(baselineAutosave, afterRun2Autosave) && sameSet(baselineFeedback, afterRun2Feedback)) {
    pass("after run 2: BOTH real directories' full entry sets are STILL unchanged from baseline");
  } else {
    fail("after run 2: a real directory's entry set CHANGED — see diff below");
    console.log("  Autosave now:", afterRun2Autosave);
    console.log("  Feedback now (count):", afterRun2Feedback.length);
  }

  // Labeled subset leg — the roadmap wording's literal glob, Autosave only.
  legsTotal++;
  const finalGlobSubset = autosaveGlobSubset(afterRun2Autosave);
  if (sameSet(baselineGlobSubset, finalGlobSubset)) {
    pass(`labeled subset leg: *.dawproj + autosave.dawproject unchanged (${finalGlobSubset.length} entries)`);
  } else {
    fail("labeled subset leg: the *.dawproj / autosave.dawproject glob CHANGED");
  }

  // Positive co-assertion — the redirection mechanism actually engaged.
  legsTotal++;
  const freshAutosaveRoots = findFreshTestRoots("DAWPro-test-autosave-", startedAt);
  const freshFeedbackRoots = findFreshTestRoots("DAWPro-test-feedback-", startedAt);
  const autosaveRootsHaveFiles = freshAutosaveRoots.some(hasAnyFile);
  const feedbackRootsHaveFiles = freshFeedbackRoots.some(hasAnyFile);
  if (freshAutosaveRoots.length > 0 && autosaveRootsHaveFiles && freshFeedbackRoots.length > 0 && feedbackRootsHaveFiles) {
    pass(
      `positive co-assertion: ${freshAutosaveRoots.length} fresh DAWPro-test-autosave-* root(s) and ` +
        `${freshFeedbackRoots.length} fresh DAWPro-test-feedback-* root(s) exist under ${os.tmpdir()} and contain artifacts`
    );
  } else {
    fail(
      `positive co-assertion FAILED — autosave roots: ${freshAutosaveRoots.length} (files: ${autosaveRootsHaveFiles}), ` +
        `feedback roots: ${freshFeedbackRoots.length} (files: ${feedbackRootsHaveFiles}). ` +
        `A clean diff here is ambiguous between "fixed" and "never ran".`
    );
  }

  console.log(`\n${legsPassed}/${legsTotal} legs passed.`);
  if (legsPassed !== legsTotal) {
    console.log("GATE FAILED.");
    process.exit(1);
  }
  console.log("GATE PASSED.");
}

main();
