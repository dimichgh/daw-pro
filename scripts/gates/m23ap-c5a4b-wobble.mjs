// m23-ap C5a-4b GATE — THE WOBBLE TOOL AND ITS DOT, LOOKED AT on a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is stopped PIDFILE-EXACT through `_pitch-editor-look.mjs`'s
// `stopLook`, never pkill/pgrep). Design: vibrato-handle §15 T18 (→ C5a-G),
// unpitched design §4 (the dot), §18.8 (the low-note question).
//
// ⭐ A SPY GATE WITH A SECOND INSTRUMENT. The pane says what it drew
// (`debug.pitchEditor`'s `wobble` block: the dot, its tip, the draft, the
// palette's readout), and the STORE is read back over the wire independently
// (`clip.getPitchEdits`, `edit.history`, `edit.undo`) — never one instrument.
//
// WHAT THIS PROVES
//   • the Wobble tool is a palette slot; in it a hovered sung note shows THE
//     DOT (on that note) and the palette's readout; in the Move tool the same
//     hover shows none (the control);
//   • ONE DOT CLICK is ONE step: the stored keep moves by exactly 0.10, every
//     other stored field and note is byte-identical, the history grows by one,
//     the tip says the user's words, and Undo restores the table exactly;
//   • 4 pt of travel on the dot is a DRAG, and one that changes nothing
//     commits nothing (T10): the history does not move;
//   • a DRAG commits ONCE at release, and what the store holds is what the
//     draft drew at the last tick (all six fields); Undo restores;
//   • a note pulled all the way down reads "smoothed flat";
//   • the §18.8 question, on a LOW note (110 Hz) after a handoff, captured and
//     its readout printed for a person to judge.
//   • the readout at the 1208 pt window floor, captured;
//   • (C5b-4b) the readout MID-DRAG at that floor — the palette's longest line
//     where the palette is narrowest — captured.
//
// FOCUS (w7): staging launches with DAWPRO_STAGING_NO_ACTIVATE=1, so the
// user's frontmost app stays frontmost (C5b-4b; DAWProApp's onAppear).
//
// WHAT THIS DOES NOT PROVE
//   • a real pointer (m23-g1): the steps go through the pane's own gesture
//     functions (`debug.pitchEditor {act:…}`), not the event system;
//   • sound: the track is muted, and a gate has no business making sound;
//   • motion: `view.capture` is ~3.5 fps and cannot film a drag.
//
// PROVENANCE — as in `m23ap-i5-playhead.mjs`: the look harness launches with
// `skipBuild`, so this gate first proves `.build/debug/DAWApp` is newer than
// every file under `Sources/` and `Package.swift` (with a positive control on
// the same `find`), and refuses (exit 2) otherwise. Build under a heavy slot
// right before running it.
//
//   node scripts/gates/m23ap-c5a4b-wobble.mjs
//
// Env: M23AP_C5A4B_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-c5a4b).
//
// EXIT: 0 green, 1 red, 2 proves nothing (a refused precondition).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, verdict, sleep } from "./_staging.mjs";
import {
  synthesizeVocalFixture, launchLook, stopLook, makeCmd, waitPitchEditorReady,
  stagePitchEditorStep, captureLook,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-c5a4b";

// ═══════════════════════════════════════════════════════════════════════════
// THE PALETTE (W7-NTU, 2026-10-04). Four slots since the Voice tool landed
// (W7-NTU U3), in the order drawn (`PitchEditorTool.allCases`, which the pane
// both draws and echoes as `interaction.paletteLabels`). This gate pinned three
// until then, so it read red on the real palette.
//   node scripts/gates/m23ap-c5a4b-wobble.mjs --self-test-palette
// runs ONLY the check below on a planted echo, without staging: the real
// palette must pass, and a palette without "Voice" (or the old three) must not.
// ═══════════════════════════════════════════════════════════════════════════
const PALETTE = ["Move", "Split", "Wobble", "Voice"];
const paletteIsTheToolSet = (labels) => JSON.stringify(labels) === JSON.stringify(PALETTE);
if (process.argv.includes("--self-test-palette")) {
  const rows = [
    { labels: ["Move", "Split", "Wobble", "Voice"], want: true },
    { labels: ["Move", "Split", "Wobble"], want: false },          // Voice removed (the old pin)
    { labels: ["Move", "Split", "Voice"], want: false },           // Wobble removed
    { labels: ["Move", "Split", "Voice", "Wobble"], want: false }, // order changed
    { labels: undefined, want: false },                            // no echo field
  ];
  let bad = 0;
  for (const r of rows) {
    const got = paletteIsTheToolSet(r.labels);
    if (got !== r.want) bad += 1;
    console.log(`  ${got === r.want ? "ok  " : "!!  "} ${JSON.stringify(r.labels)} -> ${got} (want ${r.want})`);
  }
  console.log(bad === 0 ? "palette self-test: GREEN" : `palette self-test: RED (${bad})`);
  process.exit(bad === 0 ? 0 : 1);
}

const OUT = process.env.M23AP_C5A4B_OUT || "/tmp/m23ap-c5a4b";
mkdirSync(OUT, { recursive: true });

const PPB = 64;             // wide enough that a note's body is well clear of its dot
const EPS = 1e-9;
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const r3 = (v) => (typeof v === "number" ? Math.round(v * 1000) / 1000 : v);
/** A key-order-free rendering: the wire's objects come from a Swift
 * dictionary, whose key ORDER differs call to call (measured: the first run
 * of this gate compared raw `JSON.stringify` and read "CHANGED" for tables
 * that were equal). Every table comparison below goes through this. */
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// PROVENANCE
// ═══════════════════════════════════════════════════════════════════════════
{
  const binary = join(ROOT, DEFAULT_BINARY);
  const find = (args) => spawnSync("find", args, { cwd: ROOT, encoding: "utf8" });
  const newer = find(["Sources", "Package.swift", "-newer", binary, "-type", "f"]);
  const older = find(["Sources", "-type", "f", "!", "-newer", binary]);
  if (newer.status !== 0 || older.status !== 0) refuseRun(`find failed: ${newer.stderr || older.stderr}`);
  const newerFiles = newer.stdout.split("\n").filter(Boolean);
  const olderCount = older.stdout.split("\n").filter(Boolean).length;
  if (olderCount === 0) refuseRun("provenance control: `! -newer` matched no file — the find shape is broken");
  if (newerFiles.length > 0) {
    refuseRun(`${newerFiles.length} source file(s) are NEWER than ${DEFAULT_BINARY} `
      + `(${newerFiles.slice(0, 4).join(", ")}) — rebuild under a heavy slot and re-run`);
  }
  console.log(`provenance: ${DEFAULT_BINARY} is newer than all ${olderCount} files under Sources/ and Package.swift`);
}

// Four sung notes with the fixture's own 5.5 Hz vibrato: three mid notes and a
// LOW one (110 Hz, the §18.8 question).
const LEGS = [
  { hz: 220, seconds: 1.5 },   // hover + the dot click
  { hz: 247, seconds: 1.5 },   // a new wobble, mid-drag
  { hz: 196, seconds: 1.5 },   // pulled flat
  { hz: 110, seconds: 1.8 },   // low note, after a handoff
];
const fixturePath = synthesizeVocalFixture(OUT, { notes: LEGS });

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchLook({ gate: GATE, settleMs: 1500, env: { DAWPRO_STAGING_NO_ACTIVATE: "1" } });
console.log(`staging pid ${session.pid} (skipBuild — provenance proved above); started ${new Date().toISOString()}`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});
const stage = (act) => stagePitchEditorStep(cmd, act);

