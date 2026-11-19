#!/usr/bin/env node
// CHAPTERS 3–6 — the note editor, a take made sour ON PURPOSE, Tune to Melody,
// Hard Tune, keeping a low voice's size, and the Voice tool. Every act goes
// through the editor's / card's own staged hand (debug.pitchEditor,
// debug.tuneVocal), every still is a debug.captureUI, every quoted sentence is
// read from the app's echo into work/quotes-tune.json, and every state the
// film plays is SAVED (work/states/<state>/) so renders and screen recordings
// open exactly what the stills show.
//
//   node tune.mjs [--no-shots]
//
// States written: sour, tuned, hard, octave-keep, octave-off, deeper.
// ⚠ ONE WIRE SCRIPT AT A TIME (project.open replaces what is open).
import { open, close, cmd, sleep } from "./wire.mjs";
import { shot as rawShot } from "./shoot.mjs";
import { seedSung, openState, saveState, openEditor, pe, steps, noteAtTime,
         edits, dump, VOCAL } from "./states.mjs";

const SHOTS = !process.argv.includes("--no-shots");
const shot = async (n) => { if (SHOTS) await rawShot(n); };
const Q = {};                                   // every word quoted on screen
const must = (cond, msg) => { if (!cond) throw new Error(msg); };

// The four phrase-final notes, by their time in the take (seconds from the
// clip's start): "door", "to-NIGHT", "two", "bright". Measured on the sung
// take's note table (work/edits-sour.json): 2.96–3.95, 7.74–8.77,
// 12.61–13.60, 17.34–18.74.
const ENDS = [3.4, 8.2, 13.1, 18.0];
const SOUR_CENTS = 70;

async function tune(preset, label) {
  // Tune to Melody, the card driven the way a person drives it.
  const o = await cmd("debug.tuneVocal", { clipId: VOCAL, melody: { open: true, preset } });
  const card = o.melodyCard;
  must(card && card.phase === "choosing", `${label}: the card did not open`);
  const lead = card.choices.find((c) => c.id === card.selected);
  must(lead && lead.name === "Lead", `${label}: the card picked ${lead?.name}, not Lead`);
  Q[`${label}Card`] = { menu: o.melodyMenu, source: card.source, choices: card.choices.map((c) => [c.name, c.detail]),
                        selected: lead.name, preset: card.preset, presetLine: card.presetLine,
                        matchOctave: card.matchOctave, octaveLine: card.octaveLine };
  await shot(`${label}-card`);
  let r = await cmd("debug.tuneVocal", { clipId: VOCAL, melody: { apply: true } });
  if (r.melodyCard.phase === "waitingForAnswer") {
    Q[`${label}Replace`] = r.pending;
    await shot(`${label}-replace`);
    r = await cmd("debug.tuneVocal", { clipId: VOCAL, answer: "replace" });
  }
  for (let i = 0; i < 90 && !["finished", "refused"].includes(r.melodyCard.phase); i++) {
    await sleep(1000);
    r = await cmd("debug.tuneVocal", { clipId: VOCAL });
  }
  must(r.melodyCard.phase === "finished", `${label}: ${JSON.stringify(r.melodyCard.result)}`);
  Q[`${label}Done`] = r.melodyCard.result;
  await shot(`${label}-done`);
  await cmd("debug.tuneVocal", { clipId: VOCAL, melody: { close: true } });
  return r.melodyCard.result;
}

