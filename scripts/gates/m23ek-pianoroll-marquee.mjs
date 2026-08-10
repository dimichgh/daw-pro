// m23-ek-1 GATE — the PIANO ROLL's rubber band, against a REAL app on staging
// (port 17695 ONLY; 17600 is the user's LIVE app and is never touched. Staging
// is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves, end to end through the app's own handlers: that a band selects
//   exactly the notes it touches (with an X-ONLY and a Y-ONLY exclusion, so a
//   band that ignored either axis fails); that the band is POSITIVELY visible
//   mid-drag and gone after release; that PROMOTION really is gated on travel
//   (a sub-slop drag draws no band); that shrinking gives notes back; that the
//   chord unions rather than replaces; that a degenerate press still CLEARS, as
//   it did before this item; zoom invariance at a second `ppb`; the three
//   shipped-behaviour changes of the ⌘ chord table (m23-ek-1 D5); that an
//   external mutation mid-band leaves no ghost; and that the roll is ENGAGED by
//   a staged press exactly as by a mouse press.
//
//   DOES NOT PROVE — stated plainly, because a green leg here looks like proof:
//     • that SwiftUI's real gesture arbitration promotes a physical mouse drag.
//       A real drag is not injectable (`DragGesture.Value` has no public
//       initializer; the unbundled staging binary has no Accessibility grant —
//       the m17-b measurement). Every leg below drives `PianoRollView`'s own
//       press/promote/release handlers, which is what the seam is FOR, but the
//       last inch from AppKit to those handlers is unproven here. The evidence
//       it is right is that `gridDrag` already routes note clicks, moves and
//       resizes through the same three functions.
//     • the live `ArrangeClickModifiers.current` read: the chord is passed
//       EXPLICITLY, so that one line is exercised by no seam (as the arrange
//       records for `debug.arrangeMarquee`).
//     • a coordinate-space mismatch between the live gesture and the drawn band:
//       this seam feeds grid CONTENT points straight in.
//     • the row-height half of the zoom law: `PianoRollModel.rowHeight` has no
//       staging seam (it is not a `PanelLayoutStore` slot), so it cannot be
//       driven. Every y below is still DERIVED from the echoed `rowHeight` — see
//       the SKIP at the end.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW —
// derive it from values the gate controls or READS, never discover it by trial):
//   Content space is x = beats · ppb, y = (127 − pitch) · rowHeight. NEITHER
//   scale is a constant a fixture may assume: `ppb` is the persisted, zoomable
//   `PanelLayoutStore.pianoRollPPB`, and `rowHeight` is a model field. Both are
//   read from `debug.pianoRollMarquee {}`.
//   Four notes in one 8-beat clip, chosen so each exclusion is single-axis:
//     N0 pitch 62 @0  len1   — excluded by X ONLY (same row as N1)
//     N1 pitch 62 @2  len1   — IN
//     N2 pitch 64 @4  len1   — IN
//     N3 pitch 72 @4  len1   — excluded by Y ONLY (same beat as N2)
//   Band: beats [1.5, 5.5] × rows [pitch 64 .. pitch 62]. A band that dropped
//   the X test would take N0; one that dropped the Y test would take N3.
//
// Setup: none — run it.
//
//   node scripts/gates/m23ek-pianoroll-marquee.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, panelDensityGuard, verdict } from "./_staging.mjs";

const GATE = "m23ek";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23EK_OUT || "/tmp/m23ek";
const PIDFILE = process.env.M23EK_PIDFILE || "/tmp/m23ek-staging.pid";
const BINARY = process.env.M23EK_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23EK_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

