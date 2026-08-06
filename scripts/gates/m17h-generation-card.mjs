// m17-h orchestrator gate — generation presence card seam matrix: bare-read
// law (A), import-origin seed (B), failed-row reason echoed verbatim (C),
// project snapshot carries ZERO card keys (D), bad-phase teaching error (E),
// clear verb (F), dead-sidecar wire generate -> boot narration (G).
// NOTES: card elapsed echoes as a formatted STRING ("0:33"), not a number —
// the echo has no raw-seconds field (DAWProApp.generationCardState), so leg
// B's elapsed check parses the m:ss/h:mm:ss string into seconds inline;
// leg B's capture call uses debug.captureUI (the only registered capture
// command). Both were PRE-EXISTING bugs in this gate's own logic (never app
// bugs) that made leg B permanently 2-fail, filed at m20-f and fixed here
// at m20-i.
// leg G requires the sidecar STOPPED on entry and kicks a REAL sidecar boot as
// its own test. (m23-az) Both are now handled BY THE GATE, not by a manual
// instruction a human has to remember to follow:
//   - the precondition is EXPLICIT: leg G queries ai.sidecarStatus first and
//     only runs when the sidecar is actually down (installedNotRunning /
//     notInstalled). A healthy/starting sidecar — the user's own, or left
//     behind by a prior run — makes leg G a LOUD SKIP instead: running it
//     would poison its own precondition, which is exactly how this gate went
//     false-idempotent (first run 12/0, every later run 10/2, PROVEN not the
//     gate-conversion's fault — the unconverted gate reproduced the same
//     10/2 in a healthy-sidecar environment).
//   - stopped-as-found is RESTORED automatically: if leg G is the one that
//     booted the sidecar, the gate kills that exact pid (read back from
//     ai.sidecarStatus, confirmed alive AND confirmed to actually be the
//     ACE-Step process via `ps -p <pid> -o args=` before the kill — never a
//     pid merely read from a pidfile) and confirms port 8001 is free
//     afterwards. If the sidecar was already up at entry, the gate never
//     kicked it and never touches it — it may be the user's own.
// A SKIP is counted separately from pass/fail and never folds into pass
// (m23-bj: a skip must not look like coverage that ran). Exit code reflects
// `fail` (m23-az defect (1): this gate used to `process.exit(0)`
// unconditionally regardless of pass/fail).
// (m23-az-1) m23-az's own restore message overclaimed. Two fixes, same file,
// no behaviour weakened: (a) "port 8001 free" is only evidence the port was
// ever OBSERVED bound — a monitor now watches from before the boot attempt
// through teardown and the restore line says plainly when it never saw a
// bind, instead of implying "free" means "was running and now is not".
// (b) SIGTERM only reaches the `uv run` PARENT; its python child (the one
// that actually holds the ~75 GB, per m23-bb's measured topology) can
// survive it. The pre-kill process tree is snapshotted with `ps -eo
// pid,ppid,args` (BEFORE the SIGTERM — reparenting to pid 1 afterwards
// destroys the ppid linkage), every transitive descendant is SIGTERM'd, and a
// confirmed survivor (args re-checked against the pre-kill capture, to guard
// against pid reuse) is escalated to SIGKILL after a bounded grace period.
// A pid whose args no longer match what was captured is left alone and
// reported, never killed on the strength of a stale identity.
// Staging: DAW_CONTROL_PORT=17695.
// Usage: node m17h-generation-card.mjs
// Output: captures land under /tmp/daw-gate-out/m17h-orch/ —
// `mkdir -p /tmp/daw-gate-out/m17h-orch` before running.
// Promoted from session scratchpad 2026-07-16 (m17-g).
// m23-ac-3a: was "class 3" — it never launched anything and drove whatever was
// on 17695. It now builds and launches its own instance. GATE is "m17h-orch" so
// that `startStaging` creates the SAME `/tmp/daw-gate-out/m17h-orch` this gate
// already writes its captures into; the "mkdir -p before running" note above is
// obsolete because the harness makes the directory.
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
import { spawnSync } from "node:child_process";

