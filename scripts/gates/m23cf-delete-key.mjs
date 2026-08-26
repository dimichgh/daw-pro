// m23-cf-3 GATE — THE DELETE KEY, AGAINST THE USER'S OWN REPRO.
//
// Staging port ONLY (imported from `_staging.mjs` as `STAGING_PORT`, never a
// literal here). 17600 is the user's LIVE app and is never touched; staging is
// killed PIDFILE-EXACT, never pkill/pgrep.
//
// ═══ THE REPORT THIS ENCODES, VERBATIM (2026-08-10) ═══
//
//   "I added one clip and then in note editor I added multiple notes and when I
//    select a note and hit delete, it does not remove the note. If I select a
//    clip and mouse in the track area, delete does not work either."
//
// So the fixture is THEIR shape — ONE clip, MULTIPLE notes — and the legs run in
// THEIR order: select ONE note and press DELETE (U1), then select the clip in
// the track area and press DELETE (U2). Nothing here was invented to be
// convenient to assert.
//
// ⭐ U1 ASSERTS THE RIGHT NOTE DIED, NOT MERELY THAT A NOTE DIED. "the note was
// deleted" and "the note I selected was deleted" are different claims, and only
// a COUNT plus an IDENTITY check separates them — a delete-all that happened to
// leave the clip standing would satisfy the first. The surviving notes are
// checked BY ID.
//
// ═══ WHY THE BUG WAS SEEN AT ALL, AND WHY THAT DOES NOT DECIDE THIS ═══
//
// The user tested `dist/DAWPro.app`, a STALE Aug-6 bundle (proven by
// `mdls -name kMDItemLastUsedDate`, last launched minutes before the report).
// The one-funnel key routing is uncommitted working-tree code that was never
// compiled into it, so their result is consistent with the fix being ABSENT and
// says nothing about whether it works. This gate answers that question against
// the CURRENT tree, which is the only reason it can be answered without a human.
//
// ═══ THE DEFECT ═══
//
// `DeleteMenuPolicy`'s banner records the diagnosis: THREE views claim
// `.onKeyPress(.delete)` behind three separate `@FocusState`s, only one can hold
// focus, and which one is eligible FLIPS ON EVERY CLIP SELECTION
// (`pianoRollEditorFocused` measured alternating 6 true / 6 false over 12
// consecutive selections). The three handlers then did DIFFERENT things.
//
// AND THE DIVERGENCE WAS DESTRUCTIVE: `handleArrangeNudgeKey` carries a fifth
// guard ("the roll would have consumed this key") and `handleArrangeDeleteKey`
// carries NO such term — `DAWProApp.swift`'s `arrangeKeyFocusNonce` note says
// the arrange branch "deletes the whole union INCLUDING the clip the roll is
// open on". So on the parity where the arrange won the coin flip while the roll
// was open with notes selected, DELETE deleted the CLIP instead of the note.
// That is what U1c pins.
//
// ═══ WHAT THIS DOES NOT PROVE — stated plainly, because a green leg looks like
// proof ═══
//
//   • THAT A SwiftUI `.onKeyPress(.delete)` EVER FIRES. It does not, in this app,
//     and leg K MEASURES that rather than assuming it.
//     ⚠️⚠️ STALE AS OF m23-fk (2026-08-10), NOTED AT m23-ft RATHER THAN REWRITTEN
//     — kept as the historical record of what leg K measured AT THE TIME, since
//     the claim below it (staging DOES route real key events) is still true and
//     is the load-bearing half. m23-fk respelled all three `.onKeyPress(.delete)`
//     mounts (`KeyEquivalent("\u{7F}")` alongside `.delete`/`.deleteForward`) so
//     they DO now fire for the physical ⌫ — leg K2arrival (added at m23-ft)
//     measures exactly that: `deleteKeyFunnelSeq` now advances across a REFUSED
//     key, which is only possible if a live mount was entered. Do not read the
//     sentence below as current.
//     ⚠️⚠️ THE OLD "m23-bw WALL" IS MIS-STATED WHEREVER IT SAYS AN UNBUNDLED
//     STAGING BINARY "DOES NOT ROUTE REAL KEY EVENTS" — this gate's own leg K
//     refutes that, and so do seven other gates' header notes (m23ak, m23am,
//     m23x, m23aj, m23y, m23g1, m23ek all repeat the wrong claim; they are FILED
//     for re-triage, not edited from here). Key events ARE routed: a posted
//     DELETE reaches AppKit's field editor and deletes text (K2), and a posted
//     SPACE drives the transport (K3). What never happened [AT THE TIME — see
//     the m23-fk/m23-ft note on the bullet above; it happens now] was a SwiftUI
//     `.onKeyPress` firing — being on the responder chain is NECESSARY but NOT
//     SUFFICIENT. That is why the fix is an `NSEvent` monitor
//     (`DeleteKeyMonitorRouting`) and not more focus wrangling — that
//     architectural reasoning is unaffected by m23-fk, which only changed
//     whether the MOUNTS ALSO fire for a key the monitor passes through.
//     ⭐ AND THE OLD PROBE WAS NEVER LYING. `{act:"keyDelete"}` (plain
//     `NSApp.sendEvent`) turns out to run local monitors too — MEASURED, see leg
//     D4, which was written asserting the opposite and went red. So its
//     `delivered:false` since m23-g1 was the app honestly reporting that NOTHING
//     HANDLED THE KEY. The signal was right; the interpretation ("staging cannot
//     inject keys") was wrong, and it sent five gates down the delivery path.
//   • SwiftUI's focus arbitration. Deliberately not a term in anything here:
//     m23-cf's fix is that every claimant gets the SAME answer, so who wins the
//     coin flip stops being visible. A gate that measured the arbitration would
//     be testing the thing the design refuses to depend on.
//
// ═══ FIXTURE ARITHMETIC, computed BEFORE any assertion was written ═══
//   ONE instrument track, ONE MIDI clip @ beat 0, 8 beats long, FOUR notes:
//     N0 pitch 60 @ 0 · N1 pitch 64 @ 2 · N2 pitch 67 @ 4 · N3 pitch 72 @ 6
//   The DELETE target is N1 — a MIDDLE note, so "the right one died" cannot be
//   satisfied by an off-by-one that always takes the first.
//   Notes are 2 beats apart with length 1, so a band over beats [1.5, 3.5]
//   excludes N0 and N2 BY X ALONE; pitches are ≥3 apart so rows 62..66 exclude
//   them BY Y ALONE. Both exclusions are asserted independently (U1a2), the
//   `m23ek-pianoroll-marquee` P0b idiom — a band that happened to be right for
//   one reason is not a fixture.
//   Content space is x = beats · ppb, y = (127 − pitch) · rowHeight, and NEITHER
//   scale may be assumed: `ppb` is the persisted, zoomable
//   `PanelLayoutStore.pianoRollPPB` and `rowHeight` is a model field. Both are
//   READ from `debug.pianoRollMarquee {}`.
//   A marker at beat 16 supplies leg C's rename field.
//
// ⚠️ EVERY ROLL-CLAIM STATE IS PROVEN NON-DESTRUCTIVELY BEFORE ANY PRESS, via
// `debug.editClipboard {}`'s `menu.copy` — which resolves through
// `ClipboardMenuPolicy` on the SAME `pianoRollWouldConsumeKey` term
// `deleteKeyRouting` reads. This is not belt-and-braces: `{act:"pianoRollNotes"}`
// does NOT throw on an unsatisfiable request (unlike `automationPoints` and
// `engage`), so a fixture that never armed would answer `ok`, DELETE would route
// to the arrange, the clip would die, and the gate would report "the destructive
// divergence is still live" — the most damaging wrong conclusion available here.
//
// Setup: none — run it.
//
//   node scripts/gates/m23cf-delete-key.mjs
import fs from "fs";
import {
  buildOrAbort, startStaging, stopStaging, panelDensityGuard, STAGING_PORT, sleep, verdict,
} from "./_staging.mjs";

