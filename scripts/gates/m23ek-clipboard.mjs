// m23-ek-3 GATE — the EDIT CLIPBOARD (copy / cut / paste for clips and notes),
// against a REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE app
// and is never touched. Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves, end to end through the app's own menu actions: that copy → paste
//   round-trips clips and notes to CONTENT-EQUAL material; that a paste lands on
//   the PLAYHEAD and not where the material came from (with an anti-vacuity leg
//   that the source was somewhere else); that a multi-clip paste translates
//   RIGIDLY — every internal gap preserved, never welded; that a repeated paste
//   does NOT advance the anchor; that one undo reverses a whole paste; that a
//   note paste is its OWN undo step even 0 ms after a note edit (with the
//   anti-vacuity control that coalescing really is in force during the run);
//   that cut removes and pastes back identically; and that each menu item's
//   `refusedBy` branch is reachable and named.
//
//   DOES NOT PROVE — stated plainly, because a green leg here looks like proof:
//     • ⌘C / ⌘X / ⌘V. There are none in v1 (the USER'S OWN RULING — menu and
//       context menu only), and an unbundled staging binary does not route real
//       key events anyway (the m23-g1 law), so a leg that tried would pass or
//       fail for reasons unrelated to this code. NOTHING BELOW MAY USE A KEY.
//     • that the `Button`s appear in the Edit menu, or that the context-menu
//       entries are clickable. `Commands` bodies and `.contextMenu` builders are
//       not reachable from the wire. Every leg drives the SAME
//       `AppModel.performMenuCopy/Cut/Paste` those buttons call — which is what
//       the seam is FOR — but the last inch from a menu click to those methods
//       is unproven here. The titles and enabled states ARE proven, because the
//       seam echoes the very `copyMenuItem`/`cutMenuItem`/`pasteMenuItem`
//       properties the buttons render.
//     • a NEGATIVE paste anchor. `transport.positionBeats` is never negative, so
//       the group clamp is structurally unreachable from here — see the SKIP at
//       the end; `PasteAnchorPolicyTests` pins it headlessly.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW —
// derive it from values the gate controls or READS, never discover it by trial):
//   Track T0 (instrument) holds two SHORT clips with a gap:
//     A @ beat 0, len 2      B @ beat 4, len 2      → internal gap = 4 beats
//   Clip pastes are anchored at PASTE_BEAT = 32, chosen far past both so a
//   landing can never be confused with the source position and so no paste
//   overlaps the fixture. Expected: A' @ 32, B' @ 36 (32 + (4 − 0)).
//   Track T1 (instrument) holds ONE long clip R @ 0, len 16, with two notes at
//   clip-local 0 and 1.5 — a 1.5-beat gap that is DELIBERATELY OFF EVERY GRID,
//   so a paste that snapped each note instead of the anchor would weld them and
//   the gap assertion would go red.
//   ⚠️ NOTE_ANCHOR_BEAT = 4 IS NOT ARBITRARY. The roll snaps the paste anchor
//   through its own effective resolution, which this gate cannot read; beat 4 is
//   one BAR at 4/4, so it is a fixed point of every resolution the roll offers
//   (bar, beat, ½, ¼, ⅛, 1/16 — and `off`, which passes through). The expected
//   landing is therefore 4 whatever the roll's snap happens to be.
//
// Setup: none — run it.
//
//   node scripts/gates/m23ek-clipboard.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, panelDensityGuard, verdict } from "./_staging.mjs";

const GATE = "m23ekcb";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23EKCB_OUT || "/tmp/m23ekcb";
const PIDFILE = process.env.M23EKCB_PIDFILE || "/tmp/m23ekcb-staging.pid";
const BINARY = process.env.M23EKCB_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23EKCB_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