const GATE = "m17h-orch";
buildOrAbort({ label: "building staging binary (m17h)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0, pass = 0, fail = 0, skipped = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const i = `oh_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
function check(name, ok, detail = "") {
  if (ok) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.log(`FAIL ${name} :: ${detail}`); }
}
// m23-az: a skip is neither pass nor fail — it must never increment `pass`,
// or a SKIP re-creates the exact false-green this item exists to remove, just
// in a new costume. Mirrors the house convention in m20e-flip-path.mjs.
function skip(name, reason) {
  skipped++;
  console.log(`SKIP ${name} :: ${reason}`);
}

/** Port 8001 free/busy, checked with lsof (never touches ace-step files). */
function port8001Free() {
  const out = spawnSync("lsof", ["-i", ":8001"], { encoding: "utf8" });
  return (out.stdout ?? "").trim().length === 0;
}

// m23-az-1 gap (a): `port8001Free()` alone is only evidence when the port was
// ever BOUND — in both of m23-az's own runs the boot died before binding
// 8001, so "free" passed trivially, exactly as it would have if nothing had
// ever run. This flag turns "is it free right now" into "did we ever OBSERVE
// it bound, and is it free now" — a check that can actually discriminate.
// Started right before leg G kicks a boot attempt and stopped once the
// restore block is done, via a `setInterval` (unref'd so it can never itself
// keep the process alive if some path forgets to stop it).
let portObservedBoundDuringRun = false;
let portMonitorHandle = null;
function startPortMonitor(intervalMs = 300) {
  portMonitorHandle = setInterval(() => {
    if (!port8001Free()) portObservedBoundDuringRun = true;
  }, intervalMs);
  portMonitorHandle.unref();
}
function stopPortMonitor() {
  if (portMonitorHandle) { clearInterval(portMonitorHandle); portMonitorHandle = null; }
}
/** The honest sentence for whatever the monitor above observed — never implies more than it saw. */
function portEvidenceSummary() {
  if (!portObservedBoundDuringRun) {
    return "port 8001 was NEVER observed bound during this run — this run proves nothing about "
      + "shutdown via the port (the boot likely never got far enough to bind it); it is not the "
      + "same evidence as watching a bound port go free";
  }
  return port8001Free()
    ? "port 8001 WAS observed bound during this run and is free now"
    : "port 8001 WAS observed bound during this run and is STILL NOT FREE";
}

/**
 * Is `pid` alive, and does it actually look like the ACE-Step sidecar?
 * Never trust a pid read from a pidfile alone (m23-bb: pidfiles go stale and
 * the OS can reuse the number) — this is the confirmation gate the item
 * requires before any kill.
 */
function inspectPid(pid) {
  const out = spawnSync("ps", ["-p", String(pid), "-o", "args="], { encoding: "utf8" });
  const args = (out.stdout ?? "").trim();
  // scripts/ace-step/run.sh execs "uv run --no-sync acestep-api" (or the
  // acestep-api entry point directly) — NO separator between "ace" and
  // "step" in the actual process args. m23-az MEASURED this the hard way:
  // an earlier /ace[-_]step/i draft required a separator and refused to
  // kill a pid it had just correctly identified, leaking a real boot.
  return { alive: out.status === 0 && args.length > 0, args, looksLikeAceStep: /ace[-_]?step/i.test(args) };
}

/**
 * Full process-table snapshot: `[{ pid, ppid, args }]`, read with `ps -eo
 * pid,ppid,args` (never touches ace-step files; read-only). `args` is the
 * FULL command line (macOS `ps` does not truncate this column when not
 * writing to a tty), which is what the pid-reuse guard below compares.
 */
function psSnapshot() {
  const out = spawnSync("ps", ["-eo", "pid,ppid,args"], { encoding: "utf8" });
  const rows = [];
  for (const line of (out.stdout ?? "").split("\n").slice(1)) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (m) rows.push({ pid: Number(m[1]), ppid: Number(m[2]), args: m[3] });
  }
  return rows;
}

/**
 * Transitive descendants of `rootPid`, walked forward through `ppid` links in
 * `snapshot`. m23-az-1's whole point: this MUST be called with a snapshot
 * taken BEFORE the parent is killed — once the parent dies its children are
 * reparented to pid 1 and the `ppid` linkage that makes this walk possible is
 * gone. Calling it after the kill would silently return nothing, which is why
 * this function does not take the pid alone; the caller is forced to have a
 * snapshot in hand.
 */
function descendantsOf(rootPid, snapshot) {
  const byPpid = new Map();
  for (const row of snapshot) {
    if (!byPpid.has(row.ppid)) byPpid.set(row.ppid, []);
    byPpid.get(row.ppid).push(row);
  }
  const result = [];
  const seen = new Set();
  const frontier = [rootPid];
  while (frontier.length) {
    const p = frontier.pop();
    for (const child of byPpid.get(p) ?? []) {
      if (seen.has(child.pid)) continue;
      seen.add(child.pid);
      result.push(child);
      frontier.push(child.pid);
    }
  }
  return result;
}

