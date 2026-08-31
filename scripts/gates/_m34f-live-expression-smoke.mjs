// m34-f step ② SMOKE — EXPRESSION PERFORMED DURING A REAL TAKE, PROVEN TWICE:
// read back out of the clip, and HEARD in the render.
//
// ══ WHY THIS GATE EXISTS ════════════════════════════════════════════════════
//
// The pad's original live endpoint, `pad.previewEffort`, is preview-only by
// explicit design — its own description says "nothing is written to any clip,
// nothing is recorded". A pressure axis wired to THAT would sound perfect while
// the user performed it and would be **absent from the bounce**, which is this
// tree's characteristic failure mode stated exactly: a control that returns a
// plausible answer while doing something other than what it appears to do.
//
// So this gate refuses to be satisfied by a lane full of numbers. It asserts the
// number AND the sound:
//
//   LEG 1  the performance reaches the clip — read back with `project.snapshot`,
//          the way m34-b proved chord mode by reading recorded NOTES.
//   LEG 2  the render actually DIFFERS. Two mixdowns of the same take — one with
//          the performed lane, one with that lane removed — measured two
//          independent ways (the app's own BS.1770 meter and ffmpeg's
//          `ebur128`), asserted to differ by a real number of dB.
//
// ⭐ TWO INSTRUMENTS ON ONE QUESTION. If the app's meter and ffmpeg disagree
// about the delta, that disagreement is the finding — a gate that trusted one
// number could be fooled by a broken renderer that also broke its own meter.
//
// ⚠️ `ffmpeg -v error` SUPPRESSES the `ebur128` summary, which logs at INFO.
// Every ffmpeg invocation here uses `-hide_banner` and reads stderr.
//
// ⛔⛔ WHAT THIS GATE CANNOT DO, SAID PLAINLY: **it cannot press a trackpad.**
// Every value it performs arrives over the wire through `pad.playEffort`. That
// covers the SEAM (step ②) completely and covers the PRESSURE AXIS (step ①) not
// at all — the axis is exercised synthetically by `debug.breathPad {pressure}`
// in LEG 3, which drives the same model method the real `NSEventTypePressure`
// handler drives, and by `PadPressureTests` headless. Whether a real pressure
// event ever arrives, whether `.primaryGeneric` suppressed the Force Click
// detent, and whether the AppKit y-flip is right are HAND CHECKS.
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sleep, buildOrAbort, startStaging, stopStaging, connect, verdict,
} from "./_staging.mjs";

const GATE = "m34f-live-expression-smoke";
const OUT = process.env.M34F_OUT_DIR ?? join(tmpdir(), "m34f-live-expression");
mkdirSync(OUT, { recursive: true });

