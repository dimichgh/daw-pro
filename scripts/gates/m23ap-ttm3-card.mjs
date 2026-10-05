// W7-TTM3 GATE — TUNE TO MELODY, M3: the clip menu's "Tune Vocal ▸ Tune to
// Melody…" and its card, LOOKED AT on a REAL app on staging (port 17695 ONLY;
// 17600 is the user's LIVE app and is never touched. Staging is stopped
// PIDFILE-EXACT through `_pitch-editor-look.mjs`'s `stopLook`, never
// pkill/pgrep — its window closes with it).
//
// ⭐ A SPY GATE WITH A SECOND INSTRUMENT. The card says what it shows
// (`debug.tuneVocal`'s `melodyCard` / `melodyMenu` / `pending` echo: every word
// verbatim, the phase, what Apply would do), and the STORE is read back over
// the wire independently (`clip.getPitchEdits`' per-note `detectedHz` +
// `pitchOffsetCents`, `edit.history`, the clip's `contentStamp`) — never one
// instrument. Every action goes through the card's OWN funnels
// (`debug.tuneVocal {melody: {open, pick, preset, matchOctave, apply, close}}`,
// the same calls the card's buttons make), and the replace card is answered
// through its own (`answer: replace|cancel`).
//
// ⭐ THE FIXTURE MAKES "TUNED TO THE MELODY" FALSIFIABLE. The vocal sings ON
// 57 / 59 / 55 (220, 247, 196 Hz) and the "Lead" melody under it plays 58→59
// (it CHANGES under the first sung note) / 60 / 56: a plain preset would move
// nothing (every note is already on a semitone), so a stored +100 / +200 c can
// only be the melody pass.
//
// ⭐ AND "TUNED N NOTES" COUNTABLE. The melody changing under the first sung
// note makes the pass CUT it into two rows (rule 2): 4 stored rows from 3 sung
// notes. The line must say 3 — the notes the person sang (W7-TTM3 follow-up 1).
//
// THE STATES, ALL AT THE 1208 x 640 FLOOR
//   c1 the card just opened: "Lead" first (it was added AFTER "Bass"), both with
//      their note counts (4 and 1), Lead picked, Natural, Match octave on;
//   c2 Hard Tune picked: its own line — and the card must be THE SAME HEIGHT as
//      c1 (every chip's line is laid out, the picked one shown: Gentle and
//      Natural wrap to 2 lines, Tight and Hard Tune 1; a person compares);
//   c3 the result after Apply: one plain line ("Tuned 3 notes to Lead." — 3
//      sung notes, though the pass wrote 4 rows), the green check, the undo note;
//   c4 a hand edit (a split), then Apply: "Replace your hand edits?" naming
//      Tune to Melody, drawn ON TOP of the card (the card dimmed, frozen).
// plus, echo-and-store only: the menu item greyed with its reason on a vocal
// with no melody under it, Cancel (nothing runs, the card returns to choosing),
// Replace (ONE more step), ONE undo puts the clip back, Close.
//
// WHAT THIS DOES NOT PROVE — THE ON-SCREEN CHECKS THAT ARE A PERSON'S
//   • the context menu itself: a staged step cannot open or photograph an
//     NSMenu. Right-click a vocal with no MIDI under it → Tune Vocal: "Tune to
//     Melody…" greyed, with "Add a MIDI melody under this vocal first." as a
//     greyed line under it; over a melody, live, and it opens the card;
//   • ⌫ with the card up does NOT delete the vocal (pinned in source by
//     TuneToMelodySiteTests S4; this gate has no key seam for ⌫);
//   • the picker scrolls past 4 rows (this fixture has 2);
//   • sound: every track is muted.
//
// PRECONDITIONS (the live run only)
//   • AN UNLOCKED SCREEN — checked FIRST. EXIT 3, "PENDING".
//   • PROVENANCE — `.build/debug/DAWApp` newer than every file under
//     `Sources/` and `Package.swift` (with a positive control on the same
//     `find`); else EXIT 2. Build under a heavy slot right before running it.
//
//   node scripts/gates/m23ap-ttm3-card.mjs              # the live gate (staging)
//   node scripts/gates/m23ap-ttm3-card.mjs --selftest   # HEADLESS: no app, no port
//
// --selftest runs the SAME check functions the live run uses against a canned
// GOOD trace (every check must pass) and against PLANTED bad traces (each must
// fail the check it targets). It launches nothing and imports no staging code.
//
// Env: M23AP_TTM3_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-ttm3-card).
//
// EXIT: 0 green, 1 red, 2 proves nothing (a refused precondition), 3 pending
//       (the screen is locked; nothing was launched). --selftest: 0 when the
//       good trace passes and every plant is caught, 1 otherwise (through
//       `verdict`, which also records coverage in the corpus baseline unless
//       CORPUS_BASELINE points elsewhere).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { verdict } from "./_verdict.mjs";

