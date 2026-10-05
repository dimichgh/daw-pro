#!/usr/bin/env node
// m34-d — ⌘A WORKS ON THE FIRST PRESS, WHENEVER THE EDITOR IS OPEN.
//
// ══ THE USER'S RULING ═══════════════════════════════════════════════════════
// 2026-08-30: *"⌘A does nothing on the first press."* Opening a clip showed the
// piano roll but did not yet count as being IN it; one click inside and ⌘A
// worked every time. They ruled, verbatim:
//
//     "Make it work whenever the editor is open."
//
// THE FIX: `SelectAllMenuPolicy`'s first guard moved from
// `EditorSurfaceRouter.resolve` (ENGAGEMENT — "which surface did the user last
// act inside") to `.openSurface` (MOUNT — "which surface is on screen"). No
// NSEvent monitor was added and no SwiftUI focus was rearranged: ⌘A already
// rode AppKit's `selectAll:` correctly, and MEASURED BEFORE ANY EDIT
// (`_m34d-select-all-probe.mjs`) a REAL posted ⌘A reached the real menu and
// selected nothing, then selected everything after one `act:"engage"`. Delivery
// was never the defect; the policy was.
//
// ══ TWO TIERS, AND WHY THE SPLIT IS NOT COSMETIC ═══════════════════════════
//
//   K — THE REAL-KEY TIER. Every ⌘A is a real `NSEvent` posted through
//       `NSApp.postEvent`: the real queue, the real `NSApplication.sendEvent`,
//       the real main-menu key-equivalent dispatch, the real responder chain.
//       This is the only tier that can see DELIVERY, and the only one that can
//       pin the text-field guard (which is STRUCTURAL, not a policy term).
//
//   P — THE POLICY TIER. Reads the app's OWN live verdict for Edit ▸ Select All
//       (`debug.arrangeSelection {}` → `selectAllMenuItem`), which is
//       deterministic and independent of window activation. **The item's claim
//       is proved here** — so if K has to skip, this gate still says whether
//       ⌘A is live on the first press; it just says less about delivery.
//
// ⚠️⚠️ **WHY K IS CONDITIONAL, MEASURED ACROSS 3 RUNS 2026-08-30 (NOT ASSUMED).**
// AppKit dispatches a posted menu key equivalent only while the app is ACTIVE
// (an inactive app has no `keyWindow`, so `NSApp.target(forAction:)` finds no
// target and the item is never validated or fired). Staging DELIBERATELY never
// calls `NSApp.activate` — it must not steal the user's system focus — so it can
// run inactive, which is the m23-fi law already recorded on `debug.keySpace`'s
// `appActive` field. The correlation is exact:
//
//     run 1  appActive=true   selectAllNonce 0→1→2→3→4→5   every leg green
//     run 2  appActive=true   selectAllNonce 0→1→2→3→4→5   every leg green
//     run 3  appActive=false  selectAllNonce 0→1, then STUCK — every posted
//                             ⌘A after the app lost activation did nothing,
//                             while the POLICY read "piano-roll-notes" the
//                             whole time
//
// ⭐ SO A RED K LEG ON AN INACTIVE APP WOULD BE A FALSE NEGATIVE ABOUT THE
// PRODUCT, and a silent skip would be a false positive about the gate. K is
// therefore GATED on `appActive` and its skipped legs are COUNTED AND NAMED in
// the closing banner. Keep the staging window frontmost to get the full run.
//
// ⚠️⚠️ **HONEST LIMIT, EVEN AT FULL COVERAGE: NO GATE IN THIS TREE CAN PRESS A
// PHYSICAL KEY.** A posted `NSEvent` is the strongest evidence available and is
// strictly stronger than a `debug.*` seam — it exercises delivery, not just the
// handler — but it is synthesized. **The first-press fix wants a human to
// confirm once at a real keyboard.** Nothing below claims otherwise.
//
// Staging 17695 only. 17600 is the user's live app and is never contacted.
import {
  buildOrAbort, startStaging, stopStaging, sleep, verdict,
} from "./_staging.mjs";

