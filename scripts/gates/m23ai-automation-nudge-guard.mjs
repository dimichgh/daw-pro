// m23-ai — THE AUTOMATION LANE EDITOR'S HALF OF THE ARROW-KEY GUARD.
//
// WHAT THIS PROVES. With an automation lane editor on screen holding a live
// breakpoint selection, ← / → must NOT slide the selected clips: the editor
// would have consumed that key (its own `.onKeyPress(.delete)` consumes on
// exactly the same test, `AutomationLaneEditor.liveSelectionIndex`), and m23-x
// closed the identical hole for the piano roll. The refusal must also CONSUME
// the key rather than pass it through — `TimelineLanesView.automationLanes`
// (`:786`) sits inside the horizontal `ScrollView` at `:775`, so an `.ignored`
// arrow would answer by scrolling the timeline sideways, swapping one surprise
// for another.
//
// WHAT IT DELIBERATELY DOES NOT PROVE — read before trusting a green run:
//
//  • NOT that a REAL arrow keypress reaches the ancestor mount while a
//    descendant editor holds `@FocusState`. The unbundled staging binary does
//    not route real key events (m23-g1). Every leg here drives
//    `handleArrangeNudgeKey` through the `debug.arrangeSelection {act:"nudge"}`
//    seam, which is the SAME method `ContentView.swift`'s `.onKeyPress` calls.
//    Handler-level certainty, not end-to-end.
//  • NOT that `.onDisappear` fires on a workspace switch. Leg C proves the
//    arrows RECOVER after a mixer round trip, which is the user-visible hazard;
//    a remounted editor reporting `false` for the same lane id would drain the
//    set just as well. The leg is named for what it witnesses.
//  • NOT focus. `AutomationLaneEditor.focused` stays private and unreported on
//    purpose — a raw SwiftUI focus flag was MEASURED at 6-true / 6-false over
//    12 consecutive selections of DIFFERENT clips, so it is not a term in the
//    guard and not a term here. ⚠️ CORRECTED AT m23-al-1 (2026-08-03): this
//    header used to say "across 12 `.id()`-keyed rebuilds", attributing the
//    flip to the rebuild. THAT WAS FALSIFIED — the flag flips on REPEAT clicks
//    too, where the `.id()` never changes and neither lifecycle callback runs,
//    and over 12 clicks on ONE clip it reads `true` just ONCE. m23-al-1 fixed
//    the zoom routing that consumed it; the flag itself still alternates and is
//    still unusable as a guard term, which is why this leg is unchanged.
//
// ⚠️ ONE LEG LOOKS LIKE COVERAGE AND IS NOT, AND IT SAYS SO IN ITS OWN NAME.
// A4 asserts the refusal reports `handled: true`. A SUCCESSFUL nudge reports
// `handled: true` too, so A4 stays GREEN under a mutant that deletes the guard
// entirely. It pins the consume-vs-pass-through decision, not the guard. The
// legs that discriminate are the `refusedBy` legs and the clip-position legs.
//
// RUN: node scripts/gates/m23ai-automation-nudge-guard.mjs
// Staging :17695 ONLY — port 17600 is the user's live app and is never touched.

import fs from "fs";
import { startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23ai";
const PORT = 17695;
const REPO = "/Users/dsemenov/Views/daw-pro";
const OUT = `/tmp/daw-gate-out/${GATE}`;
const PIDFILE = `${OUT}/staging.pid`;
const BINARY = ".build/debug/DAWApp";
const SETTLE = 350;

fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

const staging = startStaging({ gate: GATE, root: REPO, port: PORT,
  binary: BINARY, detached: true, pidfile: PIDFILE, outDir: OUT });
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4000);

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}
const { ws, req } = await connect();

// Any throw past this point must STILL stop staging — a leaked detached app
// holding :17695 is the one thing this gate must never do. ⚠️ `stopStaging` is
// POSITIONAL (`_staging.mjs:265`); an options object would be accepted, resolve
// a `[object Object]` pidfile path, and silently no-op (m23-ah-1).
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => {
    console.error(`${ev}:`, e && e.message);
    try { stopStaging(GATE, PIDFILE); } catch {}
    process.exit(2);
  });
}

