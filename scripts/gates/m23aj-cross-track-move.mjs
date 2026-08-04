// m23-aj GATE — the CROSS-TRACK clip move, end to end against a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is killed PIDFILE-EXACT via `_staging.mjs`, never pkill/pgrep).
//
// It builds and launches its OWN binary, so the thing under test has KNOWN
// provenance (m23-ac): a gate that drives whatever instance happens to be on the
// port can pass against code that is days old and cannot tell you that it did.
//
//   node scripts/gates/m23aj-cross-track-move.mjs
//
// ═══ WHAT THIS GATE OWNS, AND WHAT IT DELIBERATELY DOES NOT ═══════════════════
//
// m23-aj shipped in three parts and each has its own proof surface. This file is
// the one that reaches the parts NOTHING ELSE CAN:
//
//   • the DOMAIN verb (m23-aj-1) is proven by Tests/DAWCoreTests/
//     ClipCrossTrackMoveTests.swift, in-process against a real store;
//   • the WIRE (m23-aj-2) is proven by Tests/DAWControlTests/
//     ClipCrossTrackMoveCommandTests.swift and, live, by
//     scripts/gates/m23aj2-move-wire.mjs (17 legs) — which already pins the
//     response SHAPES, the `rejectUnknownKeys` behaviour, the `.toTrack` key
//     omission, and the manufactured-collision message BYTE-EXACTLY;
//   • the KEYBOARD LAYER (m23-aj-3) is proven ONLY here. `DAWApp` has no test
//     target, so `AppModel.handleArrangeNudgeKey`'s six guards, the
//     `ArrangeNudgeAxisKey` routing, the vertical CONSUME rule and the debug
//     seam are unreachable from `Tests/`. A green Swift suite must not be read
//     as covering them.
//
// So the wire legs below (A, B, C, I, J, K, L) do NOT re-assert what
// m23aj2-move-wire.mjs already asserts. Each one carries the half that gate does
// not: undo DEPTH, `project.snapshot` BYTE-IDENTITY, and resident-geometry
// EQUALITY against the same-track path. Where a leg is a strictly weaker twin of
// an aj-2 leg it says so and cites it rather than duplicating it.
//
// ═══ THE FIXTURE, STATED SO NOBODY INVENTS A DIFFERENT ONE ═══════════════════
//
//   [inst A, inst B, inst C, bus D, audio E]   — indices 0..4, in that order
//
// It is the same shape as the DAWCore suite's and the aj-2 gate's, and the shape
// is load-bearing:
//   • THREE consecutive instrument tracks give a two-track group room to move
//     down ONE lane and land legally (leg A). ⚠️ The obvious `inst, inst, bus`
//     layout makes leg A's group land ON the bus, so the headline leg reddens
//     for entirely the wrong reason and the gate looks like it is working.
//   • the bus at index 3 is what leg B refuses on;
//   • the audio track at index 4 is what leg G's `.store` refusal uses.
// Track ORDER is a fixture FACT here, not incidental setup, so leg F0 asserts it
// after construction instead of trusting `track.add` ordering.
//
// Two legs build their OWN fixture and say why: leg F needs SIX instrument
// tracks (five ↓ presses from track 0 would otherwise hit the bus partway and
// redden for the wrong reason — the same trap as above, on the other axis), and
// leg H needs a muted two-track playback rig.
//
// ═══ THE MUTATION TABLE (design §13 + §18.8) ═════════════════════════════════
//
// Every mutation must redden a NAMED leg: a leg that stays green under its own
// mutation measures nothing. Sites are given so the next reader can reproduce
// them without re-deriving where the code lives.
//
//   M1  delete the phase-2b kind check (`guard tracks[dt].canHold(...)`)   → B
//   M2  make the vertical clamp THROW instead of reducing                  → D
//   M3  call `resolveOverlap` directly instead of `resolvingGroupOverlaps` → C
//   M4  phase 3 per-track (remove-then-add) instead of vacate-all/land-all → A
//   M5  give the vertical move its own coalescing key                      → F
//   M6  return `.ignored` for the vertical `.store` refusal                → G2
//   M7  relax the 2b' interval test to `<=`                                → K
//   M8  drop the same-source grandfather (`sources[i] != sources[j]`)      → (none here — see below)
//   M9  filter the 2b' check to CROSSING movers                            → L
//
// ⚠️ M8 HAS NO GATE TARGET ON PURPOSE, and saying so is better than leaving it
// looking unpaired. It reddens the two GRANDFATHER legs in
// ClipCrossTrackMoveTests.swift, which build a sanctioned audio CROSSFADE pair —
// two overlapping audio clips on one track. That fixture is UNBUILDABLE from the
// wire: `clip.addMIDI` / the import path route through `resolvingOverlaps`, so
// two overlapping ordinary clips cannot be created over the control protocol at
// all (the m23-g1 law). It is domain geometry the Swift suite can build directly
// and this gate cannot.
//
// ═══ RED BASELINE ════════════════════════════════════════════════════════════
//
// Recorded as a SET of named legs, never a count (m20-e: a race makes totals a
// range, the set is stable). See the close-out record for the measured sets.
import { launchStaging, stopStaging, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23aj";
const SETTLE_MS = 250;
// `UndoJournal.coalescingWindow` is 800 ms and `moveClipsKey(ids:)` does not
// distinguish keyboard from wire, so two logically separate moves of the SAME
// selection inside it fold into ONE entry. Correct behaviour, and a trap for a
// gate that then counts entries: anywhere this gate wants two countable entries
// it waits this out. Asserted deliberately at F, never discovered as a failure.
const COALESCE_MS = 900;

let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
const observations = [];
const skips = [];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `aj-${++seq}`;
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
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}
/** Leg H's channel. PRINTS, never scores — see the leg's own banner. */
function obs(label, text) {
  observations.push({ label, text });
  console.log(`OBSERVE ${label} :: ${text}`);
}
function skip(label, why) {
  skips.push({ label, why });
  console.log(`SKIP ${label} :: ${why}`);
}