await open();
try {
  seedSung();

  // ================================================ A. the note editor (sung)
  await openState("sung");
  let e = await openEditor({ rowHeight: 14 });
  Q.selectionAfterOpen = e.selection.count;        // a defect probe (see README)
  e = await steps([{ act: "clearSelection" }, { act: "tool", tool: "pointer" }]);
  Q.editor = { status: e.chrome.statusText, caption: e.chrome.captionText,
               presets: e.chrome.presetLabels.map((l, i) => [l, e.chrome.presetSummaries[i]]),
               toolHelp: e.interaction.toolHelp, palette: e.interaction.paletteLabels,
               hear: e.audition.toggle, singer: e.singer?.voice };
  await shot("t01-editor");

  // HEAR — press a note and it plays (the audition router says what happened).
  const door = noteAtTime(e, ENDS[0]);
  await pe({ act: "press", x: door.cx, y: door.cy });
  await sleep(700);
  e = await pe({});
  Q.hear = { outcome: e.audition.router.lastOutcome, source: e.audition.router.lastSource,
             note: { startSeconds: door.startSeconds, endSeconds: door.endSeconds, midi: door.playedMidi } };
  must(e.audition.router.lastOutcome === "sounded", `press did not sound: ${JSON.stringify(e.audition.router)}`);
  await shot("t02-hear");
  await pe({ act: "release", x: door.cx, y: door.cy });     // a click: selects it

  // THE CUT LINE — the Split tool, hovered over the held "door" note. Nothing
  // is cut: the point is the line and its two lengths, read from the echo.
  e = await steps([{ act: "tool", tool: "scissors" },
                   { act: "hover", x: door.x + door.w * 0.5, y: door.cy }]);
  Q.cutLine = e.cutPreview;
  Q.splitHelp = e.interaction.toolHelp;
  must(e.cutPreview.visible, `no cut line: ${JSON.stringify(e.cutPreview)}`);
  await shot("t02b-cutline");
  await steps([{ act: "hoverEnd" }, { act: "tool", tool: "pointer" }]);

  // SELECT the four phrase ends (⇧-click adds one).
  for (const t of ENDS.slice(1)) {
    const n = noteAtTime(e, t);
    await steps([{ act: "press", x: n.cx, y: n.cy, shift: true },
                 { act: "release", x: n.cx, y: n.cy, shift: true }]);
  }
  e = await pe({});
  must(e.selection.count === 4, `selected ${e.selection.count}, not 4`);
  Q.selected = e.selection.summary;
  await shot("t03-selected");

  // SOUR, ON PURPOSE: ⌥-drag one selected note up; the other three follow.
  // 14 pt per semitone, so 70 cents = 9.8 pt.
  const night = noteAtTime(e, ENDS[1]);
  const dy = (SOUR_CENTS / 100) * e.zoom.rowHeight;
  e = await steps([{ act: "press", x: night.cx, y: night.cy, option: true },
                   { act: "drag", x: night.cx, y: night.cy - dy / 2, option: true },
                   { act: "drag", x: night.cx, y: night.cy - dy, option: true }]);
  Q.sourReadout = e.interaction.dragReadout;
  must(e.interaction.dragReadout === `+${SOUR_CENTS} cents`, `drag reads ${e.interaction.dragReadout}`);
  await shot("t04-dragging");
  await pe({ act: "release", x: night.cx, y: night.cy - dy, option: true });
  const sour = await edits();
  const moved = sour.segments.filter((s) => Math.abs(s.pitchOffsetCents) > 0.5);
  must(moved.length === 4 && moved.every((s) => Math.abs(s.pitchOffsetCents - SOUR_CENTS) < 0.5),
       `sour edit is not 4 notes at +${SOUR_CENTS}: ${JSON.stringify(moved.map((s) => [s.startSeconds, s.pitchOffsetCents]))}`);
  Q.sourNotes = moved.map((s) => [s.startSeconds, s.endSeconds, s.pitchOffsetCents]);
  await shot("t05-sour");
  await saveState("sour");

  // ================================================ B. Tune to Melody (sour)
  Q.ttmResult = await tune("natural", "t06-ttm");
  e = await steps([{ act: "clearSelection" }]);
  Q.tunedBadge = e.chrome.clipBadgeText;
  await shot("t09-tuned");
  await saveState("tuned");

  // ================================================ C. Hard Tune (tuned)
  Q.hardResult = await tune("hardTune", "t10-hard");
  await shot("t11-hard");
  await saveState("hard");

  // ================================================ D. an octave down (tuned)
  await openState("tuned");
  e = await openEditor({ rowHeight: 10 });          // the smallest rows: room for an octave
  Q.selectionAfterReopen = e.selection.count;
  e = await steps([{ act: "clearSelection" }, { act: "tool", tool: "pointer" }, { act: "selectAll" }]);
  Q.selectAll = e.selection.summary;
  const tunedEdits = await edits();
  const two = noteAtTime(e, ENDS[2]);
  const base = two.pitchOffsetCents;
  const readMove = (x) => {
    const m = /^([+-]?\d+) cents$/.exec(x.interaction.dragReadout || "");
    return m ? Math.round((Number(m[1]) - base) / 100) * 100 : 0;
  };
  // A group drag stops at the drawn window's floor; holding at the bottom edge
  // grows a row per tick (autoscroll). Walk there, then settle on -1200.
  let y = two.cy;
  await pe({ act: "press", x: two.cx, y });
  for (let i = 0; i < 60; i++) {
    const cur = await pe({});
    const move = readMove(cur);
    if (move === -1200) break;
    const edge = cur.viewport.offsetY + cur.viewport.viewportH - 1;
    let want = y + ((move + 1200) / 100) * cur.zoom.rowHeight;   // + = further down
    if (move < -1200) want = y - cur.zoom.rowHeight;             // overshot: back up a row
    y = Math.min(want, edge + 1);
    await pe({ act: "drag", x: two.cx, y });
  }
  e = await pe({});
  Q.octaveReadout = e.interaction.dragReadout;
  must(readMove(e) === -1200, `octave drag stopped at ${e.interaction.dragReadout}`);
  await shot("t12-octave-drag");
  await pe({ act: "release", x: two.cx, y });
  const oct = await edits();
  const byId = Object.fromEntries(tunedEdits.segments.map((s) => [s.id, s]));
  const deltas = [...new Set(oct.segments.map((s) => Math.round(s.pitchOffsetCents - byId[s.id].pitchOffsetCents)))];
  must(deltas.length === 1 && deltas[0] === -1200, `octave deltas ${JSON.stringify(deltas)}`);
  must(oct.formantCorrection === 1, `Keep voice size is ${oct.formantCorrection}, not 1`);
  e = await pe({});
  Q.voiceSizeKeep = e.singer.voice;
  await shot("t13-octave-keep");
  await saveState("octave-keep");

  e = await steps([{ act: "singer", control: "voiceTrack", fraction: 0 }, { act: "singer", control: "voiceRelease" }]);
  Q.voiceSizeOff = e.singer.voice;
  must((await edits()).formantCorrection === 0, "Keep voice size did not reach 0");
  await shot("t14-octave-off");
  await saveState("octave-off");

  // ================================================ E. the Voice tool (tuned)
  await openState("tuned");
  e = await openEditor({ rowHeight: 14 });
  e = await steps([{ act: "clearSelection" }, { act: "tool", tool: "voice" }]);
  Q.voiceToolHelp = e.interaction.toolHelp;
  const line4 = e.notes.filter((n) => n.startSeconds >= 14.5 && n.origin !== "unpitched")
                       .map((n) => noteAtTime(e, (n.startSeconds + n.endSeconds) / 2));
  for (const n of line4) {
    await steps([{ act: "press", x: n.cx, y: n.cy }, { act: "drag", x: n.cx, y: n.cy + 50 },
                 { act: "drag", x: n.cx, y: n.cy + 110 }]);
    if (n === line4[line4.length - 1]) {
      const d = await pe({});
      Q.voiceReadout = d.voice.readout;
      await shot("t15-voice-drag");
    }
    await pe({ act: "release", x: n.cx, y: n.cy + 110 });
  }
  const deep = await edits();
  const formanted = deep.segments.filter((s) => s.formantOffsetSemitones);
  must(formanted.length === line4.length && formanted.every((s) => s.formantOffsetSemitones === -6),
       `voice tool: ${JSON.stringify(formanted.map((s) => [s.startSeconds, s.formantOffsetSemitones]))}`);
  const pitchMoved = deep.segments.filter((s) => Math.abs(s.pitchOffsetCents - byId[s.id].pitchOffsetCents) > 0.01);
  must(pitchMoved.length === 0, "the Voice tool moved a pitch");
  Q.voiceNotes = formanted.map((s) => [s.startSeconds, s.endSeconds, s.formantOffsetSemitones]);
  await shot("t16-line-deeper");
  await saveState("deeper");

  dump("quotes-tune", Q);
  console.log(JSON.stringify({ ttm: Q.ttmResult, hard: Q.hardResult, sour: Q.sourNotes, octave: Q.octaveReadout,
                               voice: Q.voiceNotes.length, selectionAfterOpen: Q.selectionAfterOpen,
                               selectionAfterReopen: Q.selectionAfterReopen }, null, 1));
} catch (err) {
  // ⛔ WITHOUT THIS, AN ERROR EXITS 0: the finally below calls process.exit,
  // which ends the process before Node reports the rejection. MEASURED
  // 2026-10-11: tune.mjs died after one still and printed "exit 0".
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
