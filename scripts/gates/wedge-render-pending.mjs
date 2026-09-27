// WF GATE — THE MAIN THREAD MUST NOT STARVE WHILE A RENDER IS PENDING WITH THE
// NOTE EDITOR OPEN. Runs against a REAL app on staging (port 17695 ONLY; 17600 is
// the user's LIVE app and is never touched; killed PIDFILE-EXACT, never
// pkill/pgrep).
//
// THE DEFECT THIS GUARDS (WF, 2026-09-25, pinned by bisection with an
// `RBLayer -display` spy in a staging build):
//   The note editor's scrub ruler band (`PianoRollScrubRulerBand`: a
//   `.clipped()` group holding a content-wide ruler `Canvas`, slid with
//   `.offset(x: -scrollX)`) was flattened by SwiftUI into ONE window-level
//   RenderBox layer. That layer re-rasterized on EVERY Core Animation commit,
//   even with nothing in it changed. The band's body and Canvas closure never
//   re-ran; RenderBox re-drew the cached list into a fresh surface. At rest the
//   VibeMeter's 60 Hz tick is the only commit source (60 re-draws/s, which is
//   sustainable). A clip note edit starts a stretch render, and the arrange's
//   `ClipShimmer` animates while it is pending. That second commit source took
//   the band to 180–240 re-draws/s. With the window ON SCREEN the WindowServer
//   could not hand surfaces back that fast. The MAIN THREAD then slept in
//   `CA::Transaction::commit → -[RBLayer display] → RB::SurfacePool::alloc →
//   wait_image_queue` (usleep), for up to ~70% of a 5 s sample. Wire commands,
//   liveness pongs and the 10 Hz stretch poll all waited behind it. Once, it
//   lasted 24 s straight, with a `WEDGED` breadcrumb. The fix is
//   `.geometryGroup()` in the band's `scrolling` helper: the strip is its own
//   layer, drawn once, and a scroll moves it.
//
// WHAT THIS PROVES — six measured phases, each a 5 s (or 3 s) `/usr/bin/sample`
// of the staging pid plus a 100 ms wire ping loop:
//   A  idle, arrange, pane open                          — control
//   B  `clip.setNotePitch` → render PENDING, pane open    — THE LEG
//   C  idle again                                        — control
//   D  workspace = Mix, `clip.setNotePitch` → pending     — control (band off screen)
//   E  idle, Mix                                         — control
//   F  back to arrange, `clip.setNotePitch` → pending     — THE LEG, again
//   For B and F: main-thread samples inside `RB::SurfacePool::wait_image_queue`
//   ≤ WEDGE_WAIT_MAX (default 10 of ~4000), max ping < 500 ms. For every phase:
//   the wait count ≤ WEDGE_WAIT_MAX. And NO new `main-actor-wedge.log` line
//   tagged with this staging pid (the breadcrumb carries `pid= port= process=`
//   since WF; a line from any other process is REPORTED, never counted).
//
// ⛔ WHAT IT CANNOT PROVE — AND REFUSES (exit 2) RATHER THAN PASS:
//   • The waits exist ONLY while the window is being DRAWN. Covered by another
//     app, minimized, on another Space or with the display asleep, the broken
//     binary reads 0 waits, which is GREEN on a defect. So B and F read the
//     app's own `NSWindow.occlusionState` (`debug.windowFrame`'s
//     `occlusionVisible`) at their START and END. The start read must be true.
//     The end read may be missing when the wedge itself blocked it, but it must
//     not be false. Otherwise the run is INCONCLUSIVE (exit 2), and so is a leg
//     that errors while the last read said "not drawn". This gate cannot run
//     headless, with the display off, or behind another window.
//   • Occlusion is NOT a display-awake signal: WF-F1 runs read it TRUE with the
//     display asleep and the screen locked. So B and F also read CoreGraphics
//     (`CGDisplayIsAsleep` + the session's screen-lock flag, through JXA —
//     read-only) at START and END: awake and unlocked at the start, neither
//     asleep nor locked at the end, or the run is INCONCLUSIVE (exit 2).
//   • B, D and F must each SEE the render pending (`stretchRendering` true on
//     at least one 250 ms poll), or they measured nothing. That is also exit 2.
//   • Max ping alone cannot discriminate: red runs measured 1196 waits with a
//     27 ms max ping (the waits land between pings). The wait count is the
//     measurement; the ping is the user-visible symptom.
//   • Measured on the unfixed band with the window drawn (WF, 2026-09-25):
//     the base and planted builds went red in 4 of 4 render phases (260–2957
//     waits). Five variants that kept the flattened band went red in 10 of 10
//     (55–1918). The lowest red was 55 against a threshold of 10: the margin
//     is real but not huge, so run a plant more than once and report the count.
//   • A DIFFERENT main-thread stall exists and this gate will ALSO go red on
//     it: `RB::SharedSurfaceGroup::wait_for_allocations → -[CAContext
//     waitForCommitId:timeout:]`, seen in the FIXED build. Once it hit with
//     the window read as drawn (Mix, idle: 1795 of 2381 main-thread samples,
//     4.8 s wedge; the display state was not recorded). It also hit every
//     phase of a spy run made with the display asleep and the screen locked,
//     and several runs this gate refused as not drawn. The VibeMeter's
//     60 Hz layer drives it (pausing the meter removed it), and the band is
//     not involved. Read the sample before blaming the band: the band's
//     signature is `SurfacePool::wait_image_queue`, counted above. Each PHASE
//     line also prints `commit waits` (main-thread samples in
//     `-[CAContext waitForCommitId:timeout:]`), so a red run names its stall.
//   • The log's first line is this script's own sha256, so a verdict can be
//     tied to the exact legs and refusals that produced it.
//
// PLANT: build with the `.geometryGroup()` line removed from
// `PianoRollScrubRulerBand.scrolling` into a scratch copy of the binary, then run
// this gate against it with `WEDGE_BINARY=<abs path>` + `WEDGE_SKIP_BUILD=1`
// (+ `WEDGE_EXPECT_PLANT=1` to label the log). It must go RED with the window
// drawn.
//
// Env: WEDGE_ROOT (default: MAIN, `_staging.mjs`'s `ROOT`), WEDGE_BINARY
//      (default `.build/debug/DAWApp`; absolute or relative to WEDGE_ROOT),
//      WEDGE_SKIP_BUILD=1, WEDGE_EXPECT_SHA (hard ABORT on mismatch), WEDGE_OUT
//      (default /tmp/wedge-render-pending), WEDGE_WAIT_MAX (default 10),
//      WEDGE_EXPECT_PLANT=1 (labels the run only).
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, existsSync, readFileSync, statSync, openSync, readSync, closeSync, appendFileSync } from "node:fs";
import { join, isAbsolute } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { ROOT, DEFAULT_BINARY, verdict, sleep, buildOrAbort, launchStaging, stopStaging } from "./_staging.mjs";
import { synthesizeVocalFixture, makeCmd, waitPitchEditorReady, openTunedClip } from "./_pitch-editor-look.mjs";

