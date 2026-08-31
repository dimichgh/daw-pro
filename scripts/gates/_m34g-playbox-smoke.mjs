// m34-g SMOKE — PLAYBOX, across the LIVE wire, on staging 17695.
//
// ══ WHAT THIS PROVES, AND WHAT IT CANNOT ═══════════════════════════════════
//
// The user's words: *"I like that light activation with presets and it would be
// nice to have a playbox mode where AI would pre-generate next series of lights
// to play and record (activate with mode switch)."*
//
// ⭐⭐⭐ **THE POINT IS NOT TECHNICAL: THIS INVERTS THE USUAL AI-MUSIC
// RELATIONSHIP. The AI produces the INVITATION; the HUMAN produces the
// PERFORMANCE.** So the closing leg of this gate is not "the lights are right" —
// it is a RECORDED TAKE read back out of the clip with `clip.getNotes`. A gate
// that only checked lights would not have shown that anything was played.
//
// Four things are asserted that nothing else in this tree can see:
//
//   1. **THE LOOK-AHEAD QUEUE, and it closes a defect m34-i could only state.**
//      Four Chords `[1,5,6,4]` and Doo-Wop `[1,6,4,5]` light the same four
//      degrees AND both open on I, so with only a moving border two of the three
//      presets are identical AT REST. The queue distinguishes them before a note
//      is played. The COUNTS are pinned — exactly one border, exactly three queue
//      marks, on disjoint cells — because the bug this surface keeps re-earning
//      is a COUNT bug (ten badges where four were meant) that only a screenshot
//      could see.
//   2. **THREE MODES, THREE DIFFERENT ANSWERS to the same off-plan chord.** A
//      three-position switch with two identical positions is a UI that lies.
//   3. **⛔ A CUE, NEVER A GATE, IN EVERY MODE.** An off-plan chord performs,
//      sounds a full voicing, and reaches the store — in all three.
//   4. **PLAYBOX GENERATES WITHOUT AN API KEY AND SAYS SO.**
//
// ⛔⛔ **IT DRIVES `{playbox:"local"}` AND NEVER `"ai"`.** A staging app inherits
// this machine's environment: driving the AI path would spend a real Anthropic
// call on every run, and would take a DIFFERENT branch on a machine with no key
// — the worst property a gate can have. The AI leg is unit-tested against a
// scripted fake (`PlayboxModelTests`, `ChordProgressionProviderTests`).
//
// ⛔ **IT CANNOT SEE A PIXEL**, and the queue is a pixel. So it does the one
// thing that reduces a pixel to a number — it pins the COUNTS — and it CAPTURES
// the strip in each of the three modes for a human to open. **The captures are
// written for a human to look at; this gate does not judge their contents.**
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sleep, buildOrAbort, startStaging, stopStaging, connect, verdict,
} from "./_staging.mjs";

const GATE = "m34g-playbox-smoke";
const SHOTS = process.env.M34G_SHOT_DIR ?? join(tmpdir(), "m34g-playbox-shots");
mkdirSync(SHOTS, { recursive: true });