const results = [];
const check = (n, ok, d) => { results.push({ n, ok, d }); console.log(`  ${ok ? "ok  " : "!!  "} ${n}\n        ${d}`); };

// ── fixture helpers ──────────────────────────────────────────────────────────

/// Deep-search the snapshot for the clip and return its start beat. A fixture
/// that cannot be READ is a fixture failure, not a soft leg — it throws, so a
/// broken fixture can never present as a guard that passed.
function clipStart(snap, clipId) {
  let found;
  (function walk(node) {
    if (found !== undefined || node === null || typeof node !== "object") return;
    if (Array.isArray(node)) { node.forEach(walk); return; }
    if (node.id === clipId) {
      const v = node.startBeat ?? node.start ?? node.atBeat;
      if (typeof v === "number") { found = v; return; }
    }
    Object.values(node).forEach(walk);
  })(snap);
  if (found === undefined) throw new Error(`FIXTURE: clip ${clipId} has no readable start beat in project.snapshot`);
  return found;
}
const startOf = async (clipId) => clipStart(await req("project.snapshot"), clipId);

/// Pull an id out of a response, whatever wrapper it wears — `track.add` and
/// `clip.addMIDI` answer with the encoded model, `automation.addLane` wraps it
/// in `{lane: {...}}`. THROWS rather than yielding `undefined`: an undefined id
/// travels silently into the next call and surfaces as a confusing param error
/// three steps later, which is how a fixture bug gets mistaken for a defect.
function idOf(res, label) {
  const v = res?.id ?? res?.lane?.id ?? res?.track?.id ?? res?.clip?.id;
  if (typeof v !== "string") throw new Error(`FIXTURE: no id in ${label} response: ${JSON.stringify(res).slice(0, 200)}`);
  return v;
}

/// The seam's echo — the ONLY way to observe the bridge from outside. Without
/// it the refusal would be the sole witness and could not distinguish "the
/// guard fired" from "the fixture never armed".
///
/// A BARE `{}` IS A PURE READ, verified structurally rather than assumed:
/// `DAWProApp.swift:3694` gates the entire act switch behind
/// `if let act = params["act"]`, so with no act nothing mutates and only the
/// report object is built. That is NOT true of every debug seam in this tree —
/// `debug.arrangeScroll` mutates on a bare read (m23-ah-2) — so it is checked
/// here rather than inherited.
const echo = () => req("debug.arrangeSelection", {});

const nudge = (dir = "right") =>
  req("debug.arrangeSelection", { act: "nudge", direction: dir });

// ── FIXTURE ──────────────────────────────────────────────────────────────────
// ORDER IS LOAD-BEARING (measured by the implementer): the lane must have at
// least one breakpoint BEFORE staging, because `stage(select:true)` resolves to
// `draft.indices.first` and an empty draft selects nothing. And
// `automation.setPoints` AFTER arming silently DISARMS that lane (the editor's
// `.onChange(of: lane.points)` re-seeds the draft and nils the selection) —
// leg B2 turns that trap into the instrument it uses.
await req("project.new", { discardChanges: true });
const trackA = idOf(await req("track.add", { kind: "instrument", name: "Lead" }), "track.add A");
const trackB = idOf(await req("track.add", { kind: "instrument", name: "Pad" }), "track.add B");
const clip = idOf(await req("clip.addMIDI", { trackId: trackA, atBeat: 8, lengthBeats: 4 }), "clip.addMIDI");

const laneA = idOf(await req("automation.addLane", { trackId: trackA, target: { type: "volume" } }), "addLane A");
const laneB = idOf(await req("automation.addLane", { trackId: trackB, target: { type: "volume" } }), "addLane B");
const points = [{ beat: 0, value: 0.5 }, { beat: 4, value: 0.8 }];
await req("automation.setPoints", { trackId: trackA, laneId: laneA, points });
await req("automation.setPoints", { trackId: trackB, laneId: laneB, points });

await req("debug.windowFrame", { width: 1400, height: 1000 });
await req("ui.showAutomation", { trackId: trackA });
await sleep(SETTLE);
await req("debug.arrangeSelection", { act: "click", clipId: clip });
await sleep(SETTLE);

