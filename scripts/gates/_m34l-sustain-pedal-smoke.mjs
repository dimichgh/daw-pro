// m34-l SMOKE — THE SUSTAIN PEDAL, PROVEN THREE WAYS: heard, recorded, and
// heard again out of the recording.
//
// ══ WHY THIS GATE EXISTS ════════════════════════════════════════════════════
//
// The item's own blocker comment said sustain was cut from v1 because "adding
// key bindings that reach nothing would be four more keys claimed for no
// sound". A pedal that pushes a CC nobody consumes is exactly that — and it
// would pass any unit test that counted bytes leaving the store. So this gate
// refuses to be satisfied by a CC that left:
//
//   LEG 1  THE INSTRUMENTS ACTUALLY HONOUR CC 64 — measured live, on ALL THREE
//          shipped instrument paths (built-in poly synth, built-in sampler,
//          hosted GM sound bank), through the AUDITION ring the Tab key uses.
//          ⛔ Includes the PAST-8-SECOND window, which is where the m34-l
//          renderer defect lived: before the fix every one of the three read
//          SILENT past `liveTailSeconds`.
//   LEG 2  THE PERFORMANCE REACHES THE CLIP — a real armed take, read back out
//          with clip.getNotes, CC 64 lane present with both edges.
//   LEG 3  THE RENDER DIFFERS, IN THE TAIL — the same take rendered with the
//          lane and with it removed, measured in a window that opens AFTER the
//          key-up.
//   LEG 4  THE PEDAL CANNOT BE STRANDED — take end lifts it and the lane
//          CLOSES at 0 rather than parking at 127.
//
// ⭐ WHY A TAIL WINDOW AND NOT INTEGRATED LOUDNESS. Sustain does not change how
// LOUD anything is; it changes how LONG it lasts. Integrated loudness over a
// whole file moves only a little and moves for many reasons, so it is a weak
// instrument for this question. The tail window is the strong one: after the
// key-up the un-pedalled render is SILENCE and the pedalled one is programme,
// which is a difference no threshold argument is needed to read.
//
// ⚠️ `ffmpeg -v error` SUPPRESSES the `ebur128` and `astats` summaries, which
// log at INFO. Every ffmpeg invocation here uses `-hide_banner` and reads
// stderr.
//
// ⚠️ THE INSTRUMENT FOR LEG 3 IS THE BUILT-IN POLY SYNTH, DELIBERATELY. The
// sax team's defect ③ (an AU render dropping the first clip) is live and would
// confound an offline render through the hosted sound-bank path; LEG 1 covers
// that path LIVE, where the defect does not apply.
//
// ⛔⛔ WHAT THIS GATE CANNOT DO, SAID PLAINLY: IT CANNOT PRESS A PHYSICAL KEY.
// Every pedal edge here arrives over the wire (`play.sustain`) or through
// `debug.musicalTyping`, which synthesizes an NSEvent below the monitor. That
// covers the LATCH, the SEAM and the SOUND completely, and covers DELIVERY of
// a real Tab keystroke not at all. Whether AppKit hands Tab to the monitor
// rather than moving focus is a HAND CHECK, named in the item.
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sleep, buildOrAbort, startStaging, stopStaging, connect, verdict,
} from "./_staging.mjs";

const GATE = "m34l-sustain-pedal-smoke";
const OUT = process.env.M34L_OUT_DIR ?? join(tmpdir(), "m34l-sustain-pedal");
mkdirSync(OUT, { recursive: true });