const GATE = "wedge-render-pending";
const RUN_ROOT = process.env.WEDGE_ROOT || ROOT;
const BINARY = process.env.WEDGE_BINARY || DEFAULT_BINARY;
const OUT = process.env.WEDGE_OUT || "/tmp/wedge-render-pending";
const WAIT_MAX = Number(process.env.WEDGE_WAIT_MAX ?? 10);
const PING_MAX_MS = 500;
const PIDFILE = join(OUT, "staging.pid");
const WEDGE_LOG = `${process.env.HOME}/Library/Logs/DAWPro/main-actor-wedge.log`;
mkdirSync(join(OUT, "out"), { recursive: true });
if (process.env.WEDGE_EXPECT_PLANT === "1") console.log("RUN LABEL: a PLANTED build — RED legs are the point");

const T0 = Date.now();
const trace = (o) => appendFileSync(join(OUT, "trace.jsonl"), JSON.stringify({ ms: Date.now() - T0, ...o }) + "\n");

// The gate's OWN hash, so a run log says which version of these legs and
// refusals produced its verdict (WF-F1: two drafts once shared one log format).
const gateSha = createHash("sha256").update(readFileSync(fileURLToPath(import.meta.url))).digest("hex");
console.log(`gate script sha256 ${gateSha}`);
trace({ ev: "gate", sha256: gateSha });

buildOrAbort({ root: RUN_ROOT, skip: process.env.WEDGE_SKIP_BUILD === "1" });
const binPath = isAbsolute(BINARY) ? BINARY : join(RUN_ROOT, BINARY);
const binarySha = spawnSync("shasum", ["-a", "256", binPath], { encoding: "utf8" }).stdout.split(/\s+/)[0];
console.log(`binary ${binPath}\nsha256 ${binarySha}`);
if (process.env.WEDGE_EXPECT_SHA && binarySha !== process.env.WEDGE_EXPECT_SHA) {
  console.log(`ABORT (proves nothing): binary sha256 ${binarySha} != WEDGE_EXPECT_SHA ${process.env.WEDGE_EXPECT_SHA}`);
  process.exit(2);
}