const GATE = "m23cfdk";
const PORT = STAGING_PORT;               // never a literal — the standing law
const OUT = process.env.M23CFDK_OUT || "/tmp/m23cfdk";
const PIDFILE = process.env.M23CFDK_PIDFILE || "/tmp/m23cfdk-staging.pid";
const BINARY = process.env.M23CFDK_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23CFDK_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

let guard = null;   // assigned after connect; read by the killer below
const killer = setTimeout(async () => {
  console.error("TIMEOUT");
  await guard?.restore("timeout");
  process.exit(2);
}, 600_000);

const SETTLE_MS = 250;
// The fixture's numbers, named once so no assertion can quietly disagree.
const CLIP_LEN = 8, MARKER_BEAT = 16;
const FIXTURE_NOTES = [
  { key: "N0", pitch: 60, start: 0, len: 1 },
  { key: "N1", pitch: 64, start: 2, len: 1 },   // ⭐ the DELETE target — a MIDDLE note
  { key: "N2", pitch: 67, start: 4, len: 1 },
  { key: "N3", pitch: 72, start: 6, len: 1 },
];
const TARGET_KEY = "N1";
// `DeleteMenuPolicy.inertTitle` — the title a REFUSED key carries. Pinned as a
// literal because the whole point of that constant is that it is NOT the bare
// word "Delete" (macOS's own Edit menu already ships one).
const INERT_TITLE = "Delete Selection";

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

buildOrAbort({ label: "building staging binary (m23cf-delete-key)…" });
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
guard = panelDensityGuard(req);
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };

const sel = (p = {}) => req("debug.arrangeSelection", p);
const cb = (p = {}) => req("debug.editClipboard", p);   // READ-ONLY when p is {}
const mq = (p = {}) => req("debug.pianoRollMarquee", p);
const clipOf = (echo, id) => echo.clips.find((c) => c.id === id);
const sortIds = (a) => [...a].sort();
const same = (a, b) => a.length === b.length && sortIds(a).every((v, i) => v === sortIds(b)[i]);

/** A band over beats [b0,b1] × the rows of pitches [pHigh..pLow], in points. */
const bandOn = (rh, ppb, b0, b1, pHigh, pLow, pad = 2) => ({
  x0: b0 * ppb, x1: b1 * ppb,
  y0: (127 - pHigh) * rh + pad, y1: (127 - pLow) * rh + rh - pad,
});

/**
 * The gate's OWN independent band→ids implementation, never the app's — so
 * "the fixture selects exactly N1" is a claim this file can check before it
 * trusts the app's answer. `Math.max(3, …)` mirrors the roll's minimum hit
 * width (`m23ek-pianoroll-marquee`'s `expectHits`).
 */
function expectHits(rh, ppb, band, notes) {
  const x0 = Math.min(band.x0, band.x1), x1 = Math.max(band.x0, band.x1);
  const y0 = Math.min(band.y0, band.y1), y1 = Math.max(band.y0, band.y1);
  if (x1 - x0 <= 0 || y1 - y0 <= 0) return [];
  const out = [];
  for (const n of notes) {
    const nx0 = n.start * ppb, nx1 = nx0 + Math.max(3, n.len * ppb);
    const ny0 = (127 - n.pitch) * rh, ny1 = ny0 + rh;
    if (x0 < nx1 && nx0 < x1 && y0 < ny1 && ny0 < y1) out.push(n.id);
  }
  return sortIds(out);
}