/** Poll ai.sidecarStatus until it reports a pid, or give up honestly. */
async function pollForBootedPid(timeoutMs = 20000, intervalMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const s = await cmd("ai.sidecarStatus");
    if (s.ok && s.result?.pid) return s.result;
    await sleep(intervalMs);
  }
  return null;
}

/** Poll until a killed pid is gone AND port 8001 is free, or give up honestly. */
async function pollForStopped(pid, timeoutMs = 10000, intervalMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!inspectPid(pid).alive && port8001Free()) return true;
    await sleep(intervalMs);
  }
  return false;
}

/** Generic poll-until-true, used by the descendant reaper below. */
async function pollUntil(predicate, timeoutMs, intervalMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(intervalMs);
  }
  return predicate();
}

/**
 * m23-az-1 gap (b): SIGTERM to the `uv run` PARENT does not reach its python
 * child (m23-bb's real topology: pid 49156 -> python 49160 listening on
 * 8001) — bash does not forward TERM to a backgrounded child by default, and
 * that child is what holds the ~75 GB. `descendants` MUST be pre-kill
 * snapshots (pid + args captured before the parent's SIGTERM, per
 * `descendantsOf`'s doc comment) — reparenting to pid 1 after the parent dies
 * destroys the ppid linkage this function has no other way to reconstruct.
 *
 * Pid-reuse guard: before killing any survivor, re-`ps` it and compare args
 * to what was captured pre-kill. A pid that died and was recycled by the OS
 * in the interim will show DIFFERENT args — refuse to kill it and say so,
 * rather than sending a signal to a process we can no longer identify.
 *
 * Escalates a confirmed (args-matched) survivor to SIGKILL only after a
 * bounded SIGTERM grace period, and reports every escalation.
 */
async function reapDescendants(descendants, { graceMs = 5000, pollMs = 300 } = {}) {
  const outcomes = [];
  for (const d of descendants) {
    const before = inspectPid(d.pid);
    if (!before.alive) {
      outcomes.push({ ...d, outcome: "already gone (exited on its own before we got to it)" });
      continue;
    }
    if (before.args !== d.args) {
      outcomes.push({
        ...d,
        outcome: `SKIPPED — pid ${d.pid} now has different args ("${before.args}"); the pid was `
          + "likely reused since capture, refusing to kill it",
      });
      continue;
    }
    console.log(`restore: descendant pid ${d.pid} (${d.args}) is alive — sending SIGTERM`);
    try { process.kill(d.pid, "SIGTERM"); } catch (e) {
      outcomes.push({ ...d, outcome: `SIGTERM failed — ${e?.message ?? e}` });
      continue;
    }
    const stoppedAfterTerm = await pollUntil(() => !inspectPid(d.pid).alive, graceMs, pollMs);
    if (stoppedAfterTerm) {
      outcomes.push({ ...d, outcome: "confirmed stopped after SIGTERM" });
      continue;
    }
    const recheck = inspectPid(d.pid);
    if (!recheck.alive) {
      outcomes.push({ ...d, outcome: "confirmed stopped after SIGTERM (settled just after the poll)" });
      continue;
    }
    if (recheck.args !== d.args) {
      outcomes.push({
        ...d,
        outcome: `SKIPPED escalation — pid ${d.pid} now has different args ("${recheck.args}"); `
          + "reused since the SIGTERM, refusing to SIGKILL it",
      });
      continue;
    }
    console.log(`restore: descendant pid ${d.pid} still alive after ${graceMs}ms grace — escalating to SIGKILL`);
    try { process.kill(d.pid, "SIGKILL"); } catch (e) {
      outcomes.push({ ...d, outcome: `SIGKILL failed — ${e?.message ?? e}` });
      continue;
    }
    const stoppedAfterKill = await pollUntil(() => !inspectPid(d.pid).alive, graceMs, pollMs);
    outcomes.push({
      ...d,
      outcome: stoppedAfterKill
        ? "confirmed stopped after SIGKILL"
        : `WARNING — pid ${d.pid} still alive after SIGKILL — check manually`,
    });
  }
  return outcomes;
}

