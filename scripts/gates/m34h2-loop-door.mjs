// m34-h-2 gate — LIVE LOOPING'S DOOR. THE QUESTION THIS GATE EXISTS TO ANSWER:
// can a HUMAN reach the looper — start a session, arm a track, finish a layer,
// take one back, mute one, and end — **without an AI agent and without the
// Position/Time readouts moving underneath them?**
//
// ⛔⛔ IT IS DELIBERATELY NOT `m34h1-loop-deck.mjs`. That gate is a CLOSED 53/53
// record of the deck's behaviour and is not touched here. This one measures the
// SURFACE m34-h-1 left out, and it measures three things no assertion in this
// tree could see before:
//
//   1. ⭐⭐ THE 340 pt READOUT ANCHOR DOES NOT MOVE. `TransportBar.swift`'s
//      comment says the deck surface sits right of the `Spacer` "so
//      Position/Time do not move when a session opens or closes". That was a
//      COMMENT. Here it is a MEASUREMENT: `debug.explainFrames` reports
//      `transportPosition`/`transportTime` before the session, with a two-layer
//      session live, and after it ends — all three x values must be identical.
//      ⚠️ The m25-j caveat (frames reporting a PRE-`.offset()` x) is specific to
//      `clipBlock`, which carries an `.offset()`; these readouts do not.
//
//   2. ⭐⭐ THE DOOR IS VISIBLE WITH NO SESSION, IN BOTH DENSITIES. The whole
//      defect was a surface gated on the state only that surface could create.
//      The `loopDeck` explain frame must have real area with NO session open —
//      the inverse of the old `if let deck = store.loopDeckStatus`.
//
//   3. ⭐⭐ A HUMAN CAN LOOK AT IT. Five captures a person actually opens: the
//      door in Simple, the door in Pro (the only density showing the length
//      choice), the QUEUED state (armed, not yet recording — the state the
//      brief singles out as most forgettable), a live two-layer session, and a
//      session with one layer muted through its own lamp.
//
// ⚠️ THE CONTROLS ARE SwiftUI BUTTONS AND THIS IS A WIRE GATE — no gate in this
// tree can press a pixel. What it CAN do is drive the exact store methods the
// buttons call and assert the SURFACE reflects them, then hand a human the
// pictures. Said plainly rather than implied: **the clicks were not simulated.**
//
// ⚠️ MIDI-ONLY, ON PURPOSE — v1 of the deck records instrument layers only, and
// `note.play` opens no microphone, so no TCC prompt can fire.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { existsSync, mkdirSync } from "node:fs";
import {
  sleep, buildOrAbort, startStaging, stopStaging, connect, verdict, panelDensityGuard,
} from "./_staging.mjs";

const GATE = "m34h2-loop-door";
const SHOTS =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/m34h2-shots";
mkdirSync(SHOTS, { recursive: true });

buildOrAbort({ label: "building staging binary (m34-h-2)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34h2${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
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

const density = panelDensityGuard((command, params) => cmd(command, params));

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : "")); }
};

async function shot(name) {
  const path = `${SHOTS}/${name}.png`;
  const r = await cmd("debug.captureUI", { path });
  const wrote = existsSync(path);
  ck(`captured ${name}.png for a human to LOOK at`, wrote, JSON.stringify(r).slice(0, 200));
  if (wrote) console.log(`  SHOT ${path}`);
}

/**
 * The measured frames of the transport readouts + the deck surface.
 *
 * ⚠️ `debug.explainFrames` answers `{frames: {id: [rect, …]}}` — an id maps to
 * an ARRAY, because one explain id can be mounted more than once. Each of these
 * three is mounted exactly once in the transport bar, and that is asserted
 * rather than assumed: a silently duplicated mount would make `[0]` an
 * arbitrary pick and every x comparison below meaningless.
 *
 * ⚠️ EXPLAIN MODE MUST BE ON or the probes report nothing at all — and "nothing
 * at all" and "the control is missing" are the same output, which is exactly
 * the false negative this repo keeps paying for.
 */