const GATE = "m23ap-ttm3-card";
const SELFTEST = process.argv.includes("--selftest");
const OUT = process.env.M23AP_TTM3_OUT || "/tmp/m23ap-ttm3-card";

// The words, verbatim from `TuneToMelodyCopy` (Sources/DAWAppKit/TuneToMelodyCard.swift)
// and `PitchPresetReplaceCopy`: a changed word is a changed gate (edit both together).
const WORDS = {
  menuTitle: "Tune to Melody…",
  menuHelp: "Tune each sung note to the MIDI melody playing under it.",
  noMelody: "Add a MIDI melody under this vocal first.",
  preset: {
    gentle: "Where one note runs into the next, a little of your own singing can show through. Vibrato stays.",
    natural: "Where one note runs into the next, only a trace of your own singing can show through. Vibrato stays.",
    tight: "Each note stays tuned right up to the next one. Vibrato stays.",
    hardTune: "Each note stays tuned right up to the next, with less vibrato. The robot effect.",
  },
  octaveOn: "Each note goes to the melody's note in your own range, so a low voice can follow a high melody.",
  octaveOff: "Each note goes to the melody's note as written, even when that is much higher or lower than you sang.",
  replaceTitle: "Replace your hand edits?",
  step: "Auto-Correct Pitch",
};
const OVERCLAIM = /exact|perfect|precise/i;
const sourceLine = (vocal, track) => `“${vocal}” on ${track}`;

// The fixture's melody, in beats at 120 BPM (the vocal's legs start after its
// 0.12 s noise burst: 0.24 beats). The first sung leg (beats 0.24-3.24) has TWO
// melody notes under it, so the pass cuts it: 4 rows, 3 sung notes.
const LEAD = [
  { pitch: 58, startBeat: 0.24, lengthBeats: 1.5 },
  { pitch: 59, startBeat: 1.74, lengthBeats: 1.5 },
  { pitch: 60, startBeat: 3.24, lengthBeats: 3 },
  { pitch: 56, startBeat: 6.24, lengthBeats: 3 },
];
const SUNG_NOTES = 3;
const STORED_ROWS = 4;
const BASS = [{ pitch: 45, startBeat: 0.24, lengthBeats: 9 }];

// ═══════════════════════════════════════════════════════════════════════════
// THE CHECKS — pure functions of a TRACE. The live run fills the trace;
// --selftest feeds canned ones. One list, so the self-test exercises exactly
// what the live run asserts.
// ═══════════════════════════════════════════════════════════════════════════
const card = (e) => e?.melodyCard ?? null;
const midiOf = (hz) => 69 + 12 * Math.log2(hz / 440);
function leadUnder(seconds) {
  const beat = seconds * 2;
  return LEAD.find((n) => beat >= n.startBeat && beat < n.startBeat + n.lengthBeats) ?? null;
}