const START = await startOf(clip);
if (START !== 8) throw new Error(`FIXTURE: clip should start at beat 8, reads ${START}`);

// ── F: the observability wire itself ─────────────────────────────────────────
const e0 = await echo();
check("F1 the seam ECHOES the bridge at all (without this every later leg is inference, not measurement)",
  e0.automationPointSelection !== undefined && e0.automationPointLaneCount !== undefined,
  `automationPointSelection=${e0.automationPointSelection} automationPointLaneCount=${e0.automationPointLaneCount}`);

check("F2 BASELINE: an editor on screen with NOTHING selected claims nothing — the arrange owns the arrows",
  e0.automationPointSelection === false && e0.automationPointLaneCount === 0,
  `claim=${e0.automationPointSelection} lanes=${e0.automationPointLaneCount}`);

// ── A: the controlled pair, one lane ─────────────────────────────────────────
await req("debug.arrangeSelection", { act: "click", clipId: clip });
await req("debug.arrangeSelection", { act: "automationPoints", select: true });
const e1 = await echo();
check("A1 ARM: staging a breakpoint selection makes exactly the ONE mounted lane claim the key",
  e1.automationPointSelection === true && e1.automationPointLaneCount === 1,
  `claim=${e1.automationPointSelection} lanes=${e1.automationPointLaneCount}`);

const nA = await nudge();
const startA = await startOf(clip);
check("A2 [DISCRIMINATING] → is REFUSED by the automation guard, and names itself",
  nA.refusedBy === "automation-point-edit",
  `refusedBy=${JSON.stringify(nA.refusedBy)} (expected "automation-point-edit")`);
check("A3 [DISCRIMINATING] and the clip did NOT move — the point the user is editing keeps its clip",
  startA === START,
  `start ${START} -> ${startA} (must be unchanged)`);
check("A4 [NOT DISCRIMINATING — a successful nudge sets this too] the refusal CONSUMES the key",
  nA.nudged === true,
  `nudged=${nA.nudged}; pins consume-vs-pass-through only. The lanes' horizontal ScrollView would answer an .ignored arrow by scrolling the timeline.`);

await req("debug.arrangeSelection", { act: "automationPoints", select: false });
const e2 = await echo();
check("A5 DISARM: dropping the breakpoint selection releases the claim",
  e2.automationPointSelection === false && e2.automationPointLaneCount === 0,
  `claim=${e2.automationPointSelection} lanes=${e2.automationPointLaneCount}`);

await req("debug.arrangeSelection", { act: "click", clipId: clip });
const nB = await nudge();
const startB = await startOf(clip);
check("A6 CONTROL: the IDENTICAL call now moves the clip — so A3 is a refusal, not a dead fixture",
  startB !== START && nB.refusedBy == null,
  `start ${START} -> ${startB}, refusedBy=${JSON.stringify(nB.refusedBy)}, delta=${nB.effectiveDeltaBeats}`);

// ── B: the Set-vs-Bool proof (a Bool bridge FAILS B3/B4) ─────────────────────
// Both lanes on screen and armed; then SILENCE one of them and confirm the
// other's claim survives. With `hasSelection: Bool` the silent lane's `false`
// would be last-writer-wins and the guard would go dead — which is the whole
// reason this bridge is keyed by lane id.
await req("ui.showAutomation", { trackId: trackB });
await sleep(SETTLE);
await req("debug.arrangeSelection", { act: "automationPoints", select: true });
const e3 = await echo();
check("B1 TWO lanes on screen, both armed — the bridge holds two distinct claims",
  e3.automationPointLaneCount === 2,
  `lanes=${e3.automationPointLaneCount} (expected 2)`);

// Re-seeding lane B's points nils ITS selection only (the editor's own
// `.onChange(of: lane.points)`), which is the cleanest way to silence exactly
// one live editor from the wire.
// ⚠️ THE POINTS MUST ACTUALLY CHANGE. Re-submitting the IDENTICAL array is a
// no-op — `onChange(of: lane.points)` compares values, so nothing fires, the
// lane never disarms, and B2/B3 read as a broken guard when the fixture was
// the thing that did nothing. Measured on the first run of this gate.
await req("automation.setPoints", { trackId: trackB, laneId: laneB,
  points: [{ beat: 0, value: 0.25 }, { beat: 4, value: 0.9 }, { beat: 8, value: 0.6 }] });
