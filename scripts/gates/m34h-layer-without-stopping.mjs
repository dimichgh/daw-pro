// m34-h gate — THE QUESTION THIS ITEM EXISTS TO ANSWER: can a performer finish
// a layer and keep the music running, then record the next layer without ever
// stopping?
//
// Before this item, `ProjectStore.stop()` was the ONLY route that finalised a
// take, and it called `engine.stopRecording()`, which halts playback internally.
// Ending a take and stopping the transport were one action. That weld is what
// made live looping impossible: the music stopped between every layer.
//
// ⭐⭐ THREE THINGS ARE MEASURED HERE, AND ALL THREE ARE NEEDED — any two of them
// pass on a broken build:
//   1. THE CLIP EXISTS. Read back out of `clip.getNotes`, never out of a
//      command's return value. A setter's return is not proof it took.
//   2. THE PLAYHEAD ADVANCED ACROSS THE CLOSE. Sampled BEFORE and AFTER, with a
//      real wait between. A transport that stopped keeps reporting its last
//      position forever, so a state flag alone (`isPlaying: true`) would look
//      identical to a live one. The moving number is the only honest evidence
//      the render callbacks kept firing.
//   3. A SECOND LAYER RECORDED WITH NO STOP AND NO PLAY IN BETWEEN. Structural:
//      this script sends `transport.stop` exactly once, at the very end, and
//      `transport.play` never. If either appeared mid-run the claim would be
//      hollow, so the run also COUNTS its own verbs and asserts that.
//
// ⚠️ MIDI-ONLY, ON PURPOSE. Layers are recorded through `note.play` onto armed
// INSTRUMENT tracks, so no microphone is opened and no TCC prompt can fire on a
// fresh staging binary. That exercises the whole store/engine seam — the take
// close, the MIDI clamp, the landing `performEdit`, the layer start against the
// running anchor — but NOT the audio capture writer's teardown. That half is
// covered offline by `Tests/DAWEngineTests/LiveLayerCaptureTests.swift` and
// `RecordingWriterTests` against synthetic buffers, and is called out plainly
// rather than implied.
//
// ⚠️ Waits are load-bearing, not padding. A take's anchor is scheduled slightly
// AHEAD of the record command and `MIDICaptureSession` DROPS every note-on
// before it (the same rule that makes count-in work) — measured in
// `LivePlayCaptureTests`: a chord struck at t≈0 vanished while a note struck
// 120 ms later landed at beat 0.103.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m34h-layer-without-stopping";
buildOrAbort({ label: "building staging binary (m34-h)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
/** Every verb this run sends, so the "never stopped" claim can be checked. */
const sentVerbs = [];
function cmd(command, params = {}) {
  sentVerbs.push(command);
  return new Promise((res, rej) => {
    const i = `m34h${++n}`;
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

let pass = 0,
  fail = 0;
const ck = (name, cond, extra) => {
  if (cond) {
    pass++;
    console.log("PASS " + name);
  } else {
    fail++;
    console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : ""));
  }
};

/** The live playhead, read off the app's own snapshot. */
async function playhead() {
  const snap = await cmd("project.snapshot");
  return snap.result?.transport?.positionBeats;
}

/** Every MIDI note on the named tracks, with its owning track/clip. */
async function notesOn(trackIDs) {
  const snap = await cmd("project.snapshot");
  const out = [];
  for (const track of snap.result?.tracks ?? []) {
    if (trackIDs && !trackIDs.includes(track.id)) continue;
    for (const clip of track.clips ?? []) {
      const got = await cmd("clip.getNotes", { clipId: clip.id });
      for (const note of got.result?.notes ?? []) {
        // ⚠️ `clipStartBeat`, NOT `startBeat`. A first draft of this probe wrote
        // `{ startBeat: clip.startBeat, ...note }` — and the spread SHADOWED it
        // with the note's own clip-relative start. The "layer landed at the live
        // playhead" check then passed on a note offset of 1.04 while the clip
        // was actually at 5.50, i.e. it would have passed identically had the
        // clip landed at beat 0. A distinct key makes that shadowing
        // impossible.
        out.push({ track: track.name, clip: clip.name, clipStartBeat: clip.startBeat, ...note });
      }
    }
  }
  return out;
}

/** Plays two notes then releases — one layer's worth of performance. */
async function playTwoNotes(trackId, a, b) {
  await sleep(500); // past the take anchor. See the header.
  const first = await cmd("note.play", { trackId, pitches: [a] });
  await sleep(600);
  const second = await cmd("note.play", { trackId, pitches: [b] });
  await sleep(600);
  const release = await cmd("note.play", { trackId, pitches: [] });
  return { first, second, release };
}

/** Polls until the take lands (it finalizes asynchronously) or gives up. */
async function awaitNotes(trackIDs, wanted) {
  let seen = [];
  for (let i = 0; i < 20; i++) {
    await sleep(250);
    seen = await notesOn(trackIDs);
    if (seen.length >= wanted) break;
  }
  return seen;
}

// ---------------------------------------------------------------------------
// SETUP
// ---------------------------------------------------------------------------
console.log("\n=== SETUP ===");

let r = await cmd("project.new", { discardChanges: true });
ck("project.new", r.ok, r.error);

r = await cmd("track.add", { name: "m34h Layer One", kind: "instrument" });
const trackOne = r.result?.id;
ck("track.add layer one", r.ok && !!trackOne, r.error);

r = await cmd("track.add", { name: "m34h Layer Two", kind: "instrument" });
const trackTwo = r.result?.id;
ck("track.add layer two", r.ok && !!trackTwo, r.error);

r = await cmd("track.setArm", { trackId: trackOne, armed: true });
ck("layer one armed", r.ok, r.error);

// ⚠️ EXPLICIT COUNT-IN 0 (m23-cy): the project default is ONE bar, which delays
// the take anchor by 2.0 s at 120 BPM — four times the 500 ms wait in
// playTwoNotes, so both notes would land pre-anchor and this gate would redden
// for a reason that has nothing to do with layering.
r = await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
ck("count-in pinned to 0 for this gate", r.ok && r.result?.countInBars === 0, r.result);

// ---------------------------------------------------------------------------
// NEGATIVE CONTROL FIRST — a layer must be REFUSED from a stopped transport.
// Run before the positive arm on purpose: it proves the verb is reachable and
// discriminating, so a later refusal cannot be confused with a dead route.
// ---------------------------------------------------------------------------
console.log("\n=== NEGATIVE CONTROL: recordLayer from a STOPPED transport ===");

r = await cmd("transport.recordLayer");
ck("recordLayer REFUSES a stopped transport", r.ok === false, r);
ck(
  "and the refusal TEACHES what to do instead",
  typeof r.error === "string" && /nothing is playing/.test(r.error),
  r.error
);

// ---------------------------------------------------------------------------
// LAYER 1 — the ordinary record path, then THE CLOSE THAT KEEPS PLAYING
// ---------------------------------------------------------------------------
console.log("\n=== LAYER 1: record, then finish WITHOUT stopping ===");

r = await cmd("transport.record", {});
ck("transport.record started", r.ok, r.error);

const playedOne = await playTwoNotes(trackOne, 60, 64);
ck("note.play accepted on layer one", playedOne.first.ok, playedOne.first.error);
// ⭐ THE HONESTY LIGHT. If this is false the notes sounded and went into no
// take, and every note assertion below would be measuring the wrong thing.
ck(
  "recording:true on the armed track (the honesty light)",
  playedOne.first.result?.recording === true,
  playedOne.first.result
);

const beatBeforeClose = await playhead();

// ⭐⭐ THE ITEM ITSELF.
r = await cmd("transport.finishLayer", {});
ck("transport.finishLayer accepted", r.ok, r.error);
ck("response says isPlaying:true — the music did NOT stop", r.result?.isPlaying === true, r.result);
ck("response says isRecording:false — the take DID close", r.result?.isRecording === false, r.result);

// ⭐ THE MOVING NUMBER. A stopped transport reports its last position forever,
// so `isPlaying: true` alone proves nothing. Real wait, second sample.
await sleep(900);
const beatAfterClose = await playhead();
console.log(`[measured] playhead across the close: ${beatBeforeClose} -> ${beatAfterClose}`);
ck(
  "⭐ THE PLAYHEAD ADVANCED PAST THE CLOSE — playback genuinely continued",
  typeof beatBeforeClose === "number" &&
    typeof beatAfterClose === "number" &&
    beatAfterClose > beatBeforeClose,
  { beatBeforeClose, beatAfterClose }
);

const layerOneNotes = await awaitNotes([trackOne], 2);
console.log("[measured] layer one notes: " + JSON.stringify(layerOneNotes));
ck("layer one landed as a clip with 2 notes", layerOneNotes.length === 2, layerOneNotes);
ck(
  "layer one pitches are 60 then 64, in the order played",
  [...layerOneNotes].sort((a, b) => a.startBeat - b.startBeat).map((x) => x.pitch).join(",") === "60,64",
  layerOneNotes.map((x) => x.pitch)
);

const positiveArmWorked = layerOneNotes.length === 2 && beatAfterClose > beatBeforeClose;
if (!positiveArmWorked) {
  console.log(
    "\n⛔ THE CLOSE-WHILE-PLAYING ARM FAILED — everything below measures a " +
      "transport whose state is unknown. Fix this arm before reading the rest."
  );
}

// ---------------------------------------------------------------------------
// A SECOND NEGATIVE CONTROL, taken while PLAYING: a loop must refuse.
// Placed here rather than at the end because it must run on a rolling
// transport, which only exists between the two layers.
// ---------------------------------------------------------------------------
console.log("\n=== NEGATIVE CONTROL: recordLayer under a LOOP must refuse ===");

r = await cmd("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 8 });
ck("loop enabled for the refusal probe", r.ok, r.error);
r = await cmd("transport.recordLayer");
ck("recordLayer REFUSES while the loop is enabled", r.ok === false, r);
ck(
  "and the refusal names the trap: loop takes are ALTERNATE takes, not layers",
  typeof r.error === "string" && /overdub/.test(r.error) && /loop/.test(r.error),
  r.error
);
r = await cmd("transport.setLoop", { enabled: false });
ck("loop disabled again", r.ok, r.error);

// ---------------------------------------------------------------------------
// LAYER 2 — recorded WITHOUT EVER STOPPING
// ---------------------------------------------------------------------------
console.log("\n=== LAYER 2: record on top, transport never stopped ===");

r = await cmd("track.setArm", { trackId: trackOne, armed: false });
ck("layer one un-armed", r.ok, r.error);
r = await cmd("track.setArm", { trackId: trackTwo, armed: true });
ck("layer two armed (switching instruments mid-performance)", r.ok, r.error);

r = await cmd("transport.recordLayer", {});
ck("⭐ transport.recordLayer accepted on a ROLLING transport", r.ok, r.error);
ck("layer two is recording", r.result?.isRecording === true, r.result);
ck("and still playing", r.result?.isPlaying === true, r.result);
const layerTwoStartBeat = r.result?.positionBeats;

const playedTwo = await playTwoNotes(trackTwo, 67, 71);
ck("note.play accepted on layer two", playedTwo.first.ok, playedTwo.first.error);
ck(
  "recording:true on layer two (the honesty light, second layer)",
  playedTwo.first.result?.recording === true,
  playedTwo.first.result
);

const beatBeforeSecondClose = await playhead();
r = await cmd("transport.finishLayer", {});
ck("second transport.finishLayer accepted", r.ok, r.error);
ck("still playing after TWO layers", r.result?.isPlaying === true, r.result);

await sleep(900);
const beatAfterSecondClose = await playhead();
console.log(
  `[measured] playhead across the second close: ${beatBeforeSecondClose} -> ${beatAfterSecondClose}`
);
ck(
  "the playhead advanced past the SECOND close too",
  typeof beatBeforeSecondClose === "number" &&
    typeof beatAfterSecondClose === "number" &&
    beatAfterSecondClose > beatBeforeSecondClose,
  { beatBeforeSecondClose, beatAfterSecondClose }
);

const allNotes = await awaitNotes([trackOne, trackTwo], 4);
console.log("[measured] all notes after two layers: " + JSON.stringify(allNotes));

const onOne = allNotes.filter((x) => x.track === "m34h Layer One");
const onTwo = allNotes.filter((x) => x.track === "m34h Layer Two");
ck("layer one STILL holds exactly its 2 notes", onOne.length === 2, onOne);
ck("layer two holds exactly 2 notes", onTwo.length === 2, onTwo);
ck(
  "layer two pitches are 67 then 71 — the second performance, not the first",
  [...onTwo].sort((a, b) => a.startBeat - b.startBeat).map((x) => x.pitch).join(",") === "67,71",
  onTwo.map((x) => x.pitch)
);
ck(
  "layer one pitches are UNCHANGED at 60/64 — layer two did not overwrite it",
  [...onOne].sort((a, b) => a.startBeat - b.startBeat).map((x) => x.pitch).join(",") === "60,64",
  onOne.map((x) => x.pitch)
);

// ⭐ THE PLACEMENT CHECK, and it is the one that catches "the layer recorded but
// landed in the wrong place". Layer 2's CLIP must sit at the beat the transport
// was actually at when recordLayer was called — that is the whole purpose of
// aligning the new capture onto the already-running anchor. A clip at beat 0
// would mean the layer ignored the live playhead and stacked on top of layer 1.
const layerOneClipStart = onOne[0]?.clipStartBeat;
const layerTwoClipStart = onTwo[0]?.clipStartBeat;
console.log(
  `[measured] clip starts — layer one ${layerOneClipStart}, layer two ${layerTwoClipStart}; ` +
    `recordLayer reported positionBeats ${layerTwoStartBeat}`
);
ck(
  "⭐ layer two's CLIP landed at the beat recordLayer reported (within one bar)",
  typeof layerTwoClipStart === "number" &&
    typeof layerTwoStartBeat === "number" &&
    Math.abs(layerTwoClipStart - layerTwoStartBeat) < 4,
  { layerTwoClipStart, layerTwoStartBeat }
);
ck(
  "⭐ and it is DOWNSTREAM of layer one's clip — the layers do not stack at beat 0",
  typeof layerOneClipStart === "number" &&
    typeof layerTwoClipStart === "number" &&
    layerTwoClipStart > layerOneClipStart + 1,
  { layerOneClipStart, layerTwoClipStart }
);

// ---------------------------------------------------------------------------
// THE STRUCTURAL CLAIM: the transport was never stopped or restarted.
// ---------------------------------------------------------------------------
console.log("\n=== STRUCTURAL: was the music ever stopped? ===");

const stops = sentVerbs.filter((v) => v === "transport.stop").length;
const plays = sentVerbs.filter((v) => v === "transport.play").length;
console.log(`[measured] transport.stop sent ${stops}x, transport.play sent ${plays}x before teardown`);
ck("⭐ transport.stop was NEVER sent during the two layers", stops === 0, sentVerbs);
ck("⭐ transport.play was NEVER sent during the two layers", plays === 0, sentVerbs);

// ---------------------------------------------------------------------------
// TEARDOWN — the one and only stop.
// ---------------------------------------------------------------------------
r = await cmd("transport.stop", {});
ck("transport.stop (teardown)", r.ok, r.error);

console.log(
  `\n[measured] m34-h: 2 layers recorded, ${onOne.length + onTwo.length} notes landed, ` +
    `playhead ran ${beatBeforeClose} -> ${beatAfterSecondClose} without a single stop.`
);

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