export function evaluate(t) {
  const out = [];
  const check = (id, name, fn) => {
    let ok = false;
    let detail = "";
    try {
      const r = fn();
      ok = r.ok === true;
      detail = r.detail ?? "";
    } catch (err) {
      detail = `threw: ${err?.message ?? err}`;
    }
    out.push({ id, name, ok, detail });
  };

  check("menuOff", "menu: on a vocal with no MIDI note under it, Tune to Melody… is greyed and says why", () => {
    const m = t.lonely?.melodyMenu;
    return {
      ok: m?.title === WORDS.menuTitle && m?.enabled === false && m?.help === WORDS.noMelody
        && card(t.lonely) === null,
      detail: JSON.stringify(m ?? null),
    };
  });

  check("menuOn", "menu: over a melody the item is live, with its help", () => {
    const m = t.menuOn?.melodyMenu;
    return { ok: m?.enabled === true && m?.help === WORDS.menuHelp, detail: JSON.stringify(m ?? null) };
  });

  check("opened", "card: Lead first (added after Bass), both with note counts, Lead picked, Natural, Match octave on", () => {
    const c = card(t.opened);
    const names = (c?.choices ?? []).map((x) => x.name);
    const details = (c?.choices ?? []).map((x) => x.detail);
    return {
      ok: JSON.stringify(names) === JSON.stringify(["Lead", "Bass"])
        && JSON.stringify(details) === JSON.stringify(["4 notes under this vocal", "1 note under this vocal"])
        && c.selected === c.choices[0].id && c.preset === "natural" && c.presetLine === WORDS.preset.natural
        && c.matchOctave === true && c.octaveLine === WORDS.octaveOn && c.phase === "choosing"
        && c.canApply === true && c.canClose === true && c.source === sourceLine(t.vocalName, t.vocalTrack),
      detail: JSON.stringify({ names, details, selected: c?.selected, preset: c?.preset, phase: c?.phase,
        source: c?.source }),
    };
  });

  check("chips", "chips: each chip shows its own line, and picking one runs nothing", () => {
    const seen = Object.entries(t.chips ?? {}).map(([p, e]) => [p, card(e)?.preset, card(e)?.presetLine,
      card(e)?.phase, e?.pending ?? null]);
    return {
      ok: seen.length === 4 && seen.every(([p, preset, line, phase, pending]) =>
        preset === p && line === WORDS.preset[p] && phase === "choosing" && pending === null),
      detail: JSON.stringify(seen.map(([p, preset, line]) => [p, preset, line])),
    };
  });

  check("octave", "switch: Match octave off says so; on again says so", () => {
    const off = card(t.octaveOff);
    const on = card(t.octaveOn);
    return {
      ok: off?.matchOctave === false && off?.octaveLine === WORDS.octaveOff
        && on?.matchOctave === true && on?.octaveLine === WORDS.octaveOn,
      detail: JSON.stringify([off?.octaveLine, on?.octaveLine]),
    };
  });

  check("applyNow", "apply with no hand edits runs NOW: no question asked, the card frozen while it tunes", () => {
    const c = card(t.applyNow);
    return {
      ok: t.applyNow?.pending === null
        && (c?.phase === "finished" || (c?.phase === "tuning" && c?.canClose === false && c?.canApply === false)),
      detail: JSON.stringify({ pending: t.applyNow?.pending ?? null, phase: c?.phase, canClose: c?.canClose }),
    };
  });

  check("result", "result: one plain line, tuned to Lead, no far-move note for 1-semitone moves, nothing overclaimed", () => {
    const c = card(t.finished);
    const r = c?.result ?? {};
    return {
      ok: c?.phase === "finished" && r.foundSinging === true && r.tunedNotes >= 1
        && /^Tuned \d+ notes? to Lead\./.test(r.summary ?? "") && r.farMoveNote === null
        && !OVERCLAIM.test(r.summary ?? ""),
      detail: JSON.stringify(r),
    };
  });

  check("store", "store: ONE \"Auto-Correct Pitch\" step, and every stored row now sits on the Lead note under it "
    + "(+1 or +2 semitones: a plain preset would have moved nothing)", () => {
    const before = t.historyBefore ?? [];
    const after = t.historyAfterApply ?? [];
    const sung = (t.storedAfterApply?.segments ?? []).filter((g) => g.origin !== "unpitched" && g.detectedHz > 0);
    const rows = sung.map((g) => {
      const lead = leadUnder((g.startSeconds + g.endSeconds) / 2);
      const now = midiOf(g.detectedHz) + g.pitchOffsetCents / 100;
      return { lead: lead?.pitch ?? null, now: Math.round(now * 100) / 100, cents: g.pitchOffsetCents };
    }).filter((x) => x.lead !== null);
    return {
      ok: after.length === before.length + 1 && after[0] === WORDS.step && rows.length >= 3
        && rows.every((x) => Math.abs(x.now - x.lead) < 0.3)
        && rows.filter((x) => Math.abs(x.cents) > 50).length >= 3,
      detail: `history +${after.length - before.length} (${after[0]}); notes ${JSON.stringify(rows)}`,
    };
  });

  check("sungNotes", `result: the line counts SUNG notes — ${SUNG_NOTES}, though the melody's change under the first `
    + `one made the pass write ${STORED_ROWS} rows`, () => {
    const r = card(t.finished)?.result ?? {};
    const rows = (t.storedAfterApply?.segments ?? []).filter((g) => g.origin !== "unpitched" && g.detectedHz > 0).length;
    return {
      ok: rows === STORED_ROWS && r.tunedNotes === SUNG_NOTES
        && (r.summary ?? "").startsWith(`Tuned ${SUNG_NOTES} notes to Lead.`),
      detail: JSON.stringify({ rows, tunedNotes: r.tunedNotes, summary: r.summary }),
    };
  });

  check("asked", "hand edits: Apply ASKS — the replace card names Tune to Melody; the card waits and cannot close", () => {
    const p = t.asked?.pending;
    const c = card(t.asked);
    return {
      ok: t.handEdited?.clip?.handEditedSinceAutoCorrect === true && p?.tuneToMelody === true
        && p?.title === WORDS.replaceTitle
        && (p?.body ?? "").startsWith(`Tune to Melody tunes all of “${t.vocalName}” from scratch.`)
        && c?.phase === "waitingForAnswer" && c?.canClose === false && c?.canApply === false,
      detail: JSON.stringify({ title: p?.title, body: p?.body, tuneToMelody: p?.tuneToMelody, phase: c?.phase }),
    };
  });

  check("cancel", "Cancel: nothing runs, the card is back to choosing, the hand edit stands", () => {
    const c = card(t.cancelled);
    return {
      ok: t.cancelled?.pending === null && c?.phase === "choosing" && c?.canApply === true
        && (t.historyAfterCancel ?? []).length === (t.historyBeforeAsk ?? []).length
        && t.cancelled?.clip?.handEditedSinceAutoCorrect === true,
      detail: JSON.stringify({ phase: c?.phase, history: (t.historyAfterCancel ?? []).length,
        before: (t.historyBeforeAsk ?? []).length }),
    };
  });

  check("replace", "Replace my edits: the melody pass runs as ONE more step and the hand edit is gone", () => {
    const c = card(t.replaced);
    const h = t.historyAfterReplace ?? [];
    return {
      ok: t.replaced?.pending === null && c?.phase === "finished"
        && h.length === (t.historyBeforeAsk ?? []).length + 1 && h[0] === WORDS.step
        && t.replaced?.clip?.handEditedSinceAutoCorrect === false,
      detail: JSON.stringify({ phase: c?.phase, history: h.slice(0, 2), handEdited: t.replaced?.clip?.handEditedSinceAutoCorrect }),
    };
  });

  check("undo", "Undo (⌘Z): ONE step puts the clip back exactly as it was before Replace", () => {
    const h = t.historyAfterUndo ?? [];
    return {
      ok: h.length === (t.historyAfterReplace ?? []).length - 1 && typeof t.stampBeforeReplace === "string"
        && t.undone?.clip?.contentStamp === t.stampBeforeReplace
        && t.undone?.clip?.handEditedSinceAutoCorrect === true,
      detail: JSON.stringify({ history: h.length, stamp: t.undone?.clip?.contentStamp, want: t.stampBeforeReplace }),
    };
  });

  check("close", "Close: the card goes", () => ({
    ok: t.closed !== undefined && card(t.closed) === null,
    detail: JSON.stringify(card(t.closed)),
  }));

  check("words", "no word the card drew promises an exact landing", () => {
    const all = [];
    for (const e of [t.opened, ...Object.values(t.chips ?? {}), t.octaveOff, t.finished, t.replaced]) {
      const c = card(e);
      if (!c) continue;
      all.push(c.presetLine, c.octaveLine, c.source, c.result?.summary, c.result?.farMoveNote);
    }
    const bad = all.filter((s) => typeof s === "string" && OVERCLAIM.test(s));
    return { ok: all.length >= 10 && bad.length === 0, detail: `${all.length} strings; overclaims ${JSON.stringify(bad)}` };
  });

  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// --selftest: a canned GOOD trace (the shape a correct run produces) and
// PLANTED bad ones, each a single regression a person would care about.
// ═══════════════════════════════════════════════════════════════════════════
function goodTrace() {
  const vocalName = "vocal-fixture-3notes";
  const choices = [
    { id: "track:L", name: "Lead", detail: "4 notes under this vocal", isClip: false, notesUnderVocal: 4 },
    { id: "track:B", name: "Bass", detail: "1 note under this vocal", isClip: false, notesUnderVocal: 1 },
  ];
  const base = {
    vocalClipId: "V", source: sourceLine(vocalName, "TTM3 Vocal"), choices, selected: "track:L",
    preset: "natural", presetLine: WORDS.preset.natural, matchOctave: true, octaveLine: WORDS.octaveOn,
    phase: "choosing", canApply: true, canClose: true, result: {},
  };
  const withCard = (patch, extra = {}) => ({ pending: null, melodyCard: { ...base, ...patch }, ...extra });
  const finishedResult = { summary: "Tuned 3 notes to Lead.", farMoveNote: null, tunedNotes: 3, untouchedNotes: 0,
    farMoves: 0, foundSinging: true };
  const seg = (s, e, hz, cents) => ({ startSeconds: s, endSeconds: e, detectedHz: hz, pitchOffsetCents: cents, origin: "pitched" });
  const chips = {};
  for (const p of ["gentle", "natural", "tight", "hardTune"]) chips[p] = withCard({ preset: p, presetLine: WORDS.preset[p] });
  return {
    vocalName,
    vocalTrack: "TTM3 Vocal",
    lonely: { pending: null, melodyCard: null,
      melodyMenu: { title: WORDS.menuTitle, enabled: false, help: WORDS.noMelody } },
    menuOn: { pending: null, melodyCard: null, melodyMenu: { title: WORDS.menuTitle, enabled: true, help: WORDS.menuHelp } },
    opened: withCard({}),
    chips,
    octaveOff: withCard({ matchOctave: false, octaveLine: WORDS.octaveOff }),
    octaveOn: withCard({}),
    applyNow: withCard({ phase: "tuning", canApply: false, canClose: false }),
    finished: withCard({ phase: "finished", result: finishedResult }),
    historyBefore: ["Add MIDI Clip"],
    historyAfterApply: [WORDS.step, "Add MIDI Clip"],
    storedAfterApply: { segments: [
      { startSeconds: 0, endSeconds: 0.12, detectedHz: 0, pitchOffsetCents: 0, origin: "unpitched" },
      seg(0.13, 0.86, 220.0, 100.4), seg(0.87, 1.6, 220.0, 199.6), seg(1.63, 3.1, 246.9, 99.1),
      seg(3.13, 4.6, 196.0, 100.9)] },
    handEdited: { pending: null, clip: { handEditedSinceAutoCorrect: true } },
    historyBeforeAsk: ["Split Note", WORDS.step, "Add MIDI Clip"],
    asked: { pending: { title: WORDS.replaceTitle, tuneToMelody: true,
      body: `Tune to Melody tunes all of “${vocalName}” from scratch. This replaces the tuning already on this clip, including any note you moved or split by hand.` },
      melodyCard: { ...base, phase: "waitingForAnswer", canApply: false, canClose: false } },
    cancelled: withCard({}, { clip: { handEditedSinceAutoCorrect: true } }),
    historyAfterCancel: ["Split Note", WORDS.step, "Add MIDI Clip"],
    stampBeforeReplace: "stamp-split",
    replaced: withCard({ phase: "finished", result: finishedResult }, { clip: { handEditedSinceAutoCorrect: false, contentStamp: "stamp-melody" } }),
    historyAfterReplace: [WORDS.step, "Split Note", WORDS.step, "Add MIDI Clip"],
    undone: withCard({ phase: "finished", result: finishedResult }, { clip: { handEditedSinceAutoCorrect: true, contentStamp: "stamp-split" } }),
    historyAfterUndo: ["Split Note", WORDS.step, "Add MIDI Clip"],
    closed: { pending: null, melodyCard: null },
  };
}

const PLANTS = [
  { id: "menuOff", what: "the menu item is LIVE on a vocal with no melody under it",
    plant: (t) => { t.lonely.melodyMenu.enabled = true; } },
  { id: "menuOn", what: "the menu item is greyed over a melody",
    plant: (t) => { t.menuOn.melodyMenu.enabled = false; t.menuOn.melodyMenu.help = WORDS.noMelody; } },
  { id: "opened", what: "Lead is not first (project order wins)",
    plant: (t) => { t.opened.melodyCard.choices.reverse(); } },
  { id: "opened", what: "nothing is picked when the card opens",
    plant: (t) => { t.opened.melodyCard.selected = null; } },
  { id: "chips", what: "Hard Tune shows Natural's line (a stale chip line)",
    plant: (t) => { t.chips.hardTune.melodyCard.presetLine = WORDS.preset.natural; } },
  { id: "chips", what: "picking a chip raises the replace card",
    plant: (t) => { t.chips.tight.pending = { title: WORDS.replaceTitle }; } },
  { id: "octave", what: "the switch's line does not change when it is turned off",
    plant: (t) => { t.octaveOff.melodyCard.octaveLine = WORDS.octaveOn; } },
  { id: "applyNow", what: "Apply asks about hand edits on a clip that has none",
    plant: (t) => { t.applyNow.pending = { title: WORDS.replaceTitle }; } },
  { id: "result", what: "the result line overclaims an exact landing",
    plant: (t) => { t.finished.melodyCard.result.summary = "Tuned 3 notes exactly onto Lead."; } },
  { id: "result", what: "a far-move note on 1-semitone moves",
    plant: (t) => { t.finished.melodyCard.result.farMoveNote = "3 notes had to jump a long way to reach the melody."; } },
  { id: "store", what: "the pass ran as a plain preset (nothing moved: the notes sit on 57/59/55)",
    plant: (t) => { for (const g of t.storedAfterApply.segments) g.pitchOffsetCents = 0; } },
  { id: "sungNotes", what: "the line counts the pass's ROWS (4), not the sung notes (3)",
    plant: (t) => { t.finished.melodyCard.result.tunedNotes = 4; t.finished.melodyCard.result.summary = "Tuned 4 notes to Lead."; } },
  { id: "store", what: "the pass took TWO undo steps",
    plant: (t) => { t.historyAfterApply = [WORDS.step, "Tune to Melody", "Add MIDI Clip"]; } },
  { id: "asked", what: "the replace card names the chip, not Tune to Melody",
    plant: (t) => { t.asked.pending.body = t.asked.pending.body.replace("Tune to Melody", "Natural"); } },
  { id: "asked", what: "the card can be closed under the question",
    plant: (t) => { t.asked.melodyCard.canClose = true; } },
  { id: "cancel", what: "Cancel runs the pass anyway",
    plant: (t) => { t.historyAfterCancel = [WORDS.step, ...t.historyAfterCancel]; } },
  { id: "cancel", what: "Cancel leaves the card frozen",
    plant: (t) => { t.cancelled.melodyCard.phase = "waitingForAnswer"; } },
  { id: "replace", what: "Replace applies a plain preset and leaves the hand edit flagged",
    plant: (t) => { t.replaced.clip.handEditedSinceAutoCorrect = true; } },
  { id: "undo", what: "one undo does not put the clip back",
    plant: (t) => { t.undone.clip.contentStamp = "stamp-melody"; } },
  { id: "close", what: "Close leaves the card up",
    plant: (t) => { t.closed.melodyCard = t.opened.melodyCard; } },
  { id: "words", what: "a chip line promises a perfect result",
    plant: (t) => { t.chips.gentle.melodyCard.presetLine = "Perfect pitch on every note."; } },
];

if (SELFTEST) {
  // Every item below is ONE self-check: each good-trace check, the empty-trace
  // control, each plant, and the coverage rule. `ran` counts them all.
  let ran = 0;
  let broken = 0;
  const good = evaluate(goodTrace());
  const goodFails = good.filter((c) => !c.ok);
  console.log(`selftest GOOD trace: ${good.length} checks, ${goodFails.length} failed`);
  for (const c of goodFails) console.log(`  !! GOOD trace failed ${c.id}: ${c.name}\n        ${c.detail}`);
  ran += good.length;
  broken += goodFails.length;
  if (good.length < 15) { console.log(`  !! only ${good.length} checks: one went missing`); ran += 1; broken += 1; }
  // Positive control on the plant mechanism: an EMPTY trace must fail every check.
  const empty = evaluate({});
  const emptyPasses = empty.filter((c) => c.ok);
  console.log(`selftest EMPTY trace: ${empty.length - emptyPasses.length} of ${empty.length} checks fail`
    + (emptyPasses.length ? ` — PASSING ON NOTHING: ${emptyPasses.map((c) => c.id).join(", ")}` : ""));
  ran += 1;
  if (emptyPasses.length > 0) broken += 1;
  const coveredIds = new Set();
  for (const p of PLANTS) {
    const t = goodTrace();
    p.plant(t);
    const r = evaluate(t);
    const target = r.find((c) => c.id === p.id);
    const others = r.filter((c) => !c.ok && c.id !== p.id).map((c) => c.id);
    const caught = target && !target.ok;
    if (caught) coveredIds.add(p.id);
    console.log(`  ${caught ? "caught " : "MISSED "} [${p.id}] ${p.what}`
      + (others.length ? ` (also red: ${others.join(", ")})` : ""));
    ran += 1;
    if (!caught) broken += 1;
  }
  const uncovered = good.map((c) => c.id).filter((id) => !coveredIds.has(id));
  console.log(`checks with no plant: ${uncovered.length ? uncovered.join(", ") : "none"}`);
  ran += 1;
  if (uncovered.length > 0) broken += 1;
  console.log(broken === 0
    ? `SELFTEST PASS — the good trace passes all ${good.length} checks and all ${PLANTS.length} plants are caught`
    : `SELFTEST FAIL — ${broken} problem(s) above`);
  // The m23aw-prepare-headroom precedent: the self-test's own result goes
  // through the ONE verdict primitive (0 pass, 1 a self-check failed).
  verdict({ ran, failed: broken });
}

// ═══════════════════════════════════════════════════════════════════════════
// THE LIVE RUN — staging only. Staging code is imported HERE, so --selftest
// never loads it.
// ═══════════════════════════════════════════════════════════════════════════
const { ROOT, DEFAULT_BINARY, STAGING_DEFAULTS_DOMAIN, sleep } = await import("./_staging.mjs");
const { synthesizeVocalFixture, launchLook, stopLook, makeCmd, captureLook } = await import("./_pitch-editor-look.mjs");
const STAGING_NAME = STAGING_DEFAULTS_DOMAIN;

/** The frontmost app's name AND pid, from lsappinfo (the ntu-voice gate's reader). */
function frontmostApp() {
  const front = spawnSync("lsappinfo", ["front"], { encoding: "utf8" });
  const asn = (front.stdout ?? "").trim();
  if (!asn) return { name: null, pid: null, raw: `lsappinfo front: ${(front.stderr ?? "").trim() || "no output"}` };
  const info = spawnSync("lsappinfo", ["info", "-only", "pid,name", asn], { encoding: "utf8" });
  const raw = (info.stdout ?? "").trim();
  const m = /"LSDisplayName"="([^"]*)"/.exec(raw);
  const p = /"pid"=(\d+)/.exec(raw);
  return { name: m ? m[1] : null, pid: p ? Number(p[1]) : null, raw };
}