buildOrAbort({ label: "building staging binary (m34-g)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34g${++n}`;
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
const bordered = s => cells(s).filter(c => c.next === true);
const queued = s => cells(s).filter(c => c.queue !== null && c.queue !== undefined);
const borderKey = s => bordered(s).map(c => c.key).join("+") || "-";
/// The whole marked row as `KEY=rank`, cue first. This ONE string is what tells
/// Four Chords from Doo-Wop at rest, which is the defect this item closes.
const queueMap = s => {
  const out = {};
  for (const c of bordered(s)) out[c.key] = 0;
  for (const c of queued(s)) out[c.key] = c.queue;
  return out;
};
/// ⚠️ **COMPARED BY RANK ORDER, NOT BY `JSON.stringify`.** Measured on the first
/// run: the seam returns the cells in KEY order, so `stringify` produced
/// `{"A":0,"F":3,"G":1,"H":2}` and an equality against a hand-written
/// `{"A":0,"G":1,...}` failed on three legs whose DATA was exactly right. The
/// thing being asserted is "which key is at which rank", so that is what this
/// spells: `A@0>G@1>H@2>F@3`, sorted by rank.
const rowSignature = s => Object.entries(queueMap(s))
  .sort((a, b) => a[1] - b[1])
  .map(([k, r]) => `${k}@${r}`)
  .join(">");
const state = async (params = {}) => body(await cmd("debug.musicalTyping", params));
/// The cue key out of a row signature (`A@0>G@1>…` -> `A`).
const borderKeyOf = signature => signature.split("@")[0];

/// Read the marks and pin BOTH counts in the same breath. A helper that returned
/// only the first match would have been perfectly happy with ten of them.
function marks(s, where, expectQueue) {
  const b = bordered(s), q = queued(s);
  ok(b.length === 1, `exactly ONE bordered cell — ${where}`,
     `${b.length}: ${JSON.stringify(b.map(c => c.key))}`);
  ok(q.length === expectQueue,
     `exactly ${expectQueue} queue marks — ${where}`,
     `${q.length}: ${JSON.stringify(q.map(c => `${c.key}=${c.queue}`))}`);
  ok(b.every(c => c.queue === null || c.queue === undefined),
     `⛔ no cell is BOTH bordered and queued — ${where}`,
     JSON.stringify(b.map(c => [c.key, c.queue])));
  return b[0];
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
  await cmd("project.new", { name: "m34g-playbox-smoke" });
  const t = body(await cmd("track.add", { name: "Keys", kind: "instrument" }));
  const trackID = (t.track ?? t)?.id;
  ok(!!trackID, "instrument track added", JSON.stringify(t).slice(0, 200));
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: trackID });
  await cmd("debug.musicalTyping", { enable: true });
  await cmd("debug.musicalTyping", { playMode: "chords" });

  // ══ 1. THE DEFAULT IS THE MODE THE USER WAS TOLD WOULD LEAD ═════════════
  let s = await state({});
  ok(s.advanceModeSetting === "free",
     "⭐ the default advance mode is LIGHTS-RUN-AHEAD, as the user was told",
     String(s.advanceModeSetting));
  ok(s.queueDepth === 3,
     "…and the queue shows three chords beyond the cue — one full four-bar loop",
     String(s.queueDepth));

  // ══ 2. ⭐⭐⭐ THE QUEUE TELLS THE PRESETS APART *AT REST* ════════════════
  // m34-i's own close: "Four Chords and Doo-Wop BOTH OPEN ON I, so two of the
  // three still look identical until the first chord is played." That is the
  // limit this leg closes, and it closes it with NO note played.
  const atRest = {};
  for (const id of ["four-chords", "doo-wop", "pop-punk"]) {
    s = await state({ progression: id });
    atRest[id] = rowSignature(s);
    ok(borderKey(s) === (id === "pop-punk" ? "H" : "A"),
       `${id} opens where the preset says it does`, borderKey(s));
    marks(s, `${id} at rest`, 3);
  }
  ok(borderKeyOf(atRest["four-chords"]) === borderKeyOf(atRest["doo-wop"]),
     "⚠️ THE PREMISE, MEASURED: Four Chords and Doo-Wop still share a CUE (both open on I)",
     JSON.stringify([atRest["four-chords"], atRest["doo-wop"]]));
  ok(atRest["four-chords"] !== atRest["doo-wop"],
     "⭐⭐⭐ …and the QUEUE tells them apart anyway, before a note is played",
     JSON.stringify([atRest["four-chords"], atRest["doo-wop"]]));
  ok(atRest["four-chords"] === "A@0>G@1>H@2>F@3",
     "Four Chords queues I V vi IV", atRest["four-chords"]);
  ok(atRest["doo-wop"] === "A@0>H@1>F@2>G@3",
     "Doo-Wop queues I vi IV V", atRest["doo-wop"]);
  ok(new Set(Object.values(atRest)).size === 3,
     "⭐ three presets, three DISTINCT marked rows, all at rest",
     JSON.stringify(atRest));

  // ⚠️ THE HONEST COST OF ONE-CELL-PER-DEGREE, pinned rather than glossed: a
  // three-chord loop cannot queue three without re-showing its own cue.
  s = await state({ progression: "ii-v-i" });
  marks(s, "ii-V-I (a three-chord loop)", 2);

  // ══ 3. THE QUEUE MOVES WITH THE PERFORMANCE ═════════════════════════════
  s = await state({ progression: "four-chords" });
  await cmd("debug.musicalTyping", { press: "A" });
  await cmd("debug.musicalTyping", { release: "A" });
  s = await state({});
  ok(rowSignature(s) === "G@0>H@1>F@2>A@3",
     "⭐ playing the cue rotates the WHOLE marked row, wrapping onto the loop's top",
     rowSignature(s));
  marks(s, "after playing I", 3);

  // ══ 4. ⛔⛔ THREE MODES, THREE ANSWERS — AND A CUE, NEVER A GATE, IN ALL ══
  const answers = {};
  for (const mode of ["onMatch", "onBeat", "free"]) {
    await cmd("debug.musicalTyping", { progression: "four-chords" });
    s = await state({ advanceMode: mode });
    ok(s.advanceModeSetting === mode && s.advanceMode === mode,
       `the switch and the player agree on ${mode}`,
       JSON.stringify([s.advanceModeSetting, s.advanceMode]));
    ok(borderKey(s) === "A", `${mode} opens on the cue`, borderKey(s));
    // "S" is ii — DIM, off-plan in every mode.
    s = await state({ press: "S" });
    ok(s.decision === "performed",
       `⛔⛔ ${mode}: an off-plan key still PERFORMS`, String(s.decision));
    ok((s.sounding ?? []).length === 4,
       `⛔⛔ ${mode}: …and sounds a FULL chord`, JSON.stringify(s.sounding));
    ok((s.storeHeldPitches ?? []).length === 4,
       `⛔⛔ ${mode}: …which reached the store`, JSON.stringify(s.storeHeldPitches));
    await cmd("debug.musicalTyping", { release: "S" });
    s = await state({});
    answers[mode] = s.sequenceStep;
    await shot(`mode-${mode}`);
  }
  ok(answers.onMatch === 1, "WAIT-FOR-YOU waited", String(answers.onMatch));
  ok(answers.free === 2, "LIGHTS-RUN-AHEAD consumed a suggestion", String(answers.free));
  ok(answers.onBeat === 1, "ON-THE-BEAT ignored the note-on", String(answers.onBeat));
  ok(new Set(Object.values(answers)).size >= 2,
     "⛔ the three positions are not all the same — the switch is not decorative",
     JSON.stringify(answers));

  // ══ 5. ⭐⭐ ON-THE-BEAT, DRIVEN — the mode m34-i shipped BLIND ═══════════
  // m34-i's own close: "the heldInk flip that keeps the border visible on a
  // SOUNDING cell … is defensive code for m34-g's on-the-beat mode and is
  // covered by no pixel." This is where it becomes real: hold the cued chord,
  // tick the beat onto it, and CAPTURE it.
  await cmd("debug.musicalTyping", { progression: "four-chords" });
  await cmd("debug.musicalTyping", { advanceMode: "onBeat" });
  s = await state({ beat: true });
  ok(s.beatMovedCursor === true, "⭐ a downbeat MOVES the cue in on-the-beat mode",
     String(s.beatMovedCursor));
  ok(borderKey(s) === "G" && s.sequenceStep === 2,
     "…onto V", JSON.stringify([borderKey(s), s.sequenceStep]));
  // Now HOLD V and leave the border on it — the bordered-and-sounding state.
  s = await state({ press: "G" });
  ok((s.sounding ?? []).length === 4, "the cued chord is held", JSON.stringify(s.sounding));
  const holding = cells(s).find(c => c.key === "G");
  ok(holding?.next === true,
     "⭐⭐ THE BORDER IS ON A CELL THAT IS SOUNDING — the state m34-i could not stage",
     JSON.stringify([holding?.key, holding?.next]));
  await shot("border-on-a-sounding-cell");
  await cmd("debug.musicalTyping", { release: "G" });
  // …and the beat keeps going without a note being played at all.
  await cmd("debug.musicalTyping", { beat: true });
  s = await state({ beat: true });
  ok(s.sequenceStep === 4,
     "⭐ the click alone walks the cue — nothing had to be played",
     String(s.sequenceStep));
  // ⛔ The other two modes REFUSE the tick, so the switch means something here too.
  await cmd("debug.musicalTyping", { advanceMode: "onMatch" });
  s = await state({ beat: true });
  ok(s.beatMovedCursor === false, "⛔ a downbeat does NOT move a wait-for-you cue",
     String(s.beatMovedCursor));
  await cmd("debug.musicalTyping", { advanceMode: "free" });
  s = await state({ beat: true });
  ok(s.beatMovedCursor === false, "⛔ …nor a lights-run-ahead one",
     String(s.beatMovedCursor));

  // ══ 5b. ⭐⭐⭐ THE REAL TICK CHAIN, END TO END — NOT THE SYNTHETIC ONE ═════
  // ⛔⛔ **EVERY CHECK ABOVE USED `{beat:true}`, WHICH BYPASSES THE DRIVER.** So
  // until here the chain that actually runs in the app — rolling transport ->
  // `Timer` -> `sampleMusicalTypingBeat` -> `MusicalTypingBeatDriver` counts a
  // DOWNBEAT -> the cue moves — had an instrument on NEITHER end: the driver is
  // unit-tested in isolation and the timer wiring by nothing at all. That is
  // exactly this tree's named failure mode (the record says X, the source says
  // Y, and nothing compares them), so this leg rolls a REAL transport and
  // watches the cue move on its own, with nobody playing anything.
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
  await cmd("debug.musicalTyping", { progression: "four-chords" });
  await cmd("debug.musicalTyping", { advanceMode: "onBeat" });
  await cmd("transport.seek", { beats: 0 });
  s = await state({});
  const stepBeforeRoll = s.sequenceStep;
  ok(stepBeforeRoll === 1, "the cue is parked on step 1 before the transport rolls",
     String(stepBeforeRoll));

  await cmd("transport.play", {});
  // One bar at 120 BPM is 2.0 s. The driver latches its FIRST sample without
  // firing (the cue owns the bar it starts in), so the first real tick lands at
  // the top of bar 2. 2.8 s clears that with margin and is not a race.
  await sleep(2800);
  const rolled = await state({});
  await cmd("transport.stop", {});
  // ⛔ THE DISAMBIGUATOR: if the cue did not move, this says whether the
  // transport rolled at all, so the failure is readable instead of a mystery.
  ok(rolled.transportBeats > 3.5,
     "the transport really rolled — at least one full bar of playhead",
     `beats=${rolled.transportBeats} playing=${rolled.transportPlaying}`);
  ok(rolled.sequenceStep !== stepBeforeRoll,
     "⭐⭐⭐ A ROLLING TRANSPORT MOVED THE CUE BY ITSELF — nobody played a note "
     + "and nothing was synthesized: the Timer, the sampler and the DOWNBEAT rule all ran",
     JSON.stringify({ before: stepBeforeRoll, after: rolled.sequenceStep,
                      beats: rolled.transportBeats }));

  // ⛔ THE CONTROL. The same rolling transport must move NOTHING in the other
  // two modes — otherwise the tick is not gated by the switch at all and the
  // check above would pass for the wrong reason.
  for (const quiet of ["free", "onMatch"]) {
    await cmd("debug.musicalTyping", { progression: "four-chords" });
    await cmd("debug.musicalTyping", { advanceMode: quiet });
    await cmd("transport.seek", { beats: 0 });
    await cmd("transport.play", {});
    await sleep(2800);
    const q = await state({});
    await cmd("transport.stop", {});
    ok(q.transportBeats > 3.5, `…and the control for ${quiet} really rolled too`,
       String(q.transportBeats));
    ok(q.sequenceStep === 1,
       `⛔ …while the SAME rolling transport moves nothing in ${quiet}`,
       String(q.sequenceStep));
  }
  await cmd("transport.seek", { beats: 0 });

  // ══ 6. PLAYBOX GENERATES, AND SAYS WHO WROTE IT ═════════════════════════
  await cmd("debug.musicalTyping", { progression: "" });
  s = await state({});
  ok(s.playboxSource === null && bordered(s).length === 0,
     "no lights and no provenance before the button is pressed",
     JSON.stringify([s.playboxSource, borderKey(s)]));
  await cmd("debug.musicalTyping", { playbox: "local" });
  for (let i = 0; i < 40 && (await state({})).playboxBusy; i++) await sleep(50);
  s = await state({});
  ok(s.playboxBusy === false, "the generation finished", String(s.playboxBusy));
  ok(s.sequenceLength >= 2, "⭐⭐ PLAYBOX PRODUCED A SEQUENCE WITH NO API KEY",
     String(s.sequenceLength));
  ok(s.playboxSource === "local",
     "⛔ …and it says the LIBRARY wrote it, not the AI", String(s.playboxSource));
  ok(typeof s.playboxSummary === "string" && !s.playboxSummary.includes("AI"),
     "⛔⛔ the fallback never claims authorship it did not earn",
     String(s.playboxSummary));
  ok(cells(s).filter(c => c.lit).length > 0, "…and it LIT keys",
     String(cells(s).filter(c => c.lit).length));
  // ⚠️ THE EXPECTATION IS DERIVED FROM THE APP'S OWN SEQUENCE, NOT GUESSED.
  // Measured on the first run: a generated sequence with a REPEATED degree
  // marks fewer cells than it has steps, because one degree is one cell on the
  // row and a repeat resolves to its SOONEST rank. `Math.min(3, len - 1)` was
  // wrong for exactly that case, and the honest fix is to count the distinct
  // degrees the queue can actually reach rather than to relax the assertion.
  const steps = s.sequenceDegrees ?? [];
  const reach = Math.min(3, steps.length - 1);
  const cueDegree = s.sequenceDegree;
  const reachable = new Set();
  for (let k = 1; k <= reach; k++) {
    const d = steps[k % steps.length];
    if (d !== cueDegree && !reachable.has(d)) reachable.add(d);
  }
  ok(steps.length >= 2, "the echo reports the generated sequence itself",
     JSON.stringify(steps));
  marks(s, `a generated sequence ${JSON.stringify(steps)}`, reachable.size);
  await shot("playbox-generated");
  const generatedDegrees = cells(s)
    .filter(c => c.next || (c.queue !== null && c.queue !== undefined))
    .map(c => c.degree);
  ok(generatedDegrees.every(d => d >= 1 && d <= 7),
     "⛔ every generated degree is one the chord row can actually play",
     JSON.stringify(generatedDegrees));

  // Pressing it again is not a do-nothing control.
  const firstRun = rowSignature(s);
  let changed = false;
  for (let attempt = 0; attempt < 6 && !changed; attempt++) {
    await cmd("debug.musicalTyping", { playbox: "local" });
    for (let i = 0; i < 40 && (await state({})).playboxBusy; i++) await sleep(50);
    changed = rowSignature(await state({})) !== firstRun;
  }
  ok(changed, "⭐ pressing NEW LIGHTS again gives different lights", firstRun);

  // ══ 7. ⭐⭐⭐ THE TAKE IS GENUINELY THE USER'S ═══════════════════════════
  // The deliverable is not the lights. It is a RECORDED PERFORMANCE, played on
  // the keys and read back out of the clip — the m34-b proof shape.
  await cmd("debug.musicalTyping", { progression: "four-chords" });
  await cmd("debug.musicalTyping", { advanceMode: "free" });
  // ⚠️ `track.setArm`, NOT `track.arm` — measured on the first run of this gate,
  // which recorded nothing at all because the arm silently never happened.
  await cmd("track.setArm", { trackId: trackID, armed: true });
  // ⚠️ EXPLICIT COUNT-IN 0, not inherited (m23-cy): the project default is ONE
  // BAR = 2 s at 120 BPM, so every chord below would land pre-anchor and this
  // gate would report Playbox broken when it is not.
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
  await cmd("transport.seek", { beat: 0 });
  await cmd("transport.record", {});
  // ⚠️ 500 ms BEFORE THE FIRST CHORD, AND IT IS NOT PADDING. A take's
  // PlaybackAnchor is scheduled slightly ahead of startTake and every
  // PRE-ANCHOR note-on is DISCARDED by design — the same measured ~300 ms the
  // m23-ct smoke documents. 220 ms was not enough on the first run.
  await sleep(500);
  // ⭐ TWO INSTRUMENTS BEFORE A NOTE IS PLAYED, so an empty clip below fails for
  // the RIGHT reason: the app's prediction and the ENGINE's own answer.
  let armed = await state({});
  ok(armed.targetState === "recording-armed",
     "the app predicts a captured take", String(armed.targetState));
  const played = [];
  for (let i = 0; i < 4; i++) {
    s = await state({});
    const key = borderKey(s);
    played.push(key);
    const pressed = await state({ press: key });
    if (i === 0) {
      ok(pressed.sinkIsRecording === true,
         "⭐⭐ the ENGINE confirms the take is keeping what is played",
         JSON.stringify(pressed.sinkIsRecording));
    }
    await sleep(200);
    await cmd("debug.musicalTyping", { release: key });
    await sleep(120);
  }
  await cmd("transport.stop", {});
  await sleep(400);
  ok(JSON.stringify(played) === JSON.stringify(["A", "G", "H", "F"]),
     "⭐ the human followed the lights through one full loop", JSON.stringify(played));

  const overview = body(await cmd("project.overview", {}));
  const track = (overview.tracks ?? []).find(x => x.id === trackID);
  const clip = (track?.clips ?? [])[0];
  ok(!!clip, "⭐⭐ A CLIP WAS RECORDED — the take exists",
     JSON.stringify(track?.clips ?? []).slice(0, 300));
  if (clip) {
    const notes = body(await cmd("clip.getNotes", { clipId: clip.id })).notes ?? [];
    ok(notes.length > 0,
       "⭐⭐⭐ AND THE NOTES ARE IN IT — read back with clip.getNotes, not inferred",
       `${notes.length} notes`);
    // Four chords of 3-5 notes each. The exact count depends on the voicing, so
    // the assertion is a RANGE with a stated reason rather than a magic number.
    ok(notes.length >= 8,
       "…at least eight notes — four chords were played, not four single keys",
       `${notes.length} notes`);
    const pitches = new Set(notes.map(x => x.pitch));
    ok(pitches.size >= 4, "…across several distinct pitches",
       JSON.stringify([...pitches].sort((a, b) => a - b)));
    // ⚠️ `lengthBeats`, NOT `durationBeats` — measured on the first run of this
    // gate, where the wrong field name made `undefined > 0` fail against notes
    // that all had real lengths. A VERIFIED NAME IS NOT A VERIFIED FIELD.
    ok(notes.every(x => x.lengthBeats > 0),
       "⛔ every note has a real length — the offs landed",
       JSON.stringify(notes.slice(0, 3)));
    const starts = notes.map(x => x.startBeat);
    ok(Math.max(...starts) > Math.min(...starts),
       "⛔⛔ THE TIMING IS THE USER'S: the chords land at DIFFERENT beats, "
       + "which is what a played take looks like and a generated one does not",
       JSON.stringify([Math.min(...starts), Math.max(...starts)]));
  }

  await cmd("debug.musicalTyping", { releaseAll: true });
  await sleep(120);

  console.log(`M34G_PLAYBOX_SMOKE pass=${pass} fail=${fail} total=${pass + fail}`);
  console.log(`SHOTS IN ${SHOTS} — a UI phase is not done until someone LOOKS.`);
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}
verdict({ ran: pass + fail, failed: fail });
