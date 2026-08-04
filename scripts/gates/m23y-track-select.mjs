// m23-y staging gate — TRACK MULTI-SELECT in the arrange, over the real control
// port, against a binary this script BUILT AND LAUNCHED ITSELF.
//
// ⚠️ BUILD FIRST, then launch OUR OWN process on 17695. A gate that drives
// whatever instance happens to be on the port has unknown provenance and its
// green is undetectable noise — that is the m23-ac class, and 33 gates in this
// tree still have it. This one is not the 34th.
//
// Staging 17695 ONLY. 17600 is the USER'S LIVE APP and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
//
// ═══ WHY THESE ASSERTIONS AND NOT THE ROADMAP'S SENTENCES ═══
//
// The roadmap's four legs are all vacuous in their literal form, so each is
// written here in the shape that can actually fail:
//
//   • "selects every clip on that track" — asserted as the EXACT id set AND that
//     clips on OTHER tracks are NOT selected, over a ≥2-track fixture. A handler
//     that selected the whole project passes the literal sentence.
//   • "adds without dropping the first's" — asserted as the exact UNION, with
//     track 2 holding clips track 1 does not.
//   • "ONE history step" — asserted as depth +1 AND the exact surviving clip set
//     AND that ONE undo restores everything. Depth +1 alone is equally
//     consistent with "one clip deleted, five silently dropped".
//   • "a zero-clip track selects cleanly" — asserted as the FULL consequence:
//     selection empty, focus nil (so the piano roll closes), and DELETE pushes
//     no history step.
//
// Plus Y5, the leg that PINS THE CHORD DECISION (all-or-none set toggle rather
// than `formUnion`): without it the policy ships unpinned and a mutation to
// `formUnion` is invisible.
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";

// The build/launch/pidfile-kill lifecycle lives in ONE place (m23-ac-1) —
// `_staging.mjs`. It used to be copy-pasted into every gate that had it at all.
import { launchStaging, stopStaging, sleep, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23y";
const OUT = "/tmp/daw-gate-out/m23y";
mkdirSync(OUT, { recursive: true });

let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
const skips = [];
function raw(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `y-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
async function req(command, params = {}) {
  const m = await raw(command, params);
  if (m.error) throw new Error(`${command}: ${JSON.stringify(m.error)}`);
  return m.result ?? {};
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label}\n       :: ${detail}`); }
}
const skip = (name, why) => { skips.push({ name, why }); console.log(`SKIP ${name}\n       :: ${why}`); };

// The selection seam. Every read and every act goes through it, so what the gate
// sees is the model's own ground truth (`arrangeSelection`), never the input.
const sel = (p = {}) => req("debug.arrangeSelection", p);
const clickTrack = (trackId, mods = {}) => sel({ act: "clickTrack", trackId, ...mods });
const depth = async () => (await req("edit.history")).undo?.length ?? -1;
const idsOf = (s) => [...(s.selectedIds ?? [])].sort();
const sorted = (a) => [...a].sort();
const same = (a, b) => JSON.stringify(sorted(a)) === JSON.stringify(sorted(b));
// Every clip id currently in the project, read off the store.
async function liveClips() {
  const ov = await req("project.overview");
  return (ov.tracks ?? []).flatMap((t) => (t.clips ?? []).map((c) => c.id));
}