// PRECONDITION 1 — AN UNLOCKED SCREEN, BEFORE ANYTHING ELSE
const front0 = frontmostApp();
console.log(`frontmost before anything: ${front0.name ?? `(unreadable: ${front0.raw})`} (pid ${front0.pid})`);
if (front0.name === "loginwindow") {
  console.log("PENDING — the screen is LOCKED (frontmost: loginwindow). Nothing was launched or written.");
  process.exit(3);
}
if (front0.name === null) {
  console.log(`ABORT (proves nothing): lsappinfo did not name the frontmost app (${front0.raw})`);
  process.exit(2);
}
if (front0.name === STAGING_NAME) {
  console.log(`ABORT (proves nothing): a staging app (${STAGING_NAME}) is ALREADY frontmost`);
  process.exit(2);
}

mkdirSync(OUT, { recursive: true });
const liveChecks = [];
const liveCheck = (name, ok, detail) => {
  liveChecks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}
let stagingPid = null;
const stoleFocus = (f) => (stagingPid !== null && f.pid === stagingPid) || f.name === STAGING_NAME
  || (f.name === "Finder" && front0.name !== "Finder");

function captureFacts(path) {
  if (!existsSync(path)) return { exists: false };
  const sha = createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 16);
  const r = spawnSync("ffmpeg", ["-hide_banner", "-i", path, "-vf", "signalstats,metadata=print",
    "-f", "null", "-"], { encoding: "utf8" });
  const text = `${r.stderr ?? ""}${r.stdout ?? ""}`;
  const num = (k) => {
    const m = new RegExp(`lavfi\\.signalstats\\.${k}=([0-9.]+)`).exec(text);
    return m ? Number(m[1]) : null;
  };
  return { exists: true, sha, ymin: num("YMIN"), ymax: num("YMAX"), ffmpegStatus: r.status };
}