const near = (a, b, eps = 1e-9) => typeof a === "number" && Math.abs(a - b) < eps;
const histLen = async () => (await cmd("edit.history")).result?.undo?.length ?? -1;
const overview = async () => (await cmd("project.overview")).result ?? {};
/**
 * Deep key-sort. ⚠️ MEASURED, NOT DEFENSIVE: `project.snapshot` returns the same
 * project with a DIFFERENT JSON key ORDER on two consecutive reads (leg B0 caught
 * it — two 2798-byte strings that were not equal). Swift dictionaries have no
 * ordering guarantee and the encoder does not impose one, so a raw
 * `JSON.stringify` comparison reports "the project changed" for every refusal
 * leg. Canonicalising is the ONE place this is handled; B0 stays in as the
 * regression guard that it is still handled.
 */
const canon = (v) => {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === "object") {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = canon(v[k]);
    return out;
  }
  return v;
};
/** The WHOLE project, canonically stringified — B/J/L's no-partial-mutation probe. */
const snapshot = async () =>
  JSON.stringify(canon((await cmd("project.snapshot")).result ?? null));
const mk = async (trackId, name, atBeat, lengthBeats = 4, notes) =>
  (await cmd("clip.addMIDI", { trackId, name, atBeat, lengthBeats, ...(notes ? { notes } : {}) }))
    .result?.id;
const sel = async (p = {}) => (await cmd("debug.arrangeSelection", p)).result ?? {};
const nudge = (p) => sel({ act: "nudge", ...p });

/** Every clip in the project, id -> {clip, trackId, trackIndex}. From the STORE. */
async function clipIndex() {
  const ov = await overview();
  const map = new Map();
  (ov.tracks ?? []).forEach((t, i) => {
    for (const c of t.clips ?? []) map.set(c.id, { clip: c, trackId: t.id, trackIndex: i });
  });
  return map;
}
/** Selects `ids` as a group through the SAME click path a mouse would use. */
async function selectClips(ids) {
  await sel({ act: "clear" });
  for (const [i, id] of ids.entries()) {
    await sel({ act: "click", clipId: id, ...(i === 0 ? {} : { shift: true }) });
  }
}

async function buildFixture() {
  await cmd("project.new", { discardChanges: true });
  const a = (await cmd("track.add", { name: "A", kind: "instrument" })).result?.id;
  const b = (await cmd("track.add", { name: "B", kind: "instrument" })).result?.id;
  const c = (await cmd("track.add", { name: "C", kind: "instrument" })).result?.id;
  const d = (await cmd("track.add", { name: "D", kind: "bus" })).result?.id;
  const e = (await cmd("track.add", { name: "E", kind: "audio" })).result?.id;
  return { a, b, c, d, e };
}