let guard = null;   // m23-ej-2: `let` — assigned after connect, read by the killer below
const killer = setTimeout(async () => {
  console.error("TIMEOUT");
  await guard?.restore("timeout");
  process.exit(2);
}, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE_MS = 250;

// The fixture's numbers, named once so no assertion can quietly disagree.
const PASTE_BEAT = 32;
const NOTE_ANCHOR_BEAT = 4;
const NOTE_GAP = 1.5;

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

buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
guard = panelDensityGuard(req);   // req already unwraps to .result ?? whole msg
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const cb = (p = {}) => req("debug.editClipboard", p);
const sel = (p = {}) => req("debug.arrangeSelection", p);
/** Clips on one track, sorted by start — read from the seam's own echo. */
const clipsOn = (echo, trackId) =>
  echo.clips.filter((c) => c.trackId === trackId).sort((a, b) => a.startBeat - b.startBeat);
const notesOf = (echo) => [...echo.editorNotes].sort((a, b) => a.startBeat - b.startBeat);

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await guard.set("arrange", "pro");
  await req("debug.panelLayout", { reset: true });
  const t0 = (await req("track.add", { kind: "instrument", name: "CB0" })).id;
  const t1 = (await req("track.add", { kind: "instrument", name: "CB1" })).id;
  const clipA = (await req("clip.addMIDI", {
    trackId: t0, atBeat: 0, lengthBeats: 2,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const clipB = (await req("clip.addMIDI", {
    trackId: t0, atBeat: 4, lengthBeats: 2,
    notes: [{ pitch: 67, startBeat: 0, lengthBeats: 1, velocity: 90 }],
  })).id;
  const clipR = (await req("clip.addMIDI", {
    trackId: t1, atBeat: 0, lengthBeats: 16,
    notes: [
      { pitch: 62, startBeat: 0, lengthBeats: 1, velocity: 100 },
      { pitch: 64, startBeat: NOTE_GAP, lengthBeats: 1, velocity: 110 },
    ],
  })).id;
  await sleep(SETTLE_MS);

  let e = await cb({});
  const fixtureA = e.clips.find((c) => c.id === clipA);
  const fixtureB = e.clips.find((c) => c.id === clipB);
  check("F0 fixture: two short clips with a 4-beat gap on T0, one 16-beat clip on T1",
        near(fixtureA?.startBeat, 0) && near(fixtureB?.startBeat, 4)
        && e.clips.filter((c) => c.trackId === t1).length === 1,
        `A@${fixtureA?.startBeat} B@${fixtureB?.startBeat} T1clips=`
        + `${e.clips.filter((c) => c.trackId === t1).length}`);

  // ══ C1 — the bare read, and every menu item's refusal ═════════════════════
  // ⚠️ THESE LEGS ASSERTED BARE TITLES ("Copy"/"Cut"/"Paste") AND WERE STALE —
  // fixed 2026-08-09 after the m23-ej-2 sweep re-ran this gate and it came back
  // RED. The bare-title convention was DELIBERATELY REVERSED in the source: see
  // `ClipboardMenuPolicy.swift:60-86`, whose own comment records that the
  // earlier "bare, per DeleteMenuPolicy" rationale MISQUOTED that precedent —
  // `DeleteMenuPolicy.inertTitle` is "Delete Selection", not "Delete". The
  // concrete defect bare titles caused: this group mounts `after: .pasteboard`,
  // so AppKit's native Cut/Copy/Paste stay above ours, and with nothing
  // selected the Edit menu rendered as SIX near-identical greyed rows.
  //
  // ⚠️ THE REAL LESSON, and why this comment is long: the SAME decision was
  // pinned in TWO homes and only ONE was updated. `ClipboardMenuPolicyTests`
  // (Swift) already asserts "Copy Selection" and has been green all along; this
  // `.mjs` gate kept asserting the superseded convention and nobody re-ran it.
  // Only the LIVE title carries a count ("Copy 3 Clips") — the inert title is
  // the one that had to become legible.
  const INERT = { copy: "Copy Selection", cut: "Cut Selection", paste: "Paste Clipboard" };
  check("C1 an empty clipboard: kind null, and PASTE names the empty-clipboard guard",
        e.kind === null && e.menu.paste.enabled === false
        && e.menu.paste.refusedBy === "empty-clipboard" && e.menu.paste.title === INERT.paste,
        `kind=${e.kind} paste=${JSON.stringify(e.menu.paste)}`);
  check("C1b nothing selected: COPY and CUT name the empty-selection guard, and the "
        + "INERT title names what the item is waiting for (not a bare verb)",
        e.menu.copy.refusedBy === "empty-selection" && e.menu.copy.title === INERT.copy
        && e.menu.cut.refusedBy === "empty-selection" && e.menu.cut.title === INERT.cut,
        `copy=${JSON.stringify(e.menu.copy)} cut=${JSON.stringify(e.menu.cut)}`);

  // ══ C2/C3 — copy one clip; PASTE GOES LIVE WITH NO OTHER ACTION ═══════════
  await sel({ act: "click", clipId: clipA });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("C2 one clip selected: COPY is live and its title names the blast radius",
        e.menu.copy.enabled === true && e.menu.copy.title === "Copy Clip"
        && e.menu.copy.surface === "arrange-clips",
        `copy=${JSON.stringify(e.menu.copy)}`);
  const seqBeforeCopy = e.seq;
  e = await cb({ act: "copy" });
  check("C3 copy loads the clipboard and PASTE flips live with no other action (F14)",
        e.result === true && e.kind === "clips" && e.clipCount === 1
        && e.seq === seqBeforeCopy + 1
        && e.menu.paste.enabled === true && e.menu.paste.title === "Paste Clip",
        `kind=${e.kind} count=${e.clipCount} seq=${seqBeforeCopy}→${e.seq} `
        + `paste=${JSON.stringify(e.menu.paste)}`);

  // ══ C4 — a paste lands on the PLAYHEAD ═══════════════════════════════════
  await req("transport.seek", { beats: PASTE_BEAT });
  const before = await cb({});
  const anchor = before.playheadBeat;   // DERIVED from the echo, never assumed
  check("C4a ANTI-VACUITY: the source clip is NOT already at the playhead",
        !near(fixtureA.startBeat, anchor) && near(anchor, PASTE_BEAT),
        `source@${fixtureA.startBeat}, playhead@${anchor} — so "landed at the playhead" `
        + `below is a real constraint and cannot pass because nothing moved`);
  const beforeIds = new Set(before.clips.map((c) => c.id));
  e = await cb({ act: "paste" });
  const pastedA = e.clips.find((c) => !beforeIds.has(c.id));
  check("C4b the pasted clip lands EXACTLY on the echoed playhead, on the source track",
        e.result === true && near(pastedA?.startBeat, anchor) && pastedA?.trackId === t0
        && near(pastedA?.lengthBeats, fixtureA.lengthBeats),
        `pasted@${pastedA?.startBeat} (anchor ${anchor}) track=${pastedA?.trackId === t0} `
        + `len=${pastedA?.lengthBeats}`);
  check("C4c content-equal: the pasted clip carries the source's notes under a FRESH id",
        pastedA?.id !== clipA && pastedA?.noteCount === fixtureA.noteCount,
        `id≠source=${pastedA?.id !== clipA} notes=${pastedA?.noteCount} vs ${fixtureA.noteCount}`);
  check("C4d the pasted clip is SELECTED, and the roll follows it (decision 5)",
        e.selectedClipIds.length === 1 && e.selectedClipIds[0] === pastedA?.id
        && e.focusClipId === pastedA?.id && e.rollOpen === true,
        `selected=${e.selectedClipIds.length} focus=${e.focusClipId === pastedA?.id} `
        + `rollOpen=${e.rollOpen} — a single-clip paste must NOT close an open roll`);
  check("C4e ONE undo step for the paste, labelled as one",
        e.undoLabels[0] === "Paste Clip 'MIDI Clip 1'" || /^Paste Clip /.test(e.undoLabels[0]),
        `top undo label = ${JSON.stringify(e.undoLabels[0])}`);

  // ══ C5 — repeated paste does NOT advance the anchor (decision 4) ══════════
  const beforeIds2 = new Set(e.clips.map((c) => c.id));
  e = await cb({ act: "paste" });
  const pastedA2 = e.clips.find((c) => !beforeIds2.has(c.id));
  check("C5 a second paste lands at the SAME playhead — the anchor does not advance",
        near(pastedA2?.startBeat, anchor) && pastedA2?.id !== pastedA?.id,
        `second paste @${pastedA2?.startBeat} (anchor still ${anchor}), fresh id=`
        + `${pastedA2?.id !== pastedA?.id}`);

  // ══ C6 — one undo reverses a WHOLE multi-clip paste, translated RIGIDLY ═══
  await req("edit.undo", {});   // drop the stacked second paste
  await req("edit.undo", {});   // drop the first paste
  await sel({ act: "click", clipId: clipA });
  await sel({ act: "click", clipId: clipB, shift: true });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("C6a two clips selected: the COPY title names TWO",
        e.menu.copy.title === "Copy 2 Clips" && e.menu.copy.enabled === true,
        `title=${JSON.stringify(e.menu.copy.title)}`);
  await cb({ act: "copy" });
  await req("transport.seek", { beats: PASTE_BEAT });
  const before3 = await cb({});
  const anchor3 = before3.playheadBeat;
  const beforeIds3 = new Set(before3.clips.map((c) => c.id));
  const undoDepthBefore = before3.undoLabels.length;
  e = await cb({ act: "paste" });
  const fresh = e.clips.filter((c) => !beforeIds3.has(c.id)).sort((a, b) => a.startBeat - b.startBeat);
  check("C6b BOTH clips land, the earliest ON the playhead",
        fresh.length === 2 && near(fresh[0]?.startBeat, anchor3),
        `landed ${fresh.length} at [${fresh.map((c) => c.startBeat).join(", ")}], anchor ${anchor3}`);
  check("C6c ⚠️ RIGID: the 4-beat internal gap survives EXACTLY — nothing welded",
        near(fresh[1]?.startBeat - fresh[0]?.startBeat, fixtureB.startBeat - fixtureA.startBeat),
        `pasted gap = ${fresh[1]?.startBeat - fresh[0]?.startBeat}, source gap = `
        + `${fixtureB.startBeat - fixtureA.startBeat} — a per-member clamp/snap would weld `
        + `these to 0`);
  check("C6d ONE undo entry for the whole two-clip paste",
        e.undoLabels.length === undoDepthBefore + 1 && e.undoLabels[0] === "Paste 2 Clips",
        `depth ${undoDepthBefore} → ${e.undoLabels.length}, top=${JSON.stringify(e.undoLabels[0])}`);
  const afterPaste = e.clips.length;
  e = await cb({});
  await req("edit.undo", {});
  e = await cb({});
  check("C6e one undo removes BOTH pasted clips",
        e.clips.length === afterPaste - 2,
        `clips ${afterPaste} → ${e.clips.length}`);

  // ══ C7 — CUT: removes, loads the clipboard, and pastes back identically ═══
  await sel({ act: "click", clipId: clipB });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("C7a one clip selected: CUT is live and titled",
        e.menu.cut.enabled === true && e.menu.cut.title === "Cut Clip",
        `cut=${JSON.stringify(e.menu.cut)}`);
  // m23-ee-2d: `e.clipCount` is the CLIPBOARD's count, not the project's — so
  // before this pin the leg could pass on an EMPTY `e.clips` (`[].every()` is
  // true), "proving" a clip was removed from a list it never actually read.
  // Pinning the delta says what C7b claims out loud — cut removed exactly one.
  const clipsBeforeCut = e.clips.length;
  e = await cb({ act: "cut" });
  check("C7b cut REMOVES the clip and loads the clipboard with it",
        e.result === true
        && e.clips.length === clipsBeforeCut - 1
        && e.clips.every((c) => c.id !== clipB)
        && e.kind === "clips" && e.clipCount === 1,
        `clips ${clipsBeforeCut} → ${e.clips.length}, `
        + `clipB gone=${e.clips.every((c) => c.id !== clipB)} kind=${e.kind}`);
  await req("transport.seek", { beats: PASTE_BEAT });
  const before4 = await cb({});
  const anchor4 = before4.playheadBeat;
  const beforeIds4 = new Set(before4.clips.map((c) => c.id));
  e = await cb({ act: "paste" });
  const back = e.clips.find((c) => !beforeIds4.has(c.id));
  check("C7c the cut clip pastes back CONTENT-EQUAL at the playhead",
        near(back?.startBeat, anchor4) && near(back?.lengthBeats, fixtureB.lengthBeats)
        && back?.noteCount === fixtureB.noteCount && back?.name === fixtureB.name
        && back?.trackId === t0,
        `@${back?.startBeat} len=${back?.lengthBeats} notes=${back?.noteCount} `
        + `name=${JSON.stringify(back?.name)}`);

  // ══ N — NOTES ════════════════════════════════════════════════════════════
  await sel({ act: "click", clipId: clipR });
  await sleep(SETTLE_MS);
  await sel({ act: "pianoRollNotes", select: true });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("N1a with the roll holding a note selection, COPY targets the ROLL",
        e.menu.copy.surface === "piano-roll-notes"
        && e.menu.copy.title === "Copy Selected Notes",
        `copy=${JSON.stringify(e.menu.copy)} — NO COUNT on purpose: the bridge publishes a `
        + `Bool, so the Edit menu does not have the number`);
  e = await cb({ act: "copy" });
  check("N1b copy loads NOTES, and PASTE names the count (the deliberate asymmetry)",
        e.result === true && e.kind === "notes" && e.noteCount === 2
        && e.menu.paste.title === "Paste 2 Notes" && e.menu.paste.surface === "piano-roll-notes",
        `kind=${e.kind} n=${e.noteCount} paste=${JSON.stringify(e.menu.paste.title)}`);

  // Paste the notes at a bar-aligned playhead inside the clip.
  await req("transport.seek", { beats: NOTE_ANCHOR_BEAT });
  const beforeNotes = await cb({});
  const srcNotes = notesOf(beforeNotes);
  check("N2a ANTI-VACUITY: the copied notes do NOT already start at the paste anchor",
        !near(srcNotes[0]?.startBeat, NOTE_ANCHOR_BEAT)
        && near(beforeNotes.playheadBeat, NOTE_ANCHOR_BEAT),
        `source notes at [${srcNotes.map((n) => n.startBeat).join(", ")}], anchor `
        + `${beforeNotes.playheadBeat} — so "landed at the anchor" below is a real constraint`);
  const beforeNoteIds = new Set(beforeNotes.editorNotes.map((n) => n.id));
  e = await cb({ act: "paste" });
  const pastedNotes = notesOf(e).filter((n) => !beforeNoteIds.has(n.id));
  check("N2b both notes land, the earliest ON the (bar-aligned) anchor",
        e.result === true && e.editorNotes.length === 4 && pastedNotes.length === 2
        && near(pastedNotes[0]?.startBeat, NOTE_ANCHOR_BEAT),
        `total=${e.editorNotes.length} pasted at `
        + `[${pastedNotes.map((n) => n.startBeat).join(", ")}], anchor ${NOTE_ANCHOR_BEAT}`);
  check("N2c ⚠️ RIGID: the OFF-GRID 1.5-beat gap survives EXACTLY — the anchor was "
        + "snapped ONCE, not each note",
        near(pastedNotes[1]?.startBeat - pastedNotes[0]?.startBeat, NOTE_GAP),
        `pasted gap = ${pastedNotes[1]?.startBeat - pastedNotes[0]?.startBeat}, source gap = `
        + `${NOTE_GAP} — snapping each note to any grid ≥ 1/2 would weld this`);
  check("N2d FRESH ids, and pitch/velocity/length carried verbatim",
        pastedNotes.every((n) => !beforeNoteIds.has(n.id))
        && pastedNotes[0]?.pitch === srcNotes[0].pitch
        && pastedNotes[1]?.pitch === srcNotes[1].pitch
        && pastedNotes[0]?.velocity === srcNotes[0].velocity
        && pastedNotes[1]?.velocity === srcNotes[1].velocity,
        `pitches=[${pastedNotes.map((n) => n.pitch).join(",")}] `
        + `velocities=[${pastedNotes.map((n) => n.velocity).join(",")}]`);
  check("N2e the pasted notes ARE the selection, so the user can drag them at once",
        e.menu.copy.surface === "piano-roll-notes",
        `copy still targets the roll ⇒ the roll reports a live note selection after the paste`);

  // ══ N3 — ⚠️⚠️ THE UNDO-COALESCING TRAP, END TO END, WITH ITS CONTROL ══════
  //
  // `setClipNotes` journals under `clip.notes:<id>` and the journal folds
  // same-key edits inside 800 ms. NO SLEEP ANYWHERE IN THIS BLOCK: a gate that
  // waited past the window would pass while proving nothing.
  const undoBefore = (await cb({})).undoLabels.length;
  const editNotes = (await cb({})).editorNotes.map((n) => ({
    pitch: n.pitch, startBeat: n.startBeat, lengthBeats: n.lengthBeats, velocity: n.velocity,
  }));
  // (1) THE CONTROL, FIRST: two note edits back to back must COALESCE into one
  //     entry. If this ever goes red, coalescing is not in force during this run
  //     and the paste leg below would be passing for free.
  await req("clip.setNotes", { clipId: clipR, notes: editNotes });
  await req("clip.setNotes", {
    clipId: clipR, notes: [...editNotes, { pitch: 72, startBeat: 12, lengthBeats: 1, velocity: 80 }],
  });
  e = await cb({});
  const afterTwoEdits = e.undoLabels.length;
  check("N3a ANTI-VACUITY CONTROL: two rapid note EDITS coalesce into ONE undo entry",
        afterTwoEdits === undoBefore + 1 && e.undoLabels[0] === "Edit Notes",
        `depth ${undoBefore} → ${afterTwoEdits} (expected +1), top=`
        + `${JSON.stringify(e.undoLabels[0])} — this is what proves the 800 ms window was `
        + `ACTIVE, so N3b below is not passing vacuously`);
  // (2) THE LEG: a paste immediately after those edits must be its OWN entry.
  e = await cb({ act: "paste" });
  check("N3b ⚠️ a note paste 0 ms after a note edit is its OWN undo step",
        e.undoLabels.length === afterTwoEdits + 1 && e.undoLabels[0] === "Paste Notes"
        && e.undoLabels[1] === "Edit Notes",
        `depth ${afterTwoEdits} → ${e.undoLabels.length}, top two = `
        + `${JSON.stringify(e.undoLabels.slice(0, 2))} — routed through the UNCOALESCED `
        + `pasteNotes; through setClipNotes it would have folded and read "Edit Notes"`);
  const notesAfterPaste = e.editorNotes.length;
  await req("edit.undo", {});
  e = await cb({});
  check("N3c one undo reverses ONLY the paste, leaving the edits standing",
        e.editorNotes.length === notesAfterPaste - 2 && e.undoLabels[0] === "Edit Notes",
        `notes ${notesAfterPaste} → ${e.editorNotes.length}, top=`
        + `${JSON.stringify(e.undoLabels[0])}`);

  // ══ N4 — CUT notes, then paste them back ═════════════════════════════════
  await sel({ act: "pianoRollNotes", select: true });
  await sleep(SETTLE_MS);
  const beforeCut = await cb({});
  const cutCount = beforeCut.editorNotes.length;
  e = await cb({ act: "cut" });
  check("N4a cut EMPTIES the roll and loads the clipboard with what it removed",
        e.result === true && e.editorNotes.length === 0
        && e.kind === "notes" && e.noteCount === cutCount,
        `notes ${cutCount} → ${e.editorNotes.length}, clipboard=${e.kind}/${e.noteCount}`);
  await req("transport.seek", { beats: NOTE_ANCHOR_BEAT });
  e = await cb({ act: "paste" });
  const backNotes = notesOf(e);
  const srcSorted = [...beforeCut.editorNotes].sort((a, b) => a.startBeat - b.startBeat);
  const srcMin = srcSorted[0].startBeat;
  check("N4b the cut notes paste back with their SHAPE intact (offsets from the anchor)",
        backNotes.length === cutCount
        && backNotes.every((n, i) =>
             near(n.startBeat - NOTE_ANCHOR_BEAT, srcSorted[i].startBeat - srcMin)
             && n.pitch === srcSorted[i].pitch && n.velocity === srcSorted[i].velocity),
        `back=[${backNotes.map((n) => n.startBeat).join(",")}] from `
        + `[${srcSorted.map((n) => n.startBeat).join(",")}] (min ${srcMin}) at anchor `
        + `${NOTE_ANCHOR_BEAT}`);

  // ══ R — the remaining refusal branches ═══════════════════════════════════
  // The clipboard holds NOTES; close the roll and Paste must name `no-roll-open`.
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("R1 notes on the clipboard with NO roll open: PASTE names no-roll-open",
        e.rollOpen === false && e.menu.paste.enabled === false
        && e.menu.paste.refusedBy === "no-roll-open" && e.menu.paste.title === INERT.paste,
        `rollOpen=${e.rollOpen} paste=${JSON.stringify(e.menu.paste)}`);
  // The Mix console owns no clip selection, so all three refuse on `workspace`.
  await req("ui.showMixer", { show: true });
  await sleep(SETTLE_MS);
  e = await cb({});
  check("R2 in the Mix console all three items refuse on the WORKSPACE guard",
        e.menu.copy.refusedBy === "workspace" && e.menu.cut.refusedBy === "workspace"
        && e.menu.paste.refusedBy === "workspace",
        `copy=${e.menu.copy.refusedBy} cut=${e.menu.cut.refusedBy} `
        + `paste=${e.menu.paste.refusedBy}`);
  await req("ui.showMixer", { show: false });
  await sleep(SETTLE_MS);
  // An unknown act is a TEACHING error, not a bare rejection (m23-cy).
  let teachErr = null;
  try { await cb({ act: "duplicate" }); } catch (err) { teachErr = String(err); }
  check("R3 an unknown act teaches the valid ones rather than merely refusing",
        teachErr !== null && /copy/.test(teachErr) && /cut/.test(teachErr)
        && /paste/.test(teachErr),
        `error = ${teachErr}`);

  // ══ what this gate structurally cannot reach ═════════════════════════════
  skip("a NEGATIVE paste anchor clamping the GROUP",
       "`transport.positionBeats` is never negative and there is no seam that could make it "
       + "so, therefore the group clamp is unreachable from the wire. It is NOT dead code — "
       + "`MIDINote.init` floors startBeat at 0 PER NOTE, so a negative anchor reaching the "
       + "store would weld the early notes rather than error. `PasteAnchorPolicyTests` pins "
       + "both the clamp and its anti-vacuity control headlessly; C6c and N2c above pin the "
       + "same RIGIDITY property on the reachable side.");
  skip("the Edit-menu Buttons and the two context menus",
       "`Commands` bodies and `.contextMenu` builders are not reachable from the wire. Every "
       + "leg above drives the same `performMenuCopy/Cut/Paste` those buttons call, and the "
       + "seam echoes the very `copyMenuItem`/`cutMenuItem`/`pasteMenuItem` properties they "
       + "render — so the POLICY is proven end to end and only the mount is not.");
  skip("⌘C / ⌘X / ⌘V",
       "there are none in v1 — the USER'S OWN RULING, menu and context menu only. And an "
       + "unbundled staging binary does not route real key events (the m23-g1 law), so even "
       + "if one existed a leg here would pass or fail for reasons unrelated to the code.");
  skip("a take-comp member refusing a cut (F15's clip half)",
       "building a take group needs a real multi-take recording fixture, which this gate has "
       + "no way to stand up. The ORDER that makes it honest — delete first, write the "
       + "clipboard only on `deleteArrangeSelection()`'s true return — is structural in "
       + "`AppModel.cutArrangeSelection`, and N4a proves the note half's success path.");

  // ══ summary ══════════════════════════════════════════════════════════════
  const bad = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - bad.length}/${checks.length} legs passed`
    + (skips.length ? `, ${skips.length} skipped` : ""));
  for (const s of skips) console.log(`  SKIP ${s.name}: ${s.why}`);
  if (bad.length) { for (const b of bad) console.log(`  FAIL ${b.name}: ${b.detail}`); }
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  // ⚠️ m23-ej-2: guard.restore() round-trips over `req`/`ws` — it MUST run
  // before ws.close(), never after (measured live on m23k4b's identical bug:
  // closing first strands the restore write until the guard's own timeout).
  await guard.restore("normal exit");
  ws.close();
  stopStaging(GATE, PIDFILE);
  verdict({ ran: checks.length, failed: bad.length });
} catch (e) {
  console.error("GATE ERROR", e);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips, error: String(e) }, null, 2));
  clearTimeout(killer);
  await guard.restore("catch");
  try { ws.close(); } catch {}
  stopStaging(GATE, PIDFILE);
  process.exit(2);
}
