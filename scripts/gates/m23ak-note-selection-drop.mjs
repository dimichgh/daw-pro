// m23-ak GATE — THE PIANO ROLL DROPS ITS NOTE SELECTION WHEN THE ARRANGE
// SELECTION GROWS PAST THE CLIP IT IS OPEN ON, against a REAL app on staging
// (port 17695 ONLY; 17600 is the user's LIVE app and is never touched. Staging is
// killed PIDFILE-EXACT, never pkill/pgrep — at start AND at exit).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY (the m23-x/m23-aj pattern), so the thing
// under test has KNOWN PROVENANCE. A gate that drives whatever instance happens
// to be on the port can pass against code that is minutes or days old, and it
// cannot tell you that it did (m23-ac).
//
// THE BUG THIS PINS (filed by the m23-x implementer, MEASURED, roadmap m23-ak):
// select a MIDI clip -> select notes in the roll -> shift-click two more clips in
// the arrange -> press ->. NOTHING HAPPENS (`refusedBy: piano-roll-note-edit`,
// starts unchanged), and DELETE removes the NOTES rather than the three clips.
// Both are correct under m23-x's predicate and wrong by intent: the user's
// evident target is the three-clip arrange selection.
//
// WHAT THIS PROVES
//   • THE FIX (L1): widening a 1-clip selection to 3 while the roll holds notes
//     drops the note selection, leaves the ROLL OPEN on the same clip, and lets
//     -> move all three clips.
//   • THE CONTROL (L2), on its OWN fixture: notes selected and the selection NOT
//     widened -> -> still refuses with `refusedBy: piano-roll-note-edit` and the
//     clip does not move. Without this half, L1 passes against a build that
//     deleted the fifth guard outright. It does not share L1's fixture: a control
//     that inherits the state of the leg it controls is not a control (m23-aj-3).
//   • DELETE (L3): after the same widening, the app's DELETE handler takes all
//     three clips, and at the moment of the key the roll holds NO note claim —
//     which is exactly the test its own `.onKeyPress(.delete)` applies to decide
//     whether to consume the key or let it fall through. See the honesty note on
//     L3 for the one hop this cannot reach.
//   • THE DROP SURVIVES A NARROW-BACK (L4): narrow back to the one clip WITHOUT
//     closing the editor and the notes are still gone — nothing re-reports and
//     hands the claim back. ⚠️ It does NOT prove the roll's MODEL was cleared;
//     that reading was measured false 2026-08-03 (see L4b). The forged-report
//     failure mode is caught by L4d/L4e and by the Swift unit test
//     `widenedDropDoesNotForgeTheReport`, not here.
//   • THE TRANSITION SEMANTICS (L4d): re-widen, then DELIBERATELY select notes
//     again — they are KEPT and -> refuses again. m23-ak is a transition rule,
//     not a standing one, and this is the documented consequence.
//   • A SECOND GROWTH PATH (L5): a TRACK-HEADER click, which reaches the same
//     `didSet` through `ArrangeTrackSelection.apply(click:modifiers:to:)` — an
//     `inout` argument across a module boundary, i.e. the path most likely to be
//     missed by a trigger that only watched clicks.
//
// WHAT THIS DOES NOT PROVE: that SwiftUI hands a REAL DELETE key to the arrange
// rather than to the roll. m23-g1 measured that an unbundled staging binary does
// not route real key events (`keyDelete` -> `delivered:false`), and m23-x/m23-y
// both record that arbitration as a SKIP. It is recorded as a SKIP here too,
// never as a pass.
//
// ⚠️ THE `pianoRollNoteSelection` ECHO IS A FAITHFUL PROXY FOR THE ROLL'S OWN
// `model.selection`, NOT AN INDEPENDENT FLAG. `PianoRollView.swift:289-291`
// drives it from `.onChange(of: model.selection.isEmpty, initial: true)` inside
// the roll — the same expression the roll's own DELETE handler reads — so the
// value this gate asserts is the roll reporting its private `@State` model, not
// something the app set beside it. L4 is what discriminates "the model was
// cleared" from "the report was suppressed", and it does so by narrowing the
// selection back down WITHOUT unmounting the editor.
//
// ⚠️ EVERY LEG THAT DEPENDS ON THE ROLL SURVIVING ALSO ASSERTS
// `editorClipId === <the clip>` IN THE SAME ECHO. Without it, "notes are gone"
// cannot be told apart from "the editor was rebuilt, so of course they are gone"
// — and a rebuild is easy to cause by accident: `.id(clip.id)` means any move of
// the FOCUS makes a fresh `PianoRollModel` with an empty selection. That is why
// L4 narrows by toggling the extra clips OFF (the focus never moves) instead of
// the obvious clear-and-reclick, which would have been vacuous.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW —
// derive it from values the gate controls, never discover it by trial):
//   snap = bar, 4/4  =>  a bare press steps 4 beats. Each leg gets its OWN track
//   with three clips at 0 / 8 / 16, length 2 -> [0,2) [8,10) [16,18); after one
//   press right, 4 / 12 / 20 -> [4,6) [12,14) [20,22). Disjoint before AND after,
//   on one track, so no assertion is quietly reading the overlap resolver's
//   output.
//   EVERY CLIP CARRIES NOTES, and that is fixture, not decoration (m23-aj law,
//   measured): `{act:"pianoRollNotes", select:true}` resolves to the roll's own
//   select-all, which selects NOTHING in an empty clip — so with a noteless clip
//   the fifth guard cannot arm, the refusal reads `refusedBy: null`, and the leg
//   reddens for a fixture reason wearing a guard's clothes.
//
// Setup: none — run it.
//
//   node scripts/gates/m23ak-note-selection-drop.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23ak";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AK_OUT || "/tmp/m23ak";
const PIDFILE = process.env.M23AK_PIDFILE || "/tmp/m23ak-staging.pid";
const BINARY = process.env.M23AK_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23AK_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const LEN = 2;          // clip length in beats
const BAR = 4;          // bar grid in 4/4 — one bare press under `.bar`
const SETTLE_MS = 250;
// `UndoJournal.coalescingWindow` is 800 ms and `moveClipsKey` does not
// distinguish keyboard from gesture, so two nudges of the SAME selection inside
// it fold into ONE entry (m23-x N4). Anywhere this gate counts entries it waits
// this out first.
const COALESCE_MS = 900;
// How long a leg waits for the roll to answer a nonce. The chain is: `didSet` ->
// `dropForWidenedArrangeSelection` -> `.onChange(of: stageNonce)` ->
// `model.clearSelection()` -> `.onChange(of: model.selection.isEmpty)` ->
// `report(false)` — plausibly two SwiftUI update cycles, while the `click` act's
// own `awaitSelectionRendered` only waits for the LANES to re-render. Reading the
// click's own echo directly would be a race, and the honest fix is to poll the
// app's own report rather than to sleep a guessed constant (the shape
// `act:"pianoRollNotes"` already uses internally).
// ⚠️ Kept SHORT on purpose: on a RED BASELINE every one of these burns in full.
const NOTE_DEADLINE_MS = 1500;

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
const near = (a, b, eps = 1e-9) => typeof a === "number" && Math.abs(a - b) < eps;