try {
  const staging = await launchStaging({ gate: GATE });
  ws = staging.ws;
  console.log(`connected to staging on ${STAGING_PORT} (pid ${staging.pid})`);
  await cmd("debug.windowFrame", { width: 1400, height: 1000 });

  // ═══ F0  THE FIXTURE IS WHAT THIS GATE THINKS IT IS ═══════════════════════
  {
    const t = await buildFixture();
    const ov = await overview();
    const order = (ov.tracks ?? []).map((x) => `${x.name}:${x.kind}`);
    ck("F0 fixture order is [inst A, inst B, inst C, bus D, audio E] — ASSERTED, not assumed",
       JSON.stringify(order) === JSON.stringify(
         ["A:instrument", "B:instrument", "C:instrument", "D:bus", "E:audio"]),
       JSON.stringify(order));
    ck("F0b the five ids came back distinct (a failed track.add would make every "
       + "later leg reason about the wrong track)",
       new Set([t.a, t.b, t.c, t.d, t.e]).size === 5 && t.a && t.e,
       JSON.stringify(t));
  }

  // ═══ A  THE HEADLINE: a 2-track group moves down ONE lane, rigidly ════════
  // The geometry is chosen to make M4 (per-track remove-then-add instead of
  // vacate-all-then-land-all) VISIBLE: X's landing window [0,4) on track B
  // OVERLAPS Y, which is still sitting on B at [2,6) when the move starts. Under
  // vacate-all Y has already left and X lands clean; under remove-then-add the
  // resolver trims Y on its way past. With the DISJOINT geometry the aj-2 gate
  // uses (0 and 4) both orderings agree and the leg would measure nothing.
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);   // A, [0,4)
    const y = await mk(t.b, "Y", 2);   // B, [2,6) — deliberately in X's landing window
    await sleep(COALESCE_MS);
    const before = await histLen();
    const r = await cmd("clip.moveManyByTracks", { ids: [x, y], byTracks: 1 });
    const res = r.result ?? {};
    ck("A1 ok", r.ok, JSON.stringify(r).slice(0, 240));
    const idx = await clipIndex();
    ck("A2 the group landed one lane down: X on B, Y on C (relative TRACK offset of 1 intact)",
       idx.get(x)?.trackId === t.b && idx.get(y)?.trackId === t.c,
       `X on ${idx.get(x)?.trackIndex} Y on ${idx.get(y)?.trackIndex}`);
    ck("A3 relative BEAT offset intact (0 and 2) and neither clip was shortened",
       near(idx.get(x)?.clip.startBeat, 0) && near(idx.get(y)?.clip.startBeat, 2)
         && near(idx.get(x)?.clip.lengthBeats, 4) && near(idx.get(y)?.clip.lengthBeats, 4),
       `X=${idx.get(x)?.clip.startBeat}/${idx.get(x)?.clip.lengthBeats} `
       + `Y=${idx.get(y)?.clip.startBeat}/${idx.get(y)?.clip.lengthBeats}`);
    ck("A4 THE MOVERS DID NOT TRIM EACH OTHER even though track B was vacated and "
       + "landed on in the SAME move — nothing trimmed, nothing removed",
       (res.trimmedClipIDs ?? []).length === 0 && (res.removedClipIDs ?? []).length === 0,
       `trimmed=${JSON.stringify(res.trimmedClipIDs)} removed=${JSON.stringify(res.removedClipIDs)}`);
    ck("A5 a 2-clip cross-track move is ONE journal entry — not a loop of single moves",
       (await histLen()) - before === 1, `depth +${(await histLen()) - before}`);
  }

  // ═══ B  A LANDING ON A BUS REFUSES, AND NOTHING AT ALL CHANGED ════════════
  // m23aj2 L9 already proves the refusal and that the clip stayed put. THIS leg
  // adds the half it cannot: the WHOLE PROJECT is byte-identical afterwards, so
  // no partial mutation happened anywhere — not to another track, not to the
  // journal, not to a field the overview does not print.
  {
    const t = await buildFixture();
    const m = await mk(t.c, "M", 0);   // C is index 2; +1 lands on the bus at 3
    await sleep(SETTLE_MS);
    const s0 = await snapshot();
    const s0b = await snapshot();
    ck("B0 project.snapshot is BYTE-STABLE across two reads with no edit between "
       + "(without this, B3 proves nothing)", s0 === s0b,
       `len ${s0.length} vs ${s0b.length}`);
    const before = await histLen();
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: 1 });
    ck("B1 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("B2 the error names the reason ('cannot hold')", /cannot hold/.test(r.error ?? ""),
       r.error ?? "");
    ck("B3 project.snapshot BYTE-IDENTICAL before/after — the refusal is ALL-OR-NOTHING",
       (await snapshot()) === s0, "snapshot changed");
    ck("B4 no undo step was pushed by the refusal",
       (await histLen()) === before, `${before} -> ${await histLen()}`);
  }

  // ═══ C  THE SAME OVERLAP PATH, NOT A SECOND IMPLEMENTATION ════════════════
  // Build IDENTICAL geometry twice — once resolved by `clip.move` (same track),
  // once by `clip.moveManyByTracks` (landing from another track) — and assert the
  // RESIDENT comes out the same. Asserting the trim rule twice would be weaker:
  // this asserts the two PATHS agree, which is the property that survives a
  // future change to the rule.
  //
  // Both halves use a fresh fixture rather than sharing one, so the second
  // mover's `clip.addMIDI` cannot land on the first half's leftovers and be
  // silently trimmed on the way in.
  {
    // Half 1 — SAME TRACK. Resident R [0,4) on A; mover M [8,12) moved to 2.
    const t1 = await buildFixture();
    const r1 = await mk(t1.a, "R", 0);
    const m1 = await mk(t1.a, "M", 8);
    await sleep(SETTLE_MS);
    const mv = await cmd("clip.move", { trackId: t1.a, clipId: m1, toStartBeat: 2 });
    const idx1 = await clipIndex();
    const snap1 = JSON.parse(await snapshot());

    // Half 2 — CROSS TRACK. Resident R [0,4) on B; mover M [2,6) on A, byTracks 1.
    const t2 = await buildFixture();
    const r2 = await mk(t2.b, "R", 0);
    const m2 = await mk(t2.a, "M", 2);
    await sleep(SETTLE_MS);
    const mm = await cmd("clip.moveManyByTracks", { ids: [m2], byTracks: 1 });
    const idx2 = await clipIndex();
    const snap2 = JSON.parse(await snapshot());

    ck("C0 both halves ran (a refused call would make the comparison vacuous)",
       mv.ok === true && mm.ok === true,
       `same-track=${JSON.stringify(mv.error)} cross-track=${JSON.stringify(mm.error)}`);
    ck("C1 the RESIDENT's start and length are identical through both paths",
       near(idx1.get(r1)?.clip.startBeat, idx2.get(r2)?.clip.startBeat)
         && near(idx1.get(r1)?.clip.lengthBeats, idx2.get(r2)?.clip.lengthBeats),
       `same-track=${idx1.get(r1)?.clip.startBeat}/${idx1.get(r1)?.clip.lengthBeats} `
       + `cross-track=${idx2.get(r2)?.clip.startBeat}/${idx2.get(r2)?.clip.lengthBeats}`);
    ck("C1b ...and it really WAS trimmed (0 -> length 2), so C1 is not comparing two "
       + "untouched clips",
       near(idx2.get(r2)?.clip.lengthBeats, 2) && near(idx2.get(r2)?.clip.startBeat, 0),
       `${idx2.get(r2)?.clip.startBeat}/${idx2.get(r2)?.clip.lengthBeats}`);
    // The FULL persisted clip, not just the two numbers the overview prints:
    // startOffsetSeconds, fades and their curves, gain envelope, notes, stretch.
    // Only `id` may differ, so only `id` is stripped.
    const strip = (o) => {
      const { id, ...rest } = o ?? {};
      return JSON.stringify(canon(rest));   // key order is not information — see `canon`
    };
    const findClip = (snap, id) => {
      for (const tr of snap?.tracks ?? []) {
        const c = (tr.clips ?? []).find((x) => x.id === id);
        if (c) return c;
      }
      return null;
    };
    ck("C2 the resident's WHOLE persisted geometry is identical (every field the "
       + "snapshot carries, id excluded), not merely its start and length",
       strip(findClip(snap1, r1)) === strip(findClip(snap2, r2)),
       `same-track=${strip(findClip(snap1, r1))}\ncross-track=${strip(findClip(snap2, r2))}`);
    ck("C3 both paths REPORT the resident the same way: each names it once as trimmed, "
       + "neither removes anything (the report is part of the path, not decoration)",
       JSON.stringify(mv.result?.trimmed) === JSON.stringify([r1])
         && JSON.stringify(mm.result?.trimmedClipIDs) === JSON.stringify([r2])
         && (mv.result?.removed ?? []).length === 0
         && (mm.result?.removedClipIDs ?? []).length === 0,
       `same-track trimmed=${JSON.stringify(mv.result?.trimmed)} `
       + `cross-track trimmed=${JSON.stringify(mm.result?.trimmedClipIDs)}`);
  }

  // ═══ D  THE KEYBOARD'S TOP CLAMP ═══════════════════════════════════════════
  // Deliberately the KEYBOARD surface, not the wire one: m23aj2 L2 already pins
  // the wire clamp (`byTracks: -5` -> effective 0). What is new here is that the
  // ↑ key reaches it at all, that the seam echoes the vertical triple, and that a
  // fully-clamped press consumes no undo slot.
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 0);
    await selectClips([m]);
    await sleep(COALESCE_MS);
    const before = await histLen();
    const n = await nudge({ direction: "up" });
    ck("D1 the ↑ key produced a vertical step of exactly -1 (one lane, no coarse/fine)",
       n.trackStepDelta === -1, JSON.stringify(n.trackStepDelta));
    ck("D2 at the TOP of the track list the WHOLE-GROUP clamp reduced it to nothing",
       n.requestedTrackDelta === -1 && n.effectiveTrackDelta === 0 && n.clampedTracks === true,
       `requested=${n.requestedTrackDelta} effective=${n.effectiveTrackDelta} `
       + `clampedTracks=${n.clampedTracks}`);
    ck("D3 a fully-clamped press journals NOTHING — no undo entry for a no-op",
       (await histLen()) === before, `${before} -> ${await histLen()}`);
    const idx = await clipIndex();
    ck("D4 the clip is still on track A", idx.get(m)?.trackId === t.a,
       `trackIndex=${idx.get(m)?.trackIndex}`);
    // CONTROL: the same selection then moves DOWN, so D2/D3 measured the wall and
    // not a dead key.
    const n2 = await nudge({ direction: "down" });
    const idx2 = await clipIndex();
    ck("D5 CONTROL: the SAME selection then moves DOWN one lane — D2 measured the "
       + "wall, not a corpse",
       n2.effectiveTrackDelta === 1 && n2.clampedTracks === false
         && idx2.get(m)?.trackId === t.b,
       `effective=${n2.effectiveTrackDelta} trackIndex=${idx2.get(m)?.trackIndex}`);
    ck("D6 the landing is REPORTED, from track A to track B",
       (n2.landings ?? []).length === 1 && n2.landings[0].fromTrackId === t.a
         && n2.landings[0].toTrackId === t.b,
       JSON.stringify(n2.landings));
  }

  // ═══ E  THE SIX GUARDS ON THE VERTICAL AXIS, EACH A CONTROLLED PAIR ═══════
  // The whole point of `ArrangeNudgeAxisKey` is that ONE guard stack serves both
  // axes. That claim is only worth anything if every guard is observed refusing a
  // VERTICAL press — a duplicated stack that forgot one would look identical in
  // review. Idiom (m23-x N5): arm -> the SAME call must refuse, name itself, and
  // leave clips and journal untouched; disarm -> the SAME call must move. Without
  // the second half a handler that always returns false passes every one.
  {
    const t = await buildFixture();
    // ⚠️ THE NOTE IS FIXTURE, NOT DECORATION (measured on the first run of this
    // gate). `debug.arrangeSelection {act:"pianoRollNotes", select:true}` resolves
    // to the roll's own select-all, which selects NOTHING in an empty clip — so
    // with a noteless clip the fifth guard cannot arm, the refusal half reads
    // `refusedBy: null`, and the leg reddens for a fixture reason. Unlike the
    // automation act, this one does NOT throw on an unsatisfiable request, so the
    // FIXTURE assertion below is what turns that silence into a loud leg.
    const m = await mk(t.a, "M", 0, 4,
                       [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }]);
    await selectClips([m]);
    await sleep(SETTLE_MS);
    const trackOf = async () => (await clipIndex()).get(m)?.trackId;
    /**
     * Refuse-then-allow, then put the clip back where it started.
     *
     * `consumes` is the whole reason this is parameterised rather than copied:
     * FOUR guards fall through (`nudged: false`, so the key reaches whatever
     * wants it) and TWO consume (`nudged: true`, because the shielded surface
     * would have answered ↑/↓ itself). Both halves still assert `refusedBy`, and
     * both still assert nothing moved and nothing was journaled.
     */
    const pair = async (name, guard, arm, disarm, { consumes = false, fixture } = {}) => {
      const home = await trackOf();
      const d0 = await histLen();
      await arm();
      await sleep(SETTLE_MS);
      if (fixture) await fixture();
      const refused = await nudge({ direction: "down" });
      ck(`E-${name} GUARD: ↓ is refused and names itself (${consumes ? "CONSUMED" : "passed through"}); `
         + "nothing moved, nothing journaled",
         refused.nudged === consumes && refused.refusedBy === guard
           && (await trackOf()) === home && (await histLen()) === d0,
         `nudged=${refused.nudged} (want ${consumes}) by=${refused.refusedBy} `
         + `track=${(await trackOf()) === home ? "unmoved" : "MOVED"} depth=${d0}->${await histLen()}`);
      await disarm();
      await sleep(SETTLE_MS);
      const allowed = await nudge({ direction: "down" });
      const moved = (await trackOf()) !== home;
      ck(`E-${name} CONTROL: with the guard disarmed the SAME call moves one lane down`,
         allowed.nudged === true && allowed.effectiveTrackDelta === 1 && moved,
         `nudged=${allowed.nudged} effective=${allowed.effectiveTrackDelta} moved=${moved}`);
      // Back to the top lane so the next pair starts from a known place.
      await nudge({ direction: "up" });
    };

    await pair("workspace", "workspace",
               () => cmd("ui.showMixer", { show: true }),
               () => cmd("ui.showMixer", { show: false }));
    await pair("modal", "modal",
               () => cmd("debug.quantizePanel", { clipId: m }),
               () => cmd("debug.quantizePanel", { close: true }));

    // TEXT EDITING. `marker.add` is itself an undoable edit, so the marker is
    // created BEFORE the pair's own depth baseline is taken.
    await cmd("marker.add", { beat: 1, name: "RenameMe" });
    const markers = (await cmd("marker.list")).result ?? {};
    const markerId = (markers.markers ?? markers)[0]?.id;
    await sleep(SETTLE_MS);
    await pair("text-editing", "text-editing",
               () => cmd("debug.markerRename", { markerId }),
               () => cmd("debug.markerRename", { clear: true }));

    await pair("empty-selection", "empty-selection",
               () => sel({ act: "clear" }),
               () => selectClips([m]));

    // PIANO ROLL. Selecting the single MIDI clip opens the roll on it, so the
    // editor is up in BOTH halves and only the note selection moves — a
    // controlled pair on one variable (m23-x's finding: focus alone is true for
    // any single selected MIDI clip and is NOT a sufficient predicate).
    // CONSUMES the key, unchanged from m23-x: a roll holding a note selection
    // would answer ↑/↓ as transposition, more strongly than it answers ←/→.
    await pair("piano-roll-note-edit", "piano-roll-note-edit",
               () => sel({ act: "pianoRollNotes", select: true }),
               () => sel({ act: "pianoRollNotes", select: false }),
               { consumes: true,
                 fixture: async () => {
                   const e = await sel({});
                   ck("E-piano-roll-note-edit FIXTURE: the roll is open on the clip AND holds "
                      + "a note selection (else the refusal below is a fixture failure "
                      + "wearing a guard's clothes)",
                      e.editorClipId === m && e.pianoRollNoteSelection === true,
                      `editorClipId=${e.editorClipId} notes=${e.pianoRollNoteSelection}`);
                 } });
  }

  // ── E, continued: the SIXTH guard, on its own m23-ai-shaped fixture ────────
  // FRESH PROJECT, and the order below is the one m23-ai MEASURED to work:
  // add the lanes and their points FIRST, then `ui.showAutomation`, then click
  // the clip. Reached for after the first run of this gate could not arm a lane
  // on the shared fixture. The seam THROWS rather than silently no-op when it
  // cannot arm, so an unarmable fixture is recorded as a SKIP, never as a pass.
  {
    await cmd("project.new", { discardChanges: true });
    const ta = (await cmd("track.add", { kind: "instrument", name: "Lead" })).result?.id;
    const tb = (await cmd("track.add", { kind: "instrument", name: "Pad" })).result?.id;
    const clip = await mk(ta, "M", 8, 4,
                          [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }]);
    const points = [{ beat: 0, value: 0.5 }, { beat: 4, value: 0.8 }];
    for (const tr of [ta, tb]) {
      // ⚠️ `automation.addLane` WRAPS its model: the id is `result.lane.id`, NOT
      // `result.id` (m23-ai's `idOf` records the same trap). Reading `result.id`
      // yields undefined, `setPoints` then edits nothing, the lane has no
      // breakpoints, and the arm below fails with a message about a missing
      // EDITOR — pointing at the wrong half of the fixture entirely. Measured on
      // this gate's second run.
      const addLane = await cmd("automation.addLane",
                                { trackId: tr, target: { type: "volume" } });
      const lane = addLane.result?.lane?.id ?? addLane.result?.id;
      const set = await cmd("automation.setPoints", { trackId: tr, laneId: lane, points });
      if (!lane || set.error) {
        ck(`E-automation-point-edit FIXTURE: lane created and seeded on ${tr}`, false,
           `laneId=${JSON.stringify(lane)} setPoints=${JSON.stringify(set.error)}`);
      }
    }
    await cmd("ui.showAutomation", { trackId: ta });
    await sleep(SETTLE_MS);
    await selectClips([clip]);
    await sleep(SETTLE_MS);
    const trackOf = async () => (await clipIndex()).get(clip)?.trackId;
    const arm = await cmd("debug.arrangeSelection", { act: "automationPoints", select: true });
    if (arm.error) {
      skip("E-automation-point-edit",
           `could not ARM a breakpoint selection (${arm.error}) — a guard leg run against an `
           + "unarmed fixture is the m23-x failure class (9 of 46 red, every one a CONTROL "
           + "half), so this is recorded as unrun rather than as a pass");
    } else {
      const echo = await sel({});
      ck("E-automation-point-edit FIXTURE: exactly one mounted lane claims the key "
         + "(without this the refusal below could be any other guard)",
         echo.automationPointSelection === true && echo.automationPointLaneCount === 1,
         `claim=${echo.automationPointSelection} lanes=${echo.automationPointLaneCount}`);
      const home = await trackOf();
      const d0 = await histLen();
      const refused = await nudge({ direction: "down" });
      ck("E-automation-point-edit GUARD: ↓ with a live breakpoint selection is refused "
         + "and CONSUMED (an automation lane would answer ↑/↓ as value adjustment)",
         refused.nudged === true && refused.refusedBy === "automation-point-edit"
           && (await trackOf()) === home && (await histLen()) === d0,
         `nudged=${refused.nudged} by=${refused.refusedBy}`);
      await cmd("debug.arrangeSelection", { act: "automationPoints", select: false });
      await sleep(SETTLE_MS);
      await selectClips([clip]);
      const allowed = await nudge({ direction: "down" });
      ck("E-automation-point-edit CONTROL: with the breakpoint deselected the SAME call moves",
         allowed.nudged === true && allowed.effectiveTrackDelta === 1
           && (await trackOf()) !== home,
         `nudged=${allowed.nudged} effective=${allowed.effectiveTrackDelta}`);
    }
  }

  // ═══ F  KEY REPEAT FOLDS INTO ONE JOURNAL ENTRY ═══════════════════════════
  // LEG-LOCAL FIXTURE, and the reason is the same trap the shared fixture's
  // banner names: from track 0 of `[inst, inst, inst, bus, audio]` a THIRD ↓
  // lands on the bus and REFUSES, so a `repeat: 5` burst would redden this leg
  // for a reason that has nothing to do with coalescing. Six instrument tracks
  // give the burst room. (§18.8's grandfather leg sets the leg-local-fixture
  // precedent in the Swift suite.)
  {
    await cmd("project.new", { discardChanges: true });
    const ids = [];
    for (const n of ["T0", "T1", "T2", "T3", "T4", "T5"]) {
      ids.push((await cmd("track.add", { name: n, kind: "instrument" })).result?.id);
    }
    const m = await mk(ids[0], "M", 0);
    await selectClips([m]);
    await sleep(COALESCE_MS);
    const before = await histLen();
    const seqBefore = (await sel({})).editSeq;
    const n = await nudge({ direction: "down", repeat: 5 });
    const idx = await clipIndex();
    ck("F1 the seam really ran five presses (else every count below is about a "
       + "different number of presses)", n.nudgeRepeats === 5, JSON.stringify(n.nudgeRepeats));
    ck("F2 five ↓ presses walked the clip five lanes, to track index 5",
       idx.get(m)?.trackIndex === 5 && idx.get(m)?.trackId === ids[5],
       `trackIndex=${idx.get(m)?.trackIndex}`);
    ck("F3 ...and folded into ONE undo entry",
       (await histLen()) - before === 1, `depth +${(await histLen()) - before}`);
    ck("F4 editSeq advanced by FIVE — all five presses LANDED. Depth alone cannot "
       + "tell '5 folded into 1' from '1 landed and 4 were dropped'",
       n.editSeq === seqBefore + 5, `${seqBefore} -> ${n.editSeq}`);
    ck("F5 the LAST press reports a one-lane step, not the accumulated five",
       n.effectiveTrackDelta === 1 && n.trackStepDelta === 1,
       `effective=${n.effectiveTrackDelta} step=${n.trackStepDelta}`);
    // The other half of the coalescing story, asserted rather than assumed:
    // waited out, the next press is a SECOND entry.
    await sleep(COALESCE_MS);
    const d1 = await histLen();
    await nudge({ direction: "up" });
    ck("F6 a press SEPARATED by more than the 800 ms window is a SECOND entry — "
       + "F3 measured coalescing, not a journal that never grows",
       (await histLen()) - d1 === 1, `depth +${(await histLen()) - d1}`);
  }

  // ═══ G  THE CONSUME RULE ═══════════════════════════════════════════════════
  //
  // ⚠️ THIS LEG IS NOT THE ONE THE DESIGN ASKED FOR, AND THE DIFFERENCE IS A
  // FINDING, NOT A SHORTCUT. §10.5 asks the gate to read the LANES' VERTICAL
  // SCROLL OFFSET before and after a refused ↓ and prove it did not move. That
  // measurement is UNREACHABLE from any gate in this tree, for two independent
  // reasons, either of which alone is fatal:
  //
  //   1. NOTHING DELIVERS THE KEY. `debug.arrangeSelection {act:"nudge"}` calls
  //      `AppModel.handleArrangeNudgeKey` DIRECTLY. SwiftUI never sees a
  //      `KeyPress`, so `.handled` / `.ignored` is never returned to anything and
  //      the `ScrollView` cannot react whatever the consume rule says. And the
  //      real-key route is closed too: m23-g1 MEASURED that an unbundled staging
  //      binary does not route real key events (`keyDelete` -> `delivered:false`),
  //      re-probed at G3 below rather than inherited.
  //   2. NOTHING REPORTS THE OFFSET. The shared `ScrollView(.vertical)` in
  //      `ContentView` publishes no offset anywhere; `debug.arrangeScroll` SETS a
  //      target track and bumps a nonce, it does not read a position.
  //
  // A leg that read a scroll offset here would therefore pass identically under
  // M6 — i.e. it would measure nothing, which is precisely what §13 exists to
  // prevent. So G1/G2 pin the CONSUME DECISION, which is the observable half and
  // the half M6 flips, and G3 records the unmeasurable half honestly as a SKIP.
  {
    // G1 — the boundary-clamped ↑ (the beat-0-wall precedent, vertical).
    const t = await buildFixture();
    const m = await mk(t.a, "M", 0);
    await selectClips([m]);
    await sleep(COALESCE_MS);
    const clamped = await nudge({ direction: "up" });
    ck("G1 a ↑ the clamp reduced to NOTHING is still CONSUMED (nudged: true) — else it "
       + "falls through to the lanes' vertical ScrollView and slides the arrangement",
       clamped.nudged === true && clamped.effectiveTrackDelta === 0
         && clamped.clampedTracks === true,
       `nudged=${clamped.nudged} effective=${clamped.effectiveTrackDelta} `
       + `clampedTracks=${clamped.clampedTracks}`);

    // G2 — the `.store` refusal. THE FOURTH CONSUMING REFUSAL, and the one this
    // item re-examined: unlike the horizontal `.store` refusal (which needs a
    // take-comp member) this one is reachable in ordinary use — a MIDI clip with
    // an audio track below it.
    const t2 = await buildFixture();
    const m2 = await mk(t2.c, "M", 0);   // C is index 2; ↓ lands on the bus at 3
    await selectClips([m2]);
    await sleep(COALESCE_MS);
    const d0 = await histLen();
    const refused = await nudge({ direction: "down" });
    const idx = await clipIndex();
    ck("G2 a ↓ the STORE refused is CONSUMED on the VERTICAL axis (handled: true), "
       + "which is the one place the two axes deliberately differ",
       refused.nudged === true && refused.refusedBy === "store",
       `nudged=${refused.nudged} by=${refused.refusedBy} refusal=${refused.refusal}`);
    ck("G2b the refusal carries the store's own words, and the clip did not move",
       /cannot hold/.test(refused.refusal ?? "") && idx.get(m2)?.trackId === t2.c
         && (await histLen()) === d0,
       `refusal=${JSON.stringify(refused.refusal)} trackIndex=${idx.get(m2)?.trackIndex}`);
    ck("G2c the vertical step WAS chosen before the store refused (trackStepDelta is "
       + "set, not null) — so G2 measured a STORE refusal, not a chord rejection",
       refused.trackStepDelta === 1, JSON.stringify(refused.trackStepDelta));
    const allowed = await nudge({ direction: "up" });
    ck("G2d CONTROL: the SAME selection moves UP one lane — G2 measured the refusal, "
       + "not a dead key",
       allowed.nudged === true && allowed.effectiveTrackDelta === -1,
       `nudged=${allowed.nudged} effective=${allowed.effectiveTrackDelta}`);

    // G3 — the honest negative, re-MEASURED rather than inherited (the m23-y
    // idiom): probe whether this binary routes real key events at all.
    const probe = await sel({ act: "keyDelete" });
    obs("G3 key-delivery probe", `debug.arrangeSelection {act:"keyDelete"} -> `
        + `delivered=${probe.delivered}`);
    if (probe.delivered === true) {
      skip("G3 the lanes' vertical scroll offset before/after a refused ↓",
           "this binary DOES route real key events (delivered=true, contradicting m23-g1) — "
           + "but there is still no seam anywhere that reports the shared "
           + "ScrollView(.vertical)'s offset, so the measurement is blocked on the second "
           + "reason only. Report this: it changes what a future gate can do.");
    } else {
      skip("G3 the lanes' vertical scroll offset before/after a refused ↓",
           `BOTH links are missing. (1) delivered=${probe.delivered}: an unbundled staging `
           + "binary does not route real key events (m23-g1), and the nudge seam calls the "
           + "handler DIRECTLY, so SwiftUI never sees a KeyPress and the ScrollView cannot "
           + "react whatever the consume rule returns. (2) nothing publishes that "
           + "ScrollView's offset — debug.arrangeScroll sets a target and a nonce, it does "
           + "not read a position. A leg reading an offset here would pass identically "
           + "under M6, i.e. measure nothing. §10.5's premise stays REASONED, not proven; "
           + "G1/G2 pin the decision, which is the half that exists to be observed.");
    }
  }

  // ═══ H  OBSERVATION ONLY — NEVER A PIN (design §4.5 / §15, m23-bv) ════════
  //
  // Moving a MIDI clip between instrument tracks MID-PLAYBACK runs
  // `restart(cause: .continuation)`, and `.continuation` is the one cause that
  // CHASES held notes. Whether that is right — a missing pad versus a phantom
  // attack — is m23-bv, a PRODUCT question the user has not ruled on. This leg
  // therefore PRINTS what happens and asserts nothing about whether it is
  // correct. `ck` is not called once inside it.
  //
  // ⚠️ BOTH TRACKS ARE MUTED BEFORE PLAY, DELIBERATELY. Staging renders to the
  // system default output — the user's speakers — and this project treats
  // making unrequested sound as needing a user-present moment (m20-j's two
  // unrun audible legs). Mute is a MIXER-NODE gain gate
  // (`PlaybackGraph.applyMixerState`, "bus gain = muted ? 0 : volume"; the
  // file's own note says volume/pan/mute/solo "stay outside and never interrupt
  // audio"), so it silences the output without touching the MIDI schedule this
  // leg is observing. What it does mean is that the AUDIBLE half of m23-bv —
  // is the held note re-attacked or dropped — is NOT what this leg sees; that
  // needs the BlackHole loopback rig (m23bp-held-note.mjs) and a user-present
  // moment. What this leg observes is the TRANSPORT's behaviour across the
  // reschedule.
  {
    await cmd("project.new", { discardChanges: true });
    const a = (await cmd("track.add", { name: "H0", kind: "instrument" })).result?.id;
    const b = (await cmd("track.add", { name: "H1", kind: "instrument" })).result?.id;
    await cmd("track.setMute", { trackId: a, muted: true });
    await cmd("track.setMute", { trackId: b, muted: true });
    // BOTH TRACKS GET A REAL INSTRUMENT (m23bp's flat GM organ, program 19). Without
    // one there is no renderer and therefore no held VOICE — the observation would
    // read as being about m23-bv's sustained pad while actually being about an empty
    // schedule. GM sound banks are the safe path here: a third-party AUv2 wedges the
    // main actor for minutes (the AU-hosting lore), a GM bank does not.
    const instA = await cmd("track.setInstrument",
                            { trackId: a, soundBank: { source: "gm", program: 19 } });
    const instB = await cmd("track.setInstrument",
                            { trackId: b, soundBank: { source: "gm", program: 19 } });
    const held = await mk(a, "Held", 0, 128,
                          [{ pitch: 64, velocity: 100, startBeat: 0, lengthBeats: 128 }]);
    obs("H setup", `two MUTED instrument tracks; one 128-beat clip on H0 holding a single `
        + `128-beat note (clip ${held ? "created" : "MISSING"}); instruments `
        + `src=${instA.result?.soundBank?.name ?? JSON.stringify(instA.error)} `
        + `dst=${instB.result?.soundBank?.name ?? JSON.stringify(instB.error)}`);
    const play = await cmd("transport.play");
    await sleep(700);
    const beforeBeats = [];
    for (let i = 0; i < 3; i++) {
      beforeBeats.push((await overview()).transport?.positionBeats);
      await sleep(120);
    }
    const perfBefore = (await cmd("engine.performanceStats")).result ?? {};
    const move = await cmd("clip.moveManyByTracks", { ids: [held], byTracks: 1 });
    const afterBeats = [];
    for (let i = 0; i < 5; i++) {
      afterBeats.push((await overview()).transport?.positionBeats);
      await sleep(120);
    }
    const perfAfter = (await cmd("engine.performanceStats")).result ?? {};
    const ov = await overview();
    obs("H play", `transport.play ok=${play.ok}; positionBeats BEFORE the move `
        + `[${beforeBeats.join(", ")}]`);
    obs("H move", `clip.moveManyByTracks ok=${move.ok} error=${JSON.stringify(move.error)} `
        + `effectiveTrackDelta=${move.result?.effectiveTrackDelta} `
        + `landings=${JSON.stringify(move.result?.landings)}`);
    obs("H after", `positionBeats AFTER the move [${afterBeats.join(", ")}]; `
        + `isPlaying=${ov.transport?.isPlaying}`);
    const mono = afterBeats.every((v, i) => i === 0 || (typeof v === "number" && v >= afterBeats[i - 1]));
    obs("H continuity", `position advanced monotonically after the reschedule: ${mono}; `
        + `first post-move sample ${afterBeats[0]} vs last pre-move ${beforeBeats.at(-1)}`);
    obs("H engine", `performanceStats before=${JSON.stringify(perfBefore).slice(0, 300)}`);
    obs("H engine", `performanceStats after=${JSON.stringify(perfAfter).slice(0, 300)}`);
    obs("H m23-bv", "the AUDIBLE outcome (chased re-attack vs dropped pad) is NOT observed "
        + "here — both tracks DO have a real GM instrument, so the voice is genuinely held, "
        + "but they are muted on purpose and no seam reports RescheduleCause. This leg "
        + "records the transport's behaviour and nothing else. NOTHING IS PINNED.");
    await cmd("transport.stop");
    await sleep(SETTLE_MS);
  }

  // ═══ I  `.toTrack` COLLAPSES A 2-TRACK GROUP IN ONE STEP ══════════════════
  // m23aj2 L10 already pins the landings and the surviving beat offsets. The half
  // it does not reach is the JOURNAL: a collapse must be ONE entry, not one per
  // mover.
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);
    const y = await mk(t.b, "Y", 8);   // DISJOINT from X, so §18's refusal is not in play
    await sleep(COALESCE_MS);
    const before = await histLen();
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    const idx = await clipIndex();
    ck("I1 ok", r.ok, JSON.stringify(r).slice(0, 240));
    ck("I2 both movers collapsed onto C",
       idx.get(x)?.trackId === t.c && idx.get(y)?.trackId === t.c,
       `X on ${idx.get(x)?.trackIndex} Y on ${idx.get(y)?.trackIndex}`);
    ck("I3 the relative BEAT offset of 8 survived the collapse",
       near(idx.get(y)?.clip.startBeat - idx.get(x)?.clip.startBeat, 8),
       `${idx.get(x)?.clip.startBeat} / ${idx.get(y)?.clip.startBeat}`);
    ck("I4 a two-track collapse is ONE journal entry",
       (await histLen()) - before === 1, `depth +${(await histLen()) - before}`);
    ck("I5 nothing was trimmed or removed on the destination",
       (r.result?.trimmedClipIDs ?? []).length === 0
         && (r.result?.removedClipIDs ?? []).length === 0,
       `trimmed=${JSON.stringify(r.result?.trimmedClipIDs)}`);
  }

  // ═══ J  THE MANUFACTURED COLLISION REFUSES, WHOLE ═════════════════════════
  // Two movers from DIFFERENT source tracks at the SAME beats: perfectly legal
  // where they are, and the collapse would MANUFACTURE an overlap out of them.
  // m23aj2 L16 already pins the message BYTE-EXACTLY (a strictly stronger
  // assertion than anything here) — this leg carries the half it does not: the
  // whole project is byte-identical afterwards.
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);
    const y = await mk(t.b, "Y", 0);
    await sleep(SETTLE_MS);
    const s0 = await snapshot();
    const before = await histLen();
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    ck("J1 refused", !!r.error, JSON.stringify(r).slice(0, 240));
    ck("J2 the error names BOTH clips by id (names are not unique — two takes are "
       + "routinely both 'Audio 1')",
       (r.error ?? "").includes(x) && (r.error ?? "").includes(y), r.error ?? "");
    ck("J3 project.snapshot BYTE-IDENTICAL before/after — refused BEFORE any mutation",
       (await snapshot()) === s0, "snapshot changed");
    ck("J4 no undo step", (await histLen()) === before, `${before} -> ${await histLen()}`);
  }

  // ═══ K  ABUTMENT SUCCEEDS — the `<` vs `<=` leg (§18.8) ═══════════════════
  // [0,4) and [4,8) TOUCH at a shared edge, which is adjacency and not overlap
  // (`resolveOverlap`'s own half-open rule). Nothing else in this gate catches a
  // 2b' test relaxed to `<=`: J and L still refuse under it.
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0, 4);   // [0,4)
    const y = await mk(t.b, "Y", 4, 4);   // [4,8)
    await sleep(COALESCE_MS);
    const before = await histLen();
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    const idx = await clipIndex();
    ck("K1 ABUTTING movers from two source tracks COLLAPSE successfully — touching at a "
       + "shared edge is adjacency, not overlap",
       r.ok === true, JSON.stringify(r.error ?? r).slice(0, 240));
    ck("K2 both landed on C, intact, at 0 and 4",
       idx.get(x)?.trackId === t.c && idx.get(y)?.trackId === t.c
         && near(idx.get(x)?.clip.startBeat, 0) && near(idx.get(y)?.clip.startBeat, 4)
         && near(idx.get(x)?.clip.lengthBeats, 4) && near(idx.get(y)?.clip.lengthBeats, 4),
       `X=${idx.get(x)?.clip.startBeat}/${idx.get(x)?.clip.lengthBeats} `
       + `Y=${idx.get(y)?.clip.startBeat}/${idx.get(y)?.clip.lengthBeats}`);
    ck("K3 nothing was trimmed or removed",
       (r.result?.trimmedClipIDs ?? []).length === 0
         && (r.result?.removedClipIDs ?? []).length === 0,
       `trimmed=${JSON.stringify(r.result?.trimmedClipIDs)} `
       + `removed=${JSON.stringify(r.result?.removedClipIDs)}`);
    ck("K4 one journal entry", (await histLen()) - before === 1,
       `depth +${(await histLen()) - before}`);
  }

  // ═══ L  A NON-CROSSING MOVER COLLIDES TOO (§18.4(i)) ══════════════════════
  // X is ALREADY on the destination, so it never crosses: it keeps its array slot
  // rather than being vacated and re-appended. It is still in that destination's
  // `activeIDs`, and `resolvingOverlaps` exempts `activeIDs` members from
  // trimming each other — so it collides just the same. An implementation that
  // copies phase 2b's `where crossing[i]` filter passes every other leg here.
  {
    const t = await buildFixture();
    const x = await mk(t.c, "X", 0);   // ALREADY on C — the destination
    const y = await mk(t.b, "Y", 0);   // arrives from B
    await sleep(SETTLE_MS);
    const s0 = await snapshot();
    const before = await histLen();
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    ck("L1 refused even though one mover never leaves its track",
       !!r.error, JSON.stringify(r).slice(0, 240));
    ck("L2 the error names both clips", (r.error ?? "").includes(x) && (r.error ?? "").includes(y),
       r.error ?? "");
    ck("L3 project.snapshot BYTE-IDENTICAL before/after",
       (await snapshot()) === s0, "snapshot changed");
    ck("L4 no undo step", (await histLen()) === before, `${before} -> ${await histLen()}`);
    // CONTROL: the SAME arrival with X left OUT of `ids` succeeds — X is then an
    // ordinary RESIDENT, and the overlap policy edits it as it always has. This
    // is what proves L1 is about two MOVERS and not about "anything on C".
    //
    // ⚠️ IT GETS A FRESH FIXTURE, AND THAT IS A MEASURED CORRECTION. Run on L1's
    // fixture it was a CASCADE, not a control: mutation M9 (filter 2b' to crossing
    // movers) made L1 SUCCEED, which left Y already on C, so the control call
    // became a no-op that reports no trim — reddening L5 for a reason that had
    // nothing to do with what L5 claims to measure. A control that inherits the
    // state of the leg it controls is not a control.
    const t2 = await buildFixture();
    const x2 = await mk(t2.c, "X2", 0);   // resident on the destination
    const y2 = await mk(t2.b, "Y2", 0);   // the only mover
    await sleep(SETTLE_MS);
    const r2 = await cmd("clip.moveManyToTrack", { ids: [y2], toTrackId: t2.c });
    const idx = await clipIndex();
    ck("L5 CONTROL: with X a RESIDENT rather than a mover the same arrival SUCCEEDS, "
       + "and X is edited by the ordinary overlap policy",
       r2.ok === true && idx.get(y2)?.trackId === t2.c
         && ((r2.result?.removedClipIDs ?? []).includes(x2)
             || (r2.result?.trimmedClipIDs ?? []).includes(x2)),
       `ok=${r2.ok} trimmed=${JSON.stringify(r2.result?.trimmedClipIDs)} `
       + `removed=${JSON.stringify(r2.result?.removedClipIDs)}`);
  }
} catch (err) {
  fail++; failures.push(`harness: ${err.message}`);
  console.log(`FAIL harness :: ${err.message}`);
} finally {
  try { ws?.close(); } catch { /* already gone */ }
  stopStaging(GATE);
}

console.log(`\nM23AJ ${pass}/${pass + fail}`
  + `  (${observations.length} observations, ${skips.length} skipped)`);
if (failures.length) console.log("failed legs:\n  " + failures.join("\n  "));
process.exit(fail === 0 ? 0 : 1);