// m23-bg: PRINT-ONLY — no pin. This gate has no frame pin today and no
// baseline to detect a pin-induced regression against, so the fix is limited
// to making the inherited geometry visible in the log. A bare
// `debug.windowFrame` never mutates (DAWProApp.swift:3617 only writes when
// width/height are present). Polls briefly since `connect()` can return
// before the window itself exists.
{
  let wf = null;
  for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
    wf = (await cmd("debug.windowFrame", {})).result;
    if (!(wf && typeof wf.width === "number")) await sleep(250);
  }
  console.log(`${GATE} m23-bg inherited (NOT pinned): ${JSON.stringify(wf)}`);
}

await cmd("project.new");

// A: bare read law — read-only, empty on fresh app
let r = await cmd("debug.generationCard");
check("A bare read ok + invisible + empty", r.ok && r.result.visible === false && r.result.jobs.length === 0, JSON.stringify(r));

// B: seed IMPORT-origin running row (origin never live-gated by the agent)
r = await cmd("debug.generationCard", { seed: { phase: "running", origin: "import", label: "orch import probe", progress: 0.42, stage: "Generating music (batch size: 2)...", elapsedSeconds: 33 } });
check("B seed import running accepted", r.ok, JSON.stringify(r.error ?? ""));
await sleep(400);
r = await cmd("debug.generationCard");
const bj = r.result?.jobs?.find(j => j.origin === "import");
check("B card visible with import row", r.ok && r.result.visible === true && !!bj, JSON.stringify(r.result ?? {}));
check("B import row echoes progress/stage/elapsed", !!bj && Math.abs(bj.progress - 0.42) < 0.001 && /batch size/.test(bj.stage ?? "") && bj.elapsed.split(":").map(Number).reverse().reduce((acc, v, i) => acc + v * 60 ** i, 0) >= 33, JSON.stringify(bj ?? {}));
r = await cmd("debug.captureUI", { path: "/tmp/daw-gate-out/m17h-orch/cap-import-running.png" });
check("B capture import card", r.ok, JSON.stringify(r.error ?? ""));

// C: seed failed row with verbatim reason; then clear
r = await cmd("debug.generationCard", { seed: { phase: "failed", origin: "wire", label: "orch fail probe", reason: "orchestrator synthetic reason — verbatim echo test", elapsedSeconds: 7 } });
check("C seed failed accepted", r.ok, JSON.stringify(r.error ?? ""));
await sleep(400);
r = await cmd("debug.generationCard");
const cj = r.result?.jobs?.find(j => j.phase === "failed");
check("C failed row verbatim reason", !!cj && cj.reason === "orchestrator synthetic reason — verbatim echo test", JSON.stringify(cj ?? {}));

// D: snapshot cleanliness — card state is app-level, never project data
r = await cmd("project.snapshot");
const snapStr = JSON.stringify(r.result ?? {});
check("D no generation-card keys in project snapshot", r.ok && !/generationCard|presenceJob|GenerationPresence/i.test(snapStr), snapStr.slice(0, 200));

// E: teaching error on bad phase
r = await cmd("debug.generationCard", { seed: { phase: "wiggling" } });
check("E bad phase refused with teaching error", !r.ok && typeof r.error === "string" && /phase/.test(r.error), JSON.stringify(r.error ?? "no error"));

// F: clear verb empties the card
r = await cmd("debug.generationCard", { clear: true });
await sleep(300);
r = await cmd("debug.generationCard");
check("F clear empties card", r.ok && r.result.visible === false && r.result.jobs.length === 0, JSON.stringify(r.result ?? {}));

// G: wire generate with sidecar STOPPED — error verbatim mentions the sidecar, card narrates the boot.
// (m23-az) Explicit precondition: only run this leg when the sidecar is actually down. Running it
// against a healthy/starting sidecar would poison ITS OWN precondition (that is defect (2), proven
// not assumed — see the header comment), so any other state is a LOUD SKIP, not a pass.
r = await cmd("ai.sidecarStatus");
const preG = r.result;
console.log("sidecar status pre-G:", JSON.stringify(preG ?? r.error));
const sidecarWasDown = preG?.state === "installedNotRunning" || preG?.state === "notInstalled";