// PRECONDITION 2 — PROVENANCE
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

// FIXTURE — three sung notes ON 57 / 59 / 55 after the helper's 0.12 s noise burst
const fixturePath = synthesizeVocalFixture(OUT, {
  notes: [{ hz: 220, seconds: 1.5 }, { hz: 246.94, seconds: 1.5 }, { hz: 196, seconds: 1.5 }],
});

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchLook({ gate: GATE, settleMs: 1500, env: { DAWPRO_STAGING_NO_ACTIVATE: "1" } });
stagingPid = session.pid;
console.log(`staging pid ${session.pid} (skipBuild; DAWPRO_STAGING_NO_ACTIVATE=1); started ${new Date().toISOString()}`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const history = async () => (await must("edit.history", {})).undo;
const fronts = [{ at: "before anything", name: front0.name, pid: front0.pid }];
const noteFront = (at) => {
  const f = frontmostApp();
  fronts.push({ at, name: f.name ?? `(unreadable: ${f.raw})`, pid: f.pid });
  return f;
};

let exitCode = null;
const captures = {};
const facts = {};
const trace = {};
async function shoot(key, file) {
  const shot = await captureLook(cmd, join(OUT, file));
  captures[key] = shot.path;
  facts[key] = { ...captureFacts(shot.path), appActive: shot.appActive, width: shot.width, height: shot.height };
  return shot;
}

try {
  {
    const f = noteFront("after the launch");
    liveCheck("FOCUS — the launch did not take the user's focus (lsappinfo)",
      f.name !== null && f.pid !== null && !stoleFocus(f),
      `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  }

  // ── a NAMED project of this gate's own: a vocal, "Bass" then "Lead" under it, a lonely vocal later
  await must("project.new", { discardChanges: true });
  await must("transport.setTempo", { bpm: 120 });
  const vocalTrack = await must("track.add", { name: "TTM3 Vocal", kind: "audio" });
  const vocal = await must("clip.addAudio", { trackId: vocalTrack.id, path: fixturePath, atBeat: 0 });
  const lonely = await must("clip.addAudio", { trackId: vocalTrack.id, path: fixturePath, atBeat: 40 });
  const bass = await must("track.add", { name: "Bass", kind: "instrument" });
  await must("clip.addMIDI", { trackId: bass.id, name: "Bass line", atBeat: 0, lengthBeats: 10, notes: BASS });
  const lead = await must("track.add", { name: "Lead", kind: "instrument" });
  await must("clip.addMIDI", { trackId: lead.id, name: "Lead line", atBeat: 0, lengthBeats: 10, notes: LEAD });
  for (const t of [vocalTrack, bass, lead]) await must("track.setMute", { trackId: t.id, muted: true });
  const projectPath = join(OUT, "TTM3 Tune to Melody.dawproj");
  await must("project.save", { path: projectPath });
  trace.vocalName = vocal.name;
  trace.vocalTrack = vocalTrack.name ?? "TTM3 Vocal";
  console.log(`project: ${projectPath} — vocal ${vocal.id.slice(0, 8)} "${vocal.name}", lonely ${lonely.id.slice(0, 8)}`);

  const tune = (params) => must("debug.tuneVocal", { clipId: vocal.id, ...params });
  const melody = (block) => tune({ melody: block });
  async function untilPhase(phases, ms = 60_000) {
    const deadline = Date.now() + ms;
    let e = await tune({});
    while (!phases.includes(e.melodyCard?.phase) && Date.now() < deadline) {
      await sleep(250);
      e = await tune({});
    }
    return e;
  }

  const frame = await must("debug.windowFrame", { width: 1208, height: 640 });
  console.log(`window: ${JSON.stringify(frame)}`);
  await sleep(800);

  // ── the menu, both ways (echo only: a context menu is not a staged picture)
  trace.lonely = await must("debug.tuneVocal", { clipId: lonely.id });
  trace.menuOn = await tune({});

  // ── c1: the card opens
  trace.opened = await melody({ open: true });
  await sleep(400);
  await shoot("c1", "ttm3-c1-card-open-1208x640.png");

  // ── the chips (c2: Hard Tune), the switch
  trace.chips = {};
  for (const p of ["gentle", "tight", "hardTune", "natural"]) {
    trace.chips[p] = await melody({ preset: p });
    if (p === "hardTune") {
      await sleep(300);
      await shoot("c2", "ttm3-c2-hard-tune-1208x640.png");
    }
  }
  trace.octaveOff = await melody({ matchOctave: false });
  trace.octaveOn = await melody({ matchOctave: true });

  // ── Apply with no hand edits: runs now; c3 the result
  trace.historyBefore = await history();
  trace.applyNow = await melody({ apply: true });
  trace.finished = await untilPhase(["finished", "refused"]);
  trace.historyAfterApply = await history();
  trace.storedAfterApply = await must("clip.getPitchEdits", { clipId: vocal.id });
  {
    const rows = (trace.storedAfterApply.segments ?? []).filter((g) => g.origin !== "unpitched" && g.detectedHz > 0);
    if (rows.length !== STORED_ROWS) {
      refuseRun(`the pass stored ${rows.length} sung row(s), not ${STORED_ROWS} (3 legs + the cut under the first) — `
        + "a fixture fact, not a finding about the card");
    }
  }
  await sleep(300);
  await shoot("c3", "ttm3-c3-result-1208x640.png");

  // ── a hand edit (a split), then Apply: the replace card on top (c4); Cancel; Apply + Replace
  {
    const sung = (trace.storedAfterApply.segments ?? []).filter((g) => g.origin !== "unpitched" && g.detectedHz > 0)
      .sort((a, b) => a.startSeconds - b.startSeconds);
    if (sung.length < 2) refuseRun(`the pass stored ${sung.length} sung note(s) — a fixture fact, not a finding`);
    const g = sung[1];
    await must("clip.splitNote", { clipId: vocal.id, segmentId: g.id, atSourceSeconds: (g.startSeconds + g.endSeconds) / 2 });
  }
  trace.handEdited = await tune({});
  if (trace.handEdited.clip?.handEditedSinceAutoCorrect !== true) {
    refuseRun("the split did not register as a hand edit — a fixture fact, not a finding about the card");
  }
  trace.historyBeforeAsk = await history();
  trace.stampBeforeReplace = trace.handEdited.clip?.contentStamp ?? null;
  trace.asked = await melody({ apply: true });
  await sleep(400);
  await shoot("c4", "ttm3-c4-replace-card-on-top-1208x640.png");
  trace.cancelled = await tune({ answer: "cancel" });
  trace.historyAfterCancel = await history();
  await tune({ melody: { apply: true }, answer: "replace" });
  trace.replaced = await untilPhase(["finished", "refused"]);
  trace.historyAfterReplace = await history();

  // ── ONE undo
  await must("edit.undo", {});
  await sleep(300);
  trace.undone = await tune({});
  trace.historyAfterUndo = await history();

  // ── Close
  trace.closed = await melody({ close: true });

  for (const c of evaluate(trace)) liveCheck(c.name, c.ok, c.detail);

  {
    const f = noteFront("after the last capture");
    liveCheck("FOCUS — no capture took the user's focus (lsappinfo), and every capture reports the app INACTIVE",
      f.name !== null && !stoleFocus(f) && Object.values(facts).every((x) => x.appActive === false),
      `frontmost ${f.name} (pid ${f.pid}); appActive ${JSON.stringify(Object.fromEntries(Object.entries(facts).map(([k, v]) => [k, v.appActive])))}`);
  }
  {
    const shas = Object.entries(facts).map(([k, v]) => [k, v.sha]);
    const dup = shas.filter(([, a], i) => shas.findIndex(([, b]) => b === a) !== i);
    liveCheck("every capture exists, is not blank, and no two states share one picture (none is stale)",
      Object.keys(facts).length === 4
        && Object.values(facts).every((x) => x.exists && x.ymax !== null && x.ymin !== null && x.ymax - x.ymin > 40)
        && dup.length === 0,
      `${Object.keys(facts).length} captures; duplicates ${JSON.stringify(dup)}`);
  }
  writeFileSync(join(OUT, "ttm3-card-trace.json"), JSON.stringify({ captures, facts, trace, fronts }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
  console.log(`trace: ${join(OUT, "ttm3-card-trace.json")}`);
  console.log("A PERSON LOOKS: c1 vs c2 the card the SAME height; c3 the green result line; c4 the replace card "
    + "ON TOP of the dimmed card. And on screen (no staged step can): the greyed menu item with its reason line, "
    + "and ⌫ with the card up leaving the vocal where it is.");
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { session.ws.close(); } catch { /* ignore */ }
  stopLook(GATE);
  console.log("staging stopped (pidfile-exact); its window closed with it");
  const f = noteFront("after the stop");
  console.log(`frontmost after the stop: ${f.name ?? f.raw} (pid ${f.pid}); before: ${front0.name} (pid ${front0.pid})`);
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: liveChecks.length, failed: liveChecks.filter((c) => !c.ok).length });