let exitCode = null;
const captures = {};
const looks = {};
try {
  // ── a NAMED project of this gate's own; the vocal at beat 0, muted
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { name: "C5a4b Vocal", kind: "audio" });
  const clip = await must("clip.addAudio", { trackId: track.id, path: fixturePath, atBeat: 0 });
  await must("clip.autoCorrectPitch", { clipId: clip.id });
  await must("track.setMute", { trackId: track.id, muted: true });
  const projectPath = join(OUT, "C5a4b Wobble.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${clip.id.slice(0, 8)}`);
  const opened = await must("view.openPitchEditor", { clipId: clip.id });
  if (opened.opened !== true) refuseRun(`view.openPitchEditor did not open: ${opened.reason}`);
  await waitPitchEditorReady(cmd, { timeoutMs: 30_000, intervalMs: 250 });
  await must("transport.stop", {});
  await must("debug.panelLayout", { pitchEditorPPB: PPB });

  // The tool is gated on the RENDER's contour (the basis gate, §5.5): wait for
  // the tuned clip's render to land and the line to be drawn from it.
  {
    const deadline = Date.now() + 60_000;
    let basis = "";
    let rendering = true;
    while (Date.now() < deadline) {
      const c = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
        .find((x) => x.id === clip.id);
      rendering = c?.stretchRendering === true;
      basis = (await echo()).playedLine?.basis;
      if (!rendering && basis === "render") break;
      await sleep(300);
    }
    if (basis !== "render") refuseRun(`the played line never reached the render's basis (basis "${basis}", rendering ${rendering})`);
  }
  await sleep(300);

  // ── which drawn note is which leg: the longest stored note near each leg's pitch
  const e0 = await echo();
  const midiOf = (hz) => 69 + 12 * Math.log2(hz / 440);
  const pick = (hz) => {
    const near = e0.notes.filter((n) => n.origin !== "unpitched" && Math.abs(n.sungMidi - midiOf(hz)) < 1);
    near.sort((a, b) => (b.endSeconds - b.startSeconds) - (a.endSeconds - a.startSeconds));
    const n = near[0];
    const rect = n && e0.notesAsDrawn.find((r) => r.id === n.id);
    if (!rect) refuseRun(`no drawn note near ${hz} Hz (notes: ${e0.notes.map((x) => r3(x.detectedHz)).join(", ")})`);
    return { id: n.id, hz: n.detectedHz, rect };
  };
  const mid = pick(220);
  const made = pick(247);
  const flat = pick(196);
  const low = pick(110);
  console.log(`notes: 220→${mid.id.slice(0, 8)} 247→${made.id.slice(0, 8)} 196→${flat.id.slice(0, 8)} `
    + `110→${low.id.slice(0, 8)} (of ${e0.notes.length} stored, ${e0.notesAsDrawn.length} drawn)`);
  // A point on a note's BODY, well clear of the dot's 12 pt reach; and its dot.
  const bodyOf = (n) => ({ x: n.rect.x + 8, y: n.rect.y + n.rect.height / 2 });
  const dotOf = (n) => ({ x: n.rect.x + n.rect.width / 2, y: n.rect.y });
  /** Scroll so a note sits in view, then re-read its rect (content space is
   * unchanged by a scroll; the capture needs it on screen). */
  async function showNote(n) {
    const e = await echo();
    const wantX = Math.max(0, n.rect.x - 120);
    // Vertically: the note (and the tip plate above it) in the middle of what
    // the pane shows — the low note sits below the rows a fresh pane shows.
    const wantY = Math.max(0, n.rect.y + n.rect.height / 2 - e.viewport.viewportH / 2);
    if (Math.abs(e.viewport.offsetX - wantX) > 1 || Math.abs(e.viewport.offsetY - wantY) > 1) {
      await stage({ act: "scroll", x: wantX, y: wantY });
    }
    await sleep(250);
  }
  const storedTable = async () => (await must("clip.getPitchEdits", { clipId: clip.id })).segments;
  const byId = (segments, id) => segments.find((s) => s.id === id);
  const history = async () => (await must("edit.history", {})).undo;
  const SIX = ["vibratoRateHz", "vibratoDepthCents", "vibratoOnsetSeconds", "vibratoPhaseAnchorSeconds",
    "vibratoScale", "driftScale"];

  // ═════════════════════════════════════════════════════════════════════════
  // 1 — THE TOOL, THE HOVER, THE DOT (and the Move tool as the control)
  // ═════════════════════════════════════════════════════════════════════════
  await showNote(mid);
  await stage({ act: "tool", tool: "pointer" });
  await stage({ act: "hover", ...bodyOf(mid) });
  const moveHover = await echo();
  check("CONTROL — in the Move tool, a hovered note shows NO dot and no wobble readout",
    moveHover.wobble.engaged === false && moveHover.wobble.dot.visible === false && moveHover.wobble.readout === "",
    `tool ${moveHover.tool}; dot ${JSON.stringify(moveHover.wobble.dot)}; readout "${moveHover.wobble.readout}"`);
  await stage({ act: "tool", tool: "wobble" });
  await stage({ act: "hover", ...bodyOf(mid) });
  const hovered = await echo();
  check("the palette offers Move, Split, Wobble and Voice, and the Wobble slot is engaged",
    paletteIsTheToolSet(hovered.interaction.paletteLabels)
      && hovered.tool === "wobble" && hovered.wobble.engaged === true,
    `labels ${JSON.stringify(hovered.interaction.paletteLabels)}; tool ${hovered.tool}`);
  check("⭐ a hovered sung note in the Wobble tool shows THE DOT at its top centre, and the palette reads it",
    hovered.wobble.dot.visible === true && hovered.wobble.dot.noteId === mid.id
      && Math.abs(hovered.wobble.dot.x - dotOf(mid).x) < 0.5 && Math.abs(hovered.wobble.dot.y - dotOf(mid).y) < 0.5
      && hovered.wobble.readout.length > 0 && hovered.interaction.dragReadout === hovered.wobble.readout,
    `dot ${JSON.stringify(hovered.wobble.dot)}; readout "${hovered.wobble.readout}" `
    + `(warning ${hovered.wobble.readoutIsWarning}); help "${hovered.interaction.toolHelp}"`);
  captures.hover = (await captureLook(cmd, join(OUT, "c5a4b-1-hover-sung-note.png"))).path;
  looks.hover = { readout: hovered.wobble.readout, tip: hovered.wobble.dot.tip, help: hovered.interaction.toolHelp };

  // ═════════════════════════════════════════════════════════════════════════
  // 2 — 4 pt ON THE DOT IS A DRAG, AND ONE THAT CHANGES NOTHING COMMITS NOTHING
  // ═════════════════════════════════════════════════════════════════════════
  {
    const d = dotOf(mid);
    const h0 = await history();
    const t0 = await storedTable();
    const pressed = await stage({ act: "press", x: d.x, y: d.y });
    await stage({ act: "drag", x: d.x + 4, y: d.y });
    const rel = await stage({ act: "release", x: d.x + 4, y: d.y });
    const h1 = await history();
    const t1 = await storedTable();
    check("4 pt of travel on the dot is a DRAG (endWobble), and a drag that changes nothing commits nothing (T10)",
      pressed.press.kind === "wobble" && pressed.press.door === "dot"
        && rel.lastRelease?.action === "endWobble" && h1.length === h0.length
        && canon(t1) === canon(t0),
      `press ${pressed.press.kind}/${pressed.press.door}; release ${rel.lastRelease?.action}; `
      + `history ${h0.length}→${h1.length}; table ${canon(t1) === canon(t0) ? "unchanged" : "CHANGED"}`);
  }
  await sleep(900);   // past the journal's 800 ms fold, so the click below is its own step

  // ═════════════════════════════════════════════════════════════════════════
  // 3 — ONE DOT CLICK IS ONE STEP; UNDO RESTORES
  // ═════════════════════════════════════════════════════════════════════════
  {
    const d = dotOf(mid);
    const h0 = await history();
    const t0 = await storedTable();
    const before = byId(t0, mid.id);
    await stage({ act: "press", x: d.x, y: d.y });
    const rel = await stage({ act: "release", x: d.x, y: d.y });
    const h1 = await history();
    const t1 = await storedTable();
    const after = byId(t1, mid.id);
    const othersSame = t0.every((s) => s.id === mid.id || canon(s) === canon(byId(t1, s.id)));
    const fieldsSame = Object.keys(before).every((k) => k === "vibratoScale" || k === "edited"
      || canon(before[k]) === canon(after[k]));
    check("⭐ ONE dot click is ONE step: the stored keep moves by exactly 0.10 (read back over the wire), nothing else moves",
      rel.lastRelease?.action === "wobbleStep" && rel.lastRelease?.bigger === true
        && Math.abs(after.vibratoScale - before.vibratoScale - 0.1) < 1e-9 && othersSame && fieldsSame,
      `release ${rel.lastRelease?.action} bigger=${rel.lastRelease?.bigger}; keep ${before.vibratoScale}→${after.vibratoScale}; `
      + `drift ${before.driftScale}→${after.driftScale}; other notes ${othersSame ? "unchanged" : "CHANGED"}; `
      + `other fields ${fieldsSame ? "unchanged" : "CHANGED"}`);
    check("POSITIVE CONTROL for the table comparator: the click's table compares DIFFERENT (so an 'unchanged' above can be believed)",
      canon(t1) !== canon(t0), "canon(after click) vs canon(before)");
    check("the click is exactly ONE undo entry", h1.length === h0.length + 1,
      `history ${h0.length}→${h1.length}; newest "${h1[0]}"`);
    await sleep(300);   // the pane resyncs from the store on its next render
    const tipped = await echo();
    check("the dot's TIP after the click says the user's words for the new keep",
      tipped.wobble.dot.visible === true && tipped.wobble.dot.noteId === mid.id
        && /^Wobble widened to 110%$|^Wobble kept: \d+% of how you sang it$|^As you sang it \(100%\)$/.test(tipped.wobble.dot.tip),
      `tip "${tipped.wobble.dot.tip}" (reason ${tipped.wobble.dot.reason}); readout "${tipped.wobble.readout}"`);
    captures.dotTip = (await captureLook(cmd, join(OUT, "c5a4b-4-dot-click-tip.png"))).path;
    looks.dotTip = { tip: tipped.wobble.dot.tip, reason: tipped.wobble.dot.reason, readout: tipped.wobble.readout };
    await must("edit.undo", {});
    await sleep(300);
    const t2 = await storedTable();
    check("Undo restores the table EXACTLY (every note, every field)",
      canon(t2) === canon(t0),
      `keep after undo ${byId(t2, mid.id)?.vibratoScale}; table ${canon(t2) === canon(t0) ? "identical" : "DIFFERENT"}`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 4 — A NEW WOBBLE, MID-DRAG; ONE COMMIT AT RELEASE = WHAT THE DRAFT DREW
  // ═════════════════════════════════════════════════════════════════════════
  await showNote(made);
  {
    const b = bodyOf(made);
    const h0 = await history();
    const t0 = await storedTable();
    await stage({ act: "hover", ...b });
    const pressed = await stage({ act: "press", x: b.x, y: b.y });
    // Sideways past the 16 pt dead zone (the handoff to a new wobble), then wider.
    for (const [dx, dy] of [[6, 0], [20, 0], [34, -6], [40, -14]]) {
      await stage({ act: "drag", x: b.x + dx, y: b.y + dy });
    }
    const middrag = await echo();
    captures.madeMidDrag = (await captureLook(cmd, join(OUT, "c5a4b-2-new-wobble-mid-drag.png"))).path;
    looks.madeMidDrag = { readout: middrag.wobble.readout, phase: middrag.wobble.phase, draft: middrag.wobble.draft };
    check("mid-drag: the press is a wobble through the NOTE's door, dragging, and the pane holds a draft",
      pressed.press.door === "drag" && middrag.wobble.dragging === true && middrag.wobble.draft !== null
        && middrag.wobble.noteId === made.id && middrag.wobble.dot.visible === false,
      `door ${pressed.press.door}; dragging ${middrag.wobble.dragging}; phase ${middrag.wobble.phase}; `
      + `readout "${middrag.wobble.readout}"; dot during drag ${middrag.wobble.dot.visible}`);
    const h1mid = await history();
    check("NOTHING is committed during the drag", h1mid.length === h0.length
      && canon(await storedTable()) === canon(t0), `history ${h0.length}→${h1mid.length}`);
    const rel = await stage({ act: "release", x: b.x + 40, y: b.y - 14 });
    const h1 = await history();
    const after = byId(await storedTable(), made.id);
    const drawn = middrag.wobble.draft;
    const sixSame = SIX.every((k) => Math.abs(after[k] - drawn[k]) < 1e-9);
    check("⭐ the release commits ONCE, and the store holds EXACTLY the six fields the draft drew at the last tick",
      rel.lastRelease?.action === "endWobble" && h1.length === h0.length + 1 && sixSame,
      `history ${h0.length}→${h1.length} ("${h1[0]}"); stored ${JSON.stringify(Object.fromEntries(SIX.map((k) => [k, r3(after[k])])))} `
      + `vs drawn ${JSON.stringify(Object.fromEntries(SIX.map((k) => [k, r3(drawn[k])])))}`);
    await must("edit.undo", {});
    await sleep(300);
    check("Undo restores the table after the drag",
      canon(await storedTable()) === canon(t0), "table compared whole");
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 5 — A NOTE PULLED FLAT, MID-DRAG
  // ═════════════════════════════════════════════════════════════════════════
  await showNote(flat);
  {
    const b = bodyOf(flat);
    await stage({ act: "hover", ...b });
    await stage({ act: "press", x: b.x, y: b.y });
    for (const dy of [10, 60, 140, 240]) await stage({ act: "drag", x: b.x, y: b.y + dy });
    const pulled = await echo();
    captures.flat = (await captureLook(cmd, join(OUT, "c5a4b-3-pulled-flat.png"))).path;
    looks.flat = { readout: pulled.wobble.readout, draft: pulled.wobble.draft };
    check("a note pulled all the way down reads SMOOTHED FLAT (keep 0 in the draft)",
      /smoothed flat/i.test(pulled.wobble.readout) && pulled.wobble.draft?.vibratoScale === 0,
      `readout "${pulled.wobble.readout}"; draft keep ${pulled.wobble.draft?.vibratoScale}, drift ${pulled.wobble.draft?.driftScale}`);
    await stage({ act: "release", x: b.x, y: b.y + 240 });
    await must("edit.undo", {});
    await sleep(300);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 6 — §18.8: A LOW NOTE AFTER A HANDOFF (captured for a person to judge)
  // ═════════════════════════════════════════════════════════════════════════
  await showNote(low);
  {
    const b = bodyOf(low);
    await stage({ act: "hover", ...b });
    const rest = await echo();
    await stage({ act: "press", x: b.x, y: b.y });
    for (const dx of [8, 20, 30]) await stage({ act: "drag", x: b.x + dx, y: b.y });
    const handed = await echo();
    captures.low = (await captureLook(cmd, join(OUT, "c5a4b-5-low-note-handoff.png"))).path;
    const sung = (handed.wobble.perNote ?? []).find((p) => p.id === low.id);
    looks.low = {
      hz: low.hz, restReadout: rest.wobble.readout, phase: handed.wobble.phase, handedOff: handed.wobble.handedOff,
      readout: handed.wobble.readout, draft: handed.wobble.draft, readings: sung,
    };
    console.log(`  look (§18.8): ${r3(low.hz)} Hz — at rest "${rest.wobble.readout}"; after 30 pt sideways `
      + `phase ${handed.wobble.phase}: "${handed.wobble.readout}"; sung ${JSON.stringify(sung?.sung)}; `
      + `played ${JSON.stringify(sung?.played)}; draft depth ${r3(handed.wobble.draft?.vibratoDepthCents)} c`);
    await stage({ act: "release", x: b.x + 30, y: b.y });
    const h = await history();
    if (handed.wobble.phase === "handedOff") { await must("edit.undo", {}); await sleep(300); }
    looks.low.historyTop = h[0];
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 7 — THE READOUT AT THE 1208 pt WINDOW FLOOR
  // ═════════════════════════════════════════════════════════════════════════
  {
    const frame = await must("debug.windowFrame", { width: 1208 });
    await sleep(800);
    await showNote(mid);
    await stage({ act: "hover", ...bodyOf(mid) });
    const narrow = await echo();
    captures.floor = (await captureLook(cmd, join(OUT, "c5a4b-6-floor-1208.png"))).path;
    looks.floor = { width: frame.width, minWidth: frame.minWidth, readout: narrow.wobble.readout };
    check("at the window floor the palette still reports the Wobble readout (the capture shows whether it fits)",
      frame.width === 1208 && narrow.wobble.readout.length > 0,
      `window ${frame.width} (floor ${frame.minWidth}); readout "${narrow.wobble.readout}"`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 7b — (C5b-4b) THE READOUT MID-DRAG AT THE 1208 pt FLOOR: the palette's
  // longest line where the palette is narrowest. Section 4's drag on the same
  // note, so the state is one this gate already proves at full width.
  // ═════════════════════════════════════════════════════════════════════════
  await showNote(made);
  {
    const b = bodyOf(made);
    const h0 = await history();
    await stage({ act: "hover", ...b });
    await stage({ act: "press", x: b.x, y: b.y });
    for (const [dx, dy] of [[6, 0], [20, 0], [34, -6], [40, -14]]) {
      await stage({ act: "drag", x: b.x + dx, y: b.y + dy });
    }
    const narrowDrag = await echo();
    const frameNow = await must("debug.windowFrame", {});   // bare: reads, never writes
    captures.floorMidDrag = (await captureLook(cmd, join(OUT, "c5a4b-7-floor-1208-mid-drag.png"))).path;
    looks.floorMidDrag = {
      width: frameNow.width, phase: narrowDrag.wobble.phase, readout: narrowDrag.wobble.readout,
      help: narrowDrag.interaction.toolHelp,
    };
    check("at the window floor, MID-DRAG, the palette reports the drag's readout (the capture shows whether it fits)",
      frameNow.width === 1208 && narrowDrag.wobble.dragging === true && narrowDrag.wobble.readout.length > 0
        && narrowDrag.interaction.dragReadout === narrowDrag.wobble.readout,
      `window ${frameNow.width}; phase ${narrowDrag.wobble.phase}; readout "${narrowDrag.wobble.readout}"; `
      + `help "${narrowDrag.interaction.toolHelp}"`);
    await stage({ act: "release", x: b.x + 40, y: b.y - 14 });
    if ((await history()).length > h0.length) { await must("edit.undo", {}); await sleep(300); }
  }
  writeFileSync(join(OUT, "c5a4b-looks.json"), JSON.stringify({ captures, looks }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
  console.log(`looks: ${join(OUT, "c5a4b-looks.json")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { session.ws.close(); } catch { /* ignore */ }
  stopLook(GATE);
  console.log("staging stopped (pidfile-exact)");
}
{
  const LOG = join(process.env.HOME ?? "", "Library/Logs/DAWPro/main-actor-wedge.log");
  let text = null;
  try { text = readFileSync(LOG, "utf8"); } catch (e) { console.log(`wedge log: unreadable (${e.code}) — ${LOG}`); }
  if (text !== null) {
    const mine = text.split("\n").filter((l) => l.includes(` pid=${session.pid} `));
    console.log(`wedge log: ${mine.length} line(s) from staging pid ${session.pid}`
      + (mine.length ? `\n        ${mine.join("\n        ")}` : ""));
  }
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