await sleep(SETTLE);
const e4 = await echo();
check("B2 silencing ONE lane drops ONE claim — not the set",
  e4.automationPointLaneCount === 1 && e4.automationPointSelection === true,
  `lanes=${e4.automationPointLaneCount} claim=${e4.automationPointSelection} (a Bool bridge would read claim=false here)`);

await req("debug.arrangeSelection", { act: "click", clipId: clip });
const beforeC = await startOf(clip);
const nC = await nudge();
const afterC = await startOf(clip);
check("B3 [DISCRIMINATING — the leg a Bool bridge fails] the surviving lane still refuses the key",
  nC.refusedBy === "automation-point-edit",
  `refusedBy=${JSON.stringify(nC.refusedBy)}`);
check("B4 [DISCRIMINATING] and the clip still did not move",
  afterC === beforeC,
  `start ${beforeC} -> ${afterC}`);

// ── C: the latch hazard — arrows must RECOVER after a workspace round trip ───
// ⚠️ WHAT THIS WITNESSES: that leaving and re-entering the arrange does not
// leave the arrow keys dead. It does NOT isolate `.onDisappear` — a remounted
// editor reporting `false` for the same lane id drains the set identically.
// Both are acceptable outcomes; a LATCHED claim is not, and that is what a red
// C1/C2 would mean.
await req("ui.showMixer", { show: true });
await sleep(SETTLE);
await req("ui.showMixer", { show: false });
await sleep(SETTLE);
const e5 = await echo();
check("C1 after arrange -> mix -> arrange the claim is GONE (not latched for the session)",
  e5.automationPointSelection === false && e5.automationPointLaneCount === 0,
  `claim=${e5.automationPointSelection} lanes=${e5.automationPointLaneCount}`);

await req("debug.arrangeSelection", { act: "click", clipId: clip });
const beforeD = await startOf(clip);
const nD = await nudge();
const afterD = await startOf(clip);
check("C2 and the arrow keys WORK again — the hazard the bridge's doc comment names did not fire",
  afterD !== beforeD && nD.refusedBy == null,
  `start ${beforeD} -> ${afterD}, refusedBy=${JSON.stringify(nD.refusedBy)}`);

// ── D: an unarmable fixture must FAIL LOUDLY, never certify silently ─────────
// A lane with zero breakpoints cannot be armed (`draft.indices.first` is nil).
// If that answered "ok", a gate whose fixture forgot the points would sail
// through its refuse legs on a guard that was never armed — the vacuous-leg
// trap. The seam is supposed to throw. This leg proves it does.
await req("project.new", { discardChanges: true });
const bare = idOf(await req("track.add", { kind: "instrument", name: "Bare" }), "track.add bare");
const bareLane = idOf(await req("automation.addLane", { trackId: bare, target: { type: "volume" } }), "addLane bare");
await req("ui.showAutomation", { trackId: bare });
await sleep(SETTLE);
let threw = null;
try {
  await req("debug.arrangeSelection", { act: "automationPoints", select: true });
} catch (e) { threw = e.message; }
check("D1 arming a lane with NO breakpoints THROWS — an unarmable fixture cannot pass as an armed one",
  threw !== null,
  threw ? `threw: ${threw.slice(0, 150)}` : `NO THROW — the seam certified an editor that claims nothing (lane ${bareLane})`);

// ── report ───────────────────────────────────────────────────────────────────
const pass = results.filter((r) => r.ok).length;
console.log(`\n${GATE}: ${pass}/${results.length} passed`);
for (const r of results.filter((r) => !r.ok)) console.log(`  FAILED: ${r.n}`);

try { ws.close(); } catch {}
stopStaging(GATE, PIDFILE);
clearTimeout(killer);
// ⚠️ An explicit exit is mandatory: a detached child plus a pending timer keep
// node's event loop alive, and a gate that finished its work then hung is
// indistinguishable from a hung measurement (m23-ah paid 10 minutes for this).
process.exit(pass === results.length ? 0 : 1);