try {
  const staging = await launchStaging({ gate: GATE });
  ws = staging.ws;
  console.log(`connected to staging on ${STAGING_PORT} (pid ${staging.pid})`);

  // ══ FIXTURE ═══════════════════════════════════════════════════════════════
  // THREE tracks with clips + one EMPTY track. Three, not two, because Y3's
  // "mixed selection" needs a loose clip that belongs to NEITHER clicked track —
  // otherwise "the union" and "everything selected by the last click" are the
  // same set and the leg cannot tell them apart.
  await req("project.new", { discardChanges: true });
  const T = [];
  for (const n of ["Y-A", "Y-B", "Y-C", "Y-EMPTY"]) {
    T.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  const mk = async (t, beat) => (await req("clip.addMIDI", {
    trackId: T[t], atBeat: beat, lengthBeats: 2,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;

  const a0 = await mk(0, 0), a4 = await mk(0, 4), a8 = await mk(0, 8);
  const b0 = await mk(1, 0), b4 = await mk(1, 4);
  const c0 = await mk(2, 0);
  const A = [a0, a4, a8], B = [b0, b4];
  await sleep(400);

  ck("Y0 FIXTURE: 3 tracks with clips + 1 empty, 6 clips total, all distinct",
     same(await liveClips(), [...A, ...B, c0]) && new Set([...A, ...B, c0]).size === 6,
     JSON.stringify(await liveClips()));

  // ══ Y1 — a header click selects EXACTLY that track's clips ════════════════
  await sel({ act: "clear" });
  let s = await clickTrack(T[0]);
  ck("Y1 a plain header click selects the EXACT id set on that track",
     same(idsOf(s), A), `${JSON.stringify(idsOf(s))} vs ${JSON.stringify(sorted(A))}`);
  ck("Y1 clips on OTHER tracks are NOT selected (a project-wide handler fails here)",
     !idsOf(s).includes(b0) && !idsOf(s).includes(b4) && !idsOf(s).includes(c0)
       && s.count === 3,
     `count=${s.count} ids=${JSON.stringify(idsOf(s))}`);
  ck("Y1 the seam echoes the ONE HOME's own answer, and it matches the selection",
     same(s.trackClipIds ?? [], A) && s.trackClickIntent === "replace"
       && s.trackClickEffect === "replace",
     `trackClipIds=${JSON.stringify(s.trackClipIds)} intent=${s.trackClickIntent} `
     + `effect=${s.trackClickEffect}`);

  // A SECOND plain click REPLACES rather than accumulating — the half that
  // distinguishes `replace(with:)` from `formUnion` on the bare-chord path.
  s = await clickTrack(T[1]);
  ck("Y1b a second PLAIN header click replaces — track A's clips are gone",
     same(idsOf(s), B), JSON.stringify(idsOf(s)));

  // ══ Y2 — ⇧ on a second header ADDS, exact union ═══════════════════════════
  await sel({ act: "clear" });
  await clickTrack(T[0]);
  s = await clickTrack(T[1], { shift: true });
  ck("Y2 ⇧ on a second header yields the EXACT union of both tracks' clips",
     same(idsOf(s), [...A, ...B]) && s.count === 5,
     `count=${s.count} ids=${JSON.stringify(idsOf(s))}`);
  ck("Y2 the first track's clips were NOT dropped (B holds clips A does not)",
     A.every((id) => idsOf(s).includes(id)) && B.every((id) => idsOf(s).includes(id)),
     JSON.stringify(idsOf(s)));
  ck("Y2 the seam reports the ADD branch, not a vacuous no-op",
     s.trackClickEffect === "add" && s.trackClickIntent === "toggle"
       && same(s.trackClipIds ?? [], B),
     `effect=${s.trackClickEffect} intent=${s.trackClickIntent} `
     + `ids=${JSON.stringify(s.trackClipIds)}`);
  ck("Y2b clip c0 — on a track neither click touched — is still unselected",
     !idsOf(s).includes(c0), JSON.stringify(idsOf(s)));

  // ⌘ is the SAME chord, because it is the same table the clip click uses.
  await sel({ act: "clear" });
  await clickTrack(T[0]);
  const viaCommand = await clickTrack(T[1], { command: true });
  ck("Y2c ⌘ behaves exactly as ⇧ (ONE shared chord table, not a second one)",
     same(idsOf(viaCommand), [...A, ...B]) && viaCommand.trackClickEffect === "add",
     `${JSON.stringify(idsOf(viaCommand))} effect=${viaCommand.trackClickEffect}`);

  // ══ Y5 — THE CHORD DECISION: ⇧ on a FULLY-selected header REMOVES ═════════
  // The ONLY leg that discriminates the shipped all-or-none set toggle from a
  // `formUnion` resolution. Under `formUnion` the selection below is unchanged
  // (still 5 ids) and every other leg in this gate still passes.
  await sel({ act: "clear" });
  await clickTrack(T[0]);
  await clickTrack(T[1], { shift: true });
  s = await clickTrack(T[0], { shift: true });
  ck("Y5 ⇧ on a FULLY-selected header removes EXACTLY that track's clips",
     same(idsOf(s), B) && s.count === 2,
     `count=${s.count} ids=${JSON.stringify(idsOf(s))} (formUnion would leave 5)`);
  ck("Y5 the OTHER track's clips are left standing",
     B.every((id) => idsOf(s).includes(id))
       && A.every((id) => !idsOf(s).includes(id)),
     JSON.stringify(idsOf(s)));
  ck("Y5 the seam reports the REMOVE branch",
     s.trackClickEffect === "remove", `effect=${s.trackClickEffect}`);

  // …and it ROUND-TRIPS. A true toggle is its own inverse; an additive rule is not.
  s = await clickTrack(T[0], { shift: true });
  ck("Y5b ⇧ again re-adds — the toggle is its own inverse",
     same(idsOf(s), [...A, ...B]) && s.trackClickEffect === "add",
     `${JSON.stringify(idsOf(s))} effect=${s.trackClickEffect}`);

  // PARTIAL selection ADDS the rest rather than inventing a tiebreak.
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: a4 });        // one of track A's three
  s = await clickTrack(T[0], { shift: true });
  ck("Y5c ⇧ on a PARTIALLY-selected header adds the rest (all-or-none, no tiebreak)",
     same(idsOf(s), A) && s.trackClickEffect === "add",
     `${JSON.stringify(idsOf(s))} effect=${s.trackClickEffect}`);

  // ══ Y6 — THE FOCUS DECISION: a header click NEVER ADOPTS a focus ══════════
  // User-visible: plain-clicking a header does NOT open the piano roll, while
  // clicking a clip does. Asserted through `editorClipId`, which is the clip the
  // roll is ACTUALLY open on (`AppModel.openEditorClip`), not a guess.
  await sel({ act: "clear" });
  s = await clickTrack(T[2]);                      // track C: exactly ONE MIDI clip
  ck("Y6 a plain header click on a single-MIDI-clip track selects it WITHOUT "
     + "opening the note editor (selecting is not opening)",
     same(idsOf(s), [c0]) && s.focusClipId === null && s.editorClipId === null
       && s.selectedClipId === null,
     `ids=${JSON.stringify(idsOf(s))} focus=${s.focusClipId} editor=${s.editorClipId}`);

  // CONTROLLED PAIR: the very same clip, reached by a CLIP click, DOES open it.
  // Without this half, Y6 would pass against an app whose editor never opens.
  s = await sel({ act: "click", clipId: c0 });
  ck("Y6b CONTROL: clicking that same clip DOES open the editor — so Y6 is a "
     + "difference between the two paths, not a dead editor",
     s.focusClipId === c0 && s.editorClipId === c0,
     `focus=${s.focusClipId} editor=${s.editorClipId}`);

  // …and a SURVIVING focus is KEPT by a header click (this is A2's setup).
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: a4 });          // focus = a4, roll open on it
  s = await clickTrack(T[0]);                       // header of a4's OWN track
  ck("Y6c a header click KEEPS a focus that survives into the new set — the roll "
     + "stays open on the clip it was open on",
     same(idsOf(s), A) && s.focusClipId === a4 && s.editorClipId === a4,
     `ids=${JSON.stringify(idsOf(s))} focus=${s.focusClipId} editor=${s.editorClipId}`);

  // …and a focus that does NOT survive is dropped, closing the editor (INV1).
  s = await clickTrack(T[1]);                       // a different track entirely
  ck("Y6d a header click DROPS a focus the new set does not contain (INV1)",
     same(idsOf(s), B) && s.focusClipId === null && s.editorClipId === null,
     `ids=${JSON.stringify(idsOf(s))} focus=${s.focusClipId} editor=${s.editorClipId}`);

  // ══ Y8 — the KEY-FOCUS nonce, the mechanism DELETE-after-a-header-click ═══
  // needs. Asserted as a BUMP, with a controlled negative so it is not vacuous.
  // HONEST SCOPE: this proves the bump, not that SwiftUI moved focus — nothing
  // in this app can observe the latter, and m23-x measured the roll's own focus
  // flag alternating 6/6, so it must not be pressed into service as a proxy.
  await sel({ act: "clear" });
  const n0 = (await sel({})).keyFocusNonce;
  const n1 = (await clickTrack(T[0])).keyFocusNonce;
  ck("Y8 a header click BUMPS the arrange key-focus nonce — the mechanism that "
     + "lets DELETE reach the clips it just selected",
     n1 === n0 + 1, `${n0} -> ${n1}`);
  const n2 = (await clickTrack(T[0])).keyFocusNonce;
  ck("Y8b it bumps on EVERY click, including a re-click that changed nothing "
     + "(the piano roll steals focus back, so a one-shot flag would go stale)",
     n2 === n1 + 1, `${n1} -> ${n2}`);
  const n3 = (await sel({})).keyFocusNonce;
  ck("Y8c CONTROL: a bare READ does not bump it — so Y8 is measuring the click, "
     + "not the round trip",
     n3 === n2, `${n2} -> ${n3}`);
  const bogusNonce = await raw("debug.arrangeSelection", {
    act: "clickTrack", trackId: "22222222-3333-4444-5555-666666666666" });
  ck("Y8d a REFUSED click does not bump it either — no focus assertion without "
     + "a cause",
     !!bogusNonce.error && (await sel({})).keyFocusNonce === n3,
     `nonce=${(await sel({})).keyFocusNonce} expected ${n3}`);

  // ══ Y3 — group DELETE over a MIXED selection = ONE history step ═══════════
  // MIXED means: track A's three clips (from a header click) + one loose clip on
  // track C (from a clip click). Of the six clips that exist, FOUR go (a0, a4,
  // a8, c0) and TWO remain (b0, b4). Asserted as the exact surviving SET,
  // because depth +1 alone is equally consistent with "one clip deleted, three
  // silently dropped".
  await sel({ act: "clear" });
  await clickTrack(T[0]);                           // a0, a4, a8
  s = await sel({ act: "click", clipId: c0, shift: true });   // + the loose clip
  const union = [...A, c0];
  ck("Y3 FIXTURE: a MIXED track+clip selection is exactly the union",
     same(idsOf(s), union) && s.count === 4,
     `count=${s.count} ids=${JSON.stringify(idsOf(s))}`);

  const dBefore = await depth();
  const del = await sel({ act: "delete" });
  const dAfter = await depth();
  const survivors = await liveClips();
  ck("Y3 the delete reported success", del.deleted === true, JSON.stringify(del.deleted));
  ck("Y3 EXACTLY ONE history step (+1, not +4)", dAfter - dBefore === 1,
     `${dBefore} -> ${dAfter}`);
  ck("Y3 the EXACT surviving set is B's two clips — nothing extra removed, "
     + "nothing silently spared",
     same(survivors, B), JSON.stringify(survivors));
  ck("Y3 the selection cleared on success", (await sel({})).count === 0,
     `count=${(await sel({})).count}`);

  await req("edit.undo");
  const restored = await liveClips();
  ck("Y3 ONE undo restores ALL FOUR — the atomicity claim, both directions",
     same(restored, [...A, ...B, c0]) && restored.length === 6,
     JSON.stringify(restored));
  ck("Y3 the undo consumed exactly the one step it pushed",
     (await depth()) === dBefore, `depth=${await depth()} expected ${dBefore}`);

  // ══ Y4 — the ZERO-CLIP track, full consequence ════════════════════════════
  await sel({ act: "clear" });
  await clickTrack(T[0]);
  await sel({ act: "click", clipId: a4 });          // give it a real focus first
  let before = await sel({});
  ck("Y4 FIXTURE: something IS selected and focused before the empty click "
     + "(otherwise 'the selection is empty after' is vacuous)",
     before.count === 1 && before.focusClipId === a4 && before.editorClipId === a4,
     `count=${before.count} focus=${before.focusClipId}`);

  const dEmpty = await depth();
  s = await clickTrack(T[3]);                       // Y-EMPTY: no clips at all
  ck("Y4 a plain click on a zero-clip track selects CLEANLY: nothing selected",
     s.count === 0 && idsOf(s).length === 0, `count=${s.count}`);
  ck("Y4 the focus is nil and the PIANO ROLL CLOSES (INV2, end to end)",
     s.focusClipId === null && s.editorClipId === null && s.selectedClipId === null,
     `focus=${s.focusClipId} editor=${s.editorClipId} sel=${s.selectedClipId}`);
  ck("Y4 the seam reports an empty clip set for that track",
     (s.trackClipIds ?? []).length === 0 && s.trackClickEffect === "replace",
     `ids=${JSON.stringify(s.trackClipIds)} effect=${s.trackClickEffect}`);

  const emptyDel = await sel({ act: "keyHandler" });
  ck("Y4 DELETE over the empty selection deletes NOTHING and pushes NO step",
     emptyDel.deleted === false && (await depth()) === dEmpty
       && same(await liveClips(), [...A, ...B, c0]),
     `deleted=${emptyDel.deleted} depth ${dEmpty} -> ${await depth()}`);

  // ⇧ on the empty track is the guarded degenerate case: `Set().isSubset(of:)`
  // is vacuously TRUE, so without the explicit guard this reports "remove".
  await sel({ act: "clear" });
  await clickTrack(T[0]);
  s = await clickTrack(T[3], { shift: true });
  ck("Y4b ⇧ on a zero-clip track reports .no-clips (NOT .remove — the vacuous "
     + "subset must not decide it) and changes nothing",
     s.trackClickEffect === "no-clips" && same(idsOf(s), A),
     `effect=${s.trackClickEffect} ids=${JSON.stringify(idsOf(s))}`);

  // ══ Y7 — an unknown track id is TOLD, never a silent green no-op ══════════
  const bogus = await raw("debug.arrangeSelection", {
    act: "clickTrack", trackId: "11111111-2222-3333-4444-555555555555" });
  ck("Y7 an unknown trackId is refused with the id in the message",
     !!bogus.error && JSON.stringify(bogus.error).includes("11111111"),
     JSON.stringify(bogus).slice(0, 220));
  const notUUID = await raw("debug.arrangeSelection", { act: "clickTrack", trackId: "nope" });
  ck("Y7b a non-UUID trackId is refused", !!notUUID.error,
     JSON.stringify(notUUID).slice(0, 200));
  const noID = await raw("debug.arrangeSelection", { act: "clickTrack" });
  ck("Y7c a missing trackId is refused", !!noID.error, JSON.stringify(noID).slice(0, 200));
  ck("Y7d a refused clickTrack left the selection untouched",
     same(idsOf(await sel({})), A), JSON.stringify(idsOf(await sel({}))));

  // ══ A2 — the roll-vs-arrange DELETE arbitration, pinned ═══════════════════
  // Track-select makes this newly reachable: a header click KEEPS a surviving
  // focus (Y6c), so the roll stays OPEN while the click's `arrangeKeyFocusNonce`
  // bump moves key focus to the arrange.
  //
  // ⚠️ m23-ak CHANGED THE STATE THIS LEG SETS UP, and the sentence that used to
  // end the paragraph above ("Two candidate consumers, one key") is now false —
  // rewritten here rather than left standing, because a shipped gate quietly
  // describing a fact the roadmap deliberately changed is the m23-aj-3 failure
  // shape. The header click below GROWS the arrange selection past the clip the
  // roll is open on, and `AppModel.arrangeSelection`'s `didSet` now answers that
  // by dropping the roll's note selection
  // (`PianoRollNoteSelectionBridge.shouldDropNotes`). So after the click there is
  // exactly ONE candidate consumer: the roll's `.onKeyPress(.delete)` reads
  // `guard !model.selection.isEmpty` and returns `.ignored`. That is the whole
  // point of m23-ak — the user who just selected a track means the track.
  //
  // NO ASSERTION HERE MOVED. The FIXTURE below is taken BEFORE the header click,
  // so it still reads `true`; and what A2 pins — that when the arrange's DELETE
  // handler runs it takes the WHOLE union in one step — was never about which
  // consumer won. The roll-vs-arrange drop itself is owned by
  // `scripts/gates/m23ak-note-selection-drop.mjs` (L5 drives this exact path).
  //
  // WHAT IS DECIDABLE HERE, and it is the honest half: the ARBITRATION is
  // SwiftUI's and is STRUCTURAL — `PianoRollView` owns `.onKeyPress(.delete)` as
  // a DESCENDANT of `ArrangeDeleteKey`, so a focused roll with notes selected
  // consumes the key first. No seam can drive that; `pianoRollEditorFocused` is
  // NOT asserted here because m23-x measured it alternating 6/6 across clip
  // switches. What IS pinned: when `handleArrangeDeleteKey` DOES run it has no
  // piano-roll term among its four guards (unlike the nudge's fifth), so it
  // deletes the WHOLE union including the clip the roll is open on — atomically,
  // with the editor closing on the now-dead id and nothing partial in between.
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: a4 });          // roll opens on a4
  let roll = await sel({ act: "pianoRollNotes", select: true });
  ck("A2 FIXTURE: the roll is OPEN on a4 with NOTES SELECTED — the state in "
     + "which it would consume DELETE for itself",
     roll.editorClipId === a4 && roll.pianoRollNoteSelection === true,
     `editor=${roll.editorClipId} notes=${roll.pianoRollNoteSelection}`);

  s = await clickTrack(T[0]);                       // the header of a4's own track
  ck("A2 the header click LEAVES THE ROLL OPEN while selecting the whole track, "
     + "reached the way a user reaches it (this leg used to call that 'the "
     + "two-consumer state'; m23-ak made that false — the click GROWS the "
     + "selection past the roll's clip, so the roll drops its note claim and "
     + "stops being a candidate for the key)",
     same(idsOf(s), A) && s.editorClipId === a4 && s.focusClipId === a4,
     `ids=${JSON.stringify(idsOf(s))} editor=${s.editorClipId}`);

  const dA2 = await depth();
  const a2 = await sel({ act: "keyHandler" });
  const afterA2 = await liveClips();
  ck("A2 THE PIN: when the arrange's DELETE handler runs it takes the WHOLE "
     + "union — including the clip the roll is open on — in ONE step",
     a2.deleted === true && (await depth()) - dA2 === 1 && same(afterA2, [...B, c0]),
     `deleted=${a2.deleted} depth ${dA2} -> ${await depth()} live=${JSON.stringify(afterA2)}`);
  ck("A2 NOTHING PARTIAL: the editor closed on the now-dead id and the selection "
     + "is empty — no stale editor, no half-selection",
     a2.editorClipId === null && a2.focusClipId === null && a2.count === 0,
     `editor=${a2.editorClipId} focus=${a2.focusClipId} count=${a2.count}`);

  await req("edit.undo");
  ck("A2 one undo restores the three clips the arbitration consumed",
     same(await liveClips(), [...A, ...B, c0]), JSON.stringify(await liveClips()));

  // The DELIVERY probe — the only thing that could show SwiftUI's REAL focus
  // arbitration. Reported honestly, never manufactured into a pass.
  //
  // ⚠️ SCOPE NARROWED BY m23-ak (2026-08-03), assertions unchanged. This fixture
  // arms the notes and then clicks the TRACK HEADER, which grows the arrange
  // selection past the roll's clip — so since m23-ak the roll has already
  // dropped its note claim by the time `keyDelete` runs. A delivered probe here
  // would therefore measure the arbitration in the DROPPED state (arrange is the
  // only claimant), which is a weaker question than the one this block was
  // written to ask. The CONTESTED state — roll open, notes still claimed — is no
  // longer reachable by widening the selection at all; it needs a fixture that
  // leaves the selection at ONE clip. Nothing here is wrong, it just proves less
  // than its original wording implied. Not rebuilt in this item: the branch is
  // unreachable on staging either way (delivered=false, m23-g1).
  await sel({ act: "clear" });
  await sel({ act: "click", clipId: a4 });
  await sel({ act: "pianoRollNotes", select: true });
  await clickTrack(T[0]);
  const dProbe = await depth();
  const probe = await sel({ act: "keyDelete" });
  if (probe.delivered === true) {
    ck("A2p DELIVERY PROBE: a real DELETE reached a consumer — the ARRANGE won "
       + "(the clips went, in one step)",
       (await depth()) - dProbe === 1 && same(await liveClips(), [...B, c0]),
       `depth ${dProbe} -> ${await depth()} live=${JSON.stringify(await liveClips())}`);
    await req("edit.undo");
  } else {
    skip("A2 real DELETE key DELIVERY (which consumer SwiftUI actually picks)",
         "`keyDelete` reported delivered=false: an unbundled staging binary's "
         + "window is not key, so no synthesized key event reaches SwiftUI's focus "
         + "arbitration. The arbitration is structural (PianoRollView owns "
         + "`.onKeyPress(.delete)` as a DESCENDANT of ArrangeDeleteKey) and needs "
         + "a human at a real window. NOT counted as a pass.");
    ck("A2p the honest negative: an undelivered probe changed NOTHING",
       (await depth()) === dProbe && same(await liveClips(), [...A, ...B, c0]),
       `depth ${dProbe} -> ${await depth()}`);
  }

  // ══ A3 — the take-comp fixture, and WHY IT IS NOT BUILT HERE ══════════════
  // MEASURED AT THIS CYCLE, not inherited. An earlier draft of this leg asked
  // for MIDI clips at beats 0 and 1 with lengthBeats 4 and then called
  // `take.group`; the store answered:
  //
  //     "clips do not overlap — grouping needs overlapping takes"
  //
  // because every clip verb resolves overlaps on the way in, so a take group is
  // UNBUILDABLE FROM THE WIRE (the m23-g1 law, re-measured — m23-x hit it from
  // the nudge side). Rather than fake the leg, the FACT is measured against the
  // store in `ArrangeTrackSelectionTakeCompTests`, which can reach the state the
  // wire cannot. Recorded as a skip so it never reads as covered here.
  const probeTrack = (await req("track.add", { kind: "instrument", name: "Y-PROBE" })).id;
  const p1 = (await req("clip.addMIDI", {
    trackId: probeTrack, atBeat: 0, lengthBeats: 4 })).id;
  const p2 = (await req("clip.addMIDI", {
    trackId: probeTrack, atBeat: 1, lengthBeats: 4 })).id;   // REQUESTED to overlap
  const probeOv = await req("project.overview");
  const probeClips = (probeOv.tracks ?? [])
    .find((t) => t.id === probeTrack)?.clips ?? [];
  ck("A3 the store RESOLVED the requested overlap on the way in — the two clips "
     + "asked for [0,4) and [1,5) do not overlap once created",
     probeClips.length === 2
       && probeClips.every((c) => probeClips.every((d) =>
            c.id === d.id
            || c.startBeat + c.lengthBeats <= d.startBeat
            || d.startBeat + d.lengthBeats <= c.startBeat)),
     JSON.stringify(probeClips.map((c) => [c.startBeat, c.lengthBeats])));
  const takeProbe = await raw("take.group", {
    trackId: probeTrack, clipIds: [p1, p2], name: "probe" });
  ck("A3 …and take.group therefore refuses (re-measured, not assumed) — so the "
     + "skip below is a measurement, not an excuse",
     !!takeProbe.error && JSON.stringify(takeProbe.error).includes("overlap"),
     JSON.stringify(takeProbe).slice(0, 240));
  skip("take-comp refusal over a track-header union, END TO END",
       // ⚠️ CORRECTED 2026-08-03 (m23-am). The sentence below is TRUE ABOUT THE
       // `take.group` VERB and was WRONG ABOUT THE WIRE, and this gate's own
       // A3 legs only ever tested the verb. A take group IS reachable from the
       // wire: `project.save` -> hand-author a `takeGroups` array plus a
       // `takeGroupId` on a clip into the bundle's `project.json` ->
       // `project.open` yields live comp members (MEASURED at m23-am, whose
       // gate `m23am-refusal-anchor.mjs` builds exactly that fixture and keeps
       // a CONTROL leg proving the verb still refuses on the same tree).
       // This leg therefore stays a skip only because THIS gate does not build
       // that fixture — a limit of this file, no longer a limit of the wire.
       // Re-enabling it is filed as m23-am-2.
       "`take.group` needs >=2 OVERLAPPING clips and every wire clip verb "
       + "resolves overlaps on the way in (re-measured above: \"clips do not "
       + "overlap\") — TRUE OF THE VERB, NOT OF THE WIRE; see the correction "
       + "above. MEASURED INSTEAD in `ArrangeTrackSelectionTakeCompTests`, "
       + "against the store: a comp member ANYWHERE in a two-header union "
       + "refuses the WHOLE delete — every ordinary clip on the OTHER track "
       + "survives too, and no history step is pushed. That last part is a "
       + "user-visible consequence worth FILING: selecting a track that holds a "
       + "take group makes group-DELETE do nothing at all.");

  // ══ A4 — the m23-h reorder drag still works ═══════════════════════════════
  // A single tap on the row is a new gesture on the SAME view that carries
  // `.gesture(reorderDrag)`. Driven through the existing `debug.trackHeaderDrag`
  // seam, which runs the list's own `dragUpdate`/`dragEnd`.
  await req("project.new", { discardChanges: true });
  const R = [];
  for (const n of ["R1", "R2", "R3"]) {
    R.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  await sleep(400);
  const ladder = await req("debug.trackHeaderDrag", {});
  ck("A4 FIXTURE: the row ladder is readable and has 3 rows",
     ladder.rowCount === 3 && (ladder.rowTops ?? []).length === 3,
     JSON.stringify(ladder.rowTops));

  const tops = ladder.rowTops, heights = ladder.rowHeights;
  const centre = (i) => tops[i] + heights[i] / 2;
  const dDrag = await depth();
  await req("debug.trackHeaderDrag", { act: "begin", trackId: R[0], y: centre(0) });
  const mid = await req("debug.trackHeaderDrag", { act: "changed", y: centre(2) });
  ck("A4 mid-drag the list is DRAWING a landing indicator and has NOT committed",
     mid.indicatorY !== null && JSON.stringify(mid.names) === JSON.stringify(["R1", "R2", "R3"]),
     `indicatorY=${mid.indicatorY} names=${JSON.stringify(mid.names)}`);
  const ended = await req("debug.trackHeaderDrag", { act: "end", y: centre(2) });
  ck("A4 THE REORDER DRAG STILL WORKS after the tap gesture was added: R1 landed "
     + "last, in ONE undo step",
     JSON.stringify(ended.names) === JSON.stringify(["R2", "R3", "R1"])
       && (await depth()) - dDrag === 1,
     `names=${JSON.stringify(ended.names)} depth ${dDrag} -> ${await depth()}`);
  await req("edit.undo");
  ck("A4 and it undoes cleanly",
     JSON.stringify((await req("debug.trackHeaderDrag", {})).names)
       === JSON.stringify(["R1", "R2", "R3"]),
     JSON.stringify((await req("debug.trackHeaderDrag", {})).names));

  // ══ WHAT THIS GATE CANNOT PROVE ══════════════════════════════════════════
  skip("a REAL mouse click on a REAL track header reaches `clickTrack`",
       "SwiftUI's TapGesture hands its handler no event, so the chord is read "
       + "from `NSEvent.modifierFlags` at mouse-up and a synthesized tap carries "
       + "none — `ArrangeClickModifiersBridge.swift:25-33` states this. INHERITED: "
       + "m23-g1 shipped with the same limitation for the clip click. The gate "
       + "drives the model with EXPLICIT modifiers, proving the decision and the "
       + "selection, not that one line of plumbing.");
  skip("double-click-to-rename survives the new single tap on the row",
       "`isEditingName` is @State inside `TrackRow` and is invisible to every "
       + "seam in this app — no command can read it and no capture can see the "
       + "field. The mount is `.simultaneousGesture(TapGesture())` precisely so "
       + "the question is MOOT rather than unanswered: a simultaneous gesture "
       + "never competes with a descendant's, so the count-2 rename tap cannot "
       + "be suppressed by construction. Needs a human to confirm.");
} catch (err) {
  fail++; failures.push(`harness: ${err.message}`);
  console.log(`FAIL harness :: ${err.message}\n${err.stack}`);
} finally {
  try { ws?.close(); } catch { /* already gone */ }
  stopStaging(GATE);
}

console.log(`\nM23Y ${pass}/${pass + fail}  (${skips.length} honest skips)`);
if (failures.length) console.log("failed legs:\n  " + failures.join("\n  "));
writeFileSync(`${OUT}/result.json`,
  JSON.stringify({ pass, fail, failures, skips }, null, 2));
process.exit(fail === 0 ? 0 : 1);