/**
 * One full begin→changed→end band in CONTENT points.
 *
 * ⚠️ THIS IS THE USER'S GESTURE, not a flag the gate set for itself: it goes
 * through the roll's own `@State private` `PianoRollModel` selection, the same
 * path a mouse drag drives.
 */
async function sweep(band) {
  await mq({ act: "begin", x: band.x0, y: band.y0 });
  await mq({ act: "changed", x: band.x1, y: band.y1 });
  return mq({ act: "end", x: band.x1, y: band.y1 });
}

/**
 * Bounded poll until the store's note count for `clipId` reaches `want`.
 *
 * ⚠️ NEEDED, not defensive. `{act:"deleteKey"}` echoes the ROUTING DECISION and
 * deliberately not the outcome: when the routing names an EDITOR the handler
 * bumps a bridge nonce and returns before that editor has applied anything
 * (`PianoRollModel` is `@State private`, so the work lands on SwiftUI's next
 * body pass). A one-shot read turns a determinate result into a flake. Reads the
 * STORE-BACKED echo (`clips[].noteCount`), never a roll-local one, so a delete
 * that never reached the model reads RED rather than green.
 */
async function awaitNoteCount(clipId, want, ms = 2000) {
  const deadline = Date.now() + ms;
  let echo = await cb({});
  while (Date.now() < deadline && clipOf(echo, clipId)?.noteCount !== want) {
    await sleep(50);
    echo = await cb({});
  }
  return echo;
}