if (!sidecarWasDown) {
  const why = `sidecar state is "${preG?.state ?? "unknown"}" at entry, not down — running this leg would poison its own precondition (m23-az)`;
  skip("G wire generate errors while sidecar down", why);
  skip("G card narrates the kicked boot", "skipped alongside the leg above — no boot was attempted, so there is nothing to observe narrating one");
} else {
  // m23-az-1 gap (a): watch 8001 from BEFORE the boot attempt so "was it ever
  // bound" is an observation spanning the whole window, not a single
  // point-in-time read that can miss a bind-then-unbind entirely.
  startPortMonitor();
  r = await cmd("ai.generateSong", { prompt: "orch boot narration probe", durationSeconds: 15 }, 20000).catch(e => ({ ok: false, error: String(e) }));
  check("G wire generate errors while sidecar down", !r.ok && typeof r.error === "string" && /sidecar|start/i.test(r.error), JSON.stringify(r.error ?? ""));
  await sleep(800);
  r = await cmd("debug.generationCard");
  const gj = r.result?.jobs?.find(j => j.phase === "startingSidecar" || /start/i.test(j.stageLabel ?? ""));
  check("G card narrates the kicked boot", r.ok && r.result.visible === true && !!gj, JSON.stringify(r.result ?? {}));
  console.log("G boot row:", JSON.stringify(gj ?? {}));

  // Restore stopped-as-found (m23-az): this leg — and only this leg, since sidecarWasDown gates the
  // whole block — is what booted the sidecar, so this gate is responsible for putting it back down.
  // Poll rather than assume instantly-available: the boot is slow and asynchronous to the call above.
  console.log("restore: polling for the pid the boot above produced…");
  const booted = await pollForBootedPid();
  if (!booted) {
    console.log("restore: WARNING — sidecar boot never produced a pid within the timeout; nothing to kill (it may still be starting in the background — check manually)");
    console.log(`restore: ${portEvidenceSummary()}`);
  } else {
    const pid = booted.pid;
    const probe = inspectPid(pid);
    if (!probe.alive) {
      console.log(`restore: WARNING — ai.sidecarStatus named pid ${pid} but it is not alive; nothing to kill`);
      console.log(`restore: ${portEvidenceSummary()}`);
    } else if (!probe.looksLikeAceStep) {
      console.log(`restore: WARNING — pid ${pid} is alive but its args ("${probe.args}") do not mention ace-step; refusing to kill a pid we cannot confirm is the sidecar`);
      console.log(`restore: ${portEvidenceSummary()}`);
    } else {
      // m23-az-1 gap (b): capture the descendant set BEFORE the SIGTERM —
      // once the parent dies its children are reparented to pid 1 and the
      // ppid linkage this walk depends on is gone for good.
      const preKillSnapshot = psSnapshot();
      const descendants = descendantsOf(pid, preKillSnapshot);
      console.log(`restore: pre-kill descendant(s) of pid ${pid}: `
        + (descendants.length === 0 ? "none" : JSON.stringify(descendants)));

      console.log(`restore: killing booted ACE-Step sidecar pid ${pid} (${probe.args})`);
      try { process.kill(pid, "SIGTERM"); } catch (e) { console.log(`restore: SIGTERM failed — ${e?.message ?? e}`); }
      const stopped = await pollForStopped(pid);

      const reaped = await reapDescendants(descendants);
      for (const rr of reaped) {
        console.log(`restore: descendant pid ${rr.pid} (${rr.args}) -> ${rr.outcome}`);
      }
      const survivors = reaped.filter((rr) => rr.outcome.startsWith("WARNING"));
      const descendantsMsg = descendants.length === 0
        ? "no descendants observed pre-kill"
        : `${descendants.length} descendant(s) accounted for, ${survivors.length} survived`;

      console.log((stopped && survivors.length === 0)
        ? `restore: pid ${pid} confirmed stopped, ${descendantsMsg}, ${portEvidenceSummary()}`
        : `restore: WARNING — pid ${pid} stopped=${stopped}, ${descendantsMsg} — check manually; ${portEvidenceSummary()}`);
    }
  }
  stopPortMonitor();
}
r = await cmd("ai.sidecarStatus");
console.log("sidecar status post-G:", JSON.stringify(r.result ?? r.error));
console.log("port 8001 free post-G:", port8001Free());

// normalize + report
await cmd("debug.generationCard", { clear: true });
await cmd("project.new");
console.log(`ORCH_M17H_GATE pass=${pass} fail=${fail} skipped=${skipped}`);
if (skipped) {
  console.log(`⚠️ ${skipped} leg(s) SKIPPED — leg G's precondition (sidecar down) was not met at `
    + "entry. A skip is neither pass nor fail; it must be investigated, not read as a pass (m23-az).");
}
ws.close();
stopStaging(GATE);
// m23-az defect (1): exit code now reflects the result instead of an
// unconditional process.exit(0) — this gate can go red.
process.exit(fail === 0 ? 0 : 1);