let guard = null;   // m23-ej-2: `let` — assigned after connect, read by the killer below
const killer = setTimeout(async () => {
  console.error("TIMEOUT");
  await guard?.restore("timeout");
  process.exit(2);
}, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE_MS = 250;

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
const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const sortIds = (a) => [...a].sort();
const short = (ids) => ids.map((i) => i.slice(0, 4)).join(",");

const mq = (p = {}) => req("debug.pianoRollMarquee", p);
const sel = (p = {}) => req("debug.arrangeSelection", p);

/** The gate's OWN independent band→ids implementation. Never the app's. */
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
 * Empties the NOTE selection the way the user does — a press on empty grid that
 * never travels, i.e. the shipped click-to-deselect (leg D2 proves it clears).
 *
 * ⚠️ NOT `debug.arrangeSelection {act:"clear"}`, and this cost a full red run to
 * learn: `openEditorClip` is derived from the arrange's `selectedClipID`, so
 * clearing THAT closes the editor. The roll then unmounts, `clearSurface` blanks
 * the echo, and every later leg reads `ppb: 0` and fails for a reason that has
 * nothing to do with the band.
 */
async function clearNotes(rh, ppb) {
  const x = 7 * ppb, y = (127 - 50) * rh + rh / 2;   // empty grid: no note near it
  await mq({ act: "begin", x, y });
  return mq({ act: "end", x, y });
}

/**
 * Runs a full begin→changed→end band in CONTENT points. Returns the echoes.
 *
 * ⚠️ THE CHORD GOES ON EVERY STEP, and that is the app's rule rather than this
 * gate's convenience. The live gesture reads `NSEvent.modifierFlags` at the
 * instant each DECISION is made — at PROMOTION (which happens on a `changed`,
 * not on the press) and at RELEASE — so a seam that carried the chord only on
 * `begin` would model a user who pressed shift, released it, and then dragged.
 * That is a real gesture, and a different one. (The arrange's seam takes it at
 * `begin` because over there the band arms at press; the m23-ek design doc
 * copied that clause, and it does not hold for a promotion-based band.)
 * MEASURED: with the chord on `begin` alone, an additive band REPLACED.
 */
async function sweep(band, chord = {}) {
  const begin = await mq({ act: "begin", x: band.x0, y: band.y0, ...chord });
  const mid = await mq({ act: "changed", x: band.x1, y: band.y1, ...chord });
  const end = await mq({ act: "end", x: band.x1, y: band.y1, ...chord });
  return { begin, mid, end };
}

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await guard.set("arrange", "pro");
  await req("debug.panelLayout", { reset: true });
  const trackId = (await req("track.add", { kind: "instrument", name: "EK" })).id;
  const clipId = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: 8,
    notes: [
      { pitch: 62, startBeat: 0, lengthBeats: 1, velocity: 100 },
      { pitch: 62, startBeat: 2, lengthBeats: 1, velocity: 100 },
      { pitch: 64, startBeat: 4, lengthBeats: 1, velocity: 100 },
      { pitch: 72, startBeat: 4, lengthBeats: 1, velocity: 100 },
    ],
  })).id;
  // OPEN THE ROLL — deliberately not something the marquee seam does itself.
  await sel({ act: "click", clipId });
  await sleep(SETTLE_MS);

  // Note ids, read from the STORE (the seam reports ids, so the gate needs the
  // same ids to name them by).
  const snap = await req("project.snapshot", {});
  const tracks = snap.project?.tracks ?? snap.tracks ?? [];
  const storedNotes = (tracks.find((t) => t.id === trackId)?.clips ?? [])
    .find((c) => c.id === clipId)?.notes ?? [];
  const at = (pitch, start) => storedNotes.find((n) => n.pitch === pitch && near(n.startBeat, start));
  const N0 = at(62, 0)?.id, N1 = at(62, 2)?.id, N2 = at(64, 4)?.id, N3 = at(72, 4)?.id;
  check("F0 fixture: four notes landed with readable ids at the exact beats assumed",
        storedNotes.length === 4 && [N0, N1, N2, N3].every((i) => typeof i === "string"),
        `count=${storedNotes.length} ids=${short([N0, N1, N2, N3].map(String))}`);
  const NOTES = [
    { id: N0, pitch: 62, start: 0, len: 1 },
    { id: N1, pitch: 62, start: 2, len: 1 },
    { id: N2, pitch: 64, start: 4, len: 1 },
    { id: N3, pitch: 72, start: 4, len: 1 },
  ];

  // ── The BARE read: the m11-a law, and the only legal source of the scales.
  const flat = await mq({});
  check("F1 a BARE debug.pianoRollMarquee is read-only and answers the SCALES",
        flat.rowHeight > 0 && flat.ppb > 0 && flat.bandRect === null
          && flat.noteCount === 4 && flat.editorClipId === clipId,
        `rowHeight=${flat.rowHeight} ppb=${flat.ppb} band=${flat.bandRect} `
        + `notes=${flat.noteCount} editorClip=${flat.editorClipId === clipId}`);
  check("F2 the roll opened with NOTHING selected (non-vacuity for every leg below)",
        flat.count === 0 && flat.selectedIds.length === 0 && flat.hasSelection === false,
        `count=${flat.count} hasSelection=${flat.hasSelection}`);

  /** A band over beats [b0,b1] × the rows of pitches [pHigh..pLow], in points. */
  const bandOn = (rh, ppb, b0, b1, pHigh, pLow, pad = 2) => ({
    x0: b0 * ppb, x1: b1 * ppb,
    y0: (127 - pHigh) * rh + pad, y1: (127 - pLow) * rh + rh - pad,
  });

  // ══ P  POSITIVE CORRECTNESS, ONE AXIS AT A TIME ══════════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    const band = bandOn(RH, PPB, 1.5, 5.5, 64, 62);
    const want = expectHits(RH, PPB, band, NOTES);
    check("P0 fixture: the band is computed to include exactly N1 and N2",
          same(want, sortIds([N1, N2])), `want=${short(want)}`);
    check("P0b VALIDITY: N0 is excluded by X ALONE and N3 by Y ALONE",
          same(expectHits(RH, PPB, { ...band, x0: -1e6, x1: 1e6 }, NOTES),
               sortIds([N0, N1, N2]))
            && same(expectHits(RH, PPB, { ...band, y0: -1e6, y1: 1e6 }, NOTES),
                    sortIds([N1, N2, N3])),
          "widening x alone adds N0; widening y alone adds N3");

    const r = await sweep(band);
    check("P1 a band selects exactly the notes it touches",
          same(sortIds(r.end.selectedIds), want),
          `got=${short(sortIds(r.end.selectedIds))} want=${short(want)}`);
    check("P2 hitIds and selectedIds agree on a PLAIN band (no base to union)",
          same(sortIds(r.end.hitIds), want), `hitIds=${short(sortIds(r.end.hitIds))}`);
    check("P3 the roll REPORTS the selection to the keyboard gate (hasSelection went true)",
          r.end.hasSelection === true && r.end.count === 2,
          `hasSelection=${r.end.hasSelection} count=${r.end.count}`);

    // ── V  THE BAND IS VISIBLE MID-DRAG, AND GONE AFTER ────────────────────
    check("V1 the band is POSITIVELY reported mid-drag with the expected geometry",
          r.mid.bandRect
            && near(r.mid.bandRect.x, Math.min(band.x0, band.x1))
            && near(r.mid.bandRect.y, Math.min(band.y0, band.y1))
            && near(r.mid.bandRect.width, Math.abs(band.x1 - band.x0))
            && near(r.mid.bandRect.height, Math.abs(band.y1 - band.y0)),
          `rect=${JSON.stringify(r.mid.bandRect)}`);
    check("V2 the band is GONE after release, and the selection SURVIVES it",
          r.end.bandRect === null && r.end.selectedIds.length === 2,
          `band=${r.end.bandRect} selected=${r.end.selectedIds.length}`);
    check("V3 a staged BEGIN arms no band — promotion is a TRAVEL decision, not a press",
          r.begin.bandRect === null,
          `beginRect=${r.begin.bandRect} (the arrange arms at press; this surface must not)`);

    // ── N  NEGATIVE EXTENTS ────────────────────────────────────────────────
    const rev = await sweep({ x0: band.x1, y0: band.y1, x1: band.x0, y1: band.y0 });
    check("N1 a band dragged RIGHT-TO-LEFT and BOTTOM-TO-TOP selects the same notes",
          same(sortIds(rev.end.selectedIds), want),
          `reverse=${short(sortIds(rev.end.selectedIds))}`);
    check("N2 …and the reported rect is NORMALIZED — positive extents, origin at the min corner",
          rev.mid.bandRect && rev.mid.bandRect.width > 0 && rev.mid.bandRect.height > 0
            && near(rev.mid.bandRect.x, Math.min(band.x0, band.x1))
            && near(rev.mid.bandRect.y, Math.min(band.y0, band.y1)),
          `rect=${JSON.stringify(rev.mid.bandRect)}`);
  }

  // ══ T  PROMOTION IS GATED ON TRAVEL ══════════════════════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    // A band big enough to matter, approached in two steps: one INSIDE the 4 pt
    // slop, one past it. A staged begin+end at one point could never test this —
    // it never travels — so the only honest shape is begin → changed → changed.
    const band = bandOn(RH, PPB, 1.5, 5.5, 64, 62);
    await clearNotes(RH, PPB);
    await mq({ act: "begin", x: band.x0, y: band.y0 });
    const tiny = await mq({ act: "changed", x: band.x0 + 2, y: band.y0 + 1 });
    check("T1 a drag INSIDE the 4 pt slop draws NO band and selects nothing",
          tiny.bandRect === null && tiny.count === 0,
          `travel=√5≈2.24 pt band=${tiny.bandRect} count=${tiny.count}`);
    const past = await mq({ act: "changed", x: band.x1, y: band.y1 });
    check("T2 …and the first update PAST the slop promotes: a band appears",
          past.bandRect !== null && past.count === 2,
          `band=${JSON.stringify(past.bandRect)} count=${past.count}`);
    await mq({ act: "end", x: band.x1, y: band.y1 });
  }

  // ══ S  SHRINK GIVES BACK ═════════════════════════════════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    const wide = bandOn(RH, PPB, 1.5, 5.5, 72, 62);        // all four rows, beats 1.5-5.5
    const wantWide = expectHits(RH, PPB, wide, NOTES);
    check("S0 fixture: the wide band is computed to take THREE notes",
          same(wantWide, sortIds([N1, N2, N3])), `want=${short(wantWide)}`);
    await clearNotes(RH, PPB);
    await mq({ act: "begin", x: wide.x0, y: wide.y0 });
    const grown = await mq({ act: "changed", x: wide.x1, y: wide.y1 });
    // Shrink to beats [1.5, 3.5] × the same rows: only N1 survives.
    const narrowX = 3.5 * PPB;
    const narrow = await mq({ act: "changed", x: narrowX, y: wide.y1 });
    const end = await mq({ act: "end", x: narrowX, y: wide.y1 });
    check("S1 a SHRINKING band gives notes back (it re-decides from the frozen base)",
          grown.count === 3 && same(sortIds(narrow.selectedIds), [N1])
            && same(sortIds(end.selectedIds), [N1]),
          `grown=${grown.count} narrow=${short(sortIds(narrow.selectedIds))}`);
  }

  // ══ A  THE CHORD: ADDITIVE BANDS ═════════════════════════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    const band = bandOn(RH, PPB, 1.5, 5.5, 64, 62);
    const want = expectHits(RH, PPB, band, NOTES);
    // Seed a base by banding N3 alone (its own row, its own beat).
    const seedBand = bandOn(RH, PPB, 3.5, 5.5, 72, 72);
    await sweep(seedBand);
    const base = await mq({});
    check("A0 fixture: a single-note base exists to union onto (non-vacuity)",
          same(sortIds(base.selectedIds), [N3]), `base=${short(sortIds(base.selectedIds))}`);

    const shifted = await sweep(band, { shift: true });
    check("A1 a SHIFT band UNIONS onto the pre-drag selection",
          same(sortIds(shifted.end.selectedIds), sortIds([N3, ...want])),
          `got=${short(sortIds(shifted.end.selectedIds))}`);
    check("A2 hitIds stays DISTINCT from selectedIds under the chord — the union is observable",
          same(sortIds(shifted.end.hitIds), want) && shifted.end.count === want.length + 1,
          `hits=${shifted.end.hitIds.length} selected=${shifted.end.count}`);

    // ⌘ means the same thing as shift — ONE chord table (ArrangeClickIntent).
    await sweep(seedBand);
    const commanded = await sweep(band, { command: true });
    check("A3 a ⌘ band unions too — shift and ⌘ route through the ONE chord mapping",
          same(sortIds(commanded.end.selectedIds), sortIds([N3, ...want])),
          `got=${short(sortIds(commanded.end.selectedIds))}`);

    await sweep(seedBand);
    const plain = await sweep(band);
    check("A4 the same band WITHOUT a chord REPLACES — the base is dropped",
          same(sortIds(plain.end.selectedIds), want) && !plain.end.selectedIds.includes(N3),
          `got=${short(sortIds(plain.end.selectedIds))}`);
  }

  // ══ D  THE DEGENERATE PRESS STILL CLEARS ═════════════════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    await sweep(bandOn(RH, PPB, 1.5, 5.5, 64, 62));
    const before = await mq({});
    check("D0 fixture: something IS selected, so a clear is observable (non-vacuity)",
          before.count === 2, `count=${before.count}`);
    // An empty-grid point: beat 7, pitch 50's row — no note anywhere near it.
    const x = 7 * PPB, y = (127 - 50) * RH + RH / 2;
    const begin = await mq({ act: "begin", x, y });
    const end = await mq({ act: "end", x, y });
    check("D1 a press that never travelled draws NO band at any point",
          begin.bandRect === null && end.bandRect === null,
          `begin=${begin.bandRect} end=${end.bandRect}`);
    check("D2 …and CLEARS the selection — click-to-deselect survives byte-identically",
          end.count === 0 && end.hasSelection === false,
          `count=${end.count} hasSelection=${end.hasSelection} `
          + "(a sub-slop press stays a click; this is the shipped rule, not a bug)");
  }

  // ══ C  THE ⌘ CHORD TABLE — three shipped-behaviour changes (m23-ek-1 D5) ══
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    // A point squarely inside N1 (pitch 62 @ beat 2) and inside N2.
    const onN1 = { x: 2.5 * PPB, y: (127 - 62) * RH + RH / 2 };
    const onN2 = { x: 4.5 * PPB, y: (127 - 64) * RH + RH / 2 };
    const emptyPt = { x: 7 * PPB, y: (127 - 50) * RH + RH / 2 };
    const clickAt = async (p, chord = {}) => {
      await mq({ act: "begin", x: p.x, y: p.y, ...chord });
      return mq({ act: "end", x: p.x, y: p.y, ...chord });
    };

    // Row 1 — ⌘-click on a note TOGGLES it (was: selects only it).
    await clearNotes(RH, PPB);
    await clickAt(onN1);                                   // plain click selects N1
    const seeded = await mq({});
    check("C0 fixture: a plain click on a note selects exactly it (unchanged behaviour)",
          same(sortIds(seeded.selectedIds), [N1]), `sel=${short(sortIds(seeded.selectedIds))}`);
    const added = await clickAt(onN2, { command: true });
    check("C1 ⌘-click on a note TOGGLES it into the selection (was: replaced it)",
          same(sortIds(added.selectedIds), sortIds([N1, N2])),
          `sel=${short(sortIds(added.selectedIds))}`);
    const removed = await clickAt(onN2, { command: true });
    check("C2 ⌘-click again TOGGLES it back OUT",
          same(sortIds(removed.selectedIds), [N1]),
          `sel=${short(sortIds(removed.selectedIds))}`);

    // Row 3 — ⌘-click on EMPTY grid leaves the selection alone (was: cleared).
    const kept = await clickAt(emptyPt, { command: true });
    check("C3 ⌘-click on empty grid LEAVES the selection alone (was: cleared)",
          same(sortIds(kept.selectedIds), [N1]), `sel=${short(sortIds(kept.selectedIds))}`);
    // …and the same point WITHOUT the chord still clears — the control half.
    const cleared = await clickAt(emptyPt);
    check("C4 CONTROL: the same empty-grid click without a chord still clears",
          cleared.count === 0, `count=${cleared.count}`);

    // Row 2 — ⌘-press on a note + DRAG toggles on release instead of moving.
    // The note must not have moved: read the store, not the selection.
    await clearNotes(RH, PPB);
    await clickAt(onN1);
    await mq({ act: "begin", x: onN1.x, y: onN1.y, command: true });
    await mq({ act: "changed", x: onN1.x + 3 * PPB, y: onN1.y, command: true });
    const dragged = await mq({ act: "end", x: onN1.x + 3 * PPB, y: onN1.y, command: true });
    const after = await req("project.snapshot", {});
    const n1After = ((after.project?.tracks ?? after.tracks ?? [])
      .find((t) => t.id === trackId)?.clips ?? [])
      .find((c) => c.id === clipId)?.notes?.find((n) => n.id === N1);
    check("C5 ⌘-press on a note + drag TOGGLES it and does NOT move it",
          near(n1After?.startBeat, 2) && !dragged.selectedIds.includes(N1),
          `startBeat=${n1After?.startBeat} (must stay 2) selected=${short(sortIds(dragged.selectedIds))}`);

    // C6 — THE CONTROL, MEASURED. Without this leg C5's negative could hold for
    // the wrong reason entirely: if the seam were unable to move a note AT ALL,
    // "it did not move" would pass against any implementation. So run the
    // IDENTICAL drag with no chord and require that it DOES move.
    const startOf = async (id) => {
      const s = await req("project.snapshot", {});
      return ((s.project?.tracks ?? s.tracks ?? []).find((t) => t.id === trackId)?.clips ?? [])
        .find((c) => c.id === clipId)?.notes?.find((n) => n.id === id)?.startBeat;
    };
    await clearNotes(RH, PPB);
    await mq({ act: "begin", x: onN1.x, y: onN1.y });
    await mq({ act: "changed", x: onN1.x + 3 * PPB, y: onN1.y });
    await mq({ act: "end", x: onN1.x + 3 * PPB, y: onN1.y });
    const movedTo = await startOf(N1);
    check("C6 CONTROL (MEASURED): the SAME drag without ⌘ really does move the note",
          near(movedTo, 5),
          `startBeat=${movedTo} (want 5 = 2 + 3); travel=${3 * PPB} pt vs slop 4 pt`);
    // Put it back — every later leg's band geometry assumes N1 at beat 2.
    await mq({ act: "begin", x: onN1.x + 3 * PPB, y: onN1.y });
    await mq({ act: "changed", x: onN1.x, y: onN1.y });
    await mq({ act: "end", x: onN1.x, y: onN1.y });
    const restored = await startOf(N1);
    check("C7 the fixture is restored (and a LEFTWARD drag moves symmetrically)",
          near(restored, 2), `startBeat=${restored} (want 2)`);
    await clearNotes(RH, PPB);
  }

  // ══ Z  ZOOM INVARIANCE ═══════════════════════════════════════════════════
  {
    const before = await mq({});
    const layout = await req("debug.panelLayout", { pianoRollPPB: before.ppb * 2 });
    await sleep(SETTLE_MS);
    const zoomed = await mq({});
    check("Z0 fixture: the roll really is at a DIFFERENT zoom now (the leg is not vacuous)",
          zoomed.ppb > before.ppb * 1.5 && zoomed.rowHeight === before.rowHeight,
          `ppb ${before.ppb} -> ${zoomed.ppb} (layout echoed ${layout.pianoRollPPB})`);
    const band = bandOn(zoomed.rowHeight, zoomed.ppb, 1.5, 5.5, 64, 62);
    const want = expectHits(zoomed.rowHeight, zoomed.ppb, band, NOTES);
    await clearNotes(zoomed.rowHeight, zoomed.ppb);
    const r = await sweep(band);
    check("Z1 the same MUSICAL band selects the same notes at a different zoom",
          same(sortIds(r.end.selectedIds), want) && same(want, sortIds([N1, N2])),
          `got=${short(sortIds(r.end.selectedIds))} ppb=${zoomed.ppb}`);
    check("Z2 VALIDITY: the OLD ppb's points would have addressed a different musical region",
          !near(band.x0, 1.5 * before.ppb),
          `x0 now ${band.x0}, would have been ${1.5 * before.ppb}`);
    await req("debug.panelLayout", { pianoRollPPB: before.ppb });
    await sleep(SETTLE_MS);
  }

  // ══ R  THE REGRESSIONS THIS CHANGE ACTUALLY THREATENS ════════════════════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    // R1 — m18-i: an external mutation mid-band must leave NO ghost band.
    const band = bandOn(RH, PPB, 1.5, 5.5, 64, 62);
    await clearNotes(RH, PPB);
    await mq({ act: "begin", x: band.x0, y: band.y0 });
    const live = await mq({ act: "changed", x: band.x1, y: band.y1 });
    check("R0 fixture: a band really is standing before the mutation lands",
          live.bandRect !== null, `band=${JSON.stringify(live.bandRect)}`);
    await req("clip.trim", { trackId, clipId, newStartBeat: 0, newLengthBeats: 6 });
    await sleep(SETTLE_MS);
    const reseeded = await mq({});
    check("R1 an external mutation mid-band leaves NO ghost band on screen",
          reseeded.bandRect === null && near(reseeded.clipLengthBeats, 6),
          `band=${reseeded.bandRect} clipLength=${reseeded.clipLengthBeats}`);
    await mq({ act: "end", x: band.x1, y: band.y1 });

    // R2 — m23-al R1: a staged press ENGAGES the roll, exactly as a mouse press
    // does. If promotion had bypassed `beginGesture`, this would go quiet.
    // Aimed AWAY first, so the leg has somewhere to move FROM (a surface that
    // was already `pianoRoll` would pass without the press doing anything).
    await sel({ act: "engage", surface: "arrange" });
    const engagedBefore = await sel({});
    check("R2a fixture: the ARRANGE holds the surface, so an engagement is observable",
          engagedBefore.activeEditorSurface === "arrange",
          `surface=${engagedBefore.activeEditorSurface}`);
    await mq({ act: "begin", x: band.x0, y: band.y0 });
    await mq({ act: "changed", x: band.x1, y: band.y1 });
    await mq({ act: "end", x: band.x1, y: band.y1 });
    const engaged = await sel({});
    check("R2b a staged band ENGAGES the roll (m23-al R1 survives promotion)",
          engaged.activeEditorSurface === "pianoRoll",
          `surface=${engaged.activeEditorSurface} (was ${engagedBefore.activeEditorSurface})`);
  }

  // ══ U  AN UNBALANCED STAGED GESTURE IS AN ERROR, NOT A WRONG ANSWER ══════
  {
    const { rowHeight: RH, ppb: PPB } = await mq({});
    const p0 = { x: 7 * PPB, y: (127 - 50) * RH + RH / 2 };
    await mq({ act: "begin", x: p0.x, y: p0.y });
    const open = await mq({});
    check("U0 fixture: the echo REPORTS the open gesture (gestureInFlight went true)",
          open.gestureInFlight === true, `gestureInFlight=${open.gestureInFlight}`);
    let threw = null;
    try { await mq({ act: "begin", x: p0.x + 200, y: p0.y }); }
    catch (e) { threw = String(e.message); }
    check("U1 a second begin while a gesture is open THROWS instead of answering plausibly",
          threw !== null && /in flight/.test(threw),
          `error=${threw ? threw.slice(0, 90) : "none — the seam accepted it"}`);
    await mq({ act: "end", x: p0.x, y: p0.y });
    const closed = await mq({});
    check("U2 the release clears it, so the seam is usable again (no latch)",
          closed.gestureInFlight === false, `gestureInFlight=${closed.gestureInFlight}`);
    const reused = await mq({ act: "begin", x: p0.x, y: p0.y });
    check("U3 CONTROL: a begin after a balanced gesture is accepted (U1 was not a blanket refusal)",
          reused.gestureInFlight === true, `gestureInFlight=${reused.gestureInFlight}`);
    await mq({ act: "end", x: p0.x, y: p0.y });
  }

  // ══ G  ek-1 AND ek-2 COMPOSE: band-select many, then drag them as ONE ═════
  //
  // The reason the pair exists. Every other ek-2 assertion in this repo is
  // headless; this is the only place the two halves are observed working
  // TOGETHER through the live handlers.
  //
  // ⚠️ ITS OWN CLIP, with notes at DIFFERENT SUB-GRID PHASES (0.3 and 1.7).
  // That is the whole discriminator: notes whose bases share a phase snap
  // identically under the old per-note rule and the new rigid one, so the
  // 4-note fixture above (all on integer beats) could not tell them apart.
  // 0.3 and 1.7 sit at different offsets from ANY grid, so the old rule
  // welds them and the gap changes.
  {
    const clip2 = (await req("clip.addMIDI", {
      trackId, atBeat: 16, lengthBeats: 8,
      notes: [
        { pitch: 60, startBeat: 0.3, lengthBeats: 1, velocity: 100 },
        { pitch: 61, startBeat: 1.7, lengthBeats: 1, velocity: 100 },
      ],
    })).id;
    await sel({ act: "click", clipId: clip2 });
    await sleep(SETTLE_MS);
    const notesOf = async () => {
      const s = await req("project.snapshot", {});
      return ((s.project?.tracks ?? s.tracks ?? []).find((t) => t.id === trackId)?.clips ?? [])
        .find((c) => c.id === clip2)?.notes ?? [];
    };
    const before = await notesOf();
    const A = before.find((n) => n.pitch === 60), B = before.find((n) => n.pitch === 61);
    const { rowHeight: RH, ppb: PPB, noteCount } = await mq({});
    check("G0 fixture: the second clip is open with two OFF-GRID notes at different phases",
          noteCount === 2 && near(A?.startBeat, 0.3) && near(B?.startBeat, 1.7),
          `noteCount=${noteCount} A=${A?.startBeat} B=${B?.startBeat} ppb=${PPB}`);
    const gapBefore = B.startBeat - A.startBeat;

    // ① BAND-SELECT both (ek-1) — beats 0..3, rows 61..60.
    const band = bandOn(RH, PPB, 0, 3, 61, 60);
    const banded = await sweep(band);
    check("G1 one band selects BOTH notes (ek-1 through the live handlers)",
          banded.end.count === 2
            && same(sortIds(banded.end.selectedIds), sortIds([A.id, B.id])),
          `count=${banded.end.count} sel=${short(sortIds(banded.end.selectedIds))}`);

    // ② DRAG the selection by one gesture, grabbing A (ek-2).
    const onA = { x: (A.startBeat + 0.5) * PPB, y: (127 - 60) * RH + RH / 2 };
    await mq({ act: "begin", x: onA.x, y: onA.y });
    await mq({ act: "changed", x: onA.x + PPB, y: onA.y });
    const held = await mq({});
    check("G2 the press KEPT the band's selection — it did not collapse to the grabbed note",
          held.count === 2, `count=${held.count} (a press on an already-selected note)`);
    await mq({ act: "end", x: onA.x + PPB, y: onA.y });
    const after = await notesOf();
    const A2 = after.find((n) => n.id === A.id), B2 = after.find((n) => n.id === B.id);

    check("G3 BOTH notes moved — the drag carried the whole band-selected group",
          A2.startBeat > A.startBeat && B2.startBeat > B.startBeat,
          `A ${A.startBeat}→${A2.startBeat}  B ${B.startBeat}→${B2.startBeat}`);
    check("G4 m23-ek-2: the GAP is preserved exactly — the group translated RIGIDLY",
          near(B2.startBeat - A2.startBeat, gapBefore),
          `gap ${gapBefore} → ${B2.startBeat - A2.startBeat} `
          + `(the old per-note rule snaps each base separately and welds them)`);
    check("G5 ANTI-VACUITY: snapping was ACTIVE, so G4 is a real constraint",
          !near(A2.startBeat, A.startBeat + 1),
          `anchor landed on ${A2.startBeat}, NOT base+raw (${A.startBeat + 1}) — it snapped. `
          + `If this ever goes red, snap is off and G4 passed for free.`);
    check("G6 pitches are untouched by a horizontal group drag",
          A2.pitch === 60 && B2.pitch === 61, `pitches=${A2.pitch},${B2.pitch}`);
    // Leave the arrange on the original clip so nothing downstream is surprised.
    await sel({ act: "click", clipId });
    await sleep(SETTLE_MS);
  }

  // ══ what this gate structurally cannot reach ═════════════════════════════
  skip("row-height invariance",
       "`PianoRollModel.rowHeight` has no staging seam — it is not a PanelLayoutStore slot, "
       + "so a second row height cannot be driven from the wire. Every y above is still "
       + "DERIVED from the echoed rowHeight, which is the law the leg would have pinned; "
       + "the headless `bandFollowsRowHeight` test covers the geometry at 40 pt/row.");
  skip("the scrub strip does not steal a band",
       "the scrub strip is a separate overlay with its own DragGesture; this seam drives "
       + "`PianoRollView`'s grid handlers directly and never goes through AppKit hit "
       + "testing, so a leg here could only pass vacuously. Unchanged by this item: the "
       + "band is a promotion INSIDE gridDrag, and the strip's gesture was not touched.");
  skip("double-tap-to-add still creates a note",
       "the roll's `SpatialTapGesture(count: 2)` has no staging seam of its own. The "
       + "argument it is safe is structural rather than measured: a double-tap carries no "
       + "travel, so it can never cross `PianoRollMarquee.dragSlop`, and the site pin "
       + "`rollGestureCountIsPinned` proves no gesture was added or removed.");

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