const sel = (p = {}) => req("debug.arrangeSelection", p);
const nudgeAct = (p) => sel({ act: "nudge", ...p });
const overview = () => req("project.overview", {});
const depth = async () => (await req("edit.history", {})).undo.length;

/**
 * START BEATS FROM THE STORE — never from the seam echo (m23-x law).
 *
 * A clip that no longer EXISTS comes back as NaN rather than `undefined`, on
 * purpose: `near()` is false for NaN, so a destroyed clip FAILS the leg that was
 * asking about it instead of throwing and aborting the run.
 */
async function clipsByID() {
  const ov = await overview();
  const all = new Map();
  for (const t of ov.tracks) for (const c of t.clips) all.set(c.id, c);
  return all;
}
async function starts(ids) {
  const all = await clipsByID();
  return ids.map((id) => all.get(id) ?? { startBeat: NaN, lengthBeats: NaN, missing: true });
}
/** The clips (with their noteCounts) currently living on `trackId`. */
async function clipsOnTrack(trackId) {
  const ov = await overview();
  return (ov.tracks ?? []).find((t) => t.id === trackId)?.clips ?? [];
}

/**
 * Poll the app's OWN report until the roll says it holds (or does not hold) a
 * note selection. On timeout the LAST OBSERVED echo is returned rather than
 * thrown, so the leg fails with the value it actually saw — a gate that threw
 * here would report one error and hide every leg after it.
 */
