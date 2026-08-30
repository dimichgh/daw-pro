// m23-cy gate — THE USER'S SYMPTOM, AND WHAT THE COUNT-IN ACTUALLY DOES ABOUT IT.
//
// Reported: *"The first note after you hit record is dropped."* Ruled: *"A
// one-bar count-in before recording starts."*
//
// ⛔⛔ **READ THIS BEFORE CHANGING AN ASSERTION: A COUNT-IN DOES NOT RESCUE THE
// DROPPED NOTE. IT MOVES THE ANCHOR LATER AND MARKS THE WAIT AUDIBLY.** The
// item was briefed with the acceptance test *"with countInBars: 1, a note
// struck IMMEDIATELY after transport.record must land in the take"*, and that
// is FALSE — measured, three arms, on staging 2026-08-30. A take's
// `PlaybackAnchor` is delayed by the count-in and `MIDICaptureSession` drops
// every pre-anchor note-on (`MIDICaptureSession.swift:12`: *"the anchor is
// already count-in-delayed, and note-ons with beat < the anchor beat are
// dropped"*). A note struck immediately after record with a count-in is struck
// DURING the count-in and is dropped exactly as before.
//
// What the count-in buys the user is the thing they were missing: a bar of
// clicks, so they are never playing before the anchor exists, and a take that
// starts where they were told it would. Arm B measures both.
//
// ⛔ The rejected alternative is on record in m23-ct and in
// `ProjectStore.record()`: synthesising a note-on at the anchor so the early
// note "survives". A partial note is a lie.
//
// ── THE ARMS ────────────────────────────────────────────────────────────────
//  B  countInBars 1, strike AFTER the count-in  → RECORDED, at a SMALL startBeat
//                                                 (the take EXCLUDES the count-in)
//  A  countInBars 0, strike IMMEDIATELY         → DROPPED (the user's symptom)
//  C  countInBars 1, strike DURING the count-in → DROPPED (the semantics, pinned)
//  D  a NEW project defaults to countInBars 1   → the item's actual change
//  E  a project that chose 0 KEEPS 0            → the conservative half of the ruling
//
// ⭐⭐ **B RUNS FIRST AND IS THE POSITIVE CONTROL FOR A AND C.** A and C both
// assert an EMPTY read. Without a note that demonstrably DOES land through the
// identical code path, an app that records nothing at all would satisfy both of
// them and this gate would certify the feature while it was completely broken.
// If B fails, A and C are reported as PROVING NOTHING rather than as passing.
//
// ⚠️ Timing is measured and printed, never assumed: one bar of 4/4 at 120 BPM is
// 2.0 s, and the gate logs the real wall-clock offset of every note-on so a slow
// machine produces a diagnosable failure instead of a mysterious one.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m23cy-count-in-default";
buildOrAbort({ label: "building staging binary (m23cy)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `cy${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 30000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t);
      ws.removeEventListener("message", h);
      res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : "")); }
};

/** Every MIDI note on one track, read out of the clip that landed. */
async function notesOn(trackId) {
  const snap = await cmd("project.snapshot");
  const out = [];
  for (const track of snap.result?.tracks ?? []) {
    if (track.id !== trackId) continue;
    for (const clip of track.clips ?? []) {
      const got = await cmd("clip.getNotes", { clipId: clip.id });
      for (const note of got.result?.notes ?? []) out.push(note);
    }
  }
  return out;
}

// One arm: fresh project, armed instrument track, the given count-in, one note
// struck `strikeAfterMs` after `transport.record`, held 700 ms, take stopped at
// `stopAfterMs`. Returns { notes, strikeAt } — the notes read back OUT OF THE
// CLIP, never a return value (a setter's return is not proof it took).
async function arm({ label, countInBars, strikeAfterMs, stopAfterMs, pitch }) {
  console.log(`\n=== ARM ${label} ===`);
  let r = await cmd("project.new", { discardChanges: true });
  ck(`[${label}] project.new`, r.ok, r.error);
  r = await cmd("track.add", { name: `m23cy ${label}`, kind: "instrument" });
  const trackId = r.result?.id ?? r.result?.track?.id;
  ck(`[${label}] instrument track added`, r.ok && !!trackId, r.error);
  r = await cmd("track.setArm", { trackId, armed: true });
  ck(`[${label}] armed`, r.ok, r.error);

  r = await cmd("transport.setMetronome", { enabled: false, countInBars });
  ck(`[${label}] countInBars set to ${countInBars}`, r.ok && r.result?.countInBars === countInBars, r.result);

  const t0 = Date.now();
  r = await cmd("transport.record", {});
  ck(`[${label}] transport.record started`, r.ok, r.error);
  if (strikeAfterMs > 0) await sleep(strikeAfterMs);
  const on = await cmd("note.play", { trackId, pitches: [pitch] });
  const strikeAt = Date.now() - t0;
  await sleep(700);
  await cmd("note.play", { trackId, pitches: [] });
  const remaining = stopAfterMs - (Date.now() - t0);
  if (remaining > 0) await sleep(remaining);
  await cmd("transport.stop", {});

  console.log(`  [measured] note-on at +${strikeAt} ms; note.play echo ` +
    `recording=${on.result?.recording} capturedEdges=${on.result?.capturedEdges}`);

  // The take finalizes asynchronously — poll rather than assume. An arm that
  // EXPECTS notes must not be read before they can exist, and an arm that
  // expects none must wait at least as long as one that finds them.
  let notes = [];
  for (let i = 0; i < 16; i++) {
    await sleep(250);
    notes = await notesOn(trackId);
    if (notes.length > 0) break;
  }
  console.log(`  [measured] notes in the take: ${JSON.stringify(notes)}`);
  return { notes, strikeAt };
}