try {
  // ══ FIXTURE — THE USER'S SHAPE: ONE CLIP, MULTIPLE NOTES ═════════════════
  await req("project.new", { discardChanges: true });
  // m23-et: the window size is AMBIENT STICKY STATE that survives a staging
  // restart (it lives in `DAWApp` UserDefaults, which DAWPRO_PROFILE_ROOT does
  // not isolate). Pin it rather than inheriting whatever the last run left — an
  // ambient geometry can change a verdict, not just pixels.
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await guard.set("arrange", "pro");
  await req("debug.panelLayout", { reset: true });

  const trackId = (await req("track.add", { kind: "instrument", name: "CF0" })).id;
  const theClip = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: CLIP_LEN,
    notes: FIXTURE_NOTES.map((n) => ({
      pitch: n.pitch, startBeat: n.start, lengthBeats: n.len, velocity: 100,
    })),
  })).id;
  await req("marker.add", { beat: MARKER_BEAT, name: "RenameMe" });
  await sleep(SETTLE_MS);

  // Note IDs come from the STORE, never from the request — the ids are what the
  // identity assertions in U1c are made of.
  let e = await cb({});
  check("F0 fixture: ONE clip on ONE track holding "
        + `${FIXTURE_NOTES.length} notes — the user's shape`,
        e.clips.length === 1 && clipOf(e, theClip)?.noteCount === FIXTURE_NOTES.length,
        `clips=${e.clips.length} notes=${clipOf(e, theClip)?.noteCount}`);

  // ══ LEG C — THE TEXT-EDITING GUARD ═══════════════════════════════════════
  // FIRST, and against the FULL fixture, so "nothing was destroyed" is a claim
  // about a live clip and four live notes rather than about an empty project.
  await sel({ act: "click", clipId: theClip });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(SETTLE_MS);

  e = await cb({});
  check("C0 FIXTURE ARMED (non-destructive): the roll is open on the clip but "
        + "claims NOTHING, so the arrange is what a DELETE would target",
        e.rollOpen === true && e.editorClipId === theClip
        && e.menu.copy.surface === "arrange-clips",
        `rollOpen=${e.rollOpen} editorClipId=${e.editorClipId === theClip} `
        + `menu.copy.surface=${e.menu.copy.surface}`);

  await req("debug.markerRename", {});
  await sleep(SETTLE_MS);
  let s = await sel({});
  check("C1 CONTROL: the responder classifier reports a text field has focus — "
        + "without this the next leg would pass for the wrong reason",
        s.textEditing === true && s.count === 1 && s.selectedIds[0] === theClip,
        `textEditing=${s.textEditing} count=${s.count} `
        + `selected=${JSON.stringify(s.selectedIds)}`);

  s = await sel({ act: "deleteKey" });
  check("C2 ⭐ a Backspace typed into a rename field is REFUSED, and the refusal "
        + "NAMES the guard — not a bare `handled:false`",
        s.deleteKeyRefusedBy === "text-editing" && s.deleteKeySurface === null
        && s.deleteKeyHandled === false && s.deleteKeyTitle === INERT_TITLE,
        `refusedBy=${s.deleteKeyRefusedBy} surface=${s.deleteKeySurface} `
        + `handled=${s.deleteKeyHandled} title=${JSON.stringify(s.deleteKeyTitle)}`);

  // ⚠️ C2 AND C3 ARE NOT REDUNDANT, and a REDDEN RUN measured why rather than
  // arguing it. Forcing `deleteKeyRouting`'s `isTextEditingFocused` to false
  // turned C2 RED and left C3 GREEN: `handleArrangeDeleteKey` re-applies its own
  // text-editing guard as its THIRD guard, so the clip survived anyway. The
  // protection is DEFENCE IN DEPTH — two independent guards on two tiers — and
  // only C2 can see the routing tier go. It took BOTH guards removed at once to
  // turn C3 red (measured: the clip deleted while the rename field was open).
  e = await cb({});
  check("C3 ⭐ and it DESTROYED NOTHING: the clip and every note survive",
        e.clips.length === 1 && clipOf(e, theClip)?.noteCount === FIXTURE_NOTES.length,
        `clips=${e.clips.length} notes=${clipOf(e, theClip)?.noteCount}`);

  // GATE LAW (m17-d): clear text focus via `debug.markerRename {clear:true}`,
  // never a staged click — `debug.arrangePointer` runs SwiftUI's gesture
  // handlers directly, produces no NSEvent, and so cannot resign a field editor
  // by construction.
  await req("debug.markerRename", { clear: true });
  await sleep(SETTLE_MS);
  s = await sel({});
  check("C4 the pair's other half is armed: focus is back out of the field",
        s.textEditing === false,
        `textEditing=${s.textEditing}`);

  // ══ LEG U1 — ⭐⭐ THE USER'S STEP 1 ══════════════════════════════════════
  //   "in note editor I added multiple notes and when I select a note and hit
  //    delete, it does not remove the note"
  await sel({ act: "click", clipId: theClip });
  await sleep(SETTLE_MS);

  const scales = await mq({});
  check("U1a0 the roll is mounted and reports live scales — every band below is "
        + "DERIVED from these, never from a constant",
        scales.rowHeight > 0 && scales.ppb > 0 && scales.editorClipId === theClip
        && scales.noteCount === FIXTURE_NOTES.length && scales.count === 0,
        `rowHeight=${scales.rowHeight} ppb=${scales.ppb} `
        + `noteCount=${scales.noteCount} selected=${scales.count}`);

  const RH = scales.rowHeight, PPB = scales.ppb;
  const notesNow = await cb({});
  // Marry the fixture's description to the STORE's ids by (pitch, startBeat).
  const withIds = FIXTURE_NOTES.map((n) => ({
    ...n,
    id: notesNow.editorNotes.find(
      (x) => x.pitch === n.pitch && Math.abs(x.startBeat - n.start) < 1e-6)?.id,
  }));
  const target = withIds.find((n) => n.key === TARGET_KEY);
  const survivors = withIds.filter((n) => n.key !== TARGET_KEY).map((n) => n.id);
  check("U1a1 every fixture note resolved to a STORE id (the identity check in "
        + "U1c is made of these — an unresolved id would make it vacuous)",
        withIds.length === FIXTURE_NOTES.length
        && withIds.every((n) => typeof n.id === "string")
        && new Set(withIds.map((n) => n.id)).size === FIXTURE_NOTES.length,
        `ids=${JSON.stringify(withIds.map((n) => `${n.key}:${(n.id || "MISSING").slice(0, 8)}`))}`);

  const band = bandOn(RH, PPB, 1.5, 3.5, 66, 62);
  const want = expectHits(RH, PPB, band, withIds);
  const wideX = expectHits(RH, PPB, { ...band, x0: -1e6, x1: 1e6 }, withIds);
  const wideY = expectHits(RH, PPB, { ...band, y0: -1e6, y1: 1e6 }, withIds);
  const wideBoth = expectHits(RH, PPB, { x0: -1e6, x1: 1e6, y0: -1e6, y1: 1e6 }, withIds);
  // ⚠️ CORRECTED AGAINST A RED RUN rather than reasoned: this leg first claimed
  // the m23ek shape ("N0 excluded by X alone, N3 by Y alone") and went RED —
  // MEASURED `widening x alone -> 1`. The fixture is STRONGER than that: pitches
  // are ≥3 apart AND beats are 2 apart, so EITHER axis alone already excludes all
  // three neighbours. Asserted as the stronger property it actually has.
  // ⭐ AND `wideBoth` IS THE LOAD-BEARING CONTROL. Without it an `expectHits`
  // that always answered `[target]` would satisfy all three claims above — the
  // widened bands would look like evidence while proving the calculator is
  // constant. Widening BOTH axes must return every note.
  check(`U1a2 FIXTURE VALIDITY: the band covers EXACTLY ${TARGET_KEY}; EITHER `
        + "axis alone already excludes all three neighbours; and widening BOTH "
        + "returns all four (the control that stops a constant calculator passing)",
        same(want, [target.id]) && same(wideX, [target.id]) && same(wideY, [target.id])
        && same(wideBoth, withIds.map((n) => n.id)),
        `want=${want.length} wideX=${wideX.length} wideY=${wideY.length} `
        + `wideBoth=${wideBoth.length} (expect 1/1/1/${withIds.length})`);

  const swept = await sweep(band);
  check(`U1a3 ⭐ THE USER'S GESTURE: a drag in the note editor selects EXACTLY `
        + `ONE note (${TARGET_KEY}) — through the roll's own selection model`,
        swept.count === 1 && same(swept.selectedIds, [target.id])
        && swept.hasSelection === true && swept.editorClipId === theClip,
        `count=${swept.count} selected=${swept.count === 1 ? "the target" : "WRONG"} `
        + `hasSelection=${swept.hasSelection}`);

  e = await cb({});
  check("U1a4 FIXTURE ARMED (non-destructive): with one note selected the policy "
        + "says a DELETE targets the NOTES — the leg below is meaningless without it",
        e.menu.copy.surface === "piano-roll-notes" && e.rollOpen === true
        && e.editorClipId === theClip,
        `menu.copy.surface=${e.menu.copy.surface} rollOpen=${e.rollOpen}`);

  s = await sel({ act: "deleteKey" });
  check("U1b ⭐ DELETE routes to the PIANO ROLL — the surface, the title and the "
        + "ownership all name the notes",
        s.deleteKeySurface === "piano-roll-notes" && s.deleteKeyHandled === true
        && s.deleteKeyTitle === "Delete Selected Notes" && s.deleteKeyRefusedBy === null,
        `surface=${s.deleteKeySurface} handled=${s.deleteKeyHandled} `
        + `title=${JSON.stringify(s.deleteKeyTitle)} refusedBy=${s.deleteKeyRefusedBy}`);

  e = await awaitNoteCount(theClip, FIXTURE_NOTES.length - 1);
  const liveIds = e.editorNotes.map((n) => n.id);
  check("U1c ⭐⭐ THE USER'S BUG, ANSWERED: the SELECTED note is gone, the OTHER "
        + `${FIXTURE_NOTES.length - 1} notes are still there BY ID, and THE CLIP `
        + "SURVIVED (pre-m23-cf this parity deleted the clip)",
        e.clips.length === 1 && clipOf(e, theClip) !== undefined
        && clipOf(e, theClip).noteCount === FIXTURE_NOTES.length - 1
        && !liveIds.includes(target.id) && same(liveIds, survivors),
        `clips=${e.clips.length} clip=${clipOf(e, theClip) ? "alive" : "DELETED"} `
        + `notes=${clipOf(e, theClip)?.noteCount} target=`
        + `${liveIds.includes(target.id) ? "STILL THERE" : "gone"} `
        + `survivors=${same(liveIds, survivors) ? "all intact" : "WRONG SET"}`);

  s = await sel({});
  check("U1d and the ARRANGE SELECTION was never touched — the clip is still "
        + "selected and the roll is still open on it",
        s.count === 1 && s.selectedIds[0] === theClip && s.editorClipId === theClip,
        `count=${s.count} selected=${s.selectedIds[0] === theClip} `
        + `editorClipId=${s.editorClipId === theClip}`);

  // The MULTI-note case, since the user's report says "multiple notes": select
  // every remaining note and delete them in one press. The clip must STILL live.
  await sel({ act: "pianoRollNotes", select: true });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("U1e FIXTURE ARMED: all remaining notes selected, policy still names the roll",
        e.menu.copy.surface === "piano-roll-notes"
        && e.editorNotes.length === FIXTURE_NOTES.length - 1,
        `menu.copy.surface=${e.menu.copy.surface} notes=${e.editorNotes.length}`);
  s = await sel({ act: "deleteKey" });
  e = await awaitNoteCount(theClip, 0);
  check("U1f ⭐ a MULTI-note delete removes them all and the CLIP STILL SURVIVES",
        s.deleteKeySurface === "piano-roll-notes"
        && e.clips.length === 1 && clipOf(e, theClip) !== undefined
        && clipOf(e, theClip).noteCount === 0,
        `surface=${s.deleteKeySurface} clips=${e.clips.length} `
        + `clip=${clipOf(e, theClip) ? "alive" : "DELETED"} `
        + `notes=${clipOf(e, theClip)?.noteCount}`);

  // ══ LEG U2 — ⭐ THE USER'S STEP 2 ═══════════════════════════════════════
  //   "If I select a clip and mouse in the track area, delete does not work either"
  await sel({ act: "click", clipId: theClip });
  await sleep(SETTLE_MS);
  e = await cb({});
  s = await sel({});
  check("U2a FIXTURE ARMED: the clip is selected in the track area, no text "
        + "focus, and with its notes gone the ROLL no longer claims DELETE — so "
        + "the key must fall through to the clip",
        s.textEditing === false && s.count === 1 && s.selectedIds[0] === theClip
        && e.menu.copy.surface === "arrange-clips" && e.clips.length === 1,
        `textEditing=${s.textEditing} selected=${s.selectedIds[0] === theClip} `
        + `menu.copy.surface=${e.menu.copy.surface} clips=${e.clips.length}`);

  // The funnel counter's POSITIVE CONTROL rides this press: without it a
  // `keyReachedFunnel:false` in leg D could equally mean "the field is dead",
  // and the skip there would be vacuous.
  const seqBefore = (await sel({})).deleteKeyFunnelSeq;
  s = await sel({ act: "deleteKey" });
  const seqAfter = (await sel({})).deleteKeyFunnelSeq;
  check("U2b ⭐ DELETE routes to the ARRANGE and the arrange OWNS it",
        s.deleteKeySurface === "arrange-clips" && s.deleteKeyHandled === true
        && s.deleteKeyTitle === "Delete Clip" && s.deleteKeyRefusedBy === null,
        `surface=${s.deleteKeySurface} handled=${s.deleteKeyHandled} `
        + `title=${JSON.stringify(s.deleteKeyTitle)} refusedBy=${s.deleteKeyRefusedBy}`);

  e = await cb({});
  check("U2c ⭐⭐ THE USER'S CLIP IS ACTUALLY GONE",
        e.clips.length === 0 && clipOf(e, theClip) === undefined,
        `clips=${e.clips.length} clip=${clipOf(e, theClip) === undefined ? "gone" : "STILL THERE"}`);

  check("U2d POSITIVE CONTROL: the delete funnel's counter is live and moved "
        + "EXACTLY ONCE across that press",
        typeof seqBefore === "number" && seqAfter === seqBefore + 1,
        `deleteKeyFunnelSeq ${seqBefore} -> ${seqAfter}`);

  // ══ LEG D — THE STRONGER, CONDITIONAL PROBE (a REAL synthesized key) ═════
  const clipC = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: CLIP_LEN,
    notes: [{ pitch: 72, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sel({ act: "click", clipId: clipC });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(SETTLE_MS);
  const beforeProbe = await cb({});
  check("D1 FIXTURE ARMED for the real-key probe: exactly one clip, selected, "
        + "roll claiming nothing",
        beforeProbe.clips.length === 1 && clipOf(beforeProbe, clipC) !== undefined
        && beforeProbe.menu.copy.surface === "arrange-clips",
        `clips=${beforeProbe.clips.length} menu.copy.surface=`
        + `${beforeProbe.menu.copy.surface}`);

  const probe = await sel({ act: "keyDelete" });
  check("D2 the m23-cf-3 delivery field EXISTS and is a boolean — a missing "
        + "field would make the branch below silently take the skip arm forever",
        typeof probe.keyReachedFunnel === "boolean",
        `keyReachedFunnel=${JSON.stringify(probe.keyReachedFunnel)} `
        + `delivered=${JSON.stringify(probe.delivered)}`);

  const other = await sel({ act: "clear" });
  check("D3 and it is SCOPED to the keyDelete act — absent elsewhere, so no "
        + "gate can read a defaulted `false` from a call that sent no key",
        other.keyReachedFunnel === undefined && other.delivered === undefined,
        `on act:"clear" keyReachedFunnel=${JSON.stringify(other.keyReachedFunnel)} `
        + `delivered=${JSON.stringify(other.delivered)}`);

  const afterProbe = await cb({});
  // ⚠️ CORRECTED AGAINST A RED RUN, and the correction matters more than the leg.
  // This asserted that `NSApp.sendEvent` BYPASSES local monitors — reasoning by
  // analogy from `debug.keySpace {press:true}`, which calls `handleKeyDownEvent`
  // directly. MEASURED: `keyReachedFunnel=true delivered=true clips=1 -> 0`.
  // `sendEvent` DOES run local monitors (they are invoked on
  // `-[NSApplication sendEvent:]`'s path), so BOTH probe forms now exercise the
  // fix and the older, weaker one is the one that has been reporting
  // `delivered:false` since m23-g1 — which was never an injection failure at
  // all. It was the app honestly reporting that nothing handled the key.
  check("D4 ⭐ the `sendEvent` form reaches the monitor too — so the "
        + "`delivered:false` this probe has reported since m23-g1 was never a "
        + "broken injection, it was an app with no delete handler on the key",
        probe.keyReachedFunnel === true
        && afterProbe.clips.length === beforeProbe.clips.length - 1
        && clipOf(afterProbe, clipC) === undefined,
        `keyReachedFunnel=${probe.keyReachedFunnel} delivered=${probe.delivered} `
        + `clips=${beforeProbe.clips.length} -> ${afterProbe.clips.length}`);

  // ══ LEG K — ⭐⭐⭐ A REAL DELETE KEY ON THE REAL EVENT QUEUE ═════════════
  // The user's three results, reproduced and answered. `post:true` goes through
  // `NSApp.postEvent`, which DOES run local monitors — the only form that can
  // exercise `DeleteKeyMonitorRouting`.
  //
  // ⚠️ K3 IS NOT OPTIONAL. Without it, a silent K1 could mean "the injection
  // does not work" rather than "the app ignored the key", and that ambiguity is
  // exactly what made the m23-bw wall look like a delivery problem for months.
  // A fresh target: leg D's probe consumed `clipC`.
  const clipK = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: CLIP_LEN,
    notes: [{ pitch: 65, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sel({ act: "click", clipId: clipK });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(SETTLE_MS);
  const k0 = await sel({});
  const clipsBeforeK = (await cb({})).clips.length;
  await sel({ act: "keyDelete", post: true });
  await sleep(700);
  const k1 = await sel({});
  const afterK = await cb({});
  check("K1 ⭐⭐⭐ A REAL, POSTED DELETE KEY REACHES THE HANDLER AND REMOVES THE "
        + "USER'S CLIP — the eligibility half, which no amount of routing could "
        + "supply",
        k1.deleteKeyMonitorSeq === k0.deleteKeyMonitorSeq + 1
        && k1.deleteKeyMonitorRefusedBy === null
        && k1.deleteKeyFunnelSeq === k0.deleteKeyFunnelSeq + 1
        && afterK.clips.length === clipsBeforeK - 1,
        `monitorSeq ${k0.deleteKeyMonitorSeq}->${k1.deleteKeyMonitorSeq} `
        + `refusedBy=${k1.deleteKeyMonitorRefusedBy} `
        + `funnelSeq ${k0.deleteKeyFunnelSeq}->${k1.deleteKeyFunnelSeq} `
        + `clips ${clipsBeforeK}->${afterK.clips.length}`);

  // K2 — THE ANTI-REGRESSION CONTROL. A monitor that swallowed unconditionally
  // would make K1 green and break every rename field in the app (the m17-d
  // trap); only this leg can tell those apart.
  //
  // ⭐⭐ m23-fu: K1 (above) just consumed the ONLY clip on the board — its own
  // detail says `clips 1->0`. Left alone, `clipsBeforeK2` below would be 0 and
  // `afterK2.clips.length === clipsBeforeK2` would compare 0 to 0 NO MATTER WHAT
  // THE DELETE PATH DID — the conjunct could not fail. Build a fresh clip and
  // SELECT IT in the track area BEFORE the rename field is focused, so there is
  // something that WOULD be destroyed if the text-editing guard did not hold.
  // An unselected clip would be a weaker fixture (delete would spare it anyway,
  // selected or not, since nothing targets it) — this one is the thing a
  // leaking delete would actually take.
  const clipK2 = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: CLIP_LEN,
    notes: [{ pitch: 69, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sel({ act: "click", clipId: clipK2 });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(SETTLE_MS);
  const k2Armed = await sel({});
  const k2ArmedClips = await cb({});
  check("K2pre ⭐ m23-fu FIXTURE ARMED: a clip exists AND is selected in the "
        + "track area, WITH THE ARRANGE (not the roll) OWNING DELETE, before "
        + "the rename field is focused — the thing K2's anti-regression "
        + "conjunct must have something to protect (without this it compares "
        + "0 to 0 no matter what the delete path does; and without the "
        + "surface term, a `select:false` that silently didn't take would let "
        + "a leaking delete take NOTES, and a surviving clip count would read "
        + "'safe' for the wrong reason — same trap D1/U2a guard against)",
        k2Armed.textEditing === false && k2Armed.count === 1
        && k2Armed.selectedIds[0] === clipK2 && k2ArmedClips.clips.length === 1
        && k2ArmedClips.menu.copy.surface === "arrange-clips",
        `textEditing=${k2Armed.textEditing} count=${k2Armed.count} `
        + `selected=${k2Armed.selectedIds[0] === clipK2} `
        + `clips=${k2ArmedClips.clips.length} `
        + `menu.copy.surface=${k2ArmedClips.menu.copy.surface}`);

  await req("marker.add", { beat: MARKER_BEAT, name: "RenameMe" });
  await req("debug.markerRename", {});
  await sleep(400);
  const f0 = await req("debug.keySpace", {});
  const m0 = await sel({});
  const clipsBeforeK2 = (await cb({})).clips.length;
  check("K2focus ⭐ m23-fu: the rename field is genuinely focused (a real "
        + "string, non-empty, matching the marker's own name) AND the clip "
        + "from K2pre is STILL selected — adding/selecting that clip did not "
        + "steal the focus this leg is about to test, and the delete target is "
        + "still live at the exact moment K2 posts",
        typeof f0.fieldText === "string" && f0.fieldText === "RenameMe"
        && m0.textEditing === true && m0.count === 1
        && m0.selectedIds[0] === clipK2 && clipsBeforeK2 === 1,
        `fieldText=${JSON.stringify(f0.fieldText)} textEditing=${m0.textEditing} `
        + `selected=${m0.selectedIds[0] === clipK2} clipsBeforeK2=${clipsBeforeK2}`);

  await sel({ act: "keyDelete", post: true });
  await sleep(700);
  const f1 = await req("debug.keySpace", {});
  const m1 = await sel({});
  const afterK2 = await cb({});
  // ⭐⭐ m23-ft (RE-SCOPED 2026-08-10): this leg's FIFTH conjunct used to be
  // `m1.deleteKeyFunnelSeq === m0.deleteKeyFunnelSeq` — asserting the funnel
  // does NOT move for a refused key. That was WRONG and is REMOVED here, not
  // reworded: `deleteKeyFunnelSeq` is an ARRIVAL counter, bumped as the FIRST
  // statement of `handleDeleteKey()` "before any guard runs, so it moves iff a
  // `.onKeyPress(.delete)` really reached the app, whatever the routing then
  // decided" (`DAWProApp.swift:5465-5467`, restated `:1782-1786`). Before
  // m23-fk no `.onKeyPress(.delete)` mount could fire for the physical ⌫ at
  // all (`KeyEquivalent.delete` == 0x08 vs the key's own 0x7F — see
  // `KeyPressProbe.swift`), so the funnel never moved for a refused key and
  // this conjunct passed by COINCIDENCE, not by protection. m23-fk correctly
  // made the three mounts live for ⌫ and the coincidence ended (measured:
  // `funnelSeq 6->7` on an otherwise-identical run). DO NOT RESTORE THIS
  // CONJUNCT — see leg K2arrival below, which pins the funnel MOVING as the
  // CORRECT post-m23-fk behaviour so this mistake cannot recur unnoticed.
  // ⚠️ The real safety claim was NEVER carried by the funnel conjunct — it is
  // carried entirely by `afterK2.clips.length === clipsBeforeK2` below (made
  // non-vacuous by K2pre/m23-fu) plus `monitorRefusedBy === "text-editing"`.
  // Mechanism is deliberately NOT named here: a redden at `:311-317` measured
  // that forcing `deleteKeyRouting`'s own text-editing term to false still
  // left the clip alive, because `handleArrangeDeleteKey` re-applies a THIRD,
  // independent guard — so clip-survival alone cannot say WHICH lower-tier
  // guard held, only that at least one did.
  check("K2 ⭐⭐ AND NOTHING IS DESTROYED: with a rename field focused the TEXT "
        + "still loses characters, the monitor NAMES the text-editing guard, "
        + "and the clip survives — regardless of whether the funnel itself "
        + "ran (it does; see K2arrival)",
        typeof f0.fieldText === "string" && typeof f1.fieldText === "string"
        && f1.fieldText.length < f0.fieldText.length
        && m1.deleteKeyMonitorRefusedBy === "text-editing"
        && afterK2.clips.length === clipsBeforeK2,
        `fieldText ${JSON.stringify(f0.fieldText)}->${JSON.stringify(f1.fieldText)} `
        + `monitorRefusedBy=${m1.deleteKeyMonitorRefusedBy} `
        + `clips ${clipsBeforeK2}->${afterK2.clips.length}`);

  // K2arrival — ⭐ ADDED AT m23-ft (TASK B): pins the ARRIVAL fact itself, so
  // the retracted m23-ft misunderstanding cannot recur silently. This is
  // ARRIVAL, not ACTION — it says a live `.onKeyPress(.delete)` mount was
  // entered and `handleDeleteKey()` ran, and nothing about what it decided
  // (that half is K2, above, and C2's `refusedBy` for the seam-driven twin).
  // It became true at m23-fk: before that closed item, no delete mount could
  // fire for a physical ⌫ at all, so this leg would have been red — that is
  // the OLD, WRONG expectation this leg replaces.
  // ⭐ WHICH MOUNT — deliberately NOT asserted. `KeyPressProbe.swift`'s own
  // header (`:78-93`) states that `ContentView`'s `ArrangeDeleteKey` mount and
  // `PianoRollView`'s note-delete mount — the two live candidates for this
  // arrange-workspace, roll-open-with-no-notes-selected fixture — carry NO
  // entry counter BY DESIGN, because `DeleteKeySiteTests` already pins their
  // exact `.onKeyPress` spelling and a counter would weaken that shipped
  // guard. Only `automationLaneDelete` is instrumented, and this fixture has
  // no automation lane mounted, so a "did not move" read on it would be true
  // but would not discriminate between the two real candidates — an
  // uninformative conjunct, not a clean one. Per m23-ft's own instruction not
  // to force an assertion the fields cannot cleanly support, this is
  // documented rather than asserted; see the QA report for the coverage gap.
  check("K2arrival ⭐ THE FUNNEL ARRIVES for K2's posted key even though it is "
        + "refused — CORRECT since m23-fk, not a leak (see the comment on K2 "
        + "above for why the OLD assertion of the opposite was wrong)",
        m1.deleteKeyFunnelSeq === m0.deleteKeyFunnelSeq + 1,
        `funnelSeq ${m0.deleteKeyFunnelSeq}->${m1.deleteKeyFunnelSeq}`);

  await req("debug.markerRename", { clear: true });
  await sleep(300);

  // K3 — THE INJECTION CONTROL. A posted SPACE rides the SAME monitor by a
  // different branch. If this is red, K1/K2 say nothing about the app.
  const t0 = await req("debug.keySpace", {});
  await req("debug.keySpace", { press: true, post: true });
  await sleep(700);
  const t1 = await req("debug.keySpace", {});
  check("K3 CONTROL: `NSApp.postEvent` genuinely delivers — a posted SPACE "
        + "toggles the transport through the same monitor",
        t1.monitorInstalled === true && t0.isPlaying !== t1.isPlaying,
        `monitorInstalled=${t1.monitorInstalled} isPlaying `
        + `${t0.isPlaying}->${t1.isPlaying}`);
  if (t1.isPlaying) await req("transport.stop");

  skip("a HUMAN pressing DELETE on the shipped bundle",
       "everything above runs against `.build/debug/DAWApp` with a SYNTHESIZED event on "
       + "the real queue. That is strictly stronger than the previous state of this gate "
       + "— it exercises the NSEvent monitor end to end — but it is still not a finger on "
       + "a key in `dist/DAWPro.app`. The user's 2026-08-10 report was against a bundle "
       + "that PREDATES this code, so it cannot confirm or refute it; a re-test on a "
       + "freshly bundled app is owed.");
  skip("the Edit ▸ Delete menu item and the two context menus",
       "`Commands` bodies and `.contextMenu` builders are not reachable from the wire. "
       + "They route `DeleteMenuPolicy.editMenuItem`, which `keyPress` (proven above) "
       + "literally CALLS, and `DeleteMenuPolicyTests` sweeps the precedence headlessly.");
  skip("the automation-lane branch of the routing",
       "`{act:\"automationPoints\", select:true}` needs a mounted lane editor with "
       + "breakpoints, which this fixture does not stand up. m23ai-automation-nudge-guard "
       + "owns that fixture; the branch itself is swept by `DeleteMenuPolicyTests`.");

  // ══ SUMMARY ══════════════════════════════════════════════════════════════
  const bad = checks.filter((c) => !c.ok);
  console.log(`\nM23CF_DELETE_GATE pass=${checks.length - bad.length} `
    + `fail=${bad.length} total=${checks.length} skipped=${skips.length}`);
  for (const sk of skips) console.log(`  SKIP ${sk.name}: ${sk.why}`);
  if (bad.length) for (const b of bad) console.log(`  FAIL ${b.name}: ${b.detail}`);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  // ⚠️ m23-ej-2: `guard.restore()` round-trips over `req`/`ws`, so it MUST run
  // BEFORE `ws.close()` — measured live on m23k4b's identical bug: closing
  // first strands the restore write until the guard's own timeout.
  await guard.restore("normal exit");
  ws.close();
  stopStaging(GATE, PIDFILE);
  // ⚠️ m23-fa-2: routed through verdict() — same "run that asserted nothing is
  // not green" fix this comment already described, now on the one primitive.
  verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
} catch (err) {
  console.error("GATE ERROR", err);
  console.log(`\nM23CF_DELETE_GATE pass=${checks.filter((c) => c.ok).length} `
    + `fail=${checks.filter((c) => !c.ok).length} total=${checks.length} `
    + `skipped=${skips.length} ERRORED`);
  fs.writeFileSync(`${OUT}/result.json`,
    JSON.stringify({ checks, skips, error: String(err) }, null, 2));
  clearTimeout(killer);
  await guard?.restore("catch");
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
  process.exit(2);
}
