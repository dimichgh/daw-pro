// m24-m legs B + C — CONVERT VOICE… RENDER PROBE (an instrument, not a gate).
//
// LEG C (the drag-a-voice-model-onto-a-track affordance) EXTENDS this file
// rather than adding a second one: it is the SAME panel reached a third way,
// and a probe per entry point would be three fixtures that can disagree about
// what the panel does.
//
// WHY THIS EXISTS: the m26-i sampler card shipped with passing tests, correct
// greps and a clean review, and NOBODY HAD RENDERED IT. A probe later showed
// the zone list collapsed to ~1.7 rows in the one state a first glance does not
// linger on. No gate in this tree can see a pixel, and this leg ships a card
// with THREE variable-height regions (voice list, clip list, warnings) and
// three faces (composer / converting / result) — exactly the shape that failure
// had.
//
// So this drives a REAL app on staging 17695, builds a real audio selection,
// opens the panel through the LITERAL Edit ▸ Convert funnel, and writes a PNG
// for every face — including the two a real run would cost minutes to reach
// (seeded through `debug.voicePanel`, which touches model state only: no
// sidecar, no engine, no track).
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort,
} from "./_staging.mjs";

const GATE = "m24m-convert-voice";
const SCRATCH = process.env.M24M_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 400)}`); }
};

// Browser-style WebSocket (addEventListener / ev.data) — Node's `.on` does not
// exist on it. Copied from _m28p7-breath-pad-probe.mjs.
let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m24m${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

/// A real 1-second stereo float WAV — `clip.addAudio` opens the file, so a
/// fabricated path would be refused before the panel ever saw a clip.
function makeWav(at, seconds = 1) {
  const rate = 48_000, channels = 2, frames = Math.round(rate * seconds);
  const dataBytes = frames * channels * 4;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20);                       // IEEE float
  buf.writeUInt16LE(channels, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * channels * 4, 28); buf.writeUInt16LE(channels * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames * channels; i++) buf.writeFloatLE(0.05, 44 + i * 4);
  fs.writeFileSync(at, buf);
}

const scratchWav = fs.mkdtempSync(path.join(os.tmpdir(), "m24m-"));

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1500 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);

  r = await cmd("track.add", { name: "Lead Vox", kind: "audio" });
  const vox = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("audio track added", r.ok && !!vox, r.error ?? JSON.stringify(r.result));

  r = await cmd("track.add", { name: "Keys", kind: "instrument" });
  const keys = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("instrument track added (the MIDI clip a marquee would sweep up)", r.ok && !!keys, r.error);

  // LEG C fixture. The three refusals need three DIFFERENT rows, and the empty
  // audio track is the one that discriminates: it proves the refusal is about
  // "no clips HERE, YET" and not merely about track kind.
  r = await cmd("track.add", { name: "Empty Vox", kind: "audio" });
  const emptyVox = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("empty audio track added (the 'no clips yet' refusal)", r.ok && !!emptyVox, r.error);

  r = await cmd("track.add", { name: "Vocal Bus", kind: "bus" });
  const bus = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("bus added (the 'holds no clips' refusal)", r.ok && !!bus, r.error);

  // THREE audio clips at beats 0 / 8 / 16 — NON-OVERLAPPING on purpose: leg A
  // refuses an overlapping pair, and a fixture that could not convert would
  // photograph a refusal rather than the composer.
  const clipIDs = [];
  for (const [i, beat] of [0, 8, 16].entries()) {
    const wav = path.join(scratchWav, `take-${i}.wav`);
    makeWav(wav);
    r = await cmd("clip.addAudio", { trackId: vox, path: wav, atBeat: beat });
    const cid = r.result?.id ?? r.result?.clip?.id;
    if (cid) clipIDs.push(cid);
    ck(`audio clip ${i + 1} at beat ${beat}`, r.ok && !!cid, r.error ?? JSON.stringify(r.result));
  }
  // A MIDI clip in the same project: the AUDIO-ONLY filter must not count it.
  r = await cmd("clip.addMIDI", { trackId: keys, atBeat: 0, lengthBeats: 4 });
  const midiClip = r.result?.id ?? r.result?.clip?.id;
  ck("MIDI clip added", r.ok && !!midiClip, r.error);

  // --- 1. THE MENU, BEFORE ANY SELECTION. It must EXIST and be greyed with no
  // count (the m23-cf inert-title rule).
  r = await cmd("debug.voicePanel", {});
  ck("inert Edit item exists, greyed, WITHOUT a count",
    r.result?.convertMenuEnabled === false
      && r.result?.convertMenuTitle === "Convert Clips to Voice…",
    JSON.stringify(r.result)?.slice(0, 300));

  // --- 2. SELECT the three audio clips + the MIDI clip. The title must count
  // THREE — the audio subset — never four.
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[0] });
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[1], shift: true });
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[2], shift: true });
  await cmd("debug.arrangeSelection", { act: "click", clipId: midiClip, shift: true });
  r = await cmd("debug.voicePanel", {});
  ck("a MIXED selection of 4 counts the 3 AUDIO clips, and says so",
    r.result?.convertMenuEnabled === true
      && r.result?.convertMenuTitle === "Convert 3 Clips to Voice…"
      && r.result?.selectedAudioClips === 3,
    JSON.stringify(r.result)?.slice(0, 300));

  // --- 3. OPEN THROUGH THE REAL EDIT-MENU FUNNEL (`performMenuVoiceConvert`),
  // not by setting a flag — the `debug.effectEditor {add}` rule.
  r = await cmd("debug.voicePanel", {
    sidecarState: "healthy",
    seedVoiceList: [
      { id: "dmitry", name: "Dmitry (my voice)", state: "ready" },
      { id: "backing", name: "Backing Stack", state: "needsConversion" },
      { id: "base", name: "Base (untrained)", state: "ready", kind: "builtin", trained: false,
        note: "pipeline smoke target — proves conversion runs, not a real voice" },
    ],
    convertSelection: true,
  });
  ck("Edit ▸ Convert opened the panel on exactly the 3 audio clips",
    r.ok && (r.result?.convertClipIds ?? []).length === 3,
    r.error ?? JSON.stringify(r.result)?.slice(0, 300));

  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-1-composer.png` });
  ck("captured: the COMPOSER face (voice picker + clip list + pitch)", r.ok, r.error);

  // --- 3b. THE ARMED PRIMARY. The panel's `.task` re-probes the REAL sidecar
  // on appear and overwrites a seeded status, so healthy is re-seeded before
  // every capture from here on — the banner is a truthful readout, not a
  // fixture, and it will keep telling the truth unless told otherwise.
  r = await cmd("debug.voicePanel", {
    sidecarState: "healthy", pickVoice: "dmitry", convertPitch: 2,
  });
  ck("a voice is picked and the pitch is set",
    r.result?.pickedVoice === "dmitry" && r.result?.convertPitch === 2,
    JSON.stringify(r.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-1b-armed.png` });
  ck("captured: the ARMED face (picked row violet-lit, primary violet + glowing)", r.ok, r.error);

  // --- 4. THE CONVERTING FACE. A real run is minutes-class, so the progress is
  // SEEDED — model state only, no sidecar and no engine.
  r = await cmd("debug.voicePanel", {
    sidecarState: "healthy",
    seedProgress: true, progressTotal: 3, progressCompleted: 1,
    progressPhase: "converting", progressClip: "Lead Vox", progressElapsedSeconds: 47,
  });
  ck("progress staged: CLIP 2/3, converting",
    r.result?.convertProgress?.step === "CLIP 2/3"
      && r.result?.convertProgress?.phase === "converting",
    JSON.stringify(r.result?.convertProgress));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-2-converting.png` });
  ck("captured: the CONVERTING face", r.ok, r.error);

  // --- 5. THE RESULT FACE, with a non-fatal warning and the base honesty strip.
  r = await cmd("debug.voicePanel", {
    sidecarState: "healthy",
    clearProgress: true,
    seedResult: true, resultTrackName: "Voice: base", resultClips: 3,
    resultRealConversion: false,
    resultNote: "base is the untrained generic target, not a real voice",
    resultWarnings: [
      "the converted audio for \"take-1\" is 16.4 s but the clip presents 16 s — the clip keeps its original length, so the difference is not heard; the voice engine changed the length",
    ],
    resultInferSeconds: 4.2,
  });
  ck("result staged with one warning",
    (r.result?.lastConversion?.warnings ?? []).length === 1
      && r.result?.lastConversion?.clips === 3,
    JSON.stringify(r.result?.lastConversion)?.slice(0, 300));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-3-result.png` });
  ck("captured: the RESULT face (warnings + base honesty strip)", r.ok, r.error);

  // --- 6. A REFUSAL, IN THE STORE'S OWN WORDS. The panel must print it verbatim.
  r = await cmd("debug.voicePanel", {
    sidecarState: "healthy",
    clearResult: true,
    seedConvertError: "\"take-1\" (beats 0.0–2.0) and \"take-2\" (beats 1.0–3.0) overlap, so one track cannot hold both at their own beats — convert them in two passes (each conversion makes its own track), or trim the overlap first",
  });
  ck("refusal staged", typeof r.result?.convertError === "string", JSON.stringify(r.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-4-refusal.png` });
  ck("captured: the REFUSAL face", r.ok, r.error);

  // --- 7. THE WINDOW FLOOR, which is where a centred card goes wrong. A card
  // that overhangs loses its FIRST and LAST rows — the close ✕ and the CONVERT
  // button. `VoiceConvertSheetLayout.reservedChromeHeight` is the one constant
  // no test can derive, and this is where its error would show.
  const before = await cmd("debug.windowFrame", {});
  const floored = await cmd("debug.windowFrame", { width: 1440, height: 400 });
  ck("the window is at its height floor (clamped, as designed)",
    floored.result?.height === floored.result?.minHeight,
    JSON.stringify(floored.result)?.slice(0, 200));
  // An EMPTY message CLEARS the strip — it must never draw a warning triangle
  // with no words (measured: it did, before the guard).
  r = await cmd("debug.voicePanel", { sidecarState: "healthy", seedConvertError: "" });
  ck("an empty refusal message clears the strip rather than drawing a blank one",
    r.result?.convertError === undefined, JSON.stringify(r.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-5-window-floor.png` });
  ck("captured: the composer at the WINDOW FLOOR", r.ok, r.error);
  if (typeof before.result?.height === "number") {
    await cmd("debug.windowFrame", { width: before.result.width, height: before.result.height });
  }

  // --- 8. The single-clip route still opens the same panel (the kept
  // `convertSheet` alias — every existing caller named one clip).
  await cmd("debug.voicePanel", { closeSheet: true });
  r = await cmd("debug.voicePanel", { convertSheet: clipIDs[0] });
  ck("the single-clip alias opens the SAME panel on one clip",
    (r.result?.convertClipIds ?? []).length === 1
      && r.result?.convertSheetClipId === clipIDs[0],
    JSON.stringify(r.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-6-single-clip.png` });
  ck("captured: the panel on ONE clip", r.ok, r.error);

  r = await cmd("debug.voicePanel", { closeSheet: true });
  ck("panel closes", r.ok && r.result?.convertClipIds === undefined,
    JSON.stringify(r.result)?.slice(0, 200));

  // ══════════════════════════════════════════════════════════════════════════
  // LEG C — DRAGGING A VOICE MODEL ONTO A TRACK HEADER.
  //
  // ⚠️ THIS IS NOT A REAL OS DRAG, and the probe does not pretend otherwise.
  // SwiftUI's drop callbacks arrive from an AppKit dragging session with no
  // public initializer, and the unbundled staging binary has no Accessibility
  // grant to synthesize one (m17-b, −1712) — the same two reasons written up on
  // `debug.arrangeDrop`. `debug.voiceModelDrop` calls the VERY functions
  // `TrackRow`'s `.dropDestination` calls, with no branch between them, so the
  // staged path and the real path are one function rather than two that agree.
  // What is NOT covered here is the SOURCE gesture — that `.draggable` on the
  // Voice panel's row vends the payload — and that is stated in the report.
  // ══════════════════════════════════════════════════════════════════════════

  // The Voice panel is the drag SOURCE, so it has to be on screen for these
  // captures to show the gesture's two ends at once.
  r = await cmd("debug.voicePanel", {
    open: true, sidecarState: "healthy",
    seedVoiceList: [
      { id: "dmitry", name: "Dmitry (my voice)", state: "ready" },
      { id: "backing", name: "Backing Stack", state: "needsConversion" },
      { id: "base", name: "Base (untrained)", state: "ready", kind: "builtin", trained: false,
        note: "pipeline smoke target — proves conversion runs, not a real voice" },
    ],
  });
  ck("Voice panel open with a voice list to drag from",
    r.ok && r.result?.visible === true, r.error ?? JSON.stringify(r.result)?.slice(0, 200));

  // --- C1. THE VERDICT LADDER, before any hover. A fixture MUST be built from
  // this rather than assume which rows accept (the `trackHeaderDrag` rule).
  r = await cmd("debug.voiceModelDrop", {});
  const ladder = Object.fromEntries((r.result?.tracks ?? []).map((t) => [t.id, t]));
  ck("the ladder answers for every track", r.ok && Object.keys(ladder).length === 4,
    r.error ?? JSON.stringify(r.result?.tracks)?.slice(0, 400));
  ck("the AUDIO track with 3 clips accepts, and names the blast radius",
    ladder[vox]?.accepts === true
      && ladder[vox]?.audioClips === 3
      && ladder[vox]?.title === "Convert 3 Clips to Voice…",
    JSON.stringify(ladder[vox]));
  ck("the INSTRUMENT track refuses, and names the remedy",
    ladder[keys]?.accepts === false && ladder[keys]?.reason === "Bounce to audio first",
    JSON.stringify(ladder[keys]));
  ck("the EMPTY audio track refuses for a DIFFERENT reason than the instrument one",
    ladder[emptyVox]?.accepts === false
      && ladder[emptyVox]?.reason === "No audio clips yet"
      && ladder[emptyVox]?.reason !== ladder[keys]?.reason,
    JSON.stringify(ladder[emptyVox]));
  ck("the BUS refuses — it holds no clips and never will",
    ladder[bus]?.accepts === false && ladder[bus]?.reason === "Buses hold no clips",
    JSON.stringify(ladder[bus]));
  ck("nothing is painted before any hover",
    r.result?.hoverVisible === false && r.result?.paintedTrackId === null,
    JSON.stringify(r.result)?.slice(0, 200));

  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-7-drop-resting.png` });
  ck("captured: the RESTING state (headers + the draggable voice list + its hint)", r.ok, r.error);

  // --- C2. TARGETED, ACCEPTING. `paintedTrackId` is reported by the CHIP
  // ITSELF — the `indicatorY` rule: "gone after" alone passes vacuously against
  // an implementation that never drew one.
  r = await cmd("debug.voiceModelDrop", { act: "enter", trackId: vox });
  ck("hovering the audio track: violet accept chip PAINTED on that row",
    r.result?.hoverVisible === true
      && r.result?.hoverTrackId === vox
      && r.result?.hoverAccepts === true
      && r.result?.paintedTrackId === vox
      && r.result?.paintedAccepts === true,
    JSON.stringify(r.result)?.slice(0, 400));
  const hoveredClipIDs = r.result?.hoverClipIds ?? [];
  ck("the hover names the SAME three clips, in start-beat order",
    JSON.stringify(hoveredClipIDs) === JSON.stringify(clipIDs),
    `${JSON.stringify(hoveredClipIDs)} vs ${JSON.stringify(clipIDs)}`);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-8-drop-accept.png` });
  ck("captured: the TARGETED-ACCEPT face (violet stroke + bloom + CONVERT 3 CLIPS)", r.ok, r.error);

  // --- C3. TARGETED, REFUSING (instrument). Amber, no bloom, and it says why.
  r = await cmd("debug.voiceModelDrop", { act: "enter", trackId: keys });
  ck("hovering the instrument track: amber refusal chip PAINTED, on THAT row",
    r.result?.hoverAccepts === false
      && r.result?.hoverReason === "Bounce to audio first"
      && r.result?.paintedTrackId === keys
      && r.result?.paintedAccepts === false
      && (r.result?.hoverClipIds ?? []).length === 0,
    JSON.stringify(r.result)?.slice(0, 400));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-9-drop-refuse-midi.png` });
  ck("captured: the TARGETED-REFUSE face on a MIDI track", r.ok, r.error);

  // --- C4. TARGETED, REFUSING (empty audio track) — the refusal that is about
  // the MOMENT rather than the kind.
  r = await cmd("debug.voiceModelDrop", { act: "enter", trackId: emptyVox });
  ck("hovering the empty audio track: its own words, on its own row",
    r.result?.hoverReason === "No audio clips yet" && r.result?.paintedTrackId === emptyVox,
    JSON.stringify(r.result)?.slice(0, 300));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-10-drop-refuse-empty.png` });
  ck("captured: the TARGETED-REFUSE face on an EMPTY audio track", r.ok, r.error);

  // --- C5. A REFUSED DROP OPENS NOTHING.
  r = await cmd("debug.voiceModelDrop", { act: "drop", trackId: keys, voiceId: "dmitry" });
  ck("dropping on the instrument track is REJECTED and opens no panel",
    r.result?.dropAccepted === false
      && r.result?.convertClipIds === null
      && r.result?.hoverVisible === false,
    JSON.stringify(r.result)?.slice(0, 300));

  // --- C6. THE EXIT clears the affordance (and the chip reports it gone).
  await cmd("debug.voiceModelDrop", { act: "enter", trackId: vox });
  r = await cmd("debug.voiceModelDrop", { act: "exit" });
  ck("leaving clears the hover AND the paint",
    r.result?.hoverVisible === false && r.result?.paintedTrackId === null,
    JSON.stringify(r.result)?.slice(0, 300));

  // --- C7. ⭐⭐ THE LOAD-BEARING ONE: a drop opens the SAME panel, on that
  // track's audio clips, with the DRAGGED voice already picked.
  r = await cmd("debug.voiceModelDrop", { act: "drop", trackId: vox, voiceId: "dmitry" });
  const droppedIDs = r.result?.convertClipIds ?? [];
  ck("the drop opens the panel on the track's audio clips, with the dragged voice armed",
    r.result?.dropAccepted === true
      && JSON.stringify(droppedIDs) === JSON.stringify(clipIDs)
      && r.result?.pickedVoice === "dmitry"
      && r.result?.hoverVisible === false,
    JSON.stringify(r.result)?.slice(0, 400));

  // The two seams must describe ONE panel — they read the same properties, so a
  // disagreement here would mean a second copy of the state exists.
  const viaPanel = await cmd("debug.voicePanel", {});
  ck("debug.voicePanel and debug.voiceModelDrop describe the SAME open panel",
    JSON.stringify(viaPanel.result?.convertClipIds ?? []) === JSON.stringify(droppedIDs)
      && viaPanel.result?.pickedVoice === "dmitry",
    JSON.stringify(viaPanel.result)?.slice(0, 300));

  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m24m-11-drop-opened-panel.png` });
  ck("captured: the panel the DROP opened — armed, on the track's three clips", r.ok, r.error);

  // --- C8. ⭐⭐ SAME PANEL, SAME CODE PATH. Select those very clips and open
  // through Edit ▸ Convert: the resolved set must be IDENTICAL. If dragging
  // produced a different result from selecting the same clips and using
  // Edit ▸ Convert, that is a bug — this is the check that would see it.
  await cmd("debug.voicePanel", { closeSheet: true });
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[0] });
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[1], shift: true });
  await cmd("debug.arrangeSelection", { act: "click", clipId: clipIDs[2], shift: true });
  r = await cmd("debug.voicePanel", { convertSelection: true });
  ck("Edit ▸ Convert on the same clips resolves the SAME set the DROP did",
    JSON.stringify(r.result?.convertClipIds ?? []) === JSON.stringify(droppedIDs),
    `${JSON.stringify(r.result?.convertClipIds)} vs ${JSON.stringify(droppedIDs)}`);
  // ⚠️ …and the ONE honest difference: the menu route names no voice, so it
  // opens DISARMED. A drag that did not arm the panel would have made the
  // choice the user just expressed meaningless.
  ck("…and opens DISARMED, because the menu route names no voice",
    r.result?.pickedVoice === null || r.result?.pickedVoice === undefined,
    JSON.stringify(r.result?.pickedVoice));
  await cmd("debug.voicePanel", { closeSheet: true });

  console.log(`M24M_PROBE pass=${pass} fail=${fail}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
  console.log("staging stopped (pidfile-exact)");
}
process.exit(fail === 0 ? 0 : 1);
