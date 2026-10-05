// m34-h-1 gate — LIVE LOOPING, the loop deck. THE QUESTION THIS GATE EXISTS TO
// ANSWER: can a performer stack a short piece — record a chord layer, then
// WITHOUT STOPPING arm a different track and record a second layer that lines
// up with the first — and take the bad layer back while the music keeps
// running?
//
// ⭐⭐ FOUR THINGS ARE MEASURED, AND ALL FOUR ARE NEEDED. Any three of them pass
// on a build with a launch-quantization bug:
//   1. THE LAYERS EXIST, read back out of `clip.getNotes` — never out of a
//      command's return value. A setter's return is not proof it took, and
//      `looper.status` reports the DECK, not the timeline.
//   2. ⭐⭐ THE SECOND LAYER LINES UP WITH THE FIRST, measured as an OFFSET.
//      This is the leg the item lives or dies on. The two layers are armed at
//      deliberately DIFFERENT and deliberately UGLY mid-bar instants, and each
//      one's notes are then played the SAME wall-clock delay after its own
//      capture window opens. If launch quantization works, both layers' onsets
//      land at the same position WITHIN the cycle and the difference is
//      ~0 beats. If it is broken, the difference is the press-timing
//      difference — which is exactly what "it works" looks like until it is
//      measured. ⚠️ A quantized-launch bug looks like a working feature.
//   3. THE PLAYHEAD ADVANCED ACROSS EVERY CLOSE AND ACROSS THE UNDO. Sampled
//      before and after, with a real wait between: a stopped transport reports
//      its last position forever, so `isPlaying: true` alone would look
//      identical to a live one.
//   4. `transport.stop` WAS SENT EXACTLY ONCE, AT THE VERY END, and
//      `transport.play` exactly once, at the very start. Structural: this
//      script counts its own verbs, so the claim cannot be hollow.
//
// ⚠️ MIDI-ONLY, ON PURPOSE — v1 of the deck records instrument layers only (a
// recorded waveform cannot be tiled inside one clip), and playing through
// `note.play` opens no microphone, so no TCC prompt can fire on a fresh staging
// binary.
//
// ⚠️ WAITS ARE LOAD-BEARING, NOT PADDING. The deck arms each take a full BEAT
// before its window opens precisely so the engine's capture anchor (~70–300 ms
// ahead of the call) is live by the boundary; the gate then waits for the
// boundary before playing anything, so a dropped note would be a real defect
// rather than a race this script created.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m34h1-loop-deck";
const SCRATCH =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

