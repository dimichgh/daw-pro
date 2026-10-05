// m34-i SMOKE — THE NEXT-CHORD BORDER, across the LIVE wire, on staging 17695.
//
// ══ WHAT THIS PROVES, AND WHAT IT CANNOT ═══════════════════════════════════
//
// The user played the shipped chord mode and reported two things hours apart:
//   "Four chords, 50 doowop, pop-punk does not change keyboard presets (lighted
//    keys)"
//   "4 chords with number on them which is hard to read, it is better to light
//    up border on then next recommeded chord"
//
// They are ONE defect. Those three progressions are `[1,5,6,4]`, `[1,6,4,5]` and
// `[6,4,1,5]` — the same set `{1,4,5,6}` in three orders — so they light
// identically BY CONSTRUCTION, and the unreadable order badges were carrying
// 100 % of what distinguished them.
//
// This gate asserts the replacement: a SEQUENCE CURSOR that starts on the
// progression's first chord and MOVES as you play, exposed as `next` on each
// chord cell and as `sequenceStep` on the echo.
//
// ⛔⛔ **IT CANNOT SEE A PIXEL, AND THE BUG IT REPLACES WAS A PIXEL BUG.** m23-cv
// shipped with TEN numbered badges where four were meant — four different keys
// all reading `1` — and no assertion in this tree could see it; a screenshot
// found it. So this gate does the one thing that reduces a pixel to a number:
// it pins the COUNT of bordered cells at exactly one (and at exactly zero with
// no preset), and it CAPTURES the window at two cursor positions so a human can
// look. **The capture is written for a human to open — this gate does not judge
// its contents.**
//
// It is `_m23cv-chord-mode-smoke.mjs`'s sibling and deliberately reuses its
// shape: same `debug.musicalTyping` seam, same `verdict()` exit.
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sleep, buildOrAbort, startStaging, stopStaging, connect, verdict,
} from "./_staging.mjs";

const GATE = "m34i-next-chord-border-smoke";
const SHOTS = process.env.M34I_SHOT_DIR ?? join(tmpdir(), "m34i-border-shots");
mkdirSync(SHOTS, { recursive: true });

