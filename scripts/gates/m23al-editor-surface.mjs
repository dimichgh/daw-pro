// m23-al GATE — WHICH EDITING SURFACE THE ⌘+/⌘−/⌘0 ROUTER AIMS AT IS APP STATE,
// NOT SWIFTUI FOCUS. Runs against a REAL app on staging (port 17695 ONLY; 17600
// is the user's LIVE app and is never touched. Staging is killed PIDFILE-EXACT,
// never pkill/pgrep — at start AND at exit).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY (the m23-x/m23-aj/m23-ak pattern), so the
// thing under test has KNOWN PROVENANCE. A gate that drives whatever instance
// happens to be on the port can pass against code that is minutes or days old,
// and it cannot tell you that it did (m23-ac).
//
// ── THE BUG, AS MEASURED (roadmap m23-al ①–⑧; probe `_m23al-focus-probe.mjs`) ──
// `AppModel.pianoRollEditorFocused` is a REPORT of SwiftUI focus arbitration
// between two competing `@FocusState` owners in an ancestor/descendant pair —
// the arrange workspace root (`ContentView.swift:1620/1625/1695`, asserted per
// CLICK via `DAWProApp.swift:694`) and the roll (`PianoRollView.swift:143/268/275`,
// asserted per REBUILD). The old router read that flag alone. Measured, 3 runs,
// `settling=0` on every row:
//   • clip SWITCHES  -> the flag alternates 6 true / 6 false over 12 clicks;
//   • 12 clicks on ONE clip -> `true` ONCE (the click that opens the roll) and
//     `false` eleven times.
// So clicking a MIDI clip TWICE — an ordinary thing to do — leaves ⌘+ zooming the
// ARRANGE for the rest of the session. The item's originally FILED cause (an
// `.onAppear`/`.onDisappear` race at the `.id(clip.id)` rebuild) is FALSE: S4/S5
// flip the flag on clicks where no `PianoRollView` is created or destroyed at all.
//
// ── WHAT THE FIX IS, AND THEREFORE WHAT THIS GATE ASSERTS ────────────────────
// Not "stabilise the flag" — STOP ROUTING ON IT. `EditorSurfaceRouter.resolve(
// workspaceIsArrange:rollOpen:lastEngaged:)` (DAWAppKit) is the ONE home, decided
// from three terms the APP itself writes, none of them a focus concept:
//   workspaceIsArrange == false -> (.arrange, .notArrangeWorkspace)
//   rollOpen           == false -> (.arrange, .noRollOpen)
//   lastEngaged == .pianoRoll   -> (.pianoRoll, .engagedRoll)
//   else                        -> (.arrange, .engagedArrange)
// LAST-ENGAGED WINS is m21-c's own normative rule
// (`PianoRollNoteSelectionBridge.swift:51-53`: "whichever zoom the user most
// recently engaged"), so clicking a clip OPENS the roll and LEAVES THE ARRANGE
// ACTIVE. That is the accepted product consequence, not an oversight — legs
// B/C/D assert exactly it, and leg E is what stops a hardwired `.arrange` from
// passing them.
//
// ⚠️ THE ROADMAP'S STATED GATE ("the flag is stable across 12 consecutive clip
// switches") IS INADEQUATE AND IS NOT WHAT THIS RUNS. It is leg B alone, and leg
// B alone passes on a fix that only handles rebuilds — which is precisely what S5
// exposes. Leg C (12 clicks on ONE clip) is the leg the filing lacks, and leg E
// is the anti-vacuity half it also lacks.
//
// ── WHAT THIS CANNOT PROVE, STATED AS A DEBT AND NOT HIDDEN ──────────────────
// The link `real gesture -> engage(...)`. The seam calls `editorEngagement.engage`
// directly, so a mutant that deletes the call from `PianoRollView.beginGesture`
// passes every leg here. Its substitute is STRUCTURAL, not behavioural:
// `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` asserts each of the
// R1–R8 funnels exists in source and pins the count of gesture attachments under
// `Sources/DAWApp/PianoRoll/`, so a new gesture reddens a test and forces its
// author to decide whether it engages. Same class as m23-aj-3's leg G and
// m23-ak's DELETE half. Recorded below as a SKIP, never as a pass.
//
// ── FIXTURE ARITHMETIC, derived BEFORE any assertion was written ─────────────
//   4 MIDI clips at 0 / 8 / 16 / 24, length 2, EACH CARRYING NOTES — the probe's
//   shape verbatim. A noteless clip is a different fixture and this gate must not
//   silently become it (m23-aj law).
//   ZOOM LADDER: both surfaces clamp to 4...200 pt/beat and step by ×1.25.
//   Arrange default 16, roll default 32. Twelve steps from 16 reach 232.8 and
//   CLAMP at 200 — one retry away from a spurious red, and at the ceiling
//   `setArrangeZoom`'s `guard abs(new - old) > 0.0001` makes a zoom-in a SILENT
//   NO-OP while `zoomPianoRollIn` has no such guard. So every row RESETS BOTH
//   SLOTS first and asserts a one-step move from a known floor. Nothing here
//   compares against a remembered constant: `debug.viewZoom` returns BOTH PPBs on
//   every call, so before/after come from the same command (the
//   `automationPointSelection` echo law).
//
// ⚠️ `debug.panelLayout` HAS NO `arrangePPB` PARAMETER (design §8.1 leg H says it
//    does — it does not; `DAWProApp.swift:3128-3147` accepts `pianoRollPPB` only).
//    The arrange slot is staged through `debug.arrangeZoom {ppb}`, whose
//    `if mutating { workspaceMode = .arrange }` is harmless everywhere it is used
//    here and touches NO engagement state, so `lastEngaged` survives it.
//
// Setup: none — run it.
//
//   node scripts/gates/m23al-editor-surface.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23al";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AL_GATE_OUT || "/tmp/m23al-gate";
const PIDFILE = process.env.M23AL_GATE_PIDFILE || "/tmp/m23al-gate-staging.pid";
const BINARY = process.env.M23AL_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23AL_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const LEN = 2;                 // clip length in beats
const SETTLE_MS = 250;
const ARRANGE_DEFAULT_PPB = 16;   // ArrangeZoom.defaultPixelsPerBeat
const ROLL_DEFAULT_PPB = 32;      // PianoRollZoom.defaultPixelsPerBeat