buildOrAbort({ label: "building staging binary (m34-f)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `m34f${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 60000);
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

/// ⛔⛔ **EVERY SETUP CALL GOES THROUGH HERE, AND THE REASON IS A DEFECT THIS
/// GATE ACTUALLY HAD.** The first draft called `clip.addMIDI` with `startBeat`
/// (the key is `atBeat`), ignored the `ok:false`, and then asserted three things
/// about a breath pad that had never opened — all three passed, because an
/// unopened pad reports exactly what a pressure-less pad reports. *A tool that
/// never ran and a tool that ran and found nothing produce identical output.*
/// A setup call that fails now stops the run instead of quietly making the
/// assertions vacuous.
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (r.ok === false) throw new Error(`${command} FAILED: ${r.error}`);
  return body(r);
}

/// ffmpeg's own integrated loudness, in dB LUFS, or null.
///
/// ⚠️ `-hide_banner`, never `-v error`: the `ebur128` summary logs at INFO and
/// `-v error` deletes exactly the number this gate exists to read.
function ffmpegLufs(path) {
  // ⚠️ `spawnSync`, NOT `execFileSync`. ffmpeg exits 0 on success, so
  // `execFileSync`'s stderr is reachable only through the throw that never
  // happens — the first draft read `e.stderr` and got `null` for both files
  // while ffmpeg was working perfectly. `spawnSync` hands back stderr either
  // way.
  const r = spawnSync("ffmpeg", ["-hide_banner", "-nostats", "-i", path,
                                 "-filter_complex", "ebur128=peak=true",
                                 "-f", "null", "-"],
                      { encoding: "utf8" });
  const out = String(r.stderr ?? "");
  const m = /I:\s*(-?\d+(?:\.\d+)?)\s*LUFS/g;
  let last = null, hit;
  while ((hit = m.exec(out)) !== null) last = parseFloat(hit[1]);
  return last;
}

try {
  // ────────────────────────────────────────────────────────────────────────
  // Fixture: one armed instrument track, no count-in, no metronome.
  //
  // ⚠️ `countInBars: 0` is EXPLICIT, not inherited. The project default is one
  // bar (2 s at 120 BPM); with it, everything performed in the first two seconds
  // lands PRE-ANCHOR, where a controller value LATCHES instead of streaming and
  // this gate would be measuring the latch rather than the performance.
  // ────────────────────────────────────────────────────────────────────────
  await must("project.new");
  const track = await must("track.add", { kind: "instrument", name: "Sax" });
  const trackId = track.id;
  await must("track.setArm", { trackId, armed: true });
  await must("transport.setMetronome", { enabled: false, countInBars: 0 });

  // ⛔⛔ **AN INSTRUMENT THAT ACTUALLY CONSUMES CC 11, AND THE APP TOLD ME WHY
  // THIS LINE HAS TO BE HERE.** The first run of this gate used a bare
  // instrument track and both renders came back at −21.281280064049806 LUFS —
  // IDENTICAL to fourteen decimal places. `clip.setControllerLane` had been
  // saying so all along: *"CC11 (expression) is stored but will not sound: this
  // track has no instrument yet, so nothing will play it."* The lane was
  // perfect; there was nothing to play it.
  //
  // The built-in `.sampler` is the honest choice for a step-② gate:
  // `SamplerInstrument.refreshExpressionTargets` computes
  // `ampMultiplier = ccValues[11] * …`, so CC 11 moves loudness with NO opt-in
  // parameter — unlike CC1/CC2, which are gated behind `expressionModDepth`.
  // `loopMode: "continuous"` makes the 0.35 s bundled tone sustain under a
  // 1.6 s swell; without it the note would be over before the gesture began.
  const instrument = await must("track.setInstrument", {
    trackId, kind: "sampler",
    sampler: {
      zones: [{ path: "builtin:test-tone-a4", rootPitch: 69, minPitch: 0, maxPitch: 127,
                loopMode: "continuous", release: 0.05 }],
    },
  });
  ok(instrument?.kind === "sampler" && (instrument?.sampler?.zones ?? []).length === 1,
     "the track has a real instrument that consumes CC 11",
     JSON.stringify(instrument).slice(0, 200));

  // ⭐ THE POSITIVE CONTROL FOR LEG 2, RUN BEFORE THE PERFORMANCE. The app's own
  // lane-consumption warning is the instrument that caught the dead first run;
  // asking it here means a future regression to a silent instrument fails with
  // the REASON attached instead of as a mysterious 0.00 dB delta.
  const probeClip = await must("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: 1,
    notes: [{ pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 1 }],
  });
  const probeLane = await must("clip.setControllerLane", {
    clipId: probeClip.id, type: "cc", controller: 11,
    points: [{ beat: 0, value: 40 }],
  });
  ok((probeLane.warnings ?? []).length === 0,
     "⭐ the app itself agrees this instrument will PLAY a CC 11 lane",
     JSON.stringify(probeLane.warnings ?? []));
  await must("edit.undo");
  await must("edit.undo");

  // ────────────────────────────────────────────────────────────────────────
  // THE PERFORMANCE. A held note under a hand-shaped swell — one hand on the
  // pitch, the other on the breath, which is the ergonomic idea the whole
  // feature is built around.
  // ────────────────────────────────────────────────────────────────────────
  await must("transport.record");
  const recording = body(await cmd("project.snapshot")).transport.isRecording;
  ok(recording === true, "a take is actually rolling",
     "nothing below means anything without this");

  // Past the take anchor, which is scheduled slightly AHEAD of `record` for
  // hardware latency. Measured elsewhere in this tree at ~70 ms; 400 ms is
  // comfortable and is the same settle `LivePlayCaptureTests` uses.
  await sleep(400);

  const held = body(await cmd("note.play", { trackId, pitches: [69], velocity: 100 }));
  ok(held.isRecording === true || held.recording === true,
     "the held note is going into the take (the honesty light, on the NOTE path)",
     JSON.stringify(held));

  // The swell: quiet → loud → quiet, performed over ~1.6 s.
  const performed = [0.12, 0.25, 0.45, 0.70, 0.92, 0.70, 0.45, 0.20];
  const echoes = [];
  for (const [i, value] of performed.entries()) {
    const gesture = i === 0 ? "begin" : "move";
    echoes.push(body(await cmd("pad.playEffort", { trackId, gesture, value })));
    await sleep(160);
  }
  const ended = body(await cmd("pad.playEffort", { trackId, gesture: "end" }));
  await cmd("note.play", { trackId, pitches: [] });
  await sleep(150);
  await cmd("transport.stop");
  await sleep(600);

  // ── The echo's own account, before anything is read back ──────────────────
  const delivered = echoes.filter(e => e.delivered);
  const captured = echoes.filter(e => e.capturedPoints > 0);
  ok(echoes[0].recording === true,
     "THE HONESTY LIGHT is on for the performed expression",
     JSON.stringify(echoes[0]));
  ok(captured.length >= 4,
     `at least 4 of ${echoes.length} performed values reported reaching the take`,
     `captured=${captured.length} delivered=${delivered.length}`);
  ok(ended.controllerValue === 127,
     "the release restores NEUTRAL rather than parking the last performed value",
     JSON.stringify(ended));
  ok(ended.capturedPoints === 1 && ended.recording === true,
     "⛔ and the RELEASE is recorded too — the monitor and the take must not diverge",
     JSON.stringify(ended));

  // ────────────────────────────────────────────────────────────────────────
  // LEG 1 — READ IT BACK OUT OF THE CLIP.
  // ────────────────────────────────────────────────────────────────────────
  const snap = body(await cmd("project.snapshot"));
  const clips = snap.tracks.flatMap(t => t.clips ?? []);
  const clip = clips.find(c => (c.controllerLanes ?? []).length > 0) ?? clips[0];
  ok(clip != null, "the take produced a clip");
  const lanes = clip?.controllerLanes ?? [];
  const lane = lanes.find(l => l.type?.type === "cc" && l.type?.controller === 11);
  ok(lane != null,
     "⭐ LEG 1 — the performed expression is IN THE CLIP, on CC 11",
     `lanes=${JSON.stringify(lanes.map(l => l.type))}`);

  const values = (lane?.points ?? []).map(p => p.value);
  const beats = (lane?.points ?? []).map(p => p.beat);
  console.log(`[measured] recorded lane: ${JSON.stringify(
    (lane?.points ?? []).map(p => [Number(p.beat.toFixed(3)), p.value]))}`);
  ok(values.length >= 5,
     `the lane carries the shape, not a single point (${values.length} points)`);
  ok(Math.max(...values, 0) >= 100,
     "the PEAK of the swell survived", `max=${Math.max(...values, 0)}`);
  ok(Math.min(...values.slice(0, -1), 127) <= 40,
     "and so did the quiet start", `min=${Math.min(...values.slice(0, -1), 127)}`);
  ok(values[values.length - 1] === 127,
     "the lane ENDS at neutral — what the user heard when they let go",
     `last=${values[values.length - 1]}`);
  ok(new Set(beats).size === beats.length && beats.every((b, i) => i === 0 || b > beats[i - 1]),
     "the points advance in time — a performance, not a stack");

  const notes = clip?.notes ?? [];
  ok(notes.length >= 1,
     "the take also holds the NOTE that was played — expression without a note is not a take",
     `notes=${notes.length}`);

  // ────────────────────────────────────────────────────────────────────────
  // LEG 2 — RENDER IT, AND SHOW THE AUDIO ACTUALLY DIFFERS.
  //
  // ⛔ A LANE FULL OF NUMBERS THAT NO BOUNCE REFLECTS IS PRECISELY THE FAILURE
  // STEP ② EXISTS TO PREVENT. The control is the SAME take with the performed
  // lane removed — same notes, same instrument, same window.
  // ────────────────────────────────────────────────────────────────────────
  const withPath = join(OUT, "with-expression.wav");
  const withoutPath = join(OUT, "without-expression.wav");

  const measuredWith = body(await cmd("render.measureLoudness", {}));
  await cmd("render.mixdown", { path: withPath });
  ok(existsSync(withPath) && statSync(withPath).size > 1000,
     "the expressive render wrote a real file",
     existsSync(withPath) ? String(statSync(withPath).size) : "missing");

  await cmd("clip.removeControllerLane", { clipId: clip.id, type: "cc", controller: 11 });
  const afterRemoval = body(await cmd("project.snapshot"))
    .tracks.flatMap(t => t.clips ?? []).find(c => c.id === clip.id);
  ok((afterRemoval?.controllerLanes ?? []).every(
       l => !(l.type?.type === "cc" && l.type?.controller === 11)),
     "the control really has no CC 11 lane (the A/B is an A/B)");

  const measuredWithout = body(await cmd("render.measureLoudness", {}));
  await cmd("render.mixdown", { path: withoutPath });
  ok(existsSync(withoutPath) && statSync(withoutPath).size > 1000,
     "the control render wrote a real file");

  const appWith = measuredWith?.measurement?.integratedLufs ?? null;
  const appWithout = measuredWithout?.measurement?.integratedLufs ?? null;
  const ffWith = ffmpegLufs(withPath);
  const ffWithout = ffmpegLufs(withoutPath);
  console.log(`[measured] app  LUFS  with=${appWith}  without=${appWithout}`);
  console.log(`[measured] ffmpeg LUFS with=${ffWith}  without=${ffWithout}`);

  // ⛔ THE SILENCE CONTROL. A meter that answers the same number for everything
  // — including nothing — would make every delta below meaningless. Both files
  // must read as real programme, well above the -70 LUFS gate.
  ok(appWith !== null && appWith > -70 && appWithout !== null && appWithout > -70,
     "both renders contain real programme, not silence",
     `${appWith} / ${appWithout}`);

  ok(ffWith !== null && ffWithout !== null,
     "ffmpeg produced an ebur128 summary for both files (-hide_banner, not -v error)",
     `${ffWith} / ${ffWithout}`);

  const appDelta = (appWithout ?? 0) - (appWith ?? 0);
  const ffDelta = (ffWithout ?? 0) - (ffWith ?? 0);
  console.log(`[measured] delta (without - with): app=${appDelta.toFixed(2)} dB  ` +
              `ffmpeg=${ffDelta.toFixed(2)} dB`);

  ok(appDelta >= 1.0,
     "⭐⭐ LEG 2 — the performed expression MEASURABLY CHANGES THE RENDER " +
     "(the control, with no lane, is louder)",
     `${appDelta.toFixed(2)} dB`);
  ok(ffDelta >= 1.0,
     "⭐ and ffmpeg agrees, independently",
     `${ffDelta.toFixed(2)} dB`);
  ok(Math.abs(appDelta - ffDelta) < 1.5,
     "⭐ TWO INSTRUMENTS AGREE on the size of the difference — them disagreeing " +
     "would be the finding",
     `app=${appDelta.toFixed(2)} ffmpeg=${ffDelta.toFixed(2)}`);

  // ────────────────────────────────────────────────────────────────────────
  // LEG 3 — THE PRESSURE AXIS, SYNTHETICALLY.
  //
  // ⚠️ THIS IS THE ONLY WAY ANY GATE HERE CAN TOUCH STEP ①, AND IT IS NOT A
  // TRACKPAD. `debug.breathPad {pressure}` calls the SAME model method
  // `PadPressureNSView.pressureChange(with:)` calls, so the mapping and the
  // capability latch are real; the hardware event, the haptic behaviour and the
  // coordinate flip are not covered and are hand checks.
  // ────────────────────────────────────────────────────────────────────────
  await must("project.new");
  const t2 = await must("track.add", { kind: "instrument", name: "Sax" });
  const trackId2 = t2.id;
  // ⚠️ `atBeat`, NOT `startBeat`. The first draft used `startBeat`, the call
  // failed, no clip existed, `debug.breathPad` early-returned on its own
  // `guard let clip`, and THREE assertions below passed against a pad that had
  // never opened.
  const clip2 = await must("clip.addMIDI", {
    trackId: trackId2, atBeat: 0, lengthBeats: 8,
    notes: [{ pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 8 }],
  });
  const clipId2 = clip2.id;

  const cold = body(await cmd("debug.breathPad", { clipId: clipId2 }));
  // ⛔⛔ THE ANTI-VACUITY GUARD, AND IT IS THE MOST IMPORTANT LINE IN LEG 3. An
  // unopened pad reports EXACTLY what a pressure-less pad reports — null
  // pressure, false capability, streamedEffort == effort. Without this, every
  // assertion below is satisfied by the pad never opening at all.
  ok(cold.visible === true,
     "⛔ POSITIVE CONTROL — the pad is actually OPEN (an unopened pad passes every leg below)",
     JSON.stringify({ visible: cold.visible, clipId: cold.clipId }));
  ok(cold.pressureObserved === false,
     "⛔ a pad nobody has pressed reports NO pressure capability — never a constant",
     JSON.stringify({ p: cold.pressure, obs: cold.pressureObserved }));
  ok(cold.pressure === null,
     "and `pressure` is null, which is a THIRD state beside 0 and 1");
  ok(Math.abs(cold.streamedEffort - cold.effort) < 1e-9,
     "with no pressure, what goes out IS the dot's effort — bit-for-bit the old pad",
     `${cold.streamedEffort} vs ${cold.effort}`);

  const pressed = body(await cmd("debug.breathPad", {
    clipId: clipId2, gesture: "begin", radius: 1.0, pressure: 0.5,
  }));
  ok(pressed.streaming === true,
     "⛔ POSITIVE CONTROL — a gesture really is open, so a stream can be observed at all",
     JSON.stringify({ streaming: pressed.streaming, visible: pressed.visible }));
  ok(pressed.pressureObserved === true, "a pressure event marks the machine capable");
  ok(Math.abs(pressed.pressure - 0.5) < 1e-9, "and the value is carried",
     String(pressed.pressure));
  ok(Math.abs(pressed.streamedEffort - pressed.effort * 0.5) < 1e-6,
     "⭐ LEG 3 — half pressure streams half the dot's effort, and the DOT DID NOT MOVE",
     `streamed=${pressed.streamedEffort} effort=${pressed.effort}`);

  const released = body(await cmd("debug.breathPad", { clipId: clipId2, gesture: "cancel" }));
  ok(released.pressure === null, "a lifted finger presses nothing");
  ok(released.pressureObserved === true,
     "but the machine does not stop being a Force Touch machine between gestures");
  await cmd("debug.breathPad", { close: true });
} catch (e) {
  fail++;
  console.log("FAIL harness threw  << " + (e?.stack ?? e));
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}

console.log(`\nrenders written to ${OUT} — open them if a delta ever looks wrong.`);
verdict({ ran: pass + fail, failed: fail });