buildOrAbort({ label: "building staging binary (m34-i)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34i${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
let pass = 0, fail = 0;
const ok = (c, label, detail = "") => {
  if (c) { pass++; console.log("PASS " + label); }
  else { fail++; console.log("FAIL " + label + (detail ? "  << " + detail : "")); }
};
const body = r => (r.result ?? r.data ?? r);
const cells = s => s.chordCells ?? [];
/// EVERY cell wearing the border. Returned as a LIST, never as a first match —
/// the whole point is the count.
const bordered = s => cells(s).filter(c => c.next === true);
const borderKey = s => bordered(s).map(c => c.key).join("+") || "-";
const state = async (params = {}) => body(await cmd("debug.musicalTyping", params));

/// Read the border and pin its COUNT in the same breath. m23-cv's badge bug was
/// a count bug; a helper that returned only the first match would have been
/// perfectly happy with ten of them.
function border(s, where) {
  const list = bordered(s);
  ok(list.length === 1, `exactly ONE bordered cell — ${where}`,
     `${list.length}: ${JSON.stringify(list.map(c => c.key))}`);
  return list[0];
}

async function shot(name) {
  const path = `${SHOTS}/${name}.png`;
  const r = body(await cmd("debug.captureUI", { path }));
  const wrote = existsSync(path);
  ok(wrote, `captured ${name}.png for a human to LOOK at`,
     JSON.stringify(r).slice(0, 200));
  if (wrote) console.log(`  SHOT ${path}`);
  return path;
}

try {
  await cmd("project.new", { name: "m34i-border-smoke" });
  const t = body(await cmd("track.add", { name: "Keys", kind: "instrument" }));
  const trackID = (t.track ?? t)?.id;
  ok(!!trackID, "instrument track added", JSON.stringify(t).slice(0, 200));
  // The active track is written by a HEADER CLICK — there is no `track.select`.
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: trackID });
  await cmd("debug.musicalTyping", { enable: true });
  await cmd("debug.musicalTyping", { playMode: "chords" });
  // ⚠️ PINNED EXPLICITLY AT m34-g, AND EVERY ASSERTION BELOW IS UNCHANGED.
  // This gate's subject is WAIT-FOR-YOU behaviour — "an off-sequence chord
  // sounds and does not move the cue" is that mode's contract, not chord mode's.
  // m34-g shipped the switch the user asked for and made lights-run-ahead the
  // default, so a gate that inherited the default would silently change subject.
  // The other two modes are m34-g's own gate (_m34g-playbox-smoke.mjs).
  await cmd("debug.musicalTyping", { advanceMode: "onMatch" });

  // ══ 1. NO PRESET, NO CUE ════════════════════════════════════════════════
  let s = await state({ progression: "" });
  ok(s.progression === null, "no preset selected", String(s.progression));
  ok(bordered(s).length === 0,
     "⛔ with NO progression there is exactly ZERO bordered cells",
     borderKey(s));
  ok(s.sequenceStep === null && s.sequenceLength === null,
     "…and no sequence cursor at all",
     JSON.stringify([s.sequenceStep, s.sequenceLength]));

  // ══ 2. THE CURSOR ARMS ON THE PRESET'S FIRST CHORD ══════════════════════
  s = await state({ progression: "four-chords" });
  ok(s.sequenceLength === 4, "Four Chords is a four-step sequence",
     String(s.sequenceLength));
  ok(s.advanceMode === "onMatch",
     "⭐ the advance rule is a PARAMETER — and m34-g exposes all three as a switch",
     String(s.advanceMode));
  ok(s.advanceModeSetting === "onMatch",
     "…and the SWITCH and the PLAYER agree about which mode is selected",
     JSON.stringify([s.advanceModeSetting, s.advanceMode]));
  ok(s.sequenceStep === 1 && s.sequenceDegree === 1,
     "the cursor starts on step 1 — the I chord", JSON.stringify(
       [s.sequenceStep, s.sequenceDegree]));
  let b = border(s, "Four Chords at rest");
  ok(b?.key === "A", "…and the border is on A, which plays I", b?.key);
  ok(b?.lit === true, "the bordered cell is always a lit one", JSON.stringify(b));
  // ⚠️ TWO INSTRUMENTS ON ONE QUESTION. `sequenceStep` is the cursor; `order` is
  // the cell's own step index. If they ever disagree, the border is drawn
  // somewhere the model does not think it is.
  ok(b?.order === s.sequenceStep,
     "⭐ the bordered cell's own step index AGREES with the cursor",
     JSON.stringify([b?.order, s.sequenceStep]));
  await shot("1-four-chords-step1");

  // ⛔ NO BADGES. `order` survives as SEAM DATA; nothing draws it any more. The
  // gate cannot see that directly, so it pins the shape the drawing follows:
  // exactly four stepped cells, and LIT is wider than STEPPED.
  const stepped = cells(s).filter(c => c.order !== null);
  ok(stepped.length === 4, "exactly FOUR stepped cells for a four-chord preset",
     JSON.stringify(stepped.map(c => `${c.key}=${c.order}`)));
  ok(cells(s).filter(c => c.lit).length > 4,
     "…while LIT stays wider — any lit key plays that chord",
     `${cells(s).filter(c => c.lit).length} lit`);

  // ══ 3. THE BORDER MOVES AS YOU PLAY ═════════════════════════════════════
  s = await state({ press: "A" });
  ok((s.sounding ?? []).length === 4, "playing the cued chord sounds it",
     JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { release: "A" });
  s = await state({});
  b = border(s, "after playing I");
  ok(b?.key === "G" && s.sequenceStep === 2,
     "⭐⭐ THE BORDER MOVED to V — the cue follows the performance",
     JSON.stringify([b?.key, s.sequenceStep]));
  await shot("2-four-chords-step2");

  // ⛔⛔ A CUE, NEVER A GATE. The assertion the whole item would be wrong
  // without: playing something else is neither refused nor does it move the cue.
  s = await state({ press: "S" });                 // ii — dim, off-sequence
  ok(s.decision === "performed", "⛔⛔ an off-sequence key still PERFORMS",
     String(s.decision));
  ok((s.sounding ?? []).length === 4,
     "⛔⛔ …and sounds a full chord", JSON.stringify(s.sounding));
  ok((s.storeHeldPitches ?? []).length === 4, "…which reached the store",
     JSON.stringify(s.storeHeldPitches));
  await cmd("debug.musicalTyping", { release: "S" });
  s = await state({});
  b = border(s, "after wandering off the preset");
  ok(b?.key === "G" && s.sequenceStep === 2,
     "⛔⛔ the cue did NOT advance for a chord that was not cued",
     JSON.stringify([b?.key, s.sequenceStep]));

  // A LIT chord that is simply not the NEXT one: same answer.
  await cmd("debug.musicalTyping", { press: "F" });  // IV — step 4, not step 2
  await cmd("debug.musicalTyping", { release: "F" });
  s = await state({});
  ok(borderKey(s) === "G" && s.sequenceStep === 2,
     "…and playing step 4 out of turn does not skip the cursor to step 5",
     JSON.stringify([borderKey(s), s.sequenceStep]));

  // ══ 4. IT WRAPS — A FOUR-CHORD LOOP IS A LOOP ═══════════════════════════
  const walk = [];
  for (let i = 0; i < 4; i++) {
    s = await state({});
    const key = borderKey(s);
    walk.push(key);
    await cmd("debug.musicalTyping", { press: key });
    await cmd("debug.musicalTyping", { release: key });
  }
  s = await state({});
  ok(JSON.stringify(walk) === JSON.stringify(["G", "H", "F", "A"]),
     "⭐ following the border walks V vi IV then wraps to I",
     JSON.stringify(walk));
  ok(s.sequenceStep === 2, "…and the cursor kept counting through the wrap",
     String(s.sequenceStep));

  // ══ 5. ⭐⭐⭐ THE USER'S DEFECT, MEASURED ════════════════════════════════
  // Three presets, one lit set, three different cues.
  const litSets = [];
  const opening = [];
  const second = [];
  for (const id of ["four-chords", "doo-wop", "pop-punk"]) {
    s = await state({ progression: id });
    litSets.push(JSON.stringify(cells(s).filter(c => c.lit).map(c => c.key)));
    const first = borderKey(s);
    opening.push(first);
    await cmd("debug.musicalTyping", { press: first });
    await cmd("debug.musicalTyping", { release: first });
    s = await state({});
    second.push(borderKey(s));
  }
  ok(new Set(litSets).size === 1,
     "⭐ THE PREMISE, MEASURED: all three presets light the IDENTICAL keys",
     JSON.stringify([...new Set(litSets)]).slice(0, 200));
  ok(JSON.stringify(opening) === JSON.stringify(["A", "A", "H"]),
     "⚠️ AT REST two of the three still match — both open on I. Honest limit.",
     JSON.stringify(opening));
  ok(JSON.stringify(second) === JSON.stringify(["G", "H", "F"]),
     "⭐⭐⭐ BY THE SECOND CHORD ALL THREE ARE DISTINCT — the defect is closed",
     JSON.stringify(second));
  ok(new Set(second).size === 3, "…three presets, three different cues",
     JSON.stringify(second));
  await shot("3-pop-punk-step2");

  // ══ 6. THE MOUSE DRIVES THE SAME SEQUENCE ═══════════════════════════════
  await cmd("debug.musicalTyping", { progression: "four-chords" });
  s = await state({ chordCell: 0 });               // the "A" cell, degree I
  ok((s.sounding ?? []).length === 4, "a MOUSE press on the chord row sounds it",
     JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { pointerUp: true });
  s = await state({});
  ok(borderKey(s) === "G" && s.sequenceStep === 2,
     "⛔ the on-screen row advances the border exactly as the keys do — ONE instrument",
     JSON.stringify([borderKey(s), s.sequenceStep]));

  // ══ 7. CLEARING THE PRESET CLEARS THE CUE ═══════════════════════════════
  s = await state({ progression: "" });
  ok(bordered(s).length === 0 && s.sequenceStep === null,
     "clearing the preset removes the border and the cursor together",
     JSON.stringify([borderKey(s), s.sequenceStep]));
  await cmd("debug.musicalTyping", { releaseAll: true });
  await sleep(120);

  console.log(`M34I_BORDER_SMOKE pass=${pass} fail=${fail} total=${pass + fail}`);
  console.log(`SHOTS IN ${SHOTS} — a UI phase is not done until someone LOOKS.`);
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}
verdict({ ran: pass + fail, failed: fail });