buildOrAbort({ label: "building staging binary (m34-h-1)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
/** Every verb this run sends, so the "never stopped" claim can be checked. */
const sentVerbs = [];
function cmd(command, params = {}) {
  sentVerbs.push(command);
  return new Promise((res, rej) => {
    const i = `m34h1${++n}`;
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

async function playhead() {
  const snap = await cmd("project.snapshot");
  return snap.result?.transport?.positionBeats;
}

/** Polls the app's own playhead until it reaches `beat`. */
async function waitForBeat(beat, budgetMs = 20000) {
  const deadline = Date.now() + budgetMs;
  let last = -1;
  while (Date.now() < deadline) {
    last = await playhead();
    if (typeof last === "number" && last >= beat) return last;
    await sleep(60);
  }
  return last;
}

/** Every MIDI note on one track, with the clip it came from. */
async function notesOn(trackID) {
  const snap = await cmd("project.snapshot");
  const track = (snap.result?.tracks ?? []).find((t) => t.id === trackID);
  const out = [];
  for (const clip of track?.clips ?? []) {
    const got = await cmd("clip.getNotes", { clipId: clip.id });
    for (const note of got.result?.notes ?? []) {
      // ⚠️ `clipStartBeat`, NOT `startBeat` — the m34-h probe's own lesson: a
      // spread would SHADOW the clip's start with the note's clip-relative one
      // and the alignment check would pass on the wrong number.
      out.push({ clip: clip.name, clipStartBeat: clip.startBeat, ...note });
    }
  }
  return out;
}

async function awaitNotes(trackID, wanted, budget = 24) {
  let seen = [];
  for (let i = 0; i < budget; i++) {
    await sleep(250);
    seen = await notesOn(trackID);
    if (seen.length >= wanted) break;
  }
  return seen;
}

/**
 * Records one layer: arm, WAIT FOR THE WINDOW, then play two notes at fixed
 * delays after it opens.
 *
 * ⭐ The delays are identical for every layer, and the ARM instant is
 * deliberately different — that asymmetry is what makes the alignment
 * measurement meaningful rather than tautological.
 */
async function recordLayer(trackID, pitchA, pitchB, label) {
  const arm = await cmd("looper.armLayer", { trackId: trackID });
  ck(`${label}: looper.armLayer accepted`, arm.ok, arm.error);
  const armedAt = await playhead();
  const launch = arm.result?.pendingLaunchBeat;
  ck(`${label}: the deck reports a queued launch, not an immediate one`,
     arm.result?.pendingPhase === "queued" && typeof launch === "number",
     arm.result);
  // ⭐ THE PRE-ROLL IS GUARANTEED, NOT BEST-EFFORT: the window must be at least
  // a beat away, or the take's anchor would still not be live when it opened
  // and the layer's first chord would vanish with no visible cause.
  ck(`${label}: the launch boundary is at least a beat ahead of the press`,
     typeof launch === "number" && typeof armedAt === "number" && launch - armedAt >= 0.9,
     { armedAt, launch });

  await waitForBeat(launch);
  // The window is open. Everything from here is inside the layer.
  await sleep(320);
  let r = await cmd("note.play", { trackId: trackID, pitches: [pitchA] });
  ck(`${label}: note.play accepted`, r.ok, r.error);
  // ⭐ THE HONESTY LIGHT. If this is false the note sounded into no take at all,
  // and every onset measured below would be measuring nothing.
  ck(`${label}: recording:true on the armed track (the honesty light)`,
     r.result?.recording === true, r.result);
  await sleep(700);
  r = await cmd("note.play", { trackId: trackID, pitches: [pitchB] });
  await sleep(320);
  await cmd("note.play", { trackId: trackID, pitches: [] });

  const finish = await cmd("looper.finishLayer");
  ck(`${label}: looper.finishLayer accepted`, finish.ok, finish.error);
  const closeAt = finish.result?.pendingPhase;
  ck(`${label}: the pass is CLOSING at a boundary, not chopped at the press`,
     closeAt === "closing", finish.result);
  return { launch, armedAt };
}

// ---------------------------------------------------------------------------
// SETUP
// ---------------------------------------------------------------------------
console.log("\n=== SETUP ===");

let r = await cmd("project.new", { discardChanges: true });
ck("project.new", r.ok, r.error);

r = await cmd("track.add", { name: "Deck Chords", kind: "instrument" });
const chords = r.result?.id;
ck("track.add chords", r.ok && !!chords, r.error);

r = await cmd("track.add", { name: "Deck Bass", kind: "instrument" });
const bass = r.result?.id;
ck("track.add bass", r.ok && !!bass, r.error);

// ⚠️ COUNT-IN PINNED TO 0: the project default is ONE bar (m23-cy), which is
// 2.0 s at 120 BPM. It is inert on the LAYER path by design, but
// `transport.record` is never used here anyway and pinning it removes a whole
// class of "why did the first note vanish" from this gate's failure modes.
r = await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
ck("count-in pinned to 0", r.ok && r.result?.countInBars === 0, r.result);

// ⭐ SWITCH INSTRUMENT between the layers — the user's own words ("switch
// instrument and play another sequence"). GM sound banks only: a third-party
// AUv2 wedges the main actor for minutes on this machine.
// GM is always the first entry (the "gm" sentinel), so no download is needed.
const banks = await cmd("instrument.listSoundBanks");
const hasGM = (banks.result?.banks ?? []).some((b) => b.source === "gm" || b.id === "gm");
const setChords = await cmd("track.setInstrument",
  { trackId: chords, soundBank: { source: "gm", program: 4 } });    // electric piano
const setBass = await cmd("track.setInstrument",
  { trackId: bass, soundBank: { source: "gm", program: 33 } });     // fingered bass
const instrumentsSwitched = setChords.ok && setBass.ok &&
  setChords.result?.soundBank?.program === 4 && setBass.result?.soundBank?.program === 33;
console.log(`[measured] GM listed=${hasGM}; chords program=` +
  `${setChords.result?.soundBank?.program}, bass program=${setBass.result?.soundBank?.program}`);
// ⭐ THE USER'S OWN WORDS: "switch instrument and play another sequence". The
// two layers are not merely on two tracks, they are on two DIFFERENT sounds —
// read back off the response, not assumed from the call returning ok.
ck("⭐ the two layers carry DIFFERENT instruments (GM 4 vs GM 33)",
   instrumentsSwitched,
   { chords: setChords.result?.soundBank, bass: setBass.result?.soundBank });

// ---------------------------------------------------------------------------
// NEGATIVE CONTROL FIRST — the deck must REFUSE under the transport loop, and
// must refuse an arm with nothing playing. Run before anything succeeds, so a
// later refusal cannot be confused with a dead route.
// ---------------------------------------------------------------------------
console.log("\n=== NEGATIVE CONTROLS ===");

r = await cmd("looper.status");
ck("looper.status answers null with no session open", r.ok && r.result === null, r.result);

r = await cmd("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 8 });
ck("transport.setLoop enabled (for the refusal)", r.ok, r.error);
r = await cmd("looper.begin", { bars: 2 });
ck("⛔ looper.begin REFUSES while the transport loop is enabled", r.ok === false, r);
ck("and the refusal names the take-comping feature it is NOT",
   typeof r.error === "string" && /comping/.test(r.error), r.error);
r = await cmd("transport.setLoop", { enabled: false });
ck("transport loop disabled again", r.ok, r.error);

r = await cmd("looper.begin", { bars: 2 });
ck("looper.begin opens a session", r.ok, r.error);
ck("⭐ the FIRST loop's length is fixed in advance: 2 bars = 8 beats",
   r.result?.cycleBeats === 8 && r.result?.lengthMode === "fixedBars", r.result);
ck("and no layer exists yet", (r.result?.lamps ?? []).length === 0, r.result);

r = await cmd("looper.armLayer", { trackId: chords });
ck("⛔ armLayer REFUSES with nothing playing, and teaches what to do",
   r.ok === false && /press play first/.test(r.error ?? ""), r);

r = await cmd("looper.undoLayer");
ck("⛔ undoLayer REFUSES with nothing to peel", r.ok === false, r);

// ---------------------------------------------------------------------------
// THE PIECE — play ONCE, then never stop.
// ---------------------------------------------------------------------------
console.log("\n=== THE PIECE: play once, stack two layers, peel one ===");

r = await cmd("transport.play");
ck("transport.play (the ONE start)", r.ok, r.error);

// A deliberately UGLY arm instant for layer one: mid-bar, mid-cycle.
await sleep(430);
const one = await recordLayer(chords, 60, 67, "layer 1");

const beatBeforeLanding = await playhead();
const chordNotes = await awaitNotes(chords, 2);
ck("⭐ LAYER 1 IS REALLY ON THE TIMELINE — read out of clip.getNotes",
   chordNotes.length >= 2, chordNotes);

// ⭐ A DIFFERENT UGLY OFFSET for layer two. The press timings now differ by a
// large, deliberate amount; the onsets must NOT.
await sleep(910);
const two = await recordLayer(bass, 40, 47, "layer 2");
const bassNotes = await awaitNotes(bass, 2);
ck("⭐ LAYER 2 IS REALLY ON THE TIMELINE, on its OWN track",
   bassNotes.length >= 2, bassNotes);

const beatAfterBoth = await playhead();
ck("⭐ THE PLAYHEAD RAN THROUGH BOTH LAYERS — the moving number, not a flag",
   typeof beatBeforeLanding === "number" && beatAfterBoth > beatBeforeLanding + 1,
   { beatBeforeLanding, beatAfterBoth });

// ---------------------------------------------------------------------------
// ⭐⭐ ALIGNMENT — THE MEASUREMENT THE ITEM LIVES ON.
// ---------------------------------------------------------------------------
console.log("\n=== ALIGNMENT: do the two layers line up? ===");

const cycleBeats = 8;
const status = await cmd("looper.status");
const origin = status.result?.originBeat;
ck("looper.status reports the deck's origin", typeof origin === "number", status.result);

// Each note's position WITHIN the cycle. A layer's clip starts at the origin
// and its notes are clip-relative, so the phase is just `startBeat mod cycle`.
// ⚠️ DE-DUPLICATED, AND THIS IS NOT TIDINESS. A layer's clip is the cycle
// TILED, so every repeat of a note shares its phase exactly: a raw sorted list
// is `[p1, p1, p1, …, p2, p2, …]`, and comparing element [1] of two such lists
// compares a note with ITSELF. The first draft of this gate did exactly that
// and its "second onset" leg was green by construction.
const distinct = (xs) => {
  const out = [];
  for (const x of [...xs].sort((a, b) => a - b)) {
    if (!out.length || Math.abs(x - out[out.length - 1]) > 1e-6) out.push(x);
  }
  return out;
};
const phase = (note) => ((note.startBeat % cycleBeats) + cycleBeats) % cycleBeats;
const chordPhases = distinct(chordNotes.map(phase));
const bassPhases = distinct(bassNotes.map(phase));

console.log(`[measured] press instants: layer1 armed at ${one.armedAt} (window ${one.launch}), ` +
            `layer2 armed at ${two.armedAt} (window ${two.launch})`);
console.log(`[measured] layer 1 onsets within the cycle: ${JSON.stringify(chordPhases.slice(0, 2))}`);
console.log(`[measured] layer 2 onsets within the cycle: ${JSON.stringify(bassPhases.slice(0, 2))}`);

const pressDelta = Math.abs((two.armedAt - two.launch) - (one.armedAt - one.launch));
console.log(`[measured] the two presses differed by ${pressDelta.toFixed(3)} beats relative to ` +
            `their windows`);

const firstOffset = Math.abs((chordPhases[0] ?? 99) - (bassPhases[0] ?? -99));
const secondOffset = Math.abs((chordPhases[1] ?? 99) - (bassPhases[1] ?? -99));
console.log(`[measured] onset offset layer2 - layer1: first ${firstOffset.toFixed(3)} beats, ` +
            `second ${secondOffset.toFixed(3)} beats`);

// ⭐⭐ THE CLAIM. Both layers were played the SAME delay after their own windows
// opened, so their onsets must agree WITHIN the cycle even though the presses
// did not. The tolerance is the poll interval plus a round trip (~0.15 beats at
// 120 BPM), doubled for headroom — far tighter than any quantization bug, which
// would put the second layer a whole bar or an arbitrary fraction of a cycle
// away.
ck("⭐⭐ LAYER 2's FIRST ONSET LANDS WHERE LAYER 1's DID, within the cycle",
   firstOffset < 0.35, { chordPhases, bassPhases, firstOffset });
ck("⭐⭐ ...and so does the second onset — the whole layer is aligned, not just its head",
   secondOffset < 0.35, { chordPhases, bassPhases, secondOffset });
ck("⭐ and this is NOT tautological: the two presses really did differ",
   pressDelta > 0.25, { pressDelta, one, two });
// ⭐ AND THE TWO ONSETS ARE GENUINELY TWO. Both notes were played 700 ms apart
// (1.4 beats at 120 BPM), so a layer whose phases collapsed to one value would
// mean the fold had flattened the performance — and the offset legs above would
// still be green.
ck("⭐ each layer has TWO distinct onsets, ~1.4 beats apart as played",
   chordPhases.length >= 2 && bassPhases.length >= 2 &&
     Math.abs((chordPhases[1] - chordPhases[0]) - 1.4) < 0.35 &&
     Math.abs((bassPhases[1] - bassPhases[0]) - 1.4) < 0.35,
   { chordPhases, bassPhases });

// Both layers' clips start at the deck origin and repeat: that is what makes
// them LOOPS rather than one-shots.
ck("⭐ both layers are ONE repeating clip each, starting at the deck origin",
   chordNotes[0]?.clipStartBeat === origin && bassNotes[0]?.clipStartBeat === origin,
   { chordStart: chordNotes[0]?.clipStartBeat, bassStart: bassNotes[0]?.clipStartBeat, origin });
ck("⭐ and the material REPEATS — more notes than were played, at cycle multiples",
   chordNotes.length > 2 && bassNotes.length > 2,
   { chords: chordNotes.length, bass: bassNotes.length });

// ---------------------------------------------------------------------------
// LOOK AT IT — a UI phase is not done until someone has looked.
// ---------------------------------------------------------------------------
console.log("\n=== LOOK: the lamp strip, mid-session ===");
r = await cmd("looper.armLayer", { trackId: bass });
ck("a third pass armed, so the capture shows a QUEUED lamp beside a PLAYING one",
   r.ok, r.error);
await sleep(250);
r = await cmd("debug.captureUI", { path: `${SCRATCH}/m34h1-deck-strip.png` });
ck("debug.captureUI wrote a frame", r.ok, r.error);
console.log(`[capture] ${SCRATCH}/m34h1-deck-strip.png`);
// Unwind the third pass — it was for the picture, not the piece.
r = await cmd("looper.finishLayer", { immediate: true });
console.log(`[measured] third pass unwound: ok=${r.ok}`);

// ---------------------------------------------------------------------------
// ⭐⭐ PEEL THE LAST LAYER WHILE THE MUSIC PLAYS — the most-used control.
// ---------------------------------------------------------------------------
console.log("\n=== PEEL: take the last layer back without stopping ===");

const beatBeforePeel = await playhead();
r = await cmd("looper.undoLayer");
ck("looper.undoLayer accepted", r.ok, r.error);
console.log(`[measured] peel: ${JSON.stringify(r.result)}`);

await sleep(900);
const beatAfterPeel = await playhead();
ck("⭐⭐ THE MUSIC KEPT RUNNING ACROSS THE PEEL — the playhead advanced",
   typeof beatBeforePeel === "number" && beatAfterPeel > beatBeforePeel + 0.5,
   { beatBeforePeel, beatAfterPeel });

const afterPeel = await cmd("project.snapshot");
const bassTrack = (afterPeel.result?.tracks ?? []).find((t) => t.id === bass);
const chordTrack = (afterPeel.result?.tracks ?? []).find((t) => t.id === chords);
ck("⭐ the peeled layer's clip is GONE from the timeline",
   (bassTrack?.clips ?? []).length === 0, bassTrack?.clips);
ck("⭐ and the layer underneath is untouched",
   (chordTrack?.clips ?? []).length === 1, chordTrack?.clips);

const deckAfter = await cmd("looper.status");
ck("looper.status agrees with the timeline — one lamp left, and it is PLAYING",
   (deckAfter.result?.lamps ?? []).length === 1 &&
     deckAfter.result?.lamps?.[0]?.state === "playing",
   deckAfter.result);

// ---------------------------------------------------------------------------
// THE STRUCTURAL CLAIM
// ---------------------------------------------------------------------------
console.log("\n=== STRUCTURAL: was the music ever stopped? ===");
const stops = sentVerbs.filter((v) => v === "transport.stop").length;
const plays = sentVerbs.filter((v) => v === "transport.play").length;
const records = sentVerbs.filter((v) => v === "transport.record").length;
console.log(`[measured] before teardown: transport.stop ${stops}x, transport.play ${plays}x, ` +
            `transport.record ${records}x`);
ck("⭐ transport.stop was NEVER sent while the piece was being built", stops === 0, sentVerbs);
ck("⭐ transport.play was sent EXACTLY ONCE, at the start", plays === 1, sentVerbs);
ck("⭐ transport.record was never used — every layer went through the deck", records === 0, sentVerbs);

// ---------------------------------------------------------------------------
// TEARDOWN — the one and only stop.
// ---------------------------------------------------------------------------
r = await cmd("looper.end");
ck("looper.end closes the session", r.ok, r.error);
const kept = await cmd("project.snapshot");
ck("⭐ ending the session LEAVES the layer on the timeline — it is an ordinary clip",
   ((kept.result?.tracks ?? []).find((t) => t.id === chords)?.clips ?? []).length === 1,
   kept.result?.tracks?.map((t) => ({ n: t.name, c: (t.clips ?? []).length })));

r = await cmd("transport.stop");
ck("transport.stop (teardown, the one and only)", r.ok, r.error);

console.log(`\n[measured] m34-h-1: two layers stacked on two tracks, aligned to ` +
            `${firstOffset.toFixed(3)}/${secondOffset.toFixed(3)} beats despite presses ` +
            `${pressDelta.toFixed(3)} beats apart, one peeled live, ` +
            `instrumentSwitched=${instrumentsSwitched}, zero stops.`);

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
