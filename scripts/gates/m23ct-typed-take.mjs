// m23-ct gate — THE QUESTION THIS ITEM EXISTS TO ANSWER: can something a user
// PLAYS live be recorded into a take?
//
// The user has no hardware MIDI controller ("no physical keyboard"), so until
// this landed, `MIDICaptureSession`, `transport.record`, punch and take comping
// were unreachable for them entirely — a fully-built subsystem with no door.
// This gate drives the new door (`note.play`) end to end against a real staged
// app and reads the RESULT out of the clip that landed, not out of any return
// value.
//
// ⭐⭐ TWO ARMS, AND THE NEGATIVE ONE IS MANDATORY. The positive arm records a
// two-note performance on an ARMED track and asserts the notes are there. The
// negative arm runs the IDENTICAL sequence on an UN-ARMED track and asserts
// zero notes anywhere. Without the negative arm an always-empty result would
// read as a pass on the wrong branch; without the positive arm first, the
// negative arm's emptiness is the weakest evidence there is. The positive arm
// IS the negative arm's positive control, so it runs FIRST and aborts loudly.
//
// ⚠️ The negative arm needs a SECOND, armed instrument track: `transport.record`
// refuses outright with `noArmedTracks` when nothing is armed, so "un-arm
// everything" would test the refusal instead of the capture gate. Track B is
// armed purely to make record legal; the assertion is that NEITHER track ends
// up with notes — a broken arm gate would land them on B, not on A.
//
// ⚠️ Waits are load-bearing, not padding. A take's anchor is scheduled slightly
// AHEAD of `transport.record` and `MIDICaptureSession` DROPS every note-on
// before it (the same rule that makes count-in work) — measured in
// `LivePlayCaptureTests`: a chord struck at t≈0 vanished while a note struck
// 120 ms later landed at beat 0.103.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m23ct-typed-take";
buildOrAbort({ label: "building staging binary (m23ct)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ct${++n}`;
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

/** Every MIDI note on every track, with its owning track/clip named. */
async function allNotes(trackIDs) {
  const snap = await cmd("project.snapshot");
  const tracks = snap.result?.tracks ?? [];
  const out = [];
  for (const track of tracks) {
    if (trackIDs && !trackIDs.includes(track.id)) continue;
    for (const clip of track.clips ?? []) {
      const got = await cmd("clip.getNotes", { clipId: clip.id });
      for (const note of got.result?.notes ?? []) {
        out.push({ track: track.name, clip: clip.name, ...note });
      }
    }
  }
  return out;
}

/** Plays 60, then 64, then releases — the same performance in both arms. */
async function playTwoNotes(trackId) {
  // Past the take anchor before the first note. See the header.
  await sleep(500);
  const first = await cmd("note.play", { trackId, pitches: [60] });
  await sleep(600);
  const second = await cmd("note.play", { trackId, pitches: [64] });
  await sleep(600);
  const release = await cmd("note.play", { trackId, pitches: [] });
  return { first, second, release };
}

// ---------------------------------------------------------------------------
// ARM 1 (POSITIVE — also the negative arm's positive control): armed track,
// two typed notes, and they must be IN the clip that lands.
// ---------------------------------------------------------------------------
console.log("\n=== ARM 1: ARMED — a typed performance must be RECORDED ===");

let r = await cmd("project.new", { discardChanges: true });
ck("project.new", r.ok, r.error);

r = await cmd("track.add", { name: "m23ct Typed", kind: "instrument" });
ck("track.add instrument", r.ok, r.error);
const armedTrack = r.result?.id;
ck("armed track has an id", typeof armedTrack === "string" && armedTrack.length > 0, r.result);

r = await cmd("track.setArm", { trackId: armedTrack, armed: true });
ck("track.setArm true", r.ok, r.error);

// ⚠️ EXPLICIT COUNT-IN 0, not inherited (m23-cy). The project default is now
// ONE bar, which delays the take anchor by 2.0 s at 120 BPM — four times the
// 500 ms `playTwoNotes` waits, so both notes would land pre-anchor and this
// gate would redden for a reason that has nothing to do with typed capture.
// This gate is about whether a PLAYED note reaches a take; count-in has its own
// gate (`m23cy-count-in-default.mjs`).
r = await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
ck("count-in pinned to 0 for this gate", r.ok && r.result?.countInBars === 0, r.result);

r = await cmd("transport.record", {});
ck("transport.record started", r.ok, r.error);

const played = await playTwoNotes(armedTrack);
ck("note.play [60] accepted", played.first.ok, played.first.error);
ck("note.play [64] accepted", played.second.ok, played.second.error);
ck("note.play [] accepted", played.release.ok, played.release.error);

// ⭐ THE HONESTY LIGHT. If this is false the notes sounded and went into no
// take — and every note assertion below would be measuring the wrong thing.
ck(
  "recording:true on the armed track (the honesty light)",
  played.first.result?.recording === true,
  played.first.result
);
ck(
  "capturedEdges: 1 on the first press, 2 on the change (off 60 + on 64)",
  played.first.result?.capturedEdges === 1 && played.second.result?.capturedEdges === 2,
  [played.first.result?.capturedEdges, played.second.result?.capturedEdges]
);
ck("holding:false after the release", played.release.result?.holding === false, played.release.result);

r = await cmd("transport.stop", {});
ck("transport.stop", r.ok, r.error);

// The take finalizes asynchronously — poll rather than assume.
let armedNotes = [];
for (let i = 0; i < 20; i++) {
  await sleep(250);
  armedNotes = await allNotes([armedTrack]);
  if (armedNotes.length > 0) break;
}
console.log("[measured] armed-arm notes: " + JSON.stringify(armedNotes));

ck("exactly 2 notes recorded", armedNotes.length === 2, armedNotes);
const byStart = [...armedNotes].sort((a, b) => a.startBeat - b.startBeat);
ck(
  "pitches are 60 then 64, in the order played",
  byStart.map((x) => x.pitch).join(",") === "60,64",
  byStart.map((x) => x.pitch)
);
ck(
  "both notes have a non-zero length",
  byStart.length === 2 && byStart.every((x) => x.lengthBeats > 0.01),
  byStart.map((x) => x.lengthBeats)
);
ck(
  "starts ascend — the second note begins after the first",
  byStart.length === 2 && byStart[1].startBeat > byStart[0].startBeat,
  byStart.map((x) => x.startBeat)
);

const positiveArmWorked = armedNotes.length === 2;
if (!positiveArmWorked) {
  // Loud, not quiet: without this the negative arm below is an empty probe and
  // its zero would be meaningless. A negative result from a probe that has
  // never found anything is the weakest evidence there is.
  console.log(
    "\n⛔ POSITIVE ARM FAILED — the negative arm's ZERO would prove NOTHING, " +
      "because a path that never records anything trivially records nothing " +
      "when un-armed. Fix the positive arm before reading the negative one."
  );
}

// ---------------------------------------------------------------------------
// ARM 2 (NEGATIVE CONTROL): the IDENTICAL sequence on an UN-ARMED track must
// record NOTHING — on that track OR on the armed one that made record legal.
// ---------------------------------------------------------------------------
console.log("\n=== ARM 2: NEGATIVE CONTROL — un-armed must record NOTHING ===");

r = await cmd("project.new", { discardChanges: true });
ck("project.new (arm 2)", r.ok, r.error);

r = await cmd("track.add", { name: "m23ct Unarmed", kind: "instrument" });
const unarmedTrack = r.result?.id;
ck("track.add unarmed target", r.ok && !!unarmedTrack, r.error);

// Armed ONLY so transport.record is legal (it refuses with noArmedTracks
// otherwise). Nothing is ever played on it.
r = await cmd("track.add", { name: "m23ct Bystander", kind: "instrument" });
const bystanderTrack = r.result?.id;
ck("track.add armed bystander", r.ok && !!bystanderTrack, r.error);
r = await cmd("track.setArm", { trackId: bystanderTrack, armed: true });
ck("bystander armed (record needs one)", r.ok, r.error);

// Same explicit 0 as arm 1 — and here it matters MORE, not less: with a
// count-in the negative arm would record nothing because everything was
// pre-anchor, so its zero would stop being evidence about ARMING at all.
r = await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
ck("count-in pinned to 0 for this gate (arm 2)", r.ok && r.result?.countInBars === 0, r.result);

r = await cmd("transport.record", {});
ck("transport.record started (arm 2)", r.ok, r.error);

const playedUnarmed = await playTwoNotes(unarmedTrack);
ck("note.play on an UN-ARMED track is still accepted (it sounds)", playedUnarmed.first.ok,
   playedUnarmed.first.error);
// ⭐ The honesty light must be OFF here: it sounded, and it went into no take.
ck(
  "recording:false on the un-armed track",
  playedUnarmed.first.result?.recording === false,
  playedUnarmed.first.result
);
ck(
  "capturedEdges:0 on an un-armed track",
  playedUnarmed.first.result?.capturedEdges === 0,
  playedUnarmed.first.result
);

r = await cmd("transport.stop", {});
ck("transport.stop (arm 2)", r.ok, r.error);

await sleep(1500);
const negativeNotes = await allNotes([unarmedTrack, bystanderTrack]);
console.log("[measured] negative-arm notes: " + JSON.stringify(negativeNotes));

ck("ZERO notes on the un-armed track", negativeNotes.filter((x) => x.track === "m23ct Unarmed").length === 0,
   negativeNotes);
// A broken arm gate would land the notes on the ARMED bystander (the capture
// session is engine-global and its take fans out to every armed instrument
// track), so this is the assertion that actually catches it.
ck("ZERO notes on the armed bystander that was never played",
   negativeNotes.filter((x) => x.track === "m23ct Bystander").length === 0, negativeNotes);
ck("ZERO notes anywhere in the negative arm", negativeNotes.length === 0, negativeNotes);

console.log(
  "\n[measured] m23-ct: armed arm recorded " +
    armedNotes.length +
    " note(s); un-armed arm recorded " +
    negativeNotes.length +
    " note(s)."
);

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