const wedgeLogSize = () => (existsSync(WEDGE_LOG) ? statSync(WEDGE_LOG).size : 0);
function wedgeLogSince(offset) {
  if (!existsSync(WEDGE_LOG)) return [];
  const n = statSync(WEDGE_LOG).size - offset;
  if (n <= 0) return [];
  const buf = Buffer.alloc(n);
  const fd = openSync(WEDGE_LOG, "r");
  try { readSync(fd, buf, 0, n, offset); } finally { closeSync(fd); }
  return buf.toString("utf8").split("\n").filter(Boolean);
}
const crumbOffset0 = wedgeLogSize();

/** Main-thread samples on the RB image-queue wait, summed over every call site
 * (usleep and its siblings) — plus the thread total, so an empty sample is
 * visible as `total: null` rather than as a clean 0. `commitWait` counts the
 * OTHER stall's signature (`-[CAContext waitForCommitId:timeout:]`, reached
 * from `RB::SharedSurfaceGroup`), so a red run says which stall it was without
 * anyone opening the sample file. */
function waitCount(file) {
  if (!existsSync(file)) return { total: null, wait: null, rbDisplay: null, commitWait: null };
  const lines = readFileSync(file, "utf8").split("\n");
  // `sample` heads the main thread two ways: `Thread_N: Main Thread …` when it
  // ran several queues, `Thread_N   DispatchQueue_1: com.apple.main-thread` when
  // it ran only the main queue (WF-F1: the second form read as "no samples").
  const start = lines.findIndex((l) => /^\s+\d+ Thread_/.test(l) &&
    (l.includes("Main Thread") || l.includes("com.apple.main-thread")));
  if (start < 0) return { total: null, wait: null, rbDisplay: null, commitWait: null };
  let end = lines.findIndex((l, i) => i > start && /^\s+\d+ Thread_/.test(l));
  if (end < 0) end = lines.length;
  const total = Number((lines[start].match(/(\d+) Thread_/) || [])[1]);
  let wait = 0, rbDisplay = 0, commitWait = 0;
  for (const l of lines.slice(start, end)) {
    const w = l.match(/^[\s+!:|]*(\d+) RB::SurfacePool::wait_image_queue\(/);
    if (w) wait += Number(w[1]);
    const d = l.match(/^[\s+!:|]*(\d+) -\[RBLayer display\]/);
    if (d) rbDisplay += Number(d[1]);
    const c = l.match(/^[\s+!:|]*(\d+) -\[CAContext waitForCommitId:timeout:\]/);
    if (c) commitWait += Number(c[1]);
  }
  return { total, wait, rbDisplay, commitWait };
}

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} — ${detail}`);
}
let inconclusive = null;
// Set once the first measured leg starts. An error BEFORE it (a missing
// resource bundle, a detector that found no notes) is a broken SETUP — exit 2,
// never a red verdict about the thing this gate measures.
let legsStarted = false;
function refuse(why) { if (!inconclusive) inconclusive = why; console.log(`INCONCLUSIVE: ${why}`); }

const session = await launchStaging({ gate: GATE, root: RUN_ROOT, binary: BINARY, skipBuild: true, settleMs: 1500, pidfile: PIDFILE, outDir: join(OUT, "staging") });
const PID = session.pid;
{
  const l = spawnSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(PID), "-iTCP", "-sTCP:LISTEN"], { encoding: "utf8" }).stdout || "";
  if (!l.includes(":17695") || l.includes(":17600")) {
    console.log(`ABORT: staging pid ${PID} is not listening on 17695 alone`);
    stopStaging(GATE, PIDFILE); process.exit(2);
  }
  console.log(`staging pid ${PID} on 17695 (lsof-verified)`);
}
const raw = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await raw(command, params);
  if (!r?.ok) throw new Error(`${command} failed: ${JSON.stringify(r?.error)}`);
  return r.result;
}
/** Display awake + session unlocked, read from CoreGraphics through JXA
 * (read-only; signals nothing). `occlusionVisible` alone is NOT a display-awake
 * signal: WF runs read it TRUE with the display asleep and the screen locked
 * (fixed-5 D–F, fixed-6 E–F), and a leg measured then proves nothing. */
const JXA_DISPLAY = 'ObjC.import("CoreGraphics"); const d = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())) || {}; ' +
  'JSON.stringify({ asleep: $.CGDisplayIsAsleep($.CGMainDisplayID()) === 1, locked: d.CGSSessionScreenIsLocked === true || d.CGSSessionScreenIsLocked === 1 })';
let lastAwake;
function displayState(tag) {
  const r = spawnSync("/usr/bin/osascript", ["-l", "JavaScript", "-e", JXA_DISPLAY], { encoding: "utf8" });
  let s;
  try { s = JSON.parse(String(r.stdout).trim()); } catch { s = { error: String(r.stderr || r.stdout || r.error || "").slice(0, 200) }; }
  if (typeof s.asleep === "boolean" && typeof s.locked === "boolean") lastAwake = !s.asleep && !s.locked;
  trace({ ev: "display", tag, ...s });
  return s;
}
let lastDrawn;
async function drawn(tag) {
  const r = await raw("debug.windowFrame", {});
  const v = r?.ok ? r.result?.occlusionVisible : undefined;
  // Only a definite answer moves `lastDrawn`: a read that failed BECAUSE the
  // main actor is wedged is not evidence that the window stopped being drawn.
  if (typeof v === "boolean") lastDrawn = v;
  trace({ ev: "occlusion", tag, visible: v });
  return v;
}
async function rendering(clipId) {
  const snap = await must("project.snapshot", {});
  return snap.tracks.flatMap((t) => t.clips ?? []).find((c) => c.id === clipId)?.stretchRendering === true;
}
async function waitRenderLanded(clipId, ms = 60000) {
  const t = Date.now();
  while (Date.now() - t < ms) { if (!(await rendering(clipId))) return Date.now() - t; await sleep(250); }
  return null;
}

/** One measured phase. `before` starts the render (if any) once the sampler runs. */
async function phase(name, secs, { clipId, before, needDrawn = false } = {}) {
  const ds0 = displayState(`${name}-start`);
  const v0 = await drawn(`${name}-start`);
  const file = join(OUT, `sample-${name}.txt`);
  const sampler = spawn("/usr/bin/sample", [String(PID), String(secs), "-file", file], { stdio: "ignore" });
  const done = new Promise((res) => sampler.on("exit", res));
  if (before) await before();
  const tEnd = Date.now() + secs * 1000;
  const pings = []; let seen = 0, polls = 0, lastPoll = 0;
  while (Date.now() < tEnd) {
    const t = Date.now();
    await raw("debug.pitchEditor", {});
    pings.push(Date.now() - t);
    if (clipId && Date.now() - lastPoll > 250) { lastPoll = Date.now(); polls++; if (await rendering(clipId)) seen++; }
    await sleep(100);
  }
  await done;
  const v1 = await drawn(`${name}-end`);
  const ds1 = displayState(`${name}-end`);
  const wc = waitCount(file);
  const r = { name, drawnStart: v0, drawnEnd: v1, maxPingMs: Math.max(...pings), pings: pings.length,
    renderingSeen: seen, renderPolls: polls, displayStart: ds0, displayEnd: ds1, ...wc };
  trace({ ev: "phase", ...r });
  console.log(`PHASE ${name}: waits ${wc.wait}/${wc.total} main samples (RBLayer display ${wc.rbDisplay}, commit waits ${wc.commitWait}), max ping ${r.maxPingMs} ms, ` +
    `render seen ${seen}/${polls}, drawn ${v0}→${v1}`);
  if (wc.total == null || wc.total === 0) refuse(`${name}: /usr/bin/sample produced no main-thread samples`);
  // The START read must be a definite true. The END read may be missing if the
  // main actor was wedged at that moment (the wedge is the evidence), but a
  // definite false means the window stopped being drawn mid-leg.
  if (needDrawn && (v0 !== true || v1 === false)) refuse(`${name}: the window was not being DRAWN (occlusionVisible ${v0}→${v1}) — waits cannot occur, so 0 proves nothing`);
  // The display must be AWAKE and the session UNLOCKED at the start (a definite
  // read), and not asleep/locked at the end. A missing read is not a pass.
  if (needDrawn && (ds0.asleep !== false || ds0.locked !== false || ds1.asleep === true || ds1.locked === true)) {
    refuse(`${name}: the display was not awake and unlocked (start ${JSON.stringify(ds0)}, end ${JSON.stringify(ds1)}) — occlusion reads true through display sleep, so this leg proves nothing`);
  }
  if (clipId && seen === 0) refuse(`${name}: the render was never seen pending — the leg measured nothing`);
  return r;
}

try {
  const SCALE_HZ = [196, 220, 247, 262, 294, 330, 349, 392];
  const fixture = synthesizeVocalFixture(join(OUT, "out"), {
    notes: Array.from({ length: 12 }, (_, i) => ({ hz: SCALE_HZ[i % SCALE_HZ.length], seconds: 1.4 })) });
  const opened = await openTunedClip(raw, { fixturePath: fixture });
  await must("project.save", { path: join(OUT, "out", "2026-09-25 WF Render Pending Gate.dawproj") });
  await waitPitchEditorReady(raw, { timeoutMs: 45000, intervalMs: 300 });
  const settle = await waitRenderLanded(opened.clipId);
  if (settle == null) throw new Error("the first render never landed");
  // A content-wide ruler (wider than the pane) — the shape that flattened.
  await must("debug.panelLayout", { pitchEditorPPB: 64 });
  await sleep(500);
  const echo0 = await must("debug.pitchEditor", {});
  if (echo0.open !== true) throw new Error("the pitch editor pane is not open — the gate's subject is absent");
  const segs = (await must("clip.getPitchEdits", { clipId: opened.clipId })).segments.map((n) => n.id ?? n.segmentId);
  if (segs.length < 3) throw new Error(`need 3 notes to edit, found ${segs.length}`);
  console.log(`pane open on clip ${opened.clipId.slice(0, 8)} (${segs.length} notes)`);

  legsStarted = true;
  const edit = (i, cents) => async () => { await must("clip.setNotePitch", { clipId: opened.clipId, segmentId: segs[i], cents }); };
  const A = await phase("A-idle-arrange", 3);
  const B = await phase("B-render-arrange", 5, { clipId: opened.clipId, before: edit(0, 200), needDrawn: true });
  await waitRenderLanded(opened.clipId); await sleep(1000);
  const C = await phase("C-idle-arrange", 3);
  await must("view.panelLayout", { workspace: "mix" }); await sleep(800);
  const D = await phase("D-render-mix", 5, { clipId: opened.clipId, before: edit(1, -200) });
  await waitRenderLanded(opened.clipId); await sleep(1000);
  const E = await phase("E-idle-mix", 3);
  await must("view.panelLayout", { workspace: "arrange" }); await sleep(800);
  const F = await phase("F-render-arrange", 5, { clipId: opened.clipId, before: edit(2, 150), needDrawn: true });
  await waitRenderLanded(opened.clipId);

  for (const p of [B, F]) {
    check(`${p.name}: main thread not waiting on RenderBox surfaces`, p.wait != null && p.wait <= WAIT_MAX,
      `${p.wait}/${p.total} samples in wait_image_queue (max ${WAIT_MAX})`);
    check(`${p.name}: wire answers within ${PING_MAX_MS} ms`, p.maxPingMs < PING_MAX_MS, `max ping ${p.maxPingMs} ms over ${p.pings}`);
  }
  for (const p of [A, C, D, E]) {
    check(`${p.name} (control): no surface waits`, p.wait != null && p.wait <= WAIT_MAX, `${p.wait}/${p.total}`);
  }
} catch (e) {
  console.log(`ERROR: ${e?.stack ?? e}`);
  if (legsStarted && lastDrawn === true && lastAwake !== false) {
    // A wire call that times out DURING the legs, window drawn, is the
    // defect's own symptom.
    check("the measured legs ran to completion", false, String(e?.message ?? e));
  } else if (legsStarted) {
    // Measured (WF): the VibeMeter's RenderBox commit-sync wait
    // (`waitForCommitId`) can starve the main thread on its own. It hit runs
    // with the display asleep. It is a real stall, but not this gate's
    // subject, and with the window not drawn the band cannot be measured.
    refuse(`a leg failed while the window was NOT drawn (occlusionVisible ${lastDrawn}, display awake+unlocked ${lastAwake}): ${String(e?.message ?? e).slice(0, 160)}`);
  } else {
    refuse(`setup failed before any leg ran: ${String(e?.message ?? e).slice(0, 200)}`);
  }
} finally {
  try { session.ws.close(); } catch { /* closing */ }
  stopStaging(GATE, PIDFILE);
  console.log("staging stopped (pidfile-exact)");
}

const crumbs = wedgeLogSince(crumbOffset0);
const mine = crumbs.filter((l) => l.includes(` pid=${PID} `));
for (const l of crumbs) console.log(`  breadcrumb ${l.includes(` pid=${PID} `) ? "(THIS staging pid)" : "(another process)"}: ${l}`);
check("no WEDGED/RECOVERED breadcrumb from this staging pid", mine.length === 0,
  `${mine.length} of ${crumbs.length} new line(s) in main-actor-wedge.log carry pid=${PID}`);

if (inconclusive) {
  console.log(`VERDICT: INCONCLUSIVE — ${inconclusive}. This run proves nothing either way (exit 2).`);
  process.exit(2);
}
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
