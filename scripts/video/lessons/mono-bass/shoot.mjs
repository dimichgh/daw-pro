// L8 "Mono Your Bass" — REBUILD. Pass 1: build the material in the DAW and
// render every wav the film measures.
//
// ⚠ STAGING ONLY. build.mjs refuses port 17600 outright; this file never names
// a port at all.
//
// THE MATERIAL, and why every part of it is the way it is:
//
//  * ONE bassline, played by TWO identical instrument tracks, hard left and
//    hard right. No widener, no plugin. The ONLY difference between renders is
//    that the right-hand copy's notes are nudged a few milliseconds late —
//    which is what most "stereo widening" tricks do underneath.
//
//  * THE NUDGE IS APPLIED TO THE NOTES, NOT WITH clip.move. A clip position can
//    be snapped to a grid by an overlap/quantise policy and a 0.01-beat nudge
//    would vanish silently; note startBeats are plain floats. The real offset
//    is MEASURED back off the render by cross-correlation (measure.py) rather
//    than assumed.
//
//  * A SAW, NOT A SINE. A real bass has harmonics, and the harmonics are where
//    the mid-band consequence of a comb filter lives — the part a laptop
//    speaker CAN reproduce. A sine would have made the whole lesson sub-100 Hz,
//    which is the exact fault this rebuild exists to fix.
//
//  * THE NOTES ARE CHOSEN, NOT INVENTED. Summing two copies τ apart multiplies
//    frequency f by |cos(π f τ)|. At τ = 6 ms that is a null at 83.3 Hz and a
//    peak at 166.7 Hz. E2 = 82.41 Hz sits ON the null (predicted −35.2 dB);
//    E1 = 41.20 Hz, the same note an octave down, predicts −2.9 dB. The riff
//    deliberately plays both, plus notes at every distance in between, so
//    "how bad it gets depends on the note" is demonstrated rather than stated.
import { open, cmd, addTrack, addClip, n, close, burst, shot } from "../../session/build.mjs";
import fs from "node:fs";

const AUD = process.env.MB_AUDIO || "./audio";
const BPM = 100;                 // 1 beat = 600 ms, so 6 ms = 0.01 beat exactly
const BEAT_MS = 60000 / BPM;

// ---------------------------------------------------------------- the riff
// MIDI: E1 28 (41.20 Hz) · A1 33 (55.00) · B1 35 (61.74) · D2 38 (73.42)
//       E2 40 (82.41) · F#2 42 (92.50) · G2 43 (98.00) · A2 45 (110.00)
//       C3 48 (130.81)
const E1 = 28, A1 = 33, B1 = 35, D2 = 38, E2 = 40, FS2 = 42, G2 = 43, A2 = 45, C3 = 48;
const BARS = [
  [[0, E1, .45], [.5, E1, .45], [1.5, E1, .45], [2, E2, .45], [3, E1, .45], [3.5, B1, .45]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E2, .45], [2, E1, .45], [2.5, D2, .45], [3.5, E2, .95]],
  [[0, G2, .45], [.5, G2, .45], [1.5, G2, .45], [2, D2, .45], [3, G2, .45], [3.5, A1, .45]],
  [[0, A1, .45], [.5, A1, .45], [1.5, A2, .45], [2, A1, .45], [2.5, C3, .45], [3.5, A1, .95]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E1, .45], [2, E2, .45], [3, E1, .45], [3.5, B1, .45]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E2, .45], [2, E1, .45], [2.5, D2, .45], [3.5, E2, .95]],
  [[0, FS2, .45], [.5, FS2, .45], [1.5, FS2, .45], [2, A1, .45], [3, FS2, .45], [3.5, E2, .45]],
  [[0, E1, .45], [1, E2, .95], [2, E1, .45], [2.5, E1, .45], [3, E2, 1.0]],
];
const RIFF = [];
BARS.forEach((bar, b) => bar.forEach(([o, p, l]) => RIFF.push(n(b * 4 + o, p, l, 108))));
const LEN_BEATS = 32;
const SECS = LEN_BEATS * (60 / BPM);          // 19.2 s

const BASS = {
  kind: "polySynth", waveform: "saw",
  attack: 0.005, decay: 0.25, sustain: 0.55, release: 0.12,
  cutoffHz: 1400, resonance: 0.15, gain: 0.55,
};

const shift = (notes, dBeats) =>
  notes.map(x => ({ ...x, startBeat: +(x.startBeat + dBeats).toFixed(6) }));

async function rig(offsetMs) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: BPM });
  const dBeats = offsetMs / BEAT_MS;
  const L = await addTrack("Bass L", { instrument: BASS, pan: -1 });
  const R = await addTrack("Bass R", { instrument: BASS, pan: 1 });
  const cl = await addClip(L, 0, LEN_BEATS + 1, RIFF, "Bass L");
  const cr = await addClip(R, 0, LEN_BEATS + 1, shift(RIFF, dBeats), "Bass R");
  return { L, R, cl, cr, dBeats };
}