async function awaitNotes(expected, ms = NOTE_DEADLINE_MS) {
  const deadline = Date.now() + ms;
  let last = await sel({});
  while (last.pianoRollNoteSelection !== expected && Date.now() < deadline) {
    await sleep(50);
    last = await sel({});
  }
  return last;
}

/**
 * One track, three MIDI clips at 0 / 8 / 16, each carrying two notes.
 *
 * A FRESH TRACK PER LEG, not a shared one: the legs below arm the same guard in
 * different states, and sharing clips would let one leg's leftover selection,
 * position or undo entry decide the next one's result. (m23-x N9 records the
 * cost of inheriting the previous leg's snap setting: three red legs measuring
 * leftovers rather than the guard.)
 */
async function fixture(name) {
  const trackId = (await req("track.add", { kind: "instrument", name })).id;
  const clips = [];
  for (const beat of [0, 8, 16]) {
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
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await req("debug.arrangeDrag", { snap: "bar" });
  const f0 = await sel({});
  check("F1 fixture: the arrange grid in force is BAR — one bare press is 4 beats, "
        + "which every geometric assertion below assumes",
        f0.snap === "bar" && f0.effectiveSnap === "bar",
        `snap=${f0.snap} effectiveSnap=${f0.effectiveSnap}`);
  check("F2 fixture: nothing is selected yet (non-vacuity)",
        f0.count === 0 && f0.editorClipId === null,
        `count=${f0.count} editorClipId=${f0.editorClipId}`);

  // ══ L1  THE FIX ══════════════════════════════════════════════════════════
  const L1 = await fixture("AK-FIX");
  const [a0, a1, a2] = L1.clips;
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: a0 });
  await sleep(SETTLE_MS);
  let armed = await sel({ act: "pianoRollNotes", select: true });
  check("L1a FIXTURE: one MIDI clip selected => the roll is OPEN on it and holds a "
        + "NOTE SELECTION — the exact state the user is in when they reach for a "
        + "second clip. Without this the whole leg is vacuous",
        armed.editorClipId === a0 && armed.pianoRollNoteSelection === true
          && armed.count === 1 && armed.focusClipId === a0,
        `editorClipId=${armed.editorClipId === a0} notes=${armed.pianoRollNoteSelection} `
        + `count=${armed.count} focus=${armed.focusClipId === a0}`);

  // Widen exactly the way the bug report does: shift-click two more clips.
  await sel({ act: "click", clipId: a1, shift: true });
  await sel({ act: "click", clipId: a2, shift: true });
  const wide = await awaitNotes(false);
  check("L1b THE FIX: widening the arrange selection to THREE clips drops the "
        + "roll's note selection — and the roll is STILL OPEN on the same clip, so "
        + "this is a CLEAR, not the editor being torn down",
        wide.pianoRollNoteSelection === false && wide.editorClipId === a0
          && wide.count === 3 && wide.focusClipId === a0,
        `notes=${wide.pianoRollNoteSelection} editorClipId=${wide.editorClipId === a0} `
        + `count=${wide.count} focus=${wide.focusClipId === a0}`);

  const beforeL1 = await starts([a0, a1, a2]);
  let d0 = await depth();
  await sleep(COALESCE_MS);
  let n = await nudgeAct({ direction: "right" });
  let after = await starts([a0, a1, a2]);
  check("L1c ...and -> NOW MOVES ALL THREE CLIPS. This is the reported bug, "
        + "inverted: before m23-ak the same press was refused by "
        + "`piano-roll-note-edit` and nothing moved at all",
        n.nudged === true && n.refusedBy === null && near(n.effectiveDeltaBeats, BAR)
          && after.every((c, i) => near(c.startBeat - beforeL1[i].startBeat, BAR)),
        `nudged=${n.nudged} by=${n.refusedBy} eff=${n.effectiveDeltaBeats} `
        + `${beforeL1.map((c) => c.startBeat).join(",")} -> ${after.map((c) => c.startBeat).join(",")}`);
  check("L1d ...as ONE undo step over the whole group, and the relative offsets "
        + "survived (a nudge, not three independent moves)",
        (await depth()) - d0 === 1
          && near(after[1].startBeat - after[0].startBeat, 8)
          && near(after[2].startBeat - after[1].startBeat, 8)
          && after.every((c) => near(c.lengthBeats, LEN)),
        `depth+${(await depth()) - d0} gaps=${after[1].startBeat - after[0].startBeat},`
        + `${after[2].startBeat - after[0].startBeat} lengths=${after.map((c) => c.lengthBeats).join(",")}`);

  // ══ L2  THE CONTROL — ITS OWN FIXTURE ════════════════════════════════════
  // The fifth guard must still be ALIVE. Delete it outright and L1 goes green
  // for the wrong reason; this leg is what makes that impossible. It builds its
  // own clips deliberately: a control that inherits the state of the leg it
  // controls is not a control (paid for at m23-aj-3, where a control shared its
  // subject's fixture and cascaded under mutation).
  const L2 = await fixture("AK-CONTROL");
  const [b0] = L2.clips;
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: b0 });
  await sleep(SETTLE_MS);
  armed = await sel({ act: "pianoRollNotes", select: true });
  check("L2a FIXTURE: roll open on ITS OWN clip with notes selected, selection NOT "
        + "widened — one variable different from L1",
        armed.editorClipId === b0 && armed.pianoRollNoteSelection === true
          && armed.count === 1,
        `editorClipId=${armed.editorClipId === b0} notes=${armed.pianoRollNoteSelection} `
        + `count=${armed.count}`);

  const beforeL2 = (await starts([b0]))[0].startBeat;
  await sleep(COALESCE_MS);
  d0 = await depth();
  let e0 = (await sel({})).editSeq;
  const refused = await nudgeAct({ direction: "right" });
  check("L2b THE CONTROL: with the selection still the ONE clip, -> belongs to the "
        + "EDITOR — refused by `piano-roll-note-edit`, the clip does not slide "
        + "underneath the open roll, and nothing is journaled",
        refused.refusedBy === "piano-roll-note-edit"
          && refused.pianoRollNoteSelection === true && refused.editorClipId === b0
          && near((await starts([b0]))[0].startBeat, beforeL2)
          && (await depth()) === d0 && (await sel({})).editSeq === e0,
        `by=${refused.refusedBy} notes=${refused.pianoRollNoteSelection} `
        + `editorClipId=${refused.editorClipId === b0} `
        + `start=${beforeL2} -> ${(await starts([b0]))[0].startBeat} `
        + `depth=${await depth()}/${d0} seq=${(await sel({})).editSeq}/${e0}`);
  check("L2c ...and the refusal still CONSUMES the key (nudged=true) — the m23-x "
        + "N6e/N9i twin: an `.ignored` arrow reaches TimelineLanesView's horizontal "
        + "ScrollView and scrolls the timeline out from under the user",
        refused.nudged === true, `nudged=${refused.nudged}`);

  // ══ L3  DELETE ═══════════════════════════════════════════════════════════
  // THE ROADMAP'S SECOND HALF: the honest fix is the roll dropping its notes,
  // "and it also fixes the DELETE path's version of the same confusion rather
  // than special-casing arrows".
  //
  // ⚠️ HONESTY NOTE, and it is a correction to the item's own framing. This leg
  // CANNOT discriminate the fix by counting what got deleted.
  // `AppModel.handleArrangeDeleteKey` has FOUR guards (workspace / modal /
  // text-editing / empty-selection) and NO piano-roll term — unlike the nudge's
  // fifth — so `act:"keyHandler"` deletes the three clips identically with or
  // without m23-ak. The thing that changes is which consumer SwiftUI's responder
  // chain hands the REAL key to, and that hop is unreachable from staging
  // (`keyDelete` -> `delivered:false`, m23-g1; recorded as a SKIP below and by
  // m23-x and m23-y before this).
  //
  // What this leg DOES pin, and it is the load-bearing half: at the moment of
  // the DELETE the roll is OPEN and holds NO note claim — precisely the state in
  // which its own `.onKeyPress(.delete)` returns `.ignored` and lets the key
  // fall through to the arrange (`guard !model.selection.isEmpty else { return
  // .ignored }`). Before m23-ak that same moment reads `true`, the roll consumes
  // the key, and the user watches their notes vanish instead of their clips. So
  // the state assertion is the discriminator and the deletion assertion is the
  // outcome; both are here, and neither is dressed up as the other.
  const L3 = await fixture("AK-DELETE");
  const [c0, c1, c2] = L3.clips;
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: c0 });
  await sleep(SETTLE_MS);
  armed = await sel({ act: "pianoRollNotes", select: true });
  check("L3a FIXTURE: roll open on its own clip with notes selected — the state in "
        + "which the roll would consume DELETE for itself",
        armed.editorClipId === c0 && armed.pianoRollNoteSelection === true,
        `editorClipId=${armed.editorClipId === c0} notes=${armed.pianoRollNoteSelection}`);
  await sel({ act: "click", clipId: c1, shift: true });
  await sel({ act: "click", clipId: c2, shift: true });
  const preDelete = await awaitNotes(false);
  check("L3b THE DISCRIMINATOR: with three clips selected the roll holds NO note "
        + "claim while STILL BEING OPEN — so its own `.onKeyPress(.delete)` "
        + "returns .ignored and the key belongs to the arrange. This reads `true` "
        + "before m23-ak, which is why DELETE ate the notes",
        preDelete.pianoRollNoteSelection === false && preDelete.editorClipId === c0
          && preDelete.count === 3,
        `notes=${preDelete.pianoRollNoteSelection} `
        + `editorClipId=${preDelete.editorClipId === c0} count=${preDelete.count}`);

  const dDel = await depth();
  const del = await sel({ act: "keyHandler" });
  const leftOnTrack = await clipsOnTrack(L3.trackId);
  check("L3c THE OUTCOME: DELETE takes all THREE clips, in ONE undo step — and the "
        + "alternative outcome is excluded by construction, because the track is "
        + "EMPTY. Had the notes been the thing deleted, three clips would still be "
        + "standing here with their note lists emptied",
        del.deleted === true && (await depth()) - dDel === 1
          && leftOnTrack.length === 0,
        `deleted=${del.deleted} depth+${(await depth()) - dDel} `
        + `clipsLeft=${leftOnTrack.length} `
        + `noteCounts=${JSON.stringify(leftOnTrack.map((c) => c.noteCount))}`);
  check("L3d NOTHING PARTIAL: the editor closed on the now-dead id and the "
        + "selection is empty",
        del.editorClipId === null && del.focusClipId === null && del.count === 0,
        `editorClipId=${del.editorClipId} focus=${del.focusClipId} count=${del.count}`);
  await req("edit.undo", {});
  const restored = await clipsOnTrack(L3.trackId);
  check("L3e one undo restores all three clips WITH THEIR NOTES INTACT (2 each) — "
        + "the notes were never the thing that was deleted",
        restored.length === 3 && restored.every((c) => c.noteCount === 2),
        `clips=${restored.length} noteCounts=${JSON.stringify(restored.map((c) => c.noteCount))}`);

  // ══ L4  PROVABLY CLEARED, NOT SUPPRESSED ═════════════════════════════════
  // ITS OWN FIXTURE, and the first draft of this gate got that wrong in a way
  // worth recording: L4 originally continued L1's clips, on the reasoning that
  // the roll instance had been open on `a0` since L1b. It had not — L3 ran in
  // between, clicked its own clip (moving the FOCUS, which unmounts the editor)
  // and then deleted and undid, leaving the arrange selection EMPTY. So the
  // "toggle the extras off" below toggled two clips IN instead, and the leg read
  // `count=2, editorClipId=false`. It reddened on the RED BASELINE for that
  // reason rather than for the fix's absence, which is precisely the failure a
  // red baseline exists to expose.
  //
  // ⚠️ NARROWED BY TOGGLING THE EXTRAS OFF, NOT by clear-and-reclick. `clear`
  // moves the FOCUS to nil, which unmounts the editor branch; the reclick mounts
  // a FRESH `PianoRollView` with a FRESH `@State private PianoRollModel` whose
  // selection is empty by construction. That leg would read `false` with or
  // without m23-ak — vacuous. Toggling the extras off leaves the focus on the
  // first clip throughout (`ArrangeSelection.toggle`: removing a non-focused clip
  // leaves the focus untouched), so `.id(clip.id)` never changes and the SAME
  // model — with whatever selection it really holds — answers.
  const L4 = await fixture("AK-CLEARED");
  const [d1, d2, d3] = L4.clips;
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: d1 });
  await sleep(SETTLE_MS);
  armed = await sel({ act: "pianoRollNotes", select: true });
  check("L4-fix FIXTURE: roll open on its own clip with notes selected",
        armed.editorClipId === d1 && armed.pianoRollNoteSelection === true
          && armed.count === 1,
        `editorClipId=${armed.editorClipId === d1} notes=${armed.pianoRollNoteSelection} `
        + `count=${armed.count}`);
  await sel({ act: "click", clipId: d2, shift: true });
  await sel({ act: "click", clipId: d3, shift: true });
  await awaitNotes(false);
  await sel({ act: "click", clipId: d3, shift: true });
  await sel({ act: "click", clipId: d2, shift: true });
  await sleep(SETTLE_MS);
  const narrow = await sel({});
  check("L4a the selection is back to the ONE clip and the roll was NEVER REBUILT "
        + "(focus never left it, so the model that answers below is the same "
        + "instance that held the notes)",
        narrow.count === 1 && narrow.focusClipId === d1 && narrow.editorClipId === d1,
        `count=${narrow.count} focus=${narrow.focusClipId === d1} `
        + `editorClipId=${narrow.editorClipId === d1}`);
  check("L4b THE DROP SURVIVES A NARROW-BACK: the notes are still gone with the "
        + "count returned to 1 and the same roll still mounted — nothing re-reports "
        + "and hands the claim back. ⚠️ THIS LEG DOES NOT PROVE THE ROLL'S MODEL WAS "
        + "CLEARED, and it used to say it did: MEASURED 2026-08-03, a mutant that "
        + "forged `hasSelection = false` without delivering anything to the roll "
        + "passes here, because the report fires from `.onChange(of: model.selection.isEmpty)` "
        + "and a narrow-back changes neither. What CATCHES that forgery is L4d/L4e "
        + "(a desynchronised flag can never be re-claimed) and the Swift unit test "
        + "`widenedDropDoesNotForgeTheReport`",
        narrow.pianoRollNoteSelection === false,
        `notes=${narrow.pianoRollNoteSelection}`);

  let markL4 = (await starts([d1]))[0].startBeat;
  await sleep(COALESCE_MS);
  n = await nudgeAct({ direction: "right" });
  check("L4c ...and -> nudges the single clip: the drop is not a latch that leaves "
        + "the roll permanently unable to claim the arrows",
        n.nudged === true && n.refusedBy === null
          && near((await starts([d1]))[0].startBeat, markL4 + BAR),
        `nudged=${n.nudged} by=${n.refusedBy} `
        + `start=${markL4} -> ${(await starts([d1]))[0].startBeat}`);

  // THE DOCUMENTED CONSEQUENCE of making this a TRANSITION rather than a
  // standing condition. Re-widen (which drops), then ask for notes AGAIN with
  // three clips already selected: they are KEPT. At that point the user's intent
  // is plainly the notes — they just asked for them, with the wide selection
  // already on screen — and re-clearing would be the app arguing with them.
  await sel({ act: "click", clipId: d2, shift: true });
  await sel({ act: "click", clipId: d3, shift: true });
  await awaitNotes(false);
  const deliberate = await sel({ act: "pianoRollNotes", select: true });
  check("L4d THE TRANSITION SEMANTICS: with three clips already selected, a "
        + "DELIBERATE note selection is KEPT — m23-ak fires on the crossing, not "
        + "forever after",
        deliberate.pianoRollNoteSelection === true && deliberate.count === 3
          && deliberate.editorClipId === d1,
        `notes=${deliberate.pianoRollNoteSelection} count=${deliberate.count} `
        + `editorClipId=${deliberate.editorClipId === d1}`);
  markL4 = (await starts([d1]))[0].startBeat;
  await sleep(COALESCE_MS);
  d0 = await depth();
  const refusedAgain = await nudgeAct({ direction: "right" });
  check("L4e ...and -> refuses again, naming the same guard. The fifth guard is "
        + "intact for the case it was written for; m23-ak only removed the case "
        + "where the user had plainly moved on",
        refusedAgain.refusedBy === "piano-roll-note-edit"
          && near((await starts([d1]))[0].startBeat, markL4)
          && (await depth()) === d0,
        `by=${refusedAgain.refusedBy} start=${markL4} -> `
        + `${(await starts([d1]))[0].startBeat} depth=${await depth()}/${d0}`);

  // ══ L5  A SECOND GROWTH PATH — THE TRACK-HEADER CLICK ════════════════════
  // Not a repeat of L1. The predicate reads the RESULTING selection rather than
  // the gesture, and this is the leg that pays for that claim: a track-header
  // click reaches the same `didSet` through
  // `ArrangeTrackSelection.apply(click:modifiers:to:)`, which takes the selection
  // as an `inout` argument across a module boundary — the growth path a
  // click-watching trigger is most likely to miss, and the biggest one there is
  // (m23-y: selecting a track selects ALL of its clips).
  const L5 = await fixture("AK-TRACK");
  const [e1] = L5.clips;
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: e1 });
  await sleep(SETTLE_MS);
  armed = await sel({ act: "pianoRollNotes", select: true });
  check("L5a FIXTURE: roll open on the first clip of its own track, notes selected",
        armed.editorClipId === e1 && armed.pianoRollNoteSelection === true
          && armed.count === 1,
        `editorClipId=${armed.editorClipId === e1} notes=${armed.pianoRollNoteSelection} `
        + `count=${armed.count}`);
  await sel({ act: "clickTrack", trackId: L5.trackId });
  const headed = await awaitNotes(false);
  check("L5b a TRACK-HEADER click selects all three clips and drops the note "
        + "selection too, with the roll still open on its clip — the `inout` "
        + "mutation path fires the same trigger as a shift-click",
        headed.pianoRollNoteSelection === false && headed.count === 3
          && headed.editorClipId === e1 && headed.focusClipId === e1,
        `notes=${headed.pianoRollNoteSelection} count=${headed.count} `
        + `editorClipId=${headed.editorClipId === e1} focus=${headed.focusClipId === e1}`);
  const beforeL5 = await starts(L5.clips);
  await sleep(COALESCE_MS);
  n = await nudgeAct({ direction: "right" });
  const afterL5 = await starts(L5.clips);
  check("L5c ...and -> moves the whole track's worth of clips",
        n.nudged === true && n.refusedBy === null
          && afterL5.every((c, i) => near(c.startBeat - beforeL5[i].startBeat, BAR)),
        `nudged=${n.nudged} by=${n.refusedBy} `
        + `${beforeL5.map((c) => c.startBeat).join(",")} -> ${afterL5.map((c) => c.startBeat).join(",")}`);

  // ══ Recorded as SKIP, never as a pass ════════════════════════════════════
  skip("which consumer SwiftUI hands a REAL DELETE key to",
       "m23-g1 MEASURED that an unbundled staging binary does not route real key "
       + "events (`debug.arrangeSelection {act:\"keyDelete\"}` -> delivered:false: the "
       + "window is not key, so nothing reaches SwiftUI's focus arbitration). The "
       + "arbitration is STRUCTURAL — PianoRollView owns `.onKeyPress(.delete)` as a "
       + "DESCENDANT of ArrangeDeleteKey, so a roll holding notes consumes the key "
       + "first — and m23-ak's whole DELETE claim is that after a widening the roll "
       + "no longer holds them, which L3b pins directly. The final hop needs a human "
       + "at a real window. NOT counted as a pass. (m23-x and m23-y record the same "
       + "hop as a skip.)");
  skip("the MARQUEE growth path end to end",
       "`replace(with:)` and `formUnion(_:)` are exercised headlessly by "
       + "`WidenedArrangeSelectionDropTests.allThreeGrowthPathsCross`, and the "
       + "track-header click at L5 drives `replace` through the app for real. A "
       + "rubber band additionally needs pointer geometry over the lanes "
       + "(`debug.arrangeMarquee`), which would test m23-g3's hit-testing rather "
       + "than this rule — the predicate reads the RESULTING selection and cannot "
       + "tell the two apart by construction.");

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