buildOrAbort({ label: "building staging binary (m34-l)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34l${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 90000);
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

/// ⛔⛔ EVERY SETUP CALL GOES THROUGH HERE. m34-f's gate recorded the reason: a
/// setup call whose `ok:false` is ignored makes every assertion after it
/// vacuous, and an unopened surface reports exactly what a working-but-idle one
/// reports. A failed setup now stops the run.
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (r.ok === false) throw new Error(`${command} FAILED: ${r.error}`);
  return body(r);
}

/// Integrated loudness of `path`, optionally of a WINDOW starting at `ss`
/// seconds and lasting `dur` seconds. dB LUFS, or null.
///
/// ⚠️ `-hide_banner`, never `-v error`: the `ebur128` summary logs at INFO and
/// `-v error` deletes exactly the number this gate exists to read.
/// ⚠️ `spawnSync`, not `execFileSync`: ffmpeg exits 0 on success, so
/// `execFileSync`'s stderr is only reachable through a throw that never
/// happens. m34-f's gate read `null` for two working files that way.
function ffmpegLufs(path, ss = null, dur = null) {
  const args = ["-hide_banner", "-nostats"];
  if (ss !== null) args.push("-ss", String(ss));
  if (dur !== null) args.push("-t", String(dur));
  args.push("-i", path, "-filter_complex", "ebur128=peak=true", "-f", "null", "-");
  const r = spawnSync("ffmpeg", args, { encoding: "utf8" });
  const out = String(r.stderr ?? "");
  const m = /I:\s*(-?\d+(?:\.\d+)?)\s*LUFS/g;
  let last = null, hit;
  while ((hit = m.exec(out)) !== null) last = parseFloat(hit[1]);
  return last;
}

/// Peak level of a window, in dBFS, from `astats`. THE SECOND INSTRUMENT: a
/// gate that trusted one number could be fooled by a renderer that also broke
/// its own meter, and `ebur128` gates itself on a loudness window while
/// `astats` does not — so on a nearly-silent tail they can genuinely disagree,
/// and that disagreement is a finding rather than noise.
function ffmpegPeakDb(path, ss = null, dur = null) {
  const args = ["-hide_banner", "-nostats"];
  if (ss !== null) args.push("-ss", String(ss));
  if (dur !== null) args.push("-t", String(dur));
  args.push("-i", path, "-af", "astats=measure_overall=Peak_level:measure_perchannel=none",
            "-f", "null", "-");
  const r = spawnSync("ffmpeg", args, { encoding: "utf8" });
  const m = /Peak level dB:\s*(-?\d+(?:\.\d+)?|-inf)/.exec(String(r.stderr ?? ""));
  if (!m) return null;
  return m[1] === "-inf" ? -Infinity : parseFloat(m[1]);
}

const wrote = p => existsSync(p) && statSync(p).size > 1024;

// ═══════════════════════════════════════════════════════════════════════════
// LEG 1 — DO THE INSTRUMENTS ACTUALLY HONOUR CC 64? (the lead question)
// ═══════════════════════════════════════════════════════════════════════════

const q = async () => {
  const s = body(await cmd("mixer.liveLoudness", {}));
  return typeof s.momentaryLufs === "number" ? s.momentaryLufs : null;
};
async function maxOver(ms, label) {
  const t0 = Date.now();
  let best = null, seen = 0;
  while (Date.now() - t0 < ms) {
    const v = await q(); seen++;
    if (v !== null && (best === null || v > best)) best = v;
    await sleep(110);
  }
  console.log(`    ${label}: max=${best === null ? "null" : best.toFixed(2)} (${seen} samples)`);
  return best;
}

// ⚠️ ZONE KEYS ARE `minPitch`/`maxPitch`, NOT `loMidi`/`hiMidi` — the first
// draft of this gate used the latter and would have died at the wire boundary
// on `rejectUnknownKeys` before measuring anything. And `loopMode:"continuous"`
// is copied VERBATIM from `_m34f-live-expression-smoke.mjs`, which measured it
// working: the bundled tone is a 0.35 s one-shot, so without a loop the note is
// over long before the 9.2 s window below and every leg would read "silent"
// for a reason that has nothing to do with the pedal.
const LOOPED_SAMPLER = {
  kind: "sampler",
  sampler: { zones: [{
    path: "builtin:test-tone-a4", rootPitch: 69, minPitch: 0, maxPitch: 127,
    loopMode: "continuous", release: 0.05 }] },
  gain: 0.8,
};
const POLY = { kind: "polySynth", waveform: "saw", attack: 0.005, decay: 0.005,
               sustain: 1.0, release: 0.05, gain: 0.8 };
const SOUND_BANK = { kind: "soundBank", soundBank: { source: "gm", program: 19 } };

async function honoursCC64(label, instrument) {
  console.log(`\n  ── LEG 1 · ${label} ──`);
  await must("project.new", { discardChanges: true });
  const t = await must("track.add", { kind: "instrument", name: `m34l ${label}` });
  const trackId = t.id ?? t.track?.id;
  await must("track.setInstrument", { trackId, ...instrument });
  await sleep(2500);
  await cmd("mixer.liveLoudness", { reset: true });

  // CONTROL FIRST: with no pedal, the key-up must silence it. Without this leg
  // the pedal legs below would pass against an instrument that ignored every
  // note-off — "it is still making noise" is not "the pedal worked".
  await must("note.play", { trackId, pitches: [69], velocity: 110 });
  const ctlHeld = await maxOver(900, "control key DOWN");
  await must("note.play", { trackId, pitches: [] });
  await sleep(700);
  const ctlAfter = await maxOver(1000, "control key UP, NO pedal");
  await sleep(900);

  // THE PEDAL, over the wire — the same CC 64 the Tab key sends.
  await must("play.sustain", { trackId, down: true });
  await must("note.play", { trackId, pitches: [69], velocity: 110 });
  await maxOver(900, "pedal key DOWN");
  const offAt = Date.now();
  await must("note.play", { trackId, pitches: [] });
  await sleep(700);
  const ped1 = await maxOver(1000, "pedal key UP  t+0.7..1.7s");
  // ⛔ THE DISCRIMINATING WINDOW, and it is not padding. `liveTailSeconds` is
  // 8 s: before m34-l's renderer fix every one of these three read SILENT here
  // while reading full level at t+5 s. A leg measured any earlier sits entirely
  // inside the region the broken code handled correctly.
  while (Date.now() - offAt < 9200) await sleep(150);
  const ped9 = await maxOver(1400, "pedal key UP  t+9.2s  << PAST liveTailSeconds=8");
  await must("play.sustain", { trackId, down: false });
  await sleep(900);
  const lifted = await maxOver(1000, "pedal LIFTED");

  ok(ctlHeld !== null && ctlHeld > -60, `LEG1 ${label}: the note sounds at all`,
     `momentary=${ctlHeld}`);
  ok(ctlAfter === null || ctlAfter < ctlHeld - 20,
     `LEG1 ${label}: CONTROL — key-up with no pedal goes silent`,
     `held=${ctlHeld} after=${ctlAfter}`);
  ok(ped1 !== null && ped1 > ctlHeld - 6,
     `LEG1 ${label}: HONOURS CC 64 — key-up under the pedal keeps sounding`,
     `held=${ctlHeld} pedalled-after=${ped1}`);
  ok(ped9 !== null && ped9 > ctlHeld - 6,
     `LEG1 ${label}: still sounding PAST liveTailSeconds (the m34-l renderer fix)`,
     `t+9.2s=${ped9}`);
  ok(lifted === null || lifted < ctlHeld - 20,
     `LEG1 ${label}: lifting the pedal releases it`,
     `lifted=${lifted}`);
}

try {
  await honoursCC64("polySynth", POLY);
  await honoursCC64("sampler", LOOPED_SAMPLER);
  await honoursCC64("soundBank(GM organ)", SOUND_BANK);

  // ═════════════════════════════════════════════════════════════════════════
  // LEG 2 — THE PERFORMANCE REACHES THE CLIP
  // ═════════════════════════════════════════════════════════════════════════
  console.log("\n  ── LEG 2 · performed into a real armed take ──");
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { kind: "instrument", name: "m34l pedal take" });
  const trackId = track.id ?? track.track?.id;
  await must("track.setInstrument", { trackId, ...POLY });
  await must("track.setArm", { trackId, armed: true });
  await sleep(1200);

  // ⛔⛔ COUNT-IN IS ON BY DEFAULT (`countInBars: 1`, m23-cy) AND THE FIRST
  // DRAFT OF THIS GATE WOULD HAVE RECORDED NOTHING. Pinned explicitly here so
  // the gate does not ride a default, and the wait is taken from the MEASURED
  // numbers in `Model.swift:2310`: at 120 BPM 4/4 with one bar of count-in a
  // note struck 2321 ms after `transport.record` landed at beat 0.488, while a
  // note struck 428 ms after record — i.e. DURING the count-in — recorded
  // NOTHING. This gate slept 400 ms. It would have produced an empty clip and
  // blamed the pedal for it, which is this tree's named failure shape: a leg
  // that returns a plausible-looking negative for a reason unrelated to the
  // thing under test.
  await must("transport.setMetronome", { enabled: true, countInBars: 1 });
  // ⚠️ PIN THE TEMPO rather than read it back. The first run printed
  // `tempo undefined` — `project.snapshot`'s transport object does not carry a
  // `tempo` key under that name, so LEG 3's window silently used the `?? 120`
  // fallback. It happened to be right, which is the worse outcome: a window
  // computed from a default that LOOKED measured. 120 BPM = 0.5 s/beat, set
  // here and used as a literal below.
  await must("transport.setTempo", { bpm: 120 });
  await must("transport.record", {});
  await sleep(2400);
  await must("play.sustain", { trackId, down: true });
  await must("note.play", { trackId, pitches: [60], velocity: 110 });
  await sleep(350);
  // THE KEY GOES UP EARLY — the whole scenario. The note must ring on.
  await must("note.play", { trackId, pitches: [] });
  await sleep(2200);
  // ⛔ THE TAKE ENDS WITH THE PEDAL STILL DOWN, DELIBERATELY: LEG 4 is about
  // whether `stop()` closes the lane rather than parking it at 127.
  await must("transport.stop", {});
  await sleep(900);

  const snap = await must("project.snapshot", {});
  const tk = snap.tracks.find(t => t.id === trackId);
  const clip = (tk?.clips ?? [])[0];
  ok(!!clip, "LEG2 the take produced a clip", JSON.stringify(tk?.clips ?? []).slice(0, 200));

  // ⭐⭐ THE MEASURED SHAPE, AND THE STORY IS THE POINT. This gate's first run
  // reported "the CC 64 lane is NOT in the clip" for a lane that was right
  // there — because the matcher was written against a PREDICTED encoding. I
  // predicted `{"cc":{"controller":64}}` (a Swift enum-with-associated-value's
  // default derived form) and wrote a whole comment justifying it. THE REAL
  // WIRE SHAPE, printed by the line below on that run, is:
  //
  //     {"type":{"type":"cc","controller":64},"points":[…]}
  //
  // i.e. a NESTED object carrying its own `"type"` discriminator and a FLAT
  // `controller` beside it. Three legs went red on a product that was working
  // perfectly. ⭐ THE ONLY REASON THAT COST 30 SECONDS INSTEAD OF BECOMING A
  // FALSE DEFECT REPORT IS THE `console.log` OF THE RAW JSON — a matcher that
  // finds nothing and a lane that is not there produce the same `null`. Keep
  // the print. The matcher below accepts all three shapes so it cannot break
  // again on a re-encoding, but the ASSERTION it feeds is only meaningful
  // because the raw text sits next to it in the log.
  const isCC64 = l => {
    const t = l?.type;
    if (t === "cc" && Number(l.controller) === 64) return true;          // flat
    if (t && typeof t === "object") {
      if (t.type === "cc" && Number(t.controller) === 64) return true;   // MEASURED
      if (t.cc) return Number(t.cc.controller) === 64;                   // predicted
    }
    return false;
  };
  let lane = null, notes = [];
  if (clip) {
    const read = await must("clip.getNotes", { clipId: clip.id });
    notes = read.notes ?? [];
    const lanes = read.controllerLanes ?? clip.controllerLanes ?? [];
    lane = lanes.find(isCC64);
    console.log("    lanes RAW: " + JSON.stringify(lanes).slice(0, 500));
    console.log("    notes: " + JSON.stringify(notes).slice(0, 300));
  }
  ok(!!lane, "LEG2 the CC 64 lane is IN the clip — the pedal was recorded",
     JSON.stringify(clip?.controllerLanes ?? []).slice(0, 200));
  const pressPoint = (lane?.points ?? []).find(p => p.value >= 64);
  ok(!!pressPoint, "LEG2 the lane carries a PRESS (value >= 64 = down)",
     JSON.stringify(lane?.points ?? []));

  // ⭐ LEG 2b — THE NOTE SURVIVES ITS KEY-UP *IN THE RECORDING*. Not that the
  // note is long (it correctly is not — a recorded note ends where the key was
  // released, which is what every DAW does), but that the thing which makes it
  // ring on playback is in the clip AND outlasts it. A CC 64 lane whose press
  // landed AFTER the note-off would re-sustain nothing.
  const noteOff = notes.length ? notes[0].startBeat + notes[0].lengthBeats : null;
  ok(noteOff !== null && pressPoint && pressPoint.beat <= noteOff,
     "LEG2b the pedal was DOWN before the key came up — the note is held by it",
     `press@${pressPoint?.beat} noteOff@${noteOff}`);

  // ═════════════════════════════════════════════════════════════════════════
  // LEG 3 — THE RENDER DIFFERS, IN THE TAIL
  // ═════════════════════════════════════════════════════════════════════════
  console.log("\n  ── LEG 3 · rendered with and without the lane ──");
  const withPath = join(OUT, "m34l-with-pedal.wav");
  const withoutPath = join(OUT, "m34l-without-pedal.wav");

  await must("render.mixdown", { path: withPath });
  ok(wrote(withPath), "LEG3 the pedalled render wrote a real file", withPath);

  // THE A/B IS ONE LANE, NOTHING ELSE. Same clip, same notes, same timings,
  // same instrument — only CC 64 removed. A second performance would differ in
  // a dozen uncontrolled ways and prove nothing about the pedal.
  await must("clip.removeControllerLane", { clipId: clip.id, type: "cc", controller: 64 });
  await must("render.mixdown", { path: withoutPath });
  ok(wrote(withoutPath), "LEG3 the control render wrote a real file", withoutPath);

  // The window opens AFTER the key-up. 120 BPM = 0.5 s/beat.
  const secPerBeat = 60 / 120;   // PINNED above by transport.setTempo, not read back
  const clipStartSec = (clip.startBeat ?? 0) * secPerBeat;
  const tailFromSec = clipStartSec + (noteOff ?? 0) * secPerBeat + 0.4;
  const tailDur = 1.2;
  console.log(`    tail window: ${tailFromSec.toFixed(2)}s .. `
              + `${(tailFromSec + tailDur).toFixed(2)}s (tempo pinned 120)`);

  const withTail = ffmpegLufs(withPath, tailFromSec, tailDur);
  const withoutTail = ffmpegLufs(withoutPath, tailFromSec, tailDur);
  const withPeak = ffmpegPeakDb(withPath, tailFromSec, tailDur);
  const withoutPeak = ffmpegPeakDb(withoutPath, tailFromSec, tailDur);
  console.log(`[measured] tail LUFS   with=${withTail}  without=${withoutTail}`);
  console.log(`[measured] tail PEAKdB with=${withPeak}  without=${withoutPeak}`);

  // ⛔ THE SILENCE CONTROL, INVERTED FOR THIS LEG: here the CONTROL is supposed
  // to be silent, so the assertion that carries the meaning is that the
  // PEDALLED one is NOT. A meter answering the same number for everything would
  // fail this pair.
  ok(withTail !== null && withTail > -50,
     "LEG3 the PEDALLED render has real programme in the tail",
     `tail LUFS=${withTail}`);
  ok(withoutTail === null || withoutTail < withTail - 10,
     "LEG3 the control render's tail is quiet — the sustain is the difference",
     `with=${withTail} without=${withoutTail}`);
  // TWO INSTRUMENTS ON ONE QUESTION. `ebur128` gates on a loudness window and
  // `astats` does not, so agreement here is worth more than either alone.
  ok(withPeak !== null && withoutPeak !== null && withPeak > withoutPeak + 10,
     "LEG3 the SECOND instrument agrees — tail peak is higher with the pedal",
     `with=${withPeak} without=${withoutPeak}`);

  // ═════════════════════════════════════════════════════════════════════════
  // LEG 4 — THE PEDAL CANNOT BE STRANDED
  // ═════════════════════════════════════════════════════════════════════════
  console.log("\n  ── LEG 4 · the pedal cannot outlive its take ──");
  // The take above ENDED with the pedal down. `ProjectStore.stop()` must have
  // lifted it BEFORE `stopRecording()` finalized, so the lane closes at 0.
  // Without that the clip's lane ends at 127 — and CC 64 is one of the types
  // `resetsAtClipOnset` deliberately does NOT clear at a clip boundary, so
  // every clip played after it would inherit a pedal nobody pressed.
  const liftPoint = (lane?.points ?? []).filter(p => p.value < 64).pop();
  ok(!!liftPoint, "LEG4 the take's CC 64 lane CLOSES at 0 — the pedal lifted at take end",
     JSON.stringify(lane?.points ?? []));
  ok(liftPoint && pressPoint && liftPoint.beat > pressPoint.beat,
     "LEG4 the lift comes AFTER the press (the lane reads as a real gesture)",
     `press@${pressPoint?.beat} lift@${liftPoint?.beat}`);

  const stateAfter = body(await cmd("debug.musicalTyping", {}));
  ok(stateAfter.storeSustainDown === false,
     "LEG4 the store holds NO pedal after the take", JSON.stringify(stateAfter.storeSustainDown));

  // PANIC lifts it too — the path a user reaches for when something is stuck.
  const t2 = await must("track.add", { kind: "instrument", name: "m34l panic" });
  const panicTrack = t2.id ?? t2.track?.id;
  await must("track.setInstrument", { trackId: panicTrack, ...POLY });
  // ⚠️ WAIT FOR THE REBUILD. `setSustain` deliberately does NOT remember a
  // pedal whose push reached `.noRenderer` (LivePlay.swift:223 — otherwise the
  // matching lift would later be filtered away as "already up"), so pressing
  // into a rebuilding engine would leave `storeSustainDown` FALSE and this
  // leg's own precondition would fail for a reason that is not the pedal.
  await sleep(2500);
  await must("play.sustain", { trackId: panicTrack, down: true });
  const downState = body(await cmd("debug.musicalTyping", {}));
  ok(downState.storeSustainDown === true, "LEG4 precondition: the pedal really is down",
     JSON.stringify(downState.storeSustainDown));
  await must("transport.panic", {});
  const afterPanic = body(await cmd("debug.musicalTyping", {}));
  ok(afterPanic.storeSustainDown === false, "LEG4 panic lifts the pedal",
     JSON.stringify(afterPanic.storeSustainDown));

  // ═════════════════════════════════════════════════════════════════════════
  // LEG 5 — THE KEY AND THE LAMP (synthetic key path + a screenshot)
  // ═════════════════════════════════════════════════════════════════════════
  console.log("\n  ── LEG 5 · the Tab key and the lamp ──");
  await must("track.setInstrument", { trackId, ...POLY });
  // ⚠️ THERE IS NO `track.select` ON THE WIRE, and without an ACTIVE track the
  // Tab press is refused with `noTrack` — `setSustain`'s press gate reads
  // `targetState`, which is resolved from `AppModel.activeTrackID`, which is
  // written by a HEADER CLICK and by nothing else. `_m23ct-musical-typing-smoke`
  // measured the same thing for notes ("without it, every note reports
  // no-track"); the pedal inherits it because it shares the resolver. Driving
  // the click funnel is what a mouse would do.
  await must("debug.arrangeSelection", { act: "clickTrack", trackId });
  await sleep(2500);   // same rebuild wait as LEG 4, same reason
  await cmd("debug.musicalTyping", { enable: true });
  await sleep(400);
  const readyState = body(await cmd("debug.musicalTyping", {}));
  ok(readyState.targetState === "ready",
     "LEG5 precondition: the target is READY (an active instrument track)",
     JSON.stringify({ target: readyState.targetState, enabled: readyState.enabled }));
  const pressed = body(await cmd("debug.musicalTyping", { press: "tab" }));
  ok(pressed.decision === "performed" || pressed.sustainDown === true,
     "LEG5 a synthesized Tab press latches the pedal",
     JSON.stringify({ decision: pressed.decision, down: pressed.sustainDown }));
  ok(pressed.sustainDown === true && pressed.storeSustainDown === true,
     "LEG5 the LAMP and the STORE agree after the press — two instruments",
     JSON.stringify({ lamp: pressed.sustainDown, store: pressed.storeSustainDown }));

  const shotDown = join(OUT, "m34l-lamp-down.png");
  await cmd("debug.captureUI", { path: shotDown });
  ok(wrote(shotDown), "LEG5 captured the strip with the pedal DOWN", shotDown);

  const released = body(await cmd("debug.musicalTyping", { press: "tab" }));
  ok(released.sustainDown === false && released.storeSustainDown === false,
     "LEG5 a second Tab press lifts it — it is a TOGGLE",
     JSON.stringify({ lamp: released.sustainDown, store: released.storeSustainDown }));

  const shotUp = join(OUT, "m34l-lamp-up.png");
  await cmd("debug.captureUI", { path: shotUp });
  ok(wrote(shotUp), "LEG5 captured the strip with the pedal UP", shotUp);

  // ⛔ AND TAB MUST STILL BE REFUSED WHERE IT BELONGS TO SOMETHING ELSE. The
  // synthetic path can set the responder, which is the half a hand check cannot
  // enumerate quickly; the hand check covers the half this cannot (delivery).
  await cmd("debug.musicalTyping", { press: "tab" });   // down again
  const inField = body(await cmd("debug.musicalTyping",
                                 { press: "tab", command: true }));
  ok(inField.decision !== "performed",
     "LEG5 ⌘Tab is NOT claimed by musical typing", JSON.stringify(inField.decision));
  await cmd("debug.musicalTyping", { sustain: false });
  await cmd("debug.musicalTyping", { enable: false });
  const afterModeOff = body(await cmd("debug.musicalTyping", {}));
  ok(afterModeOff.storeSustainDown === false,
     "LEG5 turning the mode off leaves no pedal behind",
     JSON.stringify(afterModeOff.storeSustainDown));
} catch (e) {
  console.log("ABORT: " + (e?.stack ?? e?.message ?? String(e)));
  fail++;
} finally {
  stopStaging(GATE);
}

console.log(`\nrenders + screenshots written to ${OUT}`);
verdict({ ran: pass + fail, failed: fail });