const mix = (name, secs = SECS + 1.2) =>
  cmd("render.mixdown", { path: `${AUD}/${name}.wav`, durationSeconds: secs })
    .then(r => console.log(`  ${name}.wav  ${r.durationSeconds?.toFixed?.(2)}s`));

await open();

// ── the three stereo renders. 0 ms is the baseline; 6 ms is the disaster;
//    15 ms is the counterintuitive control (a much BIGGER nudge that does far
//    LESS damage, because the null moves off the notes being played).
for (const ms of [0, 6, 15]) {
  await rig(ms);
  await mix(`st${ms}`);
}

// ── a MONO-SOURCE control: one track, centred, no second copy at all. This is
//    what the bass "really" is, and the file the 0 ms fold should match.
{
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: BPM });
  const t = await addTrack("Bass", { instrument: BASS, pan: 0 });
  await addClip(t, 0, LEN_BEATS + 1, RIFF, "Bass");
  await mix("single");
}

// ── the film's pictures, shot on the 6 ms project so the app on screen IS the
//    thing being measured.
{
  const { cl } = await rig(6);
  await cmd("transport.seek", { beats: 0 });
  await cmd("ui.showMixer", { show: false });
  await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
  await shot("arrange");
  await cmd("ui.showMixer", { show: true });
  await shot("mixer");
  await cmd("ui.showMixer", { show: false });
  await cmd("debug.panelLayout", { editorMaximized: true, pianoRollPPB: 26, pianoRollRowHeight: 12 });
  await cmd("debug.captureUI", { path: `${process.env.SESSION_SHOTS || "./shots"}/roll.png`, selectClip: cl });
  // ⚠ The roll opens anchored high in the 128-row pitch stack; this bass lives
  // at MIDI 28–48 and would photograph as an EMPTY GRID without this.
  await cmd("debug.panelLayout", { pianoRollCenterPitch: 38 });
  await shot("roll");
  await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.43 });
  // real motion: the transport actually running across the arrangement
  await burst("mb-arrange", 9.0, 0, { arrange: true });
}

// ── THE APP'S OWN CORRELATION METER, photographed WHILE THE TRANSPORT RUNS.
//    The master strip carries a "STEREO IMAGE / MONO SAFETY" goniometer with a
//    phase-correlation readout, and it is the one place in this whole lesson
//    where the app itself measures the fault. At rest it reads +1.00; the
//    number only means anything while audio is flowing, so these are shot
//    during playback and NOT from a stopped transport.
//    ⚠ Master to zero first: nobody asked for the bass out of their speakers.
//    ⚠ MASTER AT 0.03, NOT 0. Every other burst in this repo drops the master
//    to zero so a build does not shout out of the machine's speakers — but the
//    correlation meter is fed from the OUTPUT, and at volume 0 it reads a
//    static "+1.00 IN PHASE" with an empty goniometer, which is the IDLE state
//    and looks exactly like a real measurement. MEASURED: the first take of
//    these shots came back +1.00 for all three offsets, and two of the six
//    files were byte-identical. 0.03 is about −30 dB — the meter is live and
//    the room is quiet.
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const SH = process.env.SESSION_SHOTS || "./shots";
for (const ms of [0, 6, 15]) {
  await rig(ms);
  await cmd("mixer.setMasterVolume", { volume: 0.03 });
  await cmd("ui.showMixer", { show: true });
  await cmd("transport.seek", { beats: 0 });
  await cmd("transport.play", {});
  await sleep(2500);
  await shot(`phase${ms}-a`);
  await sleep(1200);
  await shot(`phase${ms}-b`);
  // ⚠ SUPERSEDED — there is no metercrop.py and there never was one. This
  //   loop used to shoot a `_raw-meter{ms}` burst by hammering debug.captureUI,
  //   which yields ~3 fps and a jerky picture. The film's meter footage now
  //   comes from record.mjs (ScreenCaptureKit, 30 fps, --scale 2.0) and is
  //   cropped by bursts.py. The two STILLS above are still used, as the
  //   METER0/METER6 zooms in spec.py.
  await cmd("transport.stop", {});
  await cmd("mixer.setMasterVolume", { volume: 1 });
}
await cmd("ui.showMixer", { show: false });

fs.writeFileSync(`${AUD}/riff.json`, JSON.stringify({
  bpm: BPM, beatMs: BEAT_MS, lengthBeats: LEN_BEATS, seconds: SECS,
  noteCount: RIFF.length, notes: RIFF,
}, null, 1));
console.log(`  riff.json  ${RIFF.length} notes, ${SECS}s at ${BPM} BPM`);

await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
close();
process.exit(0);