// ── build FIRST: a gate that tests the previous binary proves nothing ───────
buildOrAbort({ root: REPO });

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
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

// ── launch staging (pidfile-exact teardown of any previous run) ─────────────
const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };

const sel = (p = {}) => req("debug.arrangeSelection", p);
const vz = (p = {}) => req("debug.viewZoom", p);

/**
 * Put BOTH zoom slots back on their defaults so every row's assertion is a
 * one-step move from a known floor, independent of everything before it.
 *
 * `debug.arrangeZoom {ppb}` rather than `debug.panelLayout`: the layout seam
 * carries the ROLL's slot only. It forces `workspaceMode = .arrange`, which is
 * already true everywhere this is called, and it engages NOTHING (the §3.6(3)
 * no-feedback rule — a zoom entry point that engaged the surface it routed to
 * would be self-confirming and would latch forever).
 */
async function resetZooms() {
  await req("debug.arrangeZoom", { ppb: ARRANGE_DEFAULT_PPB });
  await req("debug.panelLayout", { pianoRollPPB: ROLL_DEFAULT_PPB });
}

/** Read (report-only) then act, both through `debug.viewZoom` so the before and
 *  after PPBs come from the SAME command and never from a remembered constant. */
async function zoomStep(act) {
  const before = await vz({});
  const after = await vz({ act });
  return { before, after };
}

const movedArrange = (b, a) => a.arrangePPB > b.arrangePPB;
const heldArrange = (b, a) => a.arrangePPB === b.arrangePPB;
const movedRollUp = (b, a) => a.pianoRollPPB > b.pianoRollPPB;
const movedRollDown = (b, a) => a.pianoRollPPB < b.pianoRollPPB;
const heldRoll = (b, a) => a.pianoRollPPB === b.pianoRollPPB;

/**
 * Four MIDI clips on ONE track, each carrying notes — the probe's fixture
 * verbatim, so the sequences below reproduce S1–S5 exactly.
 *
 * A FRESH TRACK PER LEG (the m23-ak rule): the legs arm the same router in
 * different states, and sharing clips would let one leg's leftover selection or
 * engagement decide the next one's result.
 */
async function fixture(name) {
  const trackId = (await req("track.add", { kind: "instrument", name })).id;
  const clips = [];
  for (const beat of [0, 8, 16, 24]) {
    clips.push((await req("clip.addMIDI", {
      trackId, atBeat: beat, lengthBeats: LEN,
      notes: [
        { pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 },
        { pitch: 64, startBeat: 1, lengthBeats: 1, velocity: 100 },
      ],
    })).id);
  }
  await sleep(SETTLE_MS);
  return { trackId, clips };
}