const GATE = "m34d-select-all-editor-open";
const PORT = 17695;
const SETTLE_MS = 700;
const MARKER_BEAT = 8;

buildOrAbort({ label: "building staging binary (m34-d)…" });
startStaging({ gate: GATE, port: PORT });

async function connect() {
  for (let i = 0; i < 40; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => {
        ws.onopen = res;
        ws.onerror = () => rej(new Error("x"));
      });
      let nextId = 1;
      const pending = new Map();
      ws.onmessage = (ev) => {
        let m;
        try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id);
        if (!e) return;
        pending.delete(m.id);
        if (m.ok === false || m.error) {
          e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        } else {
          e.resolve(m.result ?? m);
        }
      };
      const req = (command, params = {}) => new Promise((resolve, reject) => {
        const id = String(nextId++);
        pending.set(id, { resolve, reject, command });
        ws.send(JSON.stringify({ id, command, params }));
        setTimeout(() => {
          if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
        }, 25000);
      });
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const checks = [];
const skipped = [];
function check(label, ok, detail = "") {
  checks.push({ label, ok });
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${ok || !detail ? "" : `\n     << ${detail}`}`);
}
function skip(label, why) {
  skipped.push(label);
  console.log(`SKIP ${label}\n     << ${why}`);
}

// ⚠️⚠️ **ACTIVATION IS RE-READ AROUND EVERY SINGLE PRESS, NOT ONCE PER TIER, AND
// THAT IS A MEASURED CORRECTION RATHER THAN CAUTION.** An earlier draft sampled
// `appActive` only at K0 and then went red at K8b with `nonce 1->1` — the app had
// lost activation partway through the run, so a posted ⌘A stopped being
// dispatched while the POLICY still read "piano-roll-notes". That is a false
// negative about the product wearing a product failure's clothes. Both ends are
// read because activation can drop between the press and the readback.
async function pressCmdA(sel, req) {
  const before = (await req("debug.keySpace", {})).appActive === true;
  await sel(CMD_A);
  await sleep(SETTLE_MS);
  const after = (await req("debug.keySpace", {})).appActive === true;
  return before && after;
}

// A K leg whose subject is a posted ⌘A. Reports SKIP — never FAIL — when the app
// was not active across the press, because in that state AppKit never offered the
// key to the menu at all and the leg has no subject to speak about.
function kleg(active, label, cond, detail) {
  if (!active) {
    skip(label,
         "the app was NOT ACTIVE across this press. AppKit does not dispatch a "
         + "posted menu key equivalent to an inactive app (no keyWindow ⇒ no "
         + "target ⇒ the item is never validated or fired) — MEASURED, 3 runs, "
         + "exact correlation with `selectAllNonce` freezing. A red here would be "
         + "a false negative about the product; the P tier is unaffected.");
    return;
  }
  check(label, cond, detail);
}

// ⭐ A REAL ⌘A. `kVK_ANSI_A` is 0; AppKit matches menu key equivalents on the
// event's `charactersIgnoringModifiers`, so "a" (97) is load-bearing too. `key`
// only picks the `ProbeKey` the seam requires — every field that matters is
// overridden, and the seam posts through `NSApp.postEvent` with `.command` set.
//
// ⚠️ MATCHED BY VIRTUAL KEY CODE, NOT BY CHARACTER (the m23-fi rule): the user
// confirmed in the field that switching input language still plays correctly.
// `keyCode: 0` is the physical A key on every layout.
const CMD_A = { act: "postKey", key: "escape", keyCode: 0, charCode: 97, command: true };

let ws;
try {
  const c = await connect();
  ws = c.ws;
  const req = c.req;
  const sel = (p = {}) => req("debug.arrangeSelection", p);
  const policy = (s) => s.selectAllMenuItem ?? {};

  await req("project.new", { discardChanges: true });
  const track = await req("track.add", { name: "Keys", kind: "instrument" });
  const trackId = track.id ?? track.track?.id;
  const mkClip = (atBeat, notes) => req("clip.addMIDI", {
    trackId, atBeat, lengthBeats: 4, notes,
  });
  const three = (b) => [0, 1, 2].map((i) => (
    { pitch: 60 + i * 4, velocity: 100, startBeat: b + i, lengthBeats: 1 }));
  // ⭐ THREE CLIPS ON PURPOSE.
  //  • TWO with notes, because a single clip makes every "the arrange did not
  //    gain a selection" conjunct vacuous — with one clip, `count === 1` is
  //    indistinguishable from an arrange-wide select-all that shipped by
  //    accident. With two, that mistake reads `count === 2`.
  //  • ONE EMPTY, so the `empty-roll` refusal is reachable from a real fixture
  //    rather than only from the unit sweep.
  const clipA = (await mkClip(0, three(0))).id;
  const clipB = (await mkClip(8, three(8))).id;
  const clipEmpty = (await mkClip(16, [])).id;

  // ══════════════════════════════════════════════════════════════════════════
  // K — THE REAL-KEY TIER. Run FIRST, while the freshly launched app is most
  // likely still frontmost.
  // ══════════════════════════════════════════════════════════════════════════

  // Open the roll THE WAY THE USER DOES: click the clip in the arrange. Not
  // `act:"engage"` — that is the very gesture the user should not have to make,
  // and a fixture that made it would test the state AFTER the bug.
  await sel({ act: "click", clipId: clipA });
  await sleep(SETTLE_MS);
  const k0 = await sel({});
  // ⭐ BOUNDED WAIT FOR ACTIVATION, not a bare sample. A freshly launched GUI app
  // normally becomes active, but not instantly — and the K tier's whole value
  // depends on catching that window. Bounded so a genuinely background run costs
  // ~3 s and then skips honestly, rather than hanging waiting for something that
  // will never happen. NOTHING HERE CALLS `NSApp.activate`: staging must never
  // steal the user's system focus, so this waits for activation, it never takes it.
  let k0keys = await req("debug.keySpace", {});
  for (let i = 0; i < 12 && k0keys.appActive !== true; i++) {
    await sleep(250);
    k0keys = await req("debug.keySpace", {});
  }
  const appActive = k0keys.appActive === true;

  check("K0 ⭐ FIXTURE ARMED IN THE EXACT BUGGY STATE: the roll is OPEN on clipA, "
        + "the ARRANGE is still the engaged surface (this IS the first press), "
        + "no notes are selected, no text field is focused, and exactly ONE of "
        + "the three clips is selected",
        k0.editorClipId === clipA
        && k0.activeEditorSurfaceReason === "engagedArrange"
        && k0.activeEditorSurface === "arrange"
        && k0.pianoRollNoteSelection === false
        && k0.pianoRollSelectAllNonce === 0
        && k0.count === 1 && k0.textEditing === false,
        `editorClipId=${k0.editorClipId === clipA} `
        + `reason=${k0.activeEditorSurfaceReason} surface=${k0.activeEditorSurface} `
        + `notes=${k0.pianoRollNoteSelection} nonce=${k0.pianoRollSelectAllNonce} `
        + `count=${k0.count} textEditing=${k0.textEditing}`);

  if (!appActive) {
    skip("K1–K8 (the whole real-key tier)",
         "`appActive` is FALSE — this staging app is not the active application, "
         + "and AppKit does not dispatch a posted menu key equivalent to an "
         + "inactive app (no keyWindow ⇒ no target ⇒ the item is never validated "
         + "or fired). MEASURED, 3 runs, exact correlation. This is a HARNESS "
         + "condition, NOT a product failure: the P tier below reads the app's "
         + "own policy verdict and is unaffected. Re-run with the staging window "
         + "frontmost for delivery coverage.");
  } else {
    // ── K1/K2/K3 — THE FIX ──────────────────────────────────────────────────
    const act1 = await pressCmdA(sel, req);
    const k1 = await sel({});
    kleg(act1, "K1 ⭐⭐ THE USER'S BUG, CLOSED WITH A REAL KEY: a REAL ⌘A on the FIRST "
          + "press — roll open, arrange still engaged — reaches the real menu "
          + "(the request nonce climbs) and selects the roll's notes",
          k1.pianoRollSelectAllNonce === 1 && k1.pianoRollNoteSelection === true,
          `nonce ${k0.pianoRollSelectAllNonce}->${k1.pianoRollSelectAllNonce} `
          + `notes ${k0.pianoRollNoteSelection}->${k1.pianoRollNoteSelection}`);

    kleg(act1, "K2 ⭐ AND IT REALLY WAS THE FIRST PRESS: engagement is UNCHANGED "
          + "across it — still \"engagedArrange\", zero transitions since K0. "
          + "The fix must not work by quietly engaging the roll on the user's "
          + "behalf; that would be the same bug wearing a fix's clothes",
          k1.activeEditorSurfaceReason === "engagedArrange"
          && k1.lastEngagedSurface === "arrange"
          && k1.engagementSeq === k0.engagementSeq,
          `reason=${k1.activeEditorSurfaceReason} lastEngaged=${k1.lastEngagedSurface} `
          + `engagementSeq ${k0.engagementSeq}->${k1.engagementSeq}`);

    kleg(act1, "K3 ⚠️ THE SCOPE GUARD HELD: ⌘A selected NOTES and did NOT invent an "
          + "arrange-wide select-all — the other two clips are still unselected "
          + "(m25-s's boundary, which m34-d widened WHEN, never WHAT)",
          k1.count === 1 && k1.selectedIds[0] === clipA,
          `count=${k1.count} selected=${JSON.stringify(k1.selectedIds)} `
          + `others=${clipB},${clipEmpty}`);

    // ── K4 — THE INJECTION CONTROL ──────────────────────────────────────────
    // ⭐ Without this a green K1 could be luck and a red one could be the
    // harness. A posted SPACE rides a DIFFERENT route (the m17-d NSEvent
    // monitor) to a DIFFERENT effect, so it proves `NSApp.postEvent` delivers on
    // THIS run without touching anything ⌘A depends on.
    const t0 = await req("debug.keySpace", {});
    await req("debug.keySpace", { press: true, post: true });
    await sleep(SETTLE_MS);
    const t1 = await req("debug.keySpace", {});
    // ⚠️ THIS IS A CONTROL FOR THE QUEUE, **NOT** FOR ⌘A DISPATCH, and the
    // distinction is measured rather than pedantic: a posted SPACE reaches the
    // m17-d NSEvent LOCAL MONITOR, which fires whether or not the app is active,
    // while a posted ⌘A needs the MAIN MENU, which needs a key window, which
    // needs an active app. So this can be green in a run where every ⌘A leg was
    // correctly skipped. `appActive` is the control for those; this is the
    // control for "does `NSApp.postEvent` reach this process at all".
    check("K4 ⭐ QUEUE CONTROL: `NSApp.postEvent` genuinely reaches this process "
          + "— a posted SPACE toggles the transport through the NSEvent monitor. "
          + "If this is red, every other K leg says nothing about the app",
          t1.monitorInstalled === true && t0.isPlaying !== t1.isPlaying,
          `monitorInstalled=${t1.monitorInstalled} isPlaying ${t0.isPlaying}->${t1.isPlaying}`);
    await req("transport.stop", {});

    // ── K5 — THE ⌘ IS LOAD-BEARING ──────────────────────────────────────────
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(SETTLE_MS);
    const k5pre = await sel({});
    const act5before = (await req("debug.keySpace", {})).appActive === true;
    await sel({ act: "postKey", key: "escape", keyCode: 0, charCode: 97 });
    await sleep(SETTLE_MS);
    const act5 = act5before && (await req("debug.keySpace", {})).appActive === true;
    const k5 = await sel({});
    kleg(act5, "K5 ⭐ THE ⌘ IS LOAD-BEARING: the SAME posted key WITHOUT command "
          + "neither reaches the menu (nonce frozen) nor selects the notes — K1 "
          + "is about ⌘A, not about any key arriving",
          k5pre.pianoRollNoteSelection === false
          && k5.pianoRollNoteSelection === false
          && k5.pianoRollSelectAllNonce === k5pre.pianoRollSelectAllNonce,
          `pre=${k5pre.pianoRollNoteSelection} after bare-a=${k5.pianoRollNoteSelection} `
          + `nonce ${k5pre.pianoRollSelectAllNonce}->${k5.pianoRollSelectAllNonce}`);

    // ── K6/K7 — ⌘A MUST NOT STEAL FROM A TEXT FIELD ─────────────────────────
    // ⚠️ THE SINGLE MOST LIKELY REGRESSION, AND IT CANNOT BE PINNED BY A UNIT
    // TEST. The safety is STRUCTURAL, not a policy term: AppKit resolves a
    // nil-target `selectAll:` to the first responder that claims it, and every
    // text surface sits nearer the front of the chain than the window our
    // responder is spliced behind (MEASURED at m25-s for `selectAll:`
    // specifically — with a field editor focused, `validateMenuItem` was not
    // called at all). `SelectAllMenuPolicy` has NO text-focus term to assert,
    // so only a real posted event can show the chain still behaves.
    await req("marker.add", { beat: MARKER_BEAT, name: "RenameMe" });
    await req("debug.markerRename", {});
    await sleep(SETTLE_MS);
    const k6f = await req("debug.keySpace", {});
    const k6 = await sel({});
    check("K6a ⭐ FIXTURE ARMED: a rename field really holds focus (a real, "
          + "non-empty string matching the marker's name, and the app classifies "
          + "the responder as text-editing), the roll is STILL OPEN, and the "
          + "policy would otherwise say YES — so there is something to steal",
          typeof k6f.fieldText === "string" && k6f.fieldText === "RenameMe"
          && k6.textEditing === true
          && k6.pianoRollNoteSelection === false
          && k6.editorClipId === clipA
          && policy(k6).surface === "piano-roll-notes",
          `fieldText=${JSON.stringify(k6f.fieldText)} textEditing=${k6.textEditing} `
          + `notes=${k6.pianoRollNoteSelection} policy=${JSON.stringify(policy(k6))}`);

    const act6 = await pressCmdA(sel, req);
    const k7 = await sel({});
    const k7f = await req("debug.keySpace", {});
    kleg(act6, "K6b ⚠️⚠️ ⌘A TYPED INTO A RENAME FIELD DOES NOT TOUCH THE MUSIC: the "
          + "request nonce does NOT climb (our responder was never asked), the "
          + "roll's notes stay unselected, and the arrange gains no clips — with "
          + "the roll OPEN the whole time",
          k7.pianoRollSelectAllNonce === k6.pianoRollSelectAllNonce
          && k7.pianoRollNoteSelection === false
          && k7.count === 1
          && k7.editorClipId === clipA
          && k7f.fieldText === "RenameMe",
          `nonce ${k6.pianoRollSelectAllNonce}->${k7.pianoRollSelectAllNonce} `
          + `notes=${k7.pianoRollNoteSelection} count=${k7.count} `
          + `fieldText=${JSON.stringify(k7f.fieldText)}`);

    // ⭐⭐ AND THE FIELD GENUINELY RECEIVED IT — the conjunct that turns K6b from
    // "nothing happened" into "the right thing happened somewhere else". A ⌫ now
    // empties the field IFF ⌘A selected all eight characters; had our responder
    // stolen the ⌘A, ⌫ would delete ONE character and leave "RenameM". Two
    // outcomes, one keystroke apart, and they are not the same length.
    await sel({ act: "keyDelete", post: true });
    await sleep(SETTLE_MS);
    const k7f2 = await req("debug.keySpace", {});
    kleg(act6, "K7 ⭐⭐ THE TEXT FIELD GOT THE ⌘A, not merely 'nobody did': a following "
          + "⌫ EMPTIES the field, which only happens if ⌘A selected all 8 "
          + "characters. Had our responder stolen it, ⌫ would leave 7",
          typeof k7f2.fieldText === "string" && k7f2.fieldText === "",
          `fieldText ${JSON.stringify(k7f.fieldText)}->${JSON.stringify(k7f2.fieldText)} `
          + `(a stolen ⌘A would read "RenameM")`);

    // GATE LAW (m17-d): clear text focus via `debug.markerRename {clear:true}`,
    // never a staged click — `debug.arrangePointer` runs SwiftUI's gesture
    // handlers directly, produces no NSEvent, and cannot resign a field editor.
    await req("debug.markerRename", { clear: true });
    await sleep(SETTLE_MS);

    // ── K8 — IT IS NOT A ONE-SHOT ───────────────────────────────────────────
    // The route is nonce-driven (`PianoRollNoteSelectionBridge.selectAllNonce`),
    // and a nonce that only ever climbs once is a feature that works exactly one
    // time per session.
    //
    // ⚠️ ARMED BY STAGING `true` FIRST, AND THAT IS THE SEAM'S OWN DOCUMENTED
    // ASYMMETRY RATHER THAN BELT-AND-BRACES: `{act:"pianoRollNotes",
    // select:false}` succeeds TRIVIALLY when no roll is mounted (it waits for
    // `hasSelection == select` and both are already false), so a `false`-only
    // arm cannot tell a mounted roll from an absent one. MEASURED: an early
    // draft of this leg was red with a `false`-only fixture.
    const k8arm = await sel({ act: "pianoRollNotes", select: true });
    await sleep(SETTLE_MS);
    const k8a = await sel({});
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(SETTLE_MS);
    const k8b = await sel({});
    check("K8a ⭐ FIXTURE ARMED THE NON-TRIVIAL WAY: the roll is genuinely "
          + "MOUNTED AND OBSERVING — staging `true` TOOK (→true) and the "
          + "following `false` took as well. A `false`-only arm would report the "
          + "same numbers against a roll that never mounted",
          k8arm !== undefined && k8a.pianoRollNoteSelection === true
          && k8b.pianoRollNoteSelection === false,
          `staged true -> ${k8a.pianoRollNoteSelection}, then false -> `
          + `${k8b.pianoRollNoteSelection}`);

    const act8 = await pressCmdA(sel, req);
    const k8 = await sel({});
    kleg(act8, "K8b ⭐ REPEATABLE: a LATER real ⌘A selects again — the nonce climbs a "
          + "second time and the notes come back, still on \"engagedArrange\". "
          + "The fix is not one-shot and does not depend on anything the first "
          + "press left behind",
          k8.pianoRollSelectAllNonce === k8b.pianoRollSelectAllNonce + 1
          && k8.pianoRollNoteSelection === true
          && k8.activeEditorSurfaceReason === "engagedArrange",
          `nonce ${k8b.pianoRollSelectAllNonce}->${k8.pianoRollSelectAllNonce} `
          + `notes ${k8b.pianoRollNoteSelection}->${k8.pianoRollNoteSelection} `
          + `reason=${k8.activeEditorSurfaceReason}`);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // P — THE POLICY TIER. Deterministic, activation-independent. THIS is where
  // the item's claim is proved; K adds delivery evidence on top of it.
  // ══════════════════════════════════════════════════════════════════════════
  await sel({ act: "click", clipId: clipA });
  await sleep(SETTLE_MS);
  const p1 = await sel({});
  check("P1 ⭐⭐ THE ITEM'S CLAIM, INDEPENDENT OF ANY KEYSTROKE: with the roll "
        + "merely OPEN and the ARRANGE still engaged, Edit ▸ Select All is LIVE "
        + "and targets the roll's notes. Before m34-d this same state answered "
        + "refusedBy=\"not-piano-roll\"",
        p1.activeEditorSurfaceReason === "engagedArrange"
        && policy(p1).enabled === true
        && policy(p1).surface === "piano-roll-notes"
        && policy(p1).refusedBy === null
        && policy(p1).rollNoteCount === 3,
        `reason=${p1.activeEditorSurfaceReason} policy=${JSON.stringify(policy(p1))}`);

  await sel({ act: "engage", surface: "pianoRoll" });
  await sleep(SETTLE_MS);
  const p2 = await sel({});
  check("P2 ⭐ AND ENGAGING THE ROLL CHANGES NOTHING — which is the whole point "
        + "of the ruling. Before m34-d this was the ONLY live state; now the "
        + "verdict is identical either side of the click the user should not "
        + "have had to make",
        p2.activeEditorSurfaceReason === "engagedRoll"
        && policy(p2).surface === policy(p1).surface
        && policy(p2).enabled === policy(p1).enabled,
        `reason=${p2.activeEditorSurfaceReason} `
        + `policy ${JSON.stringify(policy(p1))} -> ${JSON.stringify(policy(p2))}`);

  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const p3 = await sel({});
  check("P3 ⚠️ NO EDITOR OPEN still refuses, under its OWN name — and the "
        + "arrange-wide select-all m25-s refused to invent is still not "
        + "invented (three clips exist and none is selected)",
        p3.editorClipId === null && p3.count === 0
        && policy(p3).enabled === false
        && policy(p3).refusedBy === "no-roll-open"
        && policy(p3).surface === null,
        `editorClipId=${p3.editorClipId} count=${p3.count} `
        + `policy=${JSON.stringify(policy(p3))}`);

  // ⚠️ THE WORKSPACE TERM — `EditorSurfaceRouter` calls it "the easiest thing to
  // drop", and dropping it costs MORE for ⌘A than for zoom: `openEditorClip`
  // stays non-nil in the Mix console while no `PianoRollView` is mounted, so a
  // policy without the term would select notes in a roll that is not on screen.
  await sel({ act: "click", clipId: clipA });
  await req("ui.showMixer", { show: true });
  await sleep(SETTLE_MS);
  const p4 = await sel({});
  check("P4 ⚠️ THE MIX CONSOLE refuses under its own name, in the exact state a "
        + "dropped workspace term would leak through: a MIDI clip IS open "
        + "(editorClipId non-null, 3 notes) and the workspace is `mix`",
        p4.workspaceMode === "mix" && p4.editorClipId === clipA
        && policy(p4).enabled === false
        && policy(p4).refusedBy === "not-arrange-workspace"
        && policy(p4).rollNoteCount === 3,
        `workspaceMode=${p4.workspaceMode} editorClipId=${p4.editorClipId === clipA} `
        + `policy=${JSON.stringify(policy(p4))}`);
  await req("ui.showMixer", { show: false });
  await sleep(SETTLE_MS);

  // The EMPTY roll — a live item that provably does nothing is the lie the
  // disabled state exists to prevent.
  await sel({ act: "click", clipId: clipEmpty });
  await sleep(SETTLE_MS);
  const p5 = await sel({});
  check("P5 ⚠️ AN EMPTY ROLL refuses rather than offering a provable no-op — "
        + "reached from a real clip with zero notes, not only from the unit sweep",
        p5.editorClipId === clipEmpty
        && policy(p5).rollNoteCount === 0
        && policy(p5).enabled === false
        && policy(p5).refusedBy === "empty-roll",
        `editorClipId=${p5.editorClipId === clipEmpty} policy=${JSON.stringify(policy(p5))}`);

  // ⭐ ANTI-VACUITY FOR THE WHOLE P TIER: four distinct verdicts were observed.
  // A policy hardwired to any single answer would pass some of P1–P5 and fail
  // the rest, but a reader skimming greens needs the count stated.
  const verdictsSeen = new Set([p1, p3, p4, p5].map(
    (s) => policy(s).surface ?? policy(s).refusedBy));
  check("P6 ⭐ FOUR DISTINCT VERDICTS WERE ACTUALLY OBSERVED across P1–P5 — the "
        + "policy discriminates rather than answering one thing well",
        verdictsSeen.size === 4,
        `saw ${JSON.stringify([...verdictsSeen])}`);
} finally {
  try { ws?.close(); } catch {}
  stopStaging(GATE);
}

if (skipped.length) {
  console.log(
    `\n⚠️⚠️ COVERAGE IS PARTIAL: ${skipped.length} entry(ies) SKIPPED — `
    + `${skipped.join("; ")}. The POLICY tier ran and proves the fix; DELIVERY `
    + `is UNPROVEN on this run. Re-run with the staging window frontmost.`);
}
console.log(
  "\n⚠️ HONEST LIMIT: every ⌘A above was a SYNTHESIZED NSEvent posted through the "
  + "real queue. That is the strongest evidence this tree can produce and it is "
  + "stronger than a debug seam — but no gate here can press a physical key. "
  + "The first-press fix still wants a human to confirm once.");
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