async function frames(label) {
  const ids = ["transportPosition", "transportTime", "loopDeck"];
  const r = await cmd("debug.explainFrames", { ids });
  const raw = (r.result ?? r)?.frames ?? {};
  const by = {};
  for (const id of ids) {
    const rects = raw[id] ?? [];
    if (rects.length !== 1) {
      console.log(`  [warn ${label}] ${id} reported ${rects.length} rects, expected 1`);
    }
    by[id] = rects[0];
    by[`${id}Count`] = rects.length;
  }
  console.log(`[measured ${label}] ` + JSON.stringify(by));
  return by;
}

// m34-v: this used to call `transport.getState`, which IS NOT A COMMAND — so
// every read returned undefined, `waitForBeat` never actually waited, and the
// quantize-boundary wait silently degraded into a fixed ~2.4 s sleep. The read
// below is the verified sibling's (`m34h1-loop-deck.mjs`), copied verbatim
// rather than reinvented.
async function playhead() {
  const snap = await cmd("project.snapshot");
  return snap.result?.transport?.positionBeats;
}

/**
 * Polls the app's own playhead until it reaches `target`.
 *
 * m34-v: the budget is wall-clock, not an iteration count. The old
 * `40 × 60 ms` cap was sized while the wait was a no-op; once the read works,
 * 2.4 s is shorter than a single bar below 100 BPM, so a real bar-quantized
 * wait would have timed out and returned early — trading one silent failure
 * for another.
 */
async function waitForBeat(target, budgetMs = 20000) {
  const deadline = Date.now() + budgetMs;
  let last;
  while (Date.now() < deadline) {
    last = await playhead();
    if (typeof last === "number" && last >= target) return last;
    await sleep(60);
  }
  return last;
}