/**
 * Click `order` (indices into `clips`) one at a time; after EVERY click reset
 * both zoom slots, then assert the ⌘+ router aims at the ARRANGE. Returns the
 * per-row records so leg I can ask its invariance question over them.
 *
 * ⚠️ EVERY ROW FROM THE SECOND ON IS ARMED WITH `engage(.pianoRoll)` FIRST, AND
 * THAT IS WHAT MAKES THESE LEGS MEAN ANYTHING. MEASURED (mutant M5, 2026-08-03):
 * without arming, deleting `editorEngagement.engage(.arrange)` from `clickClip`
 * outright reddened only leg F — B, C and D all stayed GREEN. They were passing
 * on a LEFTOVER: the latch starts on `.arrange` and nothing before these legs had
 * moved it, so "the click claimed the arrange" and "nothing ever claimed
 * anything" were the same observation. That is the m23-aj-3 law one level up — a
 * leg that inherits the state it means to assert is not asserting it. Armed, each
 * row is a real transition: the roll holds the surface and the click must TAKE IT
 * BACK.
 *
 * ⚠️ AND ROW 0 IS DELIBERATELY *NOT* ARMED — the two requirements collide there,
 * and this is the resolution rather than an oversight. Arming needs an OPEN roll,
 * so it needs a click to have happened first; the obvious fix (a priming click
 * before the loop) was measured and REJECTED, because the priming click consumes
 * the one `pianoRollEditorFocused == true` reading that leg C exists to sit on.
 * With a prime, leg C's twelve rows all read `false`, the OLD routing sends ⌘+ to
 * the arrange for all of them, and **C1 goes GREEN on the red baseline** — the
 * gate would have stopped being able to see the bug it was written for. So row 0
 * opens the roll (and is the S5 `true` row that kills the old routing) and rows
 * 1…n-1 are armed (and kill M5). Both properties, one sequence.
 */
async function clickRows(label, clips, order) {
  const rows = [];
  for (let i = 0; i < order.length; i++) {
    const id = clips[order[i]];
    // ARM (see the banner): hand the surface to the roll so this row's click has
    // to win it back. Impossible on row 0 — no roll is open yet — and that row
    // carries the other half of the job.
    if (i > 0) await sel({ act: "engage", surface: "pianoRoll" });
    await sel({ act: "click", clipId: id });
    await sleep(SETTLE_MS);
    await resetZooms();
    const { before, after } = await zoomStep("in");
    rows.push({
      i,
      clip: "ABCD"[order[i]],
      surface: before.activeSurface,
      reason: before.reason,
      lastEngaged: before.lastEngaged,
      rollOpen: before.rollOpen,
      focused: before.pianoRollEditorFocused,
      arrangeMoved: movedArrange(before, after),
      rollHeld: heldRoll(before, after),
      arrangePPB: `${before.arrangePPB}->${after.arrangePPB}`,
      rollPPB: `${before.pianoRollPPB}->${after.pianoRollPPB}`,
    });
  }
  const bad = rows.filter((r) => r.surface !== "arrange" || !r.arrangeMoved || !r.rollHeld
    || r.reason !== "engagedArrange" || r.rollOpen !== true);
  console.log(`     ${label}: ${rows.length - bad.length}/${rows.length} rows route to the arrange`);
  for (const r of bad) {
    console.log(`        row ${r.i} (${r.clip}): surface=${r.surface} reason=${r.reason} `
      + `focused=${r.focused} arrange ${r.arrangePPB} roll ${r.rollPPB}`);
  }
  return { rows, bad };
}