// One bar of 4/4 at 120 BPM. Printed, not assumed.
const COUNT_IN_MS = 2000;
console.log(`[fixture] one bar of count-in at the default 120 BPM 4/4 = ${COUNT_IN_MS} ms`);

// ── ARM B — THE FIX, AND THE POSITIVE CONTROL FOR A AND C ───────────────────
const b = await arm({
  label: "B (countInBars 1, strike AFTER the count-in)",
  countInBars: 1, strikeAfterMs: COUNT_IN_MS + 300, stopAfterMs: COUNT_IN_MS + 2200, pitch: 62,
});
ck("⭐ B: the note struck after the count-in IS in the take", b.notes.length === 1, b.notes);
ck("B: it is the pitch that was played", b.notes[0]?.pitch === 62, b.notes);
ck("B: it has a real length", (b.notes[0]?.lengthBeats ?? 0) > 0.05, b.notes);
// ⭐ THE COUNT-IN IS EXCLUDED FROM THE TAKE. One bar is 4 beats; if the count-in
// rode INTO the clip this note would sit past beat 4. It sits just after 0.
ck("⭐ B: the take EXCLUDES the count-in — startBeat is near 0, not past bar 1",
   b.notes.length === 1 && b.notes[0].startBeat >= 0 && b.notes[0].startBeat < 2.0,
   b.notes.map((x) => x.startBeat));

const positiveControlHeld = b.notes.length === 1;
if (!positiveControlHeld) {
  console.log(
    "\n⛔ ARM B FAILED — the EMPTY results in arms A and C below prove NOTHING, " +
    "because a path that never records anything trivially records nothing when " +
    "struck early. Fix arm B before reading A or C."
  );
}

// ── ARM A — THE USER'S SYMPTOM, REPRODUCED ──────────────────────────────────
const a = await arm({
  label: "A (countInBars 0, strike IMMEDIATELY)",
  countInBars: 0, strikeAfterMs: 0, stopAfterMs: 2500, pitch: 60,
});
ck("A: a note struck immediately after record with NO count-in is dropped (the reported defect)",
   positiveControlHeld && a.notes.length === 0, { notes: a.notes, positiveControlHeld });

// ── ARM C — THE SEMANTICS, PINNED SO NOBODY RE-BRIEFS THEM WRONG ────────────
const c = await arm({
  label: "C (countInBars 1, strike DURING the count-in)",
  countInBars: 1, strikeAfterMs: 400, stopAfterMs: COUNT_IN_MS + 2200, pitch: 64,
});
ck("⛔ C: a note struck DURING the count-in is ALSO dropped — count-in marks the wait, it does not rescue the note",
   positiveControlHeld && c.notes.length === 0, { notes: c.notes, positiveControlHeld });

// ── ARM D — THE ACTUAL CHANGE: A NEW PROJECT DEFAULTS TO ONE BAR ────────────
console.log("\n=== ARM D: a NEW project defaults to one bar of count-in ===");
let r = await cmd("project.new", { discardChanges: true });
ck("[D] project.new", r.ok, r.error);
let overview = await cmd("project.overview", {});
let defaulted = overview.result?.transport?.metronome?.countInBars;
ck("⭐ D: a brand-new project starts with countInBars = 1 (the whole item)",
   defaulted === 1, overview.result?.transport?.metronome);

// ── ARM E — THE CONSERVATIVE HALF: A DELIBERATE 0 IS NEVER OVERRIDDEN ───────
console.log("\n=== ARM E: a project that chose 0 keeps 0 ===");
r = await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
ck("[E] countInBars set to 0 by hand", r.ok && r.result?.countInBars === 0, r.result);
r = await cmd("track.add", { name: "m23cy E", kind: "instrument" });
const eTrack = r.result?.id ?? r.result?.track?.id;
r = await cmd("track.setArm", { trackId: eTrack, armed: true });
ck("[E] armed", r.ok, r.error);
// Recording must NOT auto-engage a count-in over a stored 0 — "a user who
// deliberately set 0 means it". Measured through behaviour, not state: with a
// count-in silently forced on, a note struck at +300 ms would be pre-anchor and
// vanish. It must land.
r = await cmd("transport.record", {});
ck("[E] transport.record started", r.ok, r.error);
await sleep(300);
await cmd("note.play", { trackId: eTrack, pitches: [67] });
await sleep(700);
await cmd("note.play", { trackId: eTrack, pitches: [] });
await sleep(400);
await cmd("transport.stop", {});
let eNotes = [];
for (let i = 0; i < 16; i++) {
  await sleep(250);
  eNotes = await notesOn(eTrack);
  if (eNotes.length > 0) break;
}
console.log(`  [measured] arm E notes: ${JSON.stringify(eNotes)}`);
ck("⭐ E: record did NOT force a count-in over a stored 0 — a note at +300 ms landed",
   eNotes.length === 1, eNotes);
overview = await cmd("project.overview", {});
ck("E: and the stored 0 is still 0 after the take",
   overview.result?.transport?.metronome?.countInBars === 0,
   overview.result?.transport?.metronome);

console.log(
  `\n[measured] m23-cy: B(after count-in)=${b.notes.length} note(s) at startBeat ` +
  `${b.notes[0]?.startBeat ?? "—"}; A(t=0, no count-in)=${a.notes.length}; ` +
  `C(during count-in)=${c.notes.length}; D(new-project default)=${defaulted}; ` +
  `E(stored 0 honoured)=${eNotes.length} note(s).`
);

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