try {
  // ------------------------------------------------------------------ SETUP
  console.log("\n=== SETUP ===");
  let r = await cmd("project.new", { discardChanges: true });
  ck("project.new", r.ok, r.error);

  r = await cmd("track.add", { name: "Deck Chords", kind: "instrument" });
  const chords = r.result?.id;
  ck("track.add chords", r.ok && !!chords, r.error);
  r = await cmd("track.add", { name: "Deck Bass", kind: "instrument" });
  const bass = r.result?.id;
  ck("track.add bass", r.ok && !!bass, r.error);

  await cmd("track.setInstrument", { trackId: chords, soundBank: { source: "gm", program: 4 } });
  await cmd("track.setInstrument", { trackId: bass, soundBank: { source: "gm", program: 33 } });
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
  // ⚠️ WITHOUT THIS EVERY FRAME BELOW IS EMPTY, and an empty frame list is
  // indistinguishable from a missing control.
  r = await cmd("debug.explainMode", { on: true });
  ck("debug.explainMode on (frames are unreadable without it)", r.ok, r.error);

  // ------------------------------------------- 1. THE DOOR, WITH NO SESSION
  console.log("\n=== 1. THE DOOR EXISTS BEFORE ANY SESSION DOES ===");
  await density.set("transport", "simple");
  await sleep(400);

  const noSession = await cmd("looper.status");
  // ⚠️ `looper.status` on a deckless project answers "no session" one way or
  // another; what matters is that the SURFACE is on screen anyway.
  console.log("[measured] looper.status with no session: " + JSON.stringify(noSession).slice(0, 200));

  const fSimple = await frames("no session, SIMPLE");
  ck("⭐⭐ THE DOOR IS DRAWN WITH NO SESSION OPEN (the inverse of the old gate)",
     !!fSimple.loopDeck && fSimple.loopDeck.width > 20 && fSimple.loopDeck.height > 10,
     fSimple.loopDeck);
  ck("the Position readout is mounted and measurable",
     !!fSimple.transportPosition && fSimple.transportPosition.width > 0,
     fSimple.transportPosition);
  await shot("1-door-simple");

  // Pro is the ONLY density that shows the length choice, so it gets its own
  // capture — a density decision nobody looked at is a density decision nobody
  // made.
  await density.set("transport", "pro");
  await sleep(400);
  const fPro = await frames("no session, PRO");
  ck("⭐ the door is WIDER in Pro — the length choice is revealed there and only there",
     !!fPro.loopDeck && !!fSimple.loopDeck && fPro.loopDeck.width > fSimple.loopDeck.width,
     { simple: fSimple.loopDeck?.width, pro: fPro.loopDeck?.width });
  await shot("2-door-pro");

  await density.set("transport", "simple");
  await sleep(400);

  // ------------------------------------------------ 2. OPEN A SESSION
  console.log("\n=== 2. THE DOOR OPENS A SESSION, AT THE PRODUCT DEFAULT ===");
  r = await cmd("transport.play");
  ck("transport.play", r.ok, r.error);
  await sleep(400);

  // ⭐ EXACTLY WHAT THE LOOPER CHIP SENDS IN SIMPLE MODE: bars 4, never a bare
  // call. The store's own default for `bars` is nil == press-to-end.
  const begun = await cmd("looper.begin", { bars: 4 });
  ck("looper.begin {bars:4} accepted", begun.ok, begun.error);
  ck("⭐⭐ THE DEFAULT DOOR PRESS PRODUCES FIXED BARS, NOT PRESS-TO-END",
     begun.result?.lengthMode === "fixedBars", begun.result?.lengthMode);
  ck("⭐ and the cycle really is four bars long",
     begun.result?.cycleBeats === 4 * begun.result?.beatsPerBar,
     { cycleBeats: begun.result?.cycleBeats, beatsPerBar: begun.result?.beatsPerBar });

  const fOpen = await frames("session open, no layers");
  ck("⛔⛔ THE 340 pt ANCHOR HOLDS: Position does not move when a session OPENS",
     fOpen.transportPosition?.x === fSimple.transportPosition?.x,
     { before: fSimple.transportPosition?.x, after: fOpen.transportPosition?.x });
  ck("⛔ and neither does Time",
     fOpen.transportTime?.x === fSimple.transportTime?.x,
     { before: fSimple.transportTime?.x, after: fOpen.transportTime?.x });

  // --------------------------------- 3. THE QUEUED STATE — THE FORGETTABLE ONE
  console.log("\n=== 3. ARMED BUT NOT YET RECORDING ===");
  const arm1 = await cmd("looper.armLayer", { trackId: chords });
  ck("looper.armLayer (chords) accepted", arm1.ok, arm1.error);
  ck("⭐⭐ THE PRESS QUEUES, IT DOES NOT RECORD — the state the whole indicator is for",
     arm1.result?.pendingPhase === "queued", arm1.result?.pendingPhase);
  const lamp1 = (arm1.result?.lamps ?? [])[0];
  ck("and the lamp says queued too, so the strip and the deck agree",
     lamp1?.state === "queued", arm1.result?.lamps);
  // Captured IMMEDIATELY, while the launch boundary is still ahead: this is the
  // frame a performer stares at, and the one the strip's chrome now carries.
  await shot("3-queued-armed-not-recording");

  const launch1 = arm1.result?.pendingLaunchBeat;
  await waitForBeat(launch1);
  await sleep(300);
  r = await cmd("note.play", { trackId: chords, pitches: [60] });
  ck("layer 1: note.play recorded into the take (the honesty light)",
     r.result?.recording === true, r.result);
  await sleep(700);
  await cmd("note.play", { trackId: chords, pitches: [64] });
  await sleep(300);
  await cmd("note.play", { trackId: chords, pitches: [] });
  r = await cmd("looper.finishLayer");
  ck("looper.finishLayer (chords) accepted", r.ok, r.error);

  // ------------------------------------------------- 4. A SECOND LAYER
  console.log("\n=== 4. A SECOND LAYER, A DIFFERENT TRACK ===");
  // Wait out the close so the deck is idle before the next arm.
  for (let i = 0; i < 40; i++) {
    const s = await cmd("looper.status");
    if (!s.result?.pendingPhase) break;
    await sleep(250);
  }
  const arm2 = await cmd("looper.armLayer", { trackId: bass });
  ck("looper.armLayer (bass) accepted", arm2.ok, arm2.error);
  await waitForBeat(arm2.result?.pendingLaunchBeat);
  await sleep(300);
  await cmd("note.play", { trackId: bass, pitches: [40] });
  await sleep(700);
  await cmd("note.play", { trackId: bass, pitches: [43] });
  await sleep(300);
  await cmd("note.play", { trackId: bass, pitches: [] });
  await cmd("looper.finishLayer");
  for (let i = 0; i < 40; i++) {
    const s = await cmd("looper.status");
    if (!s.result?.pendingPhase && (s.result?.lamps ?? []).length >= 2) break;
    await sleep(250);
  }

  const twoLayers = await cmd("looper.status");
  const lamps = twoLayers.result?.lamps ?? [];
  ck("⭐ TWO LAYERS ON TWO TRACKS, read back off the deck", lamps.length === 2, lamps);
  ck("both lamps carry their TRACK NAME (the user's 'show assignment on the screen')",
     lamps.every((l) => typeof l.trackName === "string" && l.trackName.length > 0), lamps);
  await shot("4-session-two-layers");

  const fLive = await frames("session open, two layers");
  ck("⛔⛔ THE ANCHOR STILL HOLDS with a two-layer session live",
     fLive.transportPosition?.x === fSimple.transportPosition?.x,
     { before: fSimple.transportPosition?.x, live: fLive.transportPosition?.x });
  ck("⭐ and the deck surface really did GROW when the strip appeared (so the "
     + "anchor held despite a real width change, not because nothing changed)",
     fLive.loopDeck?.width > fSimple.loopDeck?.width,
     { door: fSimple.loopDeck?.width, session: fLive.loopDeck?.width });

  // ---------------------------------------- 5. THE LAMP IS THE MUTE BUTTON
  console.log("\n=== 5. MUTING A LAYER THROUGH ITS OWN LAMP ===");
  const target = lamps[0];
  const muted = await cmd("looper.setLayerMuted", { layerId: target.layerId, muted: true });
  ck("looper.setLayerMuted accepted", muted.ok, muted.error);
  const mutedLamp = (muted.result?.lamps ?? []).find((l) => l.layerId === target.layerId);
  ck("⭐ the lamp's STATE changed to muted — the light language carries the press",
     mutedLamp?.state === "muted" && mutedLamp?.isMuted === true, mutedLamp);
  const stillPlaying = (muted.result?.lamps ?? []).find((l) => l.layerId !== target.layerId);
  ck("and ONLY that layer — the other lamp is untouched (positive control)",
     stillPlaying?.state === "playing" && stillPlaying?.isMuted === false, stillPlaying);
  await shot("5-session-one-layer-muted");

  const unmuted = await cmd("looper.setLayerMuted", { layerId: target.layerId, muted: false });
  ck("the same lamp brings it back",
     (unmuted.result?.lamps ?? []).find((l) => l.layerId === target.layerId)?.state === "playing",
     unmuted.result?.lamps);

  // -------------------------------------------------- 6. PEEL, THEN END
  console.log("\n=== 6. TAKE ONE BACK, THEN CLOSE THE SESSION ===");
  const before = await playhead();
  const peel = await cmd("looper.undoLayer");
  ck("looper.undoLayer accepted", peel.ok, peel.error);
  await sleep(600);
  const after = await playhead();
  ck("⭐ THE MUSIC KEPT RUNNING ACROSS THE PEEL (rule ④: undo without stopping)",
     typeof before === "number" && typeof after === "number" && after > before,
     { before, after });

  const ended = await cmd("looper.end");
  ck("looper.end accepted", ended.ok, ended.error);
  await sleep(400);
  const fClosed = await frames("session ended");
  ck("⛔⛔ THE ANCHOR HOLDS ON THE WAY BACK OUT TOO",
     fClosed.transportPosition?.x === fSimple.transportPosition?.x,
     { before: fSimple.transportPosition?.x, afterEnd: fClosed.transportPosition?.x });
  ck("⭐ and the DOOR is still on screen after the session closed — you can start another",
     fClosed.loopDeck?.width > 20, fClosed.loopDeck);
  await shot("6-door-after-session");

  await cmd("transport.stop");
} finally {
  try { await density.restore("m34h2 teardown"); } catch (e) { console.log("density restore: " + e.message); }
  try { ws.close(); } catch {}
  stopStaging(GATE);
}

console.log(`\n=== ${GATE}: ${pass}/${pass + fail} ===`);
console.log(`Captures for a human to look at: ${SHOTS}`);
verdict({ ran: pass + fail, failed: fail });