let teardownDone = false;
function teardown() {
  if (teardownDone) return;
  teardownDone = true;
  // PIDFILE-EXACT, our OWN child only. Never pkill/pgrep — 17600 is the user's
  // live app and must survive this script by construction.
  stopStaging(GATE, PIDFILE);
}

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });

  // ══ A  BASELINE, ROLL CLOSED ═════════════════════════════════════════════
  const A = await fixture("AL-BASE");
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  await resetZooms();
  {
    const { before, after } = await zoomStep("in");
    check("A1 with NOTHING selected the roll is closed, so the active surface is the "
          + "ARRANGE and the reason says WHY — `noRollOpen`, not a focus outcome",
          before.activeSurface === "arrange" && before.reason === "noRollOpen"
            && before.rollOpen === false,
          `surface=${before.activeSurface} reason=${before.reason} rollOpen=${before.rollOpen}`);
    check("A2 ...and ⌘+ moves the ARRANGE while the roll's slot is byte-identical",
          movedArrange(before, after) && heldRoll(before, after),
          `arrange ${before.arrangePPB}->${after.arrangePPB} `
          + `roll ${before.pianoRollPPB}->${after.pianoRollPPB}`);
  }
  {
    // A bare call is READ-ONLY (the m11-a law) — a report that moved the thing it
    // reports would make every before/after pair above meaningless.
    const r1 = await vz({});
    const r2 = await vz({});
    check("A3 a BARE `debug.viewZoom` is READ-ONLY (m11-a): two consecutive reports "
          + "return identical PPBs and an unchanged engagement seq",
          r1.arrangePPB === r2.arrangePPB && r1.pianoRollPPB === r2.pianoRollPPB
            && r1.engagementSeq === r2.engagementSeq,
          `arrange ${r1.arrangePPB}/${r2.arrangePPB} roll ${r1.pianoRollPPB}/${r2.pianoRollPPB} `
          + `seq ${r1.engagementSeq}/${r2.engagementSeq}`);
  }

  // ══ B  S3-SHAPE SWITCHES ═════════════════════════════════════════════════
  // The probe's S3 (period 4). Every click switches clip, so the roll rebuilds on
  // every one and `pianoRollEditorFocused` alternates 6/6 — the shape the ROADMAP
  // filed. Under the fix the verdict does not move at all.
  const B = await fixture("AL-SWITCH");
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const bRes = await clickRows("B", B.clips, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]);
  check("B1 TWELVE CONSECUTIVE CLIP SWITCHES, each one ARMED with the roll holding "
        + "the surface: every click TAKES IT BACK for the arrange (`engagedArrange`, "
        + "roll still open) and ⌘+ moves the arrange, leaving the roll's slot "
        + "byte-identical. 12/12, not 6/12",
        bRes.bad.length === 0 && bRes.rows.length === 12,
        `${bRes.rows.length - bRes.bad.length}/${bRes.rows.length} rows; `
        + `reasons=${JSON.stringify([...new Set(bRes.rows.map((r) => r.reason))])}`);

  // ══ C  ⭐ S5-SHAPE REPEATS — THE LEG THE ROADMAP'S GATE LACKS ═════════════
  // 12 clicks on ONE clip: `.id(clip.id)` never changes, so NO `PianoRollView` is
  // created or destroyed for the whole sequence. This is where the shipped code
  // reads `true` once and `false` eleven times — i.e. where clicking a clip TWICE
  // aims ⌘+ at the wrong surface for the rest of the session.
  const C = await fixture("AL-REPEAT");
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const cRes = await clickRows("C", C.clips, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  check("C1 ⭐ TWELVE CLICKS ON ONE CLIP (zero rebuilds), each ARMED: the verdict is "
        + "the ARRANGE on all twelve and ⌘+ moves the arrange every time. This is the "
        + "S5 shape — the user-facing half the filed gate could not see",
        cRes.bad.length === 0 && cRes.rows.length === 12,
        `${cRes.rows.length - cRes.bad.length}/${cRes.rows.length} rows; `
        + `reasons=${JSON.stringify([...new Set(cRes.rows.map((r) => r.reason))])}`);

  // ══ D  S4-SHAPE (SWITCH, REPEAT, SWITCH, REPEAT) ═════════════════════════
  const D = await fixture("AL-MIXED");
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const dRes = await clickRows("D", D.clips, [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1]);
  check("D1 the MIXED shape (S4: switch, repeat, switch, repeat) routes to the "
        + "arrange on all twelve — rebuild-driven and click-driven rows agree, "
        + "which is exactly what the old flag could not do",
        dRes.bad.length === 0 && dRes.rows.length === 12,
        `${dRes.rows.length - dRes.bad.length}/${dRes.rows.length} rows`);

  // ══ E  ⭐ THE ROLL ENGAGED — ANTI-VACUITY ════════════════════════════════
  // Without this leg a fix that hardwires `.arrange` passes B, C and D.
  const E = await fixture("AL-ENGAGE");
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: E.clips[0] });
  await sleep(SETTLE_MS);
  await sel({ act: "engage", surface: "pianoRoll" });
  await resetZooms();
  {
    const { before, after } = await zoomStep("in");
    check("E1 ⭐ ENGAGING THE ROLL makes it the active surface, and the reason names "
          + "the term that decided it (`engagedRoll`)",
          before.activeSurface === "pianoRoll" && before.reason === "engagedRoll"
            && before.lastEngaged === "pianoRoll" && before.rollOpen === true,
          `surface=${before.activeSurface} reason=${before.reason} `
          + `lastEngaged=${before.lastEngaged} rollOpen=${before.rollOpen}`);
    check("E2 ...and ⌘+ NOW MOVES THE ROLL while the arrange's slot is "
          + "byte-identical. A fix that hardwired `.arrange` dies here",
          movedRollUp(before, after) && heldArrange(before, after),
          `roll ${before.pianoRollPPB}->${after.pianoRollPPB} `
          + `arrange ${before.arrangePPB}->${after.arrangePPB}`);
  }

  // ══ F  RE-ARMABILITY ═════════════════════════════════════════════════════
  // The m23-ak law, paid for by a forge mutant: A DESYNCHRONISED LATCH CAN NEVER
  // BE RE-CLAIMED. Engaging the roll, taking it away with an arrange click, and
  // engaging it AGAIN must work — and the seq must count TRANSITIONS (3), not
  // calls, which is what pins the change-guard in `engage`.
  const F = await fixture("AL-REARM");
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: F.clips[0] });
  await sleep(SETTLE_MS);
  const f0 = await vz({});
  await sel({ act: "engage", surface: "pianoRoll" });
  const f1 = await vz({});
  await sel({ act: "click", clipId: F.clips[0] });      // a REPEAT click — S5's shape
  await sleep(SETTLE_MS);
  const f2 = await vz({});
  await sel({ act: "engage", surface: "pianoRoll" });
  const f3 = await vz({});
  check("F1 the roll can be engaged, LOSE the surface to a repeat arrange click, and "
        + "be engaged AGAIN: pianoRoll -> arrange -> pianoRoll",
        f1.activeSurface === "pianoRoll" && f2.activeSurface === "arrange"
          && f2.reason === "engagedArrange" && f3.activeSurface === "pianoRoll",
        `${f0.activeSurface} -> ${f1.activeSurface} -> ${f2.activeSurface} (${f2.reason}) `
        + `-> ${f3.activeSurface}`);
  check("F2 ...and the engagement seq grew by EXACTLY 3 — it counts TRANSITIONS, not "
        + "calls, so the change-guard in `engage` is intact (without it every drag "
        + "tick would bump it and storm every @Observable observer)",
        f3.engagementSeq - f0.engagementSeq === 3,
        `seq ${f0.engagementSeq} -> ${f1.engagementSeq} -> ${f2.engagementSeq} `
        + `-> ${f3.engagementSeq} (+${f3.engagementSeq - f0.engagementSeq})`);

  // ⚠️ F3 EXISTS BECAUSE F2 CANNOT DO THIS JOB, AND THAT WAS MEASURED, NOT
  // GUESSED. The design assigned the change-guard to "F's exact +3"; mutant M6
  // (guard removed, so the seq bumps on EVERY call) ran 22/22 GREEN. The reason
  // is structural: every engage in F's own sequence — roll, arrange-via-click,
  // roll — is a GENUINE TRANSITION, so a guarded and an unguarded counter agree
  // exactly. Only a REPEAT of the same surface separates them, and F1/F2 never
  // repeat one. This leg does.
  const g0 = await vz({});
  await sel({ act: "engage", surface: "pianoRoll" });   // already the roll: no-op
  await sel({ act: "engage", surface: "pianoRoll" });
  const g1 = await vz({});
  await sel({ act: "click", clipId: F.clips[0] });      // arrange: ONE transition
  await sleep(SETTLE_MS);
  await sel({ act: "click", clipId: F.clips[0] });      // repeat: no-op
  await sel({ act: "click", clipId: F.clips[0] });      // repeat: no-op
  await sleep(SETTLE_MS);
  const g2 = await vz({});
  check("F3 REPEATS ARE NOT TRANSITIONS: engaging the roll twice more while it is "
        + "ALREADY engaged moves the seq by 0, and three consecutive clicks on the "
        + "same clip move it by exactly 1. This is the change-guard, and it is not "
        + "an optimisation — `beginGesture` and `scrubDrag.onChanged` fire on every "
        + "tick of every drag, so an unguarded write would invalidate every observer "
        + "of the engagement object at pointer rate",
        g1.engagementSeq === g0.engagementSeq
          && g2.engagementSeq === g1.engagementSeq + 1
          && g2.activeSurface === "arrange",
        `roll+roll: ${g0.engagementSeq} -> ${g1.engagementSeq} (+`
        + `${g1.engagementSeq - g0.engagementSeq}, want +0); then click×3: `
        + `-> ${g2.engagementSeq} (+${g2.engagementSeq - g1.engagementSeq}, want +1); `
        + `surface=${g2.activeSurface}`);

  // ══ G  ⭐ CLOSE THE ROLL WHILE IT IS ENGAGED ═════════════════════════════
  // Proves `rollOpen` is a LIVE term and that the latch is not consulted once the
  // surface is gone. Without it, `resolve` could drop the term and stay green.
  const G = await fixture("AL-CLOSE");
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: G.clips[0] });
  await sleep(SETTLE_MS);
  await sel({ act: "engage", surface: "pianoRoll" });
  const gEngaged = await vz({});
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  await resetZooms();
  {
    const { before, after } = await zoomStep("in");
    check("G1 ⭐ CLOSING THE ROLL (clear the selection) hands the surface straight "
          + "back to the arrange with `noRollOpen` — WHILE THE LATCH STILL SAYS "
          + "`pianoRoll`. A closed roll can never be the active surface",
          gEngaged.activeSurface === "pianoRoll"
            && before.activeSurface === "arrange" && before.reason === "noRollOpen"
            && before.rollOpen === false && before.lastEngaged === "pianoRoll",
          `engaged=${gEngaged.activeSurface} -> surface=${before.activeSurface} `
          + `reason=${before.reason} rollOpen=${before.rollOpen} `
          + `lastEngaged=${before.lastEngaged}`);
    check("G2 ...and ⌘+ moves the arrange, not the invisible roll",
          movedArrange(before, after) && heldRoll(before, after),
          `arrange ${before.arrangePPB}->${after.arrangePPB} `
          + `roll ${before.pianoRollPPB}->${after.pianoRollPPB}`);
  }

  // ══ H  ALL THREE ENTRY POINTS READ THE ONE HOME ══════════════════════════
  // in / out / reset. A fix that migrated two of the three and left `zoomReset`
  // on the old flag passes every leg above.
  const H = await fixture("AL-TRIPLE");
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: H.clips[0] });
  await sleep(SETTLE_MS);
  await sel({ act: "engage", surface: "pianoRoll" });
  // Arrange staged to a NON-DEFAULT so `reset` has something to wrongly restore.
  await req("debug.arrangeZoom", { ppb: 40 });
  await req("debug.panelLayout", { pianoRollPPB: ROLL_DEFAULT_PPB });
  {
    const { before, after } = await zoomStep("out");
    check("H1 with the roll active, ⌘− moves ONLY the roll and leaves the arrange at "
          + "its staged non-default",
          before.activeSurface === "pianoRoll" && movedRollDown(before, after)
            && heldArrange(before, after) && after.arrangePPB === 40,
          `surface=${before.activeSurface} roll ${before.pianoRollPPB}->${after.pianoRollPPB} `
          + `arrange ${before.arrangePPB}->${after.arrangePPB}`);
  }
  {
    const { before, after } = await zoomStep("reset");
    check("H2 ...and ⌘0 resets ONLY the roll (back to 32) — the arrange stays at 40, "
          + "so `zoomReset` reads the same home `zoomIn`/`zoomOut` do",
          after.pianoRollPPB === ROLL_DEFAULT_PPB && after.arrangePPB === 40,
          `roll ${before.pianoRollPPB}->${after.pianoRollPPB} `
          + `arrange ${before.arrangePPB}->${after.arrangePPB}`);
  }

  // ══ I  ⭐ INVARIANCE TO THE OLD FLAG ═════════════════════════════════════
  // The instrument stays fed and echoed; nothing routes on it. This leg reads the
  // B and C rows back and asks whether the VERDICT moved with the flag.
  const iRows = [...bRes.rows, ...cRes.rows];
  const sawTrue = iRows.some((r) => r.focused === true);
  const sawFalse = iRows.some((r) => r.focused === false);
  check("I0 FIXTURE CHECK, ASKED FIRST: `pianoRollEditorFocused` really does take "
        + "BOTH values across B and C (S1–S5 guarantee it — 6/6 on switches, "
        + "true-once-then-false on repeats). If it did not, every leg below would "
        + "be invariant to a constant and the whole leg would be VACUOUS",
        sawTrue && sawFalse,
        `true rows=${iRows.filter((r) => r.focused === true).length} `
        + `false rows=${iRows.filter((r) => r.focused === false).length} `
        + `(B: ${bRes.rows.map((r) => (r.focused ? "T" : "f")).join("")}, `
        + `C: ${cRes.rows.map((r) => (r.focused ? "T" : "f")).join("")})`);
  {
    const onTrue = iRows.filter((r) => r.focused === true);
    const onFalse = iRows.filter((r) => r.focused === false);
    check("I1 ⭐ THE VERDICT IS INVARIANT TO THE ALTERNATING FLAG: every row reads "
          + "`arrange` on the `true` rows AND on the `false` rows. The old flag is "
          + "still moving underneath — it is an INSTRUMENT now, unread by any "
          + "routing decision",
          onTrue.every((r) => r.surface === "arrange" && r.arrangeMoved)
            && onFalse.every((r) => r.surface === "arrange" && r.arrangeMoved),
          // BOTH TERMS in the detail, separately. The first draft printed only the
          // surface count, so on the red baseline this leg reddened while its own
          // message read `7/7 arrange` — a failure line that looked like a pass.
          // A red leg must say WHICH half was not in the state it assumed.
          `on true (n=${onTrue.length}): verdict=arrange on `
          + `${onTrue.filter((r) => r.surface === "arrange").length}, ⌘+ moved the arrange on `
          + `${onTrue.filter((r) => r.arrangeMoved).length}; `
          + `on false (n=${onFalse.length}): verdict=arrange on `
          + `${onFalse.filter((r) => r.surface === "arrange").length}, ⌘+ moved the arrange on `
          + `${onFalse.filter((r) => r.arrangeMoved).length}`);
  }

  // ══ J  SEAM HONESTY ══════════════════════════════════════════════════════
  // `automationPoints`' law (`DAWProApp.swift:3983-3993`): an UNSATISFIABLE
  // request is TOLD, never answered green. A gate handed `ok` for an engagement
  // the resolver will immediately override as `.arrange` has been given a false
  // "fixture armed" — the m23-x failure class (9 of 46 red, every one a control).
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  let jThrew = null;
  try {
    await sel({ act: "engage", surface: "pianoRoll" });
  } catch (e) { jThrew = e.message; }
  check("J1 `act:\"engage\" surface:\"pianoRoll\"` with NO ROLL OPEN THROWS rather "
        + "than answering green — a fixture that cannot be armed says so",
        jThrew !== null && /piano ?roll/i.test(jThrew),
        jThrew === null ? "answered OK — no error raised" : jThrew.slice(0, 200));
  let jArrangeOk = false;
  try {
    const r = await sel({ act: "engage", surface: "arrange" });
    jArrangeOk = r.lastEngagedSurface === "arrange";
  } catch (e) { jArrangeOk = false; }
  check("J2 ...and the CONTROL half: `surface:\"arrange\"` with no roll open still "
        + "succeeds, so J1's throw is about an unsatisfiable ROLL engagement and "
        + "not about the act being broken",
        jArrangeOk, `lastEngagedSurface reported arrange = ${jArrangeOk}`);

  // ══ K  ⭐ THE MIX WORKSPACE — THE TERM MOST LIKELY TO BE SIMPLIFIED AWAY ══
  // `openEditorClip` carries NO workspace term, so in the Mix console a MIDI clip
  // stays selected with NO `PianoRollView` mounted at all. Without the workspace
  // term a latched roll engagement zooms an editor the user cannot see.
  const K = await fixture("AL-MIX");
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: K.clips[0] });
  await sleep(SETTLE_MS);
  await sel({ act: "engage", surface: "pianoRoll" });
  await resetZooms();
  const kArrange = await vz({});
  await req("ui.showMixer", { show: true });
  await sleep(SETTLE_MS);
  {
    const { before, after } = await zoomStep("in");
    check("K1 ⭐ IN THE MIX CONSOLE the active surface falls back to the ARRANGE with "
          + "`notArrangeWorkspace` — WHILE `rollOpen` IS STILL TRUE and the latch "
          + "still says `pianoRoll`. Those two facts together are the whole point: "
          + "the clip is still selected, but no roll is MOUNTED",
          kArrange.activeSurface === "pianoRoll"
            && before.activeSurface === "arrange"
            && before.reason === "notArrangeWorkspace"
            && before.rollOpen === true && before.lastEngaged === "pianoRoll",
          `arrange-workspace=${kArrange.activeSurface} -> mix surface=${before.activeSurface} `
          + `reason=${before.reason} rollOpen=${before.rollOpen} `
          + `lastEngaged=${before.lastEngaged}`);
    check("K2 ...and ⌘+ moves the arrange behind the console rather than an "
          + "unmounted editor",
          movedArrange(before, after) && heldRoll(before, after),
          `arrange ${before.arrangePPB}->${after.arrangePPB} `
          + `roll ${before.pianoRollPPB}->${after.pianoRollPPB}`);
  }
  await req("ui.showMixer", { show: false });
  await sleep(SETTLE_MS);
  {
    const back = await vz({});
    check("K3 ...and coming BACK to the arrange workspace restores the roll as the "
          + "active surface: the workspace term is live in both directions and the "
          + "latch was never destroyed by the detour",
          back.activeSurface === "pianoRoll" && back.reason === "engagedRoll",
          `surface=${back.activeSurface} reason=${back.reason} `
          + `lastEngaged=${back.lastEngaged}`);
  }

  // ══ ECHO PARITY ══════════════════════════════════════════════════════════
  // The new verdict is echoed on `debug.arrangeSelection` BESIDE the old flag,
  // never replacing it — that is what makes the DIVERGENCE observable instead of
  // invisible (it was invisible for two cycles).
  {
    const e = await sel({});
    const z = await vz({});
    check("P1 both seams report the SAME verdict from the SAME home, and the old "
          + "instrument is STILL FED alongside it (never replaced)",
          e.activeEditorSurface === z.activeSurface
            && e.activeEditorSurfaceReason === z.reason
            && e.lastEngagedSurface === z.lastEngaged
            && e.engagementSeq === z.engagementSeq
            && typeof e.pianoRollEditorFocused === "boolean",
          `sel=${e.activeEditorSurface}/${e.activeEditorSurfaceReason}/`
          + `${e.lastEngagedSurface}/${e.engagementSeq} vz=${z.activeSurface}/${z.reason}/`
          + `${z.lastEngaged}/${z.engagementSeq} oldFlag=${e.pianoRollEditorFocused}`);
  }

  // ══ Recorded as SKIP, never as a pass ════════════════════════════════════
  skip("the link `real gesture -> engage(...)`",
       "The seam calls `editorEngagement.engage` directly, so a mutant that deleted "
       + "the call from `PianoRollView.beginGesture` (R1) or from `clickClip` would "
       + "still pass every leg that drives the seam — M5 in the design's table is "
       + "detectable ONLY because `act:\"click\"` runs the real `clickClip` body. "
       + "The roll's eight funnels R1–R8 are NOT reachable from any seam in this "
       + "tree. Their substitute is structural: "
       + "`Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` asserts each "
       + "funnel exists in source and PINS the count of gesture attachments under "
       + "`Sources/DAWApp/PianoRoll/`, so a new gesture reddens a test and forces "
       + "its author to decide whether it engages. Same class as m23-aj-3's leg G "
       + "and m23-ak's DELETE half. NOT counted as a pass.");
  skip("whether a REAL ⌘+ key equivalent reaches `zoomIn()`",
       "m21-c routes the View-menu key equivalents app-side ON PURPOSE (they fire "
       + "before any focused view sees the key), and `debug.viewZoom` calls the SAME "
       + "`model.zoomIn()/zoomOut()/zoomReset()` the menu items "
       + "(`ViewCommands.swift:20/22/24`) and the ⌘= alias (`ContentView.swift:326`) "
       + "call — never the per-surface entry points. What is not exercised here is "
       + "AppKit delivering the equivalent to the menu at all, which an unbundled "
       + "staging binary cannot do (m23-g1, m23-bw ①).");

  // ══ SUMMARY ══════════════════════════════════════════════════════════════
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} assertions passed`
    + `  (${skips.length} skipped)`);
  for (const c of failed) console.log(`  FAILED: ${c.name} — ${c.detail}`);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  teardown();
  process.exit(failed.length ? 1 : 0);
} catch (err) {
  console.error("GATE ERROR:", err);
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
  process.exit(2);
}
